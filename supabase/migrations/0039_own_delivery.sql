-- 0039: delivery by the seller's own rider, with a PIN and a step-by-step status. No outside delivery company is needed.
--
-- How it works
--   1. The buyer chose delivery and the seller confirmed the order.
--   2. The seller starts the delivery (optionally naming the rider) -> status "assigned".
--   3. The seller moves it along: picked up, on the way.
--   4. The buyer sees each step and a 4 digit PIN. At hand-over the buyer tells the rider the PIN, and the seller types it in.
--      A right PIN marks the delivery "delivered" and the order "handed over" (the buyer then confirms as usual). That is the proof.
--   5. Five wrong PINs lock the delivery. The seller must cancel it or ask support.
--
-- This is NOT live tracking: there is no map and no location. The rider is the seller's own, and ZedMarket does not verify them.
-- Yango, inDrive and live tracking belong to a later module and need the provider's approval.

alter table public.deliveries add column rider_name text check (rider_name is null or char_length(rider_name) between 2 and 60);

-- The PIN lives in its own closed table. Only the functions below can read it, and only the buyer is ever shown it.
create table public.delivery_pins (
  delivery_id uuid primary key references public.deliveries (id) on delete cascade,
  pin text not null check (pin ~ '^[0-9]{4}$')
);
alter table public.delivery_pins enable row level security;

create function public.delivery_event_add(p_delivery uuid, p_status public.delivery_status, p_source text, p_note text) returns void
language sql security definer set search_path = ''
as $$
  insert into public.delivery_events (delivery_id, status, source, actor_id, note)
  values (p_delivery, p_status, p_source, (select auth.uid()), left(p_note, 300));
$$;

-- Start a delivery for a confirmed delivery order.
create function public.delivery_start(p_order uuid, p_pickup text, p_rider text default null) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders;
  new_id uuid;
  pin text := lpad((floor(random() * 10000))::integer::text, 4, '0');
  pickup text := nullif(btrim(coalesce(p_pickup, '')), '');
  rider text := nullif(btrim(coalesce(p_rider, '')), '');
begin
  o := public.order_lock(p_order);
  if not public.order_is_seller_side(o) then
    raise exception 'This is not your order.' using errcode = 'insufficient_privilege';
  end if;
  if o.fulfilment <> 'delivery' or o.status <> 'confirmed' or o.handed_over_at is not null then
    raise exception 'A delivery can only be started for a confirmed order that is to be delivered.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.deliveries d where d.order_id = o.id and d.status not in ('cancelled', 'failed')) then
    raise exception 'This order already has a delivery.' using errcode = 'check_violation';
  end if;
  if pickup is null or char_length(pickup) > 300 then
    raise exception 'Say where the item will be picked up (up to 300 characters).' using errcode = 'check_violation';
  end if;
  if rider is not null and char_length(rider) not between 2 and 60 then
    raise exception 'The rider name must be 2 to 60 characters.' using errcode = 'check_violation';
  end if;

  insert into public.deliveries (order_id, seller_id, buyer_id, provider, status, pickup_address, destination_address, rider_name)
  values (o.id, o.seller_id, o.buyer_id, 'zedmarket', 'assigned', pickup, o.delivery_address, rider)
  returning id into new_id;
  insert into public.delivery_pins (delivery_id, pin) values (new_id, pin);
  perform public.delivery_event_add(new_id, 'assigned', 'seller', case when rider is null then 'Delivery arranged by the seller.' else 'Delivery arranged. Rider: ' || rider end);
  perform public.notify(o.buyer_id, 'orders', 'delivery_started', 'Your delivery is arranged',
    'Open the order to see your delivery PIN. Give it to the rider only when you have the item.', '/order/' || o.id, 'delivery_started:' || new_id);
  return new_id;
end;
$$;

-- Move the delivery along: assigned -> picked_up -> in_transit.
create function public.delivery_set_status(p_delivery uuid, p_status public.delivery_status) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  d public.deliveries;
  o public.orders;
  label text;
begin
  select * into d from public.deliveries where id = p_delivery for update;
  if not found then
    raise exception 'Delivery not found.' using errcode = 'no_data_found';
  end if;
  o := public.order_lock(d.order_id);
  if not public.order_is_seller_side(o) then
    raise exception 'This is not your delivery.' using errcode = 'insufficient_privilege';
  end if;
  if not ((d.status = 'assigned' and p_status = 'picked_up') or (d.status = 'picked_up' and p_status = 'in_transit')) then
    raise exception 'That step is not allowed after "%".', d.status using errcode = 'check_violation';
  end if;
  update public.deliveries set status = p_status where id = d.id;
  label := case p_status when 'picked_up' then 'The rider has picked up your item.' else 'Your item is on its way.' end;
  perform public.delivery_event_add(d.id, p_status, 'seller', label);
  perform public.notify(d.buyer_id, 'orders', 'delivery_' || p_status::text, case p_status when 'picked_up' then 'Item picked up' else 'On its way' end,
    label, '/order/' || d.order_id, 'delivery_' || p_status::text || ':' || d.id);
end;
$$;

-- The seller types the PIN the buyer gives at the door. A right PIN is the proof of delivery.
create function public.delivery_confirm_dropoff(p_delivery uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  d public.deliveries;
  o public.orders;
  real_pin text;
  limit_attempts constant integer := 5;
begin
  select * into d from public.deliveries where id = p_delivery for update;
  if not found then
    raise exception 'Delivery not found.' using errcode = 'no_data_found';
  end if;
  o := public.order_lock(d.order_id);
  if not public.order_is_seller_side(o) then
    raise exception 'This is not your delivery.' using errcode = 'insufficient_privilege';
  end if;
  if d.status not in ('picked_up', 'in_transit') then
    raise exception 'The item must be picked up before it can be handed over.' using errcode = 'check_violation';
  end if;
  if d.pin_attempts >= limit_attempts then
    raise exception 'Too many wrong PINs. Cancel this delivery or ask support to help.' using errcode = 'check_violation';
  end if;

  select pin into real_pin from public.delivery_pins where delivery_id = d.id;
  if real_pin is distinct from btrim(coalesce(p_pin, '')) then
    -- A wrong PIN is an answer, not an error: raising an error would undo the attempt counter.
    update public.deliveries set pin_attempts = pin_attempts + 1 where id = d.id;
    return jsonb_build_object('ok', false, 'attempts_left', greatest(limit_attempts - d.pin_attempts - 1, 0));
  end if;

  update public.deliveries set status = 'delivered' where id = d.id;
  perform public.delivery_event_add(d.id, 'delivered', 'seller', 'Delivered. The buyer''s PIN was entered as proof.');
  perform public.mark_handed_over(o.id);
  return jsonb_build_object('ok', true, 'attempts_left', limit_attempts - d.pin_attempts);
end;
$$;

create function public.delivery_cancel(p_delivery uuid, p_reason text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  d public.deliveries;
  o public.orders;
  why text := left(nullif(btrim(coalesce(p_reason, '')), ''), 300);
begin
  if why is null then
    raise exception 'Say why the delivery is cancelled.' using errcode = 'check_violation';
  end if;
  select * into d from public.deliveries where id = p_delivery for update;
  if not found then
    raise exception 'Delivery not found.' using errcode = 'no_data_found';
  end if;
  o := public.order_lock(d.order_id);
  if not public.order_is_seller_side(o) then
    raise exception 'This is not your delivery.' using errcode = 'insufficient_privilege';
  end if;
  if d.status not in ('assigned', 'picked_up', 'in_transit') then
    raise exception 'This delivery can no longer be cancelled.' using errcode = 'check_violation';
  end if;
  update public.deliveries set status = 'cancelled', status_reason = why where id = d.id;
  perform public.delivery_event_add(d.id, 'cancelled', 'seller', why);
  perform public.notify(d.buyer_id, 'orders', 'delivery_cancelled', 'Delivery cancelled',
    'The seller cancelled this delivery: ' || why, '/order/' || d.order_id, 'delivery_cancelled:' || d.id);
end;
$$;

-- What the order screen shows. The buyer sees the PIN while the delivery is active; the seller never does.
create function public.delivery_view(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  o public.orders;
  d public.deliveries;
  is_buyer boolean;
  events jsonb;
  pin text;
begin
  select * into o from public.orders where id = p_order;
  if not found then return null; end if;
  is_buyer := o.buyer_id = uid;
  if not (is_buyer or public.order_is_seller_side(o) or public.has_staff_role('support')) then
    raise exception 'This is not your order.' using errcode = 'insufficient_privilege';
  end if;
  select * into d from public.deliveries where order_id = p_order order by created_at desc limit 1;
  if not found then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('status', e.status, 'note', e.note, 'at', e.created_at) order by e.id), '[]') into events
    from public.delivery_events e where e.delivery_id = d.id;
  if is_buyer and d.status in ('assigned', 'picked_up', 'in_transit') then
    select p.pin into pin from public.delivery_pins p where p.delivery_id = d.id;
  end if;
  return jsonb_build_object(
    'id', d.id, 'status', d.status, 'rider_name', d.rider_name, 'pickup_address', d.pickup_address,
    'destination_address', d.destination_address, 'status_reason', d.status_reason,
    'pin', pin, 'attempts_left', greatest(5 - d.pin_attempts, 0), 'events', events
  );
end;
$$;

revoke execute on function public.delivery_event_add(uuid, public.delivery_status, text, text), public.delivery_start(uuid, text, text),
  public.delivery_set_status(uuid, public.delivery_status), public.delivery_confirm_dropoff(uuid, text),
  public.delivery_cancel(uuid, text), public.delivery_view(uuid) from public, anon, authenticated;
grant execute on function public.delivery_start(uuid, text, text), public.delivery_set_status(uuid, public.delivery_status),
  public.delivery_confirm_dropoff(uuid, text), public.delivery_cancel(uuid, text), public.delivery_view(uuid) to authenticated;
