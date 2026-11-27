-- Chunk E limits (migration 0032): analytics count quantity, and the stock count shown to buyers follows a setting.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/limits.sql
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




create function zm_test.q(p_sql text) returns text language plpgsql security definer as $$
declare r text; begin execute p_sql into r; return r; end $$;
grant execute on all functions in schema zm_test to anon, authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
  ('00000000-0000-0000-0000-00000000000a', 'seller@example.test', '{"display_name":"Seller"}', now()),
  ('00000000-0000-0000-0000-0000000000b1', 'b1@example.test', '{"display_name":"Buyer"}', now());
\set S '00000000-0000-0000-0000-00000000000a'
\set B '00000000-0000-0000-0000-0000000000b1'
update public.platform_settings set value = '1000' where key = 'rate_limit.order.max';

-- three listings, one completed order each: 1 unit at 50; 3 ordered/2 handed over at 100; 2 ordered/2 handed over at 10
create temp table lst (n integer primary key, id uuid);
grant all on lst to anon, authenticated, service_role;
insert into lst select n, gen_random_uuid() from generate_series(1, 3) n;
insert into public.listings (id, seller_id, category_id, location_id, title, description, price_zmw, condition, status, moderation_status)
select id, :'S', (select id from public.categories order by id limit 1), (select id from public.locations order by id limit 1), 'Item ' || n, 'x',
       case n when 1 then 50 when 2 then 100 else 10 end, 'used_good', 'draft', 'pending' from lst;
insert into public.orders (listing_id, buyer_id, seller_id, item_title, item_price_zmw, buyer_name, seller_name, status, completed_at, handed_over_at, quantity, quantity_delivered)
select id, :'B', :'S', 'Item ' || n, case n when 1 then 50 when 2 then 100 else 10 end, 'Buyer', 'Seller', 'completed', now(), now(),
       case n when 1 then 1 when 2 then 3 else 2 end, case n when 1 then null when 2 then 2 else 2 end from lst;

select zm_test.expect_equal(zm_test.q($$select string_agg(items_zmw::text, ',' order by item_title) from public.orders$$), '50.00,200.00,20.00', 'items_zmw is price x what was handed over');

select zm_test.act_as(:'S');
select zm_test.expect_equal((public.seller_analytics(null, 30) #>> '{sales,completed_value_zmw}')::numeric::text, '270.00', 'seller analytics: completed value counts the quantity');
select zm_test.expect_equal((select sum(items_zmw)::text from public.sales_report(null, current_date - 2, current_date + 1)), '270.00', 'sales report: items');
select zm_test.expect_equal((select max(items_zmw)::text from public.sales_by_listing(null, current_date - 2, current_date + 1)), '200.00', 'sales by listing: the biggest line');
select zm_test.expect_equal((select sum(total_zmw)::text from public.sales_report(null, current_date - 2, current_date + 1)), '270.00', 'total follows too');
select zm_test.expect_equal((public.listing_performance((select id from lst where n = 2), 30) ->> 'completed_value_zmw')::numeric::text, '200.00', 'listing performance counts the quantity');
select zm_test.act_as_admin();

-- the stock count shown to buyers follows the setting
insert into public.businesses (id, owner_id, name, slug) values ('20000000-0000-0000-0000-00000000000a', :'S', 'Shop', 'shop');
update public.listings set business_id = '20000000-0000-0000-0000-00000000000a' where id = (select id from lst where n = 3);
insert into public.listing_stock (listing_id, business_id, quantity) select id, '20000000-0000-0000-0000-00000000000a', 250 from lst where n = 3;
select zm_test.expect_equal(public.listing_stock_info((select id from lst where n = 3))::text, '100', 'default cap is 100');
update public.platform_settings set value = '30' where key = 'listing.stock_display_cap';
select zm_test.expect_equal(public.listing_stock_info((select id from lst where n = 3))::text, '30', 'cap follows the setting');
update public.platform_settings set value = '0' where key = 'listing.stock_display_cap';
select zm_test.expect_equal(public.listing_stock_info((select id from lst where n = 3))::text, '250', 'zero shows the exact count');
select zm_test.expect_equal((public.listing_stock_info((select id from lst where n = 1)) is null)::text, 'true', 'a one-off item still has no count');

select 'Limits checks passed' as result;
rollback;
