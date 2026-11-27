-- Quantity reservations, branch stock and partial fulfilment (migration 0031).
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/quantity_orders.sql
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



create function zm_test.msg(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'no error'; exception when others then return sqlerrm; end $$;
create function zm_test.q(p_sql text) returns text language plpgsql security definer as $$
declare r text; begin execute p_sql into r; return r; end $$;
grant execute on all functions in schema zm_test to anon, authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@example.test', '{"display_name":"Owner Olive"}', now()),
  ('00000000-0000-0000-0000-0000000000b1', 'b1@example.test', '{"display_name":"Buyer One"}', now()),
  ('00000000-0000-0000-0000-0000000000b2', 'b2@example.test', '{"display_name":"Buyer Two"}', now()),
  ('00000000-0000-0000-0000-0000000000b3', 'b3@example.test', '{"display_name":"Buyer Three"}', now()),
  ('00000000-0000-0000-0000-0000000000b4', 'b4@example.test', '{"display_name":"Buyer Four"}', now()),
  ('00000000-0000-0000-0000-00000000000d', 'out@example.test', '{"display_name":"Outsider"}', now());
update public.platform_settings set value = '1000' where key = 'rate_limit.order.max';
insert into public.businesses (id, owner_id, name, slug, description) values
  ('20000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000a', 'Olive Electronics', 'olive-electronics', 'Phones');
update public.businesses set publish_state = 'active', registration_kind = 'registered';

create function zm_test.fresh_listing(p_business uuid default null) returns uuid language plpgsql as $$
declare new_id uuid;
begin
  insert into public.listings (seller_id, business_id, category_id, location_id, title, description, price_zmw, condition, status, moderation_status)
  select '00000000-0000-0000-0000-00000000000a', p_business, c.id, l.id, 'Item ' || substr(gen_random_uuid()::text, 1, 8), 'Test item', 100, 'used_good', 'draft', 'pending'
    from public.categories c, public.locations l where c.slug = 'electronics' and l.area = 'Kabulonga' returning id into new_id;
  insert into public.listing_images (listing_id, storage_path, position) values (new_id, 'x/' || new_id || '.jpg', 0);
  update public.listings set status = 'active' where id = new_id;
  update public.listings set moderation_status = 'approved' where id = new_id;
  return new_id;
end $$;
-- A requested order for p_qty units from buyer p_buyer, made with the real function.
create function zm_test.ask(p_buyer uuid, p_listing uuid, p_qty integer) returns uuid language plpgsql as $$
declare oid uuid;
begin
  perform zm_test.act_as(p_buyer);
  oid := (public.create_order(p_listing, 'collection', null, null, null, null, p_qty)).id;
  perform zm_test.act_as_admin();
  return oid;
end $$;
grant execute on all functions in schema zm_test to anon, authenticated, service_role;

\set O '00000000-0000-0000-0000-00000000000a'
\set B1 '00000000-0000-0000-0000-0000000000b1'
\set B2 '00000000-0000-0000-0000-0000000000b2'
\set B3 '00000000-0000-0000-0000-0000000000b3'
\set B4 '00000000-0000-0000-0000-0000000000b4'
\set OUT '00000000-0000-0000-0000-00000000000d'
\set BIZ '20000000-0000-0000-0000-00000000000a'

create temp table ids (name text primary key, id uuid);
grant all on ids to anon, authenticated, service_role;
create function zm_test.id(p text) returns uuid language sql security definer as $$ select id from ids where name = p $$;
grant execute on function zm_test.id(text) to anon, authenticated, service_role;

-- branches and a counted listing: 10 units
select zm_test.act_as(:'O');
insert into ids values ('main', public.create_branch(:'BIZ', 'Kabulonga Shop'));
insert into ids values ('cairo', public.create_branch(:'BIZ', 'Cairo Road Shop'));
select zm_test.act_as_admin();
insert into ids values ('l', zm_test.fresh_listing(:'BIZ'));
insert into ids values ('single', zm_test.fresh_listing(null));
select zm_test.act_as(:'O');
select public.track_stock(zm_test.id('l'), 10);
select zm_test.act_as_admin();

-- ---------- a one-off item stays one-off
select zm_test.act_as(:'B1');
select zm_test.expect_equal(zm_test.msg(format($$select public.create_order(%L, 'collection', null, null, null, null, 2)$$, zm_test.id('single'))), 'This is a single item. Order 1.', 'a one-off item cannot be ordered in twos');
select zm_test.expect_equal(zm_test.msg(format($$select public.create_order(%L, 'collection', null, null, null, null, 0)$$, zm_test.id('l'))), 'Choose a quantity between 1 and 1000.', 'zero');
select zm_test.expect_equal(zm_test.msg(format($$select public.create_order(%L, 'collection', null, null, null, null, 1001)$$, zm_test.id('l'))), 'Choose a quantity between 1 and 1000.', 'too many');
select zm_test.expect_equal(zm_test.msg(format($$select public.create_order(%L, 'collection', null, null, null, null, 11)$$, zm_test.id('l'))), 'Only 10 available right now. Order 10 or fewer.', 'more than the stock');
select zm_test.act_as_admin();
select zm_test.expect_equal((select listing_stock_info from (select public.listing_stock_info(zm_test.id('l'))) x)::text, '10', 'buyers see how many');
select zm_test.expect_equal((select public.listing_stock_info(zm_test.id('single')) is null)::text, 'true', 'a one-off item has no count');

-- ---------- several orders share counted stock
insert into ids values ('o1', zm_test.ask(:'B1', zm_test.id('l'), 4));
insert into ids values ('o2', zm_test.ask(:'B2', zm_test.id('l'), 4));
insert into ids values ('o3', zm_test.ask(:'B3', zm_test.id('l'), 4));
select zm_test.act_as(:'O');
select public.confirm_order(zm_test.id('o1'), 0);
select zm_test.expect_equal(zm_test.q($$select public.listing_available_quantity((select id from ids where name = 'l'))$$), '6', 'first reservation leaves 6');
select zm_test.expect_equal(zm_test.q($$select status from public.orders where id = (select id from ids where name = 'o3')$$), 'requested', 'a request that still fits stays open');
select public.confirm_order(zm_test.id('o2'), 0);
select zm_test.expect_equal(zm_test.q($$select public.listing_available_quantity((select id from ids where name = 'l'))$$), '2', 'second leaves 2');
select zm_test.expect_equal(zm_test.q($$select status || '/' || cancel_kind from public.orders where id = (select id from ids where name = 'o3')$$), 'cancelled/declined', 'a request that no longer fits is turned away');
select zm_test.expect_equal(zm_test.q($$select count(*) from public.listing_reservations where listing_id = (select id from ids where name = 'l')$$), '2', 'two reservations on one listing');
select zm_test.act_as(:'B3');
select zm_test.expect_equal(zm_test.msg(format($$select public.create_order(%L, 'collection', null, null, null, null, 3)$$, zm_test.id('l'))), 'Only 2 available right now. Order 2 or fewer.', 'asking for more than is left');
select zm_test.act_as_admin();
insert into ids values ('o4', zm_test.ask(:'B4', zm_test.id('l'), 2));
select zm_test.act_as(:'O');
select public.confirm_order(zm_test.id('o4'), 0);
select zm_test.act_as_guest();
select zm_test.expect_equal((select count(*)::text from public.public_listings where id = zm_test.id('l')), '0', 'fully reserved listing leaves browsing');
select zm_test.act_as(:'B3');
select zm_test.expect_equal(zm_test.msg(format($$select public.create_order(%L, 'collection', null, null, null, null, 1)$$, zm_test.id('l'))), 'This item is reserved for another buyer right now. Try again later.', 'nothing left');
select zm_test.act_as(:'B1');
select public.cancel_order(zm_test.id('o1'), 'changed my mind');
select zm_test.act_as_guest();
select zm_test.expect_equal((select count(*)::text from public.public_listings where id = zm_test.id('l')), '1', 'cancelling frees units and the listing returns');
select zm_test.act_as_admin();
select zm_test.expect_equal(public.listing_available_quantity(zm_test.id('l'))::text, '4', 'four free again');

-- confirm-time check: an oversized request that slipped in is refused readably
insert into public.orders (listing_id, buyer_id, seller_id, business_id, item_title, item_price_zmw, buyer_name, seller_name, expires_at, quantity)
select zm_test.id('l'), :'B3', :'O', :'BIZ', 'x', 100, 'Buyer Three', 'Olive', now() + interval '1 day', 9;
select zm_test.act_as(:'O');
select zm_test.expect_equal(zm_test.msg(format($$select public.confirm_order(%L, 0)$$, (select id from public.orders where buyer_id = :'B3' and quantity = 9))),
  'Only 4 left, so an order for 9 cannot be confirmed. Decline it, or ask the buyer to order fewer.', 'confirm refuses what does not fit');
select zm_test.act_as(:'OUT');
select zm_test.expect_error(format($$select public.confirm_order(%L, 0)$$, zm_test.id('o2')), 'an outsider cannot confirm');
select zm_test.act_as_admin();
delete from public.orders where buyer_id = :'B3' and quantity = 9;

-- ---------- partial fulfilment
select zm_test.act_as(:'O');
select zm_test.expect_equal(zm_test.msg(format($$select public.mark_handed_over(%L, 0)$$, zm_test.id('o2'))), 'Say how many were handed over: between 1 and 4.', 'zero handed over');
select zm_test.expect_equal(zm_test.msg(format($$select public.mark_handed_over(%L, 5)$$, zm_test.id('o2'))), 'Say how many were handed over: between 1 and 4.', 'more than ordered');
select public.mark_handed_over(zm_test.id('o2'), 3);
select zm_test.expect_equal(zm_test.q($$select quantity_delivered || '/' || total_zmw from public.orders where id = (select id from ids where name = 'o2')$$), '3/300.00', 'the total follows what was handed over');
select zm_test.act_as(:'B2');
select public.complete_order(zm_test.id('o2'));
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.q($$select quantity from public.listing_stock where listing_id = (select id from ids where name = 'l')$$), '7', 'stock falls by what was handed over');
select zm_test.expect_equal(zm_test.q($$select change from public.stock_movements where order_id = (select id from ids where name = 'o2') and reason = 'sale'$$), '-3', 'the sale is in the history');
select zm_test.expect_equal(zm_test.q($$select count(*) from public.listing_reservations where order_id = (select id from ids where name = 'o2')$$), '0', 'reservation released');
select zm_test.expect_equal(zm_test.q($$select status from public.listings where id = (select id from ids where name = 'l')$$), 'active', 'the listing stays open while stock remains');
select zm_test.act_as(:'B2');
select zm_test.expect_equal(public.order_receipt(zm_test.id('o2'))->>'quantity_handed_over', '3', 'receipt shows what was handed over');
select zm_test.expect_equal(public.order_receipt(zm_test.id('o2'))->>'quantity_ordered', '4', 'receipt shows what was ordered');
select zm_test.act_as_admin();

-- ---------- branch stock
-- 7 in stock, 2 reserved by o4 (no branch yet). Seed into the main branch, then split.
select zm_test.act_as(:'OUT');
select zm_test.expect_error(format($$select public.set_branch_stock(%L, %L, 1)$$, zm_test.id('l'), zm_test.id('main')), 'an outsider cannot set branch stock');
select zm_test.act_as(:'O');
select zm_test.expect_equal(zm_test.msg(format($$select public.set_branch_stock(%L, %L, -1)$$, zm_test.id('l'), zm_test.id('main'))), 'Enter a quantity between 0 and 100000.', 'negative');
select public.set_branch_stock(zm_test.id('l'), zm_test.id('cairo'), 3, 'moved from the van');
select zm_test.expect_equal((select quantity::text from public.branch_stock(zm_test.id('l')) where branch_name = 'Kabulonga Shop'), '7', 'existing stock moved into the listing''s own branch');
select zm_test.expect_equal(zm_test.q($$select quantity from public.listing_stock where listing_id = (select id from ids where name = 'l')$$), '10', 'the total is the sum of the branches');
select zm_test.expect_equal(zm_test.msg(format($$select public.adjust_stock(%L, 1, 'restock')$$, zm_test.id('l'))),
  'This listing keeps its stock per branch. Change the stock for a branch instead.', 'the total cannot be changed directly any more');
select zm_test.expect_equal(zm_test.msg(format($$select public.set_branch_stock(%L, %L, 99)$$, zm_test.id('l'), (select id from public.business_branches where name = 'Nowhere'))), 'Choose one of your active branches.', 'not a branch');
select zm_test.act_as_admin();

insert into ids values ('o5', zm_test.ask(:'B1', zm_test.id('l'), 3));
select zm_test.act_as(:'O');
select zm_test.expect_equal(zm_test.msg(format($$select public.confirm_order(%L, 0)$$, zm_test.id('o5'))), 'Choose the branch this order will be filled from.', 'a branch is needed');
select zm_test.expect_equal(zm_test.msg(format($$select public.confirm_order(%L, 0, %L)$$, zm_test.id('o5'), gen_random_uuid())), 'That branch does not hold this item.', 'a branch that holds nothing');
select public.confirm_order(zm_test.id('o5'), 0, zm_test.id('cairo'));
select zm_test.expect_equal((select reserved::text from public.branch_stock(zm_test.id('l')) where branch_name = 'Cairo Road Shop'), '3', 'reserved at the chosen branch');
select zm_test.expect_equal(zm_test.msg(format($$select public.set_branch_stock(%L, %L, 2)$$, zm_test.id('l'), zm_test.id('cairo'))),
  'This branch has 3 reserved for confirmed orders, so it cannot hold fewer than that.', 'cannot drop below reserved');
select zm_test.act_as_admin();
insert into ids values ('o6', zm_test.ask(:'B3', zm_test.id('l'), 1));
select zm_test.act_as(:'O');
select zm_test.expect_equal(zm_test.msg(format($$select public.confirm_order(%L, 0, %L)$$, zm_test.id('o6'), zm_test.id('cairo'))), 'That branch has only 0 free. Choose another branch.', 'the branch is full');
select public.confirm_order(zm_test.id('o6'), 0, zm_test.id('main'));
select zm_test.act_as(:'B1');
select public.mark_handed_over(zm_test.id('o5')) where false;
select zm_test.act_as(:'O');
select public.mark_handed_over(zm_test.id('o5'));
select zm_test.act_as(:'B1');
select public.complete_order(zm_test.id('o5'));
select zm_test.act_as(:'O');
select zm_test.expect_equal((select quantity::text from public.branch_stock(zm_test.id('l')) where branch_name = 'Cairo Road Shop'), '0', 'completion took the units from the chosen branch');
select zm_test.expect_equal((select quantity::text from public.branch_stock(zm_test.id('l')) where branch_name = 'Kabulonga Shop'), '7', 'the other branch is untouched');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.q($$select quantity from public.listing_stock where listing_id = (select id from ids where name = 'l')$$), '7', 'total equals the branches');
select zm_test.expect_equal(zm_test.q($$select (select sum(quantity) from public.listing_branch_stock where listing_id = (select id from ids where name = 'l'))::text = (select quantity::text from public.listing_stock where listing_id = (select id from ids where name = 'l'))$$), 'true', 'branches and total agree');

-- a listing without branch stock refuses a branch
select zm_test.act_as(:'O');
insert into ids values ('plain', null);
select zm_test.act_as_admin();
update ids set id = zm_test.fresh_listing(:'BIZ') where name = 'plain';
select zm_test.act_as(:'O');
select public.track_stock(zm_test.id('plain'), 5);
select zm_test.act_as_admin();
insert into ids values ('o7', zm_test.ask(:'B4', zm_test.id('plain'), 2));
select zm_test.act_as(:'O');
select zm_test.expect_equal(zm_test.msg(format($$select public.confirm_order(%L, 0, %L)$$, zm_test.id('o7'), zm_test.id('main'))), 'This listing does not keep stock per branch.', 'no branch on a plain listing');
select zm_test.act_as_admin();

-- the old one-item flow still behaves: the single item is reserved by one order
insert into ids values ('os', zm_test.ask(:'B1', zm_test.id('single'), 1));
select zm_test.act_as(:'O');
select public.confirm_order(zm_test.id('os'), 0);
select zm_test.act_as_admin();
select zm_test.expect_equal(public.listing_available_quantity(zm_test.id('single'))::text, '0', 'a reserved one-off item has nothing left');
select zm_test.expect_equal(public.listing_is_reserved(zm_test.id('single'))::text, 'true', 'and reads as reserved');
select zm_test.act_as(:'B2');
select zm_test.expect_equal(zm_test.msg(format($$select public.create_order(%L)$$, zm_test.id('single'))), 'This item is reserved for another buyer right now. Try again later.', 'nobody else can order it');
select zm_test.act_as_admin();
select zm_test.expect_error(format($$insert into public.listing_reservations (listing_id, order_id) select %L, id from public.orders where id = %L$$, zm_test.id('single'), zm_test.id('o7')), 'the database refuses a second exclusive reservation');

-- no direct access
select zm_test.act_as(:'B1');
select zm_test.expect_error($$select * from public.listing_branch_stock$$, 'no table access');
select zm_test.expect_error(format($$select public.stock_record_sale(%L, %L)$$, zm_test.id('l'), zm_test.id('o5')), 'internal function');
select zm_test.act_as_admin();

select 'Quantity order checks passed' as result;
rollback;
