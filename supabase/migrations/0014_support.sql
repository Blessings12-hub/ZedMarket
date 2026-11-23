-- Module H: customer support.
--
-- What already exists and is kept as it is: reports (about listings, people, messages), order disputes
-- with evidence, and appeals against moderation decisions. This migration adds what was missing:
-- general support tickets (not tied to an order), complaint categories, a message thread, evidence
-- photos, assignment, escalation, resolution records, a customer rating and performance figures.
--
-- Rules that matter:
--   * Anyone signed in can ask for help, including suspended accounts (they need a way to appeal).
--   * A customer sees only their own tickets, and only the public messages on them.
--   * Support staff (support or tech_admin, signed in with two-factor) work tickets through
--     functions only. Nobody works a ticket they opened themselves.
--   * An escalated ticket cannot be resolved by the person who escalated it.
--   * Internal notes never reach the customer.

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

insert into public.platform_settings (key, value, note) values
  ('support.max_open_per_user', '5', 'Open tickets one person can have at once. Starter value.'),
  ('support.sla_hours.urgent', '2', 'Target hours to a first reply. Starter values, not promises.'),
  ('support.sla_hours.high', '8', null),
  ('support.sla_hours.normal', '24', null),
  ('support.sla_hours.low', '72', null),
  ('support.reopen_days', '7', 'A resolved ticket can be reopened by the customer for this many days.'),
  ('support.auto_close_days', '7', 'A resolved ticket closes by itself after this many days.'),
  ('rate_limit.ticket.max', '5', 'New tickets per window. Starter value.'),
  ('rate_limit.ticket.window_minutes', '1440', null),
  ('rate_limit.ticket_message.max', '30', 'Customer messages per window. Starter value.'),
  ('rate_limit.ticket_message.window_minutes', '60', null)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Categories
-- ---------------------------------------------------------------------------

create table public.support_categories (
  key text primary key check (key ~ '^[a-z_]{3,40}$'),
  label text not null,
  hint text not null,
  default_priority text not null default 'normal' check (default_priority in ('low', 'normal', 'high', 'urgent')),
  sort_order integer not null default 100,
  active boolean not null default true
);
insert into public.support_categories (key, label, hint, default_priority, sort_order) values
  ('payment_problem', 'A payment problem', 'Money left your account, a payment failed, or a refund is missing.', 'high', 10),
  ('scam_or_safety', 'Scam or safety worry', 'Someone tried to cheat you, or you feel unsafe.', 'high', 20),
  ('order_problem', 'A problem with an order', 'An order did not go as agreed.', 'normal', 30),
  ('account_access', 'I cannot get into my account', 'Sign-in, two-factor or a locked account.', 'high', 40),
  ('verification', 'Verification', 'Questions about a verification request or badge.', 'normal', 50),
  ('listing_problem', 'A problem with a listing', 'A listing was removed, rejected or will not post.', 'normal', 60),
  ('business_account', 'Business account', 'Shop, team or branch problems.', 'normal', 70),
  ('app_problem', 'The app is not working', 'Something is broken or slow.', 'normal', 80),
  ('other', 'Something else', 'Anything that does not fit above.', 'low', 99);
alter table public.support_categories enable row level security;
grant select on public.support_categories to authenticated;
create policy support_categories_read on public.support_categories for select to authenticated using (active);

-- ---------------------------------------------------------------------------
-- Tickets, messages, attachments, events
-- ---------------------------------------------------------------------------

create sequence public.support_ref_seq start 1000;

create table public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  ref text not null unique default ('SUP-' || lpad(nextval('public.support_ref_seq')::text, 6, '0')),
  requester_id uuid not null references public.profiles (id) on delete cascade,
  category text not null references public.support_categories (key),
  subject text not null check (char_length(subject) between 5 and 120),
  description text not null check (char_length(description) between 10 and 2000),
  order_id uuid references public.orders (id) on delete set null,
  status text not null default 'open' check (status in ('open', 'in_progress', 'waiting_on_customer', 'escalated', 'resolved', 'closed')),
  priority text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  assigned_to uuid references public.profiles (id) on delete set null,
  due_at timestamptz not null,
  first_response_at timestamptz,
  first_response_by uuid references public.profiles (id) on delete set null,
  escalated_at timestamptz,
  escalated_by uuid references public.profiles (id) on delete set null,
  escalation_reason text check (char_length(escalation_reason) <= 500),
  resolved_at timestamptz,
  resolved_by uuid references public.profiles (id) on delete set null,
  resolution_code text check (resolution_code in ('fixed', 'explained', 'no_action', 'duplicate', 'refunded', 'not_resolvable', 'customer_withdrew')),
  resolution_note text check (char_length(resolution_note) <= 1000),
  closed_at timestamptz,
  reopened_count integer not null default 0,
  customer_rating smallint check (customer_rating between 1 and 5),
  customer_comment text check (char_length(customer_comment) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (status not in ('resolved', 'closed') or resolution_code is not null),
  check (status <> 'escalated' or escalated_by is not null)
);
create index support_tickets_requester_idx on public.support_tickets (requester_id, created_at desc);
create index support_tickets_queue_idx on public.support_tickets (status, priority, due_at);
create index support_tickets_assigned_idx on public.support_tickets (assigned_to) where status not in ('resolved', 'closed');
create index support_tickets_resolved_idx on public.support_tickets (resolved_at) where status = 'resolved';

create table public.support_messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets (id) on delete cascade,
  author_id uuid not null references public.profiles (id) on delete cascade,
  author_role text not null check (author_role in ('customer', 'staff')),
  body text not null check (char_length(body) between 1 and 2000),
  internal boolean not null default false,
  created_at timestamptz not null default now(),
  check (not internal or author_role = 'staff')
);
create index support_messages_ticket_idx on public.support_messages (ticket_id, created_at);

create table public.support_attachments (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets (id) on delete cascade,
  uploader_id uuid not null references public.profiles (id) on delete cascade,
  storage_path text not null unique,
  created_at timestamptz not null default now()
);
create index support_attachments_ticket_idx on public.support_attachments (ticket_id);

create table public.support_events (
  id bigint generated always as identity primary key,
  ticket_id uuid not null references public.support_tickets (id) on delete cascade,
  actor_id uuid,
  event text not null,
  detail jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index support_events_ticket_idx on public.support_events (ticket_id, id);

alter table public.support_tickets enable row level security;
alter table public.support_messages enable row level security;
alter table public.support_attachments enable row level security;
alter table public.support_events enable row level security;

-- Customers read their own tickets and the public side of them. Writes go through functions.
create policy support_tickets_own_read on public.support_tickets for select to authenticated
  using (requester_id = (select auth.uid()));
create policy support_messages_own_read on public.support_messages for select to authenticated
  using (not internal and exists (select 1 from public.support_tickets t where t.id = ticket_id and t.requester_id = (select auth.uid())));
create policy support_attachments_own_read on public.support_attachments for select to authenticated
  using (exists (select 1 from public.support_tickets t where t.id = ticket_id and t.requester_id = (select auth.uid())));

-- Staff-only details (who is handling it, why it was escalated) are left out of the customer columns.
-- requester_id is granted because the message and attachment policies look at it.
grant select (id, ref, requester_id, category, subject, description, order_id, status, priority, resolved_at, resolution_code,
              resolution_note, closed_at, customer_rating, customer_comment, created_at, updated_at)
  on public.support_tickets to authenticated;
grant select (id, ticket_id, author_role, body, created_at) on public.support_messages to authenticated;
grant select (id, ticket_id, storage_path, created_at) on public.support_attachments to authenticated;
-- support_events: no grants. Only the staff functions read it.

-- ---------------------------------------------------------------------------
-- Evidence bucket (private)
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('support-evidence', 'support-evidence', false, 8388608, array['image/jpeg', 'image/png', 'application/pdf'])
on conflict (id) do nothing;

create policy "support evidence: upload to own folder" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'support-evidence' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "support evidence: read own files" on storage.objects
  for select to authenticated
  using (bucket_id = 'support-evidence' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "support evidence: support staff can read" on storage.objects
  for select to authenticated
  using (bucket_id = 'support-evidence' and (public.has_staff_role('support') or public.has_staff_role('tech_admin')));

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

create function public.support_log(p_ticket uuid, p_event text, p_detail jsonb default '{}')
returns void
language sql security definer set search_path = ''
as $$
  insert into public.support_events (ticket_id, actor_id, event, detail)
  values (p_ticket, (select auth.uid()), p_event, coalesce(p_detail, '{}'));
$$;

create function public.support_check()
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public.has_staff_role('support') or public.has_staff_role('tech_admin')) then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
end;
$$;

create function public.support_priority_rank(p text)
returns integer
language sql immutable set search_path = ''
as $$ select case p when 'urgent' then 4 when 'high' then 3 when 'normal' then 2 else 1 end; $$;

-- Loads and locks a ticket for a staff member. Staff cannot work their own tickets, and (unless they are
-- a tech admin) can only change a ticket that is assigned to them.
create function public.support_work(p_ticket uuid, p_need_assigned boolean)
returns public.support_tickets
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  t public.support_tickets;
begin
  perform public.support_check();
  select * into t from public.support_tickets where id = p_ticket for update;
  if not found then
    raise exception 'Ticket not found.' using errcode = 'no_data_found';
  end if;
  if t.requester_id = uid then
    raise exception 'You cannot work on your own ticket. Another member of staff will.' using errcode = 'insufficient_privilege';
  end if;
  if p_need_assigned and t.assigned_to is distinct from uid and not public.has_staff_role('tech_admin') then
    raise exception 'Take this ticket first.' using errcode = 'insufficient_privilege';
  end if;
  return t;
end;
$$;

-- ---------------------------------------------------------------------------
-- Customer functions
-- ---------------------------------------------------------------------------

create function public.open_ticket(p_category text, p_subject text, p_description text, p_order_id uuid default null)
returns public.support_tickets
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  cat public.support_categories;
  t public.support_tickets;
  prio text;
begin
  if uid is null then
    raise exception 'Sign in to contact support.' using errcode = 'insufficient_privilege';
  end if;
  select * into cat from public.support_categories where key = p_category and active;
  if not found then
    raise exception 'Choose what the problem is about.' using errcode = 'check_violation';
  end if;
  if char_length(btrim(coalesce(p_subject, ''))) < 5 or char_length(btrim(coalesce(p_description, ''))) < 10 then
    raise exception 'Say a little more: a short title and at least a sentence of detail.' using errcode = 'check_violation';
  end if;
  if p_order_id is not null and not public.is_order_party(p_order_id) then
    raise exception 'That order is not yours.' using errcode = 'insufficient_privilege';
  end if;
  if (select count(*) from public.support_tickets where requester_id = uid and status not in ('resolved', 'closed'))
       >= public.setting_numeric('support.max_open_per_user', 5) then
    raise exception 'You already have several open tickets. Please wait for a reply, or close one you no longer need.' using errcode = 'check_violation';
  end if;
  perform public.enforce_rate_limit('ticket', 5, 1440);

  prio := cat.default_priority;
  insert into public.support_tickets (requester_id, category, subject, description, order_id, priority, due_at)
  values (uid, p_category, btrim(p_subject), btrim(p_description), p_order_id, prio,
          clock_timestamp() + make_interval(hours => public.setting_numeric('support.sla_hours.' || prio, 24)::integer))
  returning * into t;
  insert into public.support_messages (ticket_id, author_id, author_role, body) values (t.id, uid, 'customer', t.description);
  perform public.support_log(t.id, 'opened', jsonb_build_object('category', p_category, 'priority', prio));
  return t;
end;
$$;

create function public.reply_ticket(p_ticket uuid, p_body text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  t public.support_tickets;
begin
  select * into t from public.support_tickets where id = p_ticket and requester_id = uid for update;
  if not found then
    raise exception 'Ticket not found.' using errcode = 'no_data_found';
  end if;
  if char_length(btrim(coalesce(p_body, ''))) < 1 then
    raise exception 'Write a message first.' using errcode = 'check_violation';
  end if;
  perform public.enforce_rate_limit('ticket_message', 30, 60);

  if t.status = 'closed' then
    raise exception 'This ticket is closed. Open a new one if you still need help.' using errcode = 'check_violation';
  end if;
  if t.status = 'resolved' then
    if t.resolved_at < now() - make_interval(days => public.setting_numeric('support.reopen_days', 7)::integer) then
      raise exception 'This ticket was resolved a while ago. Open a new one if you still need help.' using errcode = 'check_violation';
    end if;
    update public.support_tickets
       set status = case when assigned_to is null then 'open' else 'in_progress' end,
           resolved_at = null, resolved_by = null, resolution_code = null, resolution_note = null,
           reopened_count = reopened_count + 1, updated_at = now()
     where id = t.id;
    perform public.support_log(t.id, 'reopened_by_customer');
  elsif t.status = 'waiting_on_customer' then
    update public.support_tickets
       set status = case when assigned_to is null then 'open' else 'in_progress' end, updated_at = now()
     where id = t.id;
  else
    update public.support_tickets set updated_at = now() where id = t.id;
  end if;
  insert into public.support_messages (ticket_id, author_id, author_role, body) values (t.id, uid, 'customer', btrim(p_body));
end;
$$;

create function public.add_ticket_attachment(p_ticket uuid, p_path text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  t public.support_tickets;
begin
  select * into t from public.support_tickets where id = p_ticket and requester_id = uid;
  if not found then
    raise exception 'Ticket not found.' using errcode = 'no_data_found';
  end if;
  if t.status = 'closed' then
    raise exception 'This ticket is closed.' using errcode = 'check_violation';
  end if;
  -- The file must sit in the person's own folder for this ticket. The upload itself is checked by storage.
  if p_path is null or p_path !~ ('^' || uid::text || '/' || t.id::text || '/[A-Za-z0-9._-]{1,100}$') then
    raise exception 'That file is not in the right place.' using errcode = 'check_violation';
  end if;
  if (select count(*) from public.support_attachments where ticket_id = t.id) >= 5 then
    raise exception 'A ticket can have up to 5 files.' using errcode = 'check_violation';
  end if;
  insert into public.support_attachments (ticket_id, uploader_id, storage_path) values (t.id, uid, p_path);
  update public.support_tickets set updated_at = now() where id = t.id;
end;
$$;

create function public.rate_ticket(p_ticket uuid, p_rating integer, p_comment text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  t public.support_tickets;
begin
  select * into t from public.support_tickets where id = p_ticket and requester_id = uid for update;
  if not found then
    raise exception 'Ticket not found.' using errcode = 'no_data_found';
  end if;
  if t.status not in ('resolved', 'closed') or t.resolution_code = 'customer_withdrew' then
    raise exception 'You can rate help once it has been resolved.' using errcode = 'check_violation';
  end if;
  if t.customer_rating is not null then
    raise exception 'You already rated this.' using errcode = 'check_violation';
  end if;
  if p_rating is null or p_rating not between 1 and 5 then
    raise exception 'Choose 1 to 5.' using errcode = 'check_violation';
  end if;
  update public.support_tickets set customer_rating = p_rating, customer_comment = left(btrim(p_comment), 500), updated_at = now()
   where id = t.id;
end;
$$;

-- The customer closes a ticket: either they no longer need help, or they accept the answer.
create function public.customer_close_ticket(p_ticket uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  t public.support_tickets;
begin
  select * into t from public.support_tickets where id = p_ticket and requester_id = uid for update;
  if not found then
    raise exception 'Ticket not found.' using errcode = 'no_data_found';
  end if;
  if t.status = 'closed' then
    return;
  end if;
  update public.support_tickets
     set status = 'closed', closed_at = now(), updated_at = now(),
         resolution_code = coalesce(resolution_code, 'customer_withdrew')
   where id = t.id;
  perform public.support_log(t.id, 'closed_by_customer');
end;
$$;

create function public.my_tickets(p_limit integer default 50)
returns table (id uuid, ref text, subject text, category text, status text, order_id uuid, created_at timestamptz,
               updated_at timestamptz, unread_reply boolean)
language sql stable security definer set search_path = ''
as $$
  select t.id, t.ref, t.subject, t.category, t.status, t.order_id, t.created_at, t.updated_at,
         exists (select 1 from public.support_messages m
                  where m.ticket_id = t.id and m.author_role = 'staff' and not m.internal
                    and m.created_at = (select max(m2.created_at) from public.support_messages m2 where m2.ticket_id = t.id and not m2.internal))
    from public.support_tickets t
   where t.requester_id = (select auth.uid())
   order by t.updated_at desc limit least(greatest(p_limit, 1), 100);
$$;

-- ---------------------------------------------------------------------------
-- Staff functions
-- ---------------------------------------------------------------------------

create function public.support_queue(p_status text default null, p_view text default 'all', p_category text default null,
                                     p_overdue_only boolean default false, p_search text default null,
                                     p_limit integer default 50, p_offset integer default 0)
returns table (
  id uuid, ref text, subject text, category text, status text, priority text, requester_name text,
  assigned_name text, assigned_to uuid, due_at timestamptz, overdue boolean, created_at timestamptz, updated_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  term text := replace(replace(coalesce(p_search, ''), '%', ''), '_', '');
begin
  perform public.support_check();
  return query
    select t.id, t.ref, t.subject, t.category, t.status, t.priority, rp.display_name, ap.display_name, t.assigned_to, t.due_at,
           (t.first_response_at is null and t.status in ('open', 'in_progress', 'escalated') and t.due_at < now()),
           t.created_at, t.updated_at
      from public.support_tickets t
      join public.profiles rp on rp.id = t.requester_id
      left join public.profiles ap on ap.id = t.assigned_to
     where t.requester_id <> uid
       and (p_status is null or t.status = p_status)
       and (p_status is not null or t.status not in ('resolved', 'closed'))
       and (p_view = 'all' or (p_view = 'mine' and t.assigned_to = uid) or (p_view = 'unassigned' and t.assigned_to is null))
       and (p_category is null or t.category = p_category)
       and (not p_overdue_only or (t.first_response_at is null and t.status in ('open', 'in_progress', 'escalated') and t.due_at < now()))
       and (term = '' or t.ref ilike '%' || term || '%' or t.subject ilike '%' || term || '%')
     order by (t.status = 'escalated') desc, public.support_priority_rank(t.priority) desc, t.due_at
     limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0);
end;
$$;

create function public.support_ticket_detail(p_ticket uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  result jsonb;
begin
  perform public.support_check();
  select jsonb_build_object(
      'ticket', jsonb_build_object('id', t.id, 'ref', t.ref, 'subject', t.subject, 'category', t.category,
        'status', t.status, 'priority', t.priority, 'order_ref', o.ref, 'order_id', t.order_id,
        'assigned_to', t.assigned_to, 'assigned_name', ap.display_name, 'due_at', t.due_at,
        'first_response_at', t.first_response_at, 'escalated_by', t.escalated_by, 'escalation_reason', t.escalation_reason,
        'resolution_code', t.resolution_code, 'resolution_note', t.resolution_note, 'reopened_count', t.reopened_count,
        'customer_rating', t.customer_rating, 'customer_comment', t.customer_comment,
        'created_at', t.created_at, 'resolved_at', t.resolved_at),
      'requester', jsonb_build_object('id', rp.id, 'name', rp.display_name, 'verification', rp.verification_level,
        'account_state', rp.account_state,
        'other_open_tickets', (select count(*) from public.support_tickets x where x.requester_id = t.requester_id and x.id <> t.id and x.status not in ('resolved', 'closed'))),
      'messages', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'role', m.author_role, 'author', mp.display_name,
                              'body', m.body, 'internal', m.internal, 'at', m.created_at) order by m.created_at)
                             from public.support_messages m join public.profiles mp on mp.id = m.author_id where m.ticket_id = t.id), '[]'),
      'attachments', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'path', a.storage_path, 'at', a.created_at) order by a.created_at)
                                 from public.support_attachments a where a.ticket_id = t.id), '[]'),
      'events', coalesce((select jsonb_agg(jsonb_build_object('event', e.event, 'actor', ep.display_name, 'detail', e.detail, 'at', e.created_at) order by e.id)
                           from public.support_events e left join public.profiles ep on ep.id = e.actor_id where e.ticket_id = t.id), '[]'))
    into result
    from public.support_tickets t
    join public.profiles rp on rp.id = t.requester_id
    left join public.profiles ap on ap.id = t.assigned_to
    left join public.orders o on o.id = t.order_id
   where t.id = p_ticket and t.requester_id <> uid;
  if result is null then
    raise exception 'Ticket not found.' using errcode = 'no_data_found';
  end if;
  return result;
end;
$$;

create function public.support_claim(p_ticket uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  t public.support_tickets;
begin
  t := public.support_work(p_ticket, false);
  if t.status in ('resolved', 'closed') then
    raise exception 'This ticket is already finished.' using errcode = 'check_violation';
  end if;
  if t.assigned_to is not null then
    raise exception 'Someone has already taken this ticket.' using errcode = 'check_violation';
  end if;
  if t.status = 'escalated' and t.escalated_by = uid then
    raise exception 'You escalated this ticket. Someone else needs to take it.' using errcode = 'insufficient_privilege';
  end if;
  update public.support_tickets
     set assigned_to = uid, status = case when status = 'open' then 'in_progress' else status end, updated_at = now()
   where id = t.id;
  perform public.support_log(t.id, 'claimed');
end;
$$;

create function public.support_assign(p_ticket uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  t public.support_tickets;
begin
  if not public.has_staff_role('tech_admin') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  t := public.support_work(p_ticket, false);
  if t.status in ('resolved', 'closed') then
    raise exception 'This ticket is already finished.' using errcode = 'check_violation';
  end if;
  if p_user is not null and not exists (select 1 from public.admin_roles r where r.user_id = p_user and r.role in ('support', 'tech_admin')) then
    raise exception 'That person is not on the support team.' using errcode = 'check_violation';
  end if;
  if p_user = t.requester_id then
    raise exception 'A ticket cannot be assigned to the person who opened it.' using errcode = 'check_violation';
  end if;
  if t.status = 'escalated' and p_user = t.escalated_by then
    raise exception 'It cannot go back to the person who escalated it.' using errcode = 'check_violation';
  end if;
  update public.support_tickets
     set assigned_to = p_user,
         status = case when p_user is null and status = 'in_progress' then 'open' else status end,
         updated_at = now()
   where id = t.id;
  perform public.support_log(t.id, 'assigned', jsonb_build_object('to', p_user));
  perform public.write_audit('support.assigned', 'support_ticket', t.id::text, jsonb_build_object('to', p_user));
end;
$$;

create function public.support_reply(p_ticket uuid, p_body text, p_internal boolean default false)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  t public.support_tickets;
begin
  t := public.support_work(p_ticket, true);
  if t.status in ('resolved', 'closed') then
    raise exception 'This ticket is finished. Reopening is up to the customer.' using errcode = 'check_violation';
  end if;
  if char_length(btrim(coalesce(p_body, ''))) < 1 then
    raise exception 'Write a message first.' using errcode = 'check_violation';
  end if;
  insert into public.support_messages (ticket_id, author_id, author_role, body, internal)
  values (t.id, uid, 'staff', btrim(p_body), coalesce(p_internal, false));
  if not coalesce(p_internal, false) then
    update public.support_tickets
       set first_response_at = coalesce(first_response_at, now()),
           first_response_by = case when first_response_at is null then uid else first_response_by end,
           status = case when status in ('open', 'in_progress') then 'waiting_on_customer' else status end,
           updated_at = now()
     where id = t.id;
  else
    update public.support_tickets set updated_at = now() where id = t.id;
    perform public.support_log(t.id, 'internal_note');
  end if;
end;
$$;

create function public.support_set_status(p_ticket uuid, p_status text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  t public.support_tickets;
begin
  if p_status not in ('in_progress', 'waiting_on_customer') then
    raise exception 'Choose in progress or waiting on the customer.' using errcode = 'check_violation';
  end if;
  t := public.support_work(p_ticket, true);
  if t.status not in ('open', 'in_progress', 'waiting_on_customer') then
    raise exception 'This ticket cannot change to that now.' using errcode = 'check_violation';
  end if;
  update public.support_tickets set status = p_status, updated_at = now() where id = t.id;
  perform public.support_log(t.id, 'status_' || p_status);
end;
$$;

create function public.support_escalate(p_ticket uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  t public.support_tickets;
begin
  t := public.support_work(p_ticket, true);
  if t.status in ('resolved', 'closed', 'escalated') then
    raise exception 'This ticket cannot be escalated now.' using errcode = 'check_violation';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) < 10 then
    raise exception 'Say why it needs a second person (at least 10 characters).' using errcode = 'check_violation';
  end if;
  -- It goes back to the queue with no owner, so a different person has to pick it up.
  update public.support_tickets
     set status = 'escalated', escalated_at = now(), escalated_by = uid, escalation_reason = left(btrim(p_reason), 500),
         assigned_to = null,
         priority = case when public.support_priority_rank(priority) < 3 then 'high' else priority end,
         updated_at = now()
   where id = t.id;
  perform public.support_log(t.id, 'escalated', jsonb_build_object('reason', left(btrim(p_reason), 500)));
  perform public.write_audit('support.escalated', 'support_ticket', t.id::text, jsonb_build_object('reason', left(btrim(p_reason), 500)));
end;
$$;

create function public.support_resolve(p_ticket uuid, p_code text, p_note text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  t public.support_tickets;
begin
  if p_code not in ('fixed', 'explained', 'no_action', 'duplicate', 'refunded', 'not_resolvable') then
    raise exception 'Choose how it was resolved.' using errcode = 'check_violation';
  end if;
  t := public.support_work(p_ticket, true);
  if t.status in ('resolved', 'closed') then
    raise exception 'This ticket is already finished.' using errcode = 'check_violation';
  end if;
  if p_note is null or char_length(btrim(p_note)) < 10 then
    raise exception 'Write what was done (at least 10 characters).' using errcode = 'check_violation';
  end if;
  if t.escalated_by = uid then
    raise exception 'You escalated this ticket. Someone else must resolve it.' using errcode = 'insufficient_privilege';
  end if;
  update public.support_tickets
     set status = 'resolved', resolution_code = p_code, resolution_note = left(btrim(p_note), 1000),
         resolved_at = now(), resolved_by = uid, updated_at = now()
   where id = t.id;
  perform public.support_log(t.id, 'resolved', jsonb_build_object('code', p_code));
  perform public.write_audit('support.resolved', 'support_ticket', t.id::text, jsonb_build_object('code', p_code));
end;
$$;

-- Run on a schedule: tickets nobody reopened are closed.
create function public.close_resolved_tickets()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  r record;
  n integer := 0;
begin
  for r in select id from public.support_tickets
            where status = 'resolved'
              and resolved_at < now() - make_interval(days => public.setting_numeric('support.auto_close_days', 7)::integer)
            for update skip locked loop
    update public.support_tickets set status = 'closed', closed_at = now(), updated_at = now() where id = r.id;
    insert into public.support_events (ticket_id, actor_id, event) values (r.id, null, 'auto_closed');
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- Monitoring
-- ---------------------------------------------------------------------------

create function public.support_overview(p_days integer default 30)
returns table (metric text, value numeric)
language plpgsql stable security definer set search_path = ''
as $$
declare
  since timestamptz := now() - make_interval(days => least(greatest(p_days, 1), 365));
begin
  perform public.support_check();
  return query
    select 'created', count(*)::numeric from public.support_tickets t where t.created_at >= since
    union all select 'resolved', count(*)::numeric from public.support_tickets t where t.resolved_at >= since
    union all select 'open_now', count(*)::numeric from public.support_tickets t where t.status in ('open', 'in_progress')
    union all select 'waiting_on_customer_now', count(*)::numeric from public.support_tickets t where t.status = 'waiting_on_customer'
    union all select 'escalated_now', count(*)::numeric from public.support_tickets t where t.status = 'escalated'
    union all select 'unassigned_now', count(*)::numeric from public.support_tickets t where t.assigned_to is null and t.status in ('open', 'escalated')
    union all select 'overdue_now', count(*)::numeric from public.support_tickets t
                where t.first_response_at is null and t.status in ('open', 'in_progress', 'escalated') and t.due_at < now()
    union all select 'avg_first_response_minutes', round(avg(extract(epoch from (t.first_response_at - t.created_at)) / 60)::numeric, 1)
                from public.support_tickets t where t.first_response_at is not null and t.created_at >= since
    union all select 'avg_resolution_hours', round(avg(extract(epoch from (t.resolved_at - t.created_at)) / 3600)::numeric, 1)
                from public.support_tickets t where t.resolved_at >= since
    union all select 'avg_rating', round(avg(t.customer_rating)::numeric, 2)
                from public.support_tickets t where t.customer_rating is not null and t.created_at >= since
    union all select 'rated', count(*)::numeric from public.support_tickets t where t.customer_rating is not null and t.created_at >= since
    union all select 'category:' || c.key, count(t.id)::numeric
                from public.support_categories c left join public.support_tickets t on t.category = c.key and t.created_at >= since
               group by c.key;
end;
$$;

-- Tech admins see every agent. Other support staff see only their own row.
create function public.support_performance(p_days integer default 30)
returns table (agent_id uuid, agent_name text, resolved integer, avg_first_response_minutes numeric,
               avg_resolution_hours numeric, avg_rating numeric, open_now integer, overdue_now integer)
language plpgsql stable security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  since timestamptz := now() - make_interval(days => least(greatest(p_days, 1), 365));
  all_agents boolean := public.has_staff_role('tech_admin');
begin
  perform public.support_check();
  return query
    select a.user_id, p.display_name,
           (select count(*)::integer from public.support_tickets t where t.resolved_by = a.user_id and t.resolved_at >= since),
           (select round(avg(extract(epoch from (t.first_response_at - t.created_at)) / 60)::numeric, 1)
              from public.support_tickets t where t.first_response_by = a.user_id and t.created_at >= since),
           (select round(avg(extract(epoch from (t.resolved_at - t.created_at)) / 3600)::numeric, 1)
              from public.support_tickets t where t.resolved_by = a.user_id and t.resolved_at >= since),
           (select round(avg(t.customer_rating)::numeric, 2)
              from public.support_tickets t where t.resolved_by = a.user_id and t.resolved_at >= since and t.customer_rating is not null),
           (select count(*)::integer from public.support_tickets t where t.assigned_to = a.user_id and t.status in ('open', 'in_progress', 'waiting_on_customer', 'escalated')),
           (select count(*)::integer from public.support_tickets t where t.assigned_to = a.user_id and t.first_response_at is null
               and t.status in ('open', 'in_progress', 'escalated') and t.due_at < now())
      from (select distinct r.user_id from public.admin_roles r where r.role in ('support', 'tech_admin')) a
      join public.profiles p on p.id = a.user_id
     where all_agents or a.user_id = uid
     order by 3 desc, 2;
end;
$$;

-- ---------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------

create function public.notify_support_message()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  t public.support_tickets;
begin
  if new.author_role = 'staff' and not new.internal then
    select * into t from public.support_tickets where id = new.ticket_id;
    -- The reply text stays out of the notification. The customer reads it in the app.
    perform public.notify(t.requester_id, 'account', 'support.reply', 'Support replied to ' || t.ref,
      'Open the ticket to read the reply.', '/support/' || t.id, 'supmsg:' || new.id);
  end if;
  return new;
end;
$$;
create trigger support_messages_notify after insert on public.support_messages
  for each row execute function public.notify_support_message();

create function public.notify_support_resolved()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.notify(new.requester_id, 'account', 'support.resolved', 'Your ticket ' || new.ref || ' was resolved',
    'Open it to see what was done, and tell us how we did.', '/support/' || new.id,
    'supres:' || new.id || ':' || new.reopened_count);
  return new;
end;
$$;
create trigger support_tickets_resolved_notify after update of status on public.support_tickets
  for each row when (old.status is distinct from new.status and new.status = 'resolved' and new.resolved_by is not null)
  execute function public.notify_support_resolved();

-- Appeals (migration 0003) already exist. The person now hears the outcome.
create function public.notify_appeal_reviewed()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.notify(new.user_id, 'account', 'appeal.reviewed', 'Your appeal was reviewed',
    case new.status when 'overturned' then 'The decision was reversed.' else 'The original decision was kept.' end,
    '/account', 'appeal:' || new.id || ':' || new.status);
  return new;
end;
$$;
create trigger appeals_reviewed_notify after update of status on public.appeals
  for each row when (old.status = 'open' and new.status in ('upheld', 'overturned'))
  execute function public.notify_appeal_reviewed();

-- ---------------------------------------------------------------------------
-- Function permissions: closed first, then opened on purpose
-- ---------------------------------------------------------------------------

revoke execute on function
  public.support_log(uuid, text, jsonb),
  public.support_check(),
  public.support_priority_rank(text),
  public.support_work(uuid, boolean),
  public.open_ticket(text, text, text, uuid),
  public.reply_ticket(uuid, text),
  public.add_ticket_attachment(uuid, text),
  public.rate_ticket(uuid, integer, text),
  public.customer_close_ticket(uuid),
  public.my_tickets(integer),
  public.support_queue(text, text, text, boolean, text, integer, integer),
  public.support_ticket_detail(uuid),
  public.support_claim(uuid),
  public.support_assign(uuid, uuid),
  public.support_reply(uuid, text, boolean),
  public.support_set_status(uuid, text),
  public.support_escalate(uuid, text),
  public.support_resolve(uuid, text, text),
  public.close_resolved_tickets(),
  public.support_overview(integer),
  public.support_performance(integer),
  public.notify_support_message(),
  public.notify_support_resolved(),
  public.notify_appeal_reviewed()
from public, anon, authenticated;

grant execute on function
  public.open_ticket(text, text, text, uuid),
  public.reply_ticket(uuid, text),
  public.add_ticket_attachment(uuid, text),
  public.rate_ticket(uuid, integer, text),
  public.customer_close_ticket(uuid),
  public.my_tickets(integer),
  public.support_queue(text, text, text, boolean, text, integer, integer),
  public.support_ticket_detail(uuid),
  public.support_claim(uuid),
  public.support_assign(uuid, uuid),
  public.support_reply(uuid, text, boolean),
  public.support_set_status(uuid, text),
  public.support_escalate(uuid, text),
  public.support_resolve(uuid, text, text),
  public.support_overview(integer),
  public.support_performance(integer)
to authenticated;

grant execute on function public.close_resolved_tickets() to service_role;
