-- Fraud checks (0038), delivery with the seller's own rider (0039) and promoted listings (0040).
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/delivery_fraud_promo.sql

begin;

create schema zm_test;
grant usage on schema zm_test to anon, authenticated, service_role;

create function zm_test.act_as(p_user uuid, p_aal text default 'aal1') returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  execute 'set local role authenticated';
end $$;
create function zm_test.act_as_guest() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
end $$;
create function zm_test.act_as_admin() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;
create function zm_test.expect_error(p_sql text, p_what text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception 'Expected an error but the statement worked: %', p_what;
exception when others then
  if sqlerrm like 'Expected an error but%' then raise; end if;
end $$;
create function zm_test.expect_equal(p_actual text, p_expected text, p_what text) returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'Wrong result for %: expected %, got %', p_what, coalesce(p_expected, 'null'), coalesce(p_actual, 'null');
  end if;
end $$;
create function zm_test.q(p_sql text) returns text language plpgsql security definer as $$
declare r text; begin execute p_sql into r; return r; end $$;

insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000e1', 'seller@example.test', '{"display_name":"Seller Sam"}', now()),
  ('00000000-0000-0000-0000-0000000000e2', 'buyer@example.test',  '{"display_name":"Buyer Bo"}', now()),
  ('00000000-0000-0000-0000-0000000000e3', 'mod@example.test',    '{"display_name":"Mod Mary"}', now()),
  ('00000000-0000-0000-0000-0000000000e4', 'other@example.test',  '{"display_name":"Other Olu"}', now());
insert into public.admin_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000e3', 'moderator');
\set SELLER '00000000-0000-0000-0000-0000000000e1'
\set BUYER  '00000000-0000-0000-0000-0000000000e2'
\set MOD    '00000000-0000-0000-0000-0000000000e3'
\set OTHER  '00000000-0000-0000-0000-0000000000e4'

create function zm_test.order_id() returns uuid language sql security definer as $$ select id from public.orders where item_title = 'Table' $$;
create function zm_test.delivery_id() returns uuid language sql security definer as $$ select id from public.deliveries limit 1 $$;
create function zm_test.wrong_pin() returns text language sql security definer as $$
  select case when p.pin = '0000' then '1111' else '0000' end from public.delivery_pins p join public.deliveries d on d.id = p.delivery_id where d.status not in ('cancelled', 'failed') order by d.created_at desc limit 1 $$;
create function zm_test.right_pin() returns text language sql security definer as $$ select p.pin from public.delivery_pins p join public.deliveries d on d.id = p.delivery_id where d.status not in ('cancelled', 'failed') order by d.created_at desc limit 1 $$;
create function zm_test.live_delivery() returns uuid language sql security definer as $$ select id from public.deliveries where status not in ('cancelled', 'failed', 'delivered') $$;
create function zm_test.open_promo() returns uuid language sql security definer as $$ select id from public.promotion_requests where status = 'requested' $$;
create function zm_test.promo_id() returns uuid language sql security definer as $$ select id from public.promotion_requests limit 1 $$;
grant execute on all functions in schema zm_test to anon, authenticated, service_role;

-- ===== Fraud checks =====
-- Same text posted 3 times by one seller raises one flag.
insert into public.listings (seller_id, category_id, location_id, title, description, price_zmw, condition, status, moderation_status)
  select :'SELLER', c.id, l.id, 'Samsung phone ' || g, 'Brand new sealed Samsung phone, call me now for a good price', 1000, 'used_good', 'draft', 'approved'
    from public.categories c, public.locations l, generate_series(1, 3) g limit 3;
select zm_test.expect_equal(zm_test.q($q$select count(*)::text from public.risk_flags where signal = 'repeated_listing_text'$q$), '1', 'repeated text flagged once');
-- Posting a fourth copy does not create a second open flag.
insert into public.listings (seller_id, category_id, location_id, title, description, price_zmw, condition, status, moderation_status)
  select :'SELLER', c.id, l.id, 'Samsung phone 4', 'Brand new sealed Samsung phone, call me now for a good price', 1000, 'used_good', 'draft', 'approved'
    from public.categories c, public.locations l limit 1;
select zm_test.expect_equal(zm_test.q($q$select count(*)::text from public.risk_flags where signal = 'repeated_listing_text' and status = 'open'$q$), '1', 'no duplicate open flag');
-- Short text is never fingerprinted.
select zm_test.expect_equal(zm_test.q($q$select coalesce(public.listing_text_fingerprint('Hi', 'x')::text, 'none')$q$), 'none', 'short text has no fingerprint');
-- Nothing is removed automatically.
select zm_test.expect_equal(zm_test.q($q$select count(*)::text from public.listings where seller_id = '00000000-0000-0000-0000-0000000000e1'$q$), '4', 'flag only, nothing deleted');
-- The flags function is not callable by normal users.
select zm_test.act_as(:'SELLER');
select zm_test.expect_error($q$select public.raise_risk_flag('listing', gen_random_uuid(), 'x', '{}')$q$, 'raise_risk_flag is closed');
select zm_test.act_as_admin();

-- ===== Own-rider delivery =====
insert into public.saved_addresses (user_id, label, kind, location_id, street)
  select :'BUYER', 'Home', 'both', id, 'Plot 9' from public.locations limit 1;
insert into public.listings (seller_id, category_id, location_id, title, description, price_zmw, condition, status, moderation_status)
  select :'SELLER', c.id, l.id, 'Table', 'A wooden table for the kitchen, solid', 300, 'used_good', 'draft', 'approved' from public.categories c, public.locations l limit 1;
insert into public.orders (listing_id, buyer_id, seller_id, buyer_name, seller_name, item_title, item_price_zmw, status, fulfilment, delivery_address)
  select id, :'BUYER', :'SELLER', 'Buyer Bo', 'Seller Sam', 'Table', 300, 'confirmed', 'delivery', 'Plot 9, Kabwe' from public.listings where title = 'Table';

select zm_test.act_as(:'OTHER');
select zm_test.expect_error($q$select public.delivery_start(zm_test.order_id(), 'Market', null)$q$, 'a stranger cannot start delivery');
select zm_test.act_as(:'BUYER');
select zm_test.expect_error($q$select public.delivery_start(zm_test.order_id(), 'Market', null)$q$, 'the buyer cannot start delivery');
select zm_test.act_as(:'SELLER');
select zm_test.expect_error($q$select public.delivery_start(zm_test.order_id(), '', null)$q$, 'pickup place is required');
select public.delivery_start(zm_test.order_id(), 'Soweto Market, stall 4', 'Joseph');
select zm_test.expect_error($q$select public.delivery_start(zm_test.order_id(), 'Market', null)$q$, 'only one live delivery per order');
-- The seller never sees the PIN.
select zm_test.expect_equal(zm_test.q($q$select coalesce(public.delivery_view(zm_test.order_id()) ->> 'pin', 'hidden')$q$), 'hidden', 'seller does not see the PIN');
select zm_test.expect_error($q$select public.delivery_set_status(zm_test.delivery_id(), 'in_transit')$q$, 'cannot skip a step');
select public.delivery_set_status(zm_test.delivery_id(), 'picked_up');
select public.delivery_set_status(zm_test.delivery_id(), 'in_transit');

select zm_test.act_as(:'BUYER');
select zm_test.expect_equal(zm_test.q($q$select (public.delivery_view(zm_test.order_id()) ->> 'pin') ~ '^[0-9]{4}$'$q$), 'true', 'buyer sees a 4 digit PIN');
select zm_test.act_as(:'OTHER');
select zm_test.expect_error($q$select public.delivery_view(zm_test.order_id())$q$, 'a stranger cannot view the delivery');
select zm_test.act_as_admin();

select zm_test.act_as(:'SELLER');
select zm_test.expect_equal(zm_test.q($q$select (public.delivery_confirm_dropoff(zm_test.delivery_id(), zm_test.wrong_pin()) ->> 'attempts_left')$q$), '4', 'wrong PIN counted');
select zm_test.expect_equal(zm_test.q($q$select (public.delivery_confirm_dropoff(zm_test.delivery_id(), zm_test.wrong_pin()) ->> 'ok')$q$), 'false', 'wrong PIN is not ok');
select zm_test.expect_equal(zm_test.q($q$select pin_attempts::text from public.deliveries limit 1$q$), '2', 'attempts were saved, not rolled back');
select zm_test.expect_equal(zm_test.q($q$select (public.delivery_confirm_dropoff(zm_test.delivery_id(), zm_test.right_pin()) ->> 'ok')$q$), 'true', 'right PIN works');
select zm_test.expect_equal(zm_test.q($q$select status::text from public.deliveries limit 1$q$), 'delivered', 'delivery delivered');
select zm_test.expect_equal(zm_test.q($q$select (handed_over_at is not null)::text from public.orders where item_title = 'Table'$q$), 'true', 'order handed over');

-- Five wrong PINs lock a delivery.
select zm_test.act_as_admin();
update public.orders set handed_over_at = null, status = 'confirmed' where item_title = 'Table';
update public.deliveries set status = 'cancelled', status_reason = 'test' ;
select zm_test.act_as(:'SELLER');
select public.delivery_start(zm_test.order_id(), 'Market', null);
select public.delivery_set_status(zm_test.live_delivery(), 'picked_up');
select public.delivery_confirm_dropoff(zm_test.live_delivery(), zm_test.wrong_pin()) from generate_series(1, 5);
select zm_test.expect_error($q$select public.delivery_confirm_dropoff(zm_test.live_delivery(), '1234')$q$, 'locked after five wrong PINs');
select public.delivery_cancel(zm_test.live_delivery(), 'Rider unavailable');

-- ===== Promoted listings =====
select zm_test.act_as_admin();
update public.listings set status = 'draft' where title <> 'Table';
insert into public.listing_images (listing_id, storage_path, position)
  select id, 'x/y.jpg', 0 from public.listings where title = 'Table';
update public.profiles set seller_status = 'active';
update public.listings set status = 'active', moderation_status = 'approved' where title = 'Table';
select zm_test.act_as(:'OTHER');
select zm_test.expect_error($q$select public.promotion_request((select id from public.listings where title = 'Table'), 7)$q$, 'only the owner can request');
select zm_test.act_as(:'SELLER');
select zm_test.expect_error($q$select public.promotion_request((select id from public.listings where title = 'Table'), 5)$q$, 'only 7, 14 or 30 days');
select public.promotion_request((select id from public.listings where title = 'Table'), 14);
select zm_test.expect_error($q$select public.promotion_request((select id from public.listings where title = 'Table'), 7)$q$, 'one waiting request per listing');
select zm_test.expect_equal(zm_test.q($q$select (public.promotion_my() -> 0 ->> 'price_zmw')$q$), '100.00', 'price for 14 days is double the base');
select zm_test.expect_error($q$select public.promotion_queue()$q$, 'a seller cannot see the staff queue');
select zm_test.expect_equal(zm_test.q($q$select count(*)::text from public.promoted_listings_now(10)$q$), '0', 'nothing promoted before approval');

select zm_test.act_as(:'MOD', 'aal1');
select zm_test.expect_error($q$select public.promotion_queue()$q$, 'staff need aal2');
select zm_test.act_as(:'MOD', 'aal2');
select zm_test.expect_equal(zm_test.q($q$select jsonb_array_length(public.promotion_queue())::text$q$), '1', 'staff see the request');
select zm_test.expect_error($q$select public.promotion_decide(zm_test.promo_id(), true, '')$q$, 'approval needs a payment reference');
select zm_test.expect_error($q$select public.promotion_decide(zm_test.promo_id(), false, '')$q$, 'rejection needs a reason');
select public.promotion_decide(zm_test.promo_id(), true, 'MoMo ref 123456');
select zm_test.act_as_guest();
select zm_test.expect_equal(zm_test.q($q$select count(*)::text from public.promoted_listings_now(10)$q$), '1', 'visitors see the promoted listing');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.q($q$select (ends_at > now() + interval '13 days')::text from public.promoted_listings$q$), 'true', 'runs for 14 days');
select zm_test.expect_equal(zm_test.q($q$select count(*)::text from public.audit_logs where action = 'promotion.approved'$q$), '1', 'approval is audited');

-- A second approved request extends the period instead of replacing it.
select zm_test.act_as(:'SELLER');
select public.promotion_request((select id from public.listings where title = 'Table'), 7);
select zm_test.act_as(:'MOD', 'aal2');
select public.promotion_decide(zm_test.open_promo(), true, 'MoMo ref 777777');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.q($q$select (ends_at > now() + interval '20 days')::text from public.promoted_listings$q$), 'true', 'second period is added on');

-- Ending a promotion needs a reason.
select zm_test.act_as(:'MOD', 'aal2');
select zm_test.expect_error($q$select public.promotion_end((select id from public.listings where title = 'Table'), '')$q$, 'reason required');
select public.promotion_end((select id from public.listings where title = 'Table'), 'Breaks the rules');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.q($q$select count(*)::text from public.promoted_listings$q$), '0', 'promotion ended');

select 'Delivery, fraud and promotion checks passed' as result;
rollback;
