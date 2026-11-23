-- 0012: Notifications (Module E)
--
--   * An in-app inbox with unread counts and history (table notifications).
--   * Per-category preferences for push, email and SMS (muting a category mutes everything for it).
--   * Push tokens, and a delivery queue with leases, retries with back-off, a dead state and token clean-up.
--   * Events that create notifications: orders, messages, search alerts, verification decisions,
--     account state, listing moderation, business invitations and low stock.
--   * Duplicate-event prevention: one row per (user, dedupe key).
--
-- What is NOT here, on purpose:
--   * Email and SMS are not sent. No provider has been chosen, and nothing pretends otherwise. The channels exist
--     in the queue and in preferences, and are switched off by platform settings
--     (notifications.email_enabled, notifications.sms_enabled = 0) until a provider is connected.
--   * Sending push happens in the Edge Function supabase/functions/send-notifications. It is not scheduled yet.
--
-- Rules:
--   * Messages never put the text of a message in a notification, only who it is about.
--   * Account notices (suspension, restriction, reinstatement) cannot be muted.
--   * Tables have no write grants for app users. Functions are closed first, then opened on purpose.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  category text not null check (category in ('orders', 'messages', 'alerts', 'listings', 'business', 'account')),
  type text not null check (char_length(type) between 3 and 60),
  title text not null check (char_length(title) between 1 and 120),
  body text check (char_length(body) <= 300),
  link text check (char_length(link) <= 200 and link ~ '^/[A-Za-z0-9/_.-]*$' and link !~ '\.\.'),
  dedupe_key text not null check (char_length(dedupe_key) between 1 and 200),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  unique (user_id, dedupe_key)
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_unread_idx on public.notifications (user_id) where read_at is null;
alter table public.notifications enable row level security;
grant select on public.notifications to authenticated;
create policy notifications_own_read on public.notifications
  for select to authenticated using (user_id = (select auth.uid()));

create table public.notification_preferences (
  user_id uuid not null references public.profiles (id) on delete cascade,
  category text not null check (category in ('orders', 'messages', 'alerts', 'listings', 'business', 'account')),
  in_app boolean not null default true,
  push boolean not null default true,
  email boolean not null default false,
  sms boolean not null default false,
  primary key (user_id, category),
  check (category <> 'account' or (in_app and push))
);
alter table public.notification_preferences enable row level security;
grant select on public.notification_preferences to authenticated;
create policy notification_prefs_own_read on public.notification_preferences
  for select to authenticated using (user_id = (select auth.uid()));

create table public.push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  token text not null unique check (char_length(token) between 10 and 300),
  platform text not null check (platform in ('android', 'ios', 'web')),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  disabled_at timestamptz
);
create index push_tokens_user_idx on public.push_tokens (user_id) where disabled_at is null;
alter table public.push_tokens enable row level security;
-- No grants: tokens are written through register_push_token and read only by the sending worker.

create table public.notification_deliveries (
  id bigint generated always as identity primary key,
  notification_id uuid not null references public.notifications (id) on delete cascade,
  channel text not null check (channel in ('push', 'email', 'sms')),
  push_token_id uuid references public.push_tokens (id) on delete set null,
  status text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'dead', 'skipped')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  locked_until timestamptz,
  last_error text check (char_length(last_error) <= 500),
  provider_ref text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create unique index notification_deliveries_once on public.notification_deliveries
  (notification_id, channel, coalesce(push_token_id, '00000000-0000-0000-0000-000000000000'::uuid));
create index notification_deliveries_due_idx on public.notification_deliveries (next_attempt_at)
  where status in ('pending', 'failed', 'sending');
alter table public.notification_deliveries enable row level security;
-- No grants: only the worker functions below touch the queue.

insert into public.platform_settings (key, value, note) values
  ('notifications.email_enabled', '0', 'Set to 1 only after an email provider is connected to the sending worker.'),
  ('notifications.sms_enabled', '0', 'Set to 1 only after an SMS provider is connected to the sending worker.'),
  ('notifications.max_attempts', '5', 'Delivery attempts before a notification is given up on. Starter value.'),
  ('notifications.message_push_gap_minutes', '5', 'A second message push for the same chat is held back for this long while the first is unread. Starter value.')
on conflict (key) do nothing;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.notifications;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- The one place a notification is made
-- ---------------------------------------------------------------------------

-- Returns the new notification id, or null when it was muted or already sent (same user and dedupe key).
create function public.notify(
  p_user uuid, p_category text, p_type text, p_title text, p_body text, p_link text, p_dedupe text
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  pref public.notification_preferences;
  want_in_app boolean := true;
  want_push boolean := true;
  want_email boolean := false;
  want_sms boolean := false;
  new_id uuid;
  gap integer := public.setting_numeric('notifications.message_push_gap_minutes', 5)::integer;
begin
  if p_user is null or not exists (select 1 from public.profiles where id = p_user) then
    return null;
  end if;

  select * into pref from public.notification_preferences where user_id = p_user and category = p_category;
  if found then
    want_in_app := pref.in_app; want_push := pref.push; want_email := pref.email; want_sms := pref.sms;
  end if;
  if p_category = 'account' then
    want_in_app := true; want_push := true;
  end if;
  if not want_in_app then
    return null;
  end if;

  insert into public.notifications (user_id, category, type, title, body, link, dedupe_key)
  values (p_user, p_category, p_type, left(p_title, 120), left(p_body, 300), p_link, p_dedupe)
  on conflict (user_id, dedupe_key) do nothing
  returning id into new_id;
  if new_id is null then
    return null;
  end if;

  if want_push and not (
    p_type = 'message.new' and exists (
      select 1 from public.notifications o
       where o.user_id = p_user and o.type = p_type and o.link is not distinct from p_link
         and o.read_at is null and o.id <> new_id and o.created_at > now() - make_interval(mins => gap))
  ) then
    insert into public.notification_deliveries (notification_id, channel, push_token_id)
    select new_id, 'push', t.id from public.push_tokens t where t.user_id = p_user and t.disabled_at is null;
  end if;

  if want_email and public.setting_numeric('notifications.email_enabled', 0) = 1
     and exists (select 1 from auth.users u where u.id = p_user and u.email is not null and u.email_confirmed_at is not null) then
    insert into public.notification_deliveries (notification_id, channel) values (new_id, 'email');
  end if;
  if want_sms and public.setting_numeric('notifications.sms_enabled', 0) = 1
     and exists (select 1 from auth.users u where u.id = p_user and u.phone is not null and u.phone_confirmed_at is not null) then
    insert into public.notification_deliveries (notification_id, channel) values (new_id, 'sms');
  end if;

  return new_id;
end;
$$;

-- The people on the selling side of an order: the seller and, for a business order, its team.
create function public.order_seller_side(p_order_id uuid)
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select o.seller_id from public.orders o where o.id = p_order_id
  union
  select m.user_id from public.orders o join public.business_members m on m.business_id = o.business_id where o.id = p_order_id;
$$;

-- ---------------------------------------------------------------------------
-- Events that create notifications
-- ---------------------------------------------------------------------------

-- Orders: one trigger on the order history, which every order action already writes to.
create function public.notify_order_event()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders;
  to_seller boolean := false;
  to_buyer boolean := false;
  heading text;
  who uuid;
begin
  select * into o from public.orders where id = new.order_id;
  if not found then
    return new;
  end if;

  case new.event
    when 'requested' then to_seller := true; heading := 'New order request';
    when 'confirmed' then to_buyer := true; heading := 'Your order was confirmed';
    when 'declined' then to_buyer := true; heading := 'Your request was declined';
    when 'cancelled' then
      heading := 'An order was cancelled';
      if new.actor_role = 'buyer' then to_seller := true; else to_buyer := true; end if;
    when 'expired' then to_seller := true; to_buyer := true; heading := 'An order expired';
    when 'handed_over' then to_buyer := true; heading := 'Item handed over. Please confirm you have it';
    when 'completed' then to_seller := true; heading := 'An order was completed';
    when 'auto_completed' then to_seller := true; to_buyer := true; heading := 'An order was completed automatically';
    when 'disputed' then
      heading := 'A dispute was opened';
      if new.actor_role = 'buyer' then to_seller := true; else to_buyer := true; end if;
    when 'settled_by_staff' then to_seller := true; to_buyer := true; heading := 'Staff settled an order';
    else return new;
  end case;

  if to_buyer and o.buyer_id is distinct from new.actor_id then
    perform public.notify(o.buyer_id, 'orders', 'order.' || new.event, heading, o.item_title,
      '/order/' || o.id, 'order_event:' || new.id || ':' || o.buyer_id);
  end if;
  if to_seller then
    for who in select public.order_seller_side(o.id) loop
      if who is distinct from new.actor_id then
        perform public.notify(who, 'orders', 'order.' || new.event, heading, o.item_title,
          '/order/' || o.id, 'order_event:' || new.id || ':' || who);
      end if;
    end loop;
  end if;
  return new;
end;
$$;
create trigger order_events_notify after insert on public.order_events
  for each row execute function public.notify_order_event();

-- Messages: who it is about, never what it says.
create function public.notify_new_message()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  c public.conversations;
  listing_title text;
  who uuid;
begin
  select * into c from public.conversations where id = new.conversation_id;
  select title into listing_title from public.listings where id = c.listing_id;

  for who in
    select u from (
      select c.buyer_id as u where new.sender_id <> c.buyer_id
      union
      select c.seller_id where new.sender_id = c.buyer_id
      union
      select m.user_id from public.business_members m where m.business_id = c.business_id and new.sender_id = c.buyer_id
    ) r
    where u <> new.sender_id
      and not exists (select 1 from public.blocks b where b.blocker_id = r.u and b.blocked_id = new.sender_id)
  loop
    perform public.notify(who, 'messages', 'message.new', 'New message', 'About ' || coalesce(listing_title, 'a listing'),
      '/chat/' || c.id, 'message:' || new.id || ':' || who);
  end loop;
  return new;
end;
$$;
create trigger messages_notify after insert on public.messages
  for each row execute function public.notify_new_message();

-- Saved-search alerts
create function public.notify_listing_alert()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  search_name text;
  listing_title text;
begin
  select name into search_name from public.saved_searches where id = new.saved_search_id;
  select title into listing_title from public.listings where id = new.listing_id;
  perform public.notify(new.user_id, 'alerts', 'alert.match', 'New match: ' || coalesce(search_name, 'your search'),
    listing_title, '/listing/' || new.listing_id, 'alert:' || new.id);
  return new;
end;
$$;
create trigger listing_alerts_notify after insert on public.listing_alerts
  for each row execute function public.notify_listing_alert();

-- Verification decisions
create function public.notify_identity_decision()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.status = 'pending' and new.status in ('approved', 'rejected') then
    perform public.notify(new.user_id, 'account', 'verification.identity',
      case when new.status = 'approved' then 'Your ID check was approved' else 'Your ID check was not approved' end,
      case when new.status = 'rejected' then new.reviewer_note end,
      '/verify', 'identity:' || new.id || ':' || new.status);
  end if;
  return new;
end;
$$;
create trigger identity_verifications_notify after update of status on public.identity_verifications
  for each row execute function public.notify_identity_decision();

create function public.notify_business_decision()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  owner uuid;
  biz text;
begin
  if old.status = 'pending' and new.status in ('approved', 'rejected') then
    select owner_id, name into owner, biz from public.businesses where id = new.business_id;
    perform public.notify(owner, 'account', 'verification.business',
      case when new.status = 'approved' then biz || ' was verified' else biz || ' was not verified' end,
      case when new.status = 'rejected' then new.reviewer_note end,
      '/verify', 'business:' || new.id || ':' || new.status);
  end if;
  return new;
end;
$$;
create trigger business_verifications_notify after update of status on public.business_verifications
  for each row execute function public.notify_business_decision();

-- Account state. These cannot be muted.
create function public.notify_account_state()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.account_state is distinct from new.account_state then
    perform public.notify(new.id, 'account', 'account.state',
      case new.account_state
        when 'suspended' then 'Your account was suspended'
        when 'restricted' then 'Your account was restricted'
        else 'Your account is active again' end,
      'Open your account for details.', '/account',
      'account_state:' || new.id || ':' || new.account_state || ':' || (extract(epoch from clock_timestamp()) * 1000000)::bigint);
  end if;
  return new;
end;
$$;
create trigger profiles_account_state_notify after update of account_state on public.profiles
  for each row execute function public.notify_account_state();

-- Listing moderation: a rejection always, an approval only when a moderator did it
-- (publishing approves most listings automatically, and that is not worth a notification).
create function public.notify_moderation()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.moderation_status is distinct from new.moderation_status then
    if new.moderation_status = 'rejected' then
      perform public.notify(new.seller_id, 'listings', 'listing.rejected', 'A listing was not approved', new.title,
        '/account', 'moderation:' || new.id || ':rejected:' || (extract(epoch from clock_timestamp()) * 1000000)::bigint);
    elsif new.moderation_status = 'approved' and old.moderation_status in ('pending', 'rejected') and public.is_staff() then
      perform public.notify(new.seller_id, 'listings', 'listing.approved', 'Your listing was approved', new.title,
        '/listing/' || new.id, 'moderation:' || new.id || ':approved:' || (extract(epoch from clock_timestamp()) * 1000000)::bigint);
    end if;
  end if;
  return new;
end;
$$;
create trigger listings_moderation_notify after update on public.listings
  for each row when (old.moderation_status is distinct from new.moderation_status)
  execute function public.notify_moderation();

-- Business invitations: if the email already belongs to an account, tell that person.
create function public.notify_business_invitation()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  invitee uuid;
  biz text;
begin
  select u.id into invitee from auth.users u where lower(u.email) = new.email and u.email_confirmed_at is not null limit 1;
  if invitee is not null then
    select name into biz from public.businesses where id = new.business_id;
    perform public.notify(invitee, 'business', 'business.invited', 'You were invited to join ' || biz,
      'Open to accept or decline.', '/business/invitations', 'invitation:' || new.id);
  end if;
  return new;
end;
$$;
create trigger business_invitations_notify after insert on public.business_invitations
  for each row execute function public.notify_business_invitation();

-- Low stock: only when the count crosses the line, so one notification per drop.
create function public.notify_low_stock()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  listing_title text;
  who uuid;
begin
  if old.quantity > old.low_stock_at and new.quantity <= new.low_stock_at then
    select title into listing_title from public.listings where id = new.listing_id;
    for who in
      select m.user_id from public.business_members m where m.business_id = new.business_id and m.role in ('owner', 'manager')
    loop
      perform public.notify(who, 'business', 'business.low_stock',
        case when new.quantity = 0 then 'Out of stock' else 'Running low on stock' end,
        listing_title || ': ' || new.quantity || ' left',
        '/business/manage/' || new.business_id || '/inventory',
        'low_stock:' || new.listing_id || ':' || (extract(epoch from clock_timestamp()) * 1000000)::bigint || ':' || who);
    end loop;
  end if;
  return new;
end;
$$;
create trigger listing_stock_notify after update of quantity on public.listing_stock
  for each row execute function public.notify_low_stock();

-- ---------------------------------------------------------------------------
-- Functions the app calls
-- ---------------------------------------------------------------------------

create function public.unread_notification_count()
returns integer
language sql stable security definer set search_path = ''
as $$
  select count(*)::integer from public.notifications where user_id = (select auth.uid()) and read_at is null;
$$;

create function public.mark_notifications_read(p_ids uuid[])
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  n integer;
begin
  update public.notifications set read_at = now()
   where user_id = (select auth.uid()) and id = any (coalesce(p_ids, '{}')) and read_at is null;
  get diagnostics n = row_count;
  return n;
end;
$$;

create function public.mark_all_notifications_read(p_category text default null)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  n integer;
begin
  update public.notifications set read_at = now()
   where user_id = (select auth.uid()) and read_at is null and (p_category is null or category = p_category);
  get diagnostics n = row_count;
  return n;
end;
$$;

-- All categories with defaults filled in, so the app does not have to know the defaults.
create function public.my_notification_settings()
returns table (category text, in_app boolean, push boolean, email boolean, sms boolean)
language sql stable security definer set search_path = ''
as $$
  select c.category,
         coalesce(p.in_app, true), coalesce(p.push, true), coalesce(p.email, false), coalesce(p.sms, false)
    from unnest(array['orders', 'messages', 'alerts', 'listings', 'business', 'account']) with ordinality as c(category, n)
    left join public.notification_preferences p on p.user_id = (select auth.uid()) and p.category = c.category
   order by c.n;
$$;

create function public.set_notification_preference(p_category text, p_in_app boolean, p_push boolean, p_email boolean, p_sms boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if p_category not in ('orders', 'messages', 'alerts', 'listings', 'business', 'account') then
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

-- Which channels can actually deliver right now, so the settings screen does not promise what is not built.
create function public.notification_channels()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'push', true,
    'email', public.setting_numeric('notifications.email_enabled', 0) = 1,
    'sms', public.setting_numeric('notifications.sms_enabled', 0) = 1);
$$;

-- A token belongs to whoever registered it last: signing into another account on the same phone
-- moves it, so the previous person stops receiving pushes meant for the new one.
create function public.register_push_token(p_token text, p_platform text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if p_platform not in ('android', 'ios', 'web') or char_length(coalesce(p_token, '')) not between 10 and 300 then
    raise exception 'That does not look like a push token.' using errcode = 'invalid_parameter_value';
  end if;

  insert into public.push_tokens (user_id, token, platform, last_seen_at) values (uid, p_token, p_platform, clock_timestamp())
  on conflict (token) do update set user_id = uid, platform = excluded.platform, last_seen_at = clock_timestamp(), disabled_at = null;

  -- At most 10 live tokens per person: the least recently seen ones are switched off.
  update public.push_tokens set disabled_at = now()
   where id in (
     select id from public.push_tokens where user_id = uid and disabled_at is null
      order by last_seen_at desc offset 10);
end;
$$;

create function public.unregister_push_token(p_token text)
returns void
language sql security definer set search_path = ''
as $$
  update public.push_tokens set disabled_at = now() where token = p_token and user_id = (select auth.uid()) and disabled_at is null;
$$;

-- ---------------------------------------------------------------------------
-- Worker functions (service role only)
-- ---------------------------------------------------------------------------

-- Hands out due deliveries and leases them for two minutes. Safe to run from several workers at once.
create function public.claim_notification_deliveries(p_limit integer default 50)
returns table (
  delivery_id bigint, notification_id uuid, channel text, user_id uuid,
  token text, title text, body text, link text, attempts integer
)
language plpgsql security definer set search_path = ''
as $$
declare
  max_attempts integer := public.setting_numeric('notifications.max_attempts', 5)::integer;
begin
  -- A worker that died mid-send: out of attempts means dead, otherwise it is picked up again below.
  update public.notification_deliveries d
     set status = 'dead', last_error = coalesce(d.last_error, 'The worker did not report back.')
   where d.status = 'sending' and d.locked_until < now() and d.attempts >= max_attempts;

  -- No point pushing something the person already read, or to a token that was switched off.
  update public.notification_deliveries d set status = 'skipped', last_error = 'Already read.'
   where d.status in ('pending', 'failed') and d.channel = 'push' and d.next_attempt_at <= now()
     and exists (select 1 from public.notifications n where n.id = d.notification_id and n.read_at is not null);
  -- A token that was switched off, or that has since moved to someone else's account, must not get this.
  update public.notification_deliveries d set status = 'skipped', last_error = 'Token switched off or moved to another account.'
   where d.status in ('pending', 'failed') and d.channel = 'push' and d.next_attempt_at <= now()
     and not exists (
       select 1 from public.push_tokens t join public.notifications n on n.id = d.notification_id
        where t.id = d.push_token_id and t.disabled_at is null and t.user_id = n.user_id);

  return query
    with picked as (
      select d.id from public.notification_deliveries d
       where ((d.status in ('pending', 'failed') and d.next_attempt_at <= now())
              or (d.status = 'sending' and d.locked_until < now()))
         and d.attempts < max_attempts
       order by d.next_attempt_at, d.id
       limit least(greatest(coalesce(p_limit, 50), 1), 200)
       for update skip locked
    ), leased as (
      update public.notification_deliveries d
         set status = 'sending', attempts = d.attempts + 1, locked_until = now() + interval '2 minutes'
        from picked where d.id = picked.id
      returning d.id, d.notification_id, d.channel, d.push_token_id, d.attempts
    )
    select l.id, l.notification_id, l.channel, n.user_id, t.token, n.title, n.body, n.link, l.attempts
      from leased l
      join public.notifications n on n.id = l.notification_id
      left join public.push_tokens t on t.id = l.push_token_id
     order by l.id;
end;
$$;

-- The worker reports how each send went. A failure is retried later (1, 5, 30, 120 minutes, then 12 hours)
-- until the attempts run out; then it is marked dead and left for someone to look at.
create function public.report_notification_delivery(
  p_id bigint, p_ok boolean, p_error text default null, p_provider_ref text default null,
  p_retry boolean default true, p_disable_token boolean default false
)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  d public.notification_deliveries;
  max_attempts integer := public.setting_numeric('notifications.max_attempts', 5)::integer;
  waits integer[] := array[1, 5, 30, 120, 720];
  outcome text;
begin
  select * into d from public.notification_deliveries where id = p_id for update;
  if not found or d.status <> 'sending' then
    return 'ignored';
  end if;

  if p_disable_token and d.push_token_id is not null then
    update public.push_tokens set disabled_at = now() where id = d.push_token_id;
  end if;

  if p_ok then
    update public.notification_deliveries
       set status = 'sent', sent_at = now(), locked_until = null, provider_ref = left(p_provider_ref, 200), last_error = null
     where id = p_id;
    return 'sent';
  end if;

  if not p_retry or d.attempts >= max_attempts then
    outcome := 'dead';
    update public.notification_deliveries set status = 'dead', locked_until = null, last_error = left(p_error, 500) where id = p_id;
  else
    outcome := 'failed';
    update public.notification_deliveries
       set status = 'failed', locked_until = null, last_error = left(p_error, 500),
           next_attempt_at = now() + make_interval(mins => waits[least(d.attempts, array_length(waits, 1))])
     where id = p_id;
  end if;
  return outcome;
end;
$$;

create function public.purge_old_notifications(p_read_days integer default 90, p_any_days integer default 365)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  n integer;
begin
  delete from public.notifications
   where (read_at is not null and read_at < now() - make_interval(days => greatest(p_read_days, 1)))
      or created_at < now() - make_interval(days => greatest(p_any_days, 1));
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissions: closed first, then opened on purpose
-- ---------------------------------------------------------------------------

revoke execute on function
  public.notify(uuid, text, text, text, text, text, text),
  public.order_seller_side(uuid),
  public.notify_order_event(),
  public.notify_new_message(),
  public.notify_listing_alert(),
  public.notify_identity_decision(),
  public.notify_business_decision(),
  public.notify_account_state(),
  public.notify_moderation(),
  public.notify_business_invitation(),
  public.notify_low_stock(),
  public.unread_notification_count(),
  public.mark_notifications_read(uuid[]),
  public.mark_all_notifications_read(text),
  public.my_notification_settings(),
  public.set_notification_preference(text, boolean, boolean, boolean, boolean),
  public.notification_channels(),
  public.register_push_token(text, text),
  public.unregister_push_token(text),
  public.claim_notification_deliveries(integer),
  public.report_notification_delivery(bigint, boolean, text, text, boolean, boolean),
  public.purge_old_notifications(integer, integer)
from public, anon, authenticated;

grant execute on function
  public.unread_notification_count(),
  public.mark_notifications_read(uuid[]),
  public.mark_all_notifications_read(text),
  public.my_notification_settings(),
  public.set_notification_preference(text, boolean, boolean, boolean, boolean),
  public.notification_channels(),
  public.register_push_token(text, text),
  public.unregister_push_token(text)
to authenticated;

grant execute on function
  public.claim_notification_deliveries(integer),
  public.report_notification_delivery(bigint, boolean, text, text, boolean, boolean),
  public.purge_old_notifications(integer, integer)
to service_role;
