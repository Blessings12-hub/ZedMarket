-- Staff birthdays (migration 0017): privacy, validation, the daily job (date, organisation timezone, once per event,
-- several birthdays on one day, 29 February), visibility, deactivated staff, the calendar, the message board
-- (sender identity, notifications, window, caps, permanent history), reporting and moderation, access logs,
-- notification controls, and function and table permissions.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/staff_birthdays.sql

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

-- Ten staff. 1 tech admin; 2 and 9 moderators; 3, 4, 7, 8, 10 support; 5 and 6 finance.
insert into auth.users (id, email, raw_user_meta_data)
select zm_test.s(n), 'staff' || n || '@example.test', json_build_object('display_name', 'Staff ' || n)::jsonb
  from generate_series(1, 10) n;
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000b', 'buyer@example.test', '{"display_name":"Buyer Bwalya"}');
insert into public.admin_roles (user_id, role) values
  (zm_test.s(1), 'tech_admin'), (zm_test.s(2), 'moderator'), (zm_test.s(3), 'support'), (zm_test.s(4), 'support'),
  (zm_test.s(5), 'finance'), (zm_test.s(6), 'finance'), (zm_test.s(7), 'support'), (zm_test.s(8), 'support'),
  (zm_test.s(9), 'moderator'), (zm_test.s(10), 'support');
update public.profiles set avatar_path = 'avatars/' || id || '/me.jpg' where id = zm_test.s(3);

update public.platform_settings set value = '1000' where key in ('rate_limit.birthday_profile.max', 'rate_limit.birthday_message.max', 'rate_limit.birthday_report.max');

-- Staff n saves a birthday. The saved date is back-dated so the job treats it as long standing.
create function zm_test.bday(p_n integer, p_month integer, p_day integer, p_visibility text default 'staff') returns void
language plpgsql as $$
begin
  perform zm_test.act_as(zm_test.s(p_n), 'aal2');
  perform public.set_my_birthday(p_month, p_day, p_visibility, true, 'Team member');
  perform zm_test.act_as_admin();
  update public.staff_birthday_profiles set date_changed_at = '2000-01-01' where user_id = zm_test.s(p_n);
end $$;

create function zm_test.run_job(p_at text) returns integer
language plpgsql as $$
declare n integer;
begin
  perform zm_test.act_as_admin();
  select public.run_staff_birthdays(p_at::timestamptz) into n;
  return n;
end $$;

create function zm_test.notes(p_user uuid, p_type text) returns bigint language sql as $$
  select count(*) from public.notifications where user_id = p_user and type = p_type
$$;
create function zm_test.total(p_type text) returns bigint language sql as $$
  select count(*) from public.notifications where type = p_type
$$;
create function zm_test.active_staff() returns bigint language sql as $$
  select count(distinct r.user_id) from public.admin_roles r join public.profiles p on p.id = r.user_id and p.account_state = 'active'
$$;

-- 1. Privacy by design -------------------------------------------------------------------------------------------
select zm_test.expect_equal((select count(*)::text from information_schema.columns where table_schema = 'public'
   and table_name like 'staff_birthday%' and (column_name ilike '%year%' or column_name ilike '%dob%' or column_name ilike '%date_of_birth%' or column_name ilike '%birthdate%')), '0', 'no year or full date of birth is stored anywhere');
select zm_test.expect_equal((select bool_and(c.relrowsecurity)::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname like 'staff_birthday%' and c.relkind = 'r'), 'true', 'row level security is on for every birthday table');
select zm_test.expect_equal((select count(*)::text from information_schema.role_table_grants where table_schema = 'public'
   and table_name like 'staff_birthday%' and grantee in ('anon', 'authenticated')), '0', 'no table grants for app users');

-- 2. Entering a birthday: validation and access ---------------------------------------------------------------------
select zm_test.act_as(zm_test.s(3), 'aal2');
select zm_test.expect_equal((select has_birthday::text from public.my_birthday_profile()), 'false', 'nothing saved yet');
select zm_test.expect_error($$select public.set_my_birthday(2, 30, 'staff', true, null)$$, '30 February');
select zm_test.expect_error($$select public.set_my_birthday(4, 31, 'staff', true, null)$$, '31 April');
select zm_test.expect_error($$select public.set_my_birthday(13, 1, 'staff', true, null)$$, 'month 13');
select zm_test.expect_error($$select public.set_my_birthday(0, 10, 'staff', true, null)$$, 'month 0');
select zm_test.expect_error($$select public.set_my_birthday(5, 0, 'staff', true, null)$$, 'day 0');
select zm_test.expect_error($$select public.set_my_birthday(null, 5, 'staff', true, null)$$, 'missing month');
select zm_test.expect_error($$select public.set_my_birthday(5, 5, 'everyone', true, null)$$, 'unknown visibility');
select zm_test.expect_error($$select public.set_my_birthday(5, 5, 'staff', true, 'x')$$, 'position too short');
select public.set_my_birthday(2, 29, 'staff', true, 'Support lead');
select zm_test.expect_equal((select birth_month || '-' || birth_day || '-' || visibility from public.my_birthday_profile()), '2-29-staff', '29 February is a valid birthday');
select zm_test.act_as('00000000-0000-0000-0000-00000000000b', 'aal2');
select zm_test.expect_error($$select public.set_my_birthday(5, 5, 'staff', true, null)$$, 'non-staff cannot enter a birthday');
select zm_test.expect_error($$select * from public.staff_birthdays_today()$$, 'non-staff cannot read the calendar');
select zm_test.act_as(zm_test.s(3), 'aal1');
select zm_test.expect_error($$select public.set_my_birthday(5, 5, 'staff', true, null)$$, 'staff without two-factor cannot enter a birthday');
select zm_test.expect_error($$select * from public.staff_birthdays_month(5)$$, 'staff without two-factor cannot read the calendar');
select zm_test.act_as_guest();
select zm_test.expect_error($$select * from public.staff_birthdays_upcoming()$$, 'guests cannot read the calendar');
select zm_test.expect_error($$select * from public.my_birthday_profile()$$, 'guests have no profile');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action = 'staff_birthday.updated' and metadata::text ~ '[0-9]{1,2}-[0-9]{1,2}'), '0', 'the audit log never holds the date');
-- 29 February leaves a clean slate for the scenarios below
select zm_test.act_as(zm_test.s(3), 'aal2');
select public.clear_my_birthday();
select zm_test.expect_equal((select has_birthday::text from public.my_birthday_profile()), 'false', 'a birthday can be removed');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action = 'staff_birthday.removed'), '1', 'removal is audited');
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action = 'staff_birthday.updated'), '1', 'the edit is audited');

-- 3. The job runs on the right date, in the organisation timezone (Africa/Lusaka, UTC+2) -----------------------------
select zm_test.expect_equal(public.org_timezone(), 'Africa/Lusaka', 'default organisation timezone');
select zm_test.bday(3, 3, 5);   -- 5 March
select zm_test.expect_equal(zm_test.run_job('2026-03-04T21:30:00Z')::text, '0', '23:30 on 4 March in Lusaka: not yet');
select zm_test.expect_equal(zm_test.total('birthday.greeting')::text, '0', 'nothing sent early');
select zm_test.expect_equal(zm_test.run_job('2026-03-04T22:30:00Z')::text, '1', '00:30 on 5 March in Lusaka: the birthday');
select zm_test.expect_equal(zm_test.notes(zm_test.s(3), 'birthday.greeting')::text, '1', 'the birthday person gets a greeting');
select zm_test.expect_equal(zm_test.total('birthday.today')::text, (zm_test.active_staff() - 1)::text, 'every other active staff member is told');
select zm_test.expect_equal(zm_test.notes(zm_test.s(3), 'birthday.today')::text, '0', 'the birthday person gets no "colleague" notice');
select zm_test.expect_equal(zm_test.notes('00000000-0000-0000-0000-00000000000b', 'birthday.today')::text, '0', 'non-staff are never told');
select zm_test.expect_equal((select title from public.notifications where user_id = zm_test.s(1) and type = 'birthday.today'), 'Staff 3 has a birthday today', 'the notice names the person');
select zm_test.expect_equal((select title from public.notifications where user_id = zm_test.s(3) and type = 'birthday.greeting'), 'Happy birthday, Staff 3!', 'the greeting names the person');
select zm_test.expect_equal((select (link like '/admin/birthdays/%')::text from public.notifications where user_id = zm_test.s(1) and type = 'birthday.today'), 'true', 'the notice links to the board');
select zm_test.expect_equal((select category from public.notifications where user_id = zm_test.s(1) and type = 'birthday.today'), 'staff', 'it uses the staff category');

-- 4. Once per birthday event: re-runs, the same local day, and overlapping runs send nothing again -------------------
select zm_test.expect_equal(zm_test.run_job('2026-03-04T22:30:00Z')::text, '1', 'the same moment again still reports the birthday');
select zm_test.expect_equal(zm_test.run_job('2026-03-05T10:00:00Z')::text, '1', 'later the same local day');
select zm_test.expect_equal(zm_test.total('birthday.greeting')::text, '1', 'still one greeting');
select zm_test.expect_equal(zm_test.total('birthday.today')::text, (zm_test.active_staff() - 1)::text, 'still one notice each');
select zm_test.expect_equal((select count(*)::text from public.staff_birthday_events), '1', 'one event');
select zm_test.expect_equal((select count(*)::text from public.staff_birthday_notification_logs), (zm_test.active_staff())::text, 'one log row per notice due');
select zm_test.expect_equal(zm_test.run_job('2026-03-05T22:30:00Z')::text, '0', '00:30 on 6 March: the day is over');
select zm_test.expect_error($$insert into public.staff_birthday_events (user_id, event_date) values (zm_test.s(3), '2026-03-05')$$, 'a duplicate event cannot be created');
select zm_test.expect_error($$insert into public.staff_birthday_notification_logs (event_id, kind, recipient_id) select event_id, kind, recipient_id from public.staff_birthday_notification_logs limit 1$$, 'a duplicate log row cannot be created');
-- a muted category is still logged, so it is not retried and sent later
select zm_test.bday(4, 3, 6);
select zm_test.act_as(zm_test.s(1), 'aal1');
select public.set_notification_preference('staff', false, false, false, false);
select zm_test.run_job('2026-03-05T22:30:00Z');
select zm_test.expect_equal(zm_test.notes(zm_test.s(1), 'birthday.today')::text, '1', 'a muted person gets no new in-app notice (only the earlier one)');
select zm_test.act_as(zm_test.s(1), 'aal1');
select public.set_notification_preference('staff', true, true, false, false);
select zm_test.run_job('2026-03-05T23:30:00Z');
select zm_test.expect_equal(zm_test.notes(zm_test.s(1), 'birthday.today')::text, '1', 'switching back on does not resend the missed notice');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.staff_birthday_notification_logs l join public.staff_birthday_events e on e.id = l.event_id where e.user_id = zm_test.s(4) and l.recipient_id = zm_test.s(1) and l.notification_id is null), '1', 'the muted notice is logged as not sent');

-- 5. Other timezones, and a bad timezone name ------------------------------------------------------------------------
select zm_test.bday(5, 6, 10);   -- 10 June
update public.platform_settings set value = '"Pacific/Auckland"' where key = 'org.timezone';
select zm_test.expect_equal(public.org_timezone(), 'Pacific/Auckland', 'a configured timezone is used');
select zm_test.expect_equal(zm_test.run_job('2026-06-09T12:30:00Z')::text, '1', '00:30 on 10 June in Auckland (UTC+12)');
update public.platform_settings set value = '"Africa/Lusaka"' where key = 'org.timezone';
select zm_test.expect_equal(zm_test.run_job('2026-06-09T12:30:00Z')::text, '0', 'the same instant is still 9 June in Lusaka, so nothing is celebrated');
select zm_test.expect_equal((select event_date::text from public.staff_birthday_events where user_id = zm_test.s(5)), '2026-06-10', 'the event is dated in the organisation timezone');
update public.platform_settings set value = '"Mars/Phobos"' where key = 'org.timezone';
select zm_test.expect_equal(public.org_timezone(), 'Africa/Lusaka', 'an unknown timezone falls back to Lusaka');
update public.platform_settings set value = '"Africa/Lusaka"' where key = 'org.timezone';

-- 6. Several birthdays on the same day -------------------------------------------------------------------------------------
select zm_test.bday(6, 9, 1);
select zm_test.bday(8, 9, 1);
select zm_test.bday(10, 9, 1);
select zm_test.expect_equal(zm_test.total('birthday.today')::text, ((zm_test.active_staff() - 1) * 3 - 1)::text, 'before the day: three earlier birthdays announced to 9 people each, less the one notice staff 1 had muted');
select zm_test.expect_equal(zm_test.run_job('2026-08-31T22:30:00Z')::text, '3', 'three birthdays on 1 September');
select zm_test.expect_equal((select count(*)::text from public.staff_birthday_events where event_date = '2026-09-01'), '3', 'three events');
select zm_test.expect_equal(zm_test.notes(zm_test.s(2), 'birthday.today')::text, '6', 'a colleague hears about each of the six birthdays so far');
select zm_test.expect_equal(zm_test.notes(zm_test.s(6), 'birthday.today')::text, '5', 'a birthday person hears about the other five birthdays, not their own');
select zm_test.expect_equal(zm_test.notes(zm_test.s(6), 'birthday.greeting')::text, '1', 'and gets their own greeting once');
select zm_test.run_job('2026-08-31T22:30:00Z');
select zm_test.expect_equal(zm_test.notes(zm_test.s(2), 'birthday.today')::text, '6', 'running again changes nothing');

-- 7. 29 February -----------------------------------------------------------------------------------------------------------------
select zm_test.bday(7, 2, 29);
select zm_test.expect_equal(zm_test.run_job('2027-02-27T22:30:00Z')::text, '1', '28 February 2027 (not a leap year) celebrates a 29 February birthday');
select zm_test.expect_equal(zm_test.run_job('2027-02-28T22:30:00Z')::text, '0', '1 March does not');
select zm_test.expect_equal(zm_test.run_job('2028-02-27T22:30:00Z')::text, '0', '28 February 2028 (a leap year) does not');
select zm_test.expect_equal(zm_test.run_job('2028-02-28T22:30:00Z')::text, '1', '29 February 2028 does');

-- 8. Visibility ----------------------------------------------------------------------------------------------------------------------
select zm_test.bday(3, 10, 3, 'hidden');
select zm_test.expect_equal(zm_test.run_job('2026-10-02T22:30:00Z')::text, '1', 'a hidden birthday still has an event');
select zm_test.expect_equal(zm_test.notes(zm_test.s(3), 'birthday.greeting')::text, '2', 'the person still gets a greeting');
select zm_test.expect_equal((select count(*)::text from public.notifications n join public.staff_birthday_events e on n.link = '/admin/birthdays/' || e.id::text
   where n.type = 'birthday.today' and e.event_date = '2026-10-03'), '0', 'nobody else is told about a hidden birthday');
select zm_test.act_as(zm_test.s(4), 'aal2');
select zm_test.expect_equal((select count(*)::text from public.staff_birthdays_month(10)), '0', 'a hidden birthday is not in the calendar for others');
select zm_test.expect_equal((select count(*)::text from public.staff_birthdays_upcoming(366) where display_name = 'Staff 3'), '0', 'nor in the upcoming list');
select zm_test.act_as(zm_test.s(3), 'aal2');
select zm_test.expect_equal((select count(*)::text from public.staff_birthdays_month(10)), '1', 'but the person sees their own');
select zm_test.act_as_admin();
select set_config('zm.hidden_event', (select id::text from public.staff_birthday_events where event_date = '2026-10-03'), true);
-- make the day today, so the only thing that can stop a wish is the visibility rule, not the closed window
update public.staff_birthday_events set event_date = public.bd_today() where id = current_setting('zm.hidden_event')::uuid;
select zm_test.act_as(zm_test.s(4), 'aal2');
select zm_test.expect_error($$select * from public.birthday_event(current_setting('zm.hidden_event')::uuid)$$, 'others cannot open a hidden birthday board');
select zm_test.expect_error($$select * from public.birthday_messages(current_setting('zm.hidden_event')::uuid)$$, 'or read it');
select zm_test.expect_error($$select public.send_birthday_message(current_setting('zm.hidden_event')::uuid, 'Happy birthday!')$$, 'or write on it');
select zm_test.act_as(zm_test.s(3), 'aal2');
select zm_test.expect_equal((select i_am_birthday_person::text from public.birthday_event(current_setting('zm.hidden_event')::uuid)), 'true', 'the person can open their own board');

-- 9. Deactivated staff ---------------------------------------------------------------------------------------------------------------
select zm_test.bday(9, 11, 4);
select zm_test.act_as_admin();
delete from public.admin_roles where user_id = zm_test.s(9);
select zm_test.expect_equal(zm_test.run_job('2026-11-03T22:30:00Z')::text, '0', 'someone who is no longer staff has no birthday celebration');
select zm_test.act_as_admin();
insert into public.admin_roles (user_id, role) values (zm_test.s(9), 'moderator');
update public.profiles set account_state = 'suspended' where id = zm_test.s(9);
select zm_test.expect_equal(zm_test.run_job('2026-11-03T22:30:00Z')::text, '0', 'nor a suspended account');
update public.profiles set account_state = 'active' where id = zm_test.s(9);
select zm_test.bday(9, 12, 12);
select set_config('zm.before4', zm_test.notes(zm_test.s(4), 'birthday.today')::text, true);
select set_config('zm.before1', zm_test.notes(zm_test.s(1), 'birthday.today')::text, true);
update public.profiles set account_state = 'suspended' where id = zm_test.s(4);
delete from public.admin_roles where user_id = zm_test.s(5);
select zm_test.run_job('2026-12-11T22:30:00Z');
select zm_test.expect_equal(zm_test.notes(zm_test.s(4), 'birthday.today')::text, current_setting('zm.before4'), 'a suspended person is not told');
select zm_test.expect_equal(zm_test.notes(zm_test.s(1), 'birthday.today')::text, (current_setting('zm.before1')::integer + 1)::text, 'while an active colleague is');
select zm_test.expect_equal((select count(*)::text from public.notifications n join public.staff_birthday_events e on n.link = '/admin/birthdays/' || e.id::text
   where n.user_id = zm_test.s(5) and e.event_date = '2026-12-12'), '0', 'someone who left is not told');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.staff_birthday_notification_logs l join public.staff_birthday_events e on e.id = l.event_id where e.event_date = '2026-12-12' and l.recipient_id in (zm_test.s(4), zm_test.s(5))), '0', 'and no log row is made for them');
update public.profiles set account_state = 'active' where id = zm_test.s(4);
insert into public.admin_roles (user_id, role) values (zm_test.s(5), 'finance');
select zm_test.act_as_admin();
delete from public.admin_roles where user_id = zm_test.s(8);
select zm_test.act_as(zm_test.s(1), 'aal2');
select zm_test.expect_equal((select count(*)::text from public.staff_birthdays_month(9) where display_name = 'Staff 8'), '0', 'a leaver disappears from the calendar');
select zm_test.act_as_admin();
insert into public.admin_roles (user_id, role) values (zm_test.s(8), 'support');

-- 10. The calendar -------------------------------------------------------------------------------------------------------------------------
select zm_test.act_as(zm_test.s(1), 'aal2');
select zm_test.expect_equal((select string_agg(display_name || ':' || birth_day, ',' order by birth_day, display_name) from public.staff_birthdays_month(9)), 'Staff 10:1,Staff 6:1,Staff 8:1', 'the monthly calendar');
select zm_test.expect_equal((select count(*)::text from public.staff_birthdays_month(3)), '1', 'March has one birthday now (staff 3 moved to October)');
select zm_test.expect_error($$select * from public.staff_birthdays_month(13)$$, 'month 13');
select zm_test.act_as_admin();
-- a birthday ten days from now, set straight into the table
insert into public.staff_birthday_profiles (user_id, birth_month, birth_day, date_changed_at)
select zm_test.s(1), extract(month from public.bd_today() + 10)::integer, extract(day from public.bd_today() + 10)::integer, '2000-01-01';
select zm_test.act_as(zm_test.s(4), 'aal2');
select zm_test.expect_equal((select days_until::text from public.staff_birthdays_upcoming(30) where display_name = 'Staff 1'), '10', 'upcoming shows days until');
select zm_test.expect_equal((select count(*)::text from public.staff_birthdays_upcoming(5) where display_name = 'Staff 1'), '0', 'and respects the window');
select zm_test.expect_equal((select max(days_until)::text from public.staff_birthdays_upcoming(100000)), (select least(366, max(days_until))::text from public.staff_birthdays_upcoming(366)), 'the window is capped at a year');
select zm_test.expect_equal((select count(*)::text from public.staff_birthdays_upcoming(30) where days_until < 1), '0', 'today is not in upcoming');
select zm_test.act_as_admin();
delete from public.staff_birthday_profiles where user_id = zm_test.s(1);

-- 11. Today, the board and the wishes (staff 2 has a birthday today) ---------------------------------------------------------------------------
select zm_test.act_as_admin();
select set_config('zm.tm', extract(month from public.bd_today())::text, true), set_config('zm.td', extract(day from public.bd_today())::text, true);
select zm_test.act_as(zm_test.s(2), 'aal2');
select public.clear_my_birthday();
select public.set_my_birthday(current_setting('zm.tm')::integer, current_setting('zm.td')::integer, 'staff', true, 'Moderator');
select zm_test.run_job(now()::text);
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.staff_birthday_events where user_id = zm_test.s(2)), '0', 'no event yet');
update public.staff_birthday_profiles set date_changed_at = now() - interval '2 days' where user_id = zm_test.s(2);
select zm_test.run_job(now()::text);
select zm_test.expect_equal((select count(*)::text from public.staff_birthday_events where user_id = zm_test.s(2)), '1', 'once it is a long-standing birthday, it is celebrated');
select set_config('zm.board', (select id::text from public.staff_birthday_events where user_id = zm_test.s(2)), true);
select zm_test.act_as(zm_test.s(4), 'aal2');
select zm_test.expect_equal((select count(*)::text from public.staff_birthdays_today() where display_name = 'Staff 2'), '1', 'today list shows the birthday');
select zm_test.expect_equal((select (event_id = current_setting('zm.board')::uuid)::text from public.staff_birthdays_today() where display_name = 'Staff 2'), 'true', 'with its board');
select zm_test.expect_equal((select can_write::text from public.birthday_event(current_setting('zm.board')::uuid)), 'true', 'a colleague can write');
select zm_test.expect_equal((select i_am_birthday_person::text from public.birthday_event(current_setting('zm.board')::uuid)), 'false', 'and is not the birthday person');
select zm_test.expect_equal((select user_id::text from public.birthday_event(current_setting('zm.board')::uuid)), zm_test.s(2)::text, 'the board is for the right person');
select zm_test.expect_equal((select position_title from public.birthday_event(current_setting('zm.board')::uuid)), 'Moderator', 'position shown');
select set_config('zm.m1', public.send_birthday_message(current_setting('zm.board')::uuid, '  Happy birthday, Staff 2!  ')::text, true);
select zm_test.act_as(zm_test.s(6), 'aal2');
select set_config('zm.m2', public.send_birthday_message(current_setting('zm.board')::uuid, 'Many happy returns.')::text, true);
select zm_test.act_as(zm_test.s(4), 'aal2');
select set_config('zm.m3', public.send_birthday_message(current_setting('zm.board')::uuid, 'Enjoy your cake.')::text, true);
select zm_test.expect_equal((select string_agg(sender_name, ',' order by created_at, message_id) from public.birthday_messages(current_setting('zm.board')::uuid)), 'Staff 4,Staff 6,Staff 4', 'messages show their sender, in order');
select zm_test.expect_equal((select body from public.birthday_messages(current_setting('zm.board')::uuid) where message_id = current_setting('zm.m1')::uuid), 'Happy birthday, Staff 2!', 'the text is trimmed');
select zm_test.expect_equal((select count(*)::text from public.birthday_messages(current_setting('zm.board')::uuid) where is_mine), '2', 'my own are marked');
select public.send_birthday_message(current_setting('zm.board')::uuid, 'Third wish');
select zm_test.expect_error($$select public.send_birthday_message(current_setting('zm.board')::uuid, 'Fourth wish')$$, 'the fourth wish');
select zm_test.expect_equal((select can_write::text from public.birthday_event(current_setting('zm.board')::uuid)), 'false', 'the board says the cap is reached');
select zm_test.expect_error($$select public.send_birthday_message(current_setting('zm.board')::uuid, '   ')$$, 'a blank wish');
select zm_test.act_as(zm_test.s(6), 'aal2');
select zm_test.expect_error($$select public.send_birthday_message(current_setting('zm.board')::uuid, repeat('x', 501))$$, 'too long a wish');
select zm_test.expect_error($$select public.send_birthday_message(gen_random_uuid(), 'Hello')$$, 'an event that does not exist');

-- the birthday person is told, reads the board, and cannot write on it
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.notes(zm_test.s(2), 'birthday.message')::text, '4', 'every wish notifies the birthday person');
select zm_test.expect_equal((select body from public.notifications where user_id = zm_test.s(2) and type = 'birthday.message' order by created_at limit 1), 'Open your board to read it.', 'the notice never carries the message text');
select zm_test.expect_equal((select title from public.notifications where user_id = zm_test.s(2) and type = 'birthday.message' order by created_at limit 1), 'A birthday wish from Staff 4', 'but names who it is from');
select zm_test.act_as(zm_test.s(2), 'aal1');
select zm_test.expect_equal((select count(*)::text from public.birthday_messages(current_setting('zm.board')::uuid)), '4', 'the birthday person reads the board');
select zm_test.expect_equal((select can_write::text from public.birthday_event(current_setting('zm.board')::uuid)), 'false', 'but cannot write on their own');
select zm_test.expect_error($$select public.send_birthday_message(current_setting('zm.board')::uuid, 'I wish myself well')$$, 'no self-wishes');
-- notification controls: muting the staff category stops wish notices
select public.set_notification_preference('staff', false, false, false, false);
select zm_test.act_as(zm_test.s(9), 'aal2');
select public.send_birthday_message(current_setting('zm.board')::uuid, 'Muted notice test');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.notes(zm_test.s(2), 'birthday.message')::text, '4', 'a muted person gets no notice for a new wish');
select zm_test.expect_equal((select count(*)::text from public.staff_birthday_messages where event_id = current_setting('zm.board')::uuid), '5', 'but the wish is still kept');

-- 12. Who can read and write ------------------------------------------------------------------------------------------------------------------------
select zm_test.act_as('00000000-0000-0000-0000-00000000000b', 'aal2');
select zm_test.expect_error($$select * from public.birthday_messages(current_setting('zm.board')::uuid)$$, 'non-staff cannot read a board');
select zm_test.expect_error($$select public.send_birthday_message(current_setting('zm.board')::uuid, 'Hello')$$, 'non-staff cannot write');
select zm_test.act_as(zm_test.s(7), 'aal1');
select zm_test.expect_error($$select * from public.birthday_messages(current_setting('zm.board')::uuid)$$, 'staff without two-factor cannot read a board');
select zm_test.expect_error($$select public.send_birthday_message(current_setting('zm.board')::uuid, 'Hello')$$, 'or write');
select zm_test.act_as_guest();
select zm_test.expect_error($$select * from public.birthday_messages(current_setting('zm.board')::uuid)$$, 'guests cannot read a board');
select zm_test.act_as(zm_test.s(7), 'aal2');
select zm_test.expect_error($$select * from public.staff_birthday_events$$, 'no direct reads of events');
select zm_test.expect_error($$select * from public.staff_birthday_messages$$, 'no direct reads of messages');
select zm_test.expect_error($$insert into public.staff_birthday_messages (event_id, sender_id, recipient_id, body) values (current_setting('zm.board')::uuid, zm_test.s(7), zm_test.s(2), 'Direct insert')$$, 'no direct writes');
select zm_test.expect_error($$insert into public.staff_birthday_messages (event_id, sender_id, recipient_id, body) values (current_setting('zm.board')::uuid, zm_test.s(4), zm_test.s(2), 'As someone else')$$, 'no writing as someone else');
select zm_test.expect_error($$select * from public.staff_birthday_profiles$$, 'no direct reads of birthdays');
-- the sender is whoever is signed in, whatever the caller tries
select zm_test.act_as(zm_test.s(7), 'aal2');
select set_config('zm.m7', public.send_birthday_message(current_setting('zm.board')::uuid, 'From staff 7')::text, true);
select zm_test.act_as_admin();
select zm_test.expect_equal((select sender_id::text from public.staff_birthday_messages where id = current_setting('zm.m7')::uuid), zm_test.s(7)::text, 'the sender comes from the session');
select zm_test.expect_equal((select recipient_id::text from public.staff_birthday_messages where id = current_setting('zm.m7')::uuid), zm_test.s(2)::text, 'the recipient is the birthday person');

-- 13. Messages are a permanent record -----------------------------------------------------------------------------------------------------------------
select zm_test.expect_error($$update public.staff_birthday_messages set body = 'Edited' where id = current_setting('zm.m1')::uuid$$, 'a message cannot be edited, even by an administrator');
select zm_test.expect_error($$update public.staff_birthday_messages set sender_id = zm_test.s(5) where id = current_setting('zm.m1')::uuid$$, 'the sender cannot be swapped');
select zm_test.expect_error($$delete from public.staff_birthday_messages where id = current_setting('zm.m1')::uuid$$, 'a message cannot be deleted');
select zm_test.expect_error($$insert into public.staff_birthday_messages (event_id, sender_id, recipient_id, body) values (current_setting('zm.board')::uuid, zm_test.s(5), zm_test.s(6), 'Wrong recipient')$$, 'a wish must go to the birthday person');
-- the window closes after a few days, but the history stays readable
update public.staff_birthday_events set event_date = public.bd_today() - 10 where id = current_setting('zm.board')::uuid;
select zm_test.act_as(zm_test.s(5), 'aal2');
select zm_test.expect_error($$select public.send_birthday_message(current_setting('zm.board')::uuid, 'Late wish')$$, 'wishes close after the window');
select zm_test.expect_equal((select can_write::text from public.birthday_event(current_setting('zm.board')::uuid)), 'false', 'the board says it is closed');
select zm_test.expect_equal((select count(*)::text from public.birthday_messages(current_setting('zm.board')::uuid)), '6', 'but all six wishes can still be read');
select zm_test.act_as(zm_test.s(2), 'aal2');
select zm_test.expect_equal((select count(*)::text from public.my_birthday_events()), '1', 'the birthday person has a history of boards');
select zm_test.expect_equal((select message_count::text from public.my_birthday_events()), '6', 'with message counts');
select zm_test.act_as_admin();
update public.staff_birthday_events set event_date = public.bd_today() where id = current_setting('zm.board')::uuid;

-- 14. Reporting and moderation ---------------------------------------------------------------------------------------------------------------------------
select zm_test.act_as(zm_test.s(5), 'aal2');
select zm_test.expect_error($$select public.report_birthday_message(current_setting('zm.m1')::uuid, 'x')$$, 'a reason is needed');
select public.report_birthday_message(current_setting('zm.m1')::uuid, 'This is not appropriate');
select public.report_birthday_message(current_setting('zm.m1')::uuid, 'Reported twice by mistake');
select zm_test.act_as(zm_test.s(4), 'aal2');
select zm_test.expect_error($$select public.report_birthday_message(current_setting('zm.m1')::uuid, 'Reporting my own message')$$, 'you cannot report your own message');
select zm_test.act_as('00000000-0000-0000-0000-00000000000b', 'aal2');
select zm_test.expect_error($$select public.report_birthday_message(current_setting('zm.m1')::uuid, 'Not staff so no access')$$, 'non-staff cannot report');
select zm_test.act_as(zm_test.s(6), 'aal2');
select public.report_birthday_message(current_setting('zm.m3')::uuid, 'Second report on another message');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.staff_birthday_reports where message_id = current_setting('zm.m1')::uuid), '1', 'the same person reporting twice makes one report');
select zm_test.act_as(zm_test.s(3), 'aal2');
select zm_test.expect_error($$select * from public.birthday_reports_queue()$$, 'support staff cannot see the queue');
select zm_test.act_as(zm_test.s(9), 'aal1');
select zm_test.expect_error($$select * from public.birthday_reports_queue()$$, 'a moderator without two-factor cannot see the queue');
select zm_test.act_as(zm_test.s(9), 'aal2');
select zm_test.expect_equal((select count(*)::text from public.birthday_reports_queue()), '2', 'a moderator sees the open reports');
select zm_test.expect_equal((select body from public.birthday_reports_queue() where message_id = current_setting('zm.m1')::uuid), 'Happy birthday, Staff 2!', 'with the message');
select set_config('zm.rep1', (select report_id::text from public.birthday_reports_queue() where message_id = current_setting('zm.m1')::uuid), true);
select set_config('zm.rep3', (select report_id::text from public.birthday_reports_queue() where message_id = current_setting('zm.m3')::uuid), true);
select zm_test.expect_error($$select public.resolve_birthday_report(current_setting('zm.rep1')::uuid, 'hide', '')$$, 'a reason is required');
select zm_test.expect_error($$select public.resolve_birthday_report(current_setting('zm.rep1')::uuid, 'delete', 'Not an option')$$, 'only hide or dismiss');
select public.resolve_birthday_report(current_setting('zm.rep1')::uuid, 'hide', 'Breaks the conduct policy');
select public.resolve_birthday_report(current_setting('zm.rep3')::uuid, 'dismiss', 'Looks fine to me');
select zm_test.expect_error($$select public.resolve_birthday_report(current_setting('zm.rep1')::uuid, 'dismiss', 'Already decided')$$, 'a decided report cannot be decided again');
select zm_test.expect_equal((select count(*)::text from public.birthday_reports_queue()), '0', 'the queue is empty');
select zm_test.act_as(zm_test.s(4), 'aal2');
select zm_test.expect_equal((select hidden::text || ':' || coalesce(body, 'null') from public.birthday_messages(current_setting('zm.board')::uuid) where message_id = current_setting('zm.m1')::uuid), 'true:null', 'a hidden message shows no text to anyone');
select zm_test.expect_equal((select count(*)::text from public.birthday_messages(current_setting('zm.board')::uuid)), '6', 'but its place on the board stays');
select zm_test.expect_equal((select hidden::text from public.birthday_messages(current_setting('zm.board')::uuid) where message_id = current_setting('zm.m3')::uuid), 'false', 'a dismissed report hides nothing');
select zm_test.act_as_admin();
select zm_test.expect_equal((select body from public.staff_birthday_messages where id = current_setting('zm.m1')::uuid), 'Happy birthday, Staff 2!', 'the original text is kept in the record');
select zm_test.expect_error($$update public.staff_birthday_messages set hidden_at = null, hidden_by = null where id = current_setting('zm.m1')::uuid$$, 'a hidden message stays hidden');
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action in ('staff_birthday.report_hide', 'staff_birthday.report_dismiss')), '2', 'moderation is audited');
-- conflicts of interest
select zm_test.act_as(zm_test.s(6), 'aal2');
select public.report_birthday_message(current_setting('zm.m7')::uuid, 'Staff 6 reports staff 7');
select zm_test.act_as_admin();
insert into public.admin_roles (user_id, role) values (zm_test.s(7), 'moderator');
select zm_test.act_as(zm_test.s(7), 'aal2');
select zm_test.expect_error($$select public.resolve_birthday_report((select report_id from public.birthday_reports_queue() limit 1), 'hide', 'Deciding my own case')$$, 'a moderator cannot decide a report about their own message');
select zm_test.act_as_admin();
delete from public.admin_roles where user_id = zm_test.s(7) and role = 'moderator';

-- 15. Access logs -----------------------------------------------------------------------------------------------------------------------------------------------
select zm_test.act_as(zm_test.s(1), 'aal2');
select zm_test.expect_equal((select (count(*) > 5)::text from public.staff_birthday_access_log(500)), 'true', 'calendar and board reads are logged');
select zm_test.expect_equal((select (count(*) > 0)::text from public.staff_birthday_access_log(500) where action = 'board_view'), 'true', 'including boards');
select zm_test.act_as(zm_test.s(9), 'aal2');
select zm_test.expect_error($$select * from public.staff_birthday_access_log()$$, 'moderators cannot read the access log');
select zm_test.act_as_admin();
insert into public.staff_birthday_access_logs (viewer_id, action, created_at) values (zm_test.s(4), 'calendar_month', now() - interval '120 days');
select zm_test.act_as_service();
select public.purge_old_birthday_access_logs();
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.staff_birthday_access_logs where created_at < now() - interval '90 days'), '0', 'old access logs are purged');

-- 16. Notification category ---------------------------------------------------------------------------------------------------------------------------------------
select zm_test.act_as(zm_test.s(4), 'aal1');
select zm_test.expect_equal((select count(*)::text from public.my_notification_settings()), '7', 'staff see the staff category');
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_equal((select count(*)::text from public.my_notification_settings()), '6', 'everyone else sees the original six');
select zm_test.expect_error($$select public.set_notification_preference('staff', false, false, false, false)$$, 'non-staff cannot set it');
select zm_test.act_as(zm_test.s(4), 'aal1');
select zm_test.expect_error($$select public.set_notification_preference('nonsense', false, false, false, false)$$, 'unknown categories are still refused');

-- 17. Function permissions ---------------------------------------------------------------------------------------------------------------------------------------------
select zm_test.act_as_admin();
select zm_test.expect_equal((select bool_or(has_function_privilege('authenticated', p.oid, 'execute'))::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('bd_guard_message', 'org_timezone', 'bd_need_staff', 'bd_is_active_staff', 'bd_is_leap', 'bd_date_in_year', 'bd_today', 'bd_log_access', 'bd_can_view', 'run_staff_birthdays', 'purge_old_birthday_access_logs')), 'false', 'internal and job functions are closed to the app');
select zm_test.expect_equal((select bool_or(has_function_privilege('anon', p.oid, 'execute'))::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and (p.proname like '%birthday%' or p.proname = 'staff_birthdays_today' or p.proname = 'staff_birthdays_upcoming' or p.proname = 'staff_birthdays_month')), 'false', 'guests can run none of them');
select zm_test.expect_equal(has_function_privilege('service_role', 'public.run_staff_birthdays(timestamptz)', 'execute')::text, 'true', 'the job can run');
select zm_test.act_as(zm_test.s(1), 'aal2');
select zm_test.expect_error($$select public.run_staff_birthdays()$$, 'even a technical admin cannot trigger the job from the app');

select zm_test.act_as_admin();
select 'Staff birthday checks passed' as result;
rollback;
