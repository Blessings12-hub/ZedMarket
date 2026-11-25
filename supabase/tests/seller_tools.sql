-- Seller tools (migration 0022): the tracker, status history, duplicating, bulk price and stock updates (all or
-- nothing, moderation not bypassed), photo order, accounts that cannot post, limits and closed tables.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/seller_tools.sql

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

create function zm_test.s(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000001' || lpad(n::text, 2, '0'))::uuid
$$;


insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@example.test',   '{"display_name":"Owner Olive"}', now()),
  ('00000000-0000-0000-0000-00000000000b', 'manager@example.test', '{"display_name":"Manager Mwila"}', now()),
  ('00000000-0000-0000-0000-00000000000c', 'staff@example.test',   '{"display_name":"Staff Sipho"}', now()),
  ('00000000-0000-0000-0000-00000000000d', 'outsider@example.test','{"display_name":"Outsider Omar"}', now()),
  ('00000000-0000-0000-0000-00000000000e', 'solo@example.test',    '{"display_name":"Solo Seller"}', now());
-- Posting needs an approved seller (migration 0023). These fixtures are sellers; onboarding.sql covers buyers and applicants.
update public.profiles set seller_status = 'active';
insert into public.businesses (id, owner_id, name, slug, description, location_id)
values ('20000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000a', 'Olive Electronics', 'olive-electronics', 'x',
        (select id from public.locations where area = 'Kabulonga'));
insert into public.business_members (business_id, user_id, role) values
  ('20000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b', 'manager'),
  ('20000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000c', 'staff');
update public.platform_settings set value = '1000' where key = 'rate_limit.bulk_update.max';
update public.prohibited_terms set is_active = false;
-- Old enough that the new-seller high-value rule does not apply to the business owner and the solo seller
update public.profiles set created_at = now() - interval '400 days' where id in ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000e');

create temp table zm_ids (name text primary key, id uuid);
grant all on zm_ids to anon, authenticated, service_role;

-- A live, approved listing with a photo. p_business null = personal listing of the solo seller.
create function zm_test.mk(p_name text, p_business uuid, p_price numeric default 100, p_qty integer default null, p_status text default 'active') returns uuid
language plpgsql as $$
declare
  new_id uuid;
  seller uuid := case when p_business is null then '00000000-0000-0000-0000-00000000000e'::uuid else '00000000-0000-0000-0000-00000000000a'::uuid end;
begin
  insert into public.listings (seller_id, business_id, category_id, location_id, title, description, price_zmw, condition, status)
  select seller, p_business, c.id, l.id, 'Item ' || p_name, 'Description of ' || p_name, p_price, 'used_good', 'draft'
    from public.categories c, public.locations l where c.slug = 'electronics' and l.area = 'Kabulonga'
  returning id into new_id;
  insert into public.listing_images (listing_id, storage_path, position) values (new_id, 'x/' || new_id || '-1.jpg', 0), (new_id, 'x/' || new_id || '-2.jpg', 1);
  if p_status = 'active' then
    update public.listings set status = 'active' where id = new_id;
  end if;
  if p_qty is not null then
    insert into public.listing_stock (listing_id, business_id, quantity, sku) values (new_id, p_business, p_qty, 'SKU-' || p_name);
  end if;
  insert into zm_ids values (p_name, new_id);
  return new_id;
end $$;
create function zm_test.id(p_name text) returns uuid language sql as $$ select id from zm_ids where name = p_name $$;
create function zm_test.price(p_name text) returns text language sql security definer as $$
  select price_zmw::text from public.listings where id = (select id from zm_ids where name = p_name) $$;
create function zm_test.qty(p_name text) returns text language sql security definer as $$
  select quantity::text from public.listing_stock where listing_id = (select id from zm_ids where name = p_name) $$;
grant execute on all functions in schema zm_test to anon, authenticated, service_role;

\set O '00000000-0000-0000-0000-00000000000a'
\set M '00000000-0000-0000-0000-00000000000b'
\set S '00000000-0000-0000-0000-00000000000c'
\set X '00000000-0000-0000-0000-00000000000d'
\set SOLO '00000000-0000-0000-0000-00000000000e'
\set BIZ '20000000-0000-0000-0000-00000000000a'

select zm_test.mk('A', :'BIZ', 100, 10);
select zm_test.mk('B', :'BIZ', 200, 5);
select zm_test.mk('C', :'BIZ', 300, null);
select zm_test.mk('D', :'BIZ', 50, 2, 'draft');
select zm_test.mk('P1', null, 40);
select zm_test.mk('P2', null, 60, null, 'draft');

-- 1. Closed tables
select zm_test.expect_equal((select count(*)::text from information_schema.role_table_grants where table_schema = 'public'
   and table_name = 'listing_status_events' and grantee in ('anon', 'authenticated')), '0', 'no table grants on the history');
select zm_test.act_as(:'X');
select zm_test.expect_error('select * from public.listing_status_events', 'history table is closed');
select zm_test.expect_error('select public.seller_can_manage(null::public.listings)', 'internal helper is closed');
select zm_test.act_as_guest();
select zm_test.expect_error('select * from public.seller_listings()', 'guests cannot list');

-- 2. Tracker
select zm_test.act_as(:'M');
select zm_test.expect_equal((select count(*)::text from public.seller_listings(:'BIZ')), '4', 'business sees its four listings');
select zm_test.expect_equal((select count(*)::text from public.seller_listings(:'BIZ', 'draft')), '1', 'draft filter');
select zm_test.expect_equal((select count(*)::text from public.seller_listings(:'BIZ', 'live')), '3', 'live filter');
select zm_test.expect_equal((select count(*)::text from public.seller_listings(:'BIZ', 'all', 'sku-b')), '1', 'search finds by SKU');
select zm_test.expect_equal((select photos::text from public.seller_listings(:'BIZ', 'all', 'A')  where title = 'Item A'), '2', 'photo count');
select zm_test.expect_equal((select quantity::text from public.seller_listings(:'BIZ') where title = 'Item A'), '10', 'stock shown');
select zm_test.expect_equal((select count(*)::text from public.seller_listings(null)), '0', 'the manager has no personal listings');
select zm_test.expect_error($q$select * from public.seller_listings(null, 'nonsense')$q$, 'unknown filter');
select zm_test.act_as(:'X');
select zm_test.expect_error(format($q$select * from public.seller_listings(%L)$q$, :'BIZ'), 'outsider cannot list a business');
select zm_test.expect_equal((select count(*)::text from public.seller_listings(null)), '0', 'outsider sees none of their own');
select zm_test.act_as(:'SOLO');
select zm_test.expect_equal((select count(*)::text from public.seller_listings(null)), '2', 'solo seller sees own listings');
select zm_test.expect_equal((select count(*)::text from public.seller_listings(null, 'draft')), '1', 'solo draft');

-- 3. Timeline
select zm_test.act_as(:'M');
select zm_test.expect_equal((select count(*)::text from public.listing_timeline(zm_test.id('A'))), '2', 'draft then live');
select zm_test.act_as_admin();
update public.listings set moderation_status = 'rejected', moderation_note = 'Photos do not show the item' where id = zm_test.id('B');
select zm_test.act_as(:'M');
select zm_test.expect_equal((select note from public.listing_timeline(zm_test.id('B')) order by created_at desc limit 1), 'Photos do not show the item', 'rejection reason is in the history');
select zm_test.act_as(:'X');
select zm_test.expect_error(format($q$select * from public.listing_timeline(%L)$q$, zm_test.id('A')), 'outsider cannot read a history');
select zm_test.act_as(:'SOLO');
select zm_test.expect_equal((select count(*)::text from public.listing_timeline(zm_test.id('P1'))), '2', 'solo reads own history');
select zm_test.act_as_admin();
select zm_test.expect_error('update public.listing_status_events set note = ''x''', 'history cannot be edited');
select zm_test.expect_error('delete from public.listing_status_events', 'history cannot be deleted');
select zm_test.expect_equal((select count(*)::text from public.listing_status_events where listing_id = zm_test.id('D')), '1', 'draft has its first entry');
update public.listings set title = 'Renamed D' where id = zm_test.id('D');
select zm_test.expect_equal((select count(*)::text from public.listing_status_events where listing_id = zm_test.id('D')), '1', 'edits that change no status add nothing');

-- 4. Duplicate
select zm_test.act_as(:'M');
insert into zm_ids select 'A2', public.duplicate_listing(zm_test.id('A'));
select zm_test.expect_equal((select title from public.seller_listings(:'BIZ') where listing_id = zm_test.id('A2')), 'Copy of Item A', 'default title');
select zm_test.expect_equal((select status::text from public.seller_listings(:'BIZ') where listing_id = zm_test.id('A2')), 'draft', 'copy is a draft');
select zm_test.expect_equal((select photos::text from public.seller_listings(:'BIZ') where listing_id = zm_test.id('A2')), '0', 'photos are not copied');
select zm_test.expect_equal((select tracked::text from public.seller_listings(:'BIZ') where listing_id = zm_test.id('A2')), 'false', 'stock is not copied');
select zm_test.expect_equal((select price_zmw::text from public.seller_listings(:'BIZ') where listing_id = zm_test.id('A2')), '100.00', 'price copied');
insert into zm_ids select 'A3', public.duplicate_listing(zm_test.id('A'), 'Blue version', 'NEW-1', 7);
select zm_test.expect_equal((select quantity::text from public.seller_listings(:'BIZ') where listing_id = zm_test.id('A3')), '7', 'copy with its own stock');
select zm_test.expect_error(format($q$select public.duplicate_listing(%L, 'Dup', 'NEW-1', 3)$q$, zm_test.id('A')), 'SKU must be new');
select zm_test.expect_error(format($q$select public.duplicate_listing(%L, 'Dup', 'ONLY-SKU', null)$q$, zm_test.id('A')), 'sku without quantity');
select zm_test.act_as(:'X');
select zm_test.expect_error(format($q$select public.duplicate_listing(%L)$q$, zm_test.id('A')), 'outsider cannot copy');
select zm_test.act_as(:'SOLO');
insert into zm_ids select 'P1c', public.duplicate_listing(zm_test.id('P1'));
select zm_test.expect_equal((select count(*)::text from public.seller_listings(null)), '3', 'solo copy appears');
select zm_test.expect_error(format($q$select public.duplicate_listing(%L, 'x', 'S1', 1)$q$, zm_test.id('P1')), 'stock tracking is for businesses');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action = 'listing.duplicated'), '3', 'copies audited');
update public.listings set status = 'removed' where id = zm_test.id('P2');
select zm_test.act_as(:'SOLO');
select zm_test.expect_error(format($q$select public.duplicate_listing(%L)$q$, zm_test.id('P2')), 'removed listing cannot be copied');

-- 5. Bulk prices
select zm_test.act_as(:'S');
select count(*) from public.bulk_update_prices(array[zm_test.id('A'), zm_test.id('B')], 'percent', 10);
select zm_test.expect_equal(zm_test.price('A'), '110.00', 'ten percent up');
select zm_test.expect_equal(zm_test.price('B'), '220.00', 'ten percent up (second)');
select count(*) from public.bulk_update_prices(array[zm_test.id('A'), zm_test.id('B')], 'amount', -10);
select zm_test.expect_equal(zm_test.price('A') || '/' || zm_test.price('B'), '100.00/210.00', 'amount down');
select count(*) from public.bulk_update_prices(array[zm_test.id('A'), zm_test.id('B'), zm_test.id('A')], 'set', 99.999);
select zm_test.expect_equal(zm_test.price('A') || '/' || zm_test.price('B'), '100.00/100.00', 'set rounds to two places and ignores repeated ids');
-- all or nothing
select zm_test.expect_error(format($q$select * from public.bulk_update_prices(array[%L, %L], 'set', 77)$q$, zm_test.id('A'), zm_test.id('P1')), 'one foreign listing stops the whole change');
select zm_test.expect_equal(zm_test.price('A'), '100.00', 'nothing changed after the failed call');
select zm_test.expect_error(format($q$select * from public.bulk_update_prices(array[%L, %L], 'amount', -150)$q$, zm_test.id('A'), zm_test.id('C')), 'price would go below zero');
select zm_test.expect_equal(zm_test.price('A') || '/' || zm_test.price('C'), '100.00/300.00', 'still unchanged');
select zm_test.expect_error(format($q$select * from public.bulk_update_prices(array[%L], 'bogus', 1)$q$, zm_test.id('A')), 'bad mode');
select zm_test.expect_error($q$select * from public.bulk_update_prices(array[]::uuid[], 'set', 5)$q$, 'nothing chosen');
select zm_test.expect_error(format($q$select * from public.bulk_update_prices(array[%L], 'set', null)$q$, zm_test.id('A')), 'no value');
select zm_test.act_as(:'X');
select zm_test.expect_error(format($q$select * from public.bulk_update_prices(array[%L], 'set', 1)$q$, zm_test.id('A')), 'outsider cannot change prices');
select zm_test.act_as_guest();
select zm_test.expect_error(format($q$select * from public.bulk_update_prices(array[%L], 'set', 1)$q$, zm_test.id('A')), 'guest cannot change prices');
select zm_test.act_as(:'SOLO');
select count(*) from public.bulk_update_prices(array[zm_test.id('P1')], 'set', 45);
select zm_test.expect_equal(zm_test.price('P1'), '45.00', 'solo seller changes own price');
select zm_test.expect_error(format($q$select * from public.bulk_update_prices(array[%L], 'set', 1)$q$, zm_test.id('A')), 'solo seller cannot touch a business listing');
-- moderation is not bypassed: a price over the high-value limit sends a new seller's listing back to review
select zm_test.act_as_admin();
update public.profiles set created_at = now() where id = :'SOLO';
select zm_test.act_as(:'SOLO');
select count(*) from public.bulk_update_prices(array[zm_test.id('P1')], 'set', 50000);
select zm_test.expect_equal((select moderation_status::text from public.seller_listings(null) where listing_id = zm_test.id('P1')), 'pending', 'a big price jump goes back to review');
select zm_test.act_as_admin();
update public.profiles set created_at = now() - interval '400 days' where id = :'SOLO';
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action = 'listing.bulk_price'), '5', 'successful bulk prices audited, failures leave nothing');
-- closed listings
update public.listings set status = 'sold' where id = zm_test.id('C');
select zm_test.act_as(:'M');
select zm_test.expect_error(format($q$select * from public.bulk_update_prices(array[%L], 'set', 5)$q$, zm_test.id('C')), 'sold listing price is locked');
-- cap
select zm_test.act_as_admin();
update public.platform_settings set value = '2' where key = 'seller.bulk_max_items';
select zm_test.act_as(:'M');
select zm_test.expect_error(format($q$select * from public.bulk_update_prices(array[%L, %L, %L], 'set', 5)$q$, zm_test.id('A'), zm_test.id('B'), zm_test.id('D')), 'cap on items');
select zm_test.act_as_admin();
update public.platform_settings set value = '200' where key = 'seller.bulk_max_items';

-- 6. Bulk stock
select zm_test.act_as(:'S');
select count(*) from public.bulk_update_stock(jsonb_build_array(
  jsonb_build_object('listing_id', zm_test.id('A'), 'mode', 'set', 'value', 25),
  jsonb_build_object('listing_id', zm_test.id('B'), 'mode', 'adjust', 'value', -2)));
select zm_test.expect_equal(zm_test.qty('A') || '/' || zm_test.qty('B'), '25/3', 'set and adjust');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.stock_movements where note = 'Bulk update'), '2', 'movements recorded');
select zm_test.act_as(:'S');
select zm_test.expect_error(format($q$select * from public.bulk_update_stock(jsonb_build_array(
  jsonb_build_object('listing_id', %L, 'mode', 'set', 'value', 1), jsonb_build_object('listing_id', %L, 'mode', 'set', 'value', 1)))$q$, zm_test.id('A'), zm_test.id('C')), 'an untracked listing stops everything');
select zm_test.expect_equal(zm_test.qty('A'), '25', 'nothing changed after the failure');
select zm_test.expect_error(format($q$select * from public.bulk_update_stock(jsonb_build_array(
  jsonb_build_object('listing_id', %L, 'mode', 'adjust', 'value', -99)))$q$, zm_test.id('A')), 'cannot go below zero');
select zm_test.expect_error(format($q$select * from public.bulk_update_stock(jsonb_build_array(
  jsonb_build_object('listing_id', %L, 'mode', 'set', 'value', 1.5)))$q$, zm_test.id('A')), 'whole numbers only');
select zm_test.expect_error(format($q$select * from public.bulk_update_stock(jsonb_build_array(
  jsonb_build_object('listing_id', %L, 'mode', 'set', 'value', 100001)))$q$, zm_test.id('A')), 'upper limit');
select zm_test.expect_error('select * from public.bulk_update_stock(''[]'')', 'empty');
select zm_test.expect_error('select * from public.bulk_update_stock(''{"a":1}'')', 'not an array');
select count(*) from public.bulk_update_stock(jsonb_build_array(jsonb_build_object('listing_id', zm_test.id('A'), 'mode', 'set', 'value', 0)));
select zm_test.expect_equal((select status::text from public.seller_listings(:'BIZ') where listing_id = zm_test.id('A')), 'unavailable', 'selling out pauses the listing');
select count(*) from public.bulk_update_stock(jsonb_build_array(jsonb_build_object('listing_id', zm_test.id('A'), 'mode', 'adjust', 'value', 4)));
select zm_test.expect_equal((select status::text from public.seller_listings(:'BIZ') where listing_id = zm_test.id('A')), 'active', 'restocking brings it back');
select zm_test.act_as(:'X');
select zm_test.expect_error(format($q$select * from public.bulk_update_stock(jsonb_build_array(
  jsonb_build_object('listing_id', %L, 'mode', 'set', 'value', 1)))$q$, zm_test.id('A')), 'outsider cannot change stock');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action = 'listing.bulk_stock'), '3', 'bulk stock audited');

-- 7. Photos
select zm_test.act_as(:'M');
select public.reorder_listing_images(zm_test.id('A'),
  (select array_agg(id order by position desc) from public.listing_images where listing_id = zm_test.id('A')));
select zm_test.expect_equal((select storage_path like '%-2.jpg' from public.listing_images where listing_id = zm_test.id('A') and position = 0)::text, 'true', 'second photo is now the cover');
select zm_test.expect_error(format($q$select public.reorder_listing_images(%L, array[%L]::uuid[])$q$, zm_test.id('A'),
  (select id from public.listing_images where listing_id = zm_test.id('A') limit 1)), 'must list every photo');
select zm_test.expect_error(format($q$select public.reorder_listing_images(%L, null)$q$, zm_test.id('A')), 'null list');
select zm_test.act_as(:'X');
select zm_test.expect_error(format($q$select public.reorder_listing_images(%L, array[]::uuid[])$q$, zm_test.id('A')), 'outsider cannot reorder');

-- 8. Accounts that cannot post cannot bulk edit
select zm_test.act_as_admin();
update public.profiles set account_state = 'suspended' where id = :'S';
select zm_test.act_as(:'S');
select zm_test.expect_error(format($q$select * from public.bulk_update_prices(array[%L], 'set', 5)$q$, zm_test.id('A')), 'suspended account');
select zm_test.expect_error(format($q$select public.duplicate_listing(%L)$q$, zm_test.id('A')), 'suspended account cannot copy');

-- 9. Rate limit
select zm_test.act_as_admin();
delete from public.rate_limit_log;
update public.platform_settings set value = '2' where key = 'rate_limit.bulk_update.max';
select zm_test.act_as(:'O');
select count(*) from public.bulk_update_prices(array[zm_test.id('B')], 'set', 120);
select count(*) from public.bulk_update_prices(array[zm_test.id('B')], 'set', 121);
select zm_test.expect_error(format($q$select * from public.bulk_update_prices(array[%L], 'set', 122)$q$, zm_test.id('B')), 'rate limit');

-- 10. Deleting a draft still works (its history goes with it)
select zm_test.act_as(:'SOLO');
delete from public.listings where id = zm_test.id('P1c');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.listing_status_events where listing_id = zm_test.id('P1c')), '0', 'history removed with the listing');

rollback;
