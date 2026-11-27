-- Quantity-based reservations, branch inventory and partial fulfilment (chunk E).
--
-- Before: one confirmed order reserved a whole listing, even when a business held 50 units. Now:
--   * an order has a quantity; a listing with tracked stock can be reserved by several orders at once, as long as the
--     reserved quantities together never exceed the stock. A one-off item (no tracked stock) is still reserved by one order.
--   * stock is still taken off only when an order completes, as before. Reserved units are simply not offered twice.
--   * a business can hold stock per branch. The seller picks the branch when confirming; completion takes the units from
--     that branch. Direct changes to the total are refused while branch stock exists, so the two cannot drift apart.
--   * the seller can say fewer units were handed over than ordered (partial fulfilment). The total follows what was
--     handed over, and stock is reduced by that amount.
-- Known limits: analytics "items" sums the unit price once per order (not times quantity); payments stay disabled, and
-- when they are built they must charge the total after hand-over. Neither was changed here.

alter table public.orders add column quantity integer not null default 1 check (quantity between 1 and 1000);
alter table public.orders add column quantity_delivered integer check (quantity_delivered between 1 and 1000);
alter table public.orders add constraint orders_delivered_within_ordered check (quantity_delivered is null or quantity_delivered <= quantity);
-- The total is price x quantity (what was handed over, once known) + delivery. Existing orders have quantity 1: unchanged.
alter table public.orders drop column total_zmw;
alter table public.orders add column total_zmw numeric(12, 2)
  generated always as (item_price_zmw * coalesce(quantity_delivered, quantity) + delivery_fee_zmw) stored;

-- Reservations: one row per confirmed order. Only one-off items are exclusive (one reservation per listing).
alter table public.listing_reservations drop constraint listing_reservations_pkey;
alter table public.listing_reservations add primary key (order_id);
alter table public.listing_reservations add column quantity integer not null default 1 check (quantity >= 1);
alter table public.listing_reservations add column branch_id uuid references public.business_branches (id) on delete set null;
alter table public.listing_reservations add column exclusive boolean not null default true;
create unique index listing_reservations_one_exclusive on public.listing_reservations (listing_id) where exclusive;
create index listing_reservations_listing_idx on public.listing_reservations (listing_id);

-- Stock per branch. No grants: changed only through set_branch_stock, read through branch_stock.
create table public.listing_branch_stock (
  listing_id uuid not null references public.listings (id) on delete cascade,
  branch_id uuid not null references public.business_branches (id) on delete cascade,
  quantity integer not null check (quantity between 0 and 100000),
  updated_by uuid references public.profiles (id),
  updated_at timestamptz not null default now(),
  primary key (listing_id, branch_id)
);
alter table public.listing_branch_stock enable row level security;
revoke all on public.listing_branch_stock from public, anon, authenticated;

-- How many can still be ordered. Tracked stock: the stock minus what is reserved. One-off item: 1, or 0 once reserved.
create function public.listing_available_quantity(p_listing uuid)
returns integer
language plpgsql stable security definer set search_path = ''
as $$
declare
  s integer;
  reserved integer;
begin
  select quantity into s from public.listing_stock where listing_id = p_listing;
  select coalesce(sum(quantity), 0) into reserved from public.listing_reservations where listing_id = p_listing;
  if s is null then
    return case when reserved > 0 then 0 else 1 end;
  end if;
  return greatest(s - reserved, 0);
end;
$$;

-- Same meaning as before: "reserved" = there is a reservation and nothing is left to order.
create or replace function public.listing_is_reserved(p_listing_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.listing_reservations where listing_id = p_listing_id)
     and public.listing_available_quantity(p_listing_id) <= 0;
$$;

-- Same columns as before. Hidden while a reservation leaves nothing to order.
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
  and not public.listing_is_reserved(l.id);

-- Shown to buyers: how many can be ordered right now (null for a one-off item), capped so exact stock is not published.
create function public.listing_stock_info(p_listing uuid)
returns integer
language sql stable security definer set search_path = ''
as $$
  select case when exists (select 1 from public.listing_stock where listing_id = p_listing)
              then least(public.listing_available_quantity(p_listing), 20) end;
$$;

-- Called when an order completes: takes the handed-over quantity off the stock (and off the branch the order was filled from).
create or replace function public.stock_record_sale(p_listing uuid, p_order uuid)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  s public.listing_stock;
  o public.orders;
  sold integer;
  after_qty integer;
  has_branches boolean;
begin
  select * into s from public.listing_stock where listing_id = p_listing for update;
  if not found then
    return null;
  end if;
  select * into o from public.orders where id = p_order;
  sold := coalesce(o.quantity_delivered, o.quantity, 1);
  has_branches := exists (select 1 from public.listing_branch_stock where listing_id = p_listing);
  after_qty := greatest(s.quantity - sold, 0);

  perform set_config('zm.branch_sync', 'on', true);
  if has_branches then
    update public.listing_branch_stock set quantity = greatest(quantity - sold, 0), updated_at = now()
     where listing_id = p_listing and branch_id = o.branch_id;
    -- The total is whatever the branches now hold.
    select coalesce(sum(quantity), 0) into after_qty from public.listing_branch_stock where listing_id = p_listing;
  end if;
  update public.listing_stock set quantity = after_qty, updated_at = now() where listing_id = p_listing;
  perform set_config('zm.branch_sync', 'off', true);

  if after_qty <> s.quantity then
    insert into public.stock_movements (listing_id, business_id, change, quantity_after, reason, order_id, actor_id)
    values (p_listing, s.business_id, after_qty - s.quantity, after_qty, 'sale', p_order, (select auth.uid()));
  end if;
  return after_qty;
end;
$$;

-- While a listing keeps stock per branch, its total can only change through the branch functions.
create function public.listing_stock_branch_guard()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.quantity is distinct from old.quantity
     and coalesce(current_setting('zm.branch_sync', true), 'off') <> 'on'
     and exists (select 1 from public.listing_branch_stock where listing_id = new.listing_id) then
    raise exception 'This listing keeps its stock per branch. Change the stock for a branch instead.' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger listing_stock_branch_guard before update of quantity on public.listing_stock
  for each row execute function public.listing_stock_branch_guard();

create function public.set_branch_stock(p_listing uuid, p_branch uuid, p_quantity integer, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  l public.listings;
  s public.listing_stock;
  br public.business_branches;
  seed uuid;
  old_branch integer;
  reserved integer;
  new_total integer;
begin
  select * into l from public.listings where id = p_listing for update;
  if not found or l.business_id is null or not public.business_can(l.business_id, 'manage_inventory') then
    raise exception 'Listing not found.' using errcode = 'no_data_found';
  end if;
  select * into s from public.listing_stock where listing_id = p_listing for update;
  if not found then
    raise exception 'Track stock for this listing first.' using errcode = 'check_violation';
  end if;
  select * into br from public.business_branches where id = p_branch and business_id = l.business_id and active;
  if not found then
    raise exception 'Choose one of your active branches.' using errcode = 'check_violation';
  end if;
  if p_quantity is null or p_quantity < 0 or p_quantity > 100000 then
    raise exception 'Enter a quantity between 0 and 100000.' using errcode = 'check_violation';
  end if;
  if p_note is not null and char_length(p_note) > 150 then
    raise exception 'Keep the note under 150 characters.' using errcode = 'check_violation';
  end if;

  -- The first time, the stock the listing already has moves into its own branch so nothing is lost.
  if not exists (select 1 from public.listing_branch_stock where listing_id = p_listing) then
    seed := coalesce(l.branch_id, (select id from public.business_branches where business_id = l.business_id and is_main limit 1));
    if seed is null then
      raise exception 'Give this listing a branch first.' using errcode = 'check_violation';
    end if;
    insert into public.listing_branch_stock (listing_id, branch_id, quantity, updated_by) values (p_listing, seed, s.quantity, (select auth.uid()));
  end if;

  select coalesce(sum(quantity), 0) into reserved from public.listing_reservations where listing_id = p_listing and branch_id = p_branch;
  if p_quantity < reserved then
    raise exception 'This branch has % reserved for confirmed orders, so it cannot hold fewer than that.', reserved using errcode = 'check_violation';
  end if;

  select quantity into old_branch from public.listing_branch_stock where listing_id = p_listing and branch_id = p_branch;
  insert into public.listing_branch_stock (listing_id, branch_id, quantity, updated_by) values (p_listing, p_branch, p_quantity, (select auth.uid()))
  on conflict (listing_id, branch_id) do update set quantity = excluded.quantity, updated_by = excluded.updated_by, updated_at = now();

  select coalesce(sum(quantity), 0) into new_total from public.listing_branch_stock where listing_id = p_listing;
  perform set_config('zm.branch_sync', 'on', true);
  update public.listing_stock set quantity = new_total, updated_by = (select auth.uid()), updated_at = now() where listing_id = p_listing;
  perform set_config('zm.branch_sync', 'off', true);
  if new_total <> s.quantity then
    insert into public.stock_movements (listing_id, business_id, change, quantity_after, reason, note, actor_id)
    values (p_listing, l.business_id, new_total - s.quantity, new_total, 'correction',
            left('Branch ' || br.name || ': ' || coalesce(old_branch, 0) || ' to ' || p_quantity || coalesce('. ' || nullif(btrim(p_note), ''), ''), 200), (select auth.uid()));
  end if;
  perform public.stock_apply_effects(p_listing, new_total);
end;
$$;

create function public.branch_stock(p_listing uuid)
returns table (branch_id uuid, branch_name text, quantity integer, reserved integer, available integer)
language plpgsql stable security definer set search_path = ''
as $$
declare
  l public.listings;
begin
  select * into l from public.listings where id = p_listing;
  if not found or l.business_id is null or not public.is_business_member(l.business_id) then
    raise exception 'Listing not found.' using errcode = 'no_data_found';
  end if;
  return query
    select b.branch_id, br.name, b.quantity,
           coalesce((select sum(r.quantity)::integer from public.listing_reservations r where r.listing_id = p_listing and r.branch_id = b.branch_id), 0),
           greatest(b.quantity - coalesce((select sum(r.quantity)::integer from public.listing_reservations r where r.listing_id = p_listing and r.branch_id = b.branch_id), 0), 0)
      from public.listing_branch_stock b join public.business_branches br on br.id = b.branch_id
     where b.listing_id = p_listing order by br.name;
end;
$$;

-- ---------------------------------------------------------------------------
-- create_order: now takes a quantity
-- ---------------------------------------------------------------------------
drop function public.create_order(uuid, public.fulfilment_method, text, text, integer, uuid);

create function public.create_order(
  p_listing_id uuid,
  p_fulfilment public.fulfilment_method default 'collection',
  p_delivery_address text default null,
  p_note text default null,
  p_delivery_location_id integer default null,
  p_saved_address uuid default null,
  p_quantity integer default 1
)
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  l public.listings;
  o public.orders;
  stale uuid;
  saved public.saved_addresses;
  address text := nullif(btrim(p_delivery_address), '');
  place integer := p_delivery_location_id;
  note text := nullif(btrim(p_note), '');
  coverage text;
  qty integer := coalesce(p_quantity, 1);
  tracked boolean;
  avail integer;
begin
  if uid is null then
    raise exception 'Sign in to place an order.' using errcode = '28000';
  end if;
  if not public.account_can_post() then
    raise exception 'Your account cannot place orders right now.' using errcode = 'insufficient_privilege';
  end if;

  -- A saved address fills in the text and the place, and must be the buyer's own and usable for delivery.
  if p_fulfilment = 'delivery' and p_saved_address is not null then
    select * into saved from public.saved_addresses where id = p_saved_address and user_id = uid;
    if not found or saved.kind = 'pickup' then
      raise exception 'Choose one of your delivery addresses.' using errcode = 'check_violation';
    end if;
    address := public.format_address(saved.street, saved.landmark, saved.directions, saved.location_id);
    place := saved.location_id;
  end if;

  if p_fulfilment = 'delivery' and address is null then
    raise exception 'Enter a delivery address or a landmark the seller can find.' using errcode = 'check_violation';
  end if;
  if char_length(coalesce(address, '')) > 300 or char_length(coalesce(note, '')) > 300 then
    raise exception 'The address and note must each be 300 characters or fewer.' using errcode = 'check_violation';
  end if;
  if p_fulfilment = 'collection' then
    address := null;
    place := null;
  end if;

  if qty < 1 or qty > 1000 then
    raise exception 'Choose a quantity between 1 and 1000.' using errcode = 'check_violation';
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

  if p_fulfilment = 'delivery' then
    coverage := public.listing_coverage(l.id, place);
    if coverage = 'needs_area' then
      raise exception 'Choose your area from the list so we can check that this seller delivers there.' using errcode = 'check_violation';
    elsif coverage = 'outside' then
      raise exception 'This seller does not deliver to that area. Choose collection, or ask the seller.' using errcode = 'check_violation';
    end if;
  end if;

  -- Reservations nobody collected may be past their deadline: release them now instead of waiting for the scheduled job.
  for stale in
    select r.order_id
      from public.listing_reservations r
      join public.orders ro on ro.id = r.order_id
     where r.listing_id = l.id and ro.status = 'confirmed' and ro.handed_over_at is null and ro.expires_at < now()
  loop
    perform public.order_end(stale, 'expired', 'system', 'The order was not completed in time.');
  end loop;

  tracked := exists (select 1 from public.listing_stock where listing_id = l.id);
  if not tracked and qty <> 1 then
    raise exception 'This is a single item. Order 1.' using errcode = 'check_violation';
  end if;
  avail := public.listing_available_quantity(l.id);
  if avail <= 0 then
    raise exception 'This item is reserved for another buyer right now. Try again later.' using errcode = 'check_violation';
  end if;
  if qty > avail then
    raise exception 'Only % available right now. Order % or fewer.', avail, avail using errcode = 'check_violation';
  end if;
  if exists (
    select 1 from public.orders
     where listing_id = l.id and buyer_id = uid and status in ('requested', 'confirmed')
  ) then
    raise exception 'You already have an open order for this item.' using errcode = 'unique_violation';
  end if;

  insert into public.orders (
    listing_id, buyer_id, seller_id, business_id, item_title, item_price_zmw, fulfilment,
    delivery_address, delivery_location_id, buyer_note, buyer_name, seller_name, expires_at, quantity)
  values (
    l.id, uid, l.seller_id, l.business_id, l.title, l.price_zmw, p_fulfilment,
    address, place, note,
    (select display_name from public.profiles where id = uid),
    coalesce((select name from public.businesses where id = l.business_id),
             (select display_name from public.profiles where id = l.seller_id)),
    now() + make_interval(hours => public.setting_numeric('order.request_expiry_hours', 48)::integer), qty)
  returning * into o;

  perform public.order_add_event(o.id, 'buyer', 'requested', note);
  return o;
end;
$$;

-- confirm_order: reserves the quantity, optionally from one branch
drop function public.confirm_order(uuid, numeric);

create function public.confirm_order(p_order_id uuid, p_delivery_fee numeric default 0, p_branch uuid default null)
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders;
  l public.listings;
  other record;
  fee numeric := coalesce(p_delivery_fee, 0);
  tracked boolean;
  avail integer;
  has_branches boolean;
  branch_free integer;
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

  tracked := exists (select 1 from public.listing_stock where listing_id = o.listing_id);
  avail := public.listing_available_quantity(o.listing_id);
  if avail <= 0 then
    raise exception 'This item is already reserved for another order.' using errcode = 'check_violation';
  end if;
  if o.quantity > avail then
    raise exception 'Only % left, so an order for % cannot be confirmed. Decline it, or ask the buyer to order fewer.', avail, o.quantity
      using errcode = 'check_violation';
  end if;
  has_branches := exists (select 1 from public.listing_branch_stock where listing_id = o.listing_id);
  if has_branches then
    if p_branch is null then
      raise exception 'Choose the branch this order will be filled from.' using errcode = 'check_violation';
    end if;
    select b.quantity - coalesce((select sum(r.quantity) from public.listing_reservations r
                                   where r.listing_id = o.listing_id and r.branch_id = p_branch), 0)
      into branch_free from public.listing_branch_stock b where b.listing_id = o.listing_id and b.branch_id = p_branch;
    if not found then
      raise exception 'That branch does not hold this item.' using errcode = 'check_violation';
    end if;
    if o.quantity > branch_free then
      raise exception 'That branch has only % free. Choose another branch.', greatest(branch_free, 0) using errcode = 'check_violation';
    end if;
  elsif p_branch is not null then
    raise exception 'This listing does not keep stock per branch.' using errcode = 'check_violation';
  end if;

  insert into public.listing_reservations (listing_id, order_id, quantity, branch_id, exclusive)
  values (o.listing_id, o.id, o.quantity, case when has_branches then p_branch end, not tracked);

  update public.orders
     set status = 'confirmed', confirmed_at = now(), delivery_fee_zmw = fee, branch_id = case when has_branches then p_branch else branch_id end,
         expires_at = now() + make_interval(days => public.setting_numeric('order.confirmed_expiry_days', 7)::integer)
   where id = o.id
   returning * into o;

  perform public.order_add_event(o.id, 'seller', 'confirmed',
    case when fee > 0 then 'Delivery fee K' || fee::text end);

  -- One-off items turn away every other request. Counted stock only turns away requests that no longer fit.
  avail := public.listing_available_quantity(o.listing_id);
  for other in
    select id from public.orders
     where listing_id = o.listing_id and status = 'requested' and id <> o.id
       and (not tracked or quantity > avail)
     for update
  loop
    perform public.order_end(other.id, 'declined', 'system',
      case when tracked then 'Not enough stock was left for this request.' else 'The item was reserved for another buyer.' end);
  end loop;

  return o;
end;
$$;

-- mark_handed_over: the seller can say fewer were handed over (partial fulfilment)
drop function public.mark_handed_over(uuid);

create function public.mark_handed_over(p_order_id uuid, p_quantity integer default null)
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders;
  qty integer;
begin
  o := public.order_lock(p_order_id);
  if not public.order_is_seller_side(o) then
    raise exception 'This is not your order.' using errcode = 'insufficient_privilege';
  end if;
  if o.status <> 'confirmed' or o.handed_over_at is not null then
    raise exception 'That change is not allowed for this order.' using errcode = 'check_violation';
  end if;
  qty := coalesce(p_quantity, o.quantity);
  if qty < 1 or qty > o.quantity then
    raise exception 'Say how many were handed over: between 1 and %.', o.quantity using errcode = 'check_violation';
  end if;
  update public.orders set handed_over_at = now(), expires_at = null, quantity_delivered = qty where id = o.id returning * into o;
  perform public.order_add_event(o.id, 'seller', 'handed_over',
    (case o.fulfilment when 'delivery' then 'Marked as delivered.' else 'Marked as collected.' end)
      || case when qty < o.quantity then ' Handed over ' || qty || ' of ' || o.quantity || '.' else '' end);
  return o;
end;
$$;

-- The receipt now shows the quantity
create or replace function public.order_receipt(p_order_id uuid)
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
    'quantity_ordered', o.quantity,
    'quantity_handed_over', coalesce(o.quantity_delivered, o.quantity),
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
-- Who can call what
-- ---------------------------------------------------------------------------
revoke execute on function
  public.listing_available_quantity(uuid), public.listing_stock_info(uuid), public.stock_record_sale(uuid, uuid),
  public.listing_stock_branch_guard(), public.set_branch_stock(uuid, uuid, integer, text), public.branch_stock(uuid),
  public.create_order(uuid, public.fulfilment_method, text, text, integer, uuid, integer),
  public.confirm_order(uuid, numeric, uuid), public.mark_handed_over(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.listing_stock_info(uuid) to anon, authenticated;
grant execute on function
  public.set_branch_stock(uuid, uuid, integer, text), public.branch_stock(uuid),
  public.create_order(uuid, public.fulfilment_method, text, text, integer, uuid, integer),
  public.confirm_order(uuid, numeric, uuid), public.mark_handed_over(uuid, integer)
  to authenticated;
