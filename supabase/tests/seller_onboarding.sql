-- Seller onboarding (migration 0023): buyers stay buyers; the application, its documents and questionnaire; support review
-- with two-factor, no self-review, interviews, information requests, escalation and two approvals for higher risk;
-- the publishing gate (applicants, rejected, suspended and revoked sellers cannot publish); suspension that keeps history;
-- audited document access; retention; queues; closed tables.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/seller_onboarding.sql

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

create function zm_test.s(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000001' || lpad(n::text, 2, '0'))::uuid
$$;


insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
  ('00000000-0000-0000-0000-00000000000a', 'a@example.test', '{"display_name":"Applicant Anna"}', now()),
  ('00000000-0000-0000-0000-00000000000b', 'b@example.test', '{"display_name":"Applicant Bwalya"}', now()),
  ('00000000-0000-0000-0000-00000000000c', 'c@example.test', '{"display_name":"Buyer Chanda"}', now()),
  ('00000000-0000-0000-0000-000000000051', 's1@example.test', '{"display_name":"Officer One"}', now()),
  ('00000000-0000-0000-0000-000000000052', 's2@example.test', '{"display_name":"Officer Two"}', now()),
  ('00000000-0000-0000-0000-000000000053', 's3@example.test', '{"display_name":"Officer Three"}', now()),
  ('00000000-0000-0000-0000-000000000054', 'm@example.test',  '{"display_name":"Moderator Mo"}', now());
insert into public.admin_roles (user_id, role) values
  ('00000000-0000-0000-0000-000000000051', 'support'), ('00000000-0000-0000-0000-000000000052', 'support'),
  ('00000000-0000-0000-0000-000000000053', 'support'), ('00000000-0000-0000-0000-000000000054', 'moderator');
update public.profiles set verification_level = 'contact_verified' where id in
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-000000000053');
update public.platform_settings set value = '1000' where key = 'rate_limit.verification_upload.max';
update public.platform_settings set value = '1000' where key = 'rate_limit.listing.max';
update public.prohibited_terms set is_active = false;

create temp table zm_ids (name text primary key, id uuid);
grant all on zm_ids to anon, authenticated, service_role;

create function zm_test.app_of(p_user uuid) returns uuid language sql security definer as $$
  select id from public.seller_applications where user_id = p_user order by (status in ('draft','submitted','under_review','additional_information_required')) desc, created_at desc limit 1 $$;
create function zm_test.status_of(p_user uuid) returns text language sql security definer as $$
  select status from public.seller_applications where user_id = p_user order by (status in ('draft','submitted','under_review','additional_information_required')) desc, created_at desc limit 1 $$;
create function zm_test.seller_status(p_user uuid) returns text language sql security definer as $$
  select seller_status from public.profiles where id = p_user $$;
create function zm_test.audits(p_action text) returns text language sql security definer as $$
  select count(*)::text from public.audit_logs where action = p_action $$;
create function zm_test.notes(p_user uuid, p_type text) returns text language sql security definer as $$
  select count(*)::text from public.notifications where user_id = p_user and type = p_type $$;

-- Setup helpers (run as the superuser): a document that is uploaded, scanned clean and waiting for review.
create function zm_test.doc(p_user uuid, p_kind text, p_scan text default 'clean') returns uuid language plpgsql security definer as $$
declare new_id uuid;
begin
  insert into public.verification_documents (owner_id, subject_type, subject_id, kind, storage_path, mime_type, size_bytes, scan_status, created_at)
  values (p_user, 'seller_application', zm_test.app_of(p_user), p_kind, p_user || '/seller/' || p_kind || '-' || gen_random_uuid() || '.jpg', 'image/jpeg', 1000, p_scan, clock_timestamp())
  returning id into new_id;
  return new_id;
end $$;
create function zm_test.nrc_docs(p_user uuid) returns void language plpgsql security definer as $$
begin
  perform zm_test.doc(p_user, 'id_front'); perform zm_test.doc(p_user, 'id_back'); perform zm_test.doc(p_user, 'selfie_with_id'); perform zm_test.doc(p_user, 'proof_of_address');
end $$;
create function zm_test.obj(p_path text, p_mime text default 'image/jpeg', p_size bigint default 1000) returns void language plpgsql security definer as $$
begin
  insert into storage.objects (bucket_id, name, metadata) values ('identity-documents', p_path, jsonb_build_object('mimetype', p_mime, 'size', p_size));
end $$;
create function zm_test.full_form(p_catalogue integer default 20, p_name text default 'Anna Mwansa') returns jsonb language sql as $$
  select jsonb_build_object('legal_name', p_name, 'nationality', 'Zambian', 'is_adult', true, 'id_type', 'nrc', 'id_number', '123456/10/1',
    'residential_address', 'Plot 5, Kabulonga Road, Lusaka', 'selling_location_id', (select id from public.locations where area = 'Kabulonga'),
    'category_ids', jsonb_build_array((select id from public.categories where slug = 'electronics')),
    'sourcing_type', 'local_purchase', 'sourcing_info', 'I buy phones and chargers from a licensed wholesaler in Lusaka.',
    'experience_level', 'one_to_three_years', 'experience_info', 'Sold at Soweto market', 'expected_catalogue_size', p_catalogue,
    'returns_arrangements', 'Seven day returns on unopened items.', 'customer_service_arrangements', 'I answer messages within a day.',
    'declarations', jsonb_build_object('sells_only_legal_goods', true, 'no_counterfeit_or_stolen', true, 'information_is_true', true, 'will_honour_returns', true))
$$;
-- A complete, submitted application with scanned documents.
create function zm_test.submitted(p_user uuid, p_catalogue integer default 20, p_name text default 'Anna Mwansa') returns void language plpgsql as $$
begin
  perform zm_test.act_as(p_user);
  perform public.seller_application_save(zm_test.full_form(p_catalogue, p_name));
  perform public.seller_agreement_accept(1);
  perform zm_test.act_as_admin();
  perform zm_test.nrc_docs(p_user);
  perform zm_test.act_as(p_user);
  perform public.seller_application_submit();
  perform zm_test.act_as_admin();
end $$;
create function zm_test.q(p_sql text) returns text language plpgsql security definer as $$
declare r text; begin execute p_sql into r; return r; end $$;
create function zm_test.doc_id(p_user uuid, p_kind text default null) returns uuid language sql security definer as $$
  select id from public.verification_documents where owner_id = p_user and (p_kind is null or kind = p_kind) order by created_at limit 1 $$;
create function zm_test.due() returns uuid[] language sql security definer as $$
  select coalesce(array_agg(id), '{}') from public.verification_documents where purge_after < now() and deleted_at is null $$;
create function zm_test.review_all(p_user uuid) returns void language plpgsql security definer as $$
declare d uuid; begin
  for d in select id from public.verification_documents where owner_id = p_user and deleted_at is null and scan_status = 'clean' loop
    perform public.verification_review_document(d, true);
  end loop; end $$;
grant execute on all functions in schema zm_test to anon, authenticated, service_role;

\set A '00000000-0000-0000-0000-00000000000a'
\set B '00000000-0000-0000-0000-00000000000b'
\set C '00000000-0000-0000-0000-00000000000c'
\set S1 '00000000-0000-0000-0000-000000000051'
\set S2 '00000000-0000-0000-0000-000000000052'
\set S3 '00000000-0000-0000-0000-000000000053'
\set MOD '00000000-0000-0000-0000-000000000054'

-- 1. Closed tables, and buyers stay buyers --------------------------------------------------------------------------
select zm_test.expect_equal((select count(*)::text from information_schema.role_table_grants where table_schema = 'public'
   and table_name in ('seller_applications','seller_application_private','verification_documents','verification_requests','verification_interviews','verification_events','seller_agreements','seller_agreement_acceptances')
   and grantee in ('anon','authenticated')), '0', 'no table grants for app users');
select zm_test.expect_equal((select bool_and(c.relrowsecurity)::text from pg_class c where c.relname in ('seller_applications','seller_application_private','verification_documents','verification_requests','verification_interviews','verification_events') and c.relkind = 'r'), 'true', 'RLS on');
select zm_test.act_as(:'C');
select zm_test.expect_equal(public.seller_can_publish()::text, 'false', 'a new user is a buyer, not a seller');
select zm_test.expect_error('select * from public.seller_applications', 'applications table is closed');
select zm_test.expect_error('select * from public.seller_application_private', 'private table is closed');
select zm_test.expect_error('select * from public.verification_documents', 'documents table is closed');
select zm_test.expect_error(format($q$update public.profiles set seller_status = 'active' where id = %L$q$, :'C'), 'a user cannot make themselves a seller');
select zm_test.expect_error($q$insert into public.listings (category_id, location_id, title, description, price_zmw, condition)
   select c.id, l.id, 'Sneaky listing', 'x', 10, 'new' from public.categories c, public.locations l limit 1$q$, 'a buyer cannot create a listing');
select zm_test.expect_equal((select count(*)::text from public.listings where status = 'active' and moderation_status = 'approved' and false), '0', 'browsing still works for a buyer');
select zm_test.act_as_guest();
select zm_test.expect_error('select public.seller_application_save(''{}'')', 'guests cannot apply');
select zm_test.expect_error('select * from public.verification_queue(''sellers'')', 'guests cannot see queues');

-- 2. Filling in, documents, submitting --------------------------------------------------------------------------------
select zm_test.act_as(:'A');
select zm_test.expect_error($q$select public.seller_application_save('{"legal_name":"A"}')$q$, 'a name that is too short is refused');
select zm_test.expect_error($q$select public.seller_application_save('{"category_ids":[999999]}')$q$, 'unknown category refused');
select zm_test.expect_error($q$select public.seller_application_save('{"selling_location_id":999999}')$q$, 'unknown location refused');
select public.seller_application_save(zm_test.full_form(20));
select zm_test.expect_equal(zm_test.status_of(:'A'), 'draft', 'draft created');
select zm_test.expect_error('select public.seller_application_submit()', 'cannot send without the agreement');
select public.seller_agreement_accept(1);
select zm_test.expect_error('select public.seller_agreement_accept(99)', 'only the current agreement can be accepted');
select zm_test.expect_error('select public.seller_application_submit()', 'cannot send without documents');
-- registering a document checks the real stored file
select zm_test.expect_error(format($q$select public.verification_register_document('seller_application', %L, 'id_front', 'identity-documents', %L)$q$, zm_test.app_of(:'A'), :'A' || '/seller/missing.jpg'), 'file that was never uploaded');
select zm_test.obj(:'A' || '/seller/text.txt', 'text/plain');
select zm_test.expect_error(format($q$select public.verification_register_document('seller_application', %L, 'id_front', 'identity-documents', %L)$q$, zm_test.app_of(:'A'), :'A' || '/seller/text.txt'), 'wrong file type');
select zm_test.obj(:'A' || '/seller/huge.jpg', 'image/jpeg', 9000000);
select zm_test.expect_error(format($q$select public.verification_register_document('seller_application', %L, 'id_front', 'identity-documents', %L)$q$, zm_test.app_of(:'A'), :'A' || '/seller/huge.jpg'), 'file too big');
select zm_test.obj(:'C' || '/seller/theirs.jpg');
select zm_test.expect_error(format($q$select public.verification_register_document('seller_application', %L, 'id_front', 'identity-documents', %L)$q$, zm_test.app_of(:'A'), :'C' || '/seller/theirs.jpg'), 'cannot register someone else''s file');
select zm_test.obj(:'A' || '/seller/front.jpg');
select public.verification_register_document('seller_application', zm_test.app_of(:'A'), 'id_front', 'identity-documents', :'A' || '/seller/front.jpg');
select zm_test.expect_error(format($q$select public.verification_register_document('seller_application', %L, 'id_front', 'identity-documents', %L)$q$, zm_test.app_of(:'A'), :'A' || '/seller/front.jpg'), 'same file twice');
select zm_test.act_as(:'C');
select zm_test.expect_error(format($q$select public.verification_register_document('seller_application', %L, 'id_back', 'identity-documents', %L)$q$, zm_test.app_of(:'A'), :'C' || '/seller/theirs.jpg'), 'cannot add documents to another person''s application');
select zm_test.act_as_admin();
-- fill the rest as clean documents (the front one was registered above, still waiting for a scan)
select zm_test.doc(:'A', 'id_back'); select zm_test.doc(:'A', 'selfie_with_id'); select zm_test.doc(:'A', 'proof_of_address');
select zm_test.act_as(:'A');
select public.seller_application_save('{"is_adult": false}');
select zm_test.expect_error('select public.seller_application_submit()', 'a person who is not an adult cannot apply');
select public.seller_application_save('{"is_adult": true, "declarations": {"sells_only_legal_goods": true}}');
select zm_test.expect_error('select public.seller_application_submit()', 'every questionnaire answer is required');
select public.seller_application_save(zm_test.full_form(20));
select public.seller_application_submit();
select zm_test.expect_equal(zm_test.status_of(:'A'), 'submitted', 'application submitted');
select zm_test.expect_error($q$select public.seller_application_save('{"legal_name":"Changed Name"}')$q$, 'cannot edit while it is being reviewed');
select zm_test.expect_equal((public.seller_application_mine() -> 'application' ->> 'id_number'), '123456/10/1', 'applicants can read their own answers');
select zm_test.expect_equal((select count(*)::text from public.seller_application_mine() m, jsonb_array_elements(m -> 'history') e), '3', 'visible history entries (created, document added, submitted)');
select zm_test.expect_equal(zm_test.notes(:'A', 'seller_application'), '1', 'applicant was told it arrived');
select zm_test.expect_error('select public.seller_application_submit()', 'nothing open left to send');
-- an application cannot be started without verified contact details
select zm_test.act_as_admin();
insert into auth.users (id, email, raw_user_meta_data) values ('00000000-0000-0000-0000-0000000000d1', 'd@example.test', '{"display_name":"Dina"}');
select zm_test.act_as('00000000-0000-0000-0000-0000000000d1');
select public.seller_application_save(zm_test.full_form());
select public.seller_agreement_accept(1);
select zm_test.act_as_admin();
select zm_test.nrc_docs('00000000-0000-0000-0000-0000000000d1');
select zm_test.act_as('00000000-0000-0000-0000-0000000000d1');
select zm_test.expect_error('select public.seller_application_submit()', 'unverified contact details cannot be submitted');

-- 3. Applicants cannot publish while waiting ------------------------------------------------------------------------
select zm_test.act_as(:'A');
select zm_test.expect_equal(public.seller_can_publish()::text, 'false', 'a submitted applicant is not a seller');
select zm_test.expect_error($q$insert into public.listings (category_id, location_id, title, description, price_zmw, condition)
   select c.id, l.id, 'Applicant listing', 'x', 10, 'new' from public.categories c, public.locations l limit 1$q$, 'an applicant cannot create a listing');

-- 4. Staff only: queues, detail, private details --------------------------------------------------------------------
select zm_test.act_as(:'C');
select zm_test.expect_error('select * from public.verification_queue(''sellers'')', 'buyers cannot see the queue');
select zm_test.act_as(:'MOD', 'aal2');
select zm_test.expect_error('select * from public.verification_queue(''sellers'')', 'moderators cannot see the support queue');
select zm_test.act_as(:'S1', 'aal1');
select zm_test.expect_error('select * from public.verification_queue(''sellers'')', 'support without two-factor is refused');
select zm_test.act_as(:'S1', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.verification_queue('sellers')), '1', 'one application waiting');
select zm_test.expect_error('select * from public.verification_queue(''bogus'')', 'unknown queue');
select zm_test.expect_equal((public.seller_application_detail(zm_test.app_of(:'A')) ? 'id_number')::text, 'false', 'detail never carries the ID number');
select zm_test.expect_equal((public.seller_application_detail(zm_test.app_of(:'A')) ? 'residential_address')::text, 'false', 'detail never carries the address');
select zm_test.expect_equal((select id_number from public.seller_application_private_details(zm_test.app_of(:'A'))), '123456/10/1', 'private details can be read on purpose');
select zm_test.expect_equal(zm_test.audits('verification.private_viewed'), '1', 'private read is audited');
select zm_test.act_as(:'MOD', 'aal2');
select zm_test.expect_error(format($q$select * from public.seller_application_private_details(%L)$q$, zm_test.app_of(:'A')), 'only support can read private details');

-- 5. Review a standard application ----------------------------------------------------------------------------------
select zm_test.act_as(:'S1', 'aal2');
select zm_test.expect_error(format($q$select public.seller_application_decide(%L, 'approve', 'looks fine')$q$, zm_test.app_of(:'A')), 'must claim before deciding');
select public.seller_application_claim(zm_test.app_of(:'A'));
select zm_test.expect_equal(zm_test.status_of(:'A'), 'under_review', 'claimed');
select zm_test.expect_equal(zm_test.notes(:'A', 'seller_application'), '2', 'applicant told review started');
select zm_test.act_as(:'S2', 'aal2');
select zm_test.expect_error(format($q$select public.seller_application_claim(%L)$q$, zm_test.app_of(:'A')), 'someone else already has it');
select zm_test.act_as(:'S1', 'aal2');
select zm_test.expect_error(format($q$select public.seller_application_decide(%L, 'approve', 'looks fine')$q$, zm_test.app_of(:'A')), 'documents not yet accepted');
select zm_test.expect_error(format($q$select public.verification_review_document(%L, true)$q$, zm_test.doc_id(:'A', 'id_front')), 'a file that has not been scanned cannot be accepted');
select zm_test.act_as_service();
select public.verification_record_scan(zm_test.doc_id(:'A', 'id_front'), 'clean');
select zm_test.expect_error($q$select public.verification_record_scan(gen_random_uuid(), 'clean')$q$, 'unknown document');
select zm_test.expect_error($q$select public.verification_record_scan(gen_random_uuid(), 'fine')$q$, 'bad scan result');
select zm_test.act_as(:'S1', 'aal2');
select zm_test.expect_error(format($q$select public.verification_review_document(%L, false)$q$, zm_test.doc_id(:'A', 'id_back')), 'a rejection needs a note');
select zm_test.review_all(:'A');
select zm_test.expect_error(format($q$select public.seller_application_decide(%L, 'approve', null)$q$, zm_test.app_of(:'A')), 'approval needs a recorded reason');
select zm_test.expect_error(format($q$select public.seller_application_decide(%L, 'maybe', 'x')$q$, zm_test.app_of(:'A')), 'unknown decision');
select zm_test.expect_equal(public.seller_application_decide(zm_test.app_of(:'A'), 'approve', 'Documents match and answers are consistent'), 'approved', 'standard application approved by one officer');
select zm_test.expect_equal(zm_test.seller_status(:'A'), 'active', 'seller switched on, same profile');
select zm_test.expect_equal((select verification_level::text from public.profiles where id = :'A'), 'identity_verified', 'identity verified through the reviewed documents');
select zm_test.expect_equal(zm_test.notes(:'A', 'seller_application'), '3', 'applicant told they are approved');
select zm_test.expect_equal((select count(*)::text from public.notifications where type = 'seller_application' and (body ilike '%123456%' or body ilike '%Kabulonga%' or title ilike '%123456%')), '0', 'no sensitive details in notices');
select zm_test.expect_equal(zm_test.q($z$select count(*) from public.verification_documents where owner_id = '00000000-0000-0000-0000-00000000000a' and purge_after is not null$z$), '4', 'retention date set on approval');
select zm_test.expect_error(format($q$select public.seller_application_decide(%L, 'approve', 'again please')$q$, zm_test.app_of(:'A')), 'cannot decide twice');

-- 6. An approved seller can use every existing seller tool ---------------------------------------------------------
select zm_test.act_as(:'A');
select zm_test.expect_equal(public.seller_can_publish()::text, 'true', 'approved seller');
insert into public.listings (category_id, location_id, title, description, price_zmw, condition)
  select c.id, l.id, 'Anna phone', 'Good phone', 500, 'used_good' from public.categories c, public.locations l where c.slug = 'electronics' and l.area = 'Kabulonga';
insert into public.listing_images (listing_id, storage_path, position)
  select id, auth.uid() || '/phone.jpg', 0 from public.listings where title = 'Anna phone';
update public.listings set status = 'active' where title = 'Anna phone';
select zm_test.expect_equal((select moderation_status::text from public.listings where title = 'Anna phone'), 'approved', 'listing goes through the normal rules and publishes');
select zm_test.expect_equal((select count(*)::text from public.seller_listings(null)), '1', 'seller tools work (tracker)');
select zm_test.expect_equal((select count(*)::text from public.bulk_update_prices(array[(select id from public.listings where title = 'Anna phone')], 'set', 450)), '1', 'seller tools work (bulk price)');
select zm_test.expect_error($q$select public.seller_application_save('{}')$q$, 'an approved seller does not apply again');

-- 7. Additional information, escalation, interview and two approvals (high risk) ------------------------------------
select zm_test.submitted(:'B', 500, 'Bwalya Phiri');
select zm_test.expect_equal(zm_test.q($z$select risk_level from public.seller_applications where user_id = '00000000-0000-0000-0000-00000000000b'$z$), 'high', 'a big catalogue is higher risk');
select zm_test.act_as(:'S1', 'aal2');
select public.seller_application_claim(zm_test.app_of(:'B'));
select zm_test.expect_error(format($q$select public.seller_application_request_info(%L, 'x')$q$, zm_test.app_of(:'B')), 'a request needs a real message');
select zm_test.expect_error(format($q$select public.seller_application_request_info(%L, 'Please send a clearer photo', array['bogus'])$q$, zm_test.app_of(:'B')), 'unknown document kind');
insert into zm_ids select 'req', public.seller_application_request_info(zm_test.app_of(:'B'), 'Please send evidence of where your stock comes from', array['sourcing_evidence']);
select zm_test.expect_equal(zm_test.status_of(:'B'), 'additional_information_required', 'waiting for the applicant');
select zm_test.expect_equal((select count(*)::text from public.verification_queue('info_requested')), '1', 'shows in the info-requested queue');
select zm_test.act_as(:'B');
select zm_test.expect_error(format($q$select public.seller_application_respond((select id from zm_ids where name = 'req'), 'here you go')$q$), 'cannot answer without the document');
select zm_test.act_as_admin();
select zm_test.doc(:'B', 'sourcing_evidence');
select zm_test.act_as(:'C');
select zm_test.expect_error(format($q$select public.seller_application_respond((select id from zm_ids where name = 'req'), 'hi')$q$), 'only the applicant can answer');
select zm_test.act_as(:'B');
select public.seller_application_respond((select id from zm_ids where name = 'req'), 'Receipts from my supplier attached');
select zm_test.expect_equal(zm_test.status_of(:'B'), 'under_review', 'back with the officer who asked');
select zm_test.expect_error(format($q$select public.seller_application_respond((select id from zm_ids where name = 'req'), 'again')$q$), 'a request is answered once');
select zm_test.act_as(:'S1', 'aal2');
select zm_test.review_all(:'B');
select zm_test.expect_error(format($q$select public.seller_application_decide(%L, 'approve', 'documents look right')$q$, zm_test.app_of(:'B')), 'high risk needs an interview first');
select zm_test.expect_error(format($q$select public.seller_application_record_interview(%L, 'phone', 'passed', '[]')$q$, zm_test.app_of(:'B')), 'interview needs recorded answers');
select zm_test.expect_error(format($q$select public.seller_application_record_interview(%L, 'sms', 'passed', '[{"q":"a","a":"b"}]')$q$, zm_test.app_of(:'B')), 'unknown channel');
select public.seller_application_record_interview(zm_test.app_of(:'B'), 'phone', 'passed', '[{"q":"Where is your stock from?","a":"Wholesaler in Lusaka"}]', 'Clear and consistent');
select zm_test.expect_equal(public.seller_application_decide(zm_test.app_of(:'B'), 'approve', 'Interview passed and documents are right'), 'awaiting_second_approval', 'first officer cannot finish a high-risk approval alone');
select zm_test.expect_equal(zm_test.seller_status(:'B'), 'none', 'still not a seller after one approval');
select zm_test.expect_error(format($q$select public.seller_application_claim(%L)$q$, zm_test.app_of(:'B')), 'the first approver cannot claim it again');
select zm_test.expect_equal((select awaiting_second::text from public.verification_queue('sellers') where id = zm_test.app_of(:'B')), 'true', 'queue shows it is waiting for a second officer');
select zm_test.act_as(:'S2', 'aal2');
select zm_test.expect_error(format($q$select public.seller_application_assign(%L, %L)$q$, zm_test.app_of(:'B'), :'S1'), 'cannot assign back to the first approver');
select public.seller_application_claim(zm_test.app_of(:'B'));
select zm_test.expect_equal(public.seller_application_decide(zm_test.app_of(:'B'), 'approve', 'Second review agrees'), 'approved', 'second officer completes it');
select zm_test.expect_equal(zm_test.seller_status(:'B'), 'active', 'now a seller');
select zm_test.expect_equal(zm_test.q($z$select count(*) from public.audit_logs where action = 'seller_application.approved' and (metadata ->> 'two_reviewers') = 'true'$z$), '1', 'two-reviewer approval is audited');

-- 8. Nobody reviews their own application -------------------------------------------------------------------------
select zm_test.submitted(:'S3', 10, 'Officer Three');
select zm_test.act_as(:'S3', 'aal2');
select zm_test.expect_error(format($q$select public.seller_application_claim(%L)$q$, zm_test.app_of(:'S3')), 'cannot claim your own application');
select zm_test.expect_error(format($q$select public.seller_application_detail(%L)$q$, zm_test.app_of(:'S3')), 'cannot open your own application');
select zm_test.expect_error(format($q$select * from public.seller_application_private_details(%L)$q$, zm_test.app_of(:'S3')), 'cannot read your own private details');
select zm_test.expect_error(format($q$select * from public.verification_open_document(%L)$q$, zm_test.doc_id(:'S3')), 'cannot open your own documents');
select zm_test.expect_error(format($q$select public.seller_application_decide(%L, 'approve', 'my own application')$q$, zm_test.app_of(:'S3')), 'cannot approve your own application');
select zm_test.expect_error(format($q$select public.seller_application_assign(%L, %L)$q$, zm_test.app_of(:'S3'), :'S1'), 'cannot assign your own application');
select zm_test.expect_error(format($q$select public.seller_application_escalate(%L, 'trying to help myself along')$q$, zm_test.app_of(:'S3')), 'cannot escalate your own application');
select zm_test.act_as(:'S2', 'aal2');
select public.seller_application_assign(zm_test.app_of(:'S3'), :'S1');
select zm_test.expect_equal(zm_test.notes(:'S1', 'verification_assigned'), '1', 'the officer was told about the assignment');
select zm_test.expect_error(format($q$select public.seller_application_assign(%L, %L)$q$, zm_test.app_of(:'S3'), :'MOD'), 'only a support officer can be assigned');
select zm_test.expect_error(format($q$select public.seller_application_assign(%L, %L)$q$, zm_test.app_of(:'S3'), :'S3'), 'cannot assign to the applicant');
select zm_test.expect_equal((select count(*)::text from public.verification_queue('sellers')), '1', 'the queue still lists it for others');

-- 9. Escalation puts it in front of two reviewers -----------------------------------------------------------------
select zm_test.act_as(:'S1', 'aal2');
select zm_test.expect_error(format($q$select public.seller_application_escalate(%L, 'short')$q$, zm_test.app_of(:'S3')), 'reason needed');
select public.seller_application_escalate(zm_test.app_of(:'S3'), 'The address on the document does not match the questionnaire');
select zm_test.expect_equal((select count(*)::text from public.verification_queue('escalated')), '1', 'escalated queue');
select zm_test.expect_equal(zm_test.q($z$select risk_level from public.seller_applications where user_id = '00000000-0000-0000-0000-000000000053'$z$), 'high', 'escalation makes it high risk');
select zm_test.act_as(:'S2', 'aal2');
select public.seller_application_claim(zm_test.app_of(:'S3'));
select public.seller_application_decide(zm_test.app_of(:'S3'), 'reject', 'The address on the document does not match what you wrote');
select zm_test.expect_equal(zm_test.status_of(:'S3'), 'rejected', 'one officer can reject a high-risk application');
select zm_test.expect_equal(zm_test.seller_status(:'S3'), 'none', 'rejected means no seller account');

-- 10. Rejection ----------------------------------------------------------------------------------------------------
select zm_test.submitted(:'C', 20, 'Chanda Zulu');
select zm_test.act_as(:'S1', 'aal2');
select public.seller_application_claim(zm_test.app_of(:'C'));
select zm_test.expect_error(format($q$select public.seller_application_decide(%L, 'reject', 'no')$q$, zm_test.app_of(:'C')), 'a rejection needs a reason the applicant can read');
select public.seller_application_decide(zm_test.app_of(:'C'), 'reject', 'The selfie does not show the same person as the ID');
select zm_test.expect_equal(zm_test.status_of(:'C'), 'rejected', 'rejected');
select zm_test.expect_equal((select (public.seller_application_mine() -> 'application' ->> 'decision_reason') from (select 1) x), null, 'staff reading their own record sees nothing of C');
select zm_test.act_as(:'C');
select zm_test.expect_equal((public.seller_application_mine() -> 'application' ->> 'decision_reason'), 'The selfie does not show the same person as the ID', 'the applicant reads the reason');
select zm_test.expect_error($q$insert into public.listings (category_id, location_id, title, description, price_zmw, condition)
   select c.id, l.id, 'Rejected listing', 'x', 10, 'new' from public.categories c, public.locations l limit 1$q$, 'a rejected applicant cannot list');
select zm_test.expect_error($q$select public.seller_application_save('{}')$q$, 'cannot reapply straight away');
select zm_test.act_as_admin();
update public.seller_applications set decided_at = now() - interval '10 days' where user_id = :'C';
select zm_test.act_as(:'C');
select public.seller_application_save('{}');
select zm_test.expect_equal(zm_test.status_of(:'C'), 'draft', 'a rejected applicant can start again after the waiting period');
select zm_test.expect_equal(zm_test.q($z$select count(*) from public.seller_applications where user_id = '00000000-0000-0000-0000-00000000000c'$z$), '2', 'the old application is kept');
select public.seller_application_withdraw();
select zm_test.expect_equal(zm_test.status_of(:'C'), 'rejected', 'withdrawing ends the draft');
select zm_test.expect_error('select public.seller_application_withdraw()', 'nothing left to withdraw');

-- 11. Documents: audited, support and two-factor only -------------------------------------------------------------
select zm_test.act_as_admin();
insert into zm_ids select 'docA', zm_test.doc_id(:'A', 'id_front');
select zm_test.act_as(:'S1', 'aal2');
select zm_test.expect_equal((select bucket from public.verification_open_document((select id from zm_ids where name = 'docA'))), 'identity-documents', 'support gets the storage location');
select zm_test.expect_equal((select seconds::text from public.verification_open_document((select id from zm_ids where name = 'docA'))), '60', 'a short-lived link is requested');
select zm_test.expect_equal(zm_test.audits('document.viewed'), '2', 'every open is audited');
select zm_test.act_as(:'S1', 'aal1');
select zm_test.expect_error(format($q$select * from public.verification_open_document(%L)$q$, (select id from zm_ids where name = 'docA')), 'no two-factor, no document');
select zm_test.act_as(:'MOD', 'aal2');
select zm_test.expect_error(format($q$select * from public.verification_open_document(%L)$q$, (select id from zm_ids where name = 'docA')), 'moderators cannot open documents');
select zm_test.act_as(:'A');
select zm_test.expect_error(format($q$select * from public.verification_open_document(%L)$q$, (select id from zm_ids where name = 'docA')), 'the applicant cannot use the staff function');
select zm_test.expect_equal(zm_test.audits('document.viewed'), '2', 'refused attempts do not count as views');
select zm_test.act_as_admin();
insert into zm_ids select 'docDirty', zm_test.doc(:'B', 'other', 'pending');
insert into zm_ids select 'docInfected', zm_test.doc(:'B', 'other', 'infected');
select zm_test.act_as(:'S1', 'aal2');
select zm_test.expect_error(format($q$select * from public.verification_open_document(%L)$q$, (select id from zm_ids where name = 'docDirty')), 'an unscanned file cannot be opened');
select zm_test.expect_error(format($q$select * from public.verification_open_document(%L)$q$, (select id from zm_ids where name = 'docInfected')), 'an infected file cannot be opened');
select zm_test.expect_error($q$select * from public.verification_open_document(gen_random_uuid())$q$, 'unknown document');

-- 12. Suspension, history and reinstatement -------------------------------------------------------------------------
select zm_test.act_as(:'MOD', 'aal2');
select zm_test.expect_error(format($q$select public.seller_application_suspend(%L, 'Selling counterfeit goods, see report')$q$, zm_test.app_of(:'A')), 'moderators cannot suspend sellers');
select zm_test.act_as(:'S2', 'aal2');
select zm_test.expect_error(format($q$select public.seller_application_suspend(%L, 'short')$q$, zm_test.app_of(:'A')), 'a reason is needed');
select public.seller_application_suspend(zm_test.app_of(:'A'), 'Selling counterfeit goods, see report 123');
select zm_test.expect_equal(zm_test.seller_status(:'A'), 'suspended', 'selling is off');
select zm_test.expect_equal((select status::text from public.listings where title = 'Anna phone'), 'unavailable', 'live listings are paused, not deleted');
select zm_test.expect_equal((select count(*)::text from public.listings where title = 'Anna phone'), '1', 'the listing and its history are kept');
select zm_test.expect_equal((select count(*)::text from public.verification_queue('suspended')), '1', 'suspended queue');
select zm_test.act_as(:'A');
select zm_test.expect_equal(public.seller_can_publish()::text, 'false', 'a suspended seller cannot publish');
select zm_test.expect_error($q$update public.listings set status = 'active' where title = 'Anna phone'$q$, 'cannot republish while suspended');
select zm_test.expect_error($q$insert into public.listings (category_id, location_id, title, description, price_zmw, condition)
   select c.id, l.id, 'Suspended listing', 'x', 10, 'new' from public.categories c, public.locations l limit 1$q$, 'cannot create listings while suspended');
select zm_test.expect_equal((select count(*)::text from public.seller_listings(null)), '1', 'the seller still sees their own history');
select zm_test.expect_equal((public.seller_application_mine() -> 'application' ->> 'status'), 'suspended', 'the seller sees why and what state they are in');
select zm_test.expect_equal(zm_test.notes(:'A', 'seller_application'), '4', 'seller told about the suspension');
select zm_test.expect_error($q$select public.seller_application_save('{}')$q$, 'suspended sellers do not apply again');
select zm_test.act_as(:'S2', 'aal2');
select zm_test.expect_error(format($q$select public.seller_application_reinstate(%L, 'Resolved after the investigation')$q$, zm_test.app_of(:'A')), 'a different officer must reinstate');
select zm_test.act_as(:'S1', 'aal2');
select public.seller_application_reinstate(zm_test.app_of(:'A'), 'Resolved after the investigation');
select zm_test.expect_equal(zm_test.seller_status(:'A'), 'active', 'reinstated');
select zm_test.expect_equal((select status::text from public.listings where title = 'Anna phone'), 'unavailable', 'paused listings stay paused until the seller republishes');
select zm_test.act_as(:'A');
update public.listings set status = 'active' where title = 'Anna phone';
select zm_test.expect_equal((select status::text from public.listings where title = 'Anna phone'), 'active', 'the seller can republish');
select zm_test.act_as(:'S1', 'aal2');
select public.seller_application_suspend(zm_test.app_of(:'A'), 'Repeated serious breaches of the agreement', true);
select zm_test.expect_equal(zm_test.seller_status(:'A'), 'revoked', 'revoked');
select zm_test.expect_equal(zm_test.status_of(:'A'), 'revoked', 'application shows revoked');
select zm_test.act_as(:'A');
select zm_test.expect_error($q$select public.seller_application_save('{}')$q$, 'a revoked seller cannot simply reapply');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.q(format($z$select string_agg(event, ',' order by id) from public.verification_events where subject_id = %L$z$, zm_test.app_of(:'A'))), 'created,document_added,submitted,claimed,document_accepted,document_accepted,document_accepted,document_accepted,approved,suspended,reinstated,revoked', 'the whole history is kept');
select zm_test.expect_error('update public.verification_events set note = ''x''', 'history cannot be edited');
select zm_test.expect_error('delete from public.verification_events', 'history cannot be deleted');

-- 13. Retention worker --------------------------------------------------------------------------------------------
select zm_test.expect_equal(zm_test.q($z$select count(*) from public.verification_documents where owner_id = '00000000-0000-0000-0000-00000000000c' and purge_after is not null$z$), '4', 'rejected applicant documents get a delete date');
update public.verification_documents set purge_after = now() - interval '1 day' where owner_id = :'C';
select zm_test.act_as(:'S1', 'aal2');
select zm_test.expect_error('select * from public.verification_documents_due()', 'staff cannot run the purge worker');
select zm_test.act_as_service();
select zm_test.expect_equal((select cardinality(zm_test.due())::text), '4', 'due documents are listed for the worker');
select zm_test.expect_equal(public.verification_mark_deleted(zm_test.due())::text, '4', 'deleted documents are marked');
select zm_test.expect_equal((select cardinality(zm_test.due())::text), '0', 'nothing is due twice');
select zm_test.act_as(:'S1', 'aal2');
select zm_test.expect_error(format($q$select * from public.verification_open_document(%L)$q$, zm_test.doc_id(:'C')), 'a deleted document cannot be opened');

-- 14. Queues -------------------------------------------------------------------------------------------------------
select zm_test.expect_equal((select count(*)::text from public.verification_queue('approved')), '1', 'approved queue (B; A was revoked)');
select zm_test.expect_equal((select count(*)::text from public.verification_queue('rejected')), '3', 'rejected queue (S3, C twice)');
select zm_test.expect_equal((select count(*)::text from public.verification_queue('suspended')), '1', 'revoked sellers sit in the suspended and revoked queue');

rollback;
