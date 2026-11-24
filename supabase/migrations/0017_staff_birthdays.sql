-- 0017: Staff birthdays and celebrations (Phase 11 and the birthday half of Phase 12)
--
-- Staff can enter their birthday, see who is celebrating, and leave birthday wishes. On the day, the birthday
-- person gets a greeting and the other active staff get a notice with a link to the message board.
--
-- Privacy:
--   * Only the DAY and MONTH are stored. There is no year and no full date of birth anywhere, so none can leak.
--   * Everything is staff-only (two-factor plus a staff role). Nothing here is reachable from a marketplace
--     profile, and the tables have no grants for app users.
--   * Visibility: 'staff' (other staff can see it) or 'hidden' (only you; no notice goes to anyone else).
--   * Reading the calendar or a board is logged (staff_birthday_access_logs, kept 90 days).
--
-- Timing: "today" is the organisation's timezone, platform_settings key org.timezone (default Africa/Lusaka).
-- The job run_staff_birthdays() is idempotent: unique rows make a second run, or two runs at once, send nothing twice.
-- A 29 February birthday is celebrated on 28 February in years that are not leap years.
-- A birthday saved today does not trigger notices today (it would let anyone ping every colleague on demand);
-- it starts the next time that date comes round.
--
-- Messages: written through a function that takes the sender from the signed-in session, so nobody can write as
-- someone else. They are kept for good. Moderators can hide one (the text stays in the record) after a report.
--
-- Notifications: a new 'staff' category that people can mute. It appears in a person's settings only if they hold
-- a staff role. The notification table has no image column, so the photograph appears on the board and the
-- calendar, not inside the notice itself.
--
-- Existing pieces touched: the notification category check on two tables, and my_notification_settings and
-- set_notification_preference (both only widened to know the 'staff' category).

-- ---------------------------------------------------------------------------
-- Settings (starter values)
-- ---------------------------------------------------------------------------

insert into public.platform_settings (key, value, note) values
  ('org.timezone', '"Africa/Lusaka"', 'Timezone used for "today" in birthday notices. Any name from pg_timezone_names. Falls back to Africa/Lusaka if the name is not recognised.'),
  ('staff_birthday.message_days', '3', 'Days after a birthday during which wishes can still be written. Starter value.'),
  ('staff_birthday.max_messages_per_sender', '3', 'Wishes one person can leave on one birthday. Starter value.'),
  ('rate_limit.birthday_profile.max', '5', 'Birthday edits per window. Starter value.'),
  ('rate_limit.birthday_profile.window_minutes', '1440', null),
  ('rate_limit.birthday_message.max', '30', 'Wishes per window across all boards. Starter value.'),
  ('rate_limit.birthday_message.window_minutes', '60', null),
  ('rate_limit.birthday_report.max', '10', 'Reports per window. Starter value.'),
  ('rate_limit.birthday_report.window_minutes', '60', null)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- A notification category staff can mute
-- ---------------------------------------------------------------------------

alter table public.notifications drop constraint notifications_category_check;
alter table public.notifications add constraint notifications_category_check
  check (category in ('orders', 'messages', 'alerts', 'listings', 'business', 'account', 'staff'));
alter table public.notification_preferences drop constraint notification_preferences_category_check;
alter table public.notification_preferences add constraint notification_preferences_category_check
  check (category in ('orders', 'messages', 'alerts', 'listings', 'business', 'account', 'staff'));

-- Same as before, plus the staff category for people who hold a staff role.
create or replace function public.my_notification_settings()
returns table (category text, in_app boolean, push boolean, email boolean, sms boolean)
language sql stable security definer set search_path = ''
as $$
  select c.category,
         coalesce(p.in_app, true), coalesce(p.push, true), coalesce(p.email, false), coalesce(p.sms, false)
    from unnest(array['orders', 'messages', 'alerts', 'listings', 'business', 'account', 'staff']) with ordinality as c(category, n)
    left join public.notification_preferences p on p.user_id = (select auth.uid()) and p.category = c.category
   where c.category <> 'staff'
      or exists (select 1 from public.admin_roles r where r.user_id = (select auth.uid()))
   order by c.n;
$$;

create or replace function public.set_notification_preference(p_category text, p_in_app boolean, p_push boolean, p_email boolean, p_sms boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if p_category not in ('orders', 'messages', 'alerts', 'listings', 'business', 'account', 'staff') then
    raise exception 'Unknown category.' using errcode = 'invalid_parameter_value';
  end if;
  if p_category = 'staff' and not exists (select 1 from public.admin_roles r where r.user_id = (select auth.uid())) then
    raise exception 'Unknown category.' using errcode = 'invalid_parameter_value';
  end if;
  if p_category = 'account' and not (p_in_app and p_push) then
    raise exception 'Account notices about your safety cannot be switched off.' using errcode = 'check_violation';
  end if;
  insert into public.notification_preferences (user_id, category, in_app, push, email, sms)
  values ((select auth.uid()), p_category, p_in_app, p_push, p_email, p_sms)
  on conflict (user_id, category) do update
    set in_app = excluded.in_app, push = excluded.push, email = excluded.email, sms = excluded.sms;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tables (no grants for app users; everything goes through the functions below)
-- ---------------------------------------------------------------------------

create table public.staff_birthday_profiles (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  birth_month smallint not null check (birth_month between 1 and 12),
  birth_day smallint not null check (birth_day between 1 and 31),
  visibility text not null default 'staff' check (visibility in ('staff', 'hidden')),
  show_photo boolean not null default true,
  position_title text check (position_title is null or char_length(btrim(position_title)) between 2 and 80),
  date_changed_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (birth_day <= case when birth_month = 2 then 29 when birth_month in (4, 6, 9, 11) then 30 else 31 end)
);
alter table public.staff_birthday_profiles enable row level security;

create table public.staff_birthday_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  event_date date not null,
  created_at timestamptz not null default now(),
  unique (user_id, event_date)
);
alter table public.staff_birthday_events enable row level security;

-- One row per notice that was due. The unique key is what makes the job safe to run twice.
create table public.staff_birthday_notification_logs (
  id bigint generated always as identity primary key,
  event_id uuid not null references public.staff_birthday_events (id) on delete cascade,
  kind text not null check (kind in ('greeting', 'broadcast')),
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  notification_id uuid,
  created_at timestamptz not null default now(),
  unique (event_id, kind, recipient_id)
);
alter table public.staff_birthday_notification_logs enable row level security;

create table public.staff_birthday_messages (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.staff_birthday_events (id),
  sender_id uuid not null references public.profiles (id),
  recipient_id uuid not null references public.profiles (id),
  body text not null check (char_length(btrim(body)) between 1 and 500),
  created_at timestamptz not null default clock_timestamp(),
  hidden_at timestamptz,
  hidden_by uuid references public.profiles (id),
  hidden_reason text check (char_length(hidden_reason) <= 300),
  check (sender_id <> recipient_id),
  check ((hidden_at is null) = (hidden_by is null))
);
create index staff_birthday_messages_event_idx on public.staff_birthday_messages (event_id, created_at);
alter table public.staff_birthday_messages enable row level security;

create table public.staff_birthday_reports (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.staff_birthday_messages (id),
  reporter_id uuid not null references public.profiles (id),
  reason text not null check (char_length(btrim(reason)) between 3 and 300),
  status text not null default 'open' check (status in ('open', 'actioned', 'dismissed')),
  created_at timestamptz not null default now(),
  decided_by uuid references public.profiles (id),
  decided_at timestamptz,
  decision_note text check (char_length(decision_note) <= 300),
  unique (message_id, reporter_id)
);
create index staff_birthday_reports_open_idx on public.staff_birthday_reports (created_at) where status = 'open';
alter table public.staff_birthday_reports enable row level security;

create table public.staff_birthday_access_logs (
  id bigint generated always as identity primary key,
  viewer_id uuid not null,
  action text not null check (char_length(action) between 3 and 40),
  event_id uuid,
  created_at timestamptz not null default now()
);
create index staff_birthday_access_logs_idx on public.staff_birthday_access_logs (created_at desc);
alter table public.staff_birthday_access_logs enable row level security;

-- ---------------------------------------------------------------------------
-- Messages are a permanent record
-- ---------------------------------------------------------------------------

create function public.bd_guard_message()
returns trigger
language plpgsql set search_path = ''
as $$
declare
  ev public.staff_birthday_events;
begin
  if tg_op = 'DELETE' then
    raise exception 'Birthday messages are kept and cannot be deleted.' using errcode = 'insufficient_privilege';
  end if;
  if tg_op = 'INSERT' then
    select * into ev from public.staff_birthday_events where id = new.event_id;
    if not found or ev.user_id <> new.recipient_id then
      raise exception 'A wish must go to the person whose birthday it is.' using errcode = 'check_violation';
    end if;
    return new;
  end if;
  -- UPDATE: only the moderation columns may change.
  if new.id is distinct from old.id or new.event_id is distinct from old.event_id or new.sender_id is distinct from old.sender_id
     or new.recipient_id is distinct from old.recipient_id or new.body is distinct from old.body
     or new.created_at is distinct from old.created_at then
    raise exception 'A birthday message cannot be edited.' using errcode = 'insufficient_privilege';
  end if;
  if old.hidden_at is not null and new.hidden_at is null then
    raise exception 'A hidden message stays hidden.' using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;
create trigger staff_birthday_messages_guard before insert or update or delete on public.staff_birthday_messages
  for each row execute function public.bd_guard_message();

-- ---------------------------------------------------------------------------
-- Small helpers (closed to the app)
-- ---------------------------------------------------------------------------

create function public.org_timezone()
returns text
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select n.name from pg_catalog.pg_timezone_names n
      where n.name = (select s.value #>> '{}' from public.platform_settings s where s.key = 'org.timezone') limit 1),
    'Africa/Lusaka');
$$;

create function public.bd_need_staff()
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_staff() then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
end;
$$;

-- Holds a staff role and has an active account.
create function public.bd_is_active_staff(p_user uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.admin_roles r where r.user_id = p_user)
     and exists (select 1 from public.profiles p where p.id = p_user and p.account_state = 'active');
$$;

create function public.bd_is_leap(p_year integer)
returns boolean
language sql immutable set search_path = ''
as $$ select (p_year % 4 = 0 and p_year % 100 <> 0) or p_year % 400 = 0; $$;

-- The date a birthday falls on in a given year (29 February becomes 28 February in other years).
create function public.bd_date_in_year(p_month integer, p_day integer, p_year integer)
returns date
language sql immutable set search_path = ''
as $$
  select make_date(p_year, p_month, case when p_month = 2 and p_day = 29 and not public.bd_is_leap(p_year) then 28 else p_day end);
$$;

create function public.bd_today()
returns date
language sql stable security definer set search_path = ''
as $$ select (now() at time zone public.org_timezone())::date; $$;

create function public.bd_log_access(p_action text, p_event uuid default null)
returns void
language sql security definer set search_path = ''
as $$
  insert into public.staff_birthday_access_logs (viewer_id, action, event_id)
  values ((select auth.uid()), p_action, p_event);
$$;

-- Can the signed-in person read this event's board?
create function public.bd_can_view(p_event uuid)
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  ev public.staff_birthday_events;
  prof public.staff_birthday_profiles;
begin
  if uid is null then
    return false;
  end if;
  select * into ev from public.staff_birthday_events where id = p_event;
  if not found then
    return false;
  end if;
  if ev.user_id = uid then
    return exists (select 1 from public.profiles where id = uid and account_state = 'active');
  end if;
  select * into prof from public.staff_birthday_profiles where user_id = ev.user_id;
  return found and prof.visibility = 'staff' and public.is_staff()
         and exists (select 1 from public.profiles where id = uid and account_state = 'active');
end;
$$;

-- ---------------------------------------------------------------------------
-- The daily job
-- ---------------------------------------------------------------------------

-- Creates today's birthday events and sends the greeting and the notices, once each.
-- Returns the number of birthdays celebrated today. Safe to run as often as you like.
create function public.run_staff_birthdays(p_now timestamptz default now())
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  tz text := public.org_timezone();
  local_date date := (p_now at time zone public.org_timezone())::date;
  r record;
  guest record;
  ev uuid;
  logged bigint;
  nid uuid;
  celebrated integer := 0;
begin
  for r in
    select p.user_id, p.visibility, pr.display_name
      from public.staff_birthday_profiles p
      join public.profiles pr on pr.id = p.user_id
     where public.bd_date_in_year(p.birth_month, p.birth_day, extract(year from local_date)::integer) = local_date
       and public.bd_is_active_staff(p.user_id)
       and (p.date_changed_at at time zone tz)::date < local_date
     order by p.user_id
  loop
    insert into public.staff_birthday_events (user_id, event_date) values (r.user_id, local_date)
      on conflict (user_id, event_date) do nothing
      returning id into ev;
    if ev is null then
      select id into ev from public.staff_birthday_events where user_id = r.user_id and event_date = local_date;
    end if;
    celebrated := celebrated + 1;

    -- Greeting to the birthday person.
    insert into public.staff_birthday_notification_logs (event_id, kind, recipient_id) values (ev, 'greeting', r.user_id)
      on conflict (event_id, kind, recipient_id) do nothing
      returning id into logged;
    if logged is not null then
      nid := public.notify(r.user_id, 'staff', 'birthday.greeting', 'Happy birthday, ' || r.display_name || '!',
        'The team may leave you birthday wishes today. Open the board to read them.',
        '/admin/birthdays/' || ev::text, 'birthday.greeting:' || ev::text);
      update public.staff_birthday_notification_logs set notification_id = nid where id = logged;
    end if;

    -- Notice to every other active staff member, unless the person keeps their birthday private.
    if r.visibility = 'staff' then
      for guest in
        select distinct a.user_id from public.admin_roles a
         where a.user_id <> r.user_id and public.bd_is_active_staff(a.user_id)
         order by a.user_id
      loop
        logged := null;
        insert into public.staff_birthday_notification_logs (event_id, kind, recipient_id) values (ev, 'broadcast', guest.user_id)
          on conflict (event_id, kind, recipient_id) do nothing
          returning id into logged;
        if logged is not null then
          nid := public.notify(guest.user_id, 'staff', 'birthday.today', r.display_name || ' has a birthday today',
            'Leave a birthday wish on the message board.',
            '/admin/birthdays/' || ev::text, 'birthday.today:' || ev::text);
          update public.staff_birthday_notification_logs set notification_id = nid where id = logged;
        end if;
      end loop;
    end if;
    ev := null;
  end loop;
  return celebrated;
end;
$$;

create function public.purge_old_birthday_access_logs()
returns void
language sql security definer set search_path = ''
as $$ delete from public.staff_birthday_access_logs where created_at < now() - interval '90 days'; $$;

-- ---------------------------------------------------------------------------
-- My own birthday
-- ---------------------------------------------------------------------------

create function public.my_birthday_profile()
returns table (has_birthday boolean, birth_month integer, birth_day integer, visibility text, show_photo boolean, position_title text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.bd_need_staff();
  return query
  select true, p.birth_month::integer, p.birth_day::integer, p.visibility, p.show_photo, p.position_title
    from public.staff_birthday_profiles p where p.user_id = (select auth.uid());
  if not found then
    return query select false, null::integer, null::integer, 'staff'::text, true, null::text;
  end if;
end;
$$;

create function public.set_my_birthday(p_month integer, p_day integer, p_visibility text, p_show_photo boolean, p_position text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  old public.staff_birthday_profiles;
  pos text := nullif(btrim(coalesce(p_position, '')), '');
  longest integer;
begin
  perform public.bd_need_staff();
  -- 29 February is allowed; it is celebrated on 28 February in years that are not leap years.
  longest := case when p_month = 2 then 29 when p_month in (4, 6, 9, 11) then 30 else 31 end;
  if p_month is null or p_month not between 1 and 12 or p_day is null or p_day < 1 or p_day > longest then
    raise exception 'That is not a real date.' using errcode = 'check_violation';
  end if;
  if p_visibility not in ('staff', 'hidden') then
    raise exception 'Choose who can see your birthday.' using errcode = 'check_violation';
  end if;
  if pos is not null and char_length(pos) not between 2 and 80 then
    raise exception 'Keep your position under 80 characters.' using errcode = 'check_violation';
  end if;
  perform public.enforce_rate_limit('birthday_profile', 5, 1440);

  select * into old from public.staff_birthday_profiles where user_id = uid;
  insert into public.staff_birthday_profiles (user_id, birth_month, birth_day, visibility, show_photo, position_title)
  values (uid, p_month, p_day, p_visibility, coalesce(p_show_photo, true), pos)
  on conflict (user_id) do update
    set birth_month = excluded.birth_month, birth_day = excluded.birth_day, visibility = excluded.visibility,
        show_photo = excluded.show_photo, position_title = excluded.position_title, updated_at = now(),
        date_changed_at = case when staff_birthday_profiles.birth_month = excluded.birth_month
                                and staff_birthday_profiles.birth_day = excluded.birth_day
                               then staff_birthday_profiles.date_changed_at else now() end;
  -- The audit entry records that something changed and the visibility chosen, never the date itself.
  perform public.write_audit('staff_birthday.updated', 'user', uid::text, jsonb_build_object('visibility', p_visibility, 'first_time', old.user_id is null));
end;
$$;

create function public.clear_my_birthday()
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.bd_need_staff();
  delete from public.staff_birthday_profiles where user_id = (select auth.uid());
  perform public.write_audit('staff_birthday.removed', 'user', (select auth.uid())::text, '{}');
end;
$$;

-- ---------------------------------------------------------------------------
-- The calendar
-- ---------------------------------------------------------------------------

create function public.staff_birthdays_today()
returns table (user_id uuid, display_name text, avatar_path text, position_title text, event_id uuid, is_me boolean, message_count integer)
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  today date := public.bd_today();
begin
  perform public.bd_need_staff();
  perform public.bd_log_access('calendar_today');
  return query
  select p.user_id, pr.display_name, case when p.show_photo then pr.avatar_path end, p.position_title, e.id, p.user_id = uid,
         (select count(*)::integer from public.staff_birthday_messages m where m.event_id = e.id and m.hidden_at is null)
    from public.staff_birthday_profiles p
    join public.profiles pr on pr.id = p.user_id
    left join public.staff_birthday_events e on e.user_id = p.user_id and e.event_date = today
   where public.bd_date_in_year(p.birth_month, p.birth_day, extract(year from today)::integer) = today
     and public.bd_is_active_staff(p.user_id)
     and (p.visibility = 'staff' or p.user_id = uid)
   order by pr.display_name;
end;
$$;

create function public.staff_birthdays_upcoming(p_days integer default 30)
returns table (user_id uuid, display_name text, avatar_path text, position_title text, birth_month integer, birth_day integer, next_date date, days_until integer)
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  today date := public.bd_today();
  span integer := least(greatest(coalesce(p_days, 30), 1), 366);
begin
  perform public.bd_need_staff();
  perform public.bd_log_access('calendar_upcoming');
  return query
  select x.user_id, x.display_name, x.avatar_path, x.position_title, x.birth_month, x.birth_day, x.next_date, (x.next_date - today)
    from (
      select p.user_id, pr.display_name, case when p.show_photo then pr.avatar_path end as avatar_path, p.position_title,
             p.birth_month::integer as birth_month, p.birth_day::integer as birth_day,
             case when public.bd_date_in_year(p.birth_month, p.birth_day, extract(year from today)::integer) >= today
                  then public.bd_date_in_year(p.birth_month, p.birth_day, extract(year from today)::integer)
                  else public.bd_date_in_year(p.birth_month, p.birth_day, extract(year from today)::integer + 1) end as next_date
        from public.staff_birthday_profiles p
        join public.profiles pr on pr.id = p.user_id
       where public.bd_is_active_staff(p.user_id) and (p.visibility = 'staff' or p.user_id = uid)
    ) x
   where x.next_date > today and x.next_date - today <= span
   order by x.next_date, x.display_name;
end;
$$;

create function public.staff_birthdays_month(p_month integer)
returns table (user_id uuid, display_name text, avatar_path text, position_title text, birth_month integer, birth_day integer)
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
begin
  perform public.bd_need_staff();
  if p_month is null or p_month not between 1 and 12 then
    raise exception 'Choose a month from 1 to 12.' using errcode = 'check_violation';
  end if;
  perform public.bd_log_access('calendar_month');
  return query
  select p.user_id, pr.display_name, case when p.show_photo then pr.avatar_path end, p.position_title, p.birth_month::integer, p.birth_day::integer
    from public.staff_birthday_profiles p join public.profiles pr on pr.id = p.user_id
   where p.birth_month = p_month and public.bd_is_active_staff(p.user_id) and (p.visibility = 'staff' or p.user_id = uid)
   order by p.birth_day, pr.display_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- The message board
-- ---------------------------------------------------------------------------

create function public.birthday_event(p_event uuid)
returns table (event_id uuid, user_id uuid, display_name text, avatar_path text, position_title text, event_date date,
               i_am_birthday_person boolean, can_write boolean, my_message_count integer, max_messages integer)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  uid uuid := (select auth.uid());
  ev public.staff_birthday_events;
  prof public.staff_birthday_profiles;
  mine integer;
  cap integer := public.setting_numeric('staff_birthday.max_messages_per_sender', 3)::integer;
  window_days integer := public.setting_numeric('staff_birthday.message_days', 3)::integer;
  today date := public.bd_today();
  writable boolean;
begin
  if not public.bd_can_view(p_event) then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  perform public.bd_log_access('board_view', p_event);
  select * into ev from public.staff_birthday_events where id = p_event;
  select * into prof from public.staff_birthday_profiles where user_id = ev.user_id;
  select count(*)::integer into mine from public.staff_birthday_messages where event_id = p_event and sender_id = uid;
  writable := ev.user_id <> uid and public.is_staff() and mine < cap
              and today between ev.event_date and ev.event_date + window_days
              and public.bd_is_active_staff(ev.user_id) and coalesce(prof.visibility, 'hidden') = 'staff'
              and exists (select 1 from public.profiles where id = uid and account_state = 'active');
  return query
  select ev.id, ev.user_id, pr.display_name, case when coalesce(prof.show_photo, false) then pr.avatar_path end, prof.position_title,
         ev.event_date, ev.user_id = uid, writable, mine, cap
    from public.profiles pr where pr.id = ev.user_id;
end;
$$;

create function public.birthday_messages(p_event uuid)
returns table (message_id uuid, sender_id uuid, sender_name text, body text, created_at timestamptz, is_mine boolean, hidden boolean)
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.bd_can_view(p_event) then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  return query
  select m.id, m.sender_id, pr.display_name, case when m.hidden_at is null then m.body end, m.created_at,
         m.sender_id = (select auth.uid()), m.hidden_at is not null
    from public.staff_birthday_messages m join public.profiles pr on pr.id = m.sender_id
   where m.event_id = p_event
   order by m.created_at, m.id;
end;
$$;

create function public.send_birthday_message(p_event uuid, p_body text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  ev public.staff_birthday_events;
  prof public.staff_birthday_profiles;
  new_id uuid;
  sender_name text;
  text_body text := btrim(coalesce(p_body, ''));
  cap integer := public.setting_numeric('staff_birthday.max_messages_per_sender', 3)::integer;
  window_days integer := public.setting_numeric('staff_birthday.message_days', 3)::integer;
begin
  perform public.bd_need_staff();
  if char_length(text_body) not between 1 and 500 then
    raise exception 'Write a wish of up to 500 characters.' using errcode = 'check_violation';
  end if;
  select * into ev from public.staff_birthday_events where id = p_event;
  if not found then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if ev.user_id = uid then
    raise exception 'You cannot write on your own birthday board.' using errcode = 'check_violation';
  end if;
  select * into prof from public.staff_birthday_profiles where user_id = ev.user_id;
  if not found or prof.visibility <> 'staff' or not public.bd_is_active_staff(ev.user_id)
     or not exists (select 1 from public.profiles where id = uid and account_state = 'active') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if public.bd_today() not between ev.event_date and ev.event_date + window_days then
    raise exception 'Birthday wishes for this day are closed.' using errcode = 'check_violation';
  end if;
  perform public.enforce_rate_limit('birthday_message', 30, 60);
  -- Lock the event so two wishes at once cannot get past the per-person cap.
  perform 1 from public.staff_birthday_events where id = p_event for update;
  if (select count(*) from public.staff_birthday_messages where event_id = p_event and sender_id = uid) >= cap then
    raise exception 'You have already left % wishes here.', cap using errcode = 'check_violation';
  end if;

  insert into public.staff_birthday_messages (event_id, sender_id, recipient_id, body)
  values (p_event, uid, ev.user_id, text_body) returning id into new_id;

  select display_name into sender_name from public.profiles where id = uid;
  perform public.notify(ev.user_id, 'staff', 'birthday.message', 'A birthday wish from ' || sender_name,
    'Open your board to read it.', '/admin/birthdays/' || p_event::text, 'birthday.message:' || new_id::text);
  return new_id;
end;
$$;

create function public.my_birthday_events()
returns table (event_id uuid, event_date date, message_count integer)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  return query
  select e.id, e.event_date, (select count(*)::integer from public.staff_birthday_messages m where m.event_id = e.id and m.hidden_at is null)
    from public.staff_birthday_events e where e.user_id = (select auth.uid()) order by e.event_date desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reporting and moderation (moderators, or technical admins, with two-factor)
-- ---------------------------------------------------------------------------

create function public.report_birthday_message(p_message uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  m public.staff_birthday_messages;
begin
  select * into m from public.staff_birthday_messages where id = p_message;
  if not found or not public.bd_can_view(m.event_id) then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if m.sender_id = (select auth.uid()) then
    raise exception 'You cannot report your own message.' using errcode = 'check_violation';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) not between 3 and 300 then
    raise exception 'Say briefly what is wrong (3 to 300 characters).' using errcode = 'check_violation';
  end if;
  perform public.enforce_rate_limit('birthday_report', 10, 60);
  insert into public.staff_birthday_reports (message_id, reporter_id, reason)
  values (p_message, (select auth.uid()), btrim(p_reason))
  on conflict (message_id, reporter_id) do nothing;
end;
$$;

create function public.birthday_reports_queue()
returns table (report_id uuid, message_id uuid, body text, sender_name text, reporter_name text, reason text, event_date date, birthday_person text, created_at timestamptz, message_hidden boolean)
language plpgsql security definer set search_path = ''
as $$
begin
  if not (public.has_staff_role('moderator') or public.has_staff_role('tech_admin')) then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  return query
  select r.id, m.id, m.body, sp.display_name, rp.display_name, r.reason, e.event_date, bp.display_name, r.created_at, m.hidden_at is not null
    from public.staff_birthday_reports r
    join public.staff_birthday_messages m on m.id = r.message_id
    join public.staff_birthday_events e on e.id = m.event_id
    join public.profiles sp on sp.id = m.sender_id
    join public.profiles rp on rp.id = r.reporter_id
    join public.profiles bp on bp.id = e.user_id
   where r.status = 'open'
   order by r.created_at;
end;
$$;

create function public.resolve_birthday_report(p_report uuid, p_action text, p_note text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  r public.staff_birthday_reports;
  m public.staff_birthday_messages;
begin
  if not (public.has_staff_role('moderator') or public.has_staff_role('tech_admin')) then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if p_action not in ('hide', 'dismiss') then
    raise exception 'Choose hide or dismiss.' using errcode = 'check_violation';
  end if;
  if p_note is null or char_length(btrim(p_note)) < 3 then
    raise exception 'Write a short reason. It is saved in the audit log.' using errcode = 'check_violation';
  end if;
  select * into r from public.staff_birthday_reports where id = p_report for update;
  if not found or r.status <> 'open' then
    raise exception 'This report is already decided.' using errcode = 'check_violation';
  end if;
  select * into m from public.staff_birthday_messages where id = r.message_id;
  if m.sender_id = uid or r.reporter_id = uid then
    raise exception 'You cannot decide a report you are part of.' using errcode = 'insufficient_privilege';
  end if;

  if p_action = 'hide' then
    update public.staff_birthday_messages
       set hidden_at = coalesce(hidden_at, now()), hidden_by = coalesce(hidden_by, uid), hidden_reason = coalesce(hidden_reason, left(btrim(p_note), 300))
     where id = m.id;
    update public.staff_birthday_reports set status = 'actioned', decided_by = uid, decided_at = now(), decision_note = left(btrim(p_note), 300)
     where message_id = m.id and status = 'open';
  else
    update public.staff_birthday_reports set status = 'dismissed', decided_by = uid, decided_at = now(), decision_note = left(btrim(p_note), 300)
     where id = p_report;
  end if;
  perform public.write_audit('staff_birthday.report_' || p_action, 'staff_birthday_message', m.id::text, jsonb_build_object('report', p_report));
end;
$$;

-- Who has been reading the birthday calendar and boards. Technical admins only.
create function public.staff_birthday_access_log(p_limit integer default 100)
returns table (viewer_name text, action text, event_id uuid, created_at timestamptz)
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('tech_admin') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  return query
  select pr.display_name, l.action, l.event_id, l.created_at
    from public.staff_birthday_access_logs l left join public.profiles pr on pr.id = l.viewer_id
   order by l.id desc limit least(greatest(coalesce(p_limit, 100), 1), 500);
end;
$$;

-- ---------------------------------------------------------------------------
-- Function permissions: closed first, then opened on purpose
-- ---------------------------------------------------------------------------

revoke execute on function
  public.bd_guard_message(), public.org_timezone(), public.bd_need_staff(), public.bd_is_active_staff(uuid),
  public.bd_is_leap(integer), public.bd_date_in_year(integer, integer, integer), public.bd_today(),
  public.bd_log_access(text, uuid), public.bd_can_view(uuid),
  public.run_staff_birthdays(timestamptz), public.purge_old_birthday_access_logs(),
  public.my_birthday_profile(), public.set_my_birthday(integer, integer, text, boolean, text), public.clear_my_birthday(),
  public.staff_birthdays_today(), public.staff_birthdays_upcoming(integer), public.staff_birthdays_month(integer),
  public.birthday_event(uuid), public.birthday_messages(uuid), public.send_birthday_message(uuid, text), public.my_birthday_events(),
  public.report_birthday_message(uuid, text), public.birthday_reports_queue(), public.resolve_birthday_report(uuid, text, text),
  public.staff_birthday_access_log(integer)
from public, anon, authenticated;

grant execute on function
  public.my_birthday_profile(), public.set_my_birthday(integer, integer, text, boolean, text), public.clear_my_birthday(),
  public.staff_birthdays_today(), public.staff_birthdays_upcoming(integer), public.staff_birthdays_month(integer),
  public.birthday_event(uuid), public.birthday_messages(uuid), public.send_birthday_message(uuid, text), public.my_birthday_events(),
  public.report_birthday_message(uuid, text), public.birthday_reports_queue(), public.resolve_birthday_report(uuid, text, text),
  public.staff_birthday_access_log(integer)
to authenticated;

grant execute on function public.run_staff_birthdays(timestamptz), public.purge_old_birthday_access_logs() to service_role;
