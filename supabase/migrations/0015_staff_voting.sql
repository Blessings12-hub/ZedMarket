-- 0015: Staff voting (Phase 10 and the voting half of Phase 12)
--
-- Staff can put a proposal to a vote. The server counts the votes and decides the result. Nobody can type in
-- or change a result, and a simple majority is never enough.
--
-- The rule (enforced in the database, not in the app):
--   required_votes = ceiling(eligible_staff_count * 2 / 3)
--   FOR     reaches required_votes  -> approved
--   AGAINST reaches required_votes  -> rejected
--   anything else at the deadline   -> unresolved
-- Abstentions and people who do not vote count towards neither side, but they stay in the eligible count.
--
-- Lifecycle: draft -> pending (scheduled) -> active -> approved | rejected | unresolved. A draft, pending or
-- active proposal can also be cancelled. An unresolved proposal can be resubmitted as a NEW proposal with a new
-- reference. Approved, rejected, unresolved and cancelled proposals can never change again.
--
-- Closing rules:
--   * An active vote closes at its deadline.
--   * It closes earlier the moment FOR or AGAINST reaches the threshold. That cannot be undone by later votes:
--     one vote each means both sides can never reach two thirds together.
--
-- Who is eligible: everyone holding a staff role, with an active account, at the moment the vote opens. That list
-- is frozen (staff_vote_eligibility). Later changes to staff roles do not change the denominator or remove a vote
-- already cast. Someone who has left can no longer sign in to staff tools, so they simply do not vote any more.
--
-- Secrecy:
--   * Tables have no grants for app users. Everything goes through the functions below.
--   * Ordinary staff see aggregate counts, and their own vote. Never anyone else's.
--   * Confidential proposals hide even the running counts until the vote closes.
--   * Individual ballots can be read only by a technical admin, only after a vote closes, never for a
--     confidential proposal, and every read is written to the audit trail.
--
-- What a vote is NOT: it does not run anything. An approved result is a recorded decision, nothing more. No code
-- reads it to change a setting, a role or a listing. A vote cannot override legal duties, security controls or
-- emergency responsibilities, and the proposer must confirm the proposal does not ask for that.
--
-- Notifications reuse the existing notify() function and its 'account' category (so they cannot be muted).

-- ---------------------------------------------------------------------------
-- Settings (starter values, change in platform_settings)
-- ---------------------------------------------------------------------------

insert into public.platform_settings (key, value, note) values
  ('staff_vote.min_eligible', '3', 'A vote cannot open with fewer eligible staff than this. Starter value.'),
  ('staff_vote.min_hours', '24', 'Shortest voting period in hours. Starter value.'),
  ('staff_vote.max_hours', '336', 'Longest voting period in hours (14 days). Starter value.'),
  ('staff_vote.proposer_roles', '["tech_admin","moderator","support","finance"]', 'Staff roles that may create proposals. Starter value: every staff role.'),
  ('rate_limit.staff_proposal.max', '10', 'New proposals per window. Starter value.'),
  ('rate_limit.staff_proposal.window_minutes', '1440', null)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create sequence public.staff_proposal_seq;

create table public.staff_proposals (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique check (reference ~ '^SV-[0-9]{4}-[0-9]{4,}$'),
  title text not null check (char_length(btrim(title)) between 5 and 120),
  description text not null check (char_length(btrim(description)) between 10 and 4000),
  reason text not null check (char_length(btrim(reason)) between 10 and 2000),
  proposer_id uuid not null references public.profiles (id),
  status text not null default 'draft'
    check (status in ('draft', 'pending', 'active', 'approved', 'rejected', 'unresolved', 'cancelled')),
  confidential boolean not null default false,
  -- The proposer confirms the proposal does not ask staff to override legal, security or emergency duties.
  no_override_confirmed boolean not null check (no_override_confirmed),
  created_at timestamptz not null default now(),
  opens_at timestamptz,
  closes_at timestamptz,
  opened_at timestamptz,
  closed_at timestamptz,
  eligible_count integer check (eligible_count >= 1),
  required_votes integer check (required_votes >= 1),
  resubmitted_from uuid references public.staff_proposals (id),
  cancel_reason text check (char_length(cancel_reason) <= 500),
  check (closes_at is null or opens_at is null or closes_at > opens_at),
  check (status in ('draft', 'cancelled') or (opens_at is not null and closes_at is not null)),
  check (status not in ('active', 'approved', 'rejected', 'unresolved') or (eligible_count is not null and required_votes is not null)),
  check (required_votes is null or eligible_count is null or required_votes = (eligible_count * 2 + 2) / 3),
  check (status <> 'cancelled' or cancel_reason is not null)
);
create index staff_proposals_status_idx on public.staff_proposals (status, closes_at);
create index staff_proposals_proposer_idx on public.staff_proposals (proposer_id, created_at desc);
-- An unresolved proposal can be resubmitted only once.
create unique index staff_proposals_one_resubmission on public.staff_proposals (resubmitted_from) where resubmitted_from is not null;
alter table public.staff_proposals enable row level security;

-- The frozen list of who may vote on a proposal.
create table public.staff_vote_eligibility (
  proposal_id uuid not null references public.staff_proposals (id),
  user_id uuid not null references public.profiles (id),
  snapshot_at timestamptz not null default now(),
  primary key (proposal_id, user_id)
);
alter table public.staff_vote_eligibility enable row level security;

-- One row per staff member per proposal. Never updated, never deleted.
create table public.staff_votes (
  proposal_id uuid not null,
  voter_id uuid not null,
  choice text not null check (choice in ('for', 'against', 'abstain')),
  cast_at timestamptz not null default now(),
  primary key (proposal_id, voter_id),
  foreign key (proposal_id, voter_id) references public.staff_vote_eligibility (proposal_id, user_id)
);
create index staff_votes_voter_idx on public.staff_votes (voter_id, cast_at desc);
alter table public.staff_votes enable row level security;

-- The result, written once when the vote closes. The check ties the outcome to the counts, so a wrong
-- outcome cannot be stored even by mistake.
create table public.staff_vote_results (
  proposal_id uuid primary key references public.staff_proposals (id),
  eligible_count integer not null check (eligible_count >= 1),
  required_votes integer not null check (required_votes = (eligible_count * 2 + 2) / 3),
  for_count integer not null check (for_count >= 0),
  against_count integer not null check (against_count >= 0),
  abstain_count integer not null check (abstain_count >= 0),
  outcome text not null check (outcome in ('approved', 'rejected', 'unresolved')),
  closed_by text not null check (closed_by in ('threshold', 'deadline')),
  ballot_digest text not null,
  calculated_at timestamptz not null default now(),
  check (for_count + against_count + abstain_count <= eligible_count),
  check (
    (outcome = 'approved' and for_count >= required_votes) or
    (outcome = 'rejected' and against_count >= required_votes) or
    (outcome = 'unresolved' and for_count < required_votes and against_count < required_votes)
  )
);
alter table public.staff_vote_results enable row level security;

-- Append-only audit trail. Each row carries the hash of the one before it, so an edit or a removal is detectable.
-- It never records how anyone voted.
create table public.staff_vote_audit_logs (
  id bigint generated always as identity primary key,
  proposal_id uuid not null references public.staff_proposals (id),
  seq integer not null,
  actor_id uuid,
  action text not null check (char_length(action) between 3 and 60),
  details jsonb not null default '{}',
  created_at timestamptz not null default clock_timestamp(),
  prev_hash text,
  row_hash text not null,
  unique (proposal_id, seq)
);
alter table public.staff_vote_audit_logs enable row level security;

-- ---------------------------------------------------------------------------
-- Immutability
-- ---------------------------------------------------------------------------

create function public.sv_block_change()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  raise exception 'Voting records cannot be changed or removed.' using errcode = 'insufficient_privilege';
end;
$$;

create trigger staff_votes_frozen before update or delete on public.staff_votes
  for each row execute function public.sv_block_change();
create trigger staff_vote_results_frozen before update or delete on public.staff_vote_results
  for each row execute function public.sv_block_change();
create trigger staff_vote_eligibility_frozen before update or delete on public.staff_vote_eligibility
  for each row execute function public.sv_block_change();
create trigger staff_vote_audit_frozen before update or delete on public.staff_vote_audit_logs
  for each row execute function public.sv_block_change();
create trigger staff_proposals_no_delete before delete on public.staff_proposals
  for each row execute function public.sv_block_change();

create function public.sv_truncate_block()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  raise exception 'Voting records cannot be emptied.' using errcode = 'insufficient_privilege';
end;
$$;
create trigger staff_votes_no_truncate before truncate on public.staff_votes
  for each statement execute function public.sv_truncate_block();
create trigger staff_vote_audit_no_truncate before truncate on public.staff_vote_audit_logs
  for each statement execute function public.sv_truncate_block();

-- A proposal can only move along the lifecycle, and its content is frozen once it leaves draft.
create function public.sv_guard_proposal()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if old.status in ('approved', 'rejected', 'unresolved', 'cancelled') then
    raise exception 'A closed proposal cannot be changed.' using errcode = 'insufficient_privilege';
  end if;

  if new.status <> old.status and not (
       (old.status = 'draft' and new.status in ('pending', 'active', 'cancelled')) or
       (old.status = 'pending' and new.status in ('active', 'cancelled')) or
       (old.status = 'active' and new.status in ('approved', 'rejected', 'unresolved', 'cancelled'))
     ) then
    raise exception 'A proposal cannot move from % to %.', old.status, new.status using errcode = 'check_violation';
  end if;

  -- A decision exists only if the server wrote a matching result first (see sv_settle).
  if new.status in ('approved', 'rejected', 'unresolved') and new.status <> old.status
     and not exists (select 1 from public.staff_vote_results r where r.proposal_id = new.id and r.outcome = new.status) then
    raise exception 'A result cannot be set by hand.' using errcode = 'insufficient_privilege';
  end if;

  if old.status <> 'draft' and (
       new.title is distinct from old.title or new.description is distinct from old.description
       or new.reason is distinct from old.reason or new.proposer_id is distinct from old.proposer_id
       or new.confidential is distinct from old.confidential or new.reference is distinct from old.reference
       or new.created_at is distinct from old.created_at or new.resubmitted_from is distinct from old.resubmitted_from
     ) then
    raise exception 'A proposal cannot be edited once it has been submitted.' using errcode = 'check_violation';
  end if;

  if old.status in ('pending', 'active') and (new.closes_at is distinct from old.closes_at)
     then
    raise exception 'The voting period cannot be changed once submitted.' using errcode = 'check_violation';
  end if;
  if old.status = 'active' and (new.eligible_count is distinct from old.eligible_count
       or new.required_votes is distinct from old.required_votes or new.opened_at is distinct from old.opened_at) then
    raise exception 'The eligible voter snapshot cannot be changed.' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger staff_proposals_guard before update on public.staff_proposals
  for each row execute function public.sv_guard_proposal();

-- A result can only be stored if it matches the ballots actually held, and only for an active proposal.
create function public.sv_guard_result()
returns trigger
language plpgsql set search_path = ''
as $$
declare
  f integer; a integer; ab integer;
  p public.staff_proposals;
begin
  select * into p from public.staff_proposals where id = new.proposal_id;
  if p.status <> 'active' or p.eligible_count <> new.eligible_count or p.required_votes <> new.required_votes then
    raise exception 'A result does not match its proposal.' using errcode = 'check_violation';
  end if;
  select count(*) filter (where choice = 'for'), count(*) filter (where choice = 'against'), count(*) filter (where choice = 'abstain')
    into f, a, ab from public.staff_votes where proposal_id = new.proposal_id;
  if f <> new.for_count or a <> new.against_count or ab <> new.abstain_count then
    raise exception 'A result does not match the votes cast.' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger staff_vote_results_guard before insert on public.staff_vote_results
  for each row execute function public.sv_guard_result();

-- A vote can only be inserted while its proposal is active and still inside its voting period.
create function public.sv_guard_vote()
returns trigger
language plpgsql set search_path = ''
as $$
declare
  p public.staff_proposals;
begin
  select * into p from public.staff_proposals where id = new.proposal_id;
  if p.status <> 'active' or p.closes_at <= clock_timestamp() then
    raise exception 'This vote is not open.' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger staff_votes_guard before insert on public.staff_votes
  for each row execute function public.sv_guard_vote();

-- ---------------------------------------------------------------------------
-- Internal helpers (closed to the app)
-- ---------------------------------------------------------------------------

create function public.sv_need_staff()
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_staff() then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
end;
$$;

-- Writes one audit row, chained to the previous one for the same proposal. The advisory lock makes two writers
-- for the same proposal take turns, so the chain cannot fork.
create function public.sv_log(p_proposal uuid, p_action text, p_details jsonb default '{}')
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  prev_row public.staff_vote_audit_logs;
  next_seq integer;
  stamp timestamptz := clock_timestamp();
  who uuid := (select auth.uid());
  hash text;
begin
  perform pg_advisory_xact_lock(hashtextextended('staff_vote_audit:' || p_proposal::text, 0));
  select * into prev_row from public.staff_vote_audit_logs where proposal_id = p_proposal order by seq desc limit 1;
  next_seq := coalesce(prev_row.seq, 0) + 1;
  hash := encode(sha256(convert_to(
    coalesce(prev_row.row_hash, '') || '|' || p_proposal::text || '|' || next_seq::text || '|' || coalesce(who::text, '')
    || '|' || p_action || '|' || coalesce(p_details, '{}')::text || '|'
    || to_char(stamp at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'), 'utf8')), 'hex');
  insert into public.staff_vote_audit_logs (proposal_id, seq, actor_id, action, details, created_at, prev_hash, row_hash)
  values (p_proposal, next_seq, who, p_action, coalesce(p_details, '{}'), stamp, prev_row.row_hash, hash);
end;
$$;

create function public.sv_required(p_eligible integer)
returns integer
language sql immutable set search_path = ''
as $$ select (p_eligible * 2 + 2) / 3; $$;

-- Opens a vote: freezes the list of eligible staff and the threshold. Caller holds the proposal row lock.
create function public.sv_open(p_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  p public.staff_proposals;
  n integer;
  min_n integer := public.setting_numeric('staff_vote.min_eligible', 3)::integer;
begin
  select * into p from public.staff_proposals where id = p_id;

  if p.closes_at <= now() then
    update public.staff_proposals set status = 'cancelled', cancel_reason = 'The voting period passed before the vote could open.' where id = p_id;
    perform public.sv_log(p_id, 'cancelled_by_system', jsonb_build_object('reason', 'window_passed'));
    return;
  end if;

  insert into public.staff_vote_eligibility (proposal_id, user_id)
  select p_id, r.user_id
    from (select distinct user_id from public.admin_roles) r
    join public.profiles pr on pr.id = r.user_id and pr.account_state = 'active';
  get diagnostics n = row_count;

  if n < min_n then
    raise exception 'At least % eligible staff are needed to open a vote.', min_n using errcode = 'check_violation';
  end if;

  update public.staff_proposals
     set status = 'active', opened_at = now(), eligible_count = n, required_votes = public.sv_required(n)
   where id = p_id;
  perform public.sv_log(p_id, 'opened', jsonb_build_object('eligible', n, 'required', public.sv_required(n), 'closes_at', p.closes_at));

  perform public.notify(
    e.user_id, 'account', 'staff_vote.opened',
    case when p.confidential then 'A confidential staff vote is open' else 'Staff vote open: ' || p.reference end,
    case when p.confidential then 'Your vote is needed. Open Staff tools to read it.' else left(p.title, 120) end,
    '/admin/votes/' || p_id::text, 'staff_vote.opened:' || p_id::text)
    from public.staff_vote_eligibility e where e.proposal_id = p_id;
end;
$$;

-- Counts the votes and, if the vote is decided or its time is up, writes the one result. Caller holds the row lock.
-- Returns true when the proposal was closed.
create function public.sv_settle(p_id uuid, p_deadline boolean)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  p public.staff_proposals;
  f integer; a integer; ab integer;
  result text;
  how text;
  digest text;
begin
  select * into p from public.staff_proposals where id = p_id;
  if p.status <> 'active' then
    return false;
  end if;

  select count(*) filter (where choice = 'for'), count(*) filter (where choice = 'against'), count(*) filter (where choice = 'abstain')
    into f, a, ab from public.staff_votes where proposal_id = p_id;

  if f >= p.required_votes then result := 'approved'; how := 'threshold';
  elsif a >= p.required_votes then result := 'rejected'; how := 'threshold';
  elsif p_deadline then result := 'unresolved'; how := 'deadline';
  else return false;
  end if;

  select encode(sha256(convert_to(coalesce(string_agg(voter_id::text || ':' || choice, ',' order by voter_id), ''), 'utf8')), 'hex')
    into digest from public.staff_votes where proposal_id = p_id;

  insert into public.staff_vote_results (proposal_id, eligible_count, required_votes, for_count, against_count, abstain_count, outcome, closed_by, ballot_digest)
  values (p_id, p.eligible_count, p.required_votes, f, a, ab, result, how, digest);
  update public.staff_proposals set status = result, closed_at = now() where id = p_id;

  perform public.sv_log(p_id, 'closed', jsonb_build_object(
    'outcome', result, 'closed_by', how, 'for', f, 'against', a, 'abstain', ab,
    'eligible', p.eligible_count, 'required', p.required_votes, 'ballot_digest', digest));
  perform public.write_audit('staff_vote.closed', 'staff_proposal', p_id::text,
    jsonb_build_object('reference', p.reference, 'outcome', result));

  perform public.notify(
    e.user_id, 'account', 'staff_vote.closed',
    case when p.confidential then 'A confidential staff vote has closed' else 'Staff vote closed: ' || p.reference end,
    case when p.confidential then 'Open Staff tools to see the result.' else left(p.title, 100) || ' - ' || result end,
    '/admin/votes/' || p_id::text, 'staff_vote.closed:' || p_id::text)
    from public.staff_vote_eligibility e where e.proposal_id = p_id;
  return true;
end;
$$;

-- Moves one proposal forward if its time has come (opens a scheduled vote, closes a finished one).
create function public.sv_advance(p_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  p public.staff_proposals;
begin
  select * into p from public.staff_proposals where id = p_id for update;
  if not found then
    return;
  end if;
  if p.status = 'pending' and p.opens_at <= now() then
    begin
      perform public.sv_open(p_id);
    exception when check_violation then
      update public.staff_proposals set status = 'cancelled', cancel_reason = 'Not enough eligible staff when the vote was due to open.' where id = p_id;
      perform public.sv_log(p_id, 'cancelled_by_system', jsonb_build_object('reason', 'not_enough_eligible_staff'));
    end;
    select * into p from public.staff_proposals where id = p_id;
  end if;
  if p.status = 'active' and p.closes_at <= now() then
    perform public.sv_settle(p_id, true);
  end if;
end;
$$;

create function public.sv_advance_all()
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r record;
begin
  for r in select id from public.staff_proposals
            where (status = 'pending' and opens_at <= now()) or (status = 'active' and closes_at <= now())
            order by closes_at loop
    perform public.sv_advance(r.id);
  end loop;
end;
$$;

-- For the scheduled job (see docs/SCHEDULED_JOBS.md).
create function public.staff_vote_tick()
returns void
language sql security definer set search_path = ''
as $$ select public.sv_advance_all(); $$;

-- ---------------------------------------------------------------------------
-- Writing proposals
-- ---------------------------------------------------------------------------

create function public.create_staff_proposal(
  p_title text, p_description text, p_reason text, p_confidential boolean, p_no_override_confirmed boolean
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  allowed jsonb := coalesce((select value from public.platform_settings where key = 'staff_vote.proposer_roles'), '[]'::jsonb);
  new_id uuid;
  ref text;
begin
  perform public.sv_need_staff();
  if not exists (select 1 from public.admin_roles r where r.user_id = uid and allowed ? (r.role::text)) then
    raise exception 'Your role cannot create proposals.' using errcode = 'insufficient_privilege';
  end if;
  if not coalesce(p_no_override_confirmed, false) then
    raise exception 'Confirm that this proposal does not ask staff to override legal, security or emergency duties.' using errcode = 'check_violation';
  end if;
  perform public.enforce_rate_limit('staff_proposal', 10, 1440);

  ref := 'SV-' || to_char(now() at time zone 'Africa/Lusaka', 'YYYY') || '-' || lpad(nextval('public.staff_proposal_seq')::text, 4, '0');
  insert into public.staff_proposals (reference, title, description, reason, proposer_id, confidential, no_override_confirmed)
  values (ref, btrim(p_title), btrim(p_description), btrim(p_reason), uid, coalesce(p_confidential, false), true)
  returning id into new_id;
  perform public.sv_log(new_id, 'created', jsonb_build_object('reference', ref, 'confidential', coalesce(p_confidential, false)));
  perform public.write_audit('staff_vote.created', 'staff_proposal', new_id::text, jsonb_build_object('reference', ref));
  return new_id;
end;
$$;

create function public.update_staff_proposal(p_id uuid, p_title text, p_description text, p_reason text, p_confidential boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  p public.staff_proposals;
begin
  perform public.sv_need_staff();
  select * into p from public.staff_proposals where id = p_id for update;
  if not found or p.proposer_id <> (select auth.uid()) or p.status <> 'draft' then
    raise exception 'Only the proposer can edit a draft.' using errcode = 'insufficient_privilege';
  end if;
  update public.staff_proposals
     set title = btrim(p_title), description = btrim(p_description), reason = btrim(p_reason),
         confidential = coalesce(p_confidential, confidential)
   where id = p_id;
  perform public.sv_log(p_id, 'edited', '{}');
end;
$$;

-- Submits a draft. With no start time (or one that is already due) the vote opens straight away.
create function public.submit_staff_proposal(p_id uuid, p_opens_at timestamptz, p_closes_at timestamptz)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  p public.staff_proposals;
  starts timestamptz := coalesce(p_opens_at, now());
  min_h numeric := public.setting_numeric('staff_vote.min_hours', 24);
  max_h numeric := public.setting_numeric('staff_vote.max_hours', 336);
  hours numeric;
begin
  perform public.sv_need_staff();
  select * into p from public.staff_proposals where id = p_id for update;
  if not found or p.proposer_id <> (select auth.uid()) then
    raise exception 'Only the proposer can submit this.' using errcode = 'insufficient_privilege';
  end if;
  if p.status <> 'draft' then
    raise exception 'Only a draft can be submitted.' using errcode = 'check_violation';
  end if;
  if p_closes_at is null then
    raise exception 'Choose when voting closes.' using errcode = 'check_violation';
  end if;
  if starts < now() - interval '5 minutes' then
    raise exception 'The start time is in the past.' using errcode = 'check_violation';
  end if;
  hours := extract(epoch from (p_closes_at - greatest(starts, now()))) / 3600;
  if hours < min_h or hours > max_h then
    raise exception 'Voting must stay open between % and % hours.', min_h, max_h using errcode = 'check_violation';
  end if;

  update public.staff_proposals set opens_at = greatest(starts, now()), closes_at = p_closes_at,
         status = case when starts <= now() + interval '1 minute' then 'draft' else 'pending' end
   where id = p_id;
  -- 'draft' above is a placeholder so the row passes its own checks; the next step decides the real state.
  if starts <= now() + interval '1 minute' then
    perform public.sv_open(p_id);
  else
    perform public.sv_log(p_id, 'scheduled', jsonb_build_object('opens_at', starts, 'closes_at', p_closes_at));
  end if;
  perform public.write_audit('staff_vote.submitted', 'staff_proposal', p_id::text, jsonb_build_object('reference', p.reference));
  return (select status from public.staff_proposals where id = p_id);
end;
$$;

create function public.cancel_staff_proposal(p_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  p public.staff_proposals;
  uid uuid := (select auth.uid());
begin
  perform public.sv_need_staff();
  if p_reason is null or char_length(btrim(p_reason)) < 3 then
    raise exception 'Write a short reason.' using errcode = 'check_violation';
  end if;
  perform public.sv_advance(p_id);
  select * into p from public.staff_proposals where id = p_id for update;
  if not found then
    raise exception 'Proposal not found.' using errcode = 'no_data_found';
  end if;
  if p.status in ('approved', 'rejected', 'unresolved', 'cancelled') then
    raise exception 'This proposal is already closed.' using errcode = 'check_violation';
  end if;

  if p.status in ('draft', 'pending') then
    if p.proposer_id <> uid and not public.has_staff_role('tech_admin') then
      raise exception 'Only the proposer or a technical admin can cancel this.' using errcode = 'insufficient_privilege';
    end if;
  else
    -- Stopping a live vote needs a technical admin who did not write the proposal.
    if not public.has_staff_role('tech_admin') or p.proposer_id = uid then
      raise exception 'A live vote can only be cancelled by a technical admin who is not the proposer.' using errcode = 'insufficient_privilege';
    end if;
  end if;

  update public.staff_proposals set status = 'cancelled', cancel_reason = left(btrim(p_reason), 500), closed_at = now() where id = p_id;
  perform public.sv_log(p_id, 'cancelled', jsonb_build_object('previous_status', p.status, 'reason', left(btrim(p_reason), 500)));
  perform public.write_audit('staff_vote.cancelled', 'staff_proposal', p_id::text,
    jsonb_build_object('reference', p.reference, 'previous_status', p.status));
end;
$$;

-- An unresolved proposal can be put to the vote again as a new proposal (new reference, new draft).
create function public.resubmit_staff_proposal(p_id uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  p public.staff_proposals;
  uid uuid := (select auth.uid());
  new_id uuid;
  ref text;
begin
  perform public.sv_need_staff();
  perform public.sv_advance(p_id);
  select * into p from public.staff_proposals where id = p_id for update;
  if not found or p.status <> 'unresolved' then
    raise exception 'Only an unresolved proposal can be resubmitted.' using errcode = 'check_violation';
  end if;
  if p.proposer_id <> uid and not public.has_staff_role('tech_admin') then
    raise exception 'Only the proposer or a technical admin can resubmit this.' using errcode = 'insufficient_privilege';
  end if;
  if exists (select 1 from public.staff_proposals where resubmitted_from = p_id) then
    raise exception 'This proposal was already resubmitted.' using errcode = 'unique_violation';
  end if;
  perform public.enforce_rate_limit('staff_proposal', 10, 1440);

  ref := 'SV-' || to_char(now() at time zone 'Africa/Lusaka', 'YYYY') || '-' || lpad(nextval('public.staff_proposal_seq')::text, 4, '0');
  insert into public.staff_proposals (reference, title, description, reason, proposer_id, confidential, no_override_confirmed, resubmitted_from)
  values (ref, p.title, p.description, p.reason, uid, p.confidential, true, p_id)
  returning id into new_id;
  perform public.sv_log(new_id, 'created', jsonb_build_object('reference', ref, 'resubmitted_from', p.reference));
  perform public.sv_log(p_id, 'resubmitted', jsonb_build_object('new_reference', ref));
  perform public.write_audit('staff_vote.resubmitted', 'staff_proposal', new_id::text, jsonb_build_object('from', p.reference, 'reference', ref));
  return new_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Voting
-- ---------------------------------------------------------------------------

-- Returns the proposal's status afterwards ('active' if still open, or the final outcome if this vote decided it).
create function public.cast_staff_vote(p_id uuid, p_choice text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  p public.staff_proposals;
  uid uuid := (select auth.uid());
begin
  perform public.sv_need_staff();
  if p_choice is null or p_choice not in ('for', 'against', 'abstain') then
    raise exception 'Choose for, against or abstain.' using errcode = 'check_violation';
  end if;

  perform public.sv_advance(p_id);
  select * into p from public.staff_proposals where id = p_id for update;
  if not found or p.status = 'draft' then
    raise exception 'Proposal not found.' using errcode = 'no_data_found';
  end if;
  if p.status <> 'active' then
    raise exception 'This vote is not open.' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.staff_vote_eligibility where proposal_id = p_id and user_id = uid) then
    raise exception 'You were not eligible when this vote opened.' using errcode = 'insufficient_privilege';
  end if;
  if exists (select 1 from public.staff_votes where proposal_id = p_id and voter_id = uid) then
    raise exception 'You have already voted. A vote cannot be changed.' using errcode = 'unique_violation';
  end if;

  insert into public.staff_votes (proposal_id, voter_id, choice) values (p_id, uid, p_choice);
  perform public.sv_log(p_id, 'vote_cast', '{}'); -- the choice is deliberately not recorded here
  perform public.sv_settle(p_id, false);
  return (select status from public.staff_proposals where id = p_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------

-- One place that decides what a staff member may see of a proposal.
create function public.sv_view(p_id uuid, p_section text)
returns table (
  id uuid, reference text, title text, description text, reason text, status text, confidential boolean,
  proposer_id uuid, proposer_name text, created_at timestamptz, opens_at timestamptz, closes_at timestamptz,
  opened_at timestamptz, closed_at timestamptz, eligible_count integer, required_votes integer,
  for_count integer, against_count integer, abstain_count integer, counts_hidden boolean, outcome text,
  my_choice text, i_am_proposer boolean, can_vote boolean, resubmitted_from uuid, resubmitted_as uuid,
  cancel_reason text, voted_count integer
)
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
begin
  perform public.sv_need_staff();
  perform public.sv_advance_all();
  return query
  select p.id, p.reference, p.title, p.description, p.reason, p.status, p.confidential,
         p.proposer_id, pr.display_name, p.created_at, p.opens_at, p.closes_at, p.opened_at, p.closed_at,
         p.eligible_count, p.required_votes,
         case when hide.hidden then null else t.f end,
         case when hide.hidden then null else t.a end,
         case when hide.hidden then null else t.ab end,
         hide.hidden,
         case when p.status in ('approved', 'rejected', 'unresolved') then p.status else null end,
         mv.choice, p.proposer_id = uid,
         p.status = 'active' and p.closes_at > now() and mv.choice is null
           and exists (select 1 from public.staff_vote_eligibility e where e.proposal_id = p.id and e.user_id = uid),
         p.resubmitted_from,
         (select c.id from public.staff_proposals c where c.resubmitted_from = p.id),
         p.cancel_reason,
         t.n
    from public.staff_proposals p
    join public.profiles pr on pr.id = p.proposer_id
    cross join lateral (
      select (p.confidential and p.status in ('pending', 'active')) as hidden
    ) hide
    left join lateral (
      select count(*) filter (where v.choice = 'for')::integer as f,
             count(*) filter (where v.choice = 'against')::integer as a,
             count(*) filter (where v.choice = 'abstain')::integer as ab,
             count(*)::integer as n
        from public.staff_votes v where v.proposal_id = p.id
    ) t on true
    left join public.staff_votes mv on mv.proposal_id = p.id and mv.voter_id = uid
   where (p_id is null or p.id = p_id)
     and (p.status <> 'draft' or p.proposer_id = uid)
     and case coalesce(p_section, '')
           when 'active' then p.status = 'active'
           when 'upcoming' then p.status = 'pending'
           when 'completed' then p.status in ('approved', 'rejected')
           when 'unresolved' then p.status = 'unresolved'
           when 'mine' then p.proposer_id = uid
           else true
         end
   order by case when p.status = 'active' then 0 else 1 end, coalesce(p.closed_at, p.closes_at, p.created_at) desc;
end;
$$;

create function public.list_staff_proposals(p_section text default null)
returns table (
  id uuid, reference text, title text, description text, reason text, status text, confidential boolean,
  proposer_id uuid, proposer_name text, created_at timestamptz, opens_at timestamptz, closes_at timestamptz,
  opened_at timestamptz, closed_at timestamptz, eligible_count integer, required_votes integer,
  for_count integer, against_count integer, abstain_count integer, counts_hidden boolean, outcome text,
  my_choice text, i_am_proposer boolean, can_vote boolean, resubmitted_from uuid, resubmitted_as uuid,
  cancel_reason text, voted_count integer
)
language sql security definer set search_path = ''
as $$ select * from public.sv_view(null, p_section); $$;

create function public.get_staff_proposal(p_id uuid)
returns table (
  id uuid, reference text, title text, description text, reason text, status text, confidential boolean,
  proposer_id uuid, proposer_name text, created_at timestamptz, opens_at timestamptz, closes_at timestamptz,
  opened_at timestamptz, closed_at timestamptz, eligible_count integer, required_votes integer,
  for_count integer, against_count integer, abstain_count integer, counts_hidden boolean, outcome text,
  my_choice text, i_am_proposer boolean, can_vote boolean, resubmitted_from uuid, resubmitted_as uuid,
  cancel_reason text, voted_count integer
)
language sql security definer set search_path = ''
as $$ select * from public.sv_view(p_id, null); $$;

-- My own voting history: only my own choices.
create function public.my_staff_votes()
returns table (proposal_id uuid, reference text, title text, confidential boolean, my_choice text, cast_at timestamptz, status text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.sv_need_staff();
  return query
  select p.id, p.reference, p.title, p.confidential, v.choice, v.cast_at, p.status
    from public.staff_votes v join public.staff_proposals p on p.id = v.proposal_id
   where v.voter_id = (select auth.uid())
   order by v.cast_at desc;
end;
$$;

-- What the current staff member is allowed to do here (the app uses it only to decide what to show).
create function public.my_staff_vote_access()
returns table (is_staff boolean, can_propose boolean, can_audit boolean)
language plpgsql stable security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  allowed jsonb := coalesce((select value from public.platform_settings where key = 'staff_vote.proposer_roles'), '[]'::jsonb);
begin
  return query select public.is_staff(),
    public.is_staff() and exists (select 1 from public.admin_roles r where r.user_id = uid and allowed ? (r.role::text)),
    public.has_staff_role('tech_admin');
end;
$$;

-- Individual ballots: technical admin only, only after the vote has closed, never for a confidential matter.
create function public.staff_vote_ballots(p_id uuid)
returns table (voter_id uuid, voter_name text, choice text, cast_at timestamptz)
language plpgsql security definer set search_path = ''
as $$
declare
  p public.staff_proposals;
begin
  if not public.has_staff_role('tech_admin') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  select * into p from public.staff_proposals where id = p_id;
  if not found or p.status not in ('approved', 'rejected', 'unresolved') then
    raise exception 'Individual votes can only be read after a vote closes.' using errcode = 'check_violation';
  end if;
  if p.confidential then
    raise exception 'Individual votes on a confidential matter are never shown.' using errcode = 'insufficient_privilege';
  end if;
  perform public.sv_log(p_id, 'ballots_read', '{}');
  perform public.write_audit('staff_vote.ballots_read', 'staff_proposal', p_id::text, jsonb_build_object('reference', p.reference));
  return query
  select v.voter_id, pr.display_name, v.choice, v.cast_at
    from public.staff_votes v join public.profiles pr on pr.id = v.voter_id
   where v.proposal_id = p_id order by pr.display_name;
end;
$$;

-- The audit trail for one proposal. Technical admins only.
create function public.staff_vote_audit(p_id uuid)
returns table (seq integer, actor_name text, action text, details jsonb, created_at timestamptz, row_hash text)
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('tech_admin') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  return query
  select l.seq, pr.display_name, l.action, l.details, l.created_at, l.row_hash
    from public.staff_vote_audit_logs l left join public.profiles pr on pr.id = l.actor_id
   where l.proposal_id = p_id order by l.seq;
end;
$$;

-- Recomputes the chain. False means a row was changed or removed.
create function public.verify_staff_vote_audit(p_id uuid)
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
declare
  r public.staff_vote_audit_logs;
  prev text := null;
  expected integer := 1;
  hash text;
begin
  if not public.has_staff_role('tech_admin') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  for r in select * from public.staff_vote_audit_logs where proposal_id = p_id order by seq loop
    hash := encode(sha256(convert_to(
      coalesce(prev, '') || '|' || p_id::text || '|' || r.seq::text || '|' || coalesce(r.actor_id::text, '')
      || '|' || r.action || '|' || r.details::text || '|'
      || to_char(r.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'), 'utf8')), 'hex');
    if r.seq <> expected or r.prev_hash is distinct from prev or r.row_hash <> hash then
      return false;
    end if;
    prev := r.row_hash;
    expected := expected + 1;
  end loop;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- Function permissions: closed first, then opened on purpose
-- ---------------------------------------------------------------------------

revoke execute on function
  public.sv_block_change(), public.sv_truncate_block(), public.sv_guard_proposal(), public.sv_guard_vote(), public.sv_guard_result(),
  public.sv_need_staff(), public.sv_log(uuid, text, jsonb), public.sv_required(integer),
  public.sv_open(uuid), public.sv_settle(uuid, boolean), public.sv_advance(uuid), public.sv_advance_all(),
  public.staff_vote_tick(),
  public.create_staff_proposal(text, text, text, boolean, boolean),
  public.update_staff_proposal(uuid, text, text, text, boolean),
  public.submit_staff_proposal(uuid, timestamptz, timestamptz),
  public.cancel_staff_proposal(uuid, text),
  public.resubmit_staff_proposal(uuid),
  public.cast_staff_vote(uuid, text),
  public.sv_view(uuid, text), public.list_staff_proposals(text), public.get_staff_proposal(uuid),
  public.my_staff_votes(), public.my_staff_vote_access(),
  public.staff_vote_ballots(uuid), public.staff_vote_audit(uuid), public.verify_staff_vote_audit(uuid)
from public, anon, authenticated;

grant execute on function
  public.create_staff_proposal(text, text, text, boolean, boolean),
  public.update_staff_proposal(uuid, text, text, text, boolean),
  public.submit_staff_proposal(uuid, timestamptz, timestamptz),
  public.cancel_staff_proposal(uuid, text),
  public.resubmit_staff_proposal(uuid),
  public.cast_staff_vote(uuid, text),
  public.list_staff_proposals(text), public.get_staff_proposal(uuid),
  public.my_staff_votes(), public.my_staff_vote_access(),
  public.staff_vote_ballots(uuid), public.staff_vote_audit(uuid), public.verify_staff_vote_audit(uuid)
to authenticated;

grant execute on function public.staff_vote_tick() to service_role;
