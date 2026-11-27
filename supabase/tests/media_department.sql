-- Media Department (migrations 0033 and 0034): permissions, uploads, approvals, unauthorised access, removal.
-- Rolls itself back. Run against a local or staging database, never production:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/media_department.sql
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

\set T  '00000000-0000-0000-0000-0000000000d1'
\set M1 '00000000-0000-0000-0000-0000000000d2'
\set M2 '00000000-0000-0000-0000-0000000000d3'
\set SUP '00000000-0000-0000-0000-0000000000d4'
\set MOD '00000000-0000-0000-0000-0000000000d5'
\set BUY '00000000-0000-0000-0000-0000000000d6'

insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
  (:'T',   'admin@example.test',  '{"display_name":"Tech Admin"}', now()),
  (:'M1',  'media1@example.test', '{"display_name":"Media One"}', now()),
  (:'M2',  'media2@example.test', '{"display_name":"Media Two"}', now()),
  (:'SUP', 'sup@example.test',    '{"display_name":"Support Sue"}', now()),
  (:'MOD', 'mod@example.test',    '{"display_name":"Moderator Mo"}', now()),
  (:'BUY', 'buyer@example.test',  '{"display_name":"Buyer Bwalya"}', now());
insert into public.admin_roles (user_id, role) values
  (:'T', 'tech_admin'), (:'M1', 'media'), (:'M2', 'media'), (:'SUP', 'support'), (:'MOD', 'moderator');

-- ---------------------------------------------------------------- appointment
select zm_test.expect_equal((select count(*)::text from public.media_staff), '2', 'both Media staff got a title row');
select zm_test.act_as(:'T');
select public.media_set_title(:'M1', 'lead');
select zm_test.expect_error($$select public.media_set_title('00000000-0000-0000-0000-0000000000d4', 'lead')$$, 'a support person is not in Media');
select zm_test.act_as(:'SUP');
select zm_test.expect_error($$select public.media_set_title('00000000-0000-0000-0000-0000000000d2', 'designer')$$, 'support cannot set titles');
select zm_test.expect_error($$select public.grant_admin_role('00000000-0000-0000-0000-0000000000d4', 'media')$$, 'support cannot appoint staff');
select zm_test.act_as(:'M1');
select zm_test.expect_error($$select public.grant_admin_role('00000000-0000-0000-0000-0000000000d4', 'media')$$, 'media cannot appoint staff');
select zm_test.expect_error($$select public.grant_staff_permission('00000000-0000-0000-0000-0000000000d2', 'media.publish')$$, 'media cannot give itself publishing');

-- ---------------------------------------------------------------- permissions
select zm_test.act_as(:'M1');
select zm_test.expect_equal(public.staff_can('media.access')::text, 'true', 'media staff open the dashboard');
select zm_test.expect_equal(public.staff_can('media.publish')::text, 'false', 'media staff cannot publish by default');
select zm_test.expect_equal(public.staff_can('media.review')::text, 'false', 'media staff cannot review by default');
select zm_test.expect_equal(public.staff_can('media.delete')::text, 'false', 'media staff cannot delete by default');
-- two-factor is required
select zm_test.act_as(:'M1', 'aal1');
select zm_test.expect_equal(public.staff_can('media.access')::text, 'false', 'no access without two-factor');
select zm_test.expect_error($$select public.media_overview()$$, 'overview needs two-factor');
select zm_test.act_as(:'SUP');
select zm_test.expect_equal(public.staff_can('media.access')::text, 'false', 'support has no media access');
select zm_test.expect_error($$select public.media_overview()$$, 'support cannot open the dashboard');
select zm_test.act_as(:'BUY');
select zm_test.expect_equal(public.staff_can('media.access')::text, 'false', 'a buyer has nothing');
select zm_test.expect_error($$select public.media_overview()$$, 'a buyer cannot open the dashboard');

-- ---------------------------------------------------------------- existing powers are untouched
select zm_test.act_as(:'M1');
select zm_test.expect_equal(public.has_staff_role('support')::text, 'false', 'media is not support');
select zm_test.expect_equal(public.is_core_staff()::text, 'false', 'media is not core staff');
select zm_test.expect_equal(public.is_staff()::text, 'true', 'media is staff (directory, votes, birthdays)');
select zm_test.expect_error($$select public.verification_queue('sellers')$$, 'media cannot see seller applications');
select zm_test.expect_error($$select * from public.verification_documents$$, 'media cannot read verification documents');
select zm_test.expect_error($$select public.review_appeal(gen_random_uuid(), 'upheld', 'x')$$, 'media cannot decide appeals');
select zm_test.expect_error($$select public.revoke_admin_role('00000000-0000-0000-0000-0000000000d3', 'media')$$, 'media cannot remove staff');
select zm_test.expect_error($$select * from public.payments$$, 'media cannot read payments');
select zm_test.expect_equal((select count(*)::text from public.admin_approvals), '0', 'media sees no dual-control requests');
select zm_test.expect_error($$insert into public.admin_approvals (action) values ('x')$$, 'media cannot raise dual-control requests');
select zm_test.act_as(:'SUP');
select zm_test.expect_equal(public.is_core_staff()::text, 'true', 'support still core staff');
select zm_test.expect_equal(public.has_staff_role('support')::text, 'true', 'support still support');

-- ---------------------------------------------------------------- uploads
select zm_test.act_as_admin();
create temp table zm_ids (name text primary key, id uuid);
grant all on zm_ids to authenticated, service_role, anon;
select zm_test.obj(:'M1' || '/poster.png');
select zm_test.obj(:'M1' || '/clip.mp4', 'video/mp4', 20000000);
select zm_test.obj(:'M1' || '/huge.png', 'image/png', 20000000);
select zm_test.obj(:'M1' || '/script.exe', 'application/x-msdownload', 100);
select zm_test.obj(:'M1' || '/fake.png', 'application/pdf', 100);
select zm_test.obj(:'M2' || '/other.png');
select zm_test.act_as(:'M1');
insert into zm_ids select 'poster', public.media_asset_register('Launch poster', 'Main poster', 'poster', :'M1' || '/poster.png');
insert into zm_ids select 'clip', public.media_asset_register('Intro clip', null, 'video', :'M1' || '/clip.mp4');
select zm_test.expect_error($$select public.media_asset_register('Huge', null, 'poster', '00000000-0000-0000-0000-0000000000d2/huge.png')$$, 'oversized image refused');
select zm_test.expect_error($$select public.media_asset_register('Bad', null, 'poster', '00000000-0000-0000-0000-0000000000d2/script.exe')$$, 'executable refused');
select zm_test.expect_error($$select public.media_asset_register('Fake', null, 'poster', '00000000-0000-0000-0000-0000000000d2/fake.png')$$, 'name and type must agree');
select zm_test.expect_error($$select public.media_asset_register('Missing', null, 'poster', '00000000-0000-0000-0000-0000000000d2/none.png')$$, 'file must exist');
select zm_test.expect_error($$select public.media_asset_register('Theirs', null, 'poster', '00000000-0000-0000-0000-0000000000d3/other.png')$$, 'file must be in your own folder');
select zm_test.expect_error($$select public.media_asset_register('x', null, 'poster', '00000000-0000-0000-0000-0000000000d2/poster.png')$$, 'a file cannot be registered twice');
select zm_test.expect_error($$select public.media_asset_register('Cat', null, 'nonsense', '00000000-0000-0000-0000-0000000000d2/poster.png')$$, 'category must be known');
select zm_test.expect_equal((select scan_status from public.media_assets where title = 'Launch poster'), 'pending', 'new file waits for the scan');
-- other people cannot upload
select zm_test.act_as(:'SUP');
select zm_test.expect_error($$select public.media_asset_register('Sneaky', null, 'poster', '00000000-0000-0000-0000-0000000000d4/x.png')$$, 'support cannot upload');
select zm_test.expect_error($$insert into storage.objects (bucket_id, name, metadata) values ('media-library', '00000000-0000-0000-0000-0000000000d4/x.png', '{}')$$, 'support cannot write to the bucket');
-- only the scanner can mark a file clean
select zm_test.act_as(:'M1');
select zm_test.expect_error(format($$select public.media_record_scan(%L, 'clean')$$, (select id from zm_ids where name = 'poster')), 'staff cannot mark a file clean');
select zm_test.act_as_service();
select public.media_record_scan((select id from zm_ids where name = 'poster'), 'clean');
select zm_test.act_as(:'M1');
select zm_test.expect_equal((select scan_status from public.media_assets where title = 'Launch poster'), 'clean', 'scanner verdict is kept');

-- ---------------------------------------------------------------- library edits and versions
select public.media_asset_update((select id from zm_ids where name = 'poster'), 'Launch poster v2', 'Updated', 'banner', 'new title');
select zm_test.expect_equal((select version::text from public.media_assets where title = 'Launch poster v2'), '2', 'edit bumps the version');
select zm_test.expect_equal((select count(*)::text from public.media_asset_versions where title = 'Launch poster'), '1', 'old title kept in history');
select zm_test.act_as(:'SUP');
select zm_test.expect_equal((select count(*)::text from public.media_assets), '0', 'support sees no media files');
select zm_test.expect_error(format($$select public.media_asset_update(%L, 'x', null, 'poster')$$, (select id from zm_ids where name = 'poster')), 'support cannot edit files');

-- ---------------------------------------------------------------- content workflow
select zm_test.act_as(:'M1');
insert into zm_ids select 'c1', public.media_content_save(null, 'announcement', 'New feature', 'We launched compare.', 'in_app', null, array[(select id from zm_ids where name = 'poster')]);
select zm_test.expect_equal((select status from public.media_content where title = 'New feature'), 'draft', 'starts as a draft');
select zm_test.expect_error(format($$select public.media_content_publish(%L)$$, (select id from zm_ids where name = 'c1')), 'a draft cannot be published');
select zm_test.expect_error(format($$select public.media_content_review(%L, 'approve')$$, (select id from zm_ids where name = 'c1')), 'a draft cannot be reviewed');
select public.media_content_submit((select id from zm_ids where name = 'c1'));
select zm_test.expect_error(format($$select public.media_content_save(%L, 'announcement', 'Edit', 'x', 'in_app', null)$$, (select id from zm_ids where name = 'c1')), 'submitted content is locked');
-- the creator cannot approve, and does not hold the permission anyway
select zm_test.expect_error(format($$select public.media_content_review(%L, 'approve')$$, (select id from zm_ids where name = 'c1')), 'media staff cannot review');
-- a colleague with media.review still cannot approve their own work
select zm_test.act_as(:'T');
select public.grant_staff_permission(:'M1', 'media.review', 'test');
select zm_test.act_as(:'M1');
select zm_test.expect_error_like(format($$select public.media_content_review(%L, 'approve')$$, (select id from zm_ids where name = 'c1')), '%your own work%', 'no self approval');
-- the administrator reviews
select zm_test.act_as(:'T');
select zm_test.expect_error(format($$select public.media_content_review(%L, 'reject')$$, (select id from zm_ids where name = 'c1')), 'a reason is needed to reject');
select public.media_content_review((select id from zm_ids where name = 'c1'), 'changes', 'Shorten the headline');
select zm_test.expect_equal((select status from public.media_content where title = 'New feature'), 'changes_requested', 'changes requested');
select zm_test.expect_equal((select review_note from public.media_content where title = 'New feature'), 'Shorten the headline', 'note kept');
select zm_test.act_as(:'M1');
select public.media_content_save((select id from zm_ids where name = 'c1'), 'announcement', 'New feature', 'We launched compare and more.', 'in_app', null, array[(select id from zm_ids where name = 'poster')]);
select zm_test.expect_equal((select version::text from public.media_content where title = 'New feature'), '2', 'edit keeps a version');
select zm_test.expect_equal((select count(*)::text from public.media_content_versions), '1', 'old text kept');
select public.media_content_submit((select id from zm_ids where name = 'c1'));
select zm_test.act_as(:'T');
select public.media_content_review((select id from zm_ids where name = 'c1'), 'approve');
select zm_test.expect_equal((select status from public.media_content where title = 'New feature'), 'approved', 'approved');
select zm_test.expect_equal((select (reviewed_by = :'T')::text from public.media_content where title = 'New feature'), 'true', 'reviewer recorded');
-- publishing: the creator cannot, even though the content is approved
select zm_test.act_as(:'M1');
select zm_test.expect_error(format($$select public.media_content_publish(%L)$$, (select id from zm_ids where name = 'c1')), 'creator has no publishing authority');
-- a file that has not passed the scan blocks publishing
select zm_test.act_as(:'T');
select zm_test.act_as_admin();
update public.media_assets set scan_status = 'pending' where title = 'Launch poster v2';
select zm_test.act_as(:'T');
select zm_test.expect_error_like(format($$select public.media_content_publish(%L)$$, (select id from zm_ids where name = 'c1')), '%safety scan%', 'unscanned file blocks publishing');
select zm_test.act_as_admin();
update public.media_assets set scan_status = 'clean' where title = 'Launch poster v2';
select zm_test.act_as(:'T');
select public.media_content_publish((select id from zm_ids where name = 'c1'));
select zm_test.expect_equal((select status from public.media_content where title = 'New feature'), 'published', 'published');
select zm_test.expect_equal((select (published_by = :'T' and published_at is not null)::text from public.media_content where title = 'New feature'), 'true', 'publisher and date recorded');

-- publishing authority can be given to one Media person
select public.grant_staff_permission(:'M2', 'media.publish', 'trusted');
select zm_test.act_as(:'M2');
select zm_test.expect_equal(public.staff_can('media.publish')::text, 'true', 'granted authority works');
select zm_test.expect_equal(public.staff_can('media.review')::text, 'false', 'only what was granted');
select zm_test.act_as(:'T');
select public.revoke_staff_permission(:'M2', 'media.edit', 'test');
select zm_test.act_as(:'M2');
select zm_test.expect_equal(public.staff_can('media.edit')::text, 'false', 'a default permission can be taken away');
select zm_test.act_as(:'T');
select public.reset_staff_permission(:'M2', 'media.edit');
select zm_test.act_as(:'M2');
select zm_test.expect_equal(public.staff_can('media.edit')::text, 'true', 'reset restores the role default');
select zm_test.expect_error($$select public.grant_staff_permission('00000000-0000-0000-0000-0000000000d3', 'media.review')$$, 'media cannot grant permissions');

-- scheduled publishing
select zm_test.act_as(:'M2');
insert into zm_ids select 'c2', public.media_content_save(null, 'announcement', 'Maintenance', 'Short downtime tonight.', 'in_app', null);
select public.media_content_submit((select id from zm_ids where name = 'c2'));
select zm_test.act_as(:'T');
select public.media_content_review((select id from zm_ids where name = 'c2'), 'approve');
select public.media_content_publish((select id from zm_ids where name = 'c2'), now() + interval '2 days');
select zm_test.expect_equal((select status from public.media_content where title = 'Maintenance'), 'scheduled', 'future date schedules');

-- ---------------------------------------------------------------- published content cannot be deleted or silently changed
select zm_test.act_as(:'M1');
select zm_test.expect_error($$delete from public.media_content$$, 'no direct deletes');
select zm_test.expect_error($$update public.media_content set status = 'draft'$$, 'no direct updates');
select zm_test.expect_error($$insert into public.media_content (kind, title, created_by) values ('poster', 'Hack', '00000000-0000-0000-0000-0000000000d2')$$, 'no direct inserts');
select zm_test.expect_error(format($$select public.media_content_withdraw(%L, 'oops')$$, (select id from zm_ids where name = 'c1')), 'creator cannot withdraw');
select zm_test.expect_error(format($$select public.media_content_save(%L, 'announcement', 'Edit', 'x', 'in_app', null)$$, (select id from zm_ids where name = 'c1')), 'published content is locked');
select zm_test.expect_error(format($$select public.media_asset_archive(%L, true)$$, (select id from zm_ids where name = 'poster')), 'a file in published content cannot be archived');
select zm_test.act_as(:'T');
select zm_test.expect_error(format($$select public.media_asset_delete(%L, 'DELETE')$$, (select id from zm_ids where name = 'poster')), 'cannot delete a file in use');
select zm_test.expect_error(format($$select public.media_content_withdraw(%L, '')$$, (select id from zm_ids where name = 'c1')), 'withdrawal needs a reason');

-- ---------------------------------------------------------------- public access
select zm_test.act_as_guest();
select zm_test.expect_equal((select count(*)::text from public.media_public_announcements()), '1', 'guests see only the published announcement');
select zm_test.expect_equal((select title from public.media_public_announcements() limit 1), 'New feature', 'not the scheduled one');
select zm_test.expect_error($$select * from public.media_content$$, 'guests cannot read the table');
select zm_test.expect_equal((select count(*)::text from storage.objects where bucket_id = 'media-library'), '1', 'guests can open only the published file');
select zm_test.act_as(:'BUY');
select zm_test.expect_equal((select count(*)::text from public.media_content), '0', 'a buyer sees no content rows');
select zm_test.expect_equal((select count(*)::text from storage.objects where bucket_id = 'media-library'), '1', 'a buyer sees only the published file');
select zm_test.act_as(:'M1');
select zm_test.expect_equal(((select count(*) from storage.objects where bucket_id = 'media-library') >= 4)::text, 'true', 'media staff see unpublished files');

-- ---------------------------------------------------------------- withdraw, archive, confirm, delete
select zm_test.act_as(:'T');
select public.media_content_withdraw((select id from zm_ids where name = 'c1'), 'Wrong date');
select zm_test.expect_equal((select status from public.media_content where title = 'New feature'), 'withdrawn', 'withdrawn');
select zm_test.act_as(:'M1');
select zm_test.expect_error(format($$select public.media_asset_delete(%L, 'DELETE')$$, (select id from zm_ids where name = 'clip')), 'media staff cannot delete');
select public.media_asset_archive((select id from zm_ids where name = 'clip'), true);
select zm_test.expect_equal((select status from public.media_assets where title = 'Intro clip'), 'archived', 'archived');
select public.media_asset_archive((select id from zm_ids where name = 'clip'), false);
select public.media_asset_archive((select id from zm_ids where name = 'clip'), true);
select zm_test.act_as(:'T');
select zm_test.expect_error(format($$select public.media_asset_delete(%L, 'yes')$$, (select id from zm_ids where name = 'clip')), 'confirmation word is required');
select zm_test.expect_error(format($$select public.media_asset_delete(%L, 'DELETE')$$, (select id from zm_ids where name = 'poster')), 'poster is still active');
select zm_test.expect_equal(public.media_asset_delete((select id from zm_ids where name = 'clip'), 'DELETE'), (select :'M1' || '/clip.mp4'), 'path returned for storage clean-up');
select zm_test.expect_equal((select status from public.media_assets where title = 'Intro clip'), 'deleted', 'record kept, marked deleted');
-- the stored file can now be removed, and only that file
delete from storage.objects where bucket_id = 'media-library' and name = :'M1' || '/clip.mp4';
select zm_test.expect_equal((select count(*)::text from storage.objects where name = :'M1' || '/clip.mp4'), '0', 'deleted file removed from storage');
delete from storage.objects where bucket_id = 'media-library' and name = :'M1' || '/poster.png';
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from storage.objects where name = :'M1' || '/poster.png'), '1', 'a file that is not marked deleted cannot be removed');
select zm_test.act_as(:'M1');
delete from storage.objects where bucket_id = 'media-library' and name = :'M1' || '/poster.png';
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from storage.objects where name = :'M1' || '/poster.png'), '1', 'media staff cannot remove files either');

-- ---------------------------------------------------------------- requests between departments
select zm_test.act_as(:'SUP');
insert into zm_ids select 'r1', public.media_request_create('graphic', 'Banner for verification help', 'We need a graphic that explains seller verification.', 'high', current_date + 7);
select zm_test.expect_equal((select count(*)::text from public.media_requests), '1', 'support sees its own request');
select zm_test.expect_error(format($$select public.media_request_update(%L, 'done', null, 'finished')$$, (select id from zm_ids where name = 'r1')), 'support cannot close the request');
select zm_test.act_as(:'MOD');
select zm_test.expect_equal((select count(*)::text from public.media_requests), '0', 'another department cannot see it');
select zm_test.act_as(:'BUY');
select zm_test.expect_error($$select public.media_request_create('graphic', 'Hello', 'I want a poster please', 'low')$$, 'a buyer cannot ask');
select zm_test.act_as(:'M2');
select zm_test.expect_equal((select count(*)::text from public.media_requests), '1', 'media sees the request');
select zm_test.expect_error(format($$select public.media_request_update(%L, 'in_progress', %L)$$, (select id from zm_ids where name = 'r1'), :'SUP'), 'only Media staff can be assigned');
select public.media_request_update((select id from zm_ids where name = 'r1'), 'in_progress', :'M2');
select zm_test.expect_error(format($$select public.media_request_update(%L, 'done')$$, (select id from zm_ids where name = 'r1')), 'closing needs a note');
select public.media_request_update((select id from zm_ids where name = 'r1'), 'done', null, 'Banner is in the library');

-- ---------------------------------------------------------------- performance, calendar, overview
select zm_test.act_as(:'M1');
select zm_test.expect_error(format($$select public.media_record_performance(%L, 'in_app', 100, 10, 5)$$, (select id from zm_ids where name = 'c2')), 'only published content has numbers');
select zm_test.act_as(:'T');
select zm_test.expect_equal((select (public.media_overview() ->> 'scheduled')), '1', 'overview counts scheduled');
select zm_test.expect_equal((select count(*)::text from public.media_calendar(current_date, current_date + 5)), '1', 'calendar shows the scheduled item');
select zm_test.expect_error($$select * from public.media_calendar(current_date, current_date + 800)$$, 'calendar range is limited');

-- ---------------------------------------------------------------- audit
select zm_test.act_as(:'T');
select zm_test.expect_equal(((select count(*) from public.media_activity(300)) >= 20)::text, 'true', 'media actions are in the activity record');
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action = 'media.asset.uploaded'), '2', 'every upload is audited');
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action = 'media.content.published'), '1', 'publishing is audited');
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action = 'staff_permission.granted'), '2', 'permission grants are audited');
select zm_test.act_as(:'M1');
select zm_test.expect_error($$select * from public.media_activity()$$, 'media staff cannot read the activity record by default');
select zm_test.expect_equal((select count(*)::text from public.audit_logs), '0', 'media staff see no audit log rows');
select zm_test.expect_equal((select count(*)::text from public.media_content_events where event = 'published'), '1', 'item history shows publication');

-- ---------------------------------------------------------------- removal takes access away at once
select zm_test.act_as(:'T');
select public.revoke_admin_role(:'M2', 'media');
select zm_test.act_as(:'M2');
select zm_test.expect_equal(public.staff_can('media.access')::text, 'false', 'removed staff lose access immediately');
select zm_test.expect_equal(public.staff_can('media.publish')::text, 'false', 'and their granted authority');
select zm_test.expect_error($$select public.media_overview()$$, 'dashboard refuses a removed person');
select zm_test.expect_equal((select count(*)::text from public.media_content), '0', 'removed staff read nothing');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.media_staff where user_id = :'M2'), '0', 'department title removed');
select zm_test.expect_equal((select count(*)::text from public.staff_permission_overrides where user_id = :'M2'), '0', 'media overrides removed');
-- a person who keeps another role does not keep Media grants
select zm_test.act_as(:'T');
select public.grant_admin_role(:'MOD', 'media');
select public.grant_staff_permission(:'MOD', 'media.publish');
select public.revoke_admin_role(:'MOD', 'media');
select zm_test.act_as(:'MOD');
select zm_test.expect_equal(public.staff_can('media.publish')::text, 'false', 'a leftover grant does not survive removal');
select zm_test.expect_equal(public.has_staff_role('moderator')::text, 'true', 'the other role is untouched');

select 'Media department checks passed' as result;
rollback;
