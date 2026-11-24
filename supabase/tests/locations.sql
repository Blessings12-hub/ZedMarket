-- Location management (migration 0018): places, saved addresses (private), delivery areas and the coverage check in
-- create_order, sharing a pickup address, and nearby listings ranked by distance tier. Coordinates in this file are
-- test values only.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/locations.sql

begin;

create schema zm_test;
grant usage on schema zm_test to anon, authenticated, service_role;

create function zm_test.act_as(p_user uuid, p_aal text default 'aal1') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  execute 'set local role authenticated';
end $$;

create function zm_test.act_as_guest() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
end $$;

create function zm_test.act_as_admin() returns void
language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

create function zm_test.act_as_service() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  execute 'set local role service_role';
end $$;

create function zm_test.expect_error(p_sql text, p_what text) returns void
language plpgsql as $$
begin
  execute p_sql;
  raise exception 'Expected an error but the statement worked: %', p_what;
exception
  when others then
    if sqlerrm like 'Expected an error but%' then
      raise;
    end if;
end $$;

create function zm_test.expect_equal(p_actual text, p_expected text, p_what text) returns void
language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'Wrong result for %: expected %, got %', p_what, coalesce(p_expected, 'null'), coalesce(p_actual, 'null');
  end if;
end $$;



insert into auth.users (id, email, phone, raw_user_meta_data, email_confirmed_at, phone_confirmed_at) values
  ('00000000-0000-0000-0000-00000000000a', 'seller@example.test', '+260971000001', '{"display_name":"Seller Sam"}', now(), now()),
  ('00000000-0000-0000-0000-00000000000b', 'buyer@example.test',  null,            '{"display_name":"Buyer Bwalya"}', now(), null),
  ('00000000-0000-0000-0000-00000000000c', 'third@example.test',  null,            '{"display_name":"Third Thandi"}', now(), null),
  ('00000000-0000-0000-0000-00000000000e', 'support@example.test', null,           '{"display_name":"Support Sue"}', now(), null),
  ('00000000-0000-0000-0000-000000000001', 'mod@example.test',    null,            '{"display_name":"Moderator Mo"}', now(), null),
  ('00000000-0000-0000-0000-00000000000d', 'manager@example.test', null,           '{"display_name":"Manager Mwila"}', now(), null),
  ('00000000-0000-0000-0000-00000000000f', 'staff@example.test',   null,           '{"display_name":"Staff Sipho"}', now(), null),
  ('00000000-0000-0000-0000-0000000000f1', 'fin1@example.test',    null,           '{"display_name":"Finance One"}', now(), null),
  ('00000000-0000-0000-0000-0000000000f2', 'fin2@example.test',    null,           '{"display_name":"Finance Two"}', now(), null);
insert into public.admin_roles (user_id, role) values
  ('00000000-0000-0000-0000-00000000000e', 'support'),
  ('00000000-0000-0000-0000-000000000001', 'moderator'),
  ('00000000-0000-0000-0000-0000000000f1', 'finance'),
  ('00000000-0000-0000-0000-0000000000f2', 'finance'),
  ('00000000-0000-0000-0000-0000000000f1', 'support'),
  ('00000000-0000-0000-0000-0000000000f2', 'tech_admin');
insert into public.businesses (id, owner_id, name, slug) values
  ('20000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000a', 'Sam Shop', 'sam-shop');
insert into public.business_members (business_id, user_id, role) values
  ('20000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000d', 'manager'),
  ('20000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000f', 'staff');

-- Listings are written directly (the posting flow is covered by trust_flows.sql).
create function zm_test.fresh_listing(p_price numeric default 500, p_business uuid default null) returns uuid
language plpgsql as $$
declare
  new_id uuid;
begin
  insert into public.listings (seller_id, business_id, category_id, location_id, title, description, price_zmw, condition, status, moderation_status)
  select '00000000-0000-0000-0000-00000000000a', p_business, c.id, l.id,
         'Item ' || substr(gen_random_uuid()::text, 1, 8), 'Test item', p_price, 'used_good', 'draft', 'pending'
    from public.categories c, public.locations l
   where c.slug = 'electronics' and l.area = 'Kabulonga'
  returning id into new_id;
  insert into public.listing_images (listing_id, storage_path, position) values (new_id, 'x/' || new_id || '.jpg', 0);
  update public.listings set status = 'active' where id = new_id;
  update public.listings set moderation_status = 'approved' where id = new_id;
  return new_id;
end $$;



create function zm_test.count_for(p_user uuid, p_type text default null) returns text language sql as $$
  select count(*)::text from public.notifications where user_id = p_user and (p_type is null or type = p_type);
$$;
create function zm_test.did() returns bigint language sql security definer as $$
  select id from public.notification_deliveries order by id desc limit 1;
$$;
create temp table zm_ids (name text primary key, id uuid);
grant all on zm_ids to anon, authenticated, service_role;
grant execute on all functions in schema zm_test to anon, authenticated, service_role;

\set S '00000000-0000-0000-0000-00000000000a'
\set B '00000000-0000-0000-0000-00000000000b'
\set C '00000000-0000-0000-0000-00000000000c'
\set SUP '00000000-0000-0000-0000-00000000000e'
\set MOD '00000000-0000-0000-0000-000000000001'
\set MGR '00000000-0000-0000-0000-00000000000d'
\set F1 '00000000-0000-0000-0000-0000000000f1'
\set F2 '00000000-0000-0000-0000-0000000000f2'
\set BIZ '20000000-0000-0000-0000-00000000000a'


-- Places used below (test coordinates are rough numbers, not survey data)
select zm_test.act_as_admin();
create temp table zm_loc (name text primary key, id integer);
grant all on zm_loc to anon, authenticated, service_role;
insert into zm_loc select l.area, l.id from public.locations l where l.town = 'Lusaka' and l.area in ('Kabulonga', 'Chilenje', 'Roma', 'Matero');
insert into zm_loc select 'Lusaka town', l.id from public.locations l where l.town = 'Lusaka' and l.area is null;

-- 1. Staff add and correct places
select zm_test.act_as(:'F2', 'aal2');
insert into zm_loc select 'Ndola', public.admin_add_location('Copperbelt', 'Ndola', 'Ndola');
insert into zm_loc select 'Kitwe', public.admin_add_location('Copperbelt', 'Kitwe', 'Kitwe', 'Parklands');
select public.admin_set_location_coordinates((select id from zm_loc where name = 'Kabulonga'), -15.40, 28.33);
select public.admin_set_location_coordinates((select id from zm_loc where name = 'Chilenje'), -15.45, 28.30);
select zm_test.expect_error($$select public.admin_add_location('Atlantis', 'X', 'Y')$$, 'unknown province');
select zm_test.expect_error($$select public.admin_add_location('Lusaka', '', 'Y')$$, 'district needed');
select zm_test.expect_error($$select public.admin_add_location('Lusaka', 'Lusaka', ' ')$$, 'town needed');
select zm_test.expect_error($$select public.admin_add_location('Lusaka', 'Lusaka', 'Rome', null, 51.0, 12.0)$$, 'coordinates outside Zambia');
select zm_test.expect_error($$select public.admin_add_location('Lusaka', 'Lusaka', 'Half', null, -15.0, null)$$, 'one coordinate only');
select zm_test.expect_error($$select public.admin_set_location_coordinates(999999, -15.0, 28.0)$$, 'place that does not exist');
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action in ('location.add', 'location.coordinates')), '4', 'every change is audited');
select zm_test.act_as(:'F2', 'aal1');
select zm_test.expect_error($$select public.admin_add_location('Lusaka', 'Lusaka', 'Nope')$$, 'two-factor needed');
select zm_test.act_as(:'MOD', 'aal2');
select zm_test.expect_error($$select public.admin_add_location('Lusaka', 'Lusaka', 'Nope')$$, 'moderators cannot add places');
select zm_test.expect_error($$select public.admin_set_location_coordinates(1, -15.0, 28.0)$$, 'moderators cannot move places');
select zm_test.act_as(:'B');
select zm_test.expect_error($$select public.admin_add_location('Lusaka', 'Lusaka', 'Nope')$$, 'ordinary users cannot add places');
select zm_test.act_as_guest();
select zm_test.expect_error($$select public.admin_add_location('Lusaka', 'Lusaka', 'Nope')$$, 'guests cannot add places');

-- 2. Labels and distance
select zm_test.act_as(:'B');
select zm_test.expect_equal(public.location_label((select id from zm_loc where name = 'Kabulonga')), 'Kabulonga, Lusaka', 'area label');
select zm_test.expect_equal(public.location_label((select id from zm_loc where name = 'Ndola')), 'Ndola', 'town label');
select zm_test.expect_equal((select (public.location_distance_km((select id from zm_loc where name = 'Kabulonga'), (select id from zm_loc where name = 'Chilenje')) between 5 and 8)::text), 'true', 'a few kilometres apart');
select zm_test.expect_equal(public.location_distance_km((select id from zm_loc where name = 'Kabulonga'), (select id from zm_loc where name = 'Kabulonga'))::text, '0.0', 'same place');
select zm_test.expect_equal((public.location_distance_km((select id from zm_loc where name = 'Kabulonga'), (select id from zm_loc where name = 'Roma')) is null)::text, 'true', 'no coordinates, no distance');
select zm_test.expect_equal((public.location_distance_km((select id from zm_loc where name = 'Kabulonga'), (select id from zm_loc where name = 'Chilenje')) = public.location_distance_km((select id from zm_loc where name = 'Chilenje'), (select id from zm_loc where name = 'Kabulonga')))::text, 'true', 'same both ways');
select zm_test.expect_equal((select district from public.locations where id = (select id from zm_loc where name = 'Roma')), 'Lusaka', 'existing places got their district');

-- 3. Saved addresses
select zm_test.act_as(:'B');
create temp table zm_addr (name text primary key, id uuid);
grant all on zm_addr to anon, authenticated, service_role;
insert into zm_addr select 'home', (public.save_address(null, 'Home', 'both', (select id from zm_loc where name = 'Chilenje'), 'Plot 5', 'Shoprite', 'Turn left at the school')).id;
select zm_test.expect_equal((select is_default::text from public.saved_addresses where id = (select id from zm_addr where name = 'home')), 'true', 'the first address becomes the default');
insert into zm_addr select 'shop', (public.save_address(null, 'Shop', 'delivery', (select id from zm_loc where name = 'Roma'), null, 'Market gate', null, null, null, true)).id;
select zm_test.expect_equal((select string_agg(label, ',' order by label) from public.saved_addresses where is_default), 'Shop', 'only one default at a time');
insert into zm_addr select 'collect', (public.save_address(null, 'Collect', 'pickup', (select id from zm_loc where name = 'Kabulonga'), 'Gate 2', null, null)).id;
select zm_test.expect_equal((select count(*)::text from public.saved_addresses), '3', 'three saved');
select zm_test.expect_error($$select public.save_address(null, 'X', 'both', (select id from zm_loc where name = 'Roma'), null, null, null)$$, 'needs a street or landmark');
select zm_test.expect_error($$select public.save_address(null, '  ', 'both', (select id from zm_loc where name = 'Roma'), 'Plot', null, null)$$, 'needs a name');
select zm_test.expect_error($$select public.save_address(null, 'X', 'sometimes', (select id from zm_loc where name = 'Roma'), 'Plot', null, null)$$, 'bad kind');
select zm_test.expect_error($$select public.save_address(null, 'X', 'both', 999999, 'Plot', null, null)$$, 'unknown place');
select zm_test.expect_error($$select public.save_address(null, 'X', 'both', 1, 'Plot', null, null, 40.0, 5.0)$$, 'coordinates outside Zambia');
select zm_test.expect_error($$select public.save_address(null, 'X', 'both', 1, 'Plot', null, null, -15.0, null)$$, 'one coordinate only');
select zm_test.expect_error($$select public.save_address(null, repeat('a', 41), 'both', 1, 'Plot', null, null)$$, 'name too long');
select zm_test.expect_error($$select public.save_address(null, 'X', 'both', 1, repeat('a', 151), null, null)$$, 'street too long');
select zm_test.expect_error($$select public.save_address(null, 'X', 'both', 1, 'Plot', null, repeat('a', 301))$$, 'directions too long');
-- update your own
select public.save_address((select id from zm_addr where name = 'home'), 'Home (new)', 'both', (select id from zm_loc where name = 'Chilenje'), 'Plot 6', 'Shoprite', 'Gate is blue', -15.45, 28.30, true);
select zm_test.expect_equal((select label || '/' || is_default::text from public.saved_addresses where id = (select id from zm_addr where name = 'home')), 'Home (new)/true', 'update and make default');
select zm_test.expect_equal((select count(*)::text from public.saved_addresses where is_default), '1', 'still only one default');
-- privacy
select zm_test.act_as(:'C');
select zm_test.expect_equal((select count(*)::text from public.saved_addresses), '0', 'another user sees none');
select zm_test.expect_error(format($$select public.save_address(%L, 'Mine now', 'both', 1, 'Plot', null, null)$$, (select id from zm_addr where name = 'home')), 'cannot edit someone else''s address');
select zm_test.expect_error(format($$select public.delete_address(%L)$$, (select id from zm_addr where name = 'home')), 'cannot delete someone else''s address');
select zm_test.act_as(:'SUP', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.saved_addresses), '0', 'support cannot read addresses');
select zm_test.act_as(:'F2', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.saved_addresses), '0', 'a technical admin cannot read addresses either');
select zm_test.act_as(:'B');
select zm_test.expect_error($$insert into public.saved_addresses (user_id, label, location_id, street) values ('00000000-0000-0000-0000-00000000000b', 'x', 1, 'y')$$, 'no direct inserts');
select zm_test.expect_error($$update public.saved_addresses set label = 'x'$$, 'no direct updates');
select zm_test.expect_error($$delete from public.saved_addresses$$, 'no direct deletes');
select zm_test.act_as_guest();
select zm_test.expect_error($$select count(*) from public.saved_addresses$$, 'guests cannot read');
select zm_test.expect_error($$select public.save_address(null, 'X', 'both', 1, 'Plot', null, null)$$, 'guests cannot save');
-- limit
select zm_test.act_as_admin();
update public.platform_settings set value = '3' where key = 'address.max_per_user';
select zm_test.act_as(:'B');
select zm_test.expect_error($$select public.save_address(null, 'Fourth', 'both', 1, 'Plot', null, null)$$, 'address limit');
select zm_test.act_as_admin();
update public.platform_settings set value = '10' where key = 'address.max_per_user';
-- deleting the default hands the role on
select zm_test.act_as(:'B');
select public.delete_address((select id from zm_addr where name = 'home'));
select zm_test.expect_equal((select count(*)::text from public.saved_addresses where is_default), '1', 'a new default is chosen after deleting the default');
select zm_test.expect_error(format($$select public.delete_address(%L)$$, (select id from zm_addr where name = 'home')), 'already gone');
-- text for orders (private helper, so run as the owner of the database)
select zm_test.act_as_admin();
select zm_test.expect_equal(public.format_address('Plot 5', 'Shoprite', 'Turn left', (select id from zm_loc where name = 'Kabulonga')), 'Plot 5, near Shoprite, Kabulonga, Lusaka. Directions: Turn left', 'full address text');
select zm_test.expect_equal(public.format_address(null, 'Shoprite', null, (select id from zm_loc where name = 'Kabulonga')), 'near Shoprite, Kabulonga, Lusaka', 'landmark only');

-- 4. Delivery areas
select zm_test.act_as_admin();
insert into zm_ids values ('l1', zm_test.fresh_listing(100));
insert into zm_ids values ('l2', zm_test.fresh_listing(100));
insert into zm_ids values ('l3', zm_test.fresh_listing(100));
insert into zm_ids values ('l4', zm_test.fresh_listing(100));
insert into zm_ids values ('lb', zm_test.fresh_listing(300, :'BIZ'));
select zm_test.act_as(:'B');
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'l1'), (select id from zm_loc where name = 'Roma')), 'unrestricted', 'no areas set means no limit');
select zm_test.expect_equal(public.listing_delivery_info((select id from zm_ids where name = 'l1')) ->> 'restricted', 'false', 'info: unrestricted');
select zm_test.act_as(:'S');
select zm_test.expect_equal(public.set_delivery_areas(null, jsonb_build_array(jsonb_build_object('location_id', (select id from zm_loc where name = 'Chilenje'), 'level', 'area')))::text, '1', 'one area saved');
select zm_test.act_as(:'B');
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'l1'), (select id from zm_loc where name = 'Chilenje')), 'covered', 'the named area');
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'l1'), (select id from zm_loc where name = 'Roma')), 'outside', 'another area of the same town');
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'l1'), (select id from zm_loc where name = 'Ndola')), 'outside', 'another province');
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'l1'), null), 'needs_area', 'a place is required when limited');
select zm_test.expect_equal(public.listing_delivery_info((select id from zm_ids where name = 'l1')) #>> '{areas,0,label}', 'Chilenje, Lusaka', 'info shows the area');
select zm_test.act_as_guest();
select zm_test.expect_equal(public.listing_delivery_info((select id from zm_ids where name = 'l1')) ->> 'restricted', 'true', 'guests can see where a seller delivers');
select zm_test.expect_error($$select public.delivery_check(gen_random_uuid(), 1)$$, 'guests cannot run the check');
-- levels
select zm_test.act_as_admin();
insert into public.locations (province, district, town, area) values ('Central', 'Kabwe', 'Ndola', null);
insert into zm_loc select 'Ndola (Central)', id from public.locations where province = 'Central' and town = 'Ndola';
select zm_test.act_as(:'S');
select public.set_delivery_areas(null, jsonb_build_array(jsonb_build_object('location_id', (select id from zm_loc where name = 'Chilenje'), 'level', 'town')));
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'l1'), (select id from zm_loc where name = 'Roma')), 'covered', 'whole town');
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'l1'), (select id from zm_loc where name = 'Ndola')), 'outside', 'town level does not leave the town');
select public.set_delivery_areas(null, jsonb_build_array(jsonb_build_object('location_id', (select id from zm_loc where name = 'Ndola'), 'level', 'town')));
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'l1'), (select id from zm_loc where name = 'Ndola (Central)')), 'outside', 'a town with the same name in another province is not covered');
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'l1'), (select id from zm_loc where name = 'Ndola')), 'covered', 'the town itself is covered');
select public.set_delivery_areas(null, jsonb_build_array(jsonb_build_object('location_id', (select id from zm_loc where name = 'Ndola'), 'level', 'district')));
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'l1'), (select id from zm_loc where name = 'Kitwe')), 'outside', 'another district in the same province is not covered');
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'l1'), (select id from zm_loc where name = 'Ndola')), 'covered', 'the district itself is covered');
select public.set_delivery_areas(null, jsonb_build_array(jsonb_build_object('location_id', (select id from zm_loc where name = 'Chilenje'), 'level', 'town')));
select public.set_delivery_areas(null, jsonb_build_array(jsonb_build_object('location_id', (select id from zm_loc where name = 'Chilenje'), 'level', 'district')));
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'l1'), (select id from zm_loc where name = 'Matero')), 'covered', 'whole district');
select public.set_delivery_areas(null, jsonb_build_array(jsonb_build_object('location_id', (select id from zm_loc where name = 'Chilenje'), 'level', 'province')));
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'l1'), (select id from zm_loc where name = 'Matero')), 'covered', 'whole province');
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'l1'), (select id from zm_loc where name = 'Ndola')), 'outside', 'province level does not leave the province');
select public.set_delivery_areas(null, jsonb_build_array(
  jsonb_build_object('location_id', (select id from zm_loc where name = 'Chilenje'), 'level', 'area'),
  jsonb_build_object('location_id', (select id from zm_loc where name = 'Ndola'), 'level', 'town')));
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'l1'), (select id from zm_loc where name = 'Ndola')), 'covered', 'several areas together');
select zm_test.expect_equal((select count(*)::text from public.my_delivery_areas(null)), '2', 'my areas listed');
-- validation
select zm_test.expect_error($$select public.set_delivery_areas(null, '[{"location_id": 1, "level": "street"}]')$$, 'bad level');
select zm_test.expect_error($$select public.set_delivery_areas(null, '[{"location_id": 999999, "level": "area"}]')$$, 'unknown place');
select zm_test.expect_error($$select public.set_delivery_areas(null, '{"a": 1}')$$, 'not a list');
select zm_test.expect_error($$select public.set_delivery_areas(null, null)$$, 'no list');
select zm_test.act_as_admin();
update public.platform_settings set value = '2' where key = 'delivery.max_areas';
select zm_test.act_as(:'S');
select zm_test.expect_error(format($$select public.set_delivery_areas(null, '[{"location_id": 1, "level": "area"},{"location_id": 2, "level": "area"},{"location_id": 3, "level": "area"}]')$$), 'too many areas');
select zm_test.act_as_admin();
update public.platform_settings set value = '30' where key = 'delivery.max_areas';
select zm_test.expect_equal((select count(*)::text from public.delivery_areas where owner_user_id = :'S'), '2', 'a failed change leaves the old list');
-- the district level needs a district
select zm_test.act_as_admin();
insert into public.locations (province, town, area) values ('Southern', 'Choma', null);
select zm_test.act_as(:'S');
select zm_test.expect_error($$select public.set_delivery_areas(null, jsonb_build_array(jsonb_build_object('location_id', (select id from public.locations where town = 'Choma'), 'level', 'district')))$$, 'district level on a place with no district');
-- others cannot touch it
select zm_test.act_as(:'C');
select zm_test.expect_equal((select count(*)::text from public.my_delivery_areas(null)), '0', 'another person has their own empty list');
select zm_test.expect_error($$select * from public.delivery_areas$$, 'no direct reads');
select zm_test.act_as_admin();
update public.profiles set account_state = 'suspended' where id = :'S';
select zm_test.act_as(:'S');
select zm_test.expect_error($$select public.set_delivery_areas(null, '[]')$$, 'a suspended account cannot change areas');
select zm_test.act_as_admin();
update public.profiles set account_state = 'active' where id = :'S';
-- business
select zm_test.act_as(:'B');
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'lb'), (select id from zm_loc where name = 'Roma')), 'unrestricted', 'a business with no areas set is unlimited even if its owner limits personal listings');
select zm_test.act_as(:'MGR');
select zm_test.expect_equal(public.set_delivery_areas(:'BIZ', jsonb_build_array(jsonb_build_object('location_id', (select id from zm_loc where name = 'Roma'), 'level', 'area')))::text, '1', 'a manager sets business areas');
select zm_test.expect_equal((select count(*)::text from public.my_delivery_areas(:'BIZ')), '1', 'a manager reads them');
select zm_test.act_as('00000000-0000-0000-0000-00000000000f');
select zm_test.expect_error(format($$select public.set_delivery_areas(%L, '[]')$$, :'BIZ'), 'plain staff cannot change business areas');
select zm_test.expect_equal((select count(*)::text from public.my_delivery_areas(:'BIZ')), '1', 'staff can read them (they handle orders)');
select zm_test.act_as(:'C');
select zm_test.expect_error(format($$select public.set_delivery_areas(%L, '[]')$$, :'BIZ'), 'outsiders cannot change business areas');
select zm_test.expect_error(format($$select * from public.my_delivery_areas(%L)$$, :'BIZ'), 'outsiders cannot read business areas');
select zm_test.act_as(:'B');
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'lb'), (select id from zm_loc where name = 'Roma')), 'covered', 'the business listing follows the business areas');
select zm_test.expect_equal(public.delivery_check((select id from zm_ids where name = 'lb'), (select id from zm_loc where name = 'Chilenje')), 'outside', 'and not the owner''s personal areas');

-- 5. Ordering with delivery
select zm_test.act_as(:'S');
select public.set_delivery_areas(null, jsonb_build_array(jsonb_build_object('location_id', (select id from zm_loc where name = 'Chilenje'), 'level', 'area')));
select zm_test.act_as(:'B');
select zm_test.expect_error(format($$select public.create_order(%L, 'delivery', 'Plot 1', null, %L)$$, (select id from zm_ids where name = 'l1'), (select id from zm_loc where name = 'Roma')), 'outside the seller''s area');
select zm_test.expect_error(format($$select public.create_order(%L, 'delivery', 'Plot 1')$$, (select id from zm_ids where name = 'l1')), 'a place is needed when the seller limits delivery');
select zm_test.expect_equal((select count(*)::text from public.orders where buyer_id = :'B'), '0', 'refused orders leave nothing behind');
select zm_test.expect_equal((public.create_order((select id from zm_ids where name = 'l1'), 'delivery', 'Plot 1', null, (select id from zm_loc where name = 'Chilenje'))).delivery_location_id::text, (select id::text from zm_loc where name = 'Chilenje'), 'inside the area is accepted and recorded');
-- a collection order ignores the delivery areas
select zm_test.expect_equal((public.create_order((select id from zm_ids where name = 'l2'), 'collection')).status::text, 'requested', 'collection is never limited');
-- saved address: own, delivery-capable, text built by the server
select zm_test.expect_error(format($$select public.create_order(%L, 'delivery', null, null, null, %L)$$, (select id from zm_ids where name = 'l3'), (select id from zm_addr where name = 'shop')), 'saved address outside the area');
select zm_test.expect_error(format($$select public.create_order(%L, 'delivery', null, null, null, %L)$$, (select id from zm_ids where name = 'l3'), (select id from zm_addr where name = 'collect')), 'a pickup-only address cannot be used for delivery');
insert into zm_addr select 'cpick', (public.save_address(null, 'Pickup in Chilenje', 'pickup', (select id from zm_loc where name = 'Chilenje'), 'Gate 9', null, null)).id;
select zm_test.expect_error(format($$select public.create_order(%L, 'delivery', null, null, null, %L)$$, (select id from zm_ids where name = 'l3'), (select id from zm_addr where name = 'cpick')), 'a pickup-only address inside the area still cannot be used for delivery');
select zm_test.act_as(:'B');
insert into zm_addr select 'chilenje2', (public.save_address(null, 'Chilenje flat', 'delivery', (select id from zm_loc where name = 'Chilenje'), 'Flat 4', 'Clinic', 'Second floor')).id;
select zm_test.expect_equal((public.create_order((select id from zm_ids where name = 'l3'), 'delivery', 'ignored text', null, null, (select id from zm_addr where name = 'chilenje2'))).delivery_address, 'Flat 4, near Clinic, Chilenje, Lusaka. Directions: Second floor', 'the saved address text replaces typed text');
select zm_test.act_as(:'C');
select zm_test.expect_error(format($$select public.create_order(%L, 'delivery', null, null, null, %L)$$, (select id from zm_ids where name = 'l4'), (select id from zm_addr where name = 'chilenje2')), 'someone else''s saved address');
-- unlimited seller, as before
select zm_test.act_as(:'S');
select public.set_delivery_areas(null, '[]');
select zm_test.act_as(:'C');
select zm_test.expect_equal((public.create_order((select id from zm_ids where name = 'l4'), 'delivery', 'Anywhere')).fulfilment::text, 'delivery', 'no areas set: delivery works as it did before');

-- 6. Sharing a pickup address
select zm_test.act_as(:'S');
insert into zm_addr select 'spick', (public.save_address(null, 'My gate', 'pickup', (select id from zm_loc where name = 'Kabulonga'), 'Gate 2', 'Church', null)).id;
insert into zm_addr select 'sdel', (public.save_address(null, 'Delivery only', 'delivery', (select id from zm_loc where name = 'Kabulonga'), 'Gate 3', null, null)).id;
create temp table zm_ord (name text primary key, id uuid);
grant all on zm_ord to anon, authenticated, service_role;
insert into zm_ord select 'coll', o.id from public.orders o where o.listing_id = (select id from zm_ids where name = 'l2');
insert into zm_ord select 'deliv', o.id from public.orders o where o.listing_id = (select id from zm_ids where name = 'l4');
select zm_test.expect_error(format($$select public.share_pickup_address(%L, %L)$$, (select id from zm_ord where name = 'coll'), (select id from zm_addr where name = 'spick')), 'not before the order is confirmed');
select public.confirm_order((select id from zm_ord where name = 'coll'));
select zm_test.expect_error(format($$select public.share_pickup_address(%L, %L)$$, (select id from zm_ord where name = 'coll'), (select id from zm_addr where name = 'sdel')), 'a delivery-only address cannot be a pickup point');
select zm_test.expect_error(format($$select public.share_pickup_address(%L, %L)$$, (select id from zm_ord where name = 'coll'), (select id from zm_addr where name = 'home')), 'not someone else''s address');
select zm_test.act_as(:'B');
select zm_test.expect_error(format($$select public.share_pickup_address(%L, %L)$$, (select id from zm_ord where name = 'coll'), (select id from zm_addr where name = 'collect')), 'the buyer cannot share a pickup point');
select zm_test.act_as(:'C');
select zm_test.expect_error(format($$select public.share_pickup_address(%L, %L)$$, (select id from zm_ord where name = 'coll'), (select id from zm_addr where name = 'spick')), 'an outsider cannot');
select zm_test.act_as(:'S');
select zm_test.expect_equal((public.share_pickup_address((select id from zm_ord where name = 'coll'), (select id from zm_addr where name = 'spick'))).pickup_text, 'Gate 2, near Church, Kabulonga, Lusaka', 'the seller shares it');
select zm_test.act_as(:'B');
select zm_test.expect_equal((select pickup_text from public.orders where id = (select id from zm_ord where name = 'coll')), 'Gate 2, near Church, Kabulonga, Lusaka', 'the buyer sees it on the order');
select zm_test.act_as(:'C');
select zm_test.expect_equal((select count(*)::text from public.orders where pickup_text is not null), '0', 'nobody else does');
select zm_test.act_as(:'S');
select zm_test.expect_error(format($$select public.share_pickup_address(%L, %L)$$, (select id from zm_ord where name = 'deliv'), (select id from zm_addr where name = 'spick')), 'not on a delivery order');

-- 7. Nearby listings
select zm_test.act_as_admin();
create temp table zm_near (name text primary key, id uuid);
grant all on zm_near to anon, authenticated, service_role;
insert into zm_near select 'kab', zm_test.fresh_listing(10);
insert into zm_near select 'chi', zm_test.fresh_listing(10);
insert into zm_near select 'rom', zm_test.fresh_listing(10);
insert into zm_near select 'ndo', zm_test.fresh_listing(10);
update public.listings set location_id = (select id from zm_loc where name = 'Kabulonga') where id = (select id from zm_near where name = 'kab');
update public.listings set location_id = (select id from zm_loc where name = 'Chilenje') where id = (select id from zm_near where name = 'chi');
update public.listings set location_id = (select id from zm_loc where name = 'Roma') where id = (select id from zm_near where name = 'rom');
update public.listings set location_id = (select id from zm_loc where name = 'Ndola') where id = (select id from zm_near where name = 'ndo');
update public.listings set created_at = now() - interval '1 hour' where id = (select id from zm_near where name = 'rom');
update public.listings set created_at = now() - interval '2 hours' where id = (select id from zm_near where name = 'chi');
select zm_test.act_as_guest();
select zm_test.expect_equal((select string_agg(n.name, ',' order by n.name) from public.nearby_listings_ranked((select id from zm_loc where name = 'Kabulonga'), 'area') r join zm_near n on n.id = r.id), 'kab', 'area scope: only the same area');
select zm_test.expect_equal((select string_agg(n.name, ',' order by n.name) from public.nearby_listings_ranked((select id from zm_loc where name = 'Kabulonga'), 'town') r join zm_near n on n.id = r.id), 'chi,kab,rom', 'town scope: the whole town, not Ndola');
select zm_test.expect_equal((select string_agg(n.name, ',' order by n.name) from public.nearby_listings_ranked((select id from zm_loc where name = 'Kabulonga'), 'province') r join zm_near n on n.id = r.id), 'chi,kab,rom', 'province scope stays in the province');
select zm_test.expect_equal((select string_agg(n.name, ',' order by x.rn) from (select r.id, row_number() over () rn from public.nearby_listings_ranked((select id from zm_loc where name = 'Kabulonga'), 'town') r) x join zm_near n on n.id = x.id), 'kab,chi,rom', 'same area first, then by distance, places without coordinates last');
select zm_test.expect_equal((select string_agg(n.name, ',' order by n.name) from public.nearby_listings_ranked((select id from zm_loc where name = 'Kabulonga'), 'town', 20) r join zm_near n on n.id = r.id), 'chi,kab', 'within 20 km: only places with coordinates inside the radius');
select zm_test.expect_equal((select string_agg(n.name, ',' order by n.name) from public.nearby_listings_ranked((select id from zm_loc where name = 'Kabulonga'), 'town', 1) r join zm_near n on n.id = r.id), 'kab', 'within 1 km: only the same place');
select zm_test.expect_equal((select string_agg(n.name, ',' order by n.name) from public.nearby_listings_ranked((select id from zm_loc where name = 'Ndola'), 'province') r join zm_near n on n.id = r.id), 'ndo', 'the Copperbelt has only its own listing');
select zm_test.expect_error($$select * from public.nearby_listings_ranked(1, 'world')$$, 'bad scope');
select zm_test.expect_equal((select count(*)::text from public.nearby_listings_ranked((select id from zm_loc where name = 'Kabulonga'), 'town', null, 1, 0)), '1', 'limit');
select zm_test.expect_equal((select count(*)::text from public.nearby_listings_ranked(999999, 'town')), '0', 'unknown place gives nothing');

-- 8. Function permissions
select zm_test.act_as_admin();
select zm_test.expect_equal((select bool_or(has_function_privilege('anon', p.oid, 'execute'))::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('admin_add_location','admin_set_location_coordinates','save_address','delete_address','delivery_check','set_delivery_areas','my_delivery_areas','create_order','share_pickup_address','listing_coverage','format_address')), 'false', 'guests cannot run any write or private function');
select zm_test.expect_equal((select bool_or(has_function_privilege('authenticated', p.oid, 'execute'))::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('listing_coverage','format_address')), 'false', 'helpers are private');
select zm_test.expect_equal((select bool_or(has_function_privilege('service_role', p.oid, 'execute'))::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('save_address','set_delivery_areas','create_order')), 'false', 'workers have no reason to run them');

select 'Location checks passed' as result;
rollback;
