-- Order management (migration 0009): stock control, every allowed and forbidden order
-- step, expiry, automatic completion, event history, receipts, disputes and settlement.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/orders.sql
--
-- One transaction, rolled back at the end. Races between two people at the same
-- moment cannot be tested in one transaction; see supabase/tests/local/concurrency.sh.

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

-- People: a seller, b and c buyers, d outsider, e support agent, f business staff member, m moderator
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'seller@example.test', '{"display_name":"Seller Test"}'),
  ('00000000-0000-0000-0000-00000000000b', 'buyer@example.test',  '{"display_name":"Buyer Test"}'),
  ('00000000-0000-0000-0000-00000000000c', 'other@example.test',  '{"display_name":"Other Buyer"}'),
  ('00000000-0000-0000-0000-00000000000d', 'out@example.test',    '{"display_name":"Outsider Test"}'),
  ('00000000-0000-0000-0000-00000000000e', 'support@example.test','{"display_name":"Support Test"}'),
  ('00000000-0000-0000-0000-00000000000f', 'staff@example.test',  '{"display_name":"Shop Staff"}'),
  ('00000000-0000-0000-0000-000000000001', 'mod@example.test',    '{"display_name":"Moderator Test"}'),
  ('00000000-0000-0000-0000-000000000011', 'blocked@example.test','{"display_name":"Blocked Buyer"}');
insert into public.admin_roles (user_id, role) values
  ('00000000-0000-0000-0000-00000000000e', 'support'),
  ('00000000-0000-0000-0000-000000000001', 'moderator');

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

-- Takes a fresh order to a given state using the real functions, then returns to the admin role.
create function zm_test.make_order(p_state text, p_fulfilment public.fulfilment_method default 'collection') returns uuid
language plpgsql as $$
declare
  lid uuid;
  oid uuid;
begin
  perform zm_test.act_as_admin();
  delete from public.rate_limit_log;
  lid := zm_test.fresh_listing();
  perform zm_test.act_as('00000000-0000-0000-0000-00000000000b');
  oid := (public.create_order(lid, p_fulfilment, case when p_fulfilment = 'delivery' then 'Near the blue gate, Kabulonga' end)).id;
  if p_state = 'cancelled' then
    perform public.cancel_order(oid, 'changed my mind');
  elsif p_state <> 'requested' then
    perform zm_test.act_as('00000000-0000-0000-0000-00000000000a');
    perform public.confirm_order(oid, 0);
    if p_state = 'handed_over' then
      perform public.mark_handed_over(oid);
    elsif p_state = 'completed' then
      perform zm_test.act_as('00000000-0000-0000-0000-00000000000b');
      perform public.complete_order(oid);
    elsif p_state = 'disputed' then
      perform zm_test.act_as('00000000-0000-0000-0000-00000000000b');
      perform public.open_dispute(oid, 'Item not as described', 'Cracked');
    end if;
  end if;
  perform zm_test.act_as_admin();
  return oid;
end $$;

-- Tries one action as one person. Returns 'ok' or the error code.
create function zm_test.try_action(p_actor uuid, p_action text, p_order uuid) returns text
language plpgsql as $$
begin
  perform zm_test.act_as(p_actor);
  begin
    if p_action = 'confirm' then perform public.confirm_order(p_order, 0);
    elsif p_action = 'decline' then perform public.decline_order(p_order, 'not available');
    elsif p_action = 'cancel' then perform public.cancel_order(p_order, 'changed plans');
    elsif p_action = 'handover' then perform public.mark_handed_over(p_order);
    elsif p_action = 'complete' then perform public.complete_order(p_order);
    elsif p_action = 'dispute' then perform public.open_dispute(p_order, 'Item not as described', 'Details');
    else raise exception 'Unknown action in test: %', p_action;
    end if;
  exception when others then
    perform zm_test.act_as_admin();
    return sqlstate;
  end;
  perform zm_test.act_as_admin();
  return 'ok';
end $$;

create function zm_test.order_state(p_order uuid) returns text
language sql as $$
  select status::text || coalesce('/' || cancel_kind, '') from public.orders where id = p_order;
$$;

create function zm_test.event_trail(p_order uuid) returns text
language sql as $$
  select coalesce(string_agg(event, ',' order by id), '') from public.order_events where order_id = p_order;
$$;

grant execute on all functions in schema zm_test to anon, authenticated, service_role;
create temp table zm_ids (name text primary key, id uuid);
grant all on zm_ids to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 1. Placing an order
-- ---------------------------------------------------------------------------
select zm_test.act_as_admin();
insert into zm_ids values ('l1', zm_test.fresh_listing(500));
insert into zm_ids values ('draft', (select id from public.listings where false) );
delete from zm_ids where name = 'draft';
insert into zm_ids values ('l_sold', zm_test.fresh_listing(300));
update public.listings set status = 'sold' where id = (select id from zm_ids where name = 'l_sold');

select zm_test.act_as_guest();
select zm_test.expect_error(format($$select public.create_order(%L)$$, (select id from zm_ids where name = 'l1')), 'guest placing an order');
select zm_test.expect_error($$select 1 from public.orders$$, 'guest reading orders');
select zm_test.expect_error($$select 1 from public.order_events$$, 'guest reading order events');
select zm_test.expect_error($$select public.run_order_maintenance()$$, 'guest running maintenance');

select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_error(format($$select public.create_order(%L)$$, (select id from zm_ids where name = 'l1')), 'ordering your own listing');

select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_error(format($$select public.create_order(%L)$$, (select id from zm_ids where name = 'l_sold')), 'ordering a sold listing');
select zm_test.expect_error($$select public.create_order('99999999-9999-9999-9999-999999999999')$$, 'ordering a listing that does not exist');
select zm_test.expect_error(format($$select public.create_order(%L, 'delivery')$$, (select id from zm_ids where name = 'l1')), 'delivery without an address');
select zm_test.expect_error(format($$select public.create_order(%L, 'delivery', '   ')$$, (select id from zm_ids where name = 'l1')), 'delivery with a blank address');
select zm_test.expect_error(format($$select public.create_order(%L, 'collection', null, %L)$$, (select id from zm_ids where name = 'l1'), repeat('x', 301)), 'note over 300 characters');
select zm_test.expect_error(format($$select public.create_order(%L, 'delivery', %L)$$, (select id from zm_ids where name = 'l1'), repeat('x', 301)), 'address over 300 characters');

-- A hidden listing (not approved) cannot be ordered either.
select zm_test.act_as_admin();
insert into zm_ids values ('l_pending', zm_test.fresh_listing(200));
update public.listings set moderation_status = 'pending' where id = (select id from zm_ids where name = 'l_pending');
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_error(format($$select public.create_order(%L)$$, (select id from zm_ids where name = 'l_pending')), 'ordering an unapproved listing');

-- A buyer the seller has blocked cannot order.
select zm_test.act_as_admin();
insert into public.blocks (blocker_id, blocked_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000011');
select zm_test.act_as('00000000-0000-0000-0000-000000000011');
select zm_test.expect_error(format($$select public.create_order(%L)$$, (select id from zm_ids where name = 'l1')), 'blocked buyer ordering');

-- Placing a good order: a snapshot, an expiry and the first event.
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
insert into zm_ids values ('o_b', (public.create_order((select id from zm_ids where name = 'l1'), 'collection', 'ignored for collection', 'Can I come after 5pm?')).id);
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_b')), 'requested', 'new order is requested');
select zm_test.expect_equal((select (expires_at > now() + interval '47 hours' and expires_at < now() + interval '49 hours')::text from public.orders where id = (select id from zm_ids where name = 'o_b')),
  'true', 'request expires after about 48 hours');
select zm_test.expect_equal((select delivery_address from public.orders where id = (select id from zm_ids where name = 'o_b')), null, 'a collection order keeps no delivery address');
select zm_test.expect_equal((select buyer_note || '|' || buyer_name || '|' || seller_name from public.orders where id = (select id from zm_ids where name = 'o_b')),
  'Can I come after 5pm?|Buyer Test|Seller Test', 'note and name snapshots');
select zm_test.expect_equal(zm_test.event_trail((select id from zm_ids where name = 'o_b')), 'requested', 'first event');

select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_error(format($$select public.create_order(%L)$$, (select id from zm_ids where name = 'l1')), 'a second open order for the same item');

-- Direct writes are not possible; everything goes through the functions.
select zm_test.expect_error(format($$update public.orders set status = 'completed' where id = %L$$, (select id from zm_ids where name = 'o_b')), 'buyer updating an order directly');
select zm_test.expect_error(format($$update public.orders set item_price_zmw = 1 where id = %L$$, (select id from zm_ids where name = 'o_b')), 'buyer changing the price');
select zm_test.expect_error(format($$delete from public.orders where id = %L$$, (select id from zm_ids where name = 'o_b')), 'buyer deleting an order');
select zm_test.expect_error($$insert into public.orders (listing_id, buyer_id, seller_id, item_title, item_price_zmw) values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'x', 1)$$, 'inserting an order directly');
select zm_test.expect_error($$insert into public.order_events (order_id, actor_role, event) select id, 'buyer', 'completed' from public.orders limit 1$$, 'writing an event directly');
select zm_test.expect_error($$update public.order_events set note = 'edited'$$, 'editing the history');
select zm_test.expect_error($$delete from public.order_events$$, 'deleting the history');
select zm_test.expect_error($$select 1 from public.listing_reservations$$, 'reading reservations directly');
select zm_test.expect_error(format($$insert into public.listing_reservations (listing_id, order_id) values (%L, %L)$$, (select id from zm_ids where name = 'l1'), (select id from zm_ids where name = 'o_b')), 'creating a reservation directly');

-- Only people on the order see it.
select zm_test.act_as('00000000-0000-0000-0000-00000000000d');
select zm_test.expect_equal((select count(*)::text from public.orders), '0', 'an outsider sees no orders');
select zm_test.expect_equal((select count(*)::text from public.order_events), '0', 'an outsider sees no order history');
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_equal((select count(*)::text from public.orders where id = (select id from zm_ids where name = 'o_b')), '1', 'the seller sees the order');
select zm_test.expect_equal((select count(*)::text from public.order_events where order_id = (select id from zm_ids where name = 'o_b')), '1', 'the seller sees the history');
select zm_test.act_as('00000000-0000-0000-0000-00000000000e', 'aal1');
select zm_test.expect_equal((select count(*)::text from public.order_events where order_id = (select id from zm_ids where name = 'o_b')), '0', 'support staff without two-factor see nothing');
select zm_test.act_as('00000000-0000-0000-0000-00000000000e', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.order_events where order_id = (select id from zm_ids where name = 'o_b')), '1', 'support staff with two-factor see the history');

-- ---------------------------------------------------------------------------
-- 2. Stock control: one item, one reservation
-- ---------------------------------------------------------------------------
-- Two buyers ask for the same item. Asking does not reserve it.
select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
insert into zm_ids values ('o_c', (public.create_order((select id from zm_ids where name = 'l1'))).id);
select zm_test.act_as_guest();
select zm_test.expect_equal((select count(*)::text from public.public_listings where id = (select id from zm_ids where name = 'l1')), '1', 'a requested item is still for sale');
select zm_test.expect_equal(public.listing_is_reserved((select id from zm_ids where name = 'l1'))::text, 'false', 'not reserved by a request');

-- The seller accepts buyer b: the item is reserved and buyer c's request is turned away.
select zm_test.act_as('00000000-0000-0000-0000-00000000000d');
select zm_test.expect_error(format($$select public.confirm_order(%L, 0)$$, (select id from zm_ids where name = 'o_b')), 'outsider confirming an order');
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_error(format($$select public.confirm_order(%L, 0)$$, (select id from zm_ids where name = 'o_b')), 'buyer confirming their own order');
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select public.confirm_order((select id from zm_ids where name = 'o_b'), 0);

select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_b')), 'confirmed', 'b is confirmed');
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_c')), 'cancelled/declined', 'c is turned away automatically');
select zm_test.expect_equal((select cancelled_by from public.orders where id = (select id from zm_ids where name = 'o_c')), 'system', 'turned away by the system');
select zm_test.expect_equal(zm_test.event_trail((select id from zm_ids where name = 'o_c')), 'requested,declined', 'c history');
select zm_test.expect_equal((select count(*)::text from public.listing_reservations where listing_id = (select id from zm_ids where name = 'l1')), '1', 'exactly one reservation');

select zm_test.act_as_guest();
select zm_test.expect_equal((select count(*)::text from public.public_listings where id = (select id from zm_ids where name = 'l1')), '0', 'reserved item is hidden from browsing');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_term => 'Item')), (select count(*)::text from public.public_listings where title like 'Item %'), 'search agrees');
select zm_test.expect_equal(public.listing_is_reserved((select id from zm_ids where name = 'l1'))::text, 'true', 'listing is reported as reserved');
select zm_test.expect_equal((select count(*)::text from public.public_listing_details where id = (select id from zm_ids where name = 'l1')), '1', 'the listing page still opens');

select zm_test.act_as('00000000-0000-0000-0000-00000000000d');
select zm_test.expect_error(format($$select public.create_order(%L)$$, (select id from zm_ids where name = 'l1')), 'a third buyer ordering a reserved item');
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_error(format($$select public.confirm_order(%L, 0)$$, (select id from zm_ids where name = 'o_c')), 'confirming an order that was turned away');

-- The database itself refuses a second reservation, whatever the code does.
select zm_test.act_as_admin();
select zm_test.expect_error(format($$insert into public.listing_reservations (listing_id, order_id) values (%L, %L)$$, (select id from zm_ids where name = 'l1'), (select id from zm_ids where name = 'o_c')), 'a second reservation for one item');
select zm_test.expect_error(format($$insert into public.orders (listing_id, buyer_id, seller_id, item_title, item_price_zmw)
  values (%L, '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000a', 'x', 1)$$, (select id from zm_ids where name = 'l1')),
  'two open orders for one buyer and item at the database level');

-- The buyer cancels: the item is released, and someone else can now ask for it.
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select public.cancel_order((select id from zm_ids where name = 'o_b'), 'Found it cheaper elsewhere');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_b')), 'cancelled/cancelled', 'b cancelled');
select zm_test.expect_equal((select cancelled_by || ': ' || cancelled_reason from public.orders where id = (select id from zm_ids where name = 'o_b')), 'buyer: Found it cheaper elsewhere', 'reason is kept');
select zm_test.expect_equal((select count(*)::text from public.listing_reservations), '0', 'reservation released');
select zm_test.act_as_guest();
select zm_test.expect_equal((select count(*)::text from public.public_listings where id = (select id from zm_ids where name = 'l1')), '1', 'item is back in browsing');
select zm_test.act_as('00000000-0000-0000-0000-00000000000d');
insert into zm_ids values ('o_d', (public.create_order((select id from zm_ids where name = 'l1'))).id);
-- b can ask again after cancelling.
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
insert into zm_ids values ('o_b2', (public.create_order((select id from zm_ids where name = 'l1'))).id);

-- Completing sells the item and nobody can buy it again.
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select public.confirm_order((select id from zm_ids where name = 'o_b2'), 0);
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_d')), 'cancelled/declined', 'd turned away when b2 was confirmed');
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select public.complete_order((select id from zm_ids where name = 'o_b2'));
select zm_test.act_as_admin();
select zm_test.expect_equal((select status::text from public.listings where id = (select id from zm_ids where name = 'l1')), 'sold', 'completing marks the item sold');
select zm_test.expect_equal((select count(*)::text from public.listing_reservations), '0', 'no reservation left after completing');
select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
select zm_test.expect_error(format($$select public.create_order(%L)$$, (select id from zm_ids where name = 'l1')), 'buying an item that is sold');

-- ---------------------------------------------------------------------------
-- 3. Every step, for every person, in every state
-- ---------------------------------------------------------------------------
-- 6 states x 6 actions x 3 people = 108 checks. Anything not listed as allowed must be refused,
-- and refused for the right kind of reason (not, say, a typing mistake in the test).
select zm_test.act_as_admin();
do $$
declare
  allowed text[] := array[
    'requested|confirm|seller', 'requested|decline|seller', 'requested|cancel|buyer',
    'confirmed|cancel|buyer', 'confirmed|cancel|seller', 'confirmed|handover|seller',
    'confirmed|complete|buyer', 'confirmed|dispute|buyer', 'confirmed|dispute|seller',
    'handed_over|complete|buyer', 'handed_over|dispute|buyer', 'handed_over|dispute|seller',
    'completed|dispute|buyer', 'completed|dispute|seller'];
  people text[] := array['buyer', 'seller', 'outsider'];
  actors uuid[] := array['00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000d']::uuid[];
  s text;
  a text;
  i integer;
  oid uuid;
  result text;
  checks integer := 0;
begin
  foreach s in array array['requested', 'confirmed', 'handed_over', 'completed', 'cancelled', 'disputed'] loop
    foreach a in array array['confirm', 'decline', 'cancel', 'handover', 'complete', 'dispute'] loop
      for i in 1..3 loop
        oid := zm_test.make_order(s);
        result := zm_test.try_action(actors[i], a, oid);
        checks := checks + 1;
        if (s || '|' || a || '|' || people[i]) = any (allowed) then
          if result <> 'ok' then
            raise exception 'Should be allowed but failed (%): % may % an order that is %', result, people[i], a, s;
          end if;
        else
          if result = 'ok' then
            raise exception 'Should be refused but worked: % %ing an order that is %', people[i], a, s;
          end if;
          if result not in ('23514', '42501', 'P0002') then
            raise exception 'Refused for the wrong reason (%): % %ing an order that is %', result, people[i], a, s;
          end if;
        end if;
      end loop;
    end loop;
  end loop;
  raise notice 'checked % order steps', checks;
end $$;

-- Old app versions still call set_order_status. It follows the same rules.
select zm_test.act_as_admin();
insert into zm_ids values ('o_old', zm_test.make_order('requested'));
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select public.set_order_status((select id from zm_ids where name = 'o_old'), 'cancelled', 'No longer selling');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_old')), 'cancelled/declined', 'old call: seller cancelling a request declines it');
insert into zm_ids values ('o_old2', zm_test.make_order('confirmed'));
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_error(format($$select public.set_order_status(%L, 'disputed')$$, (select id from zm_ids where name = 'o_old2')), 'old call: moving to disputed this way');
select zm_test.expect_error(format($$select public.set_order_status(%L, 'requested')$$, (select id from zm_ids where name = 'o_old2')), 'old call: moving back to requested');
select public.set_order_status((select id from zm_ids where name = 'o_old2'), 'completed');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_old2')), 'completed', 'old call: buyer completing');

-- ---------------------------------------------------------------------------
-- 4. Delivery, address and the disclosed fee
-- ---------------------------------------------------------------------------
select zm_test.act_as_admin();
insert into zm_ids values ('o_del', zm_test.make_order('requested', 'delivery'));
select zm_test.expect_equal((select delivery_address from public.orders where id = (select id from zm_ids where name = 'o_del')), 'Near the blue gate, Kabulonga', 'delivery address is kept');
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_error(format($$select public.confirm_order(%L, -5)$$, (select id from zm_ids where name = 'o_del')), 'negative delivery fee');
select zm_test.expect_error(format($$select public.confirm_order(%L, 100001)$$, (select id from zm_ids where name = 'o_del')), 'delivery fee over the cap');
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_error(format($$select public.confirm_order(%L, 20)$$, (select id from zm_ids where name = 'o_del')), 'buyer setting a delivery fee');
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select public.confirm_order((select id from zm_ids where name = 'o_del'), 150);
select zm_test.act_as_admin();
select zm_test.expect_equal((select delivery_fee_zmw::text || '|' || total_zmw::text from public.orders where id = (select id from zm_ids where name = 'o_del')), '150.00|650.00', 'fee is added to the total');
select zm_test.expect_equal((select note from public.order_events where order_id = (select id from zm_ids where name = 'o_del') and event = 'confirmed'), 'Delivery fee K150', 'fee is written to the history');

insert into zm_ids values ('o_col', zm_test.make_order('requested'));
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_error(format($$select public.confirm_order(%L, 20)$$, (select id from zm_ids where name = 'o_col')), 'a delivery fee on a collection order');

-- ---------------------------------------------------------------------------
-- 5. Expiry
-- ---------------------------------------------------------------------------
select zm_test.act_as_admin();
-- An unanswered request expires.
insert into zm_ids values ('o_exp1', zm_test.make_order('requested'));
-- A confirmed order nobody collects expires and frees the item.
insert into zm_ids values ('o_exp2', zm_test.make_order('confirmed'));
-- Already handed over: does not expire even if its deadline were old.
insert into zm_ids values ('o_exp3', zm_test.make_order('handed_over'));
-- In dispute: does not expire.
insert into zm_ids values ('o_exp4', zm_test.make_order('disputed'));
-- Not yet due: stays.
insert into zm_ids values ('o_exp5', zm_test.make_order('requested'));
update public.orders set expires_at = now() - interval '1 hour'
 where id in (select id from zm_ids where name in ('o_exp1', 'o_exp2', 'o_exp3', 'o_exp4'));

select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_error($$select public.run_order_maintenance()$$, 'ordinary user running the order job');
select zm_test.expect_error($$select public.expire_overdue_orders()$$, 'ordinary user expiring orders');
select zm_test.act_as('00000000-0000-0000-0000-00000000000e', 'aal2');
select zm_test.expect_error($$select public.run_order_maintenance()$$, 'staff running the order job');

select zm_test.act_as_service();
select zm_test.expect_equal((select public.run_order_maintenance()->>'expired'), '2', 'two orders expire');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_exp1')), 'cancelled/expired', 'unanswered request expired');
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_exp2')), 'cancelled/expired', 'uncollected order expired');
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_exp3')), 'confirmed', 'handed-over order did not expire');
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_exp4')), 'disputed', 'disputed order did not expire');
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_exp5')), 'requested', 'order not yet due did not expire');
select zm_test.expect_equal(zm_test.event_trail((select id from zm_ids where name = 'o_exp2')), 'requested,confirmed,expired', 'expiry is in the history');
select zm_test.expect_equal((select cancelled_by from public.orders where id = (select id from zm_ids where name = 'o_exp2')), 'system', 'expiry is by the system');
select zm_test.expect_equal((select count(*)::text from public.listing_reservations where order_id = (select id from zm_ids where name = 'o_exp2')), '0', 'expiry released the item');
select zm_test.act_as_service();
select zm_test.expect_equal((select public.run_order_maintenance()->>'expired'), '0', 'running it again expires nothing more');

-- Even without the scheduled job, a stale reservation does not block the next buyer.
select zm_test.act_as_admin();
insert into zm_ids values ('o_stale', zm_test.make_order('confirmed'));
update public.orders set expires_at = now() - interval '1 minute' where id = (select id from zm_ids where name = 'o_stale');
insert into zm_ids values ('l_stale', (select listing_id from public.orders where id = (select id from zm_ids where name = 'o_stale')));
select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
insert into zm_ids values ('o_after_stale', (public.create_order((select id from zm_ids where name = 'l_stale'))).id);
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_stale')), 'cancelled/expired', 'stale reservation released on the next request');
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_after_stale')), 'requested', 'the next buyer got through');

-- A seller answering an overdue request finds it already expired, and the item is not reserved.
insert into zm_ids values ('o_late', zm_test.make_order('requested'));
update public.orders set expires_at = now() - interval '1 minute' where id = (select id from zm_ids where name = 'o_late');
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_equal((select (public.confirm_order((select id from zm_ids where name = 'o_late'), 0)).status::text), 'cancelled', 'late confirmation comes back expired');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_late')), 'cancelled/expired', 'late confirmation did not reserve');
select zm_test.expect_equal((select count(*)::text from public.listing_reservations where order_id = (select id from zm_ids where name = 'o_late')), '0', 'no reservation from a late confirmation');

-- ---------------------------------------------------------------------------
-- 6. Automatic completion after hand-over
-- ---------------------------------------------------------------------------
select zm_test.act_as_admin();
insert into zm_ids values ('o_auto1', zm_test.make_order('handed_over'));
insert into zm_ids values ('o_auto2', zm_test.make_order('handed_over'));
insert into zm_ids values ('o_auto3', zm_test.make_order('confirmed'));
insert into zm_ids values ('o_auto4', zm_test.make_order('handed_over'));
update public.orders set handed_over_at = now() - interval '4 days' where id = (select id from zm_ids where name = 'o_auto1');
update public.orders set handed_over_at = now() - interval '1 day' where id = (select id from zm_ids where name = 'o_auto2');
-- o_auto4: handed over long ago but disputed in the meantime.
update public.orders set handed_over_at = now() - interval '9 days' where id = (select id from zm_ids where name = 'o_auto4');
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select public.open_dispute((select id from zm_ids where name = 'o_auto4'), 'Item not as described', 'It broke');

select zm_test.act_as_service();
select zm_test.expect_equal((select public.run_order_maintenance()->>'auto_completed'), '1', 'only the overdue hand-over completes by itself');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_auto1')), 'completed', 'overdue hand-over completed');
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_auto2')), 'confirmed', 'recent hand-over left alone');
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_auto3')), 'confirmed', 'order never handed over left alone');
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_auto4')), 'disputed', 'disputed order is not completed for the buyer');
select zm_test.expect_equal(zm_test.event_trail((select id from zm_ids where name = 'o_auto1')), 'requested,confirmed,handed_over,auto_completed', 'automatic completion is in the history');
select zm_test.expect_equal((select l.status::text from public.listings l join public.orders o on o.listing_id = l.id where o.id = (select id from zm_ids where name = 'o_auto1')), 'sold', 'item sold by automatic completion');

-- ---------------------------------------------------------------------------
-- 7. When the item stops being for sale
-- ---------------------------------------------------------------------------
select zm_test.act_as_admin();
insert into zm_ids values ('o_g1', zm_test.make_order('confirmed'));
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_error(format($$update public.listings set status = 'sold' where id = (select listing_id from public.orders where id = %L)$$, (select id from zm_ids where name = 'o_g1')),
  'marking an item sold while it has a confirmed order');
select zm_test.expect_error(format($$update public.listings set status = 'unavailable' where id = (select listing_id from public.orders where id = %L)$$, (select id from zm_ids where name = 'o_g1')),
  'pausing an item while it has a confirmed order');

-- Staff removing the listing closes the order and frees the reservation.
select zm_test.act_as_admin();
insert into zm_ids values ('l_g1', (select listing_id from public.orders where id = (select id from zm_ids where name = 'o_g1')));
select zm_test.act_as('00000000-0000-0000-0000-000000000001', 'aal2');
select public.remove_listing((select id from zm_ids where name = 'l_g1'), 'Prohibited item');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_g1')), 'cancelled/cancelled', 'removal cancels the confirmed order');
select zm_test.expect_equal((select cancelled_reason from public.orders where id = (select id from zm_ids where name = 'o_g1')), 'This listing was removed.', 'with the reason');
select zm_test.expect_equal((select count(*)::text from public.listing_reservations where order_id = (select id from zm_ids where name = 'o_g1')), '0', 'and frees the reservation');

-- Pausing an item that only has open requests turns those requests away.
insert into zm_ids values ('o_g2', zm_test.make_order('requested'));
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
update public.listings set status = 'unavailable' where id = (select listing_id from public.orders where id = (select id from zm_ids where name = 'o_g2'));
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_g2')), 'cancelled/declined', 'pausing declines open requests');
select zm_test.expect_equal(zm_test.event_trail((select id from zm_ids where name = 'o_g2')), 'requested,declined', 'and says so in the history');

-- The seller can mark an item sold once the confirmed order is cancelled.
insert into zm_ids values ('o_g3', zm_test.make_order('confirmed'));
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select public.cancel_order((select id from zm_ids where name = 'o_g3'), 'Sold it to someone else');
update public.listings set status = 'sold' where id = (select listing_id from public.orders where id = (select id from zm_ids where name = 'o_g3'));

-- ---------------------------------------------------------------------------
-- 8. Event history
-- ---------------------------------------------------------------------------
select zm_test.act_as_admin();
insert into zm_ids values ('o_hist', zm_test.make_order('handed_over'));
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select public.complete_order((select id from zm_ids where name = 'o_hist'));
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.event_trail((select id from zm_ids where name = 'o_hist')), 'requested,confirmed,handed_over,completed', 'full journey history');
select zm_test.expect_equal((select string_agg(actor_role, ',' order by id) from public.order_events where order_id = (select id from zm_ids where name = 'o_hist')),
  'buyer,seller,seller,buyer', 'who did each step');
select zm_test.expect_equal((select count(*)::text from public.order_events where order_id = (select id from zm_ids where name = 'o_hist') and actor_id is null), '0', 'people are recorded on their own steps');
select zm_test.act_as('00000000-0000-0000-0000-00000000000d');
select zm_test.expect_equal((select count(*)::text from public.order_events where order_id = (select id from zm_ids where name = 'o_hist')), '0', 'an outsider cannot read it');
select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
select zm_test.expect_equal((select count(*)::text from public.order_events where order_id = (select id from zm_ids where name = 'o_hist')), '0', 'a buyer of another item cannot read it');

-- ---------------------------------------------------------------------------
-- 9. Receipts
-- ---------------------------------------------------------------------------
select zm_test.act_as_admin();
insert into zm_ids values ('o_rcpt_early', zm_test.make_order('confirmed'));
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_error(format($$select public.order_receipt(%L)$$, (select id from zm_ids where name = 'o_rcpt_early')), 'receipt before completion');
select zm_test.act_as('00000000-0000-0000-0000-00000000000d');
select zm_test.expect_error(format($$select public.order_receipt(%L)$$, (select id from zm_ids where name = 'o_hist')), 'outsider reading a receipt');
select zm_test.act_as_guest();
select zm_test.expect_error(format($$select public.order_receipt(%L)$$, (select id from zm_ids where name = 'o_hist')), 'guest reading a receipt');

select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_equal((select public.order_receipt((select id from zm_ids where name = 'o_hist'))->>'total_zmw'), '500.00', 'receipt total');
select zm_test.expect_equal((select public.order_receipt((select id from zm_ids where name = 'o_hist'))->>'buyer'), 'Buyer Test', 'receipt buyer');
select zm_test.expect_equal((select (public.order_receipt((select id from zm_ids where name = 'o_hist'))->>'payment_note') like '%did not take, hold or confirm any payment%')::text, 'true', 'receipt says no payment was handled');
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_equal((select public.order_receipt((select id from zm_ids where name = 'o_hist'))->>'receipt_number'), (select ref from public.orders where id = (select id from zm_ids where name = 'o_hist')), 'seller can read it');
select zm_test.act_as('00000000-0000-0000-0000-00000000000e', 'aal2');
select zm_test.expect_equal((select public.order_receipt((select id from zm_ids where name = 'o_hist'))->>'order_status'), 'completed', 'support can read it');

-- A receipt does not change when the seller later edits the listing or their name.
select zm_test.act_as_admin();
update public.listings set title = 'Completely different title', price_zmw = 9999 where id = (select listing_id from public.orders where id = (select id from zm_ids where name = 'o_hist'));
update public.profiles set display_name = 'Renamed Seller' where id = '00000000-0000-0000-0000-00000000000a';
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_equal((select public.order_receipt((select id from zm_ids where name = 'o_hist'))->>'item'), (select item_title from public.orders where id = (select id from zm_ids where name = 'o_hist')), 'item name is as agreed');
select zm_test.expect_equal((select public.order_receipt((select id from zm_ids where name = 'o_hist'))->>'seller'), 'Seller Test', 'seller name is as it was');
select zm_test.expect_equal((select public.order_receipt((select id from zm_ids where name = 'o_hist'))->>'total_zmw'), '500.00', 'price is as agreed');
select zm_test.act_as_admin();
update public.profiles set display_name = 'Seller Test' where id = '00000000-0000-0000-0000-00000000000a';

-- A receipt for a delivery order shows the disclosed fee.
insert into zm_ids values ('o_rcpt_del', zm_test.make_order('requested', 'delivery'));
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select public.confirm_order((select id from zm_ids where name = 'o_rcpt_del'), 75);
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select public.complete_order((select id from zm_ids where name = 'o_rcpt_del'));
select zm_test.expect_equal((select public.order_receipt((select id from zm_ids where name = 'o_rcpt_del'))->>'delivery_fee_zmw'), '75.00', 'receipt shows the delivery fee');
select zm_test.expect_equal((select public.order_receipt((select id from zm_ids where name = 'o_rcpt_del'))->>'total_zmw'), '575.00', 'and the total');

-- ---------------------------------------------------------------------------
-- 10. Disputes and settlement
-- ---------------------------------------------------------------------------
select zm_test.act_as_admin();
insert into zm_ids values ('o_disp', zm_test.make_order('disputed'));
select zm_test.expect_equal(zm_test.event_trail((select id from zm_ids where name = 'o_disp')), 'requested,confirmed,disputed', 'dispute is in the history');
select zm_test.expect_equal((select count(*)::text from public.listing_reservations where order_id = (select id from zm_ids where name = 'o_disp')), '1', 'a disputed order keeps the item reserved');
select zm_test.expect_equal((select expires_at::text from public.orders where id = (select id from zm_ids where name = 'o_disp')), null, 'a disputed order has no deadline');

select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_error(format($$select public.staff_settle_order(%L, 'completed', 'x')$$, (select id from zm_ids where name = 'o_disp')), 'buyer settling their own dispute');
select zm_test.act_as('00000000-0000-0000-0000-00000000000e', 'aal1');
select zm_test.expect_error(format($$select public.staff_settle_order(%L, 'completed', 'x')$$, (select id from zm_ids where name = 'o_disp')), 'support without two-factor settling');
select zm_test.act_as('00000000-0000-0000-0000-000000000001', 'aal2');
select zm_test.expect_error(format($$select public.staff_settle_order(%L, 'completed', 'x')$$, (select id from zm_ids where name = 'o_disp')), 'a moderator settling (wrong role)');
select zm_test.act_as('00000000-0000-0000-0000-00000000000e', 'aal2');
select zm_test.expect_error(format($$select public.staff_settle_order(%L, 'refunded', 'x')$$, (select id from zm_ids where name = 'o_disp')), 'settling with an unknown outcome');
select zm_test.expect_error(format($$select public.staff_settle_order(%L, 'completed', 'x')$$, (select id from zm_ids where name = 'o_hist')), 'settling an order that is not disputed');

select public.staff_settle_order((select id from zm_ids where name = 'o_disp'), 'completed', 'Both sides confirmed the item changed hands.');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_disp')), 'completed', 'settled as completed');
select zm_test.expect_equal((select l.status::text from public.listings l join public.orders o on o.listing_id = l.id where o.id = (select id from zm_ids where name = 'o_disp')), 'sold', 'item sold');
select zm_test.expect_equal((select count(*)::text from public.listing_reservations where order_id = (select id from zm_ids where name = 'o_disp')), '0', 'reservation freed');
select zm_test.expect_equal(zm_test.event_trail((select id from zm_ids where name = 'o_disp')), 'requested,confirmed,disputed,settled_by_staff', 'settlement in history');
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action = 'order.settled' and target_id = (select id::text from zm_ids where name = 'o_disp')), '1', 'settlement is audited');

insert into zm_ids values ('o_disp2', zm_test.make_order('disputed'));
select zm_test.act_as('00000000-0000-0000-0000-00000000000e', 'aal2');
select public.staff_settle_order((select id from zm_ids where name = 'o_disp2'), 'cancelled', 'Item was never handed over.');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.order_state((select id from zm_ids where name = 'o_disp2')), 'cancelled/cancelled', 'settled as cancelled');
select zm_test.expect_equal((select cancelled_by from public.orders where id = (select id from zm_ids where name = 'o_disp2')), 'staff', 'by staff');
select zm_test.expect_equal((select l.status::text from public.listings l join public.orders o on o.listing_id = l.id where o.id = (select id from zm_ids where name = 'o_disp2')), 'active', 'item is for sale again');
select zm_test.expect_equal((select count(*)::text from public.listing_reservations where order_id = (select id from zm_ids where name = 'o_disp2')), '0', 'reservation freed');

-- A dispute can still be opened on a completed order, and the receipt stays available.
insert into zm_ids values ('o_disp3', zm_test.make_order('completed'));
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select public.open_dispute((select id from zm_ids where name = 'o_disp3'), 'Item not as described', 'Stopped working');
select zm_test.expect_equal((select public.order_receipt((select id from zm_ids where name = 'o_disp3'))->>'order_status'), 'disputed', 'receipt remains after a dispute');

-- ---------------------------------------------------------------------------
-- 11. Rate limit on buy requests
-- ---------------------------------------------------------------------------
select zm_test.act_as_admin();
delete from public.rate_limit_log;
do $$
declare
  ids uuid[] := '{}';
  i integer;
begin
  for i in 1..11 loop
    ids := ids || zm_test.fresh_listing();
  end loop;
  perform set_config('zm.listings', array_to_string(ids, ','), true);
end $$;
select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
do $$
declare
  ids uuid[] := string_to_array(current_setting('zm.listings'), ',')::uuid[];
  i integer;
begin
  for i in 1..10 loop
    perform public.create_order(ids[i]);
  end loop;
end $$;
select zm_test.expect_error(format($$select public.create_order(%L)$$, (string_to_array(current_setting('zm.listings'), ','))[11]), 'eleventh buy request within the hour');

-- ---------------------------------------------------------------------------
-- 12. Business orders
-- ---------------------------------------------------------------------------
select zm_test.act_as_admin();
delete from public.rate_limit_log;
insert into public.businesses (owner_id, name, slug) values ('00000000-0000-0000-0000-00000000000a', 'Kabulonga Phones', 'kabulonga-phones');
insert into public.business_members (business_id, user_id, role)
  select id, '00000000-0000-0000-0000-00000000000f', 'staff' from public.businesses where slug = 'kabulonga-phones';
insert into zm_ids values ('l_biz', zm_test.fresh_listing(800, (select id from public.businesses where slug = 'kabulonga-phones')));
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
insert into zm_ids values ('o_biz', (public.create_order((select id from zm_ids where name = 'l_biz'))).id);
select zm_test.act_as_admin();
select zm_test.expect_equal((select seller_name from public.orders where id = (select id from zm_ids where name = 'o_biz')), 'Kabulonga Phones', 'a business order carries the business name');
select zm_test.act_as('00000000-0000-0000-0000-00000000000d');
select zm_test.expect_error(format($$select public.confirm_order(%L, 0)$$, (select id from zm_ids where name = 'o_biz')), 'an outsider confirming a business order');
select zm_test.act_as('00000000-0000-0000-0000-00000000000f');
select zm_test.expect_equal((select count(*)::text from public.orders where id = (select id from zm_ids where name = 'o_biz')), '1', 'business staff can see the order');
select public.confirm_order((select id from zm_ids where name = 'o_biz'), 0);
select public.mark_handed_over((select id from zm_ids where name = 'o_biz'));
select zm_test.expect_error(format($$select public.complete_order(%L)$$, (select id from zm_ids where name = 'o_biz')), 'business staff completing for the buyer');

select 'Order checks passed' as result;
rollback;
