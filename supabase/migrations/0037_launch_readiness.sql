-- 0037: launch readiness.
--   1. Error log: the app reports its own crashes here, so a problem on someone else's phone is seen by the team.
--   2. Staff health summary: one read-only page of numbers for technical admins.
--   3. Reply speed: "usually replies within an hour" worked out from real chats, never typed in by a seller.
--   4. Delete my account: for buyers. Personal details are scrubbed and sign-in is switched off; orders and chats stay,
--      shown under the name "Deleted user", because the other person in each order still needs their record.
--   5. Invite codes: a person shares a code; the table counts who joined with it. No reward is attached.
--   6. Terms acceptance: which version of the terms a person agreed to, and when.

-- ---------------------------------------------------------------------------
-- 1. Error log
-- ---------------------------------------------------------------------------
create table public.client_errors (
  id bigint generated always as identity primary key,
  fingerprint text not null,
  hour timestamptz not null,
  user_id uuid references public.profiles (id) on delete set null,
  platform text not null check (platform in ('android', 'ios', 'web', 'unknown')),
  app_version text,
  route text,
  message text not null,
  stack text,
  occurrences integer not null default 1,
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  unique (fingerprint, hour)
);
create index client_errors_last_seen_idx on public.client_errors (last_seen desc);
create index client_errors_user_idx on public.client_errors (user_id);
alter table public.client_errors enable row level security;
-- No grants and no policies: written only by report_client_error, read only by staff_health_summary.

-- The app calls this when it crashes. Guests can call it too, because the crash may happen before anyone signs in.
-- The same error in the same hour is counted, not stored again, and at most 500 different errors are kept per hour, so
-- nobody can fill the table. It never raises an error to the caller: reporting a problem must not cause another one.
create function public.report_client_error(
  p_message text, p_stack text default null, p_route text default null, p_platform text default 'unknown', p_app_version text default null
) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  msg text := left(btrim(coalesce(p_message, '')), 500);
  hr timestamptz := date_trunc('hour', now());
  fp text;
  plat text := case when p_platform in ('android', 'ios', 'web') then p_platform else 'unknown' end;
begin
  if msg = '' then return; end if;
  fp := md5(msg || '|' || coalesce(left(p_stack, 300), ''));
  if (select count(*) from public.client_errors where hour = hr) >= 500
     and not exists (select 1 from public.client_errors where fingerprint = fp and hour = hr) then
    return;
  end if;
  insert into public.client_errors (fingerprint, hour, user_id, platform, app_version, route, message, stack)
  values (fp, hr, (select auth.uid()), plat, left(p_app_version, 40), left(p_route, 200), msg, left(p_stack, 2000))
  on conflict (fingerprint, hour) do update
    set occurrences = public.client_errors.occurrences + 1, last_seen = now();
exception when others then
  return;
end;
$$;

-- Old entries are deleted after 30 days. Schedule it like the other purges (docs/SCHEDULED_JOBS.md).
create function public.purge_old_client_errors() returns integer
language plpgsql security definer set search_path = ''
as $$
declare n integer;
begin
  delete from public.client_errors where last_seen < now() - interval '30 days';
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Staff health summary
-- ---------------------------------------------------------------------------
create function public.staff_health_summary() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  top jsonb;
begin
  if not public.has_staff_role('tech_admin') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  select coalesce(jsonb_agg(t order by t.total desc), '[]') into top from (
    select message, route, platform, sum(occurrences)::integer as total, max(last_seen) as last_seen
      from public.client_errors where last_seen > now() - interval '24 hours'
     group by message, route, platform order by sum(occurrences) desc limit 5
  ) t;
  return jsonb_build_object(
    'errors_24h', (select coalesce(sum(occurrences), 0) from public.client_errors where last_seen > now() - interval '24 hours'),
    'error_kinds_24h', (select count(distinct fingerprint) from public.client_errors where last_seen > now() - interval '24 hours'),
    'top_errors', top,
    'tickets_late', (select count(*) from public.support_tickets where status in ('open', 'in_progress', 'waiting_on_customer', 'escalated') and due_at < now()),
    'tickets_unassigned', (select count(*) from public.support_tickets where status in ('open', 'escalated') and assigned_to is null),
    'seller_applications_waiting', (select count(*) from public.seller_applications where status in ('submitted', 'under_review')),
    'listings_waiting', (select count(*) from public.listings where moderation_status = 'pending' and status <> 'removed'),
    'reports_open', (select count(*) from public.reports where status in ('open', 'in_review')),
    'disputes_open', (select count(*) from public.disputes where status in ('open', 'awaiting_info')),
    'notifications_failed_24h', (select count(*) from public.notification_deliveries where status in ('failed', 'dead') and created_at > now() - interval '24 hours'),
    'checked_at', now()
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Reply speed, from real chats
-- ---------------------------------------------------------------------------
-- For each chat started in the last 90 days (and at least a day ago, so the seller has had time), the wait between the
-- buyer's first message and the seller's first answer. A chat the seller never answered counts as 100 hours. The badge
-- needs at least 5 such chats, so one lucky answer never earns it. Only the word is returned, never the chats.
create function public.seller_reply_speed(p_seller uuid) returns text
language sql stable security definer set search_path = ''
as $$
  with firsts as (
    select c.id,
           (select min(m.created_at) from public.messages m where m.conversation_id = c.id and m.sender_id = c.buyer_id) as asked,
           c.seller_id
      from public.conversations c
     where c.seller_id = p_seller and c.created_at > now() - interval '90 days'
  ), waits as (
    select f.id,
           coalesce(extract(epoch from (
             (select min(m.created_at) from public.messages m where m.conversation_id = f.id and m.sender_id = f.seller_id and m.created_at >= f.asked) - f.asked
           )) / 3600.0, 100.0) as hours
      from firsts f
     where f.asked is not null and f.asked < now() - interval '1 day'
  ), stats as (
    select count(*) as n, percentile_cont(0.5) within group (order by hours) as median from waits
  )
  select case when n < 5 then null when median <= 1 then 'within_an_hour' when median <= 24 then 'within_a_day' else null end from stats
$$;

-- ---------------------------------------------------------------------------
-- 4. Delete my account
-- ---------------------------------------------------------------------------
alter table public.profiles add column deleted_at timestamptz;

create function public.account_delete(p_reason text default null) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  prof public.profiles;
  open_orders integer;
  biz record;
  why text := left(nullif(btrim(coalesce(p_reason, '')), ''), 300);
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;
  select * into prof from public.profiles where id = uid for update;
  if not found or prof.deleted_at is not null then
    raise exception 'This account is already deleted.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.admin_roles where user_id = uid) then
    raise exception 'Staff accounts are removed by a technical administrator, not here.' using errcode = 'check_violation';
  end if;

  select count(*) into open_orders from public.orders
   where (buyer_id = uid or seller_id = uid) and status in ('requested', 'confirmed', 'disputed');
  if open_orders > 0 then
    raise exception 'Finish or cancel your % open order(s) first, then delete your account.', open_orders using errcode = 'check_violation';
  end if;

  -- Businesses you own are deleted first (their own checks apply), then your selling account.
  for biz in select id from public.businesses where owner_id = uid loop
    perform public.business_close(biz.id, 'Owner deleted their account');
  end loop;
  if prof.seller_status <> 'none' then
    begin
      perform public.seller_account_close('Account deleted');
    exception when others then
      -- A revoked seller cannot close the selling account; the account is still deleted and the revoked state stays on record.
      null;
    end;
  end if;

  -- Personal details and private lists go. Orders, chats, reviews and verification history stay, under a neutral name.
  update public.profiles
     set display_name = 'Deleted user', bio = null, avatar_path = null, location_id = null, deleted_at = now()
   where id = uid;
  delete from public.saved_addresses where user_id = uid;
  delete from public.favourites where user_id = uid;
  delete from public.saved_searches where user_id = uid;
  delete from public.listing_views where viewer_id = uid;
  delete from public.push_tokens where user_id = uid;
  delete from public.notification_preferences where user_id = uid;
  delete from public.notifications where user_id = uid;

  -- Switch sign-in off and remove the email and phone, when the auth tables allow it (they do on Supabase).
  if exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'banned_until') then
    execute format($f$update auth.users set banned_until = 'infinity', email = %L, phone = null, raw_user_meta_data = '{}'::jsonb where id = %L$f$,
                   'deleted-' || uid || '@deleted.invalid', uid);
  else
    update auth.users set email = 'deleted-' || uid || '@deleted.invalid', phone = null, raw_user_meta_data = '{}'::jsonb where id = uid;
  end if;

  perform public.write_audit('account.deleted', 'profile', uid::text, jsonb_build_object('reason', why));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Invite codes
-- ---------------------------------------------------------------------------
create table public.referral_codes (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  code text not null unique check (code ~ '^[A-HJ-NP-Z2-9]{8}$'),
  created_at timestamptz not null default now()
);
create table public.referrals (
  referred_user uuid primary key references public.profiles (id) on delete cascade,
  code_owner uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  check (referred_user <> code_owner)
);
create index referrals_owner_idx on public.referrals (code_owner);
alter table public.referral_codes enable row level security;
alter table public.referrals enable row level security;
-- No grants: reached only through the functions below.

create function public.referral_code_mine() returns text
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  existing text;
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  candidate text;
  tries integer := 0;
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;
  select code into existing from public.referral_codes where user_id = uid;
  if existing is not null then return existing; end if;
  loop
    candidate := (select string_agg(substr(alphabet, 1 + floor(random() * 32)::integer, 1), '') from generate_series(1, 8));
    begin
      insert into public.referral_codes (user_id, code) values (uid, candidate);
      return candidate;
    exception when unique_violation then
      tries := tries + 1;
      if tries > 10 then raise exception 'Could not make a code. Try again.'; end if;
    end;
  end loop;
end;
$$;

-- A new person enters a friend's code once, within 30 days of joining. No reward is attached; it only counts.
create function public.referral_redeem(p_code text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  owner uuid;
  joined timestamptz;
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;
  select created_at into joined from public.profiles where id = uid;
  if joined is null or joined < now() - interval '30 days' then
    raise exception 'Invite codes can only be used in your first 30 days.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.referrals where referred_user = uid) then
    raise exception 'You have already used an invite code.' using errcode = 'check_violation';
  end if;
  select user_id into owner from public.referral_codes where code = upper(btrim(coalesce(p_code, '')));
  if owner is null then
    raise exception 'That invite code was not found.' using errcode = 'no_data_found';
  end if;
  if owner = uid then
    raise exception 'You cannot use your own invite code.' using errcode = 'check_violation';
  end if;
  insert into public.referrals (referred_user, code_owner) values (uid, owner);
end;
$$;

create function public.referral_count() returns integer
language sql stable security definer set search_path = ''
as $$ select count(*)::integer from public.referrals where code_owner = (select auth.uid()) $$;

-- ---------------------------------------------------------------------------
-- 6. Terms acceptance
-- ---------------------------------------------------------------------------
alter table public.profiles add column terms_version text, add column terms_accepted_at timestamptz;

-- The sign-up trigger now also records the terms version the app sends in the sign-up details (accepted_terms_version).
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  chosen text := left(btrim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), 60);
  terms text := left(nullif(btrim(coalesce(new.raw_user_meta_data ->> 'accepted_terms_version', '')), ''), 20);
begin
  if char_length(chosen) < 2 then
    chosen := left(split_part(coalesce(new.email, ''), '@', 1), 60);
  end if;
  if char_length(chosen) < 2 then
    chosen := 'Member ' || substr(new.id::text, 1, 6);
  end if;

  insert into public.profiles (id, display_name, terms_version, terms_accepted_at)
  values (new.id, chosen, terms, case when terms is null then null else now() end);
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------------
revoke execute on function
  public.report_client_error(text, text, text, text, text), public.purge_old_client_errors(), public.staff_health_summary(),
  public.seller_reply_speed(uuid), public.account_delete(text), public.referral_code_mine(), public.referral_redeem(text),
  public.referral_count()
  from public, anon, authenticated;
grant execute on function public.report_client_error(text, text, text, text, text) to anon, authenticated;
grant execute on function public.seller_reply_speed(uuid) to anon, authenticated;
grant execute on function public.staff_health_summary(), public.account_delete(text), public.referral_code_mine(),
  public.referral_redeem(text), public.referral_count() to authenticated;
grant execute on function public.purge_old_client_errors() to service_role;
