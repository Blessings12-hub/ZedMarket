-- Trust dashboard workloads, escalation deadlines and document-access monitoring (chunk C).
-- Read-only for support officers; nothing here changes an application. App users get no table access.
-- An escalation deadline is measured from the 'escalated' event in the immutable history, so no application table changes.

insert into public.platform_settings (key, value, note) values
  ('verification.escalation_due_hours', '24', 'Hours an escalated application may wait before it counts as overdue. Starter value.'),
  ('verification.access_alert_per_day', '30', 'Document and private-detail opens by one officer in the window that mark them for a look. Starter value.')
on conflict (key) do nothing;

create function public.verification_workload()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  hours numeric := public.setting_numeric('verification.escalation_due_hours', 24);
  me uuid := auth.uid();
  result jsonb;
begin
  perform public.verification_need_support();
  with apps as (
    select 'seller'::text as kind, id, status, escalated, assigned_to, first_approved_by, due_at, 'seller_application'::text as st from public.seller_applications where status <> 'draft'
    union all
    select 'business', id, status, escalated, assigned_to, first_approved_by, due_at, 'business_application' from public.business_applications where status <> 'draft'
  ), open_apps as (
    select * from apps where status in ('submitted', 'under_review', 'additional_information_required')
  ), esc as (
    select o.kind, o.id from open_apps o
     where o.escalated and coalesce((select max(e.created_at) from public.verification_events e
                                      where e.subject_type = o.st and e.subject_id = o.id and e.event = 'escalated'), now()) < now() - make_interval(hours => hours::integer)
  )
  select jsonb_build_object(
    'escalation_due_hours', hours,
    'mine', (select count(*) from open_apps where assigned_to = me),
    'kinds', jsonb_build_object(
      'seller', public.verification_workload_counts('seller'),
      'business', public.verification_workload_counts('business')),
    'escalations_overdue', (select count(*) from esc),
    'officers', coalesce((select jsonb_agg(jsonb_build_object('id', x.assigned_to, 'name', p.display_name, 'open', x.n) order by x.n desc)
                            from (select assigned_to, count(*) n from open_apps where assigned_to is not null group by assigned_to) x
                            join public.profiles p on p.id = x.assigned_to), '[]'::jsonb))
  into result;
  return result;
end;
$$;

-- Internal helper (app users cannot call it): counts for one kind.
create function public.verification_workload_counts(p_kind text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare r jsonb;
begin
  if p_kind = 'seller' then
    select jsonb_build_object(
      'submitted', count(*) filter (where status = 'submitted'),
      'under_review', count(*) filter (where status = 'under_review'),
      'info_requested', count(*) filter (where status = 'additional_information_required'),
      'escalated', count(*) filter (where escalated and status in ('submitted', 'under_review', 'additional_information_required')),
      'overdue', count(*) filter (where due_at < now() and status in ('submitted', 'under_review')),
      'awaiting_second', count(*) filter (where first_approved_by is not null and status = 'under_review'),
      'unassigned', count(*) filter (where assigned_to is null and status in ('submitted', 'under_review'))) into r
    from public.seller_applications where status <> 'draft';
  else
    select jsonb_build_object(
      'submitted', count(*) filter (where status = 'submitted'),
      'under_review', count(*) filter (where status = 'under_review'),
      'info_requested', count(*) filter (where status = 'additional_information_required'),
      'escalated', count(*) filter (where escalated and status in ('submitted', 'under_review', 'additional_information_required')),
      'overdue', count(*) filter (where due_at < now() and status in ('submitted', 'under_review')),
      'awaiting_second', count(*) filter (where first_approved_by is not null and status = 'under_review'),
      'unassigned', count(*) filter (where assigned_to is null and status in ('submitted', 'under_review'))) into r
    from public.business_applications where status <> 'draft';
  end if;
  return r;
end;
$$;

-- Who opened documents and private details lately. Flags unusually many opens. Looking at this page is itself audited.
create function public.verification_access_monitor(p_hours integer default 24)
returns table (officer_id uuid, officer_name text, document_opens bigint, private_views bigint, people_touched bigint,
               first_at timestamptz, last_at timestamptz, flagged boolean)
language plpgsql security definer set search_path = ''
as $$
declare
  hrs integer := least(greatest(coalesce(p_hours, 24), 1), 720);
  threshold numeric := public.setting_numeric('verification.access_alert_per_day', 30);
begin
  perform public.verification_need_support();
  perform public.write_audit('verification.access_monitor_viewed', 'user', auth.uid()::text, jsonb_build_object('hours', hrs));
  return query
    select l.actor_id, coalesce(p.display_name, 'Unknown'),
           count(*) filter (where l.action = 'document.viewed'),
           count(*) filter (where l.action = 'verification.private_viewed'),
           count(distinct l.target_id),
           min(l.created_at), max(l.created_at),
           count(*) >= threshold
      from public.audit_logs l
      left join public.profiles p on p.id = l.actor_id
     where l.action in ('document.viewed', 'verification.private_viewed') and l.actor_id is not null
       and l.created_at >= now() - make_interval(hours => hrs)
     group by l.actor_id, p.display_name
     order by count(*) desc, max(l.created_at) desc;
end;
$$;

revoke all on function public.verification_workload(), public.verification_workload_counts(text), public.verification_access_monitor(integer) from public, anon, authenticated;
grant execute on function public.verification_workload(), public.verification_access_monitor(integer) to authenticated;
