-- 0010: User & Trust Management
--
-- A staff section that is separate from "Staff tools" (which stays about the staff team itself).
-- It lets support and moderators work through verification applications, look at users,
-- review documents, and read the trail of what staff did.
--
-- Rules this migration keeps:
--   * Every read goes through a function that checks the staff role AND two-factor (aal2).
--   * Support can see applications and documents. Moderators can see users and the lists, but not documents.
--   * Opening a document is written to the audit log before the path is handed back.
--   * Nobody can review their own application.
--   * A rejection needs a written reason, because the applicant sees it.
--   * New functions are closed to everyone first, then opened to signed-in users only.

-- ---------------------------------------------------------------------------
-- Stronger review functions (same names and signatures as 0003, so the app keeps working)
-- ---------------------------------------------------------------------------

create or replace function public.review_identity_verification(p_id uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v public.identity_verifications;
  keep_days integer := public.setting_numeric('retention.identity_documents_days', 30);
  note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.has_staff_role('support') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if not p_approve and (note is null or char_length(note) < 3) then
    raise exception 'A rejection needs a reason the applicant can read.' using errcode = 'check_violation';
  end if;

  select * into v from public.identity_verifications where id = p_id and status = 'pending' for update;
  if not found then
    raise exception 'No pending request with that id.' using errcode = 'no_data_found';
  end if;
  if v.user_id = (select auth.uid()) then
    raise exception 'You cannot review your own application.' using errcode = 'insufficient_privilege';
  end if;

  update public.identity_verifications
     set status = case when p_approve then 'approved'::public.review_status else 'rejected'::public.review_status end,
         reviewed_by = (select auth.uid()), reviewed_at = now(),
         reviewer_note = left(note, 500),
         purge_after = now() + make_interval(days => keep_days)
   where id = p_id;

  if p_approve then
    update public.profiles set verification_level = 'identity_verified' where id = v.user_id;
  end if;

  perform public.write_audit('identity.reviewed', 'user', v.user_id::text,
    jsonb_build_object('approved', p_approve, 'application_id', p_id, 'note', left(note, 500)));
end;
$$;

create or replace function public.review_business_verification(p_id uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v public.business_verifications;
  owner uuid;
  note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.has_staff_role('support') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if not p_approve and (note is null or char_length(note) < 3) then
    raise exception 'A rejection needs a reason the applicant can read.' using errcode = 'check_violation';
  end if;

  select * into v from public.business_verifications where id = p_id and status = 'pending' for update;
  if not found then
    raise exception 'No pending request with that id.' using errcode = 'no_data_found';
  end if;
  select owner_id into owner from public.businesses where id = v.business_id;
  if owner = (select auth.uid()) then
    raise exception 'You cannot review your own application.' using errcode = 'insufficient_privilege';
  end if;

  update public.business_verifications
     set status = case when p_approve then 'approved'::public.review_status else 'rejected'::public.review_status end,
         reviewed_by = (select auth.uid()), reviewed_at = now(), reviewer_note = left(note, 500)
   where id = p_id;

  update public.businesses
     set verification_status = case when p_approve then 'verified'::public.business_verification_status
                                    else 'rejected'::public.business_verification_status end
   where id = v.business_id;

  perform public.write_audit('business.reviewed', 'business', v.business_id::text,
    jsonb_build_object('approved', p_approve, 'application_id', p_id, 'note', left(note, 500)));
end;
$$;

-- ---------------------------------------------------------------------------
-- Who may read this section
-- ---------------------------------------------------------------------------

create function public.trust_can_read()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.has_staff_role('support') or public.has_staff_role('moderator');
$$;

-- ---------------------------------------------------------------------------
-- Applications: pending, approved (verified) and rejected, for people and businesses
-- ---------------------------------------------------------------------------

create function public.trust_applications(
  p_kind text,
  p_status public.review_status default 'pending',
  p_search text default null,
  p_limit integer default 30,
  p_offset integer default 0
)
returns table (
  kind text,
  id uuid,
  subject_id uuid,
  subject_user_id uuid,
  subject_name text,
  detail text,
  status public.review_status,
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewer_id uuid,
  reviewer_name text,
  reviewer_note text,
  has_document boolean
)
language plpgsql stable security definer set search_path = ''
as $$
declare
  lim integer := least(greatest(coalesce(p_limit, 30), 1), 100);
  off integer := greatest(coalesce(p_offset, 0), 0);
  term text := lower(btrim(coalesce(p_search, '')));
begin
  if not public.trust_can_read() then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if p_kind not in ('identity', 'business') then
    raise exception 'Kind must be identity or business.' using errcode = 'invalid_parameter_value';
  end if;

  if p_kind = 'identity' then
    return query
      select 'identity'::text, iv.id, iv.user_id, iv.user_id, p.display_name,
             replace(iv.document_type, '_', ' '), iv.status, iv.created_at, iv.reviewed_at,
             iv.reviewed_by, r.display_name, iv.reviewer_note, (iv.document_path is not null)
        from public.identity_verifications iv
        join public.profiles p on p.id = iv.user_id
        left join public.profiles r on r.id = iv.reviewed_by
       where iv.status = p_status
         and (term = '' or strpos(lower(p.display_name), term) > 0)
       order by case when p_status = 'pending' then iv.created_at end asc,
                coalesce(iv.reviewed_at, iv.created_at) desc
       limit lim offset off;
  else
    return query
      select 'business'::text, bv.id, b.id, b.owner_id, b.name,
             'registration ' || bv.registration_number, bv.status, bv.created_at, bv.reviewed_at,
             bv.reviewed_by, r.display_name, bv.reviewer_note, (bv.document_path is not null)
        from public.business_verifications bv
        join public.businesses b on b.id = bv.business_id
        left join public.profiles r on r.id = bv.reviewed_by
       where bv.status = p_status
         and (term = '' or strpos(lower(b.name), term) > 0)
       order by case when p_status = 'pending' then bv.created_at end asc,
                coalesce(bv.reviewed_at, bv.created_at) desc
       limit lim offset off;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Users: verified, suspended, restricted, or everyone
-- ---------------------------------------------------------------------------

create function public.trust_users(
  p_filter text default 'all',
  p_search text default null,
  p_limit integer default 30,
  p_offset integer default 0
)
returns table (
  id uuid,
  display_name text,
  verification_level public.verification_level,
  account_state public.account_state,
  joined_at timestamptz,
  state_reason text,
  state_changed_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $$
declare
  lim integer := least(greatest(coalesce(p_limit, 30), 1), 100);
  off integer := greatest(coalesce(p_offset, 0), 0);
  term text := lower(btrim(coalesce(p_search, '')));
begin
  if not public.trust_can_read() then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if p_filter not in ('all', 'verified', 'suspended', 'restricted') then
    raise exception 'Filter must be all, verified, suspended or restricted.' using errcode = 'invalid_parameter_value';
  end if;

  return query
    select p.id, p.display_name, p.verification_level, p.account_state, p.created_at,
           last_change.metadata ->> 'reason', last_change.created_at
      from public.profiles p
      left join lateral (
        select a.metadata, a.created_at
          from public.audit_logs a
         where a.action = 'account.state_changed' and a.target_id = p.id::text
         order by a.id desc limit 1
      ) last_change on p.account_state <> 'active'
     where (p_filter = 'all'
            or (p_filter = 'verified' and p.verification_level = 'identity_verified')
            or (p_filter = 'suspended' and p.account_state = 'suspended')
            or (p_filter = 'restricted' and p.account_state = 'restricted'))
       and (term = '' or strpos(lower(p.display_name), term) > 0)
     order by case when p_filter in ('suspended', 'restricted') then last_change.created_at end desc nulls last,
              p.created_at desc
     limit lim offset off;
end;
$$;

-- ---------------------------------------------------------------------------
-- One user's profile, as staff see it
-- ---------------------------------------------------------------------------

create function public.trust_user_profile(p_user uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  p public.profiles;
  last_change record;
begin
  if not public.trust_can_read() then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;

  select * into p from public.profiles where id = p_user;
  if not found then
    raise exception 'User not found.' using errcode = 'no_data_found';
  end if;

  select a.metadata, a.created_at into last_change
    from public.audit_logs a
   where a.action = 'account.state_changed' and a.target_id = p_user::text
   order by a.id desc limit 1;

  return jsonb_build_object(
    'id', p.id,
    'display_name', p.display_name,
    'bio', p.bio,
    'verification_level', p.verification_level,
    'account_state', p.account_state,
    'joined_at', p.created_at,
    'state_reason', case when p.account_state <> 'active' then last_change.metadata ->> 'reason' end,
    'state_changed_at', case when p.account_state <> 'active' then last_change.created_at end,
    'staff_roles', (select coalesce(jsonb_agg(r.role order by r.role), '[]'::jsonb) from public.admin_roles r where r.user_id = p_user),
    'listings_total', (select count(*) from public.listings where seller_id = p_user),
    'listings_active', (select count(*) from public.listings where seller_id = p_user and status = 'active'),
    'orders_as_buyer', (select count(*) from public.orders where buyer_id = p_user),
    'orders_as_seller', (select count(*) from public.orders where seller_id = p_user),
    'orders_completed', (select count(*) from public.orders where (buyer_id = p_user or seller_id = p_user) and status = 'completed'),
    'disputes_opened', (select count(*) from public.disputes where opened_by = p_user),
    'reports_against', (select count(*) from public.reports where target_type = 'user' and target_id = p_user),
    'reports_open_against', (select count(*) from public.reports where target_type = 'user' and target_id = p_user and status = 'open'),
    'businesses', (
      select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'verification_status', b.verification_status) order by b.created_at), '[]'::jsonb)
        from public.businesses b where b.owner_id = p_user
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Verification history: every application a person (or their businesses) ever made
-- ---------------------------------------------------------------------------

create function public.trust_verification_history(p_user uuid)
returns table (
  kind text,
  id uuid,
  subject_name text,
  detail text,
  status public.review_status,
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewer_id uuid,
  reviewer_name text,
  reviewer_note text
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.trust_can_read() then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;

  return query
    select * from (
      select 'identity'::text as kind, iv.id, p.display_name as subject_name,
             replace(iv.document_type, '_', ' ') as detail, iv.status,
             iv.created_at as submitted_at, iv.reviewed_at, iv.reviewed_by as reviewer_id,
             r.display_name as reviewer_name, iv.reviewer_note
        from public.identity_verifications iv
        join public.profiles p on p.id = iv.user_id
        left join public.profiles r on r.id = iv.reviewed_by
       where iv.user_id = p_user
      union all
      select 'business', bv.id, b.name, 'registration ' || bv.registration_number, bv.status,
             bv.created_at, bv.reviewed_at, bv.reviewed_by, r.display_name, bv.reviewer_note
        from public.business_verifications bv
        join public.businesses b on b.id = bv.business_id
        left join public.profiles r on r.id = bv.reviewed_by
       where b.owner_id = p_user
    ) h
    order by h.submitted_at desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- Document review. The audit entry is written first; only support may open documents.
-- The app then asks storage for a short-lived signed link using the path returned here.
-- ---------------------------------------------------------------------------

create function public.trust_open_document(p_kind text, p_id uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  path text;
  subject uuid;
begin
  if not public.has_staff_role('support') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;

  if p_kind = 'identity' then
    select document_path, user_id into path, subject from public.identity_verifications where id = p_id;
  elsif p_kind = 'business' then
    select bv.document_path, b.owner_id into path, subject
      from public.business_verifications bv join public.businesses b on b.id = bv.business_id
     where bv.id = p_id;
  else
    raise exception 'Kind must be identity or business.' using errcode = 'invalid_parameter_value';
  end if;

  if not found then
    raise exception 'Application not found.' using errcode = 'no_data_found';
  end if;
  if path is null then
    raise exception 'No document is stored for this application.' using errcode = 'no_data_found';
  end if;

  perform public.write_audit('document.viewed', 'user', subject::text,
    jsonb_build_object('kind', p_kind, 'application_id', p_id));
  return path;
end;
$$;

-- ---------------------------------------------------------------------------
-- Audit trail. Technical admins see everything. Support and moderators see only the
-- actions that belong to this section, so they can follow a case without reading
-- everything else staff did.
-- ---------------------------------------------------------------------------

create function public.trust_audit_trail(
  p_target_type text default null,
  p_target_id text default null,
  p_actor uuid default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id bigint,
  created_at timestamptz,
  actor_id uuid,
  actor_name text,
  action text,
  target_type text,
  target_id text,
  metadata jsonb
)
language plpgsql stable security definer set search_path = ''
as $$
declare
  lim integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  off integer := greatest(coalesce(p_offset, 0), 0);
  everything boolean := public.has_staff_role('tech_admin');
begin
  if not (everything or public.trust_can_read()) then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;

  return query
    select a.id, a.created_at, a.actor_id, p.display_name, a.action, a.target_type, a.target_id, a.metadata
      from public.audit_logs a
      left join public.profiles p on p.id = a.actor_id
     where (everything or a.action in ('identity.reviewed', 'business.reviewed', 'account.state_changed', 'document.viewed'))
       and (p_target_type is null or a.target_type = p_target_type)
       and (p_target_id is null or a.target_id = p_target_id)
       and (p_actor is null or a.actor_id = p_actor)
     order by a.id desc
     limit lim offset off;
end;
$$;

-- Document views are saved against the person the document belongs to, so the trail for a
-- user shows reviews, state changes and every time someone opened their documents.
create index if not exists audit_logs_action_idx on public.audit_logs (action, id desc);

-- ---------------------------------------------------------------------------
-- Permissions: closed first, then opened on purpose
-- ---------------------------------------------------------------------------

revoke execute on function
  public.trust_can_read(),
  public.trust_applications(text, public.review_status, text, integer, integer),
  public.trust_users(text, text, integer, integer),
  public.trust_user_profile(uuid),
  public.trust_verification_history(uuid),
  public.trust_open_document(text, uuid),
  public.trust_audit_trail(text, text, uuid, integer, integer)
from public, anon, authenticated;

grant execute on function
  public.trust_applications(text, public.review_status, text, integer, integer),
  public.trust_users(text, text, integer, integer),
  public.trust_user_profile(uuid),
  public.trust_verification_history(uuid),
  public.trust_open_document(text, uuid),
  public.trust_audit_trail(text, text, uuid, integer, integer)
to authenticated;
