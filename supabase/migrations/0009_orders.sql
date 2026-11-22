-- 0009: Order management (Module B)
--
-- What this adds to the orders from migration 0003:
--   * a reservation table so one single-quantity item can only be reserved once
--     (the primary key on listing_id is the final safeguard; row locks keep
--     concurrent requests orderly)
--   * expiry of unanswered requests and of confirmed orders nobody collects
--   * decline, cancel, hand-over and complete as separate, checked steps
--   * an event history for every order
--   * collection or delivery with a delivery address and a disclosed delivery fee
--   * digital receipts that record the agreed deal
--   * staff settlement of disputed orders
--
-- No money moves through any of this. The receipt says so.
--
-- Changed from earlier migrations, on purpose:
--   * create_order gains two optional arguments, so the old two-argument version is dropped
--     and replaced. Calls with one or two arguments keep working.
--   * set_order_status, open_dispute and the public_listings view are redefined.
--     set_order_status keeps its signature and now hands over to the new functions.

-- ---------------------------------------------------------------------------
-- Settings (starting values, to be tuned after the pilot)
-- ---------------------------------------------------------------------------

insert into public.platform_settings (key, value, note) values
  ('order.request_expiry_hours', '48', 'Hours a seller has to answer a buy request before it expires. Starter value.'),
  ('order.confirmed_expiry_days', '7', 'Days a confirmed order can wait for hand-over before it expires and the item is released. Starter value.'),
  ('order.auto_complete_days', '3', 'Days after the seller marks an item handed over before the order completes by itself, if the buyer has not responded or opened a dispute. Starter value.'),
  ('rate_limit.order.max', '10', 'Buy requests per window. Starter value.'),
  ('rate_limit.order.window_minutes', '60', null)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Order columns
-- ---------------------------------------------------------------------------

alter table public.orders
  add column buyer_name text,
  add column seller_name text,
  add column delivery_address text check (char_length(delivery_address) <= 300),
  add column buyer_note text check (char_length(buyer_note) <= 300),
  add column cancel_kind text check (cancel_kind in ('cancelled', 'declined', 'expired')),
  add column cancelled_by text check (cancelled_by in ('buyer', 'seller', 'system', 'staff')),
  add column confirmed_at timestamptz,
  add column handed_over_at timestamptz,
  add column completed_at timestamptz,
  add column expires_at timestamptz;

-- Orders made before this migration: fill the new columns as well as the old data allows.
update public.orders o
   set buyer_name = (select display_name from public.profiles where id = o.buyer_id),
       seller_name = coalesce((select name from public.businesses where id = o.business_id),
                              (select display_name from public.profiles where id = o.seller_id)),
       cancel_kind = case when o.status = 'cancelled' then 'cancelled' end,
       confirmed_at = case when o.status in ('confirmed', 'completed', 'disputed') then o.updated_at end,
       completed_at = case when o.status = 'completed' then o.updated_at end,
       expires_at = case o.status
                      when 'requested' then now() + interval '48 hours'
                      when 'confirmed' then now() + interval '7 days'
                    end;

alter table public.orders
  alter column buyer_name set not null,
  alter column seller_name set not null,
  add constraint orders_delivery_fee_cap check (delivery_fee_zmw <= 100000),
  add constraint orders_cancel_kind_matches check ((status = 'cancelled') = (cancel_kind is not null)),
  add constraint orders_delivery_needs_address check (fulfilment <> 'delivery' or delivery_address is not null) not valid;

-- The same buyer cannot hold two open orders for one item, even if two requests arrive together.
create unique index orders_one_open_per_buyer_item
  on public.orders (listing_id, buyer_id) where status in ('requested', 'confirmed');
create index orders_listing_idx on public.orders (listing_id);
create index orders_due_idx on public.orders (expires_at) where status in ('requested', 'confirmed');

-- ---------------------------------------------------------------------------
-- Reservations and event history
-- ---------------------------------------------------------------------------

-- One row per reserved item. The primary key is what makes a double reservation impossible.
create table public.listing_reservations (
  listing_id uuid primary key references public.listings (id) on delete cascade,
  order_id uuid not null unique references public.orders (id) on delete cascade,
  reserved_at timestamptz not null default now()
);
alter table public.listing_reservations enable row level security;
-- No grants and no policies: only the order functions below touch it.

create table public.order_events (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders (id) on delete cascade,
  actor_id uuid,
  actor_role text not null check (actor_role in ('buyer', 'seller', 'system', 'staff')),
  event text not null check (event in (
    'requested', 'confirmed', 'declined', 'cancelled', 'expired', 'handed_over',
    'completed', 'auto_completed', 'disputed', 'settled_by_staff')),
  note text,
  created_at timestamptz not null default clock_timestamp()
);
create index order_events_order_idx on public.order_events (order_id, id);
alter table public.order_events enable row level security;

grant select on public.order_events to authenticated;
create policy order_events_read on public.order_events
  for select to authenticated
  using (public.is_order_party(order_id) or public.has_staff_role('support'));

-- Reserved items drop out of browsing and search until they are released.
-- (Same columns as before, so everything that uses the view keeps working.)
create or replace view public.public_listings as
select
  l.id,
  l.title,
  l.price_zmw,
  l.condition,
  l.category_id,
  l.location_id,
  loc.town,
  loc.area,
  l.seller_id,
  p.display_name as seller_name,
  p.verification_level as seller_level,
  l.created_at,
  (select i.storage_path from public.listing_images i
    where i.listing_id = l.id order by i.position, i.created_at limit 1) as image_path
from public.listings l
join public.profiles p on p.id = l.seller_id
join public.locations loc on loc.id = l.location_id
where l.status = 'active'
  and l.moderation_status = 'approved'
  and p.account_state <> 'suspended'
  and not exists (select 1 from public.listing_reservations r where r.listing_id = l.id);

create function public.listing_is_reserved(p_listing_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.listing_reservations where listing_id = p_listing_id);
$$;

-- ---------------------------------------------------------------------------
-- Internal helpers (not callable from the app)
-- ---------------------------------------------------------------------------

-- Locks the item first and then the order, always in that order, so two people
-- acting on the same item queue up instead of deadlocking.
create function public.order_lock(p_order_id uuid)
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  lid uuid;
  o public.orders;
begin
  select listing_id into lid from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order not found.' using errcode = 'no_data_found';
  end if;
  perform 1 from public.listings where id = lid for update;
  select * into o from public.orders where id = p_order_id for update;
  return o;
end;
$$;

create function public.order_add_event(p_order_id uuid, p_role text, p_event text, p_note text default null)
returns void
language sql security definer set search_path = ''
as $$
  insert into public.order_events (order_id, actor_id, actor_role, event, note)
  values (p_order_id, (select auth.uid()), p_role, p_event, left(p_note, 300));
$$;

create function public.order_is_seller_side(p_order public.orders)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select (select auth.uid()) = p_order.seller_id
      or public.is_business_member(p_order.business_id, array['owner', 'manager', 'staff']::public.business_member_role[]);
$$;

-- The one place an order is cancelled, declined or expired. Frees the reservation.
create function public.order_end(p_order_id uuid, p_kind text, p_by text, p_reason text)
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders;
begin
  update public.orders
     set status = 'cancelled', cancel_kind = p_kind, cancelled_by = p_by,
         cancelled_reason = left(p_reason, 300), expires_at = null
   where id = p_order_id
   returning * into o;
  delete from public.listing_reservations where order_id = p_order_id;
  perform public.order_add_event(p_order_id, p_by,
    case p_kind when 'declined' then 'declined' when 'expired' then 'expired' else 'cancelled' end, p_reason);
  return o;
end;
$$;

-- The one place an order is completed. Marks the item sold and frees the reservation.
create function public.order_finish(p_order_id uuid, p_by text)
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders;
begin
  update public.orders
     set status = 'completed', completed_at = coalesce(completed_at, now()), expires_at = null
   where id = p_order_id
   returning * into o;
  update public.listings set status = 'sold', sold_at = coalesce(sold_at, now())
   where id = o.listing_id and status <> 'sold';
  delete from public.listing_reservations where order_id = p_order_id;
  perform public.order_add_event(p_order_id, p_by,
    case when p_by = 'system' then 'auto_completed' when p_by = 'staff' then 'settled_by_staff' else 'completed' end,
    case when p_by = 'staff' then 'Settled as completed.' end);
  return o;
end;
$$;

-- ---------------------------------------------------------------------------
-- Buyer and seller actions
-- ---------------------------------------------------------------------------

drop function public.create_order(uuid, public.fulfilment_method);

create function public.create_order(
  p_listing_id uuid,
  p_fulfilment public.fulfilment_method default 'collection',
  p_delivery_address text default null,
  p_note text default null
)
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  l public.listings;
  o public.orders;
  stale uuid;
  address text := nullif(btrim(p_delivery_address), '');
  note text := nullif(btrim(p_note), '');
begin
  if uid is null then
    raise exception 'Sign in to place an order.' using errcode = '28000';
  end if;
  if not public.account_can_post() then
    raise exception 'Your account cannot place orders right now.' using errcode = 'insufficient_privilege';
  end if;
  if p_fulfilment = 'delivery' and address is null then
    raise exception 'Enter a delivery address or a landmark the seller can find.' using errcode = 'check_violation';
  end if;
  if char_length(coalesce(address, '')) > 300 or char_length(coalesce(note, '')) > 300 then
    raise exception 'The address and note must each be 300 characters or fewer.' using errcode = 'check_violation';
  end if;
  if p_fulfilment = 'collection' then
    address := null;
  end if;

  perform public.enforce_rate_limit('order', 10, 60);

  -- Lock the item so requests and confirmations for it are handled one at a time.
  select * into l from public.listings
   where id = p_listing_id and status = 'active' and moderation_status = 'approved'
   for update;
  if not found then
    raise exception 'This listing is not available.' using errcode = 'no_data_found';
  end if;
  if l.seller_id = uid then
    raise exception 'You cannot order your own listing.' using errcode = 'check_violation';
  end if;
  if public.users_blocked(uid, l.seller_id) then
    raise exception 'You cannot order from this seller.' using errcode = 'insufficient_privilege';
  end if;

  -- A reservation nobody collected may be past its deadline: release it now instead of waiting for the scheduled job.
  select r.order_id into stale
    from public.listing_reservations r
    join public.orders ro on ro.id = r.order_id
   where r.listing_id = l.id and ro.status = 'confirmed' and ro.handed_over_at is null and ro.expires_at < now();
  if stale is not null then
    perform public.order_end(stale, 'expired', 'system', 'The order was not completed in time.');
  end if;

  if exists (select 1 from public.listing_reservations where listing_id = l.id) then
    raise exception 'This item is reserved for another buyer right now. Try again later.' using errcode = 'check_violation';
  end if;
  if exists (
    select 1 from public.orders
     where listing_id = l.id and buyer_id = uid and status in ('requested', 'confirmed')
  ) then
    raise exception 'You already have an open order for this item.' using errcode = 'unique_violation';
  end if;

  insert into public.orders (
    listing_id, buyer_id, seller_id, business_id, item_title, item_price_zmw, fulfilment,
    delivery_address, buyer_note, buyer_name, seller_name, expires_at)
  values (
    l.id, uid, l.seller_id, l.business_id, l.title, l.price_zmw, p_fulfilment,
    address, note,
    (select display_name from public.profiles where id = uid),
    coalesce((select name from public.businesses where id = l.business_id),
             (select display_name from public.profiles where id = l.seller_id)),
    now() + make_interval(hours => public.setting_numeric('order.request_expiry_hours', 48)::integer))
  returning * into o;

  perform public.order_add_event(o.id, 'buyer', 'requested', note);
  return o;
end;
$$;

-- Seller (or a business member) accepts the request. This reserves the item and
-- turns away every other open request for it. For delivery orders the seller states
-- the delivery fee here; the buyer sees it on the order and can still cancel.
create function public.confirm_order(p_order_id uuid, p_delivery_fee numeric default 0)
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders;
  l public.listings;
  other record;
  fee numeric := coalesce(p_delivery_fee, 0);
begin
  o := public.order_lock(p_order_id);
  if not public.order_is_seller_side(o) then
    raise exception 'This is not your order.' using errcode = 'insufficient_privilege';
  end if;
  if o.status <> 'requested' then
    raise exception 'That change is not allowed for this order.' using errcode = 'check_violation';
  end if;

  if o.expires_at is not null and o.expires_at < now() then
    return public.order_end(o.id, 'expired', 'system', 'The seller did not answer in time.');
  end if;

  select * into l from public.listings where id = o.listing_id;
  if l.status <> 'active' or l.moderation_status <> 'approved' then
    return public.order_end(o.id, 'declined', 'system', 'This item is no longer available.');
  end if;

  if fee < 0 or fee > 100000 then
    raise exception 'The delivery fee must be between K0 and K100,000.' using errcode = 'check_violation';
  end if;
  if o.fulfilment = 'collection' and fee <> 0 then
    raise exception 'A collection order has no delivery fee.' using errcode = 'check_violation';
  end if;

  insert into public.listing_reservations (listing_id, order_id) values (o.listing_id, o.id);

  update public.orders
     set status = 'confirmed', confirmed_at = now(), delivery_fee_zmw = fee,
         expires_at = now() + make_interval(days => public.setting_numeric('order.confirmed_expiry_days', 7)::integer)
   where id = o.id
   returning * into o;

  perform public.order_add_event(o.id, 'seller', 'confirmed',
    case when fee > 0 then 'Delivery fee K' || fee::text end);

  for other in
    select id from public.orders
     where listing_id = o.listing_id and status = 'requested' and id <> o.id
     for update
  loop
    perform public.order_end(other.id, 'declined', 'system', 'The item was reserved for another buyer.');
  end loop;

  return o;
end;
$$;

create function public.decline_order(p_order_id uuid, p_reason text default null)
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders;
begin
  o := public.order_lock(p_order_id);
  if not public.order_is_seller_side(o) then
    raise exception 'This is not your order.' using errcode = 'insufficient_privilege';
  end if;
  if o.status <> 'requested' then
    raise exception 'That change is not allowed for this order.' using errcode = 'check_violation';
  end if;
  return public.order_end(o.id, 'declined', 'seller', p_reason);
end;
$$;

-- Buyer: any time before hand-over. Seller: only after confirming, and before hand-over.
create function public.cancel_order(p_order_id uuid, p_reason text default null)
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  o public.orders;
begin
  o := public.order_lock(p_order_id);
  if o.buyer_id = uid then
    if o.status not in ('requested', 'confirmed') or o.handed_over_at is not null then
      raise exception 'That change is not allowed for this order.' using errcode = 'check_violation';
    end if;
    return public.order_end(o.id, 'cancelled', 'buyer', p_reason);
  elsif public.order_is_seller_side(o) then
    if o.status <> 'confirmed' or o.handed_over_at is not null then
      raise exception 'That change is not allowed for this order.' using errcode = 'check_violation';
    end if;
    return public.order_end(o.id, 'cancelled', 'seller', p_reason);
  end if;
  raise exception 'This is not your order.' using errcode = 'insufficient_privilege';
end;
$$;

-- Seller says the item has been handed over (collected, or delivered). This starts the
-- clock for automatic completion and stops the order from expiring. It does not complete
-- the order: the buyer does that, or it completes by itself after a few days.
create function public.mark_handed_over(p_order_id uuid)
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders;
begin
  o := public.order_lock(p_order_id);
  if not public.order_is_seller_side(o) then
    raise exception 'This is not your order.' using errcode = 'insufficient_privilege';
  end if;
  if o.status <> 'confirmed' or o.handed_over_at is not null then
    raise exception 'That change is not allowed for this order.' using errcode = 'check_violation';
  end if;
  update public.orders set handed_over_at = now(), expires_at = null where id = o.id returning * into o;
  perform public.order_add_event(o.id, 'seller', 'handed_over',
    case o.fulfilment when 'delivery' then 'Marked as delivered.' else 'Marked as collected.' end);
  return o;
end;
$$;

-- Buyer confirms they have the item.
create function public.complete_order(p_order_id uuid)
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders;
begin
  o := public.order_lock(p_order_id);
  if o.buyer_id <> (select auth.uid()) then
    raise exception 'This is not your order.' using errcode = 'insufficient_privilege';
  end if;
  if o.status <> 'confirmed' then
    raise exception 'That change is not allowed for this order.' using errcode = 'check_violation';
  end if;
  return public.order_finish(o.id, 'buyer');
end;
$$;

-- Same signature as before. Older app versions keep working.
create or replace function public.set_order_status(p_order_id uuid, p_status public.order_status, p_reason text default null)
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order not found.' using errcode = 'no_data_found';
  end if;

  if p_status = 'confirmed' then
    return public.confirm_order(p_order_id, 0);
  elsif p_status = 'completed' then
    return public.complete_order(p_order_id);
  elsif p_status = 'cancelled' then
    if o.status = 'requested' and public.order_is_seller_side(o) then
      return public.decline_order(p_order_id, p_reason);
    end if;
    return public.cancel_order(p_order_id, p_reason);
  end if;
  raise exception 'That change is not allowed for this order.' using errcode = 'check_violation';
end;
$$;

-- Opening a dispute is unchanged except that it is now written to the order history
-- and stops the order from expiring or completing by itself.
create or replace function public.open_dispute(p_order_id uuid, p_reason text, p_details text default null)
returns public.disputes
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  o public.orders;
  d public.disputes;
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found or not public.is_order_party(p_order_id) then
    raise exception 'Order not found.' using errcode = 'no_data_found';
  end if;
  if o.status not in ('confirmed', 'completed') then
    raise exception 'A dispute can only be opened on a confirmed or completed order.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.disputes where order_id = o.id and status in ('open', 'awaiting_info')) then
    raise exception 'There is already an open dispute for this order.' using errcode = 'unique_violation';
  end if;

  insert into public.disputes (order_id, opened_by, reason, details)
  values (o.id, uid, p_reason, p_details)
  returning * into d;

  update public.orders set status = 'disputed', expires_at = null where id = o.id;
  perform public.order_add_event(o.id, case when o.buyer_id = uid then 'buyer' else 'seller' end, 'disputed', left(p_reason, 100));
  return d;
end;
$$;

-- ---------------------------------------------------------------------------
-- Receipts
-- ---------------------------------------------------------------------------

-- A receipt is a record of the deal the two sides agreed. It is not proof of payment:
-- ZedMarket does not take, hold or confirm payments, and the receipt says so.
create function public.order_receipt(p_order_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  o public.orders;
begin
  select * into o from public.orders where id = p_order_id;
  if not found or not (public.is_order_party(p_order_id) or public.has_staff_role('support')) then
    raise exception 'Order not found.' using errcode = 'no_data_found';
  end if;
  if o.completed_at is null then
    raise exception 'A receipt is available once the order is completed.' using errcode = 'check_violation';
  end if;

  return jsonb_build_object(
    'receipt_number', o.ref,
    'order_status', o.status,
    'item', o.item_title,
    'item_price_zmw', o.item_price_zmw,
    'delivery_fee_zmw', o.delivery_fee_zmw,
    'total_zmw', o.total_zmw,
    'fulfilment', o.fulfilment,
    'buyer', o.buyer_name,
    'seller', o.seller_name,
    'requested_at', o.created_at,
    'confirmed_at', o.confirmed_at,
    'handed_over_at', o.handed_over_at,
    'completed_at', o.completed_at,
    'payment_note', 'ZedMarket did not take, hold or confirm any payment for this order. '
                    || 'This receipt records the item and price the buyer and seller agreed.');
end;
$$;

-- ---------------------------------------------------------------------------
-- Staff: settle a disputed order
-- ---------------------------------------------------------------------------

-- Resolving the dispute record does not by itself decide what happens to the order.
-- A support agent settles it as completed (the item changed hands) or cancelled (it did not).
create function public.staff_settle_order(p_order_id uuid, p_outcome text, p_note text)
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders;
begin
  if not public.has_staff_role('support') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if p_outcome not in ('completed', 'cancelled') then
    raise exception 'Choose completed or cancelled.' using errcode = 'check_violation';
  end if;
  o := public.order_lock(p_order_id);
  if o.status <> 'disputed' then
    raise exception 'Only a disputed order can be settled.' using errcode = 'check_violation';
  end if;

  if p_outcome = 'completed' then
    o := public.order_finish(o.id, 'staff');
  else
    o := public.order_end(o.id, 'cancelled', 'staff', p_note);
  end if;
  perform public.write_audit('order.settled', 'order', o.id::text, jsonb_build_object('outcome', p_outcome, 'note', p_note));
  return o;
end;
$$;

-- ---------------------------------------------------------------------------
-- When an item stops being for sale
-- ---------------------------------------------------------------------------

-- A seller cannot pause or mark sold an item that has a confirmed order: they must
-- complete or cancel the order first, so a buyer is never left with a reservation on nothing.
create function public.listings_order_guard()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.status = 'active' and new.status in ('sold', 'unavailable', 'draft')
     and exists (select 1 from public.orders where listing_id = new.id and status = 'confirmed') then
    raise exception 'This item has a confirmed order. Complete or cancel the order first.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger listings_order_guard before update of status on public.listings
  for each row execute function public.listings_order_guard();

-- Whatever is still open when an item goes away is closed with a reason.
create function public.listings_order_cascade()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  o record;
begin
  if old.status = 'active' and new.status <> 'active' then
    for o in
      select id, status from public.orders
       where listing_id = new.id and status in ('requested', 'confirmed')
       for update
    loop
      perform public.order_end(o.id,
        case when o.status = 'requested' then 'declined' else 'cancelled' end, 'system',
        case when new.status = 'removed' then 'This listing was removed.' else 'This item is no longer available.' end);
    end loop;
  end if;
  return new;
end;
$$;
create trigger listings_order_cascade after update of status on public.listings
  for each row execute function public.listings_order_cascade();

-- ---------------------------------------------------------------------------
-- Scheduled maintenance (run by trusted server code, not from the app)
-- ---------------------------------------------------------------------------

create function public.expire_overdue_orders()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  r record;
  o public.orders;
  total integer := 0;
begin
  for r in
    select id from public.orders
     where expires_at < now()
       and (status = 'requested' or (status = 'confirmed' and handed_over_at is null))
     order by expires_at
     limit 500
  loop
    o := public.order_lock(r.id);
    if o.expires_at < now()
       and (o.status = 'requested' or (o.status = 'confirmed' and o.handed_over_at is null)) then
      perform public.order_end(o.id, 'expired', 'system',
        case when o.status = 'requested' then 'The seller did not answer in time.'
             else 'The order was not completed in time.' end);
      total := total + 1;
    end if;
  end loop;
  return total;
end;
$$;

create function public.auto_complete_orders()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  r record;
  o public.orders;
  days integer := public.setting_numeric('order.auto_complete_days', 3)::integer;
  total integer := 0;
begin
  for r in
    select id from public.orders
     where status = 'confirmed' and handed_over_at < now() - make_interval(days => days)
     order by handed_over_at
     limit 500
  loop
    o := public.order_lock(r.id);
    if o.status = 'confirmed' and o.handed_over_at < now() - make_interval(days => days) then
      perform public.order_finish(o.id, 'system');
      total := total + 1;
    end if;
  end loop;
  return total;
end;
$$;

create function public.run_order_maintenance()
returns jsonb
language sql security definer set search_path = ''
as $$
  select jsonb_build_object(
    'expired', public.expire_overdue_orders(),
    'auto_completed', public.auto_complete_orders());
$$;

-- ---------------------------------------------------------------------------
-- Who can call what
-- ---------------------------------------------------------------------------

-- Start from nothing for every function in this file, then grant only what is meant.
revoke execute on function
  public.listing_is_reserved(uuid),
  public.order_lock(uuid),
  public.order_add_event(uuid, text, text, text),
  public.order_is_seller_side(public.orders),
  public.order_end(uuid, text, text, text),
  public.order_finish(uuid, text),
  public.create_order(uuid, public.fulfilment_method, text, text),
  public.confirm_order(uuid, numeric),
  public.decline_order(uuid, text),
  public.cancel_order(uuid, text),
  public.mark_handed_over(uuid),
  public.complete_order(uuid),
  public.set_order_status(uuid, public.order_status, text),
  public.open_dispute(uuid, text, text),
  public.order_receipt(uuid),
  public.staff_settle_order(uuid, text, text),
  public.listings_order_guard(),
  public.listings_order_cascade(),
  public.expire_overdue_orders(),
  public.auto_complete_orders(),
  public.run_order_maintenance()
  from public, anon, authenticated;

grant execute on function public.listing_is_reserved(uuid) to anon, authenticated;

grant execute on function
  public.create_order(uuid, public.fulfilment_method, text, text),
  public.confirm_order(uuid, numeric),
  public.decline_order(uuid, text),
  public.cancel_order(uuid, text),
  public.mark_handed_over(uuid),
  public.complete_order(uuid),
  public.set_order_status(uuid, public.order_status, text),
  public.open_dispute(uuid, text, text),
  public.order_receipt(uuid),
  public.staff_settle_order(uuid, text, text)
  to authenticated;

grant execute on function
  public.expire_overdue_orders(),
  public.auto_complete_orders(),
  public.run_order_maintenance()
  to service_role;
