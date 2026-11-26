-- Trust workload and document-access monitor (migration 0028).
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/trust_workload.sql
begin;
create schema zm_test;
grant usage on schema zm_test to anon, authenticated, service_role;
create function zm_test.act_as(p_user uuid, p_aal text default 'aal1') returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  execute 'set local role authenticated';
end $$;
create function zm_test.act_as_admin() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create function zm_test.expect_error(p_sql text, p_what text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'Expected an error but the statement worked: %', p_what;
exception when others then if sqlerrm like 'Expected an error but%' then raise; end if; end $$;
create function zm_test.expect_equal(p_actual text, p_expected text, p_what text) returns void language plpgsql as $$
begin if p_actual is distinct from p_expected then raise exception 'Wrong result for %: expected %, got %', p_what, coalesce(p_expected,'null'), coalesce(p_actual,'null'); end if; end $$;
grant execute on all functions in schema zm_test to anon, authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000a1', 'a@example.test', '{"display_name":"Applicant"}', now()),
  ('00000000-0000-0000-0000-000000000051', 's1@example.test', '{"display_name":"Officer One"}', now()),
  ('00000000-0000-0000-0000-000000000054', 'm@example.test', '{"display_name":"Moderator"}', now());
insert into public.admin_roles (user_id, role) values
  ('00000000-0000-0000-0000-000000000051', 'support'), ('00000000-0000-0000-0000-000000000054', 'moderator');

-- fixtures written as the owner (tables have no app grants)
insert into public.seller_applications (user_id, status, submitted_at, due_at, assigned_to, escalated)
values ('00000000-0000-0000-0000-0000000000a1', 'under_review', now() - interval '5 days', now() - interval '2 days',
        '00000000-0000-0000-0000-000000000051', true);
insert into public.verification_events (subject_type, subject_id, applicant_id, actor_id, event, from_status, to_status, visible_to_applicant, created_at)
select 'seller_application', id, user_id, assigned_to, 'escalated', 'under_review', 'under_review', false, now() - interval '3 days' from public.seller_applications;
insert into public.audit_logs (actor_id, action, target_type, target_id)
select '00000000-0000-0000-0000-000000000051', 'document.viewed', 'user', gen_random_uuid()::text from generate_series(1, 31);
insert into public.audit_logs (actor_id, action, target_type, target_id)
values ('00000000-0000-0000-0000-000000000051', 'verification.private_viewed', 'user', '00000000-0000-0000-0000-0000000000a1');

-- refused: not staff, wrong role, no two-factor
select zm_test.act_as('00000000-0000-0000-0000-0000000000a1', 'aal2');
select zm_test.expect_error($$select public.verification_workload()$$, 'an applicant cannot read workloads');
select zm_test.expect_error($$select * from public.verification_access_monitor(24)$$, 'an applicant cannot read the monitor');
select zm_test.act_as('00000000-0000-0000-0000-000000000054', 'aal2');
select zm_test.expect_error($$select public.verification_workload()$$, 'a moderator is not support');
select zm_test.act_as('00000000-0000-0000-0000-000000000051', 'aal1');
select zm_test.expect_error($$select public.verification_workload()$$, 'support without two-factor is refused');
select zm_test.expect_error($$select public.verification_workload_counts('seller')$$, 'the helper is internal');

-- allowed
select zm_test.act_as('00000000-0000-0000-0000-000000000051', 'aal2');
select zm_test.expect_equal((select (public.verification_workload()->'kinds'->'seller'->>'under_review')), '1', 'seller under review counted');
select zm_test.expect_equal((select (public.verification_workload()->'kinds'->'seller'->>'overdue')), '1', 'overdue counted');
select zm_test.expect_equal((select (public.verification_workload()->'kinds'->'business'->>'submitted')), '0', 'business counts are present even when empty');
select zm_test.expect_equal((select (public.verification_workload()->>'mine')), '1', 'my open work');
select zm_test.expect_equal((select (public.verification_workload()->>'escalations_overdue')), '1', 'escalation 3 days old is past the 24 hour deadline');
select zm_test.expect_equal((select jsonb_array_length(public.verification_workload()->'officers')::text), '1', 'one officer holds work');

select zm_test.expect_equal((select flagged::text from public.verification_access_monitor(24)), 'true', 'many opens are flagged');
select zm_test.expect_equal((select document_opens::text from public.verification_access_monitor(24)), '31', 'document opens counted');
select zm_test.expect_equal((select private_views::text from public.verification_access_monitor(24)), '1', 'private views counted');
select zm_test.expect_equal((select count(*)::text from public.verification_access_monitor(-5)), '1', 'a silly window is clamped, not an error');
select zm_test.act_as_admin();
select zm_test.expect_equal((select (count(*) >= 2)::text from public.audit_logs where action = 'verification.access_monitor_viewed'), 'true', 'looking at the monitor is audited');

-- a recent escalation is not overdue
insert into public.verification_events (subject_type, subject_id, applicant_id, actor_id, event, from_status, to_status, visible_to_applicant, created_at)
select 'seller_application', id, user_id, assigned_to, 'escalated', 'under_review', 'under_review', false, now() from public.seller_applications;
select zm_test.act_as('00000000-0000-0000-0000-000000000051', 'aal2');
select zm_test.expect_equal((select (public.verification_workload()->>'escalations_overdue')), '0', 'a fresh escalation is within the deadline');

select zm_test.act_as_admin();
select zm_test.act_as('00000000-0000-0000-0000-0000000000a1', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.audit_logs), '0', 'an applicant sees no audit rows');
select zm_test.act_as_admin();
select 'Trust workload checks passed' as result;
rollback;
