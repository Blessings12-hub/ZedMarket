-- Account Hub: the queries the Profile tab and its new pages run, checked against the security rules. Each person sees
-- only their own reviews written, cases, orders and memberships; staff who can read every dispute still get only
-- their own in "my cases"; profile edits cannot change verification or someone else's profile.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/account_hub.sql

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

select zm_test.act_as_admin();
insert into zm_ids values ('l1', zm_test.fresh_listing(100));
set session_replication_role = replica;
insert into public.orders (id, listing_id, buyer_id, seller_id, item_title, item_price_zmw, fulfilment, status, buyer_name, seller_name, created_at, confirmed_at, completed_at)
values ('40000000-0000-0000-0000-000000000001', (select id from zm_ids where name = 'l1'), :'B', :'S', 'Item', 100, 'collection', 'completed', 'Buyer', 'Seller', now() - interval '3 days', now() - interval '3 days', now() - interval '2 days'),
       ('40000000-0000-0000-0000-000000000002', (select id from zm_ids where name = 'l1'), :'B', :'S', 'Item', 100, 'collection', 'requested', 'Buyer', 'Seller', now() - interval '1 day', null, null);
insert into public.reviews (order_id, reviewer_id, reviewee_id, rating, comment) values ('40000000-0000-0000-0000-000000000001', :'B', :'S', 5, 'Great');
insert into public.reviews (order_id, reviewer_id, reviewee_id, rating, is_hidden) values ('40000000-0000-0000-0000-000000000001', :'S', :'B', 1, true);
insert into public.disputes (order_id, opened_by, reason, status) values ('40000000-0000-0000-0000-000000000001', :'B', 'Item not as described', 'open');
set session_replication_role = origin;

-- "my cases" as the app asks for them: appeals and reports as the person, disputes through the order's two people
select zm_test.act_as(:'B');
insert into public.appeals (target_type, target_id, message) values ('user', :'B', 'Please look again');
insert into public.reports (target_type, target_id, reason, details)
  select 'user', :'S', e.enumlabel::public.report_reason, 'x' from pg_enum e where e.enumtypid = 'public.report_reason'::regtype order by e.enumsortorder limit 1;

select zm_test.act_as_admin();
create function zm_test.my_disputes(p_uid uuid) returns text language sql stable as $$
  select count(*)::text from public.disputes d join public.orders o on o.id = d.order_id where o.buyer_id = p_uid or o.seller_id = p_uid;
$$;
grant execute on function zm_test.my_disputes(uuid) to anon, authenticated, service_role;

select zm_test.act_as(:'B');
select zm_test.expect_equal(zm_test.my_disputes(:'B'), '1', 'buyer sees the dispute they opened');
select zm_test.expect_equal((select count(*)::text from public.appeals where user_id = :'B'), '1', 'own appeals');
select zm_test.expect_equal((select count(*)::text from public.reports where reporter_id = :'B'), '1', 'own reports');
select zm_test.expect_equal((select count(*)::text from public.reviews where reviewer_id = :'B'), '1', 'reviews I wrote');
select zm_test.expect_equal((select count(*)::text from public.reviews where reviewee_id = :'B' and not is_hidden), '0', 'a hidden review about me is not listed');
select zm_test.expect_equal((select count(*)::text from public.orders where buyer_id = :'B' and status in ('requested','confirmed')), '1', 'open purchases count');
select zm_test.act_as(:'S');
select zm_test.expect_equal(zm_test.my_disputes(:'S'), '1', 'the seller is a party too');
select zm_test.expect_equal((select count(*)::text from public.orders where seller_id = :'S' and business_id is null and status = 'requested'), '1', 'requests waiting for the seller');
select zm_test.expect_equal((select count(*)::text from public.appeals where user_id = :'S'), '0', 'seller sees no one elses appeals');
select zm_test.expect_equal((select count(*)::text from public.reports where reporter_id = :'S'), '0', 'seller made no reports');

select zm_test.act_as(:'C');
select zm_test.expect_equal((select count(*)::text from public.disputes), '0', 'an outsider cannot read any dispute');
select zm_test.expect_equal(zm_test.my_disputes(:'C'), '0', 'outsider has no cases');
select zm_test.expect_equal((select count(*)::text from public.appeals), '0', 'an outsider cannot read appeals');
select zm_test.expect_equal((select count(*)::text from public.reports), '0', 'an outsider cannot read reports');
select zm_test.expect_equal((select count(*)::text from public.orders), '0', 'an outsider cannot read orders');
select zm_test.expect_equal((select count(*)::text from public.business_members where user_id = :'C'), '0', 'no memberships');
select zm_test.expect_equal((select count(*)::text from public.business_members where user_id = :'S'), '0', 'cannot list another person''s memberships');

-- Staff can read every dispute and report, but "my cases" must still show only their own
select zm_test.act_as(:'SUP', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.disputes), '1', 'support can read all disputes (needed for their queue)');
select zm_test.expect_equal(zm_test.my_disputes(:'SUP'), '0', 'but their personal case list stays empty');
select zm_test.expect_equal((select count(*)::text from public.reports where reporter_id = :'SUP'), '0', 'staff personal report history is only their own');

-- Memberships the hub reads
select zm_test.act_as(:'MGR');
select zm_test.expect_equal((select string_agg(role::text, ',') from public.business_members where user_id = :'MGR'), 'manager', 'manager sees own role');
select zm_test.expect_equal((select (b.verification_status::text) from public.business_members m join public.businesses b on b.id = m.business_id where m.user_id = :'MGR'), 'unverified', 'business verification status is readable by members');

-- Profile edits
select zm_test.act_as(:'B');
update public.profiles set display_name = 'Bwalya B', bio = 'Hello', avatar_path = :'B' || '/avatar-1.jpg' where id = :'B';
select zm_test.expect_equal((select display_name from public.profiles where id = :'B'), 'Bwalya B', 'name changed');
select zm_test.expect_error($$update public.profiles set verification_level = 'identity_verified' where id = '00000000-0000-0000-0000-00000000000b'$$, 'cannot grant themselves verification');
select zm_test.expect_error($$update public.profiles set account_state = 'active' where id = '00000000-0000-0000-0000-00000000000b'$$, 'cannot change account state');
select zm_test.expect_error($$update public.profiles set display_name = 'x' where id = '00000000-0000-0000-0000-00000000000b'$$, 'name too short');
select zm_test.expect_error($$update public.profiles set bio = repeat('a', 501) where id = '00000000-0000-0000-0000-00000000000b'$$, 'bio too long');
update public.profiles set display_name = 'Hijacked' where id = :'C';
select zm_test.act_as_admin();
select zm_test.expect_equal((select display_name from public.profiles where id = :'C'), 'Third Thandi', 'another person''s profile is untouched');

-- Guests see none of it
select zm_test.act_as_guest();
select zm_test.expect_error($$select count(*) from public.orders$$, 'guests cannot read orders');
select zm_test.expect_error($$select count(*) from public.disputes$$, 'guests cannot read disputes');
select zm_test.expect_error($$select count(*) from public.business_members$$, 'guests cannot read memberships');

select 'Account hub checks passed' as result;
rollback;
