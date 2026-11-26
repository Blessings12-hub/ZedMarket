-- Business Hub (migration 0011): role permissions, invitations, branches, catalogues, the public
-- storefront, inventory, business orders and analytics.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/business_hub.sql

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


insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@example.test',   '{"display_name":"Owner Olive"}', now()),
  ('00000000-0000-0000-0000-00000000000b', 'manager@example.test', '{"display_name":"Manager Mwila"}', now()),
  ('00000000-0000-0000-0000-00000000000c', 'staff@example.test',   '{"display_name":"Staff Sipho"}', now()),
  ('00000000-0000-0000-0000-00000000000d', 'outsider@example.test','{"display_name":"Outsider Omar"}', now()),
  ('00000000-0000-0000-0000-00000000000e', 'invitee@example.test', '{"display_name":"Invitee Ines"}', now()),
  ('00000000-0000-0000-0000-00000000000f', 'buyer@example.test',   '{"display_name":"Buyer Bwalya"}', now()),
  ('00000000-0000-0000-0000-000000000010', 'unconfirmed@example.test', '{"display_name":"Unconfirmed Una"}', null),
  ('00000000-0000-0000-0000-000000000002', 'owner2@example.test',  '{"display_name":"Second Owner"}', now());

insert into public.businesses (id, owner_id, name, slug, description) values
  ('20000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000a', 'Olive Electronics', 'olive-electronics', 'Phones and chargers'),
  ('20000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000002', 'Other Shop', 'other-shop', 'Not ours');
-- Business listings go live only for verified businesses (migration 0027); these fixtures are verified.
update public.businesses set publish_state = 'active', registration_kind = 'registered';
-- The owner is added as a member by a trigger. The manager and staff are added directly (setup only).
insert into public.business_members (business_id, user_id, role) values
  ('20000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b', 'manager'),
  ('20000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000c', 'staff');

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


create function zm_test.perms(p_business uuid) returns text language sql as $$
  select string_agg(case when public.business_can(p_business, p) then 't' else 'f' end, '' order by n)
    from unnest(array['view_team','manage_team','edit_profile','manage_branches','manage_catalogues','manage_listings','manage_inventory','manage_orders','view_analytics']) with ordinality as x(p, n);
$$;

grant execute on all functions in schema zm_test to anon, authenticated, service_role;
create temp table zm_ids (name text primary key, id uuid);
grant all on zm_ids to anon, authenticated, service_role;

\set O '00000000-0000-0000-0000-00000000000a'
\set M '00000000-0000-0000-0000-00000000000b'
\set S '00000000-0000-0000-0000-00000000000c'
\set X '00000000-0000-0000-0000-00000000000d'
\set I '00000000-0000-0000-0000-00000000000e'
\set F '00000000-0000-0000-0000-00000000000f'
\set U '00000000-0000-0000-0000-000000000010'
\set BIZ '20000000-0000-0000-0000-00000000000a'
\set OTHER '20000000-0000-0000-0000-000000000002'

-- 1. The permission table
select zm_test.act_as(:'O');
select zm_test.expect_equal(zm_test.perms(:'BIZ'), 'ttttttttt', 'owner permissions');
select zm_test.act_as(:'M');
select zm_test.expect_equal(zm_test.perms(:'BIZ'), 'tfttttttt', 'manager permissions');
select zm_test.act_as(:'S');
select zm_test.expect_equal(zm_test.perms(:'BIZ'), 'tfffftttf', 'staff permissions');
select zm_test.act_as(:'X');
select zm_test.expect_equal(zm_test.perms(:'BIZ'), 'fffffffff', 'outsider permissions');
select zm_test.expect_equal(zm_test.perms(:'OTHER'), 'fffffffff', 'outsider on another business');
select zm_test.act_as(:'O');
select zm_test.expect_equal(zm_test.perms(:'OTHER'), 'fffffffff', 'owner of one business has nothing on another');
select zm_test.expect_error(format($$select public.business_can(%L, 'fly')$$, :'BIZ'), 'unknown permission name');
select zm_test.act_as_guest();
select zm_test.expect_error(format($$select public.business_can(%L, 'view_team')$$, :'BIZ'), 'a guest calling business_can');
select zm_test.act_as_admin();
update public.profiles set account_state = 'suspended' where id = :'S';
select zm_test.act_as(:'S');
select zm_test.expect_equal(zm_test.perms(:'BIZ'), 'fffffffff', 'a suspended member has no business permissions');
select zm_test.act_as_admin();
update public.profiles set account_state = 'active' where id = :'S';

-- 2. Team and invitations
select zm_test.act_as(:'M');
select zm_test.expect_error(format($$select public.invite_member(%L, 'invitee@example.test', 'staff')$$, :'BIZ'), 'a manager inviting');
select zm_test.act_as(:'X');
select zm_test.expect_error(format($$select public.invite_member(%L, 'invitee@example.test', 'staff')$$, :'BIZ'), 'an outsider inviting');
select zm_test.act_as(:'O');
select zm_test.expect_error(format($$select public.invite_member(%L, 'not-an-email', 'staff')$$, :'BIZ'), 'bad email');
select zm_test.expect_error(format($$select public.invite_member(%L, 'invitee@example.test', 'owner')$$, :'BIZ'), 'inviting as owner');
select zm_test.expect_error(format($$select public.invite_member(%L, 'MANAGER@example.test ', 'staff')$$, :'BIZ'), 'inviting someone already on the team (case and spaces ignored)');
insert into zm_ids values ('inv1', public.invite_member(:'BIZ', '  Invitee@Example.test ', 'manager'));
select zm_test.expect_error(format($$select public.invite_member(%L, 'invitee@example.test', 'staff')$$, :'BIZ'), 'a second open invitation for the same email');
select zm_test.expect_equal((select count(*)::text from public.business_open_invitations(:'BIZ')), '1', 'owner sees the open invitation');
select zm_test.act_as(:'M');
select zm_test.expect_error(format($$select * from public.business_open_invitations(%L)$$, :'BIZ'), 'a manager listing invitations');
select zm_test.act_as(:'X');
select zm_test.expect_equal((select count(*)::text from public.my_invitations()), '0', 'someone else sees no invitation');
select zm_test.expect_error(format($$select public.respond_invitation(%L, true)$$, (select id from zm_ids where name = 'inv1')), 'accepting an invitation sent to someone else');
select zm_test.act_as(:'I');
select zm_test.expect_equal((select business_name || ':' || role::text from public.my_invitations()), 'Olive Electronics:manager', 'invitee sees it');
select zm_test.expect_error($$select * from public.business_invitations$$, 'reading the invitations table directly');
select public.respond_invitation((select id from zm_ids where name = 'inv1'), true);
select zm_test.expect_error(format($$select public.respond_invitation(%L, true)$$, (select id from zm_ids where name = 'inv1')), 'accepting twice');
select zm_test.expect_equal(zm_test.perms(:'BIZ'), 'tfttttttt', 'the new manager has manager permissions');
select zm_test.expect_equal((select count(*)::text from public.my_invitations()), '0', 'accepted invitation disappears');

-- Unconfirmed email cannot accept
select zm_test.act_as(:'O');
insert into zm_ids values ('inv2', public.invite_member(:'BIZ', 'unconfirmed@example.test', 'staff'));
select zm_test.act_as(:'U');
select zm_test.expect_equal((select count(*)::text from public.my_invitations()), '0', 'unconfirmed email sees nothing');
select zm_test.expect_error(format($$select public.respond_invitation(%L, true)$$, (select id from zm_ids where name = 'inv2')), 'accepting with an unconfirmed email');
-- Revoke, expiry, decline
select zm_test.act_as(:'M');
select zm_test.expect_error(format($$select public.revoke_invitation(%L)$$, (select id from zm_ids where name = 'inv2')), 'a manager revoking');
select zm_test.act_as(:'O');
select public.revoke_invitation((select id from zm_ids where name = 'inv2'));
select zm_test.expect_error(format($$select public.revoke_invitation(%L)$$, (select id from zm_ids where name = 'inv2')), 'revoking twice');
insert into zm_ids values ('inv3', public.invite_member(:'BIZ', 'unconfirmed@example.test', 'staff'));
select zm_test.act_as_admin();
update public.business_invitations set expires_at = now() - interval '1 hour' where id = (select id from zm_ids where name = 'inv3');
select zm_test.act_as(:'U');
select zm_test.expect_equal((select count(*)::text from public.my_invitations()), '0', 'expired invitation is not offered');
select zm_test.expect_error(format($$select public.respond_invitation(%L, true)$$, (select id from zm_ids where name = 'inv3')), 'accepting an expired invitation');
select zm_test.act_as(:'O');
insert into zm_ids values ('inv4', public.invite_member(:'BIZ', 'unconfirmed@example.test', 'staff'));
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.business_invitations where status = 'revoked'), '2', 'the stale invitation was replaced');
select zm_test.act_as(:'O');

-- Direct writes are closed
select zm_test.expect_error(format($$insert into public.business_members (business_id, user_id, role) values (%L, %L, 'staff')$$, :'BIZ', :'X'), 'owner inserting a member directly');
select zm_test.expect_error(format($$delete from public.business_members where business_id = %L and user_id = %L$$, :'BIZ', :'S'), 'owner deleting a member directly');
-- Roles and removal
select zm_test.expect_error(format($$select public.set_member_role(%L, %L, 'manager')$$, :'BIZ', :'O'), 'changing own role');
select zm_test.expect_error(format($$select public.set_member_role(%L, %L, 'owner')$$, :'BIZ', :'S'), 'making someone owner');
select zm_test.expect_error(format($$select public.set_member_role(%L, %L, 'staff')$$, :'BIZ', :'X'), 'role of a non-member');
select public.set_member_role(:'BIZ', :'S', 'manager');
select zm_test.act_as(:'S');
select zm_test.expect_equal(zm_test.perms(:'BIZ'), 'tfttttttt', 'promoted member has manager permissions');
select zm_test.act_as(:'O');
select public.set_member_role(:'BIZ', :'S', 'staff');
select zm_test.act_as(:'M');
select zm_test.expect_error(format($$select public.set_member_role(%L, %L, 'manager')$$, :'BIZ', :'S'), 'manager changing roles');
select zm_test.expect_error(format($$select public.remove_member(%L, %L)$$, :'BIZ', :'S'), 'manager removing someone');
select zm_test.expect_error(format($$select public.remove_member(%L, %L)$$, :'BIZ', :'O'), 'removing the owner');
select zm_test.expect_equal((select string_agg(display_name || ':' || role::text, ',' order by display_name) from public.business_team(:'BIZ')), 'Invitee Ines:manager,Manager Mwila:manager,Owner Olive:owner,Staff Sipho:staff', 'team list');
select zm_test.act_as(:'X');
select zm_test.expect_error(format($$select * from public.business_team(%L)$$, :'BIZ'), 'an outsider reading the team');
-- Leaving by choice
select zm_test.act_as(:'I');
select public.remove_member(:'BIZ', :'I');
select zm_test.expect_equal(zm_test.perms(:'BIZ'), 'fffffffff', 'someone who left has no permissions');
select zm_test.act_as(:'O');
select zm_test.expect_error(format($$select public.remove_member(%L, %L)$$, :'BIZ', :'O'), 'the owner leaving');
select public.remove_member(:'BIZ', :'M');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action in ('business.invited', 'business.member_joined', 'business.role_changed', 'business.member_removed', 'business.invitation_revoked')), '10', 'team changes are audited');
-- A confirmed invitee cannot accept after the invitation has expired
select zm_test.act_as(:'O');
insert into zm_ids values ('inv5', public.invite_member(:'BIZ', 'invitee@example.test', 'staff'));
select zm_test.act_as_admin();
update public.business_invitations set expires_at = now() - interval '1 minute' where id = (select id from zm_ids where name = 'inv5');
select zm_test.act_as(:'I');
select zm_test.expect_error(format($$select public.respond_invitation(%L, true)$$, (select id from zm_ids where name = 'inv5')), 'accepting an expired invitation (confirmed email)');
select zm_test.act_as_admin();
-- put the manager back for the next sections
insert into public.business_members (business_id, user_id, role) values (:'BIZ', :'M', 'manager');

-- 3. Branches
select zm_test.act_as(:'S');
select zm_test.expect_error(format($$select public.create_branch(%L, 'Cairo Road')$$, :'BIZ'), 'staff creating a branch');
select zm_test.act_as(:'M');
insert into zm_ids values ('br_main', public.create_branch(:'BIZ', 'Kabulonga Shop', (select id from public.locations where area = 'Kabulonga'), 'Plot 5', '+260 971 234 567'));
insert into zm_ids values ('br_two', public.create_branch(:'BIZ', 'Cairo Road Shop'));
select zm_test.expect_equal((select name from public.business_branches where business_id = :'BIZ' and is_main), 'Kabulonga Shop', 'the first branch is the main one');
select zm_test.expect_error(format($$select public.create_branch(%L, 'Cairo Road Shop')$$, :'BIZ'), 'duplicate branch name');
select zm_test.expect_error(format($$select public.create_branch(%L, 'Bad Phone', null, null, 'call me')$$, :'BIZ'), 'bad phone');
select zm_test.expect_error(format($$select public.create_branch(%L, 'x')$$, :'BIZ'), 'one-letter branch name');
select zm_test.act_as(:'X');
select zm_test.expect_error(format($$select public.create_branch(%L, 'Sneaky')$$, :'BIZ'), 'outsider creating a branch');
select zm_test.expect_equal((select count(*)::text from public.business_branches), '0', 'outsider cannot read branches');
select zm_test.act_as(:'S');
select zm_test.expect_equal((select count(*)::text from public.business_branches), '2', 'staff can read branches');
select zm_test.act_as(:'M');
select zm_test.expect_error(format($$select public.update_branch(%L, 'Kabulonga Shop', null, null, null, false, true)$$, (select id from zm_ids where name = 'br_main')), 'switching off the main branch');
select zm_test.expect_error(format($$select public.update_branch(%L, 'Kabulonga Shop', null, null, null, true, false)$$, (select id from zm_ids where name = 'br_main')), 'un-marking the main branch');
-- A listing in a branch
select zm_test.act_as_admin();
insert into zm_ids values ('l1', zm_test.fresh_listing(500, :'BIZ'));
update public.listings set branch_id = (select id from zm_ids where name = 'br_two') where id = (select id from zm_ids where name = 'l1');
select zm_test.expect_error(format($$update public.listings set branch_id = %L where id = %L$$, gen_random_uuid(), (select id from zm_ids where name = 'l1')), 'a branch that does not exist');
select zm_test.act_as(:'M');
select zm_test.expect_error(format($$select public.update_branch(%L, 'Cairo Road Shop', null, null, null, false, false)$$, (select id from zm_ids where name = 'br_two')), 'switching off a branch that has active listings');
select public.update_branch((select id from zm_ids where name = 'br_two'), 'Cairo Road Shop', null, 'Shop 12', null, true, true);
select zm_test.expect_equal((select name from public.business_branches where business_id = :'BIZ' and is_main), 'Cairo Road Shop', 'making another branch main moves the flag');
select zm_test.expect_equal((select count(*)::text from public.business_branches where business_id = :'BIZ' and is_main), '1', 'only one main branch');
-- a branch of another business cannot be used
select zm_test.act_as_admin();
insert into public.business_branches (id, business_id, name) values ('40000000-0000-0000-0000-000000000002', :'OTHER', 'Elsewhere');
select zm_test.expect_error(format($$update public.listings set branch_id = '40000000-0000-0000-0000-000000000002' where id = %L$$, (select id from zm_ids where name = 'l1')), 'using another business''s branch');

-- 4. Catalogues
select zm_test.act_as(:'S');
select zm_test.expect_error(format($$select public.create_catalogue(%L, 'Phones')$$, :'BIZ'), 'staff creating a catalogue');
select zm_test.act_as(:'M');
insert into zm_ids values ('cat1', public.create_catalogue(:'BIZ', 'Phones', 'All our phones'));
insert into zm_ids values ('cat2', public.create_catalogue(:'BIZ', 'Chargers'));
select zm_test.expect_error(format($$select public.create_catalogue(%L, 'Phones')$$, :'BIZ'), 'duplicate catalogue name');
select zm_test.act_as_admin();
insert into zm_ids values ('l2', zm_test.fresh_listing(300, :'BIZ'));
insert into zm_ids values ('l_foreign', zm_test.fresh_listing(100, :'OTHER'));
select zm_test.act_as(:'M');
select zm_test.expect_error(format($$select public.set_catalogue_listings(%L, array[%L]::uuid[])$$, (select id from zm_ids where name = 'cat1'), (select id from zm_ids where name = 'l_foreign')), 'adding another business''s listing');
select public.set_catalogue_listings((select id from zm_ids where name = 'cat1'), array[(select id from zm_ids where name = 'l2'), (select id from zm_ids where name = 'l1')]);
select zm_test.expect_equal((select count(*)::text from public.catalogue_listings), '2', 'two listings in the catalogue');
select zm_test.act_as(:'X');
select zm_test.expect_error(format($$select public.delete_catalogue(%L)$$, (select id from zm_ids where name = 'cat2')), 'an outsider deleting a catalogue');
select zm_test.expect_error(format($$select public.set_catalogue_listings(%L, array[]::uuid[])$$, (select id from zm_ids where name = 'cat1')), 'an outsider editing a catalogue');
select zm_test.act_as(:'M');
select public.update_catalogue((select id from zm_ids where name = 'cat2'), 'Chargers and cables', null, false, 5);

-- 5. Public storefront
select zm_test.act_as_guest();
select zm_test.expect_equal((select name || ':' || slug || ':' || listing_count::text from public.public_businesses where id = :'BIZ'), 'Olive Electronics:olive-electronics:2', 'guest sees the storefront');
select zm_test.expect_error($$select * from public.businesses$$, 'a guest reading the businesses table');
select zm_test.expect_error($$select * from public.business_members$$, 'a guest reading members');
select zm_test.expect_equal((select string_agg(name, ',') from public.public_business_catalogues where business_id = :'BIZ'), 'Phones', 'only visible catalogues are public');
select zm_test.expect_equal((select string_agg(name, ',' order by name) from public.public_business_branches where business_id = :'BIZ'), 'Cairo Road Shop,Kabulonga Shop', 'public branches');
select zm_test.expect_equal((select count(*)::text from public.business_storefront_listings(:'BIZ')), '2', 'storefront lists the business''s listings');
select zm_test.expect_equal((select count(*)::text from public.business_storefront_listings(:'BIZ', (select id from zm_ids where name = 'cat1'))), '2', 'catalogue filter');
select zm_test.expect_equal((select count(*)::text from public.business_storefront_listings(:'BIZ', (select id from zm_ids where name = 'cat2'))), '0', 'hidden catalogue shows nothing');
select zm_test.expect_equal((select count(*)::text from public.business_storefront_listings(:'BIZ', null, '%')), '0', 'a percent sign is not a wildcard');
select zm_test.expect_equal((select count(*)::text from public.business_storefront_listings(:'BIZ', null, null, 1, 0)), '1', 'storefront limit');
select zm_test.expect_equal((select branch_name from public.business_storefront_listings(:'BIZ') where id = (select id from zm_ids where name = 'l1')), 'Cairo Road Shop', 'storefront shows the branch');
select zm_test.expect_equal((select count(*)::text from public.business_storefront_listings(:'OTHER')), '1', 'other business storefront is separate');
select zm_test.act_as_admin();
insert into zm_ids select 'bulk' || g, zm_test.fresh_listing(10, :'OTHER') from generate_series(1, 65) g;
select zm_test.act_as_guest();
select zm_test.expect_equal((select count(*)::text from public.business_storefront_listings(:'OTHER', null, null, 100000, 0)), '60', 'storefront page is capped at 60');
select zm_test.act_as_admin();
update public.listings set moderation_status = 'pending' where id = (select id from zm_ids where name = 'l2');
select zm_test.act_as_guest();
select zm_test.expect_equal((select count(*)::text from public.business_storefront_listings(:'BIZ')), '1', 'unapproved listing is hidden from the storefront');
select zm_test.act_as_admin();
update public.listings set moderation_status = 'approved' where id = (select id from zm_ids where name = 'l2');
update public.profiles set account_state = 'suspended' where id = :'O';
select zm_test.act_as_guest();
select zm_test.expect_equal((select count(*)::text from public.public_businesses where id = :'BIZ'), '0', 'suspended owner: storefront gone');
select zm_test.expect_equal((select count(*)::text from public.business_storefront_listings(:'BIZ')), '0', 'suspended owner: no listings');
select zm_test.expect_equal((select count(*)::text from public.public_business_branches where business_id = :'BIZ'), '0', 'suspended owner: no branches');
select zm_test.act_as_admin();
update public.profiles set account_state = 'active' where id = :'O';

-- 6. Inventory
select zm_test.act_as(:'X');
select zm_test.expect_error(format($$select public.track_stock(%L, 5)$$, (select id from zm_ids where name = 'l1')), 'an outsider tracking stock');
select zm_test.expect_error(format($$select * from public.business_inventory(%L)$$, :'BIZ'), 'an outsider reading inventory');
select zm_test.act_as(:'S');
select zm_test.expect_error(format($$select public.track_stock(%L, -1)$$, (select id from zm_ids where name = 'l1')), 'negative starting stock');
select public.track_stock((select id from zm_ids where name = 'l1'), 2, 1);
select public.track_stock((select id from zm_ids where name = 'l2'), 1);
select zm_test.expect_error(format($$select public.track_stock(%L, 5)$$, (select id from zm_ids where name = 'l1')), 'tracking twice');
select zm_test.expect_error(format($$select public.adjust_stock(%L, 0, 'correction')$$, (select id from zm_ids where name = 'l1')), 'zero change');
select zm_test.expect_error(format($$select public.adjust_stock(%L, -5, 'damaged')$$, (select id from zm_ids where name = 'l1')), 'taking more than is in stock');
select zm_test.expect_error(format($$select public.adjust_stock(%L, -1, 'restock')$$, (select id from zm_ids where name = 'l1')), 'a restock that removes stock');
select zm_test.expect_error(format($$select public.adjust_stock(%L, 1, 'damaged')$$, (select id from zm_ids where name = 'l1')), 'damaged stock that adds');
select zm_test.expect_error(format($$select public.adjust_stock(%L, 1, 'gift')$$, (select id from zm_ids where name = 'l1')), 'unknown reason');
select zm_test.expect_error(format($$select public.adjust_stock(%L, 1, 'restock')$$, (select id from zm_ids where name = 'l_foreign')), 'adjusting an untracked listing');
select zm_test.expect_equal((select public.adjust_stock((select id from zm_ids where name = 'l1'), 3, 'restock', 'New delivery'))::text, '5', 'restock adds');
select zm_test.expect_equal((select string_agg(reason || ':' || change::text || ':' || quantity_after::text, ',' order by id) from public.stock_history((select id from zm_ids where name = 'l1'))), 'initial:2:2,restock:3:5', 'stock history');
select zm_test.expect_equal((select quantity::text || ':' || is_low::text from public.business_inventory(:'BIZ') where listing_id = (select id from zm_ids where name = 'l1')), '5:false', 'not low at 5');
select public.adjust_stock((select id from zm_ids where name = 'l1'), -4, 'damaged');
select zm_test.expect_equal((select count(*)::text from public.business_inventory(:'BIZ', 'low')), '2', 'low-stock filter (at or below the level)');
select public.set_low_stock_level((select id from zm_ids where name = 'l1'), 0);
select zm_test.expect_equal((select count(*)::text from public.business_inventory(:'BIZ', 'untracked')), '0', 'everything is tracked');
-- Selling out pauses the listing; restocking brings it back
select public.adjust_stock((select id from zm_ids where name = 'l2'), -1, 'damaged');
select zm_test.act_as_admin();
select zm_test.expect_equal((select status::text from public.listings where id = (select id from zm_ids where name = 'l2')), 'unavailable', 'zero stock pauses the listing');
select zm_test.expect_equal((select count(*)::text from public.public_listings where id = (select id from zm_ids where name = 'l2')), '0', 'paused listing is not public');
select zm_test.act_as(:'S');
select zm_test.expect_equal((select count(*)::text from public.business_inventory(:'BIZ', 'out')), '1', 'out-of-stock filter');
select public.adjust_stock((select id from zm_ids where name = 'l2'), 4, 'restock');
select zm_test.act_as_admin();
select zm_test.expect_equal((select status::text from public.listings where id = (select id from zm_ids where name = 'l2')), 'active', 'restock brings the listing back');
-- A listing the owner paused by hand is not revived by a restock
update public.listings set status = 'unavailable' where id = (select id from zm_ids where name = 'l2');
select zm_test.act_as(:'S');
select public.adjust_stock((select id from zm_ids where name = 'l2'), 1, 'correction');
select zm_test.act_as_admin();
select zm_test.expect_equal((select status::text from public.listings where id = (select id from zm_ids where name = 'l2')), 'unavailable', 'a hand-paused listing stays paused');
update public.listings set status = 'active' where id = (select id from zm_ids where name = 'l2');

-- 7. Business orders and stock taken off by completed orders
select zm_test.act_as_admin();
delete from public.rate_limit_log;
select zm_test.act_as(:'F');
insert into zm_ids values ('o1', (public.create_order((select id from zm_ids where name = 'l1'))).id);
select zm_test.act_as(:'S');
select public.confirm_order((select id from zm_ids where name = 'o1'), 0);
select public.mark_handed_over((select id from zm_ids where name = 'o1'));
select zm_test.act_as(:'F');
select public.complete_order((select id from zm_ids where name = 'o1'));
select zm_test.act_as_admin();
select zm_test.expect_equal((select quantity::text from public.listing_stock where listing_id = (select id from zm_ids where name = 'l1')), '0', 'a completed order took one unit off (1 left after damage, now 0)');
select zm_test.expect_equal((select status::text from public.listings where id = (select id from zm_ids where name = 'l1')), 'unavailable', 'a tracked listing at zero is paused, not sold');
select zm_test.expect_equal((select string_agg(reason, ',' order by id) from public.stock_movements where listing_id = (select id from zm_ids where name = 'l1')), 'initial,restock,damaged,sale', 'the sale is in the stock history');
select zm_test.expect_equal((select (order_id is not null)::text from public.stock_movements where reason = 'sale' limit 1), 'true', 'the sale movement points at the order');
select zm_test.act_as(:'M');
select public.adjust_stock((select id from zm_ids where name = 'l1'), 5, 'restock');
select zm_test.act_as_admin();
select zm_test.expect_equal((select status::text from public.listings where id = (select id from zm_ids where name = 'l1')), 'active', 'restocking a sold-out tracked listing reopens it');
-- A tracked listing with stock left stays open after a sale; an untracked one is sold
insert into zm_ids values ('l3', zm_test.fresh_listing(250, :'BIZ'));
update public.listings set branch_id = (select id from zm_ids where name = 'br_main') where id = (select id from zm_ids where name = 'l3');
select zm_test.act_as(:'F');
insert into zm_ids values ('o2', (public.create_order((select id from zm_ids where name = 'l1'))).id);
insert into zm_ids values ('o3', (public.create_order((select id from zm_ids where name = 'l3'))).id);
select zm_test.act_as(:'S');
select public.confirm_order((select id from zm_ids where name = 'o2'), 0);
select public.confirm_order((select id from zm_ids where name = 'o3'), 0);
select public.mark_handed_over((select id from zm_ids where name = 'o2'));
select public.mark_handed_over((select id from zm_ids where name = 'o3'));
select zm_test.act_as(:'F');
select public.complete_order((select id from zm_ids where name = 'o2'));
select public.complete_order((select id from zm_ids where name = 'o3'));
select zm_test.act_as_admin();
select zm_test.expect_equal(((select quantity::text from public.listing_stock where listing_id = (select id from zm_ids where name = 'l1')) || ':' || (select status::text from public.listings where id = (select id from zm_ids where name = 'l1'))), '4:active', 'stock left: listing stays open');
select zm_test.expect_equal((select status::text from public.listings where id = (select id from zm_ids where name = 'l3')), 'sold', 'untracked listing is sold as before');
select zm_test.expect_equal((select branch_id::text from public.orders where id = (select id from zm_ids where name = 'o3')), (select id::text from zm_ids where name = 'br_main'), 'order remembers the branch');

-- Order list
select zm_test.act_as(:'F');
insert into zm_ids values ('o4', (public.create_order((select id from zm_ids where name = 'l2'))).id);
select zm_test.act_as(:'X');
select zm_test.expect_error(format($$select * from public.business_orders(%L)$$, :'BIZ'), 'an outsider reading business orders');
select zm_test.act_as(:'S');
select zm_test.expect_equal((select count(*)::text from public.business_orders(:'BIZ')), '4', 'staff see all four business orders');
select zm_test.expect_equal((select status::text from public.business_orders(:'BIZ') limit 1), 'requested', 'requests come first');
select zm_test.expect_equal((select count(*)::text from public.business_orders(:'BIZ', 'completed')), '3', 'status filter');
select zm_test.expect_equal((select count(*)::text from public.business_orders(:'BIZ', null, (select id from zm_ids where name = 'br_main'))), '1', 'branch filter');
select zm_test.expect_equal((select buyer_name from public.business_orders(:'BIZ', 'requested')), 'Buyer Bwalya', 'buyer name shown');
select zm_test.expect_equal((select count(*)::text from public.business_orders(:'BIZ', null, null, 2, 0)), '2', 'order list limit');

-- 8. Analytics
select zm_test.act_as(:'S');
select zm_test.expect_error(format($$select public.business_analytics(%L)$$, :'BIZ'), 'staff reading analytics');
select zm_test.act_as(:'X');
select zm_test.expect_error(format($$select public.business_analytics(%L)$$, :'BIZ'), 'outsider reading analytics');
select zm_test.act_as(:'M');
select zm_test.expect_equal((select public.business_analytics(:'BIZ')->>'orders_received'), '4', 'orders received');
select zm_test.expect_equal((select public.business_analytics(:'BIZ')->>'completed_orders'), '3', 'completed orders');
select zm_test.expect_equal((select (public.business_analytics(:'BIZ')->>'completed_value_zmw')::numeric::text), '1250.00', 'completed value is listed prices (500 + 500 + 250)');
select zm_test.expect_equal((select public.business_analytics(:'BIZ')->>'orders_open_now'), '1', 'open orders now');
select zm_test.expect_equal((select public.business_analytics(:'BIZ')->'orders_by_status'->>'completed'), '3', 'orders by status');
select zm_test.expect_equal((select jsonb_array_length(public.business_analytics(:'BIZ')->'top_listings')::text), '3', 'top listings');
select zm_test.expect_equal((select public.business_analytics(:'BIZ')->'top_listings'->0->>'completed'), '2', 'best seller first');
select zm_test.expect_equal((select string_agg(x->>'branch' || ':' || (x->>'orders'), ',' order by x->>'branch') from jsonb_array_elements(public.business_analytics(:'BIZ')->'by_branch') x), 'Cairo Road Shop:2,Kabulonga Shop:1,No branch:1', 'by branch');
select zm_test.expect_equal((select public.business_analytics(:'BIZ', 0)->>'period_days'), '1', 'period is clamped');
select zm_test.expect_equal((select public.business_analytics(:'BIZ', 100000)->>'period_days'), '365', 'period is clamped at a year');
select zm_test.act_as_admin();
update public.orders set completed_at = now() - interval '60 days', created_at = now() - interval '60 days' where id = (select id from zm_ids where name = 'o1');
select zm_test.act_as(:'M');
select zm_test.expect_equal((select public.business_analytics(:'BIZ')->>'completed_orders'), '2', 'old orders fall outside the 30-day window');
select zm_test.expect_equal((select public.business_analytics(:'BIZ', 90)->>'completed_orders'), '3', 'but are inside 90 days');
select zm_test.expect_equal((select sum((x->>'completed')::integer)::text from jsonb_array_elements(public.business_analytics(:'BIZ')->'top_listings') x), '2', 'top listings count only the window');
select zm_test.act_as(:'O');
select zm_test.expect_error(format($$select public.business_analytics(%L)$$, :'OTHER'), 'owner reading another business''s analytics');

-- 9. Function permissions
select zm_test.act_as_admin();
select zm_test.expect_equal((select string_agg(p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname in ('business_can','invite_member','revoke_invitation','my_invitations','respond_invitation','set_member_role','remove_member','business_team','business_open_invitations','create_branch','update_branch','create_catalogue','update_catalogue','delete_catalogue','set_catalogue_listings','track_stock','adjust_stock','set_low_stock_level','business_inventory','stock_history','business_orders','business_analytics','stock_apply_effects','stock_record_sale','listings_branch_check','orders_copy_branch')), null, 'no business function is open to signed-out callers');
select zm_test.expect_equal((select string_agg(p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'execute')
     and p.proname in ('stock_apply_effects','stock_record_sale','listings_branch_check','orders_copy_branch')), null, 'internal helpers are not callable from the app');
select zm_test.expect_equal((select has_function_privilege('anon', 'public.business_storefront_listings(uuid, uuid, text, integer, integer)', 'execute')::text), 'true', 'the storefront search is public');

select 'Business hub checks passed' as result;
rollback;
