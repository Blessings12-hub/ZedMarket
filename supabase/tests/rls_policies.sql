-- Row level security checks. Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls_policies.sql
--
-- Everything happens inside one transaction that is rolled back at the end.
-- If a check fails, the script stops with a message saying which one.

begin;

-- 1. Every table in public must have row level security switched on.
do $$
declare
  missing text;
begin
  select string_agg(tablename, ', ') into missing
    from pg_tables
   where schemaname = 'public' and not rowsecurity;
  if missing is not null then
    raise exception 'RLS is off for: %', missing;
  end if;
end $$;

-- Helpers. act_as() pretends to be a signed-in user for the rest of the transaction.
create schema zm_test;
grant usage on schema zm_test to authenticated;

create function zm_test.act_as(p_user uuid, p_aal text default 'aal1') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  execute 'set local role authenticated';
end $$;

create function zm_test.act_as_admin() returns void
language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
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

-- 2. Test people: two ordinary users, one outsider, one moderator.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'seller@example.test', '{"display_name":"Seller Test"}'),
  ('00000000-0000-0000-0000-00000000000b', 'buyer@example.test',  '{"display_name":"Buyer Test"}'),
  ('00000000-0000-0000-0000-00000000000c', 'other@example.test',  '{"display_name":"Other Test"}'),
  ('00000000-0000-0000-0000-00000000000d', 'staff@example.test',  '{"display_name":"Staff Test"}');

insert into public.admin_roles (user_id, role) values ('00000000-0000-0000-0000-00000000000d', 'moderator');

-- 3. Seller creates one draft and one published listing.
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');

insert into public.listings (id, category_id, location_id, title, description, price_zmw, condition)
select '10000000-0000-0000-0000-000000000001', c.id, l.id, 'Test phone', 'Works well', 500, 'used_good'
  from public.categories c, public.locations l where c.slug = 'electronics' and l.area = 'Kabulonga';

insert into public.listings (id, category_id, location_id, title, description, price_zmw, condition)
select '10000000-0000-0000-0000-000000000002', c.id, l.id, 'Hidden draft', 'Not published', 300, 'new'
  from public.categories c, public.locations l where c.slug = 'electronics' and l.area = 'Kabulonga';

insert into public.listing_images (listing_id, storage_path)
values ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a/phone.jpg');

update public.listings set status = 'active' where id = '10000000-0000-0000-0000-000000000001';

do $$
begin
  if (select moderation_status from public.listings where id = '10000000-0000-0000-0000-000000000001') <> 'approved' then
    raise exception 'A small listing from an ordinary seller should be approved automatically';
  end if;
end $$;

-- Publishing without a photo must fail.
select zm_test.expect_error(
  $$update public.listings set status = 'active' where id = '10000000-0000-0000-0000-000000000002'$$,
  'publishing without a photo');

-- Profile protection: a user cannot promote their own verification level.
select zm_test.expect_error(
  $$update public.profiles set verification_level = 'identity_verified' where id = '00000000-0000-0000-0000-00000000000a'$$,
  'self-verification');

-- 4. Buyer sees the published listing but not the draft, and cannot edit either.
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');

do $$
declare
  seen integer;
  changed integer;
begin
  select count(*) into seen from public.listings
   where id in ('10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002');
  if seen <> 1 then
    raise exception 'Buyer should see exactly 1 of the 2 listings, saw %', seen;
  end if;

  update public.listings set title = 'Hijacked' where id = '10000000-0000-0000-0000-000000000001';
  get diagnostics changed = row_count;
  if changed <> 0 then
    raise exception 'Buyer was able to edit someone else''s listing';
  end if;
end $$;

-- 5. Orders: buyer creates one, outsider cannot see it, wrong person cannot complete it.
do $$
declare
  o public.orders;
begin
  o := public.create_order('10000000-0000-0000-0000-000000000001', 'collection');
  perform set_config('zm.order_id', o.id::text, true);
  if o.item_price_zmw <> 500 then
    raise exception 'Order did not snapshot the price';
  end if;
end $$;

select zm_test.expect_error(
  format($$select public.set_order_status(%L, 'completed')$$, current_setting('zm.order_id')),
  'buyer completing an order that is not confirmed');

select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
do $$
begin
  if (select count(*) from public.orders) <> 0 then
    raise exception 'An outsider can read orders';
  end if;
end $$;

-- Seller confirms, buyer completes, then the listing shows as sold.
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select public.set_order_status(current_setting('zm.order_id')::uuid, 'confirmed');

select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select public.set_order_status(current_setting('zm.order_id')::uuid, 'completed');

do $$
begin
  if (select status from public.listings where id = '10000000-0000-0000-0000-000000000001') <> 'sold' then
    raise exception 'Listing should be sold after the order completes';
  end if;
  -- The buyer reviews the seller once.
  insert into public.reviews (order_id, rating, comment)
  values (current_setting('zm.order_id')::uuid, 5, 'Smooth');
end $$;

select zm_test.expect_error(
  format($$insert into public.reviews (order_id, rating) values (%L, 4)$$, current_setting('zm.order_id')),
  'a second review from the same person');

-- 6. Messages: members can read, outsiders cannot.
select zm_test.act_as_admin();
update public.listings set status = 'active' where id = '10000000-0000-0000-0000-000000000001';

select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
do $$
declare
  conv uuid;
begin
  conv := public.start_conversation('10000000-0000-0000-0000-000000000001');
  perform set_config('zm.conv_id', conv::text, true);
  insert into public.messages (conversation_id, body) values (conv, 'Is it still available?');
end $$;

select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
do $$
begin
  if (select count(*) from public.messages) <> 1 then
    raise exception 'The seller should see the buyer''s message';
  end if;
end $$;

select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
do $$
begin
  if (select count(*) from public.messages) <> 0 then
    raise exception 'An outsider can read messages';
  end if;
end $$;

-- 7. Staff actions: refused for ordinary users, refused without MFA, allowed with it.
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_error(
  $$select public.moderate_listing('10000000-0000-0000-0000-000000000001', 'rejected', 'x')$$,
  'ordinary user moderating');

select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal1');
select zm_test.expect_error(
  $$select public.moderate_listing('10000000-0000-0000-0000-000000000001', 'rejected', 'x')$$,
  'moderator without a second factor');

select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal2');
select public.moderate_listing('10000000-0000-0000-0000-000000000001', 'rejected', 'Test decision');

-- The action must leave an audit trail, readable only by technical admins.
select zm_test.act_as_admin();
do $$
begin
  if not exists (select 1 from public.audit_logs where action = 'listing.moderated') then
    raise exception 'moderate_listing did not write an audit log';
  end if;
end $$;

select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal2');
do $$
begin
  if (select count(*) from public.audit_logs) <> 0 then
    raise exception 'A moderator should not be able to read the audit log';
  end if;
end $$;

-- 8. Newer staff actions follow the same rules.
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_error(
  $$select public.set_review_hidden('10000000-0000-0000-0000-0000000000aa', true, 'x')$$,
  'ordinary user hiding a review');
select zm_test.expect_error(
  $$select public.mark_risk_flag_reviewed('10000000-0000-0000-0000-0000000000bb')$$,
  'ordinary user closing a risk flag');
select zm_test.expect_error(
  $$select public.grant_admin_role('00000000-0000-0000-0000-00000000000b', 'tech_admin')$$,
  'ordinary user granting a staff role');

select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal1');
select zm_test.expect_error(
  $$select public.set_review_hidden('10000000-0000-0000-0000-0000000000aa', true, 'x')$$,
  'moderator without a second factor hiding a review');

rollback;

select 'All RLS checks passed' as result;
