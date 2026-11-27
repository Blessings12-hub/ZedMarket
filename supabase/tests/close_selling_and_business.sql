-- Deleting a selling account and deleting a business (migrations 0025, 0026 and 0027): a seller can close their account;
-- they become a buyer again and must apply from the start; open orders block it; only the owner can delete a business;
-- listings go off sale; guests and strangers are refused.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/close_selling_and_business.sql

begin;

create schema zm_test;
grant usage on schema zm_test to anon, authenticated, service_role;

create function zm_test.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal1')::text, true);
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
grant execute on all functions in schema zm_test to anon, authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000a1', 'seller@example.test', '{"display_name":"Seller Anna"}', now()),
  ('00000000-0000-0000-0000-0000000000a2', 'buyer@example.test',  '{"display_name":"Buyer Bwalya"}', now()),
  ('00000000-0000-0000-0000-0000000000a3', 'paused@example.test', '{"display_name":"Paused Chanda"}', now()),
  ('00000000-0000-0000-0000-0000000000a4', 'owner@example.test',  '{"display_name":"Owner Dalitso"}', now()),
  ('00000000-0000-0000-0000-0000000000a5', 'staff@example.test',  '{"display_name":"Manager Esther"}', now());

\set SELLER '00000000-0000-0000-0000-0000000000a1'
\set BUYER  '00000000-0000-0000-0000-0000000000a2'
\set PAUSED '00000000-0000-0000-0000-0000000000a3'
\set OWNER  '00000000-0000-0000-0000-0000000000a4'
\set MGR    '00000000-0000-0000-0000-0000000000a5'
\set BIZ    '00000000-0000-0000-0000-0000000000b1'

-- An approved seller, set up directly as the superuser.
update public.profiles set seller_status = 'active' where id = :'SELLER';
insert into public.seller_applications (user_id, status) values (:'SELLER', 'approved');
insert into public.seller_agreement_acceptances (user_id, version) values (:'SELLER', 1);
insert into public.listings (seller_id, category_id, location_id, title, description, price_zmw, condition, status, moderation_status)
  select :'SELLER', c.id, l.id, 'Phone for sale', 'Good phone', 500, 'used_good', 'unavailable', 'approved'
  from public.categories c, public.locations l limit 1;

insert into public.businesses (id, owner_id, name, slug) values (:'BIZ', :'OWNER', 'Dalitso Traders', 'dalitso-traders');
insert into public.business_members (business_id, user_id, role) values (:'BIZ', :'OWNER', 'owner'), (:'BIZ', :'MGR', 'manager')
  on conflict do nothing;

-- 1. Who can close a selling account ------------------------------------------------------------------------------
select zm_test.act_as_guest();
select zm_test.expect_error('select public.seller_account_close()', 'guests cannot close an account');
select zm_test.expect_error(format($q$select public.business_close(%L)$q$, :'BIZ'), 'guests cannot delete a business');
select zm_test.act_as(:'BUYER');
select zm_test.expect_error('select public.seller_account_close()', 'a buyer has no selling account to delete');

-- 2. Open orders block it -----------------------------------------------------------------------------------------
select zm_test.act_as_admin();
create temp table zm_listing as select id from public.listings where seller_id = :'SELLER' limit 1;
grant all on zm_listing to authenticated;
insert into public.orders (listing_id, buyer_id, seller_id, buyer_name, seller_name, item_title, item_price_zmw, status)
  select id, :'BUYER', :'SELLER', 'Bwalya', 'Anna', 'Phone for sale', 500, 'confirmed' from zm_listing;
select zm_test.act_as(:'SELLER');
select zm_test.expect_error('select public.seller_account_close()', 'open orders block deleting the account');
select zm_test.act_as_admin();
update public.orders set status = 'completed' where seller_id = :'SELLER';

-- 3. A clean close sends the person back to being a buyer -----------------------------------------------------------
select zm_test.act_as(:'SELLER');
select public.seller_account_close('I am stopping');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.q(format($q$select seller_status from public.profiles where id = %L$q$, :'SELLER')), 'none', 'back to a buyer');
select zm_test.expect_equal(zm_test.q(format($q$select status from public.seller_applications where user_id = %L$q$, :'SELLER')), 'closed', 'application closed');
select zm_test.expect_equal(zm_test.q(format($q$select status::text from public.listings where seller_id = %L$q$, :'SELLER')), 'removed', 'listings taken off sale');
select zm_test.expect_equal(zm_test.q(format($q$select count(*)::text from public.seller_agreement_acceptances where user_id = %L$q$, :'SELLER')), '0', 'agreement must be accepted again');
select zm_test.expect_equal(zm_test.q($q$select count(*)::text from public.audit_logs where action = 'seller.account_closed'$q$), '1', 'the deletion is audited');
select zm_test.act_as(:'SELLER');
select zm_test.expect_equal(public.seller_can_publish()::text, 'false', 'a former seller cannot publish');
select public.seller_account_close();  -- closing twice is harmless
-- The same verification starts again: a new draft is allowed straight away, with no waiting period.
select public.seller_application_save('{"legal_name":"Anna Mwansa"}');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.q(format($q$select count(*)::text from public.seller_applications where user_id = %L and status = 'draft'$q$, :'SELLER')), '1', 'a new application can be started');
select zm_test.expect_equal(zm_test.q(format($q$select seller_status from public.profiles where id = %L$q$, :'SELLER')), 'none', 'still not a seller until the team approves');

-- 4. Deleting a business ------------------------------------------------------------------------------------------
select zm_test.act_as(:'BUYER');
select zm_test.expect_error(format($q$select public.business_close(%L)$q$, :'BIZ'), 'a stranger cannot delete a business');
select zm_test.act_as(:'MGR');
select zm_test.expect_error(format($q$select public.business_close(%L)$q$, :'BIZ'), 'a manager cannot delete a business');
select zm_test.act_as(:'OWNER');
select zm_test.expect_error($q$select public.business_close('00000000-0000-0000-0000-0000000000ff')$q$, 'unknown business');
select zm_test.act_as_admin();
insert into public.listings (seller_id, business_id, category_id, location_id, title, description, price_zmw, condition, status, moderation_status)
  select :'OWNER', :'BIZ', c.id, l.id, 'Shop item', 'Shop item', 100, 'new', 'unavailable', 'approved'
  from public.categories c, public.locations l limit 1;
insert into public.orders (listing_id, buyer_id, seller_id, business_id, buyer_name, seller_name, item_title, item_price_zmw, status)
  select id, :'BUYER', :'OWNER', :'BIZ', 'Bwalya', 'Dalitso Traders', 'Shop item', 100, 'requested' from public.listings where business_id = :'BIZ';
select zm_test.act_as(:'OWNER');
select zm_test.expect_error(format($q$select public.business_close(%L)$q$, :'BIZ'), 'open business orders block deleting it');
select zm_test.act_as_admin();
update public.orders set status = 'completed' where business_id = :'BIZ';
select zm_test.act_as(:'OWNER');
select public.business_close(:'BIZ', 'Closing the shop');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.q(format($q$select count(*)::text from public.businesses where id = %L$q$, :'BIZ')), '0', 'business is gone');
select zm_test.expect_equal(zm_test.q(format($q$select count(*)::text from public.business_members where business_id = %L$q$, :'BIZ')), '0', 'members are gone');
select zm_test.expect_equal(zm_test.q($q$select count(*)::text from public.listings where title = 'Shop item' and status = 'removed' and business_id is null$q$), '1', 'its listings are off sale');
select zm_test.expect_equal(zm_test.q($q$select count(*)::text from public.audit_logs where action = 'business.deleted'$q$), '1', 'the deletion is audited');

rollback;
