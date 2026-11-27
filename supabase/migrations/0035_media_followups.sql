-- Media follow-ups.
--  1. Notifications for the Media workflow (review needed, decisions, requests).
--  2. Real view/click counts for public announcements, added into the performance summary.
--  3. Per-person "pause access" for the Support, Moderation and Finance roles. Revoke-only: it can pause what a role
--     already gives, never add powers. Default for everyone stays exactly as it is today.

-- ---------------------------------------------------------------------------
-- Who holds a permission (used to decide who to tell). Not callable by the app.
-- ---------------------------------------------------------------------------
create function public.staff_people_with(p_permission text)
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select r.user_id
    from public.admin_roles r
   where not exists (select 1 from public.staff_permission_overrides o
                      where o.user_id = r.user_id and o.permission = p_permission and o.effect = 'revoke')
     and (exists (select 1 from public.staff_role_permissions rp where rp.role = r.role and rp.permission = p_permission)
          or exists (select 1 from public.staff_permission_overrides o
                      where o.user_id = r.user_id and o.permission = p_permission and o.effect = 'grant'))
   group by r.user_id;
$$;
revoke all on function public.staff_people_with(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Notifications
-- ---------------------------------------------------------------------------
create function public.media_notify_content_event() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  c record;
  person uuid;
begin
  select id, title, created_by into c from public.media_content where id = new.content_id;
  if not found then
    return new;
  end if;

  if new.event = 'submitted' then
    for person in select public.staff_people_with('media.review') loop
      if person is distinct from new.actor_id then
        perform public.notify(person, 'account', 'media.review_needed', 'Content is waiting for your review', c.title,
                              '/media/item/' || c.id, 'media.review:' || new.id || ':' || person);
      end if;
    end loop;
  elsif new.event in ('approved', 'rejected', 'changes_requested') then
    if c.created_by is distinct from new.actor_id then
      perform public.notify(c.created_by, 'account', 'media.' || new.event,
        case new.event when 'approved' then 'Your content was approved' when 'rejected' then 'Your content was rejected' else 'Changes were requested' end,
        c.title || coalesce(' - ' || new.note, ''), '/media/item/' || c.id, 'media.decision:' || new.id);
    end if;
    if new.event = 'approved' then
      for person in select public.staff_people_with('media.publish') loop
        if person is distinct from new.actor_id and person is distinct from c.created_by then
          perform public.notify(person, 'account', 'media.ready_to_publish', 'Approved content is ready to publish', c.title,
                                '/media/item/' || c.id, 'media.ready:' || new.id || ':' || person);
        end if;
      end loop;
    end if;
  elsif new.event in ('published', 'scheduled') then
    if c.created_by is distinct from new.actor_id then
      perform public.notify(c.created_by, 'account', 'media.' || new.event,
        case new.event when 'published' then 'Your content was published' else 'Your content was scheduled' end,
        c.title, '/media/item/' || c.id, 'media.out:' || new.id);
    end if;
  end if;
  return new;
end;
$$;
create trigger media_notify_content_event after insert on public.media_content_events
  for each row execute function public.media_notify_content_event();

create function public.media_notify_request() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare person uuid;
begin
  if tg_op = 'INSERT' then
    for person in select public.staff_people_with('media.requests') loop
      if person is distinct from new.requested_by then
        perform public.notify(person, 'account', 'media.request_new', 'New request for Media', new.title, '/media/requests',
                              'media.request:' || new.id || ':' || person);
      end if;
    end loop;
  elsif new.status is distinct from old.status and new.status in ('in_progress', 'done', 'declined')
        and new.requested_by is distinct from (select auth.uid()) then
    perform public.notify(new.requested_by, 'account', 'media.request_' || new.status,
      case new.status when 'in_progress' then 'Media has started your request' when 'done' then 'Your request is done' else 'Your request was declined' end,
      new.title || coalesce(' - ' || new.resolution_note, ''), '/media/requests', 'media.request_update:' || new.id || ':' || new.status);
  end if;
  return new;
end;
$$;
create trigger media_notify_request after insert or update of status on public.media_requests
  for each row execute function public.media_notify_request();
revoke all on function public.media_notify_content_event(), public.media_notify_request() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Real counts for public announcements
-- ---------------------------------------------------------------------------
create table public.media_tracking (
  content_id uuid not null references public.media_content (id) on delete cascade,
  day date not null default current_date,
  views integer not null default 0,
  clicks integer not null default 0,
  primary key (content_id, day)
);
alter table public.media_tracking enable row level security;
revoke all on public.media_tracking from anon, authenticated;

-- Counts one view or tap of a published announcement by a signed-in person. Guests are not counted, and a person is
-- limited so one phone cannot inflate the numbers. Anything that is not a live public announcement is ignored.
create function public.media_track(p_content uuid, p_event text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    return;
  end if;
  if p_event not in ('view', 'click') then
    raise exception 'Unknown event.' using errcode = 'check_violation';
  end if;
  perform public.enforce_rate_limit('media_track', 120, 60);
  if not exists (select 1 from public.media_content c
                  where c.id = p_content and c.kind in ('announcement', 'notice') and c.channel in ('in_app', 'website')
                    and (c.status = 'published' or (c.status = 'scheduled' and c.scheduled_for <= now()))) then
    return;
  end if;
  insert into public.media_tracking (content_id, day, views, clicks)
  values (p_content, current_date, (p_event = 'view')::int, (p_event = 'click')::int)
  on conflict (content_id, day) do update
    set views = public.media_tracking.views + (p_event = 'view')::int, clicks = public.media_tracking.clicks + (p_event = 'click')::int;
end;
$$;
revoke all on function public.media_track(uuid, text) from public, anon;
grant execute on function public.media_track(uuid, text) to authenticated;

-- Same shape as before. Typed-in numbers and counted views/taps are added together.
create or replace function public.media_performance_summary()
returns table (content_id uuid, title text, kind text, published_at timestamptz, impressions bigint, clicks bigint, engagements bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.media_need('media.performance');
  return query
    select c.id, c.title, c.kind, c.published_at,
           (coalesce((select sum(p.impressions) from public.media_performance p where p.content_id = c.id), 0)
            + coalesce((select sum(t.views) from public.media_tracking t where t.content_id = c.id), 0))::bigint,
           (coalesce((select sum(p.clicks) from public.media_performance p where p.content_id = c.id), 0)
            + coalesce((select sum(t.clicks) from public.media_tracking t where t.content_id = c.id), 0))::bigint,
           coalesce((select sum(p.engagements) from public.media_performance p where p.content_id = c.id), 0)::bigint
      from public.media_content c
     where c.status = 'published'
     order by c.published_at desc nulls last limit 100;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Pause a person's department access (revoke-only)
-- ---------------------------------------------------------------------------
create function public.staff_role_access_key(p_role public.admin_role)
returns text
language sql immutable
as $$
  select case p_role when 'support' then 'support.access' when 'moderator' then 'moderation.access'
                     when 'finance' then 'finance.access' when 'media' then 'media.access' else null end;
$$;

insert into public.staff_permissions (key, department, description) values
  ('support.access',    'support',    'Use the Support and Verification tools'),
  ('moderation.access', 'moderation', 'Use the moderation tools'),
  ('finance.access',    'finance',    'Use the finance tools');
insert into public.staff_role_permissions (role, permission) values
  ('support', 'support.access'), ('moderator', 'moderation.access'), ('finance', 'finance.access');

-- Same rule as before (the role, and two-factor done), plus: not paused. With no pause set, nothing changes.
create or replace function public.has_staff_role(p_role public.admin_role)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.admin_roles r
    where r.user_id = (select auth.uid()) and r.role = p_role
  ) and coalesce((select auth.jwt() ->> 'aal'), '') = 'aal2'
    and not exists (
      select 1 from public.staff_permission_overrides o
       where o.user_id = (select auth.uid()) and o.effect = 'revoke' and o.permission = public.staff_role_access_key(p_role)
    );
$$;

-- Access to a department comes from appointing the role, so it cannot be "granted" here; and nobody can pause their own.
create or replace function public.grant_staff_permission(p_user uuid, p_permission text, p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('tech_admin') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if p_permission in ('support.access', 'moderation.access', 'finance.access') then
    raise exception 'Access to this department comes from appointing the role.' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.admin_roles where user_id = p_user) then
    raise exception 'That person is not staff.' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.staff_permissions where key = p_permission) then
    raise exception 'Unknown permission.' using errcode = 'check_violation';
  end if;
  insert into public.staff_permission_overrides (user_id, permission, effect, reason, set_by)
  values (p_user, p_permission, 'grant', left(p_reason, 300), (select auth.uid()))
  on conflict (user_id, permission) do update set effect = 'grant', reason = excluded.reason, set_by = excluded.set_by, set_at = now();
  perform public.write_audit('staff_permission.granted', 'user', p_user::text, jsonb_build_object('permission', p_permission, 'reason', left(p_reason, 300)));
end;
$$;

create or replace function public.revoke_staff_permission(p_user uuid, p_permission text, p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('tech_admin') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.staff_permissions where key = p_permission) then
    raise exception 'Unknown permission.' using errcode = 'check_violation';
  end if;
  if p_user = (select auth.uid()) and p_permission like '%.access' then
    raise exception 'You cannot pause your own access.' using errcode = 'check_violation';
  end if;
  if p_permission like '%.access' and not exists (
       select 1 from public.admin_roles r where r.user_id = p_user and public.staff_role_access_key(r.role) = p_permission) then
    raise exception 'That person does not have this role.' using errcode = 'check_violation';
  end if;
  insert into public.staff_permission_overrides (user_id, permission, effect, reason, set_by)
  values (p_user, p_permission, 'revoke', left(p_reason, 300), (select auth.uid()))
  on conflict (user_id, permission) do update set effect = 'revoke', reason = excluded.reason, set_by = excluded.set_by, set_at = now();
  perform public.write_audit('staff_permission.revoked', 'user', p_user::text, jsonb_build_object('permission', p_permission, 'reason', left(p_reason, 300)));
end;
$$;

-- When a role is removed, a pause on it goes with it (so a later re-appointment starts clean).
create function public.staff_access_cleanup() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if public.staff_role_access_key(old.role) is not null and old.role <> 'media' then
    delete from public.staff_permission_overrides where user_id = old.user_id and permission = public.staff_role_access_key(old.role);
  end if;
  return old;
end;
$$;
create trigger staff_access_cleanup after delete on public.admin_roles
  for each row execute function public.staff_access_cleanup();
revoke all on function public.staff_access_cleanup() from public, anon, authenticated;
