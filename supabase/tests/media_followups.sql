-- Media follow-ups (migration 0035): notifications, real counts, pausing department access.
-- Rolls itself back. Run against a local or staging database, never production:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/media_followups.sql
begin;

create schema zm_test;
grant usage on schema zm_test to anon, authenticated, service_role;

create function zm_test.act_as(p_user uuid, p_aal text default 'aal2') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  execute 'set local role authenticated';
end $$;
create function zm_test.act_as_guest() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
end $$;
create function zm_test.act_as_service() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  execute 'set local role service_role';
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
create function zm_test.expect_error_like(p_sql text, p_like text, p_what text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception 'Expected an error but the statement worked: %', p_what;
exception when others then
  if sqlerrm like 'Expected an error but%' then raise; end if;
  if sqlerrm not like p_like then raise exception 'Wrong error for %: %', p_what, sqlerrm; end if;
end $$;
create function zm_test.expect_equal(p_actual text, p_expected text, p_what text) returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'Wrong result for %: expected %, got %', p_what, coalesce(p_expected, 'null'), coalesce(p_actual, 'null');
  end if;
end $$;
-- A file in the media bucket, as the storage service would leave it.
create function zm_test.obj(p_path text, p_mime text default 'image/png', p_size bigint default 5000) returns void
language plpgsql security definer as $$
begin
  insert into storage.objects (bucket_id, name, metadata) values ('media-library', p_path, jsonb_build_object('mimetype', p_mime, 'size', p_size));
end $$;
grant execute on all functions in schema zm_test to anon, authenticated, service_role;

\set T  '00000000-0000-0000-0000-0000000000e1'
\set M1 '00000000-0000-0000-0000-0000000000e2'
\set SUP '00000000-0000-0000-0000-0000000000e4'
\set MOD '00000000-0000-0000-0000-0000000000e5'
\set BUY '00000000-0000-0000-0000-0000000000e6'

insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
  (:'T',   'a@example.test', '{"display_name":"Tech Admin"}', now()),
  (:'M1',  'm@example.test', '{"display_name":"Media One"}', now()),
  (:'SUP', 's@example.test', '{"display_name":"Support Sue"}', now()),
  (:'MOD', 'o@example.test', '{"display_name":"Moderator Mo"}', now()),
  (:'BUY', 'b@example.test', '{"display_name":"Buyer Bwalya"}', now());
insert into public.admin_roles (user_id, role) values (:'T', 'tech_admin'), (:'M1', 'media'), (:'SUP', 'support'), (:'MOD', 'moderator');

create temp table zm_ids (name text, id uuid);
grant all on zm_ids to authenticated, anon, service_role;

-- ---------------------------------------------------------------- notifications
select zm_test.act_as(:'M1');
insert into zm_ids select 'c1', public.media_content_save(null, 'announcement', 'Compare is here', 'You can now compare items.', 'in_app', null);
select public.media_content_submit((select id from zm_ids where name = 'c1'));
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.notifications where user_id = :'T' and type = 'media.review_needed'), '1', 'the reviewer is told');
select zm_test.expect_equal((select count(*)::text from public.notifications where user_id = :'M1' and type = 'media.review_needed'), '0', 'the author is not told about their own submission');
select zm_test.expect_equal((select count(*)::text from public.notifications where user_id = :'SUP'), '0', 'other departments are not told');
select zm_test.expect_equal((select link from public.notifications where user_id = :'T' limit 1), '/media/item/' || (select id from zm_ids where name = 'c1'), 'it links to the item');

select zm_test.act_as(:'T');
select public.media_content_review((select id from zm_ids where name = 'c1'), 'changes', 'Shorten it');
select zm_test.act_as_admin();
select zm_test.expect_equal((select type from public.notifications where user_id = :'M1' order by created_at desc limit 1), 'media.changes_requested', 'the author is told about changes');
select zm_test.expect_equal((select (body like '%Shorten it%')::text from public.notifications where user_id = :'M1' and type = 'media.changes_requested'), 'true', 'the reviewer note is included');

select zm_test.act_as(:'M1');
select public.media_content_submit((select id from zm_ids where name = 'c1'));
select zm_test.act_as(:'T');
select public.media_content_review((select id from zm_ids where name = 'c1'), 'approve');
select public.media_content_publish((select id from zm_ids where name = 'c1'));
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.notifications where user_id = :'M1' and type = 'media.approved'), '1', 'author told it was approved');
select zm_test.expect_equal((select count(*)::text from public.notifications where user_id = :'M1' and type = 'media.published'), '1', 'author told it was published');
select zm_test.expect_equal((select count(*)::text from public.notifications where user_id = :'T' and type in ('media.approved', 'media.published')), '0', 'the person who acted is not told');

-- requests
select zm_test.act_as(:'SUP');
insert into zm_ids select 'r1', public.media_request_create('graphic', 'Verification poster', 'We need a poster about verification.', 'normal', null);
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.notifications where type = 'media.request_new' and user_id in (:'M1', :'T')), '2', 'Media and the administrator are told of a new request');
select zm_test.expect_equal((select count(*)::text from public.notifications where type = 'media.request_new' and user_id = :'SUP'), '0', 'the requester is not told of their own request');
select zm_test.act_as(:'M1');
select public.media_request_update((select id from zm_ids where name = 'r1'), 'done', null, 'Poster is in the library');
select zm_test.act_as_admin();
select zm_test.expect_equal((select type from public.notifications where user_id = :'SUP' order by created_at desc limit 1), 'media.request_done', 'the requester is told it is done');

-- ---------------------------------------------------------------- real counts
select zm_test.act_as(:'BUY');
select public.media_track((select id from zm_ids where name = 'c1'), 'view');
select public.media_track((select id from zm_ids where name = 'c1'), 'view');
select public.media_track((select id from zm_ids where name = 'c1'), 'click');
select zm_test.expect_error($$select public.media_track(gen_random_uuid(), 'share')$$, 'unknown events are refused');
select public.media_track(gen_random_uuid(), 'view'); -- unknown content is ignored, not an error
select zm_test.act_as_guest();
select zm_test.expect_error(format($$select public.media_track(%L, 'view')$$, (select id from zm_ids where name = 'c1')), 'guests cannot count');
select zm_test.act_as_admin();
select zm_test.expect_equal((select sum(views)::text from public.media_tracking), '2', 'signed-in views counted, guests not');
select zm_test.expect_equal((select sum(clicks)::text from public.media_tracking), '1', 'taps counted');
select zm_test.act_as(:'BUY');
select zm_test.expect_error($$select * from public.media_tracking$$, 'nobody reads the raw counts directly');
select zm_test.act_as(:'M1');
select public.media_record_performance((select id from zm_ids where name = 'c1'), 'in_app', 10, 1, 3);
select zm_test.expect_equal((select impressions::text from public.media_performance_summary()), '12', 'typed and counted views are added');
select zm_test.expect_equal((select clicks::text from public.media_performance_summary()), '2', 'clicks added');
select zm_test.expect_equal((select engagements::text from public.media_performance_summary()), '3', 'engagements as typed');
-- a draft is never counted
select zm_test.act_as(:'M1');
insert into zm_ids select 'c2', public.media_content_save(null, 'announcement', 'Draft only', 'x', 'in_app', null);
select zm_test.act_as(:'BUY');
select public.media_track((select id from zm_ids where name = 'c2'), 'view');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.media_tracking where content_id = (select id from zm_ids where name = 'c2')), '0', 'unpublished content is not counted');

-- ---------------------------------------------------------------- pausing department access
select zm_test.act_as(:'SUP');
select zm_test.expect_equal(public.has_staff_role('support')::text, 'true', 'support works by default');
select zm_test.act_as(:'T');
select zm_test.expect_equal((select count(*)::text from public.staff_permissions where key in ('support.access', 'moderation.access', 'finance.access')), '3', 'catalogue has the access keys');
select public.revoke_staff_permission(:'SUP', 'support.access', 'on leave');
select zm_test.act_as(:'SUP');
select zm_test.expect_equal(public.has_staff_role('support')::text, 'false', 'a paused person loses that role at once');
select zm_test.expect_equal(public.is_staff()::text, 'true', 'they stay in the staff directory');
select zm_test.act_as(:'MOD');
select zm_test.expect_equal(public.has_staff_role('moderator')::text, 'true', 'other people are unaffected');
select zm_test.act_as(:'T');
select zm_test.expect_equal(public.has_staff_role('tech_admin')::text, 'true', 'administrators are unaffected');
select zm_test.expect_error_like($$select public.revoke_staff_permission('00000000-0000-0000-0000-0000000000e1', 'support.access', 'x')$$, '%own access%', 'no pausing yourself');
select zm_test.expect_error_like(format($$select public.revoke_staff_permission(%L, 'support.access', 'x')$$, :'MOD'), '%does not have this role%', 'only a role someone has can be paused');
select zm_test.expect_error_like(format($$select public.grant_staff_permission(%L, 'support.access', 'x')$$, :'M1'), '%appointing the role%', 'access cannot be granted this way');
select zm_test.act_as(:'M1');
select zm_test.expect_error(format($$select public.revoke_staff_permission(%L, 'support.access', 'x')$$, :'SUP'), 'media staff cannot pause anyone');
select zm_test.act_as(:'T');
select public.reset_staff_permission(:'SUP', 'support.access');
select zm_test.act_as(:'SUP');
select zm_test.expect_equal(public.has_staff_role('support')::text, 'true', 'restoring brings access back');
-- removing the role clears a pause so a later re-appointment starts clean
select zm_test.act_as(:'T');
select public.revoke_staff_permission(:'SUP', 'support.access', 'again');
select zm_test.act_as_admin();
delete from public.admin_roles where user_id = :'SUP' and role = 'support';
select zm_test.expect_equal((select count(*)::text from public.staff_permission_overrides where user_id = :'SUP'), '0', 'pause removed with the role');
insert into public.admin_roles (user_id, role) values (:'SUP', 'support');
select zm_test.act_as(:'SUP');
select zm_test.expect_equal(public.has_staff_role('support')::text, 'true', 're-appointed person starts clean');
-- the pause and restore are in the audit record
select zm_test.act_as_admin();
select zm_test.expect_equal((select (count(*) >= 2)::text from public.audit_logs where action in ('staff_permission.revoked', 'staff_permission.reset')), 'true', 'changes are audited');

select 'Media follow-up checks passed' as result;
rollback;
