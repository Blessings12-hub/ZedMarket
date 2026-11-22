-- User & Trust Management (migration 0010): who may read what, application queues, user lists,
-- profiles, document access with audit, verification history and the audit trail.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/user_trust.sql

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


-- People: a, b applicants; s support; m moderator; t tech admin; o outsider; x support who also applies
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'a@example.test', '{"display_name":"Applicant Anna"}'),
  ('00000000-0000-0000-0000-00000000000b', 'b@example.test', '{"display_name":"Applicant Bwalya"}'),
  ('00000000-0000-0000-0000-00000000000e', 's@example.test', '{"display_name":"Support Sam"}'),
  ('00000000-0000-0000-0000-000000000001', 'm@example.test', '{"display_name":"Moderator Mo"}'),
  ('00000000-0000-0000-0000-000000000002', 't@example.test', '{"display_name":"Tech Tina"}'),
  ('00000000-0000-0000-0000-00000000000d', 'o@example.test', '{"display_name":"Outsider Omar"}'),
  ('00000000-0000-0000-0000-000000000003', 'x@example.test', '{"display_name":"Support Xena"}');
insert into public.admin_roles (user_id, role) values
  ('00000000-0000-0000-0000-00000000000e', 'support'),
  ('00000000-0000-0000-0000-000000000001', 'moderator'),
  ('00000000-0000-0000-0000-000000000002', 'tech_admin'),
  ('00000000-0000-0000-0000-000000000003', 'support');

insert into public.identity_verifications (id, user_id, document_type, document_path, created_at) values
  ('10000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000a', 'national_id', '00000000-0000-0000-0000-00000000000a/id.jpg', '2026-01-01'),
  ('10000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000b', 'passport', '00000000-0000-0000-0000-00000000000b/pp.jpg', '2026-01-02'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000003', 'national_id', '00000000-0000-0000-0000-000000000003/id.jpg', '2026-01-03');
insert into public.businesses (id, owner_id, name, slug) values
  ('20000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000a', 'Anna Traders', 'anna-traders'),
  ('20000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000003', 'Xena Shop', 'xena-shop');
insert into public.business_verifications (id, business_id, registration_number, document_path, created_at) values
  ('30000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a', 'PACRA-1234', '00000000-0000-0000-0000-00000000000a/biz.pdf', '2026-01-04'),
  ('30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000003', 'PACRA-9999', '00000000-0000-0000-0000-000000000003/biz.pdf', '2026-01-05');

grant execute on all functions in schema zm_test to anon, authenticated, service_role;

\set A '00000000-0000-0000-0000-00000000000a'
\set B '00000000-0000-0000-0000-00000000000b'
\set S '00000000-0000-0000-0000-00000000000e'
\set M '00000000-0000-0000-0000-000000000001'
\set T '00000000-0000-0000-0000-000000000002'
\set O '00000000-0000-0000-0000-00000000000d'
\set X '00000000-0000-0000-0000-000000000003'

-- 1. Who can get in
select zm_test.act_as_guest();
select zm_test.expect_error($$select * from public.trust_applications('identity')$$, 'a guest listing applications');
select zm_test.expect_error($$select * from public.trust_users()$$, 'a guest listing users');
select zm_test.act_as(:'O', 'aal2');
select zm_test.expect_error($$select * from public.trust_applications('identity')$$, 'a normal user listing applications');
select zm_test.expect_error($$select * from public.trust_users()$$, 'a normal user listing users');
select zm_test.expect_error(format($$select public.trust_user_profile(%L)$$, :'A'), 'a normal user opening a profile');
select zm_test.expect_error(format($$select public.trust_open_document('identity', %L)$$, '10000000-0000-0000-0000-00000000000a'), 'a normal user opening a document');
select zm_test.expect_error($$select * from public.trust_audit_trail()$$, 'a normal user reading the trail');
select zm_test.act_as(:'S', 'aal1');
select zm_test.expect_error($$select * from public.trust_applications('identity')$$, 'support without two-factor');
select zm_test.expect_error(format($$select public.trust_open_document('identity', %L)$$, '10000000-0000-0000-0000-00000000000a'), 'support without two-factor opening a document');

-- 2. Pending applications, oldest first
select zm_test.act_as(:'S', 'aal2');
select zm_test.expect_equal((select string_agg(subject_name, ',') from public.trust_applications('identity', 'pending')), 'Applicant Anna,Applicant Bwalya,Support Xena', 'pending identity queue, oldest first');
select zm_test.expect_equal((select count(*)::text from public.trust_applications('business', 'pending')), '2', 'pending business queue');
select zm_test.expect_equal((select count(*)::text from public.trust_applications('identity', 'pending', 'bwal')), '1', 'search by name');
select zm_test.expect_equal((select count(*)::text from public.trust_applications('identity', 'pending', '%')), '0', 'a percent sign is not a wildcard');
select zm_test.expect_equal((select count(*)::text from public.trust_applications('identity', 'pending', null, 1, 0)), '1', 'limit works');
select zm_test.expect_equal((select count(*)::text from public.trust_applications('identity', 'pending', null, 1000, 0)), '3', 'huge limit is capped, not an error');
select zm_test.expect_error($$select * from public.trust_applications('passport')$$, 'unknown kind');
select zm_test.expect_equal((select count(*)::text from public.trust_applications('identity', 'approved')), '0', 'nothing approved yet');

-- 3. Moderators can read the lists but not documents or decisions
select zm_test.act_as(:'M', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.trust_applications('identity', 'pending')), '3', 'moderator sees the queue');
select zm_test.expect_error(format($$select public.trust_open_document('identity', %L)$$, '10000000-0000-0000-0000-00000000000a'), 'moderator opening a document');
select zm_test.expect_error(format($$select public.review_identity_verification(%L, true)$$, '10000000-0000-0000-0000-00000000000a'), 'moderator approving');

-- 4. Document review is audited
select zm_test.act_as(:'S', 'aal2');
select zm_test.expect_equal((select public.trust_open_document('identity', '10000000-0000-0000-0000-00000000000a')), '00000000-0000-0000-0000-00000000000a/id.jpg', 'support gets the path');
select zm_test.expect_equal((select public.trust_open_document('business', '30000000-0000-0000-0000-00000000000a')), '00000000-0000-0000-0000-00000000000a/biz.pdf', 'support gets the business document path');
select zm_test.expect_error(format($$select public.trust_open_document('identity', %L)$$, gen_random_uuid()), 'unknown application');
select zm_test.expect_error(format($$select public.trust_open_document('selfie', %L)$$, '10000000-0000-0000-0000-00000000000a'), 'unknown kind');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action = 'document.viewed' and target_id = :'A' and actor_id = :'S'), '2', 'both views were audited against the person');

-- 5. Approve and reject
select zm_test.act_as(:'S', 'aal2');
select zm_test.expect_error(format($$select public.review_identity_verification(%L, false)$$, '10000000-0000-0000-0000-00000000000b'), 'rejecting without a reason');
select zm_test.expect_error(format($$select public.review_identity_verification(%L, false, %L)$$, '10000000-0000-0000-0000-00000000000b', '  '), 'rejecting with a blank reason');
select public.review_identity_verification('10000000-0000-0000-0000-00000000000a', true, 'Looks fine');
select public.review_identity_verification('10000000-0000-0000-0000-00000000000b', false, 'Photo is blurry');
select public.review_business_verification('30000000-0000-0000-0000-00000000000a', false, 'Number not found');
select zm_test.expect_error(format($$select public.review_identity_verification(%L, true)$$, '10000000-0000-0000-0000-00000000000a'), 'deciding twice');
select zm_test.expect_equal((select string_agg(subject_name, ',') from public.trust_applications('identity', 'approved')), 'Applicant Anna', 'approved list');
select zm_test.expect_equal((select string_agg(subject_name || ':' || reviewer_note || ':' || reviewer_name, ',') from public.trust_applications('identity', 'rejected')), 'Applicant Bwalya:Photo is blurry:Support Sam', 'rejected list carries reason and reviewer');
select zm_test.expect_equal((select string_agg(subject_name, ',') from public.trust_applications('business', 'rejected')), 'Anna Traders', 'rejected business list');
select zm_test.expect_equal((select count(*)::text from public.trust_applications('identity', 'pending')), '1', 'only one pending left');

-- Nobody reviews their own application
select zm_test.act_as(:'X', 'aal2');
select zm_test.expect_error(format($$select public.review_identity_verification(%L, true)$$, '10000000-0000-0000-0000-000000000003'), 'support approving their own identity');
select zm_test.expect_error(format($$select public.review_business_verification(%L, true)$$, '30000000-0000-0000-0000-000000000003'), 'support approving their own business');
select zm_test.act_as(:'S', 'aal2');
select public.review_identity_verification('10000000-0000-0000-0000-000000000003', true);
select zm_test.act_as_admin();
select zm_test.expect_equal((select verification_level::text from public.profiles where id = :'A'), 'identity_verified', 'approval set the level');
select zm_test.expect_equal((select verification_level::text from public.profiles where id = :'B'), 'unverified', 'rejection left the level alone');
select zm_test.expect_equal((select verification_status::text from public.businesses where id = '20000000-0000-0000-0000-00000000000a'), 'rejected', 'business marked rejected');

-- 6. Users: verified, suspended, restricted
select zm_test.act_as(:'S', 'aal2');
select zm_test.expect_equal((select string_agg(display_name, ',' order by display_name) from public.trust_users('verified')), 'Applicant Anna,Support Xena', 'verified users');
select zm_test.act_as(:'M', 'aal2');
select public.set_account_state(:'B', 'suspended', 'Fake documents');
select public.set_account_state(:'O', 'restricted', 'Many reports');
select zm_test.expect_equal((select display_name || ':' || state_reason from public.trust_users('suspended')), 'Applicant Bwalya:Fake documents', 'suspended list shows the reason');
select zm_test.expect_equal((select display_name || ':' || state_reason from public.trust_users('restricted')), 'Outsider Omar:Many reports', 'restricted list');
select public.set_account_state(:'B', 'active', 'Appeal accepted');
select zm_test.expect_equal((select count(*)::text from public.trust_users('suspended')), '0', 'reinstated user leaves the suspended list');
select zm_test.expect_equal((select count(*)::text from public.trust_users('all', 'omar')), '1', 'search users by name');
select zm_test.expect_error($$select * from public.trust_users('banned')$$, 'unknown filter');
select zm_test.expect_equal((select count(*)::text from public.trust_users('all', '%')), '0', 'a percent sign is not a wildcard in user search');

-- 7. Profile
select zm_test.act_as(:'S', 'aal2');
select zm_test.expect_equal((select public.trust_user_profile(:'A')->>'display_name'), 'Applicant Anna', 'profile name');
select zm_test.expect_equal((select public.trust_user_profile(:'A')->>'verification_level'), 'identity_verified', 'profile level');
select zm_test.expect_equal((select jsonb_array_length(public.trust_user_profile(:'A')->'businesses')::text), '1', 'profile lists businesses');
select zm_test.expect_equal((select public.trust_user_profile(:'O')->>'state_reason'), 'Many reports', 'restricted profile shows reason');
select zm_test.expect_equal((select public.trust_user_profile(:'S')->'staff_roles')::text, '["support"]', 'staff roles shown');
select zm_test.expect_error(format($$select public.trust_user_profile(%L)$$, gen_random_uuid()), 'unknown user');

-- 8. History: everything, newest first, with reviewers
select zm_test.expect_equal((select count(*)::text from public.trust_verification_history(:'A')), '2', 'history has the identity and the business application');
select zm_test.expect_equal((select string_agg(kind || ':' || status::text || ':' || coalesce(reviewer_name, '-'), ',') from public.trust_verification_history(:'A')), 'business:rejected:Support Sam,identity:approved:Support Sam', 'history newest first with reviewer');
select zm_test.expect_equal((select count(*)::text from public.trust_verification_history(:'O')), '0', 'no history for a user with no applications');

-- 9. Audit trail
select zm_test.act_as(:'M', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.trust_audit_trail('user', :'A')), '3', 'trail for Anna: two document views and one review');
select zm_test.expect_equal((select string_agg(action, ',' order by id) from public.trust_audit_trail('user', :'B')), 'identity.reviewed,account.state_changed,account.state_changed', 'trail for Bwalya in order');
select zm_test.expect_equal((select count(*)::text from public.trust_audit_trail(null, null, :'S')), '6', 'everything Sam did in this section');
select zm_test.expect_equal((select count(*)::text from public.trust_audit_trail(null, null, :'S', 2, 0)), '2', 'paging limit');
-- Staff-team actions are not shown to support or moderators; technical admins see all.
select zm_test.act_as(:'T', 'aal2');
select public.grant_admin_role(:'B', 'finance');
select zm_test.act_as(:'M', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.trust_audit_trail() where action like 'admin_role.%'), '0', 'moderator does not see staff-team actions');
select zm_test.act_as(:'T', 'aal2');
select zm_test.expect_equal((select (count(*) > 0)::text from public.trust_audit_trail() where action not in ('identity.reviewed', 'business.reviewed', 'account.state_changed', 'document.viewed')), 'true', 'tech admin sees the rest');

-- 10. The tables stay closed even with the new functions around
select zm_test.act_as(:'O', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.identity_verifications), '0', 'an outsider still cannot read other people''s applications directly');
select zm_test.expect_equal((select count(*)::text from public.audit_logs), '0', 'an outsider still cannot read the audit log');

-- 11. Page sizes are capped, and the functions are closed to signed-out callers at the permission level
select zm_test.act_as_admin();
insert into auth.users (id, email, raw_user_meta_data)
  select gen_random_uuid(), 'bulk' || i || '@example.test', '{"display_name":"Bulk User"}' from generate_series(1, 105) i;
select zm_test.act_as(:'S', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.trust_users('all', null, 100000, 0)), '100', 'user page is capped at 100');
select zm_test.expect_equal((select count(*)::text from public.trust_users('all', 'bulk user', 100000, 100)), '5', 'second page continues');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'trust\_%' and p.proname <> 'trust_can_read'
     and (has_function_privilege('anon', p.oid, 'execute') or not has_function_privilege('authenticated', p.oid, 'execute'))), '0', 'trust functions: anon closed, signed-in open');
select zm_test.expect_equal((select (has_function_privilege('authenticated', 'public.trust_can_read()', 'execute') or has_function_privilege('anon', 'public.trust_can_read()', 'execute'))::text), 'false', 'the internal role check is not callable from the app');

select 'User and trust management checks passed' as result;
rollback;
