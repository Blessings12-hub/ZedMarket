-- Analytics (migration 0016): seller and business numbers, listing performance, sales reports, engagement,
-- platform, trust and finance statistics. Who may see what, and that the figures are right.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/analytics.sql

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




-- Fixture. Dates are relative to now so the test never goes stale. Orders are written directly with triggers
-- switched off, because the order flow itself is covered by orders.sql.
select zm_test.act_as_admin();
insert into zm_ids values ('l1', zm_test.fresh_listing(100));
insert into zm_ids values ('l2', zm_test.fresh_listing(200));
insert into zm_ids values ('lb', zm_test.fresh_listing(300, :'BIZ'));
set session_replication_role = replica;
insert into public.orders (id, listing_id, buyer_id, seller_id, business_id, item_title, item_price_zmw, fulfilment, delivery_fee_zmw, delivery_address,
                           status, cancel_kind, buyer_name, seller_name, created_at, confirmed_at, completed_at)
select gen_random_uuid(), (select id from zm_ids where name = v.l), v.buyer::uuid, :'S', v.biz::uuid, 'Item', v.price, v.ful::public.fulfilment_method, v.fee,
       case when v.ful = 'delivery' then 'Plot 1, Kabulonga' end, v.st::public.order_status, v.ck, 'Buyer', 'Seller',
       now() - v.created, case when v.conf is not null then now() - v.created + v.conf end,
       case when v.comp is not null then now() - v.created + v.conf + v.comp end
  from (values
    ('l1', :'B', null, 100, 'collection', 0,  'completed', null,       interval '5 days', interval '2 hours', interval '48 hours'),
    ('l2', :'C', null, 200, 'delivery',   20, 'completed', null,       interval '4 days', interval '4 hours', interval '24 hours'),
    ('lb', :'B', :'BIZ', 300, 'collection', 0, 'completed', null,      interval '3 days', interval '1 hour',  interval '10 hours'),
    ('l2', :'B', null, 200, 'collection', 0,  'cancelled', 'declined', interval '2 days', null, null),
    ('l1', :'B', null, 100, 'collection', 0,  'completed', null,       interval '1 day',  interval '6 hours', interval '12 hours')
  ) as v(l, buyer, biz, price, ful, fee, st, ck, created, conf, comp);
set session_replication_role = origin;

-- views: L1 by B and C, L2 by B, one 120 days old (past the 90 day window)
insert into public.listing_views (listing_id, viewer_id, viewed_at) values
  ((select id from zm_ids where name = 'l1'), :'B', now() - interval '2 days'),
  ((select id from zm_ids where name = 'l1'), :'C', now() - interval '3 days'),
  ((select id from zm_ids where name = 'l2'), :'B', now() - interval '1 day'),
  ((select id from zm_ids where name = 'l1'), :'C', now() - interval '120 days');
insert into public.favourites (user_id, listing_id, created_at) values
  (:'B', (select id from zm_ids where name = 'l1'), now() - interval '1 day'),
  (:'C', (select id from zm_ids where name = 'l1'), now() - interval '2 days');
-- conversations: L1/B answered after 30 minutes, L2/C never answered and older than 24 hours
set session_replication_role = replica;
insert into public.conversations (id, listing_id, buyer_id, seller_id, created_at, last_message_at) values
  ('30000000-0000-0000-0000-000000000001', (select id from zm_ids where name = 'l1'), :'B', :'S', now() - interval '6 days', now() - interval '6 days'),
  ('30000000-0000-0000-0000-000000000002', (select id from zm_ids where name = 'l2'), :'C', :'S', now() - interval '3 days', now() - interval '3 days');
insert into public.messages (conversation_id, sender_id, body, created_at) values
  ('30000000-0000-0000-0000-000000000001', :'B', 'Is it available?', now() - interval '6 days'),
  ('30000000-0000-0000-0000-000000000001', :'S', 'Yes it is',        now() - interval '6 days' + interval '30 minutes'),
  ('30000000-0000-0000-0000-000000000002', :'C', 'Last price?',      now() - interval '3 days');
-- a third chat, started five hours ago and not answered yet: not overdue
insert into public.conversations (id, listing_id, buyer_id, seller_id, created_at, last_message_at) values
  ('30000000-0000-0000-0000-000000000003', (select id from zm_ids where name = 'l2'), :'B', :'S', now() - interval '5 hours', now() - interval '5 hours');
insert into public.messages (conversation_id, sender_id, body, created_at) values
  ('30000000-0000-0000-0000-000000000003', :'B', 'Still there?', now() - interval '5 hours');
-- another seller's listing that B saved: must not count for S
insert into zm_ids values ('lx', zm_test.fresh_listing(50));
update public.listings set seller_id = :'C' where id = (select id from zm_ids where name = 'lx');
insert into public.favourites (user_id, listing_id, created_at) values (:'B', (select id from zm_ids where name = 'lx'), now() - interval '1 day');
-- reviews of the seller on two completed orders
insert into public.reviews (order_id, reviewer_id, reviewee_id, rating)
select o.id, o.buyer_id, :'S', case when o.buyer_id = :'C' then 4 else 5 end
  from public.orders o where o.status = 'completed' and o.business_id is null and o.created_at < now() - interval '3 days 12 hours';
-- a hidden review of the seller, and a review the seller wrote about a buyer: neither counts toward the seller's rating
insert into public.reviews (order_id, reviewer_id, reviewee_id, rating, is_hidden)
select o.id, o.buyer_id, :'S', 1, true from public.orders o where o.status = 'completed' and o.business_id is null and o.created_at > now() - interval '2 days' limit 1;
insert into public.reviews (order_id, reviewer_id, reviewee_id, rating)
select o.id, :'S', o.buyer_id, 1 from public.orders o where o.status = 'completed' and o.business_id is null and o.created_at > now() - interval '2 days' limit 1;
set session_replication_role = origin;

-- 1. Seller (personal) numbers
select zm_test.act_as(:'S');
create temp table zm_res (name text primary key, j jsonb);
grant all on zm_res to anon, authenticated, service_role;
insert into zm_res select 'seller', public.seller_analytics(null, 30);
select zm_test.expect_equal((select j #>> '{active_listings}' from zm_res where name = 'seller'), '2', 'personal listings only (the business one is excluded)');
select zm_test.expect_equal((select j #>> '{funnel,views}' from zm_res where name = 'seller'), '3', 'views in period; the 120 day old one is outside');
select zm_test.expect_equal((select j #>> '{funnel,unique_viewers}' from zm_res where name = 'seller'), '2', 'unique viewers');
select zm_test.expect_equal((select j #>> '{funnel,chats_started}' from zm_res where name = 'seller'), '3', 'chats started');
select zm_test.expect_equal((select j #>> '{funnel,orders_requested}' from zm_res where name = 'seller'), '4', 'orders requested (business order excluded)');
select zm_test.expect_equal((select j #>> '{funnel,order_rate_pct}' from zm_res where name = 'seller'), '100.0', 'rate is capped at 100');
select zm_test.expect_equal((select j #>> '{saves_in_period}' from zm_res where name = 'seller'), '2', 'saves (another seller''s listing excluded)');
select zm_test.expect_equal((select j #>> '{sales,completed_orders}' from zm_res where name = 'seller'), '3', 'completed orders');
select zm_test.expect_equal((select j #>> '{sales,completed_value_zmw}' from zm_res where name = 'seller'), '400.00', 'completed value counts items only, not delivery fees');
select zm_test.expect_equal((select j #>> '{sales,average_order_zmw}' from zm_res where name = 'seller'), '133.33', 'average order');
select zm_test.expect_equal((select j #>> '{sales,by_fulfilment,collection}' from zm_res where name = 'seller'), '2', 'collection orders');
select zm_test.expect_equal((select j #>> '{sales,by_fulfilment,delivery}' from zm_res where name = 'seller'), '1', 'delivery orders');
select zm_test.expect_equal((select j #>> '{order_handling,declined}' from zm_res where name = 'seller'), '1', 'declined');
select zm_test.expect_equal((select j #>> '{order_handling,cancelled}' from zm_res where name = 'seller'), '0', 'a decline is not counted as a cancellation');
select zm_test.expect_equal((select j #>> '{order_handling,not_completed_pct}' from zm_res where name = 'seller'), '25.0', 'not completed share');
select zm_test.expect_equal((select j #>> '{order_handling,avg_hours_to_confirm}' from zm_res where name = 'seller'), '4.0', 'average hours to confirm');
select zm_test.expect_equal((select j #>> '{order_handling,avg_hours_to_complete}' from zm_res where name = 'seller'), '28.0', 'average hours to complete');
select zm_test.expect_equal((select j #>> '{reviews,count}' from zm_res where name = 'seller'), '2', 'reviews');
select zm_test.expect_equal((select j #>> '{reviews,average}' from zm_res where name = 'seller'), '4.50', 'average rating');
select zm_test.expect_equal((select jsonb_array_length(j -> 'daily')::text from zm_res where name = 'seller'), '30', 'one row per day, empty days included');
select zm_test.expect_equal((select jsonb_array_length(j -> 'top_listings')::text from zm_res where name = 'seller'), '2', 'top listings');
select zm_test.expect_equal((select j #>> '{top_listings,0,completed}' from zm_res where name = 'seller'), '2', 'best listing first');
-- A shorter window leaves older things out
select zm_test.expect_equal((public.seller_analytics(null, 7) #>> '{sales,completed_orders}'), '3', 'seven day window still holds all three');
select zm_test.expect_equal((public.seller_analytics(null, 3) #>> '{funnel,orders_requested}'), '2', 'three day window');
-- Reply and customer numbers
select zm_test.expect_equal((public.engagement_stats(null, 30) ->> 'reply_rate_pct'), '33.3', 'reply rate');
select zm_test.expect_equal((public.engagement_stats(null, 30) ->> 'avg_first_reply_minutes'), '30.0', 'first reply time');
select zm_test.expect_equal((public.engagement_stats(null, 30) ->> 'unanswered_over_24h'), '1', 'unanswered over a day');
select zm_test.expect_equal((public.engagement_stats(null, 30) ->> 'repeat_customers'), '1', 'repeat customers (B bought twice)');
select zm_test.expect_equal((public.engagement_stats(null, 30) ->> 'customers_all_time'), '2', 'customers');
-- No buyer names or ids leak into any result
select zm_test.expect_equal((select (j::text like '%Bwalya%' or j::text like '%00000000-0000-0000-0000-00000000000b%')::text from zm_res where name = 'seller'), 'false', 'no buyer identity in the dashboard');
select zm_test.expect_equal((public.engagement_stats(null, 30)::text like '%00000000-0000-0000-0000-00000000000b%')::text, 'false', 'no buyer identity in engagement');

-- 2. Listing performance
select zm_test.expect_equal((public.listing_performance((select id from zm_ids where name = 'l1'), 30) #>> '{views}'), '2', 'listing views');
select zm_test.act_as(:'B');
select zm_test.expect_error($$select public.listing_performance((select id from zm_ids where name = 'l1'), 30)$$, 'another person''s listing');
select zm_test.act_as_guest();
select zm_test.expect_error($$select public.seller_analytics(null, 30)$$, 'guests');
select zm_test.expect_error($$select public.sales_report(null, current_date - 7, current_date)$$, 'guests: sales report');

-- 3. Business scope and roles
select zm_test.act_as(:'S');
select zm_test.expect_equal((public.seller_analytics(:'BIZ', 30) #>> '{sales,completed_orders}'), '1', 'business view holds only business orders');
select zm_test.expect_equal((public.seller_analytics(:'BIZ', 30) #>> '{active_listings}'), '1', 'business listings only');
select zm_test.act_as(:'MGR');
select zm_test.expect_equal((public.seller_analytics(:'BIZ', 30) #>> '{sales,completed_value_zmw}'), '300.00', 'manager can see the business');
select zm_test.act_as('00000000-0000-0000-0000-00000000000f');
select zm_test.expect_error($$select public.seller_analytics('20000000-0000-0000-0000-00000000000a', 30)$$, 'a plain staff member cannot see business numbers');
select zm_test.act_as(:'C');
select zm_test.expect_error($$select public.seller_analytics('20000000-0000-0000-0000-00000000000a', 30)$$, 'outsiders');
select zm_test.expect_error($$select public.engagement_stats('20000000-0000-0000-0000-00000000000a', 30)$$, 'outsiders: engagement');
select zm_test.expect_error($$select public.sales_report('20000000-0000-0000-0000-00000000000a', current_date - 7, current_date)$$, 'outsiders: sales report');
select zm_test.act_as(:'S');
select zm_test.expect_error($$select public.seller_analytics(gen_random_uuid(), 30)$$, 'a business that does not exist');

-- 4. Sales report
select zm_test.expect_equal((select sum(orders_completed)::text from public.sales_report(null, (current_date - 30), current_date, 'day')), '3', 'report orders');
select zm_test.expect_equal((select sum(items_zmw)::text from public.sales_report(null, (current_date - 30), current_date, 'day')), '400.00', 'report items');
select zm_test.expect_equal((select sum(delivery_fees_zmw)::text from public.sales_report(null, (current_date - 30), current_date, 'day')), '20.00', 'report delivery fees');
select zm_test.expect_equal((select sum(total_zmw)::text from public.sales_report(null, (current_date - 30), current_date, 'month')), '420.00', 'report total by month');
select zm_test.expect_equal((select sum(total_zmw)::text from public.sales_report(null, (current_date - 30), current_date, 'week')), '420.00', 'report total by week');
select zm_test.expect_equal((select count(*)::text from public.sales_report(null, (current_date - 400), (current_date - 390), 'day')), '0', 'empty period');
select zm_test.expect_error($$select * from public.sales_report(null, current_date - 7, current_date, 'year')$$, 'bad grouping');
select zm_test.expect_equal((select bool_and(extract(isodow from period) = 1)::text from public.sales_report(null, current_date - 30, current_date, 'week')), 'true', 'weekly periods start on Monday');
select zm_test.expect_equal((select bool_and(extract(day from period) = 1)::text from public.sales_report(null, current_date - 30, current_date, 'month')), 'true', 'monthly periods start on the first');
select zm_test.expect_error($$select * from public.sales_report(null, current_date, current_date - 7)$$, 'start after end');
select zm_test.expect_error($$select * from public.sales_report(null, current_date - 500, current_date)$$, 'more than a year');
select zm_test.expect_error($$select * from public.sales_report(null, null, current_date)$$, 'missing date');
select zm_test.expect_equal((select orders_completed::text from public.sales_by_listing(null, current_date - 30, current_date) limit 1), '2', 'best listing by value first? L2 is 200 and L1 is 200: tie broken by count');
select zm_test.expect_equal((select count(*)::text from public.sales_by_listing(null, current_date - 30, current_date)), '2', 'two personal listings sold');
select zm_test.expect_error($$select * from public.sales_by_listing(null, current_date - 500, current_date)$$, 'too long');

-- 5. Staff statistics
select zm_test.act_as(:'S');
select zm_test.expect_error($$select public.platform_stats(30)$$, 'seller cannot see platform stats');
select zm_test.expect_error($$select public.trust_stats(30)$$, 'seller cannot see trust stats');
select zm_test.expect_error($$select * from public.financial_report(current_date - 7, current_date)$$, 'seller cannot see finance');
select zm_test.expect_error($$select public.financial_totals(current_date - 7, current_date)$$, 'seller cannot see finance totals');
select zm_test.act_as(:'MOD', 'aal1');
select zm_test.expect_error($$select public.trust_stats(30)$$, 'staff without two-factor');
select zm_test.act_as(:'MOD', 'aal2');
select zm_test.expect_equal((public.trust_stats(30) is not null)::text, 'true', 'moderator sees trust stats');
select zm_test.expect_error($$select public.platform_stats(30)$$, 'moderator cannot see platform stats');
select zm_test.expect_error($$select public.financial_totals(current_date - 7, current_date)$$, 'moderator cannot see finance');
select zm_test.act_as(:'SUP', 'aal2');
select zm_test.expect_equal((public.trust_stats(30) is not null)::text, 'true', 'support sees trust stats');
select zm_test.expect_error($$select public.platform_stats(30)$$, 'support cannot see platform stats');
select zm_test.act_as(:'F1', 'aal2');
select zm_test.expect_equal((public.platform_stats(30) is not null)::text, 'true', 'finance sees platform stats');
select zm_test.expect_equal((public.trust_stats(30) is not null)::text, 'true', 'F1 also holds the support role, so trust stats are allowed');
select zm_test.act_as(:'F2', 'aal2');
select zm_test.expect_equal((public.platform_stats(30) #>> '{orders,completed}'), '4', 'platform completed orders (all sellers)');
select zm_test.expect_equal((public.trust_stats(30) is not null)::text, 'true', 'tech admin sees trust stats');
select zm_test.expect_equal((public.platform_stats(30)::text like '%Bwalya%')::text, 'false', 'no names in platform stats');

-- 6. Finance reports are audited and limited to finance
select zm_test.act_as_admin();
select set_config('zm.audit_before', (select count(*)::text from public.audit_logs), false);
select zm_test.act_as(:'F2', 'aal2');
select count(*) from public.financial_report(current_date - 30, current_date, 'day');
select public.financial_totals(current_date - 30, current_date);
select zm_test.act_as_admin();
select zm_test.expect_equal(((select count(*) from public.audit_logs) - current_setting('zm.audit_before')::int)::text, '2', 'each finance report leaves an audit record');
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action in ('analytics.financial_report', 'analytics.financial_totals') and actor_id = :'F2'), '2', 'the records carry the right actions and the person');
select zm_test.act_as(:'F1', 'aal1');
select zm_test.expect_error($$select public.financial_totals(current_date - 7, current_date)$$, 'finance without two-factor');
select zm_test.act_as(:'F1', 'aal2');
select zm_test.expect_error($$select * from public.financial_report(current_date, current_date - 7)$$, 'bad finance dates');
select zm_test.expect_error($$select * from public.financial_report(current_date - 7, current_date, 'year')$$, 'bad finance grouping');

-- 7. Function permissions: helpers are not callable by the app, report functions are not callable by guests
select zm_test.act_as_admin();
select zm_test.expect_equal((select bool_or(has_function_privilege('authenticated', p.oid, 'execute'))::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                              where n.nspname = 'public' and p.proname in ('analytics_days','analytics_owner_check','analytics_listings','analytics_orders','analytics_staff_check','analytics_pct','analytics_rate')), 'false', 'helpers are private');
select zm_test.expect_equal((select bool_or(has_function_privilege('anon', p.oid, 'execute'))::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                              where n.nspname = 'public' and p.proname in ('seller_analytics','listing_performance','sales_report','sales_by_listing','engagement_stats','platform_stats','trust_stats','financial_report','financial_totals')), 'false', 'guests cannot run reports');
select zm_test.expect_equal((select bool_and(has_function_privilege('authenticated', p.oid, 'execute'))::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                              where n.nspname = 'public' and p.proname in ('seller_analytics','listing_performance','sales_report','sales_by_listing','engagement_stats','platform_stats','trust_stats','financial_report','financial_totals')), 'true', 'signed-in people can run reports (checks are inside)');
select zm_test.expect_equal((select bool_or(has_function_privilege('service_role', p.oid, 'execute'))::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                              where n.nspname = 'public' and p.proname in ('seller_analytics','platform_stats','financial_totals')), 'false', 'workers have no reason to run reports');
-- Window validation
select zm_test.act_as(:'S');
select zm_test.expect_equal((public.seller_analytics(null, 0) ->> 'period_days'), '1', 'a window below one day is raised to one');

select 'Analytics checks passed' as result;
rollback;
