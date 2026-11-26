-- Business verification (migration 0025): creating a business is not verification; only owners can apply; ownership,
-- directors, branches, permits and documents; the informal-trader route (never shown as a registered company); support
-- review with two-factor, no self-review and no review by a member of the business; officer checks and an interview for
-- every approval; two officers for higher risk; the publishing gate for business listings; suspension that keeps history;
-- owner-only changes to a verified business; the earlier registration-number flow no longer decides who can publish.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/business_verification.sql

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
  ('00000000-0000-0000-0000-0000000000a1', 'o1@example.test', '{"display_name":"Owner One"}', now()),
  ('00000000-0000-0000-0000-0000000000a2', 'o2@example.test', '{"display_name":"Owner Two"}', now()),
  ('00000000-0000-0000-0000-0000000000a3', 'o3@example.test', '{"display_name":"Owner Three"}', now()),
  ('00000000-0000-0000-0000-0000000000b1', 'mgr@example.test', '{"display_name":"Manager"}', now()),
  ('00000000-0000-0000-0000-0000000000b2', 'stf@example.test', '{"display_name":"Staffer"}', now()),
  ('00000000-0000-0000-0000-0000000000c1', 'buyer@example.test', '{"display_name":"Buyer"}', now()),
  ('00000000-0000-0000-0000-000000000051', 's1@example.test', '{"display_name":"Officer One"}', now()),
  ('00000000-0000-0000-0000-000000000052', 's2@example.test', '{"display_name":"Officer Two"}', now()),
  ('00000000-0000-0000-0000-000000000053', 's3@example.test', '{"display_name":"Officer Three"}', now()),
  ('00000000-0000-0000-0000-000000000054', 'm@example.test',  '{"display_name":"Moderator"}', now());
insert into public.admin_roles (user_id, role) values
  ('00000000-0000-0000-0000-000000000051', 'support'), ('00000000-0000-0000-0000-000000000052', 'support'),
  ('00000000-0000-0000-0000-000000000053', 'support'), ('00000000-0000-0000-0000-000000000054', 'moderator');
update public.profiles set verification_level = 'contact_verified' where id <> '00000000-0000-0000-0000-0000000000c1';
update public.profiles set seller_status = 'active';
update public.platform_settings set value = '1000' where key in ('rate_limit.verification_upload.max', 'rate_limit.listing.max');
update public.prohibited_terms set is_active = false;

insert into public.businesses (id, owner_id, name, slug, description) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1', 'Zed Phones Ltd', 'zed-phones', 'Phones'),
  ('20000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a2', 'Chanda Stall', 'chanda-stall', 'Market stall'),
  ('20000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a3', 'Hardware Hub', 'hardware-hub', 'Tools');
insert into public.business_members (business_id, user_id, role) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1', 'manager'),
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b2', 'staff'),
  ('20000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-000000000053', 'staff');

create temp table zm_ids (name text primary key, id uuid);
grant all on zm_ids to anon, authenticated, service_role;

create function zm_test.bapp(p_biz uuid) returns uuid language sql security definer as $$
  select id from public.business_applications where business_id = p_biz order by (status in ('draft','submitted','under_review','additional_information_required')) desc, created_at desc limit 1 $$;
create function zm_test.bstatus(p_biz uuid) returns text language sql security definer as $$
  select status from public.business_applications where business_id = p_biz order by (status in ('draft','submitted','under_review','additional_information_required')) desc, created_at desc limit 1 $$;
create function zm_test.bq(p_sql text) returns text language plpgsql security definer as $$
declare r text; begin execute p_sql into r; return r; end $$;
create function zm_test.doc_id(p_user uuid) returns uuid language sql security definer as $$
  select id from public.verification_documents where owner_id = p_user order by created_at limit 1 $$;
create function zm_test.bdoc(p_user uuid, p_biz uuid, p_kind text, p_scan text default 'clean') returns uuid language plpgsql security definer as $$
declare new_id uuid;
begin
  insert into public.verification_documents (owner_id, subject_type, subject_id, kind, storage_bucket, storage_path, mime_type, size_bytes, scan_status, created_at)
  values (p_user, 'business_application', zm_test.bapp(p_biz), p_kind, 'business-documents', p_user || '/business/' || p_kind || '-' || gen_random_uuid() || '.pdf', 'application/pdf', 1000, p_scan, clock_timestamp())
  returning id into new_id;
  return new_id;
end $$;
create function zm_test.bdocs(p_user uuid, p_biz uuid, p_kinds text[]) returns void language plpgsql security definer as $$
declare k text; begin foreach k in array p_kinds loop perform zm_test.bdoc(p_user, p_biz, k); end loop; end $$;
create function zm_test.review_b(p_biz uuid) returns void language plpgsql security definer as $$
declare d uuid; begin
  for d in select id from public.verification_documents where subject_id = zm_test.bapp(p_biz) and deleted_at is null and scan_status = 'clean' loop
    perform public.verification_review_document(d, true);
  end loop; end $$;
create function zm_test.notes(p_user uuid, p_type text) returns text language sql security definer as $$
  select count(*)::text from public.notifications where user_id = p_user and type = p_type $$;
create function zm_test.audits(p_action text) returns text language sql security definer as $$
  select count(*)::text from public.audit_logs where action = p_action $$;
create function zm_test.reg_form(p_size integer default 40, p_since text default '2018-03-01') returns jsonb language sql as $$
  select jsonb_build_object('route', 'registered', 'legal_name', 'Zed Phones Limited', 'trading_name', 'Zed Phones', 'business_type', 'limited_company',
    'pacra_number', '120200001234', 'pacra_registered_on', p_since, 'tpin', '1002003004', 'physical_address', 'Plot 12, Cairo Road, Lusaka',
    'selling_location_id', (select id from public.locations where area = 'Kabulonga'), 'phone', '+260971000111', 'email', 'info@zedphones.test',
    'category_ids', jsonb_build_array((select id from public.categories where slug = 'electronics')), 'expected_catalogue_size', p_size,
    'rep_name', 'Owner One', 'rep_role', 'Managing director', 'rep_is_director', true, 'rep_id_number', '111111/10/1',
    'declarations', jsonb_build_object('information_is_true', true, 'authorised_to_apply', true, 'sells_only_legal_goods', true, 'no_counterfeit_or_stolen', true, 'will_honour_returns', true)) $$;
create function zm_test.parties_ok() returns jsonb language sql as $$
  select '[{"kind":"director","full_name":"Owner One","nationality":"Zambian","id_number":"111111/10/1"},
           {"kind":"beneficial_owner","full_name":"Owner One","nationality":"Zambian","ownership_pct":60,"id_number":"111111/10/1"},
           {"kind":"beneficial_owner","full_name":"Mary Banda","nationality":"Zambian","ownership_pct":40,"id_number":"222222/10/1"}]'::jsonb $$;
create function zm_test.msg(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'no error'; exception when others then return sqlerrm; end $$;
grant execute on all functions in schema zm_test to anon, authenticated, service_role;

\set O1 '00000000-0000-0000-0000-0000000000a1'
\set O2 '00000000-0000-0000-0000-0000000000a2'
\set O3 '00000000-0000-0000-0000-0000000000a3'
\set MG '00000000-0000-0000-0000-0000000000b1'
\set ST '00000000-0000-0000-0000-0000000000b2'
\set BUY '00000000-0000-0000-0000-0000000000c1'
\set S1 '00000000-0000-0000-0000-000000000051'
\set S2 '00000000-0000-0000-0000-000000000052'
\set S3 '00000000-0000-0000-0000-000000000053'
\set MOD '00000000-0000-0000-0000-000000000054'
\set B1 '20000000-0000-0000-0000-0000000000a1'
\set B2 '20000000-0000-0000-0000-0000000000a2'
\set B3 '20000000-0000-0000-0000-0000000000a3'

-- 1. Creating a business is not verification ------------------------------------------------------------------------
select zm_test.expect_equal((select count(*)::text from information_schema.role_table_grants where table_schema = 'public'
   and table_name like 'business_application%' and grantee in ('anon','authenticated')), '0', 'no table grants for app users');
select zm_test.act_as_guest();
select zm_test.expect_equal((select verified::text from public.public_businesses where id = :'B1'), 'false', 'a new business is not verified');
select zm_test.expect_equal((select registration_kind from public.public_businesses where id = :'B1'), null, 'no registration kind before approval');
select zm_test.act_as(:'O1');
select zm_test.expect_equal(public.business_can_publish(:'B1')::text, 'false', 'owner of a new business cannot publish');
insert into public.listings (business_id, category_id, location_id, title, description, price_zmw, condition)
  select :'B1', c.id, l.id, 'Draft phone', 'x', 100, 'new' from public.categories c, public.locations l where c.slug = 'electronics' and l.area = 'Kabulonga';
insert into public.listing_images (listing_id, storage_path, position) select id, auth.uid() || '/phone.jpg', 0 from public.listings where title = 'Draft phone';
select zm_test.expect_equal((select status::text from public.listings where title = 'Draft phone'), 'draft', 'drafts can be prepared before verification');
select zm_test.expect_error($q$update public.listings set status = 'active' where title = 'Draft phone'$q$, 'an unverified business cannot publish');
select zm_test.act_as(:'MG');
select zm_test.expect_error($q$update public.listings set status = 'active' where title = 'Draft phone'$q$, 'a manager cannot publish for an unverified business either');

-- 2. Only owners can apply ------------------------------------------------------------------------------------------
select zm_test.expect_error(format($q$select public.business_application_save(%L, '{"legal_name":"Zed Phones Limited"}')$q$, :'B1'), 'a manager cannot start an application');
select zm_test.act_as(:'ST');
select zm_test.expect_error(format($q$select public.business_application_save(%L, '{"legal_name":"Zed Phones Limited"}')$q$, :'B1'), 'staff cannot start an application');
select zm_test.act_as(:'BUY');
select zm_test.expect_error(format($q$select public.business_application_save(%L, '{"legal_name":"Zed Phones Limited"}')$q$, :'B1'), 'an outsider cannot start an application');
select zm_test.act_as(:'O2');
select zm_test.expect_error(format($q$select public.business_application_save(%L, '{"legal_name":"Zed Phones Limited"}')$q$, :'B1'), 'another business owner cannot apply for this business');
select zm_test.act_as(:'O1');
-- LESSON FROM THE SELLER FLOW: the answer always has every part, even before any application exists.
select zm_test.expect_equal((select string_agg(k, ',' order by k) from jsonb_object_keys(public.business_application_mine(:'B1')) k),
  'application,branches,documents,history,parties,permits,publish_state,registration_kind,requests', 'mine() always returns every part');
select zm_test.expect_equal(jsonb_typeof(public.business_application_mine(:'B1') -> 'documents'), 'array', 'documents is a list, not missing');
select zm_test.expect_equal(jsonb_typeof(public.business_application_mine(:'B1') -> 'history'), 'array', 'history is a list, not missing');
select zm_test.expect_error(format($q$select public.business_application_save(%L, '{"route":"somewhere"}')$q$, :'B1'), 'unknown route');
-- Readable answers that name the problem, never a raw table rule or cast failure
select zm_test.expect_equal(zm_test.msg(format($q$select public.business_application_save(%L, '{"phone":"abc"}')$q$, :'B1')), 'The phone number must be 9 to 16 digits, for example +260971000111.', 'bad phone is named');
select zm_test.expect_equal(zm_test.msg(format($q$select public.business_application_save(%L, '{"email":"nope"}')$q$, :'B1')), 'The email address is not a valid email address.', 'bad email is named');
select zm_test.expect_equal(zm_test.msg(format($q$select public.business_application_save(%L, '{"legal_name":"AB"}')$q$, :'B1')), 'The legal name must be 3 to 150 characters.', 'short name is named');
select zm_test.expect_equal(zm_test.msg(format($q$select public.business_application_save(%L, '{"pacra_registered_on":"2020-13-45"}')$q$, :'B1')), 'The registration date is not a real date.', 'impossible date is named');
select zm_test.expect_equal(zm_test.msg(format($q$select public.business_application_save(%L, '{"pacra_registered_on":"yesterday"}')$q$, :'B1')), 'The registration date must be a date written as YYYY-MM-DD.', 'wrong date shape is named');
select zm_test.expect_equal(zm_test.msg(format($q$select public.business_application_save(%L, '{"expected_catalogue_size":"lots"}')$q$, :'B1')), 'The number of products must be a whole number from 1 to 100000.', 'non-number is named');
select zm_test.expect_equal(zm_test.msg(format($q$select public.business_application_save(%L, '{"expected_catalogue_size":0}')$q$, :'B1')), 'The number of products must be a whole number from 1 to 100000.', 'zero is named');
select zm_test.expect_equal(zm_test.msg(format($q$select public.business_application_save(%L, '{"rep_is_director":"maybe"}')$q$, :'B1')), 'Say yes or no: is the representative a director?', 'bad yes/no is named');
select zm_test.expect_equal(zm_test.msg(format($q$select public.business_application_save(%L, '{"category_ids":["x"]}')$q$, :'B1')), 'Choose categories from the list.', 'bad category value is named');
select zm_test.expect_equal(zm_test.msg(format($q$select public.business_application_save(%L, '[1,2]')$q$, :'B1')), 'Send the answers as a list of fields.', 'wrong shape is named');
select zm_test.expect_equal(zm_test.msg(format($q$select public.business_application_save(%L, '{"business_type":"spaceship"}')$q$, :'B1')), 'Choose the type of business from the list.', 'unknown type is named');
select zm_test.expect_equal(zm_test.bstatus(:'B1'), null, 'refused answers never created a draft');
select zm_test.expect_error(format($q$select public.business_application_save(%L, '{"category_ids":[999999]}')$q$, :'B1'), 'unknown category');
select public.business_application_save(:'B1', zm_test.reg_form());
select zm_test.expect_equal(zm_test.bstatus(:'B1'), 'draft', 'draft created');
select zm_test.expect_error(format($q$select public.business_application_save(%L, '{"business_type":"informal_trader"}')$q$, :'B1'), 'a registered route cannot be an informal trader type');
select zm_test.act_as(:'MG');
select zm_test.expect_error(format($q$select public.business_application_set_parties(%L, '[]')$q$, zm_test.bapp(:'B1')), 'a manager cannot edit ownership');
select zm_test.expect_error(format($q$select public.business_application_mine(%L)$q$, :'B1'), 'a manager cannot read the application');
select zm_test.act_as(:'O1');

-- 3. Ownership, documents, submit -------------------------------------------------------------------------------
select zm_test.expect_error(format($q$select public.business_application_submit(%L)$q$, zm_test.bapp(:'B1')), 'cannot send without agreement, directors and documents');
select public.seller_agreement_accept(1);
select public.business_application_set_parties(zm_test.bapp(:'B1'), '[{"kind":"director","full_name":"Owner One","nationality":"Zambian"},{"kind":"beneficial_owner","full_name":"Owner One","nationality":"Zambian","ownership_pct":60}]');
select zm_test.act_as_admin();
select zm_test.bdocs(:'O1', :'B1', array['pacra_certificate', 'tpin_certificate', 'premises_evidence', 'director_id']);
select zm_test.act_as(:'O1');
select zm_test.expect_error(format($q$select public.business_application_submit(%L)$q$, zm_test.bapp(:'B1')), 'owners that do not add up to 100 per cent are refused');
select zm_test.expect_equal(zm_test.msg(format($q$select public.business_application_set_parties(%L, '[{"kind":"beneficial_owner","full_name":"X Y Z"}]')$q$, zm_test.bapp(:'B1'))), 'Give the ownership percentage of every beneficial owner.', 'a beneficial owner needs a percentage');
select zm_test.expect_equal(zm_test.msg(format($q$select public.business_application_set_parties(%L, '[{"kind":"director"}]')$q$, zm_test.bapp(:'B1'))), 'Each person''s full name must be 3 to 120 characters.', 'a nameless person is named');
select zm_test.expect_equal(zm_test.msg(format($q$select public.business_application_set_parties(%L, '[{"kind":"owner","full_name":"Abc Def"}]')$q$, zm_test.bapp(:'B1'))), 'Say whether each person is a director or a beneficial owner.', 'a wrong kind is named');
select zm_test.expect_equal(zm_test.msg(format($q$select public.business_application_set_parties(%L, '[{"kind":"beneficial_owner","full_name":"Abc Def","ownership_pct":"lots"}]')$q$, zm_test.bapp(:'B1'))), 'An ownership percentage must be a number from 0 to 100.', 'a non-number percentage is named');
select zm_test.expect_equal(zm_test.msg(format($q$select public.business_application_set_branches(%L, '[{"address":"Somewhere far away"}]')$q$, zm_test.bapp(:'B1'))), 'Each branch needs a name of 2 to 100 characters.', 'a nameless branch is named');
select zm_test.expect_equal(zm_test.msg(format($q$select public.business_application_set_permits(%L, '[{"permit_type":"Licence","expires_on":"soon"}]')$q$, zm_test.bapp(:'B1'))), 'A permit expiry date must be a date written as YYYY-MM-DD.', 'a bad permit date is named');
select public.business_application_set_parties(zm_test.bapp(:'B1'), zm_test.parties_ok());
select public.business_application_set_branches(zm_test.bapp(:'B1'), '[{"name":"Manda Hill","address":"Manda Hill Mall, Lusaka","phone":"+260971000222"}]');
select public.business_application_set_permits(zm_test.bapp(:'B1'), '[{"permit_type":"Trading licence","permit_number":"TL-1","issuer":"Lusaka City Council","expires_on":"2027-12-31"}]');
select zm_test.expect_error(format($q$select public.business_application_set_permits(%L, '"nope"')$q$, zm_test.bapp(:'B1')), 'permits must be a list');
-- registering a business document needs the real file and an owner
select zm_test.act_as_admin();
insert into storage.objects (bucket_id, name, metadata) values ('business-documents', :'O1' || '/business/extra.pdf', '{"mimetype":"application/pdf","size":2000}');
select zm_test.act_as(:'MG');
select zm_test.expect_error(format($q$select public.verification_register_document('business_application', %L, 'permit', 'business-documents', %L)$q$, zm_test.bapp(:'B1'), :'O1' || '/business/extra.pdf'), 'a manager cannot upload ownership documents');
select zm_test.act_as(:'O1');
select public.verification_register_document('business_application', zm_test.bapp(:'B1'), 'permit', 'business-documents', :'O1' || '/business/extra.pdf');
select public.business_application_submit(zm_test.bapp(:'B1'));
select zm_test.expect_equal(zm_test.bstatus(:'B1'), 'submitted', 'submitted');
select zm_test.expect_equal(zm_test.bq($z$select risk_level from public.business_applications where business_id = '20000000-0000-0000-0000-0000000000a1'$z$), 'standard', 'an established registered business is standard risk');
select zm_test.expect_error(format($q$select public.business_application_set_parties(%L, '[]')$q$, zm_test.bapp(:'B1')), 'cannot edit ownership while it is being reviewed');
select zm_test.expect_equal((public.business_application_mine(:'B1') -> 'application' ->> 'tpin'), '1002003004', 'the owner can read their own answers');
select zm_test.expect_equal(zm_test.notes(:'O1', 'business_application'), '1', 'owner told it arrived');
select zm_test.expect_equal(public.business_can_publish(:'B1')::text, 'false', 'submitted is not verified');
select zm_test.expect_error($q$update public.listings set status = 'active' where title = 'Draft phone'$q$, 'still cannot publish while waiting');

-- 4. Support review: no self-review, no conflict, two-factor -------------------------------------------------------
select zm_test.act_as(:'BUY');
select zm_test.expect_error('select * from public.business_verification_queue(''sellers'')', 'buyers cannot see the queue');
select zm_test.act_as(:'MOD', 'aal2');
select zm_test.expect_error('select * from public.business_verification_queue(''sellers'')', 'moderators cannot see the queue');
select zm_test.act_as(:'S1', 'aal1');
select zm_test.expect_error('select * from public.business_verification_queue(''sellers'')', 'no two-factor, no queue');
select zm_test.act_as(:'S1', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.business_verification_queue('sellers')), '1', 'one waiting');
select zm_test.expect_equal((public.business_application_detail(zm_test.bapp(:'B1')) ? 'tpin')::text, 'false', 'detail never carries the TPIN');
select zm_test.expect_equal((public.business_application_detail(zm_test.bapp(:'B1')) -> 'parties' -> 0 ? 'id_number')::text, 'false', 'detail never carries director ID numbers');
select zm_test.expect_equal((public.business_application_private_details(zm_test.bapp(:'B1')) ->> 'tpin'), '1002003004', 'private details can be read on purpose');
select zm_test.expect_equal(zm_test.audits('verification.private_viewed'), '1', 'and it is audited');
select zm_test.act_as(:'S3', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.business_verification_queue('sellers')), '1', 'a member of another business can review this one');
-- S3 is staff in B3: it cannot review B3's application (conflict of interest) — set up below
select zm_test.act_as(:'S1', 'aal2');
select zm_test.expect_error(format($q$select public.business_application_decide(%L, 'approve', 'looks fine')$q$, zm_test.bapp(:'B1')), 'must claim first');
select public.business_application_claim(zm_test.bapp(:'B1'));
select zm_test.expect_equal(zm_test.bstatus(:'B1'), 'under_review', 'claimed');
select zm_test.act_as(:'S2', 'aal2');
select zm_test.expect_error(format($q$select public.business_application_claim(%L)$q$, zm_test.bapp(:'B1')), 'someone else already has it');
select zm_test.act_as(:'S1', 'aal2');
select zm_test.expect_error(format($q$select public.business_application_decide(%L, 'approve', 'documents look fine')$q$, zm_test.bapp(:'B1')), 'documents not accepted yet');
select zm_test.review_b(:'B1');
select zm_test.expect_error(format($q$select public.business_application_decide(%L, 'approve', 'documents look fine')$q$, zm_test.bapp(:'B1')), 'officer checks are required');
select zm_test.expect_error(format($q$select public.business_application_record_check(%L, 'registry_lookup', 'passed', 'x')$q$, zm_test.bapp(:'B1')), 'a check needs a real note');
select zm_test.expect_error(format($q$select public.business_application_record_check(%L, 'registry_lookup', 'fine', 'Found in registry')$q$, zm_test.bapp(:'B1')), 'unknown result');
select public.business_application_record_check(zm_test.bapp(:'B1'), 'registry_lookup', 'failed', 'Name did not match first time, retry');
select zm_test.expect_error(format($q$select public.business_application_decide(%L, 'approve', 'documents look fine')$q$, zm_test.bapp(:'B1')), 'a failed check does not count');
select public.business_application_record_check(zm_test.bapp(:'B1'), 'registry_lookup', 'passed', 'Company found in the registry, directors match');
select public.business_application_record_check(zm_test.bapp(:'B1'), 'authority_confirmed', 'passed', 'Called the number on the registry, owner confirmed the applicant acts for the company');
select zm_test.expect_error(format($q$select public.business_application_decide(%L, 'approve', 'documents look fine')$q$, zm_test.bapp(:'B1')), 'an interview is required for every business');
select public.business_application_record_interview(zm_test.bapp(:'B1'), 'video', 'passed', '[{"q":"What do you sell?","a":"Phones and chargers"}]', 'Shop visible on camera');
select zm_test.expect_equal(public.business_application_decide(zm_test.bapp(:'B1'), 'approve', 'Registry, authority and interview all confirmed'), 'approved', 'standard business approved by one officer');
select zm_test.expect_equal((select publish_state from public.businesses where id = :'B1'), 'active', 'publishing is on');
select zm_test.expect_equal((select verification_status::text from public.businesses where id = :'B1'), 'verified', 'verified badge');
select zm_test.expect_equal((select registration_kind from public.businesses where id = :'B1'), 'registered', 'registered company');
select zm_test.expect_equal(zm_test.notes(:'O1', 'business_application'), '3', 'owner told (received, review started, approved)');
select zm_test.expect_equal((select count(*)::text from public.notifications where type = 'business_application' and (body ilike '%1002003004%' or body ilike '%Cairo%')), '0', 'no sensitive details in notices');
select zm_test.expect_equal(zm_test.bq($z$select count(*) from public.verification_documents where subject_type = 'business_application' and purge_after is not null$z$), '5', 'retention date set');

-- 5. After approval the business keeps everything it had -----------------------------------------------------------
select zm_test.act_as_guest();
select zm_test.expect_equal((select verified::text from public.public_businesses where id = :'B1'), 'true', 'storefront shows verified');
select zm_test.expect_equal((select registration_kind from public.public_businesses where id = :'B1'), 'registered', 'and says registered company');
select zm_test.act_as(:'MG');
update public.listings set status = 'active' where title = 'Draft phone';
select zm_test.expect_equal((select status::text from public.listings where title = 'Draft phone'), 'active', 'the manager can now publish');
select zm_test.expect_equal((select moderation_status::text from public.listings where title = 'Draft phone'), 'approved', 'through the normal listing rules');
select zm_test.expect_error($q$update public.businesses set name = 'Renamed Phones' where id = '20000000-0000-0000-0000-0000000000a1'$q$, 'a manager cannot rename a verified business');
select zm_test.expect_error($q$update public.businesses set address_text = 'Elsewhere' where id = '20000000-0000-0000-0000-0000000000a1'$q$, 'or change its address');
select zm_test.act_as(:'O1');
update public.businesses set name = 'Zed Phones Zambia' where id = :'B1';
select zm_test.expect_equal((select name from public.businesses where id = :'B1'), 'Zed Phones Zambia', 'the owner can');
select zm_test.expect_error(format($q$select public.business_application_save(%L, '{}')$q$, :'B1'), 'a verified business does not apply again');
select zm_test.expect_equal(zm_test.audits('business.sensitive_change'), '1', 'owner changes to verified details are audited');
select zm_test.expect_error($q$update public.businesses set publish_state = 'active' where id = '20000000-0000-0000-0000-0000000000a3'$q$, 'nobody can switch publishing on themselves');
select zm_test.expect_error($q$update public.businesses set registration_kind = 'registered' where id = '20000000-0000-0000-0000-0000000000a3'$q$, 'or choose their registration kind');

-- 6. Informal trader route -----------------------------------------------------------------------------------------
select zm_test.act_as(:'O2');
select public.seller_agreement_accept(1);
select public.business_application_save(:'B2', jsonb_build_object('route', 'informal_trader', 'business_type', 'informal_trader', 'legal_name', 'Chanda Mulenga',
  'physical_address', 'Soweto Market, Stall 14, Lusaka', 'selling_location_id', (select id from public.locations where area = 'Kabulonga'),
  'phone', '+260971000333', 'email', 'chanda@example.test', 'category_ids', jsonb_build_array((select id from public.categories where slug = 'electronics')),
  'expected_catalogue_size', 30, 'trading_place', 'Soweto Market, stall 14, row C', 'years_trading', 4,
  'rep_name', 'Chanda Mulenga', 'rep_role', 'Trader', 'rep_is_director', true, 'rep_id_number', '333333/10/1',
  'declarations', jsonb_build_object('information_is_true', true, 'authorised_to_apply', true, 'sells_only_legal_goods', true, 'no_counterfeit_or_stolen', true, 'will_honour_returns', true)));
select zm_test.act_as_admin();
select zm_test.bdocs(:'O2', :'B2', array['director_id', 'premises_evidence', 'ownership_evidence']);
select zm_test.act_as(:'O2');
select public.business_application_submit(zm_test.bapp(:'B2'));
select zm_test.expect_equal(zm_test.bq($z$select route from public.business_applications where business_id = '20000000-0000-0000-0000-0000000000a2'$z$), 'informal_trader', 'informal route recorded');
select zm_test.act_as(:'S2', 'aal2');
select public.business_application_claim(zm_test.bapp(:'B2'));
select zm_test.review_b(:'B2');
select public.business_application_record_check(zm_test.bapp(:'B2'), 'authority_confirmed', 'passed', 'Met by video, the trader confirmed their identity');
select public.business_application_record_interview(zm_test.bapp(:'B2'), 'phone', 'passed', '[{"q":"Where do you trade?","a":"Soweto market"}]');
select zm_test.expect_error(format($q$select public.business_application_decide(%L, 'approve', 'Trader confirmed')$q$, zm_test.bapp(:'B2')), 'an informal trader needs the trading place checked');
select public.business_application_record_check(zm_test.bapp(:'B2'), 'address_check', 'passed', 'Trading place confirmed with the market association');
select zm_test.expect_equal(public.business_application_decide(zm_test.bapp(:'B2'), 'approve', 'Trader and trading place confirmed'), 'approved', 'informal trader approved');
select zm_test.act_as_guest();
select zm_test.expect_equal((select registration_kind from public.public_businesses where id = :'B2'), 'informal_trader', 'an informal trader is never shown as a registered company');
select zm_test.expect_equal((select verified::text from public.public_businesses where id = :'B2'), 'true', 'but can be verified to trade');

-- 7. Higher risk: new registration needs two officers --------------------------------------------------------------
select zm_test.act_as(:'O3');
select public.seller_agreement_accept(1);
select public.business_application_save(:'B3', zm_test.reg_form(800, (current_date - 30)::text));
select public.business_application_set_parties(zm_test.bapp(:'B3'), zm_test.parties_ok());
select zm_test.act_as_admin();
select zm_test.bdocs(:'O3', :'B3', array['pacra_certificate', 'tpin_certificate', 'premises_evidence', 'director_id']);
select zm_test.act_as(:'O3');
select public.business_application_submit(zm_test.bapp(:'B3'));
select zm_test.expect_equal(zm_test.bq($z$select risk_level from public.business_applications where business_id = '20000000-0000-0000-0000-0000000000a3'$z$), 'high', 'a new registration with a large catalogue is higher risk');
select zm_test.act_as(:'S3', 'aal2');
select zm_test.expect_error(format($q$select public.business_application_claim(%L)$q$, zm_test.bapp(:'B3')), 'a member of the business cannot review it');
select zm_test.expect_error(format($q$select public.business_application_detail(%L)$q$, zm_test.bapp(:'B3')), 'or open it');
select zm_test.expect_error(format($q$select public.business_application_private_details(%L)$q$, zm_test.bapp(:'B3')), 'or read its private details');
select zm_test.expect_error(format($q$select * from public.verification_open_document(%L)$q$, zm_test.doc_id(:'O3')), 'or open its documents');
select zm_test.act_as(:'S1', 'aal2');
select public.business_application_claim(zm_test.bapp(:'B3'));
select zm_test.review_b(:'B3');
select public.business_application_record_check(zm_test.bapp(:'B3'), 'registry_lookup', 'passed', 'Company found, incorporated recently');
select public.business_application_record_check(zm_test.bapp(:'B3'), 'authority_confirmed', 'passed', 'Director confirmed by phone');
select public.business_application_record_interview(zm_test.bapp(:'B3'), 'video', 'passed', '[{"q":"Where does your stock come from?","a":"Direct importer"}]');
select zm_test.expect_equal(public.business_application_decide(zm_test.bapp(:'B3'), 'approve', 'Checks and interview passed'), 'awaiting_second_approval', 'first officer cannot finish a higher-risk approval alone');
select zm_test.expect_equal(zm_test.bq($z$select publish_state from public.businesses where id = '20000000-0000-0000-0000-0000000000a3'$z$), 'none', 'still not publishing');
select zm_test.expect_error(format($q$select public.business_application_claim(%L)$q$, zm_test.bapp(:'B3')), 'the first approver cannot claim it again');
select zm_test.act_as(:'S2', 'aal2');
select public.business_application_claim(zm_test.bapp(:'B3'));
select zm_test.expect_equal(public.business_application_decide(zm_test.bapp(:'B3'), 'approve', 'Second review agrees'), 'approved', 'second officer completes it');
select zm_test.expect_equal(zm_test.bq($z$select publish_state from public.businesses where id = '20000000-0000-0000-0000-0000000000a3'$z$), 'active', 'now publishing');

-- 8. Information requests and rejection ---------------------------------------------------------------------------------
select zm_test.act_as_admin();
insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values ('00000000-0000-0000-0000-0000000000a4', 'o4@example.test', '{"display_name":"Owner Four"}', now());
update public.profiles set verification_level = 'contact_verified', seller_status = 'active' where id = '00000000-0000-0000-0000-0000000000a4';
insert into public.businesses (id, owner_id, name, slug, description) values ('20000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a4', 'Shady Traders', 'shady-traders', 'x');
\set O4 '00000000-0000-0000-0000-0000000000a4'
\set B4 '20000000-0000-0000-0000-0000000000a4'
select zm_test.act_as(:'O4');
select public.seller_agreement_accept(1);
select public.business_application_save(:'B4', zm_test.reg_form(10) || '{"rep_is_director": false}');
select public.business_application_set_parties(zm_test.bapp(:'B4'), zm_test.parties_ok());
select zm_test.act_as_admin();
select zm_test.bdocs(:'O4', :'B4', array['pacra_certificate', 'tpin_certificate', 'premises_evidence', 'director_id']);
select zm_test.act_as(:'O4');
select zm_test.expect_error(format($q$select public.business_application_submit(%L)$q$, zm_test.bapp(:'B4')), 'a representative who is not a director must send an authority letter');
select zm_test.act_as_admin();
select zm_test.bdoc(:'O4', :'B4', 'authority_letter');
-- (inside one test transaction every timestamp is close together, so make this first letter clearly older)
select zm_test.bq($z$update public.verification_documents set created_at = now() - interval '1 hour' where kind = 'authority_letter' returning 'x'$z$);
select zm_test.act_as(:'O4');
select public.business_application_submit(zm_test.bapp(:'B4'));
select zm_test.act_as(:'S1', 'aal2');
select public.business_application_claim(zm_test.bapp(:'B4'));
select zm_test.expect_error(format($q$select public.business_application_request_info(%L, 'Send proof', array['bogus'])$q$, zm_test.bapp(:'B4')), 'unknown document kind');
insert into zm_ids select 'req', public.business_application_request_info(zm_test.bapp(:'B4'), 'Please send the signed letter from the director confirming your authority', array['authority_letter']);
select zm_test.expect_equal(zm_test.bstatus(:'B4'), 'additional_information_required', 'waiting for the owner');
select zm_test.act_as(:'MG');
select zm_test.expect_error(format($q$select public.business_application_respond(%L, 'hi')$q$, (select id from zm_ids where name = 'req')), 'only an owner can answer');
select zm_test.act_as(:'O4');
select zm_test.expect_error(format($q$select public.business_application_respond(%L, 'here')$q$, (select id from zm_ids where name = 'req')), 'cannot answer without the new document');
select zm_test.act_as_admin();
select zm_test.bdoc(:'O4', :'B4', 'authority_letter');
select zm_test.act_as(:'O4');
select public.business_application_respond((select id from zm_ids where name = 'req'), 'Signed letter attached');
select zm_test.expect_equal(zm_test.bstatus(:'B4'), 'under_review', 'back with the officer');
select zm_test.act_as(:'S1', 'aal2');
select zm_test.expect_error(format($q$select public.business_application_decide(%L, 'reject', 'no')$q$, zm_test.bapp(:'B4')), 'a rejection needs a reason');
select public.business_application_decide(zm_test.bapp(:'B4'), 'reject', 'The registry number does not match the company name');
select zm_test.expect_equal(zm_test.bstatus(:'B4'), 'rejected', 'rejected');
select zm_test.expect_equal(zm_test.bq($z$select publish_state from public.businesses where id = '20000000-0000-0000-0000-0000000000a4'$z$), 'none', 'rejected means no publishing');
select zm_test.act_as(:'O4');
select zm_test.expect_error(format($q$select public.business_application_save(%L, '{}')$q$, :'B4'), 'cannot reapply straight away');
select zm_test.expect_equal((public.business_application_mine(:'B4') -> 'application' ->> 'decision_reason'), 'The registry number does not match the company name', 'the owner reads the reason');

-- 9. The earlier registration-number check no longer decides who may publish ---------------------------------------------
select zm_test.act_as_admin();
insert into public.business_verifications (business_id, registration_number) values (:'B4', '120200009999');
update public.business_verifications set status = 'approved' where business_id = :'B4';
update public.businesses set verification_status = 'verified' where id = :'B4';
select zm_test.expect_equal(public.business_can_publish(:'B4')::text, 'false', 'the old flow cannot switch publishing on');
select zm_test.act_as_guest();
select zm_test.expect_equal((select verified::text from public.public_businesses where id = :'B4'), 'false', 'and shows no verified badge');

-- 10. Suspension keeps history; a different officer reinstates --------------------------------------------------------
select zm_test.act_as(:'MOD', 'aal2');
select zm_test.expect_error(format($q$select public.business_application_suspend(%L, 'Selling counterfeit goods, see report')$q$, zm_test.bapp(:'B1')), 'moderators cannot suspend a business');
select zm_test.act_as(:'S2', 'aal2');
select zm_test.expect_error(format($q$select public.business_application_suspend(%L, 'short')$q$, zm_test.bapp(:'B1')), 'a reason is needed');
select public.business_application_suspend(zm_test.bapp(:'B1'), 'Selling counterfeit goods, see report 77');
select zm_test.expect_equal((select publish_state from public.businesses where id = :'B1'), 'suspended', 'publishing off');
select zm_test.expect_equal((select verification_status::text from public.businesses where id = :'B1'), 'unverified', 'badge removed');
select zm_test.expect_equal((select status::text from public.listings where title = 'Draft phone'), 'unavailable', 'live listings paused, not deleted');
select zm_test.act_as(:'MG');
select zm_test.expect_error($q$update public.listings set status = 'active' where title = 'Draft phone'$q$, 'cannot republish while suspended');
select zm_test.expect_equal((select count(*)::text from public.listings where title = 'Draft phone'), '1', 'history kept');
select zm_test.act_as(:'S2', 'aal2');
select zm_test.expect_error(format($q$select public.business_application_reinstate(%L, 'Resolved after the investigation')$q$, zm_test.bapp(:'B1')), 'the same officer cannot reinstate');
select zm_test.act_as(:'S1', 'aal2');
select public.business_application_reinstate(zm_test.bapp(:'B1'), 'Resolved after the investigation');
select zm_test.expect_equal((select publish_state from public.businesses where id = :'B1'), 'active', 'reinstated');
select zm_test.expect_equal((select verification_status::text from public.businesses where id = :'B1'), 'verified', 'badge back');
select zm_test.act_as(:'S2', 'aal2');
select public.business_application_suspend(zm_test.bapp(:'B1'), 'Repeated serious breaches of the agreement', true);
select zm_test.expect_equal((select publish_state from public.businesses where id = :'B1'), 'revoked', 'revoked');
select zm_test.expect_equal(zm_test.bstatus(:'B1'), 'revoked', 'application shows revoked');

-- 11. Documents: audited, support and two-factor only; history is permanent -------------------------------------------
select zm_test.act_as(:'S1', 'aal2');
select zm_test.expect_equal((select bucket from public.verification_open_document(zm_test.doc_id(:'O2'))), 'business-documents', 'support gets the location');
select zm_test.expect_equal(zm_test.audits('document.viewed'), '1', 'the open is audited');
select zm_test.act_as(:'S1', 'aal1');
select zm_test.expect_error(format($q$select * from public.verification_open_document(%L)$q$, zm_test.doc_id(:'O2')), 'no two-factor, no document');
select zm_test.act_as(:'O2');
select zm_test.expect_error(format($q$select * from public.verification_open_document(%L)$q$, zm_test.doc_id(:'O2')), 'an owner cannot use the staff function');
select zm_test.act_as_admin();
insert into zm_ids select 'dirty', zm_test.bdoc(:'O2', :'B2', 'other', 'pending');
select zm_test.act_as(:'S1', 'aal2');
select zm_test.expect_error(format($q$select * from public.verification_open_document(%L)$q$, (select id from zm_ids where name = 'dirty')), 'an unscanned file cannot be opened');
select zm_test.act_as_admin();
select zm_test.expect_error('update public.verification_events set note = ''x''', 'history cannot be edited');
select zm_test.expect_error('delete from public.verification_events', 'history cannot be deleted');
select zm_test.act_as(:'S1', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.business_verification_queue('approved')), '2', 'approved queue');
select zm_test.expect_equal((select count(*)::text from public.business_verification_queue('rejected')), '1', 'rejected queue');
select zm_test.expect_equal((select count(*)::text from public.business_verification_queue('suspended')), '1', 'revoked businesses sit in the suspended queue');

-- 12. Withdrawing does not start the waiting period; deleting a business schedules its documents ---------------------------
select zm_test.act_as_admin();
insert into public.businesses (id, owner_id, name, slug, description) values
  ('20000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a1', 'Second Shop', 'second-shop', 'x'),
  ('20000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a1', 'Closing Shop', 'closing-shop', 'x');
\set B5 '20000000-0000-0000-0000-0000000000a5'
\set B6 '20000000-0000-0000-0000-0000000000a6'
select zm_test.act_as(:'O1');
select public.business_application_save(:'B5', '{"legal_name":"Second Shop Limited"}');
select public.business_application_withdraw(zm_test.bapp(:'B5'));
select zm_test.expect_equal(zm_test.bstatus(:'B5'), 'rejected', 'withdrawn is stored as ended');
select public.business_application_save(:'B5', '{"legal_name":"Second Shop Limited again"}');
select zm_test.expect_equal(zm_test.bstatus(:'B5'), 'draft', 'a withdrawn application does not start the waiting period');
select zm_test.expect_equal((select count(*)::text from jsonb_array_elements(public.business_application_mine(:'B5') -> 'history')), '1', 'the new draft has its own history');
-- a real rejection still does (checked for B4 above); deleting a business:
select public.business_application_save(:'B6', '{"legal_name":"Closing Shop Limited"}');
select zm_test.act_as_admin();
insert into zm_ids select 'closedoc', zm_test.bdoc(:'O1', :'B6', 'pacra_certificate');
select zm_test.expect_equal(zm_test.bq($z$select purge_after is null from public.verification_documents where kind = 'pacra_certificate' and subject_id = (select id from public.business_applications where business_id = '20000000-0000-0000-0000-0000000000a6')$z$), 'true', 'the document has no delete date yet');
select zm_test.act_as(:'MG');
select zm_test.expect_error(format($q$select public.business_close(%L)$q$, :'B6'), 'only an owner can delete a business');
select zm_test.act_as(:'O1');
select public.business_close(:'B6', 'Closing down');
select zm_test.expect_equal((select count(*)::text from public.businesses where id = :'B6'), '0', 'business deleted');
select zm_test.expect_equal(zm_test.bq($z$select (purge_after is not null)::text from public.verification_documents where id = (select id from zm_ids where name = 'closedoc')$z$), 'true', 'its application documents are now scheduled for deletion');
select zm_test.expect_equal(zm_test.bq($z$select count(*) from public.verification_events where event = 'business_deleted'$z$), '1', 'the history of the deletion is kept');

rollback;
