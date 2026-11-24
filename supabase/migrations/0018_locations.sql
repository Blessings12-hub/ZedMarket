-- ZedMarket database, part 18: location management (Module K).
--
-- What this adds:
--   * district, latitude and longitude on locations (province > district > town > area)
--   * saved addresses (private to their owner) for delivery, pickup, or both, with landmark directions
--   * where a seller or business delivers (delivery areas) and a check that an order is inside them
--   * create_order can take a saved address or an area, and rejects delivery outside the seller's areas
--   * the seller can share a saved pickup address with the buyer of a confirmed collection order
--   * nearby listings ranked by area, town, district, province, and by distance when both places have coordinates
--
-- What it does not do: there is no map picker and no phone GPS here. Those need app packages and a map provider key.
-- Coordinates exist in the database and are checked, but nothing fills them yet except a person with the technical
-- admin role. No coordinates are invented: places without one simply rank by name.
--
-- Existing behaviour is kept: a seller with no delivery areas set delivers anywhere, as before.

-- ---------------------------------------------------------------------------
-- 1. Places
-- ---------------------------------------------------------------------------

alter table public.locations
  add column district text check (district is null or char_length(district) between 1 and 80),
  add column latitude double precision,
  add column longitude double precision,
  add constraint locations_coordinates_pair check ((latitude is null) = (longitude is null)),
  add constraint locations_coordinates_in_zambia check (
    latitude is null or (latitude between -18.2 and -8.1 and longitude between 21.9 and 33.8));

-- The only places in the launch list are in the city of Lusaka, which is the district of Lusaka.
update public.locations set district = 'Lusaka' where province = 'Lusaka' and town = 'Lusaka' and district is null;

create index locations_province_district_idx on public.locations (province, district, town);

-- Technical admins add and correct places through these so every change is checked and audited.
create function public.admin_add_location(
  p_province text, p_district text, p_town text, p_area text default null,
  p_latitude double precision default null, p_longitude double precision default null)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  new_id integer;
  provinces constant text[] := array['Central', 'Copperbelt', 'Eastern', 'Luapula', 'Lusaka', 'Muchinga', 'Northern', 'North-Western', 'Southern', 'Western'];
begin
  if not public.has_staff_role('tech_admin') then
    raise exception 'Only a technical admin can add places.' using errcode = 'insufficient_privilege';
  end if;
  if not (p_province = any (provinces)) then
    raise exception 'Choose one of the ten provinces.' using errcode = 'check_violation';
  end if;
  if nullif(btrim(p_district), '') is null or nullif(btrim(p_town), '') is null then
    raise exception 'A district and a town are needed.' using errcode = 'check_violation';
  end if;
  insert into public.locations (province, district, town, area, latitude, longitude)
  values (p_province, btrim(p_district), btrim(p_town), nullif(btrim(p_area), ''), p_latitude, p_longitude)
  returning id into new_id;
  perform public.write_audit('location.add', 'location', new_id::text,
    jsonb_build_object('province', p_province, 'district', p_district, 'town', p_town, 'area', p_area));
  return new_id;
end;
$$;

create function public.admin_set_location_coordinates(p_location integer, p_latitude double precision, p_longitude double precision)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('tech_admin') then
    raise exception 'Only a technical admin can change places.' using errcode = 'insufficient_privilege';
  end if;
  update public.locations set latitude = p_latitude, longitude = p_longitude where id = p_location;
  if not found then
    raise exception 'That place does not exist.' using errcode = 'no_data_found';
  end if;
  perform public.write_audit('location.coordinates', 'location', p_location::text,
    jsonb_build_object('latitude', p_latitude, 'longitude', p_longitude));
end;
$$;

-- "Chilenje, Lusaka" or "Lusaka" for a town-level row.
create function public.location_label(p_location integer)
returns text
language sql stable security definer set search_path = ''
as $$
  select coalesce(l.area || ', ', '') || l.town from public.locations l where l.id = p_location;
$$;

-- Straight-line distance in kilometres between two places, or null when either has no coordinates.
create function public.location_distance_km(p_from integer, p_to integer)
returns numeric
language sql stable security definer set search_path = ''
as $$
  select case when a.latitude is null or b.latitude is null then null
    else round((6371 * 2 * asin(least(1, sqrt(
      power(sin(radians(b.latitude - a.latitude) / 2), 2)
      + cos(radians(a.latitude)) * cos(radians(b.latitude)) * power(sin(radians(b.longitude - a.longitude) / 2), 2)
    ))))::numeric, 1) end
  from public.locations a, public.locations b
  where a.id = p_from and b.id = p_to;
$$;

-- ---------------------------------------------------------------------------
-- 2. Saved addresses (private)
-- ---------------------------------------------------------------------------

insert into public.platform_settings (key, value, note) values
  ('address.max_per_user', '10', 'Saved addresses one person can keep.'),
  ('delivery.max_areas', '30', 'Delivery areas one seller or business can list.')
on conflict (key) do nothing;

create table public.saved_addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  label text not null check (char_length(label) between 1 and 40),
  kind text not null default 'both' check (kind in ('delivery', 'pickup', 'both')),
  location_id integer not null references public.locations (id),
  street text check (street is null or char_length(street) between 1 and 150),
  landmark text check (landmark is null or char_length(landmark) between 1 and 150),
  directions text check (directions is null or char_length(directions) between 1 and 300),
  latitude double precision,
  longitude double precision,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint saved_addresses_has_detail check (street is not null or landmark is not null),
  constraint saved_addresses_coordinates_pair check ((latitude is null) = (longitude is null)),
  constraint saved_addresses_coordinates_in_zambia check (
    latitude is null or (latitude between -18.2 and -8.1 and longitude between 21.9 and 33.8))
);
create unique index saved_addresses_one_default on public.saved_addresses (user_id) where is_default;
create index saved_addresses_user_idx on public.saved_addresses (user_id, created_at desc);

alter table public.saved_addresses enable row level security;
-- Read-only for the owner. Nobody else, staff included, can read someone's addresses. All changes go through functions.
grant select on public.saved_addresses to authenticated;
create policy saved_addresses_own on public.saved_addresses for select to authenticated
  using (user_id = (select auth.uid()));

-- One readable line for an address: "Plot 5, near Shoprite, Kabulonga, Lusaka. Directions: ..."
create function public.format_address(p_street text, p_landmark text, p_directions text, p_location integer)
returns text
language sql stable security definer set search_path = ''
as $$
  select concat_ws(', ', nullif(btrim(p_street), ''), 'near ' || nullif(btrim(p_landmark), ''), public.location_label(p_location))
         || coalesce('. Directions: ' || nullif(btrim(p_directions), ''), '');
$$;

create function public.save_address(
  p_id uuid default null,
  p_label text default null,
  p_kind text default 'both',
  p_location_id integer default null,
  p_street text default null,
  p_landmark text default null,
  p_directions text default null,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_default boolean default false)
returns public.saved_addresses
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  a public.saved_addresses;
  v_street text := nullif(btrim(p_street), '');
  v_landmark text := nullif(btrim(p_landmark), '');
  v_directions text := nullif(btrim(p_directions), '');
  v_label text := nullif(btrim(p_label), '');
  have integer;
  make_default boolean := coalesce(p_default, false);
begin
  if uid is null then
    raise exception 'Sign in to save an address.' using errcode = '28000';
  end if;
  if v_label is null then
    raise exception 'Give the address a short name, like Home or Shop.' using errcode = 'check_violation';
  end if;
  if v_street is null and v_landmark is null then
    raise exception 'Enter a street or plot, or a landmark people can find.' using errcode = 'check_violation';
  end if;
  if p_kind not in ('delivery', 'pickup', 'both') then
    raise exception 'Choose delivery, pickup or both.' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.locations where id = p_location_id) then
    raise exception 'Choose where this address is.' using errcode = 'check_violation';
  end if;

  if p_id is null then
    select count(*) into have from public.saved_addresses where user_id = uid;
    if have >= public.setting_numeric('address.max_per_user', 10) then
      raise exception 'You can keep up to % saved addresses. Remove one first.', public.setting_numeric('address.max_per_user', 10)::integer
        using errcode = 'check_violation';
    end if;
    if have = 0 then make_default := true; end if;
    if make_default then
      update public.saved_addresses set is_default = false where user_id = uid and is_default;
    end if;
    insert into public.saved_addresses (user_id, label, kind, location_id, street, landmark, directions, latitude, longitude, is_default)
    values (uid, v_label, p_kind, p_location_id, v_street, v_landmark, v_directions, p_latitude, p_longitude, make_default)
    returning * into a;
  else
    perform 1 from public.saved_addresses where id = p_id and user_id = uid for update;
    if not found then
      raise exception 'That address was not found.' using errcode = 'no_data_found';
    end if;
    if make_default then
      update public.saved_addresses set is_default = false where user_id = uid and is_default and id <> p_id;
    end if;
    update public.saved_addresses
       set label = v_label, kind = p_kind, location_id = p_location_id, street = v_street,
           landmark = v_landmark, directions = v_directions,
           latitude = p_latitude, longitude = p_longitude,
           is_default = case when make_default then true else is_default end,
           updated_at = now()
     where id = p_id
     returning * into a;
  end if;
  return a;
end;
$$;

create function public.delete_address(p_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  was_default boolean;
begin
  if uid is null then
    raise exception 'Sign in to manage addresses.' using errcode = '28000';
  end if;
  delete from public.saved_addresses where id = p_id and user_id = uid returning is_default into was_default;
  if not found then
    raise exception 'That address was not found.' using errcode = 'no_data_found';
  end if;
  if was_default then
    update public.saved_addresses set is_default = true
     where id = (select id from public.saved_addresses where user_id = uid order by created_at desc limit 1);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Where a seller delivers
-- ---------------------------------------------------------------------------

-- Owned by one person (personal listings) or one business, never both. No rows at all means "no limit", as before.
create table public.delivery_areas (
  id bigint generated always as identity primary key,
  owner_user_id uuid references public.profiles (id) on delete cascade,
  business_id uuid references public.businesses (id) on delete cascade,
  location_id integer not null references public.locations (id),
  level text not null check (level in ('area', 'town', 'district', 'province')),
  created_at timestamptz not null default now(),
  constraint delivery_areas_one_owner check ((owner_user_id is null) <> (business_id is null)),
  constraint delivery_areas_unique unique nulls not distinct (owner_user_id, business_id, location_id, level)
);
create index delivery_areas_owner_idx on public.delivery_areas (owner_user_id);
create index delivery_areas_business_idx on public.delivery_areas (business_id);
alter table public.delivery_areas enable row level security;
-- No direct access. Read and change through the functions below.

-- Does one listing's seller deliver to this place?  'unrestricted' (no areas set), 'covered', 'outside',
-- or 'needs_area' (areas are set but no place was given).
create function public.listing_coverage(p_listing uuid, p_location integer)
returns text
language plpgsql stable security definer set search_path = ''
as $$
declare
  l public.listings;
  t public.locations;
  total integer;
begin
  select * into l from public.listings where id = p_listing;
  if not found then
    raise exception 'This listing is not available.' using errcode = 'no_data_found';
  end if;
  select count(*) into total from public.delivery_areas d
   where (l.business_id is not null and d.business_id = l.business_id)
      or (l.business_id is null and d.owner_user_id = l.seller_id);
  if total = 0 then
    return 'unrestricted';
  end if;
  if p_location is null then
    return 'needs_area';
  end if;
  select * into t from public.locations where id = p_location;
  if not found then
    return 'needs_area';
  end if;
  if exists (
    select 1
      from public.delivery_areas d
      join public.locations a on a.id = d.location_id
     where ((l.business_id is not null and d.business_id = l.business_id)
         or (l.business_id is null and d.owner_user_id = l.seller_id))
       and case d.level
             when 'area' then a.id = t.id
             when 'town' then a.province = t.province and a.town = t.town
             when 'district' then a.district is not null and a.province = t.province and a.district = t.district
             when 'province' then a.province = t.province
           end
  ) then
    return 'covered';
  end if;
  return 'outside';
end;
$$;

-- What a buyer is told on a listing: whether the seller limits delivery, and to where.
create function public.listing_delivery_info(p_listing uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  l public.listings;
  places jsonb;
begin
  select * into l from public.listings where id = p_listing and status = 'active' and moderation_status = 'approved';
  if not found then
    return null;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('level', d.level, 'label',
           case d.level when 'area' then coalesce(a.area || ', ', '') || a.town
                        when 'town' then a.town
                        when 'district' then a.district || ' district'
                        else a.province || ' Province' end) order by d.level, a.town, a.area), '[]'::jsonb)
    into places
    from public.delivery_areas d join public.locations a on a.id = d.location_id
   where (l.business_id is not null and d.business_id = l.business_id)
      or (l.business_id is null and d.owner_user_id = l.seller_id);
  return jsonb_build_object('restricted', jsonb_array_length(places) > 0, 'areas', places);
end;
$$;

create function public.delivery_check(p_listing uuid, p_location integer)
returns text
language sql stable security definer set search_path = ''
as $$
  select public.listing_coverage(p_listing, p_location);
$$;

-- A seller (or business owner or manager) replaces their list of delivery areas. p_areas looks like
-- [{"location_id": 3, "level": "town"}]. An empty list removes every limit.
create function public.set_delivery_areas(p_business uuid, p_areas jsonb)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  item jsonb;
  n integer;
  lim integer := public.setting_numeric('delivery.max_areas', 30)::integer;
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = '28000';
  end if;
  if p_business is not null and not public.business_can(p_business, 'manage_branches') then
    raise exception 'Only the owner or a manager can change where this business delivers.' using errcode = 'insufficient_privilege';
  end if;
  if p_business is null and not public.account_can_post() then
    raise exception 'Your account cannot change delivery areas right now.' using errcode = 'insufficient_privilege';
  end if;
  if p_areas is null or jsonb_typeof(p_areas) <> 'array' then
    raise exception 'Send a list of areas.' using errcode = 'invalid_parameter_value';
  end if;
  n := jsonb_array_length(p_areas);
  if n > lim then
    raise exception 'You can list up to % delivery areas.', lim using errcode = 'check_violation';
  end if;

  for item in select * from jsonb_array_elements(p_areas) loop
    if (item ->> 'level') not in ('area', 'town', 'district', 'province') then
      raise exception 'Each area needs a level: area, town, district or province.' using errcode = 'check_violation';
    end if;
    if not exists (select 1 from public.locations where id = (item ->> 'location_id')::integer) then
      raise exception 'One of the places does not exist.' using errcode = 'check_violation';
    end if;
    if (item ->> 'level') = 'district' and (select district from public.locations where id = (item ->> 'location_id')::integer) is null then
      raise exception 'That place has no district set, so a whole district cannot be chosen from it.' using errcode = 'check_violation';
    end if;
  end loop;

  delete from public.delivery_areas
   where (p_business is not null and business_id = p_business) or (p_business is null and owner_user_id = uid);
  insert into public.delivery_areas (owner_user_id, business_id, location_id, level)
  select case when p_business is null then uid end, p_business, (e ->> 'location_id')::integer, e ->> 'level'
    from jsonb_array_elements(p_areas) e
  on conflict do nothing;
  return n;
end;
$$;

create function public.my_delivery_areas(p_business uuid default null)
returns table (location_id integer, level text, label text)
language plpgsql stable security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = '28000';
  end if;
  if p_business is not null and not public.business_can(p_business, 'manage_orders') then
    raise exception 'This is not your business.' using errcode = 'insufficient_privilege';
  end if;
  return query
    select d.location_id, d.level,
           case d.level when 'area' then coalesce(a.area || ', ', '') || a.town
                        when 'town' then a.town
                        when 'district' then a.district || ' district'
                        else a.province || ' Province' end
      from public.delivery_areas d join public.locations a on a.id = d.location_id
     where (p_business is not null and d.business_id = p_business) or (p_business is null and d.owner_user_id = uid)
     order by d.level, a.town, a.area;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Orders: delivery checked against the seller's areas, pickup address shared
-- ---------------------------------------------------------------------------

alter table public.orders
  add column delivery_location_id integer references public.locations (id),
  add column pickup_text text check (pickup_text is null or char_length(pickup_text) <= 700);

drop function public.create_order(uuid, public.fulfilment_method, text, text);

create function public.create_order(
  p_listing_id uuid,
  p_fulfilment public.fulfilment_method default 'collection',
  p_delivery_address text default null,
  p_note text default null,
  p_delivery_location_id integer default null,
  p_saved_address uuid default null
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
    delivery_address, delivery_location_id, buyer_note, buyer_name, seller_name, expires_at)
  values (
    l.id, uid, l.seller_id, l.business_id, l.title, l.price_zmw, p_fulfilment,
    address, place, note,
    (select display_name from public.profiles where id = uid),
    coalesce((select name from public.businesses where id = l.business_id),
             (select display_name from public.profiles where id = l.seller_id)),
    now() + make_interval(hours => public.setting_numeric('order.request_expiry_hours', 48)::integer))
  returning * into o;

  perform public.order_add_event(o.id, 'buyer', 'requested', note);
  return o;
end;
$$;

-- The seller shares one of their saved pickup addresses with the buyer, once the order is confirmed.
create function public.share_pickup_address(p_order uuid, p_address uuid)
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders;
  a public.saved_addresses;
begin
  o := public.order_lock(p_order);
  if not public.order_is_seller_side(o) then
    raise exception 'This is not your order.' using errcode = 'insufficient_privilege';
  end if;
  if o.fulfilment <> 'collection' or o.status <> 'confirmed' then
    raise exception 'A pickup address can be shared on a confirmed collection order.' using errcode = 'check_violation';
  end if;
  select * into a from public.saved_addresses where id = p_address and user_id = (select auth.uid()) and kind in ('pickup', 'both');
  if not found then
    raise exception 'Choose one of your pickup addresses.' using errcode = 'check_violation';
  end if;
  update public.orders
     set pickup_text = public.format_address(a.street, a.landmark, a.directions, a.location_id)
   where id = o.id
   returning * into o;
  return o;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Nearby listings
-- ---------------------------------------------------------------------------

-- Closest first: same area, then same town, then same district, then same province. Within each step, nearer places
-- first when both have coordinates. p_scope limits how far out to look. p_max_km (optional) only keeps listings that
-- have coordinates and are within that straight-line distance.
create function public.nearby_listings_ranked(
  p_location_id integer,
  p_scope text default 'district',
  p_max_km numeric default null,
  p_limit integer default 20,
  p_offset integer default 0)
returns setof public.public_listings
language plpgsql stable set search_path = ''
as $$
declare
  max_tier integer;
begin
  max_tier := case p_scope when 'area' then 0 when 'town' then 1 when 'district' then 2 when 'province' then 3 else null end;
  if max_tier is null then
    raise exception 'Scope must be area, town, district or province.' using errcode = 'invalid_parameter_value';
  end if;
  return query
    select pl.*
      from public.public_listings pl
      join public.locations there on there.id = pl.location_id
      join public.locations here on here.id = p_location_id
     where here.province = there.province
       and case
             when pl.location_id = here.id then 0
             when there.town = here.town then 1
             when here.district is not null and there.district = here.district then 2
             else 3
           end <= max_tier
       and (p_max_km is null or public.location_distance_km(here.id, there.id) <= p_max_km)
     order by case
                when pl.location_id = here.id then 0
                when there.town = here.town then 1
                when here.district is not null and there.district = here.district then 2
                else 3
              end,
              public.location_distance_km(here.id, there.id) nulls last,
              pl.created_at desc, pl.id
     limit least(greatest(coalesce(p_limit, 20), 1), 50)
    offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Who can run what
-- ---------------------------------------------------------------------------

revoke execute on function
  public.admin_add_location(text, text, text, text, double precision, double precision),
  public.admin_set_location_coordinates(integer, double precision, double precision),
  public.location_label(integer),
  public.location_distance_km(integer, integer),
  public.format_address(text, text, text, integer),
  public.save_address(uuid, text, text, integer, text, text, text, double precision, double precision, boolean),
  public.delete_address(uuid),
  public.listing_coverage(uuid, integer),
  public.listing_delivery_info(uuid),
  public.delivery_check(uuid, integer),
  public.set_delivery_areas(uuid, jsonb),
  public.my_delivery_areas(uuid),
  public.create_order(uuid, public.fulfilment_method, text, text, integer, uuid),
  public.share_pickup_address(uuid, uuid),
  public.nearby_listings_ranked(integer, text, numeric, integer, integer)
  from public, anon, authenticated;

grant execute on function
  public.admin_add_location(text, text, text, text, double precision, double precision),
  public.admin_set_location_coordinates(integer, double precision, double precision),
  public.save_address(uuid, text, text, integer, text, text, text, double precision, double precision, boolean),
  public.delete_address(uuid),
  public.delivery_check(uuid, integer),
  public.set_delivery_areas(uuid, jsonb),
  public.my_delivery_areas(uuid),
  public.create_order(uuid, public.fulfilment_method, text, text, integer, uuid),
  public.share_pickup_address(uuid, uuid)
  to authenticated;

-- Guests can browse, so they may see where a seller delivers and what is nearby.
grant execute on function
  public.listing_delivery_info(uuid),
  public.location_label(integer),
  public.location_distance_km(integer, integer),
  public.nearby_listings_ranked(integer, text, numeric, integer, integer)
  to anon, authenticated;
