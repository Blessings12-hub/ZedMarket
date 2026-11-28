-- Launch readiness (migration 0037): the error log, the staff health summary, reply speed, deleting my account,
-- invite codes and terms acceptance.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/launch_readiness.sql

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
grant execute on all functions in schema zm_test to anon, authenticated, service_role;


insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000c1', 'seller@example.test', '{"display_name":"Seller Sam"}', now()),
  ('00000000-0000-0000-0000-0000000000c2', 'tech@example.test',   '{"display_name":"Tech Tina"}', now()),
  ('00000000-0000-0000-0000-0000000000c3', 'gone@example.test',   '{"display_name":"Leaving Lubuto","accepted_terms_version":"2026-1"}', now()),
  ('00000000-0000-0000-0000-0000000000c4', 'friend@example.test', '{"display_name":"Friend Faith"}', now()),
  ('00000000-0000-0000-0000-0000000000d1', 'b1@example.test', '{"display_name":"Buyer 1"}', now()),
  ('00000000-0000-0000-0000-0000000000d2', 'b2@example.test', '{"display_name":"Buyer 2"}', now()),
  ('00000000-0000-0000-0000-0000000000d3', 'b3@example.test', '{"display_name":"Buyer 3"}', now()),
  ('00000000-0000-0000-0000-0000000000d4', 'b4@example.test', '{"display_name":"Buyer 4"}', now()),
  ('00000000-0000-0000-0000-0000000000d5', 'b5@example.test', '{"display_name":"Buyer 5"}', now());
insert into public.admin_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000c2', 'tech_admin');

\set SELLER '00000000-0000-0000-0000-0000000000c1'
\set TECH   '00000000-0000-0000-0000-0000000000c2'
\set GONE   '00000000-0000-0000-0000-0000000000c3'
\set FRIEND '00000000-0000-0000-0000-0000000000c4'

-- 1. Terms acceptance is recorded at sign-up ----------------------------------------------------------------------
select zm_test.expect_equal(zm_test.q(format($q$select terms_version from public.profiles where id = %L$q$, :'GONE')), '2026-1', 'terms version recorded');
select zm_test.expect_equal(zm_test.q(format($q$select (terms_accepted_at is not null)::text from public.profiles where id = %L$q$, :'GONE')), 'true', 'terms time recorded');
select zm_test.expect_equal(zm_test.q(format($q$select coalesce(terms_version, 'none') from public.profiles where id = %L$q$, :'FRIEND')), 'none', 'no version when none was sent');

-- 2. Error log ----------------------------------------------------------------------------------------------------
select zm_test.expect_equal((select count(*)::text from information_schema.role_table_grants where table_schema = 'public'
   and table_name in ('client_errors', 'referral_codes', 'referrals') and grantee in ('anon', 'authenticated')), '0', 'closed tables');
select zm_test.act_as_guest();
select public.report_client_error('Cannot read property x of undefined', 'at Foo (a.js:1)', '/listing/[id]', 'android', '1.0.0');
select public.report_client_error('Cannot read property x of undefined', 'at Foo (a.js:1)', '/listing/[id]', 'android', '1.0.0');
select public.report_client_error('', null);
select public.report_client_error('Another crash', null, null, 'toaster', null);
select zm_test.expect_error('select * from public.client_errors', 'guests cannot read the error log');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.q($q$select count(*)::text from public.client_errors$q$), '2', 'same error stored once, empty message ignored');
select zm_test.expect_equal(zm_test.q($q$select occurrences::text from public.client_errors where message like 'Cannot read%'$q$), '2', 'repeat is counted');
select zm_test.expect_equal(zm_test.q($q$select platform from public.client_errors where message = 'Another crash'$q$), 'unknown', 'odd platform becomes unknown');

-- 3. Staff health summary -------------------------------------------------------------------------------------------
select zm_test.act_as(:'FRIEND');
select zm_test.expect_error('select public.staff_health_summary()', 'a buyer cannot read the health summary');
select zm_test.act_as(:'TECH', 'aal1');
select zm_test.expect_error('select public.staff_health_summary()', 'staff need two-factor');
select zm_test.act_as(:'TECH', 'aal2');
select zm_test.expect_equal((public.staff_health_summary() ->> 'errors_24h'), '3', 'three error occurrences in 24 hours');
select zm_test.expect_equal((public.staff_health_summary() ->> 'error_kinds_24h'), '2', 'two kinds');
select zm_test.expect_equal(jsonb_array_length(public.staff_health_summary() -> 'top_errors')::text, '2', 'top errors listed');

-- 4. Reply speed ----------------------------------------------------------------------------------------------------
select zm_test.act_as_admin();
insert into public.listings (seller_id, category_id, location_id, title, description, price_zmw, condition, status, moderation_status)
  select :'SELLER', c.id, l.id, 'Chair', 'A chair', 100, 'used_good', 'draft', 'approved' from public.categories c, public.locations l limit 1;
select zm_test.expect_equal(zm_test.q(format($q$select coalesce(public.seller_reply_speed(%L), 'none')$q$, :'SELLER')), 'none', 'no badge without chats');
create function zm_test.chat(p_buyer uuid, p_reply_after interval) returns void language plpgsql security definer as $$
declare cid uuid; t0 timestamptz := now() - interval '3 days';
begin
  insert into public.conversations (listing_id, buyer_id, seller_id) select id, p_buyer, seller_id from public.listings where title = 'Chair' returning id into cid;
  insert into public.messages (conversation_id, sender_id, body, created_at) values (cid, p_buyer, 'Is it available?', t0);
  if p_reply_after is not null then
    insert into public.messages (conversation_id, sender_id, body, created_at) values (cid, (select seller_id from public.conversations where id = cid), 'Yes it is', t0 + p_reply_after);
  end if;
end $$;
select zm_test.chat('00000000-0000-0000-0000-0000000000d1', interval '10 minutes');
select zm_test.chat('00000000-0000-0000-0000-0000000000d2', interval '20 minutes');
select zm_test.chat('00000000-0000-0000-0000-0000000000d3', interval '30 minutes');
select zm_test.chat('00000000-0000-0000-0000-0000000000d4', interval '40 minutes');
select zm_test.expect_equal(zm_test.q(format($q$select coalesce(public.seller_reply_speed(%L), 'none')$q$, :'SELLER')), 'none', 'four chats are too few for a badge');
select zm_test.chat('00000000-0000-0000-0000-0000000000d5', interval '50 minutes');
select zm_test.expect_equal(zm_test.q(format($q$select public.seller_reply_speed(%L)$q$, :'SELLER')), 'within_an_hour', 'five quick answers earn the badge');
select zm_test.act_as_guest();
select zm_test.expect_equal(public.seller_reply_speed(:'SELLER'), 'within_an_hour', 'guests can see the badge');
select zm_test.act_as_admin();
update public.messages set created_at = created_at + interval '5 hours' where sender_id = :'SELLER';
select zm_test.expect_equal(zm_test.q(format($q$select public.seller_reply_speed(%L)$q$, :'SELLER')), 'within_a_day', 'slower answers give the weaker badge');
delete from public.messages where sender_id = :'SELLER';
select zm_test.expect_equal(zm_test.q(format($q$select coalesce(public.seller_reply_speed(%L), 'none')$q$, :'SELLER')), 'none', 'unanswered chats earn nothing');

-- 5. Invite codes -------------------------------------------------------------------------------------------------
select zm_test.act_as_guest();
select zm_test.expect_error('select public.referral_code_mine()', 'guests have no invite code');
select zm_test.act_as(:'SELLER');
select zm_test.expect_equal(length(public.referral_code_mine())::text, '8', 'code has 8 characters');
select zm_test.expect_equal((public.referral_code_mine() = public.referral_code_mine())::text, 'true', 'the code stays the same');
select zm_test.expect_equal((public.referral_code_mine() ~ '^[A-HJ-NP-Z2-9]{8}$')::text, 'true', 'no look-alike characters');
create temp table zm_code as select public.referral_code_mine() as code;
grant all on zm_code to authenticated;
select zm_test.expect_error('select public.referral_redeem((select code from zm_code))', 'cannot use your own code');
select zm_test.act_as(:'FRIEND');
select zm_test.expect_error($q$select public.referral_redeem('ZZZZZZZZ')$q$, 'unknown code');
select public.referral_redeem(lower((select code from zm_code)));
select zm_test.expect_error('select public.referral_redeem((select code from zm_code))', 'only one code per person');
select zm_test.act_as(:'SELLER');
select zm_test.expect_equal(public.referral_count()::text, '1', 'the owner sees one friend joined');
select zm_test.act_as_admin();
update public.profiles set created_at = now() - interval '40 days' where id = :'GONE';
select zm_test.act_as(:'GONE');
select zm_test.expect_error('select public.referral_redeem((select code from zm_code))', 'codes only work in the first 30 days');

-- 6. Delete my account --------------------------------------------------------------------------------------------
select zm_test.act_as_guest();
select zm_test.expect_error('select public.account_delete()', 'guests cannot delete an account');
select zm_test.act_as(:'TECH', 'aal2');
select zm_test.expect_error('select public.account_delete()', 'staff accounts are not deleted here');
select zm_test.act_as_admin();
insert into public.favourites (user_id, listing_id) select :'GONE', id from public.listings where title = 'Chair';
insert into public.saved_addresses (user_id, label, kind, location_id, street)
  select :'GONE', 'Home', 'both', id, 'Plot 1' from public.locations limit 1;
insert into public.orders (listing_id, buyer_id, seller_id, buyer_name, seller_name, item_title, item_price_zmw, status)
  select id, :'GONE', :'SELLER', 'Leaving Lubuto', 'Seller Sam', 'Chair', 100, 'confirmed' from public.listings where title = 'Chair';
select zm_test.act_as(:'GONE');
select zm_test.expect_error('select public.account_delete()', 'an open order blocks deleting the account');
select zm_test.act_as_admin();
update public.orders set status = 'completed' where buyer_id = :'GONE';
select zm_test.act_as(:'GONE');
select public.account_delete('Not using it');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.q(format($q$select display_name from public.profiles where id = %L$q$, :'GONE')), 'Deleted user', 'name is scrubbed');
select zm_test.expect_equal(zm_test.q(format($q$select (deleted_at is not null)::text from public.profiles where id = %L$q$, :'GONE')), 'true', 'marked deleted');
select zm_test.expect_equal(zm_test.q(format($q$select count(*)::text from public.favourites where user_id = %L$q$, :'GONE')), '0', 'saved items are gone');
select zm_test.expect_equal(zm_test.q(format($q$select count(*)::text from public.saved_addresses where user_id = %L$q$, :'GONE')), '0', 'addresses are gone');
select zm_test.expect_equal(zm_test.q(format($q$select email from auth.users where id = %L$q$, :'GONE')), 'deleted-' || :'GONE' || '@deleted.invalid', 'email is replaced');
select zm_test.expect_equal(zm_test.q(format($q$select count(*)::text from public.orders where buyer_id = %L$q$, :'GONE')), '1', 'the order record stays for the seller');
select zm_test.expect_equal(zm_test.q($q$select count(*)::text from public.audit_logs where action = 'account.deleted'$q$), '1', 'the deletion is audited');
select zm_test.act_as(:'GONE');
select zm_test.expect_error('select public.account_delete()', 'deleting twice is refused');

rollback;
