-- 0023: Seller onboarding (individual seller application, verification and publishing gate).
--
-- Every person starts as a buyer. Becoming an individual seller is optional and is a reviewed application:
--   draft -> submitted -> under_review -> approved | rejected, with additional_information_required in between,
--   and approved -> suspended -> approved again, or approved/suspended -> revoked.
--
-- What approval does: it activates the seller features that already exist, on the same profile
-- (profiles.seller_status becomes 'active'). It never creates a second account. Suspension or revocation switches
-- selling off, pauses live listings (they stay in the database, with their history) and keeps every record.
--
-- The rules enforced here, in the database:
--   * Only seller_status = 'active' may create listings or publish them (see seller_can_publish). Applicants, rejected
--     applicants, buyers and suspended sellers cannot. Trusted server-side work (no signed-in user) is unaffected.
--   * Support officers review, with a staff role AND two-factor (aal2). Nobody reviews their own application.
--   * Higher-risk applications (large catalogues, categories that need review, a manual escalation) need an
--     interview on record and TWO different officers to approve. Rejecting needs only one (the safe direction).
--   * Sensitive details (ID number, residential address) live in their own closed table and are read only through an
--     audited function. Documents are registered after upload, checked (type, size, folder, real object), scanned
--     (the scanner reports through verification_record_scan) and opened only through an audited function that hands
--     the path to a server that signs a very short-lived link (see supabase/functions/verification-document-url).
--   * Documents are deleted automatically after a configurable time (verification_documents_due and
--     verification_mark_deleted, for the purge worker).
--   * History is permanent: verification_events cannot be edited or deleted.
--
-- Tables are closed (RLS on, no grants for app users). Everything goes through functions.
-- Business applications reuse verification_documents, verification_events and the same review rules (next migration).

-- ---------------------------------------------------------------------------
-- 1. Settings
-- ---------------------------------------------------------------------------
insert into public.platform_settings (key, value, note) values
  ('seller.high_risk_catalogue_size', '200', 'Expected catalogue size at which an application needs two reviewers. Starter value.'),
  ('seller.reapply_days', '7', 'Days a rejected applicant waits before applying again. Starter value.'),
  ('retention.verification_rejected_days', '30', 'Days to keep documents after an application is rejected or withdrawn. Starter value.'),
  ('retention.verification_approved_days', '365', 'Days to keep documents after an application is approved. Starter value.'),
  ('verification.document_url_seconds', '60', 'How long a signed document link lasts, in seconds (the server never signs for longer than 300).'),
  ('verification.info_request_days', '14', 'Days an applicant has to answer a request for more information. Starter value.'),
  ('rate_limit.verification_upload.max', '40', 'Verification documents per person per window. Starter value.'),
  ('rate_limit.verification_upload.window_minutes', '1440', null)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Seller status on the profile (the switch that approval turns on)
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column seller_status text not null default 'none' check (seller_status in ('none', 'active', 'suspended', 'revoked'));
-- profiles grants allow app users to update only display_name, bio, avatar_path and location_id, so this column
-- can be changed only by the functions below.

create function public.seller_can_publish(p_user uuid default null)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select p.seller_status = 'active' and p.account_state = 'active'
                     from public.profiles p where p.id = coalesce(p_user, (select auth.uid()))), false)
$$;

-- ---------------------------------------------------------------------------
-- 3. Agreement
-- ---------------------------------------------------------------------------
create table public.seller_agreements (
  version integer primary key,
  title text not null,
  body text not null,
  is_current boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index seller_agreements_one_current on public.seller_agreements ((true)) where is_current;
insert into public.seller_agreements (version, title, body, is_current) values
  (1, 'ZedMarket seller agreement',
   'DRAFT FOR LEGAL REVIEW. By selling on ZedMarket I confirm that: (1) every detail in my application is true and I will keep it up to date; (2) I will list only items I am legally allowed to sell and that are as described; (3) I will not sell counterfeit, stolen or prohibited items; (4) I will honour the returns and warranty terms I state on my listings; (5) I will answer buyers promptly and handle their orders fairly; (6) ZedMarket may check my documents, ask me for more evidence, interview me, and suspend or end my selling if I break these rules; (7) my personal documents are used only to verify me and are deleted after the retention period.',
   true);

create table public.seller_agreement_acceptances (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  version integer not null references public.seller_agreements (version),
  application_id uuid,
  accepted_at timestamptz not null default now(),
  unique (user_id, version)
);

-- ---------------------------------------------------------------------------
-- 4. Applications
-- ---------------------------------------------------------------------------
create table public.seller_applications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'draft' check (status in
    ('draft', 'submitted', 'under_review', 'additional_information_required', 'approved', 'rejected', 'suspended', 'revoked')),
  legal_name text check (char_length(legal_name) between 3 and 120),
  nationality text check (char_length(nationality) between 2 and 60),
  is_adult boolean,
  id_type text check (id_type in ('nrc', 'passport')),
  selling_location_id integer references public.locations (id),
  category_ids integer[] not null default '{}',
  sourcing_type text check (sourcing_type in ('own_goods', 'local_purchase', 'import', 'manufacturer', 'other')),
  sourcing_info text check (char_length(sourcing_info) between 10 and 1000),
  experience_level text check (experience_level in ('none', 'under_1_year', 'one_to_three_years', 'over_three_years')),
  experience_info text check (char_length(experience_info) <= 1000),
  expected_catalogue_size integer check (expected_catalogue_size between 1 and 100000),
  returns_arrangements text check (char_length(returns_arrangements) between 10 and 1000),
  customer_service_arrangements text check (char_length(customer_service_arrangements) between 10 and 1000),
  declarations jsonb not null default '{}',
  risk_level text check (risk_level in ('standard', 'high')),
  assigned_to uuid references public.profiles (id),
  claimed_at timestamptz,
  escalated boolean not null default false,
  escalation_reason text,
  first_approved_by uuid references public.profiles (id),
  submitted_at timestamptz,
  due_at timestamptz,
  decided_by uuid references public.profiles (id),
  decided_at timestamptz,
  decision_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index seller_one_open_application on public.seller_applications (user_id)
  where status in ('draft', 'submitted', 'under_review', 'additional_information_required');
create unique index seller_one_live_application on public.seller_applications (user_id)
  where status in ('approved', 'suspended');
create index seller_applications_status_idx on public.seller_applications (status, submitted_at);
create trigger seller_applications_updated before update on public.seller_applications
  for each row execute function public.set_updated_at();

-- Sensitive details, kept apart.
create table public.seller_application_private (
  application_id uuid primary key references public.seller_applications (id) on delete cascade,
  id_number text check (char_length(id_number) between 5 and 30),
  residential_address text check (char_length(residential_address) between 10 and 300)
);

-- Documents, for sellers now and businesses in the next migration.
create table public.verification_documents (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  subject_type text not null check (subject_type in ('seller_application', 'business_application')),
  subject_id uuid not null,
  kind text not null check (kind in (
    'id_front', 'id_back', 'passport_page', 'selfie_with_id', 'proof_of_address', 'sourcing_evidence', 'product_evidence',
    'pacra_certificate', 'tpin_certificate', 'permit', 'ownership_evidence', 'authority_letter', 'director_id', 'premises_evidence', 'other')),
  storage_bucket text not null default 'identity-documents' check (storage_bucket in ('identity-documents', 'business-documents')),
  storage_path text not null,
  mime_type text not null check (mime_type in ('image/jpeg', 'image/png', 'application/pdf')),
  size_bytes integer not null check (size_bytes between 1 and 8388608),
  sha256 text check (sha256 ~ '^[0-9a-f]{64}$'),
  scan_status text not null default 'pending' check (scan_status in ('pending', 'clean', 'infected', 'failed')),
  scanned_at timestamptz,
  review_status text not null default 'uploaded' check (review_status in ('uploaded', 'accepted', 'rejected')),
  review_note text check (char_length(review_note) <= 300),
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  purge_after timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  unique (storage_bucket, storage_path)
);
create index verification_documents_subject_idx on public.verification_documents (subject_type, subject_id);
create index verification_documents_purge_idx on public.verification_documents (purge_after) where deleted_at is null;

create table public.verification_requests (
  id uuid primary key default gen_random_uuid(),
  subject_type text not null check (subject_type in ('seller_application', 'business_application')),
  subject_id uuid not null,
  requested_by uuid not null references public.profiles (id),
  message text not null check (char_length(message) between 5 and 1000),
  document_kinds text[] not null default '{}',
  status text not null default 'open' check (status in ('open', 'answered', 'cancelled')),
  response text check (char_length(response) <= 1000),
  due_at timestamptz not null,
  created_at timestamptz not null default now(),
  answered_at timestamptz
);
create index verification_requests_subject_idx on public.verification_requests (subject_type, subject_id, status);

create table public.verification_interviews (
  id uuid primary key default gen_random_uuid(),
  subject_type text not null check (subject_type in ('seller_application', 'business_application')),
  subject_id uuid not null,
  conducted_by uuid not null references public.profiles (id),
  channel text not null check (channel in ('phone', 'video', 'in_person')),
  outcome text not null check (outcome in ('passed', 'failed', 'inconclusive')),
  answers jsonb not null default '[]',
  notes text check (char_length(notes) <= 2000),
  conducted_at timestamptz not null default now()
);
create index verification_interviews_subject_idx on public.verification_interviews (subject_type, subject_id);

create table public.verification_events (
  id bigint generated always as identity primary key,
  subject_type text not null check (subject_type in ('seller_application', 'business_application')),
  subject_id uuid not null,
  applicant_id uuid not null,
  event text not null,
  from_status text,
  to_status text,
  actor_id uuid,
  note text,
  visible_to_applicant boolean not null default false,
  created_at timestamptz not null default clock_timestamp()
);
create index verification_events_subject_idx on public.verification_events (subject_type, subject_id, id);

create function public.verification_events_immutable()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if pg_trigger_depth() > 1 then
    return coalesce(new, old);
  end if;
  raise exception 'The verification history cannot be changed.' using errcode = 'insufficient_privilege';
end;
$$;
create trigger verification_events_no_edit before update or delete on public.verification_events
  for each row execute function public.verification_events_immutable();

alter table public.seller_agreements enable row level security;
alter table public.seller_agreement_acceptances enable row level security;
alter table public.seller_applications enable row level security;
alter table public.seller_application_private enable row level security;
alter table public.verification_documents enable row level security;
alter table public.verification_requests enable row level security;
alter table public.verification_interviews enable row level security;
alter table public.verification_events enable row level security;
-- No grants and no policies on any of them.

-- ---------------------------------------------------------------------------
-- 5. Helpers (internal)
-- ---------------------------------------------------------------------------
create function public.verification_need_support()
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('support') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
end;
$$;

create function public.verification_log(
  p_subject_type text, p_subject_id uuid, p_applicant uuid, p_event text, p_from text, p_to text, p_note text, p_visible boolean
) returns void
language sql security definer set search_path = ''
as $$
  insert into public.verification_events (subject_type, subject_id, applicant_id, event, from_status, to_status, actor_id, note, visible_to_applicant)
  values (p_subject_type, p_subject_id, p_applicant, p_event, p_from, p_to, (select auth.uid()), left(p_note, 1000), p_visible)
$$;

-- Only the status the applicant should read goes into a notice. Never documents, numbers or addresses.
create function public.seller_notify(p_user uuid, p_app uuid, p_title text, p_body text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.notify(p_user, 'account', 'seller_application', p_title, p_body, '/verify/seller',
                        'seller_app:' || p_app || ':' || md5(p_title || p_body || clock_timestamp()::text));
end;
$$;

create function public.seller_required_kinds(p_id_type text)
returns text[]
language sql immutable set search_path = ''
as $$
  select case p_id_type
    when 'nrc' then array['id_front', 'id_back', 'selfie_with_id', 'proof_of_address']
    when 'passport' then array['passport_page', 'selfie_with_id', 'proof_of_address']
    else array[]::text[] end
$$;

-- ---------------------------------------------------------------------------
-- 6. Applicant functions
-- ---------------------------------------------------------------------------
create function public.seller_agreement_current()
returns table (version integer, title text, body text)
language sql stable security definer set search_path = ''
as $$ select a.version, a.title, a.body from public.seller_agreements a where a.is_current $$;

-- Creates the person's draft if they have none, and saves what they send. While information is being asked for, the
-- same call updates the open application. Fields that are not sent are left as they are.
create function public.seller_application_save(p_data jsonb)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  a public.seller_applications;
  prof public.profiles;
  wait_days integer := public.setting_numeric('seller.reapply_days', 7)::integer;
  last_rejected timestamptz;
  cats integer[];
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;
  select * into prof from public.profiles where id = uid;
  if prof.account_state <> 'active' then
    raise exception 'Your account cannot apply right now.' using errcode = 'insufficient_privilege';
  end if;
  if prof.seller_status in ('active', 'suspended', 'revoked') then
    raise exception 'You already have a seller account. Open it from your account.' using errcode = 'check_violation';
  end if;

  select * into a from public.seller_applications
   where user_id = uid and status in ('draft', 'submitted', 'under_review', 'additional_information_required') for update;
  if not found then
    select max(decided_at) into last_rejected from public.seller_applications where user_id = uid and status = 'rejected';
    if last_rejected is not null and last_rejected > now() - make_interval(days => wait_days) then
      raise exception 'You can apply again after % days from the decision.', wait_days using errcode = 'check_violation';
    end if;
    insert into public.seller_applications (user_id) values (uid) returning * into a;
    insert into public.seller_application_private (application_id) values (a.id);
    perform public.verification_log('seller_application', a.id, uid, 'created', null, 'draft', null, true);
  elsif a.status in ('submitted', 'under_review') then
    raise exception 'Your application is being reviewed and cannot be changed now.' using errcode = 'check_violation';
  end if;

  if p_data ? 'category_ids' then
    select coalesce(array_agg(distinct x::integer), '{}') into cats from jsonb_array_elements_text(p_data -> 'category_ids') x;
    if exists (select 1 from unnest(cats) c where not exists (select 1 from public.categories k where k.id = c and k.is_active)) then
      raise exception 'Choose categories from the list.' using errcode = 'check_violation';
    end if;
    if coalesce(array_length(cats, 1), 0) > 20 then
      raise exception 'Choose up to 20 categories.' using errcode = 'check_violation';
    end if;
  else
    cats := a.category_ids;
  end if;
  if p_data ? 'selling_location_id' and p_data ->> 'selling_location_id' is not null
     and not exists (select 1 from public.locations l where l.id = (p_data ->> 'selling_location_id')::integer) then
    raise exception 'Choose a selling location from the list.' using errcode = 'check_violation';
  end if;

  update public.seller_applications set
    legal_name = case when p_data ? 'legal_name' then nullif(btrim(p_data ->> 'legal_name'), '') else legal_name end,
    nationality = case when p_data ? 'nationality' then nullif(btrim(p_data ->> 'nationality'), '') else nationality end,
    is_adult = case when p_data ? 'is_adult' then (p_data ->> 'is_adult')::boolean else is_adult end,
    id_type = case when p_data ? 'id_type' then nullif(p_data ->> 'id_type', '') else id_type end,
    selling_location_id = case when p_data ? 'selling_location_id' then (p_data ->> 'selling_location_id')::integer else selling_location_id end,
    category_ids = cats,
    sourcing_type = case when p_data ? 'sourcing_type' then nullif(p_data ->> 'sourcing_type', '') else sourcing_type end,
    sourcing_info = case when p_data ? 'sourcing_info' then nullif(btrim(p_data ->> 'sourcing_info'), '') else sourcing_info end,
    experience_level = case when p_data ? 'experience_level' then nullif(p_data ->> 'experience_level', '') else experience_level end,
    experience_info = case when p_data ? 'experience_info' then nullif(btrim(p_data ->> 'experience_info'), '') else experience_info end,
    expected_catalogue_size = case when p_data ? 'expected_catalogue_size' then (p_data ->> 'expected_catalogue_size')::integer else expected_catalogue_size end,
    returns_arrangements = case when p_data ? 'returns_arrangements' then nullif(btrim(p_data ->> 'returns_arrangements'), '') else returns_arrangements end,
    customer_service_arrangements = case when p_data ? 'customer_service_arrangements' then nullif(btrim(p_data ->> 'customer_service_arrangements'), '') else customer_service_arrangements end,
    declarations = case when p_data ? 'declarations' then (p_data -> 'declarations') else declarations end
   where id = a.id;
  update public.seller_application_private set
    id_number = case when p_data ? 'id_number' then upper(nullif(btrim(p_data ->> 'id_number'), '')) else id_number end,
    residential_address = case when p_data ? 'residential_address' then nullif(btrim(p_data ->> 'residential_address'), '') else residential_address end
   where application_id = a.id;
  return a.id;
end;
$$;

create function public.seller_agreement_accept(p_version integer)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.seller_agreements where version = p_version and is_current) then
    raise exception 'That is not the current agreement.' using errcode = 'check_violation';
  end if;
  insert into public.seller_agreement_acceptances (user_id, version, application_id)
  values (uid, p_version, (select id from public.seller_applications where user_id = uid and status in ('draft', 'additional_information_required') limit 1))
  on conflict (user_id, version) do nothing;
end;
$$;

-- Records a file the applicant already uploaded to their own folder. The object must really exist in storage and
-- match the type and size declared; that is the server-side file validation.
create function public.verification_register_document(
  p_subject_type text, p_subject_id uuid, p_kind text, p_bucket text, p_path text, p_sha256 text default null
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  obj record;
  mime text;
  size_b bigint;
  new_id uuid;
  owner_ok boolean := false;
  holder uuid;
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;
  if p_subject_type = 'seller_application' then
    select user_id into holder from public.seller_applications
     where id = p_subject_id and status in ('draft', 'additional_information_required');
    owner_ok := holder = uid;
  end if;
  if not owner_ok then
    raise exception 'You cannot add documents to that application right now.' using errcode = 'insufficient_privilege';
  end if;
  if p_bucket not in ('identity-documents', 'business-documents') then
    raise exception 'Unknown storage area.' using errcode = 'check_violation';
  end if;
  if split_part(p_path, '/', 1) <> uid::text or p_path like '%..%' or char_length(p_path) > 300 then
    raise exception 'The file must be in your own folder.' using errcode = 'insufficient_privilege';
  end if;
  select o.metadata into obj from storage.objects o where o.bucket_id = p_bucket and o.name = p_path;
  if not found then
    raise exception 'The file was not uploaded.' using errcode = 'check_violation';
  end if;
  mime := obj.metadata ->> 'mimetype';
  size_b := coalesce((obj.metadata ->> 'size')::bigint, 0);
  if mime not in ('image/jpeg', 'image/png', 'application/pdf') then
    raise exception 'Upload a JPG, PNG or PDF.' using errcode = 'check_violation';
  end if;
  if size_b < 1 or size_b > 8388608 then
    raise exception 'The file must be 8 MB or smaller.' using errcode = 'check_violation';
  end if;
  perform public.enforce_rate_limit('verification_upload', 40, 1440);

  insert into public.verification_documents (owner_id, subject_type, subject_id, kind, storage_bucket, storage_path, mime_type, size_bytes, sha256)
  values (uid, p_subject_type, p_subject_id, p_kind, p_bucket, p_path, mime, size_b::integer, lower(p_sha256))
  returning id into new_id;
  perform public.verification_log(p_subject_type, p_subject_id, uid, 'document_added', null, null, p_kind, true);
  return new_id;
end;
$$;

-- The scanner (a server-side worker with the service role) reports the verdict. Nothing else can set it.
create function public.verification_record_scan(p_document uuid, p_result text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if p_result not in ('clean', 'infected', 'failed') then
    raise exception 'Result must be clean, infected or failed.' using errcode = 'check_violation';
  end if;
  update public.verification_documents set scan_status = p_result, scanned_at = now() where id = p_document and deleted_at is null;
  if not found then
    raise exception 'Document not found.' using errcode = 'no_data_found';
  end if;
end;
$$;

create function public.seller_application_submit()
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  a public.seller_applications;
  pv public.seller_application_private;
  prof public.profiles;
  have text[];
  need text[];
  missing text[];
  big integer := public.setting_numeric('seller.high_risk_catalogue_size', 200)::integer;
  risky boolean;
  keys text[] := array['sells_only_legal_goods', 'no_counterfeit_or_stolen', 'information_is_true', 'will_honour_returns'];
  k text;
begin
  select * into a from public.seller_applications
   where user_id = uid and status in ('draft', 'additional_information_required') for update;
  if not found then
    raise exception 'You have no application to send.' using errcode = 'no_data_found';
  end if;
  select * into pv from public.seller_application_private where application_id = a.id;
  select * into prof from public.profiles where id = uid;

  if prof.verification_level = 'unverified' then
    raise exception 'Verify your phone number and email first.' using errcode = 'check_violation';
  end if;
  if a.legal_name is null or a.nationality is null or a.id_type is null or pv.id_number is null or pv.residential_address is null
     or a.selling_location_id is null or coalesce(array_length(a.category_ids, 1), 0) = 0 or a.sourcing_type is null
     or a.sourcing_info is null or a.experience_level is null or a.expected_catalogue_size is null
     or a.returns_arrangements is null or a.customer_service_arrangements is null then
    raise exception 'Some answers are missing. Complete every section before sending.' using errcode = 'check_violation';
  end if;
  if a.is_adult is distinct from true then
    raise exception 'You must be an adult to sell on ZedMarket.' using errcode = 'check_violation';
  end if;
  foreach k in array keys loop
    if coalesce(a.declarations ->> k, '') <> 'true' then
      raise exception 'Please answer every question in the questionnaire.' using errcode = 'check_violation';
    end if;
  end loop;
  if not exists (select 1 from public.seller_agreement_acceptances c join public.seller_agreements g on g.version = c.version and g.is_current
                  where c.user_id = uid) then
    raise exception 'Accept the seller agreement before sending.' using errcode = 'check_violation';
  end if;

  need := public.seller_required_kinds(a.id_type);
  select coalesce(array_agg(distinct d.kind), '{}') into have from public.verification_documents d
   where d.subject_type = 'seller_application' and d.subject_id = a.id and d.deleted_at is null and d.review_status <> 'rejected' and d.scan_status <> 'infected';
  select coalesce(array_agg(n), '{}') into missing from unnest(need) n where n <> all (have);
  if array_length(missing, 1) > 0 then
    raise exception 'Documents still needed: %.', array_to_string(missing, ', ') using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.verification_requests r where r.subject_type = 'seller_application' and r.subject_id = a.id and r.status = 'open') then
    raise exception 'Answer the request for more information first.' using errcode = 'check_violation';
  end if;

  risky := a.expected_catalogue_size >= big
        or exists (select 1 from public.categories c where c.id = any (a.category_ids) and c.requires_review)
        or (a.experience_level = 'none' and a.expected_catalogue_size >= 50)
        or a.escalated;

  update public.seller_applications
     set status = 'submitted', risk_level = case when risky then 'high' else 'standard' end,
         submitted_at = coalesce(submitted_at, now()), due_at = now() + interval '3 days', assigned_to = null, claimed_at = null
   where id = a.id;
  perform public.verification_log('seller_application', a.id, uid, 'submitted', a.status, 'submitted', null, true);
  perform public.seller_notify(uid, a.id, 'Application received', 'Our team will review your seller application. You will be told if we need more information.');
end;
$$;

create function public.seller_application_withdraw()
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  a public.seller_applications;
  keep integer := public.setting_numeric('retention.verification_rejected_days', 30)::integer;
begin
  select * into a from public.seller_applications
   where user_id = uid and status in ('draft', 'submitted', 'under_review', 'additional_information_required') for update;
  if not found then
    raise exception 'You have no open application.' using errcode = 'no_data_found';
  end if;
  update public.seller_applications set status = 'rejected', decided_at = now(), decision_reason = 'Withdrawn by the applicant.' where id = a.id;
  update public.verification_documents set purge_after = now() + make_interval(days => keep)
   where subject_type = 'seller_application' and subject_id = a.id and purge_after is null;
  perform public.verification_log('seller_application', a.id, uid, 'withdrawn', a.status, 'rejected', null, true);
end;
$$;

create function public.seller_application_respond(p_request uuid, p_response text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  r public.verification_requests;
  a public.seller_applications;
begin
  select * into r from public.verification_requests where id = p_request and subject_type = 'seller_application' for update;
  if not found then
    raise exception 'Request not found.' using errcode = 'no_data_found';
  end if;
  select * into a from public.seller_applications where id = r.subject_id for update;
  if a.user_id <> uid then
    raise exception 'Request not found.' using errcode = 'no_data_found';
  end if;
  if r.status <> 'open' or a.status <> 'additional_information_required' then
    raise exception 'This request is closed.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from unnest(r.document_kinds) k where not exists (
        select 1 from public.verification_documents d where d.subject_type = 'seller_application' and d.subject_id = a.id
           and d.kind = k and d.created_at > r.created_at and d.deleted_at is null and d.scan_status <> 'infected')) then
    raise exception 'Upload the documents that were asked for first.' using errcode = 'check_violation';
  end if;
  update public.verification_requests set status = 'answered', response = left(btrim(coalesce(p_response, '')), 1000), answered_at = now() where id = r.id;
  if not exists (select 1 from public.verification_requests x where x.subject_type = 'seller_application' and x.subject_id = a.id and x.status = 'open') then
    update public.seller_applications set status = case when assigned_to is null then 'submitted' else 'under_review' end where id = a.id;
    perform public.verification_log('seller_application', a.id, uid, 'information_provided', a.status, case when a.assigned_to is null then 'submitted' else 'under_review' end, null, true);
  end if;
end;
$$;

-- What the applicant sees: their own answers (they wrote them), document status, the history they may read, and open requests.
create function public.seller_application_mine()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  a public.seller_applications;
  pv public.seller_application_private;
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;
  select * into a from public.seller_applications where user_id = uid
   order by (status in ('draft', 'submitted', 'under_review', 'additional_information_required', 'approved', 'suspended')) desc, created_at desc limit 1;
  if not found then
    return jsonb_build_object('seller_status', (select seller_status from public.profiles where id = uid), 'application', null);
  end if;
  select * into pv from public.seller_application_private where application_id = a.id;
  return jsonb_build_object(
    'seller_status', (select seller_status from public.profiles where id = uid),
    'application', jsonb_build_object(
      'id', a.id, 'status', a.status, 'legal_name', a.legal_name, 'nationality', a.nationality, 'is_adult', a.is_adult,
      'id_type', a.id_type, 'id_number', pv.id_number, 'residential_address', pv.residential_address,
      'selling_location_id', a.selling_location_id, 'category_ids', a.category_ids, 'sourcing_type', a.sourcing_type,
      'sourcing_info', a.sourcing_info, 'experience_level', a.experience_level, 'experience_info', a.experience_info,
      'expected_catalogue_size', a.expected_catalogue_size, 'returns_arrangements', a.returns_arrangements,
      'customer_service_arrangements', a.customer_service_arrangements, 'declarations', a.declarations,
      'submitted_at', a.submitted_at, 'decision_reason', a.decision_reason, 'decided_at', a.decided_at,
      'required_documents', public.seller_required_kinds(a.id_type),
      'agreement_accepted', exists (select 1 from public.seller_agreement_acceptances c join public.seller_agreements g
                                     on g.version = c.version and g.is_current where c.user_id = uid)),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'scan', d.scan_status, 'review', d.review_status,
                  'note', d.review_note, 'at', d.created_at) order by d.created_at)
                  from public.verification_documents d where d.subject_type = 'seller_application' and d.subject_id = a.id and d.deleted_at is null), '[]'),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'message', r.message, 'document_kinds', r.document_kinds,
                  'status', r.status, 'due_at', r.due_at, 'created_at', r.created_at) order by r.created_at)
                  from public.verification_requests r where r.subject_type = 'seller_application' and r.subject_id = a.id), '[]'),
    'history', coalesce((select jsonb_agg(jsonb_build_object('event', e.event, 'to_status', e.to_status, 'note', e.note, 'at', e.created_at) order by e.id)
                  from public.verification_events e where e.subject_type = 'seller_application' and e.subject_id = a.id and e.visible_to_applicant), '[]'));
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Support functions
-- ---------------------------------------------------------------------------
create function public.seller_need_not_own(p_app public.seller_applications)
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if p_app.user_id = (select auth.uid()) then
    raise exception 'You cannot review your own application.' using errcode = 'insufficient_privilege';
  end if;
end;
$$;

-- queue: sellers, documents, info_requested, escalated, approved, rejected, suspended
create function public.verification_queue(p_queue text, p_limit integer default 50, p_offset integer default 0)
returns table (
  id uuid, applicant_id uuid, applicant_name text, status text, risk_level text, escalated boolean, awaiting_second boolean,
  assigned_to uuid, assigned_name text, submitted_at timestamptz, due_at timestamptz, overdue boolean, pending_documents bigint, mine boolean
)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  perform public.verification_need_support();
  if p_queue not in ('sellers', 'documents', 'info_requested', 'escalated', 'approved', 'rejected', 'suspended') then
    raise exception 'Unknown queue.' using errcode = 'invalid_parameter_value';
  end if;
  return query
    select a.id, a.user_id, p.display_name, a.status, a.risk_level, a.escalated, (a.first_approved_by is not null and a.status = 'under_review'),
           a.assigned_to, ap.display_name, a.submitted_at, a.due_at,
           (a.due_at is not null and a.due_at < now() and a.status in ('submitted', 'under_review')),
           (select count(*) from public.verification_documents d where d.subject_type = 'seller_application' and d.subject_id = a.id
               and d.review_status = 'uploaded' and d.deleted_at is null),
           a.assigned_to = (select auth.uid())
      from public.seller_applications a
      join public.profiles p on p.id = a.user_id
      left join public.profiles ap on ap.id = a.assigned_to
     where a.status <> 'draft' and case p_queue
             when 'sellers' then a.status in ('submitted', 'under_review')
             when 'documents' then a.status in ('submitted', 'under_review') and exists (
                select 1 from public.verification_documents d where d.subject_type = 'seller_application' and d.subject_id = a.id
                   and d.review_status = 'uploaded' and d.deleted_at is null)
             when 'info_requested' then a.status = 'additional_information_required'
             when 'escalated' then a.escalated and a.status in ('submitted', 'under_review', 'additional_information_required')
             when 'approved' then a.status = 'approved'
             when 'rejected' then a.status = 'rejected'
             else a.status in ('suspended', 'revoked') end
     order by a.escalated desc, coalesce(a.risk_level = 'high', false) desc, a.submitted_at nulls last
     limit least(greatest(coalesce(p_limit, 50), 1), 100) offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

create function public.seller_application_detail(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  a public.seller_applications;
begin
  perform public.verification_need_support();
  select * into a from public.seller_applications where id = p_id and status <> 'draft';
  if not found then
    raise exception 'Application not found.' using errcode = 'no_data_found';
  end if;
  perform public.seller_need_not_own(a);
  return jsonb_build_object(
    'id', a.id, 'status', a.status, 'risk_level', a.risk_level, 'escalated', a.escalated, 'escalation_reason', a.escalation_reason,
    'assigned_to', a.assigned_to, 'first_approved_by', a.first_approved_by, 'submitted_at', a.submitted_at, 'due_at', a.due_at,
    'applicant', (select jsonb_build_object('id', p.id, 'name', p.display_name, 'verification_level', p.verification_level,
                    'account_state', p.account_state, 'member_since', p.created_at) from public.profiles p where p.id = a.user_id),
    'legal_name', a.legal_name, 'nationality', a.nationality, 'is_adult', a.is_adult, 'id_type', a.id_type,
    'selling_location_id', a.selling_location_id,
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'requires_review', c.requires_review)), '[]')
                     from public.categories c where c.id = any (a.category_ids)),
    'sourcing_type', a.sourcing_type, 'sourcing_info', a.sourcing_info, 'experience_level', a.experience_level,
    'experience_info', a.experience_info, 'expected_catalogue_size', a.expected_catalogue_size,
    'returns_arrangements', a.returns_arrangements, 'customer_service_arrangements', a.customer_service_arrangements,
    'declarations', a.declarations, 'decision_reason', a.decision_reason,
    'required_documents', public.seller_required_kinds(a.id_type),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'scan', d.scan_status, 'review', d.review_status,
                  'note', d.review_note, 'mime', d.mime_type, 'at', d.created_at) order by d.created_at)
                  from public.verification_documents d where d.subject_type = 'seller_application' and d.subject_id = a.id and d.deleted_at is null), '[]'),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'message', r.message, 'status', r.status, 'response', r.response,
                  'due_at', r.due_at, 'document_kinds', r.document_kinds) order by r.created_at)
                  from public.verification_requests r where r.subject_type = 'seller_application' and r.subject_id = a.id), '[]'),
    'interviews', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'channel', i.channel, 'outcome', i.outcome, 'answers', i.answers,
                  'notes', i.notes, 'at', i.conducted_at, 'by', i.conducted_by) order by i.conducted_at)
                  from public.verification_interviews i where i.subject_type = 'seller_application' and i.subject_id = a.id), '[]'),
    'history', coalesce((select jsonb_agg(jsonb_build_object('event', e.event, 'from', e.from_status, 'to', e.to_status, 'note', e.note,
                  'by', e.actor_id, 'at', e.created_at) order by e.id)
                  from public.verification_events e where e.subject_type = 'seller_application' and e.subject_id = a.id), '[]'));
end;
$$;

-- ID number and residential address: a separate, audited read.
create function public.seller_application_private_details(p_id uuid)
returns table (id_number text, residential_address text)
language plpgsql security definer set search_path = ''
as $$
declare
  a public.seller_applications;
begin
  perform public.verification_need_support();
  select * into a from public.seller_applications where id = p_id and status <> 'draft';
  if not found then
    raise exception 'Application not found.' using errcode = 'no_data_found';
  end if;
  perform public.seller_need_not_own(a);
  perform public.write_audit('verification.private_viewed', 'user', a.user_id::text, jsonb_build_object('application_id', a.id));
  return query select v.id_number, v.residential_address from public.seller_application_private v where v.application_id = a.id;
end;
$$;

create function public.seller_application_claim(p_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  a public.seller_applications;
begin
  perform public.verification_need_support();
  select * into a from public.seller_applications where id = p_id and status in ('submitted', 'under_review') for update;
  if not found then
    raise exception 'That application is not waiting for review.' using errcode = 'no_data_found';
  end if;
  perform public.seller_need_not_own(a);
  if a.assigned_to is not null and a.assigned_to <> uid then
    raise exception 'Another officer is already working on this application.' using errcode = 'check_violation';
  end if;
  if a.first_approved_by = uid then
    raise exception 'A different officer must give the second approval.' using errcode = 'insufficient_privilege';
  end if;
  update public.seller_applications set assigned_to = uid, claimed_at = now(), status = 'under_review' where id = a.id;
  perform public.verification_log('seller_application', a.id, a.user_id, 'claimed', a.status, 'under_review', null, a.status = 'submitted');
  if a.status = 'submitted' then
    perform public.seller_notify(a.user_id, a.id, 'Your application is being reviewed', 'An officer has started reviewing your seller application.');
  end if;
end;
$$;

create function public.seller_application_assign(p_id uuid, p_to uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  a public.seller_applications;
begin
  perform public.verification_need_support();
  select * into a from public.seller_applications where id = p_id and status in ('submitted', 'under_review') for update;
  if not found then
    raise exception 'That application is not waiting for review.' using errcode = 'no_data_found';
  end if;
  perform public.seller_need_not_own(a);
  if p_to = a.user_id or not exists (select 1 from public.admin_roles r join public.profiles x on x.id = r.user_id
                                      where r.user_id = p_to and r.role = 'support' and x.account_state = 'active') then
    raise exception 'Assign to an active support officer who is not the applicant.' using errcode = 'check_violation';
  end if;
  if a.first_approved_by = p_to then
    raise exception 'The second approval must come from a different officer.' using errcode = 'check_violation';
  end if;
  update public.seller_applications set assigned_to = p_to, claimed_at = now(), status = 'under_review' where id = a.id;
  perform public.verification_log('seller_application', a.id, a.user_id, 'assigned', a.status, 'under_review', p_to::text, false);
  perform public.notify(p_to, 'account', 'verification_assigned', 'An application was assigned to you', 'Open the verification queue to review it.',
                        '/trust/applications', 'assign:' || a.id || ':' || p_to);
end;
$$;

create function public.verification_review_document(p_document uuid, p_accept boolean, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  d public.verification_documents;
  a public.seller_applications;
  note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  perform public.verification_need_support();
  select * into d from public.verification_documents where id = p_document and deleted_at is null for update;
  if not found or d.subject_type <> 'seller_application' then
    raise exception 'Document not found.' using errcode = 'no_data_found';
  end if;
  select * into a from public.seller_applications where id = d.subject_id;
  perform public.seller_need_not_own(a);
  if a.assigned_to is distinct from (select auth.uid()) then
    raise exception 'Claim the application first.' using errcode = 'check_violation';
  end if;
  if p_accept and d.scan_status <> 'clean' then
    raise exception 'The file has not passed the safety scan.' using errcode = 'check_violation';
  end if;
  if not p_accept and (note is null or char_length(note) < 5) then
    raise exception 'Say what is wrong with this document.' using errcode = 'check_violation';
  end if;
  update public.verification_documents set review_status = case when p_accept then 'accepted' else 'rejected' end,
         review_note = left(note, 300), reviewed_by = (select auth.uid()), reviewed_at = now() where id = d.id;
  perform public.verification_log('seller_application', a.id, a.user_id, case when p_accept then 'document_accepted' else 'document_rejected' end,
                                  null, null, d.kind || coalesce(': ' || note, ''), not p_accept);
end;
$$;

-- Opening a document: support only, two-factor, not your own application, the scan must be clean, and the access is
-- written to the audit log BEFORE anything is returned. The caller (an Edge Function) then signs a short-lived link.
create function public.verification_open_document(p_document uuid)
returns table (bucket text, path text, seconds integer)
language plpgsql security definer set search_path = ''
as $$
declare
  d public.verification_documents;
  a public.seller_applications;
begin
  perform public.verification_need_support();
  select * into d from public.verification_documents where id = p_document;
  if not found or d.deleted_at is not null then
    raise exception 'Document not found.' using errcode = 'no_data_found';
  end if;
  if d.subject_type = 'seller_application' then
    select * into a from public.seller_applications where id = d.subject_id;
    perform public.seller_need_not_own(a);
  end if;
  if d.scan_status <> 'clean' then
    raise exception 'This file has not passed the safety scan, so it cannot be opened.' using errcode = 'check_violation';
  end if;
  perform public.write_audit('document.viewed', 'user', d.owner_id::text,
    jsonb_build_object('document_id', d.id, 'kind', d.kind, 'subject_type', d.subject_type, 'subject_id', d.subject_id));
  return query select d.storage_bucket, d.storage_path, least(public.setting_numeric('verification.document_url_seconds', 60)::integer, 300);
end;
$$;

create function public.seller_application_request_info(p_id uuid, p_message text, p_kinds text[] default '{}')
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  a public.seller_applications;
  new_id uuid;
  days integer := public.setting_numeric('verification.info_request_days', 14)::integer;
begin
  perform public.verification_need_support();
  select * into a from public.seller_applications where id = p_id and status in ('submitted', 'under_review') for update;
  if not found then
    raise exception 'That application is not waiting for review.' using errcode = 'no_data_found';
  end if;
  perform public.seller_need_not_own(a);
  if a.assigned_to is distinct from (select auth.uid()) then
    raise exception 'Claim the application first.' using errcode = 'check_violation';
  end if;
  if p_message is null or char_length(btrim(p_message)) < 5 then
    raise exception 'Say what you need from the applicant.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from unnest(coalesce(p_kinds, '{}')) k where k not in (
      'id_front', 'id_back', 'passport_page', 'selfie_with_id', 'proof_of_address', 'sourcing_evidence', 'product_evidence', 'other')) then
    raise exception 'Unknown document type.' using errcode = 'check_violation';
  end if;
  insert into public.verification_requests (subject_type, subject_id, requested_by, message, document_kinds, due_at)
  values ('seller_application', a.id, (select auth.uid()), left(btrim(p_message), 1000), coalesce(p_kinds, '{}'), now() + make_interval(days => days))
  returning id into new_id;
  update public.seller_applications set status = 'additional_information_required' where id = a.id;
  perform public.verification_log('seller_application', a.id, a.user_id, 'information_requested', a.status, 'additional_information_required', p_message, true);
  perform public.seller_notify(a.user_id, a.id, 'We need more information', 'Open your seller application to see what we need.');
  return new_id;
end;
$$;

create function public.seller_application_record_interview(p_id uuid, p_channel text, p_outcome text, p_answers jsonb, p_notes text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  a public.seller_applications;
  new_id uuid;
begin
  perform public.verification_need_support();
  select * into a from public.seller_applications where id = p_id and status = 'under_review' for update;
  if not found then
    raise exception 'That application is not under review.' using errcode = 'no_data_found';
  end if;
  perform public.seller_need_not_own(a);
  if a.assigned_to is distinct from (select auth.uid()) then
    raise exception 'Claim the application first.' using errcode = 'check_violation';
  end if;
  if p_channel not in ('phone', 'video', 'in_person') or p_outcome not in ('passed', 'failed', 'inconclusive') then
    raise exception 'Choose a channel and an outcome.' using errcode = 'check_violation';
  end if;
  if p_answers is null or jsonb_typeof(p_answers) <> 'array' or jsonb_array_length(p_answers) = 0 then
    raise exception 'Record the questions asked and the answers given.' using errcode = 'check_violation';
  end if;
  insert into public.verification_interviews (subject_type, subject_id, conducted_by, channel, outcome, answers, notes)
  values ('seller_application', a.id, (select auth.uid()), p_channel, p_outcome, p_answers, left(p_notes, 2000))
  returning id into new_id;
  perform public.verification_log('seller_application', a.id, a.user_id, 'interview_recorded', null, null, p_channel || ': ' || p_outcome, false);
  return new_id;
end;
$$;

create function public.seller_application_escalate(p_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  a public.seller_applications;
begin
  perform public.verification_need_support();
  select * into a from public.seller_applications where id = p_id and status in ('submitted', 'under_review', 'additional_information_required') for update;
  if not found then
    raise exception 'That application cannot be escalated.' using errcode = 'no_data_found';
  end if;
  perform public.seller_need_not_own(a);
  if p_reason is null or char_length(btrim(p_reason)) < 10 then
    raise exception 'Write why this application looks suspicious (at least 10 characters).' using errcode = 'check_violation';
  end if;
  update public.seller_applications set escalated = true, escalation_reason = left(btrim(p_reason), 500), risk_level = 'high',
         first_approved_by = null, assigned_to = null
   where id = a.id;
  perform public.verification_log('seller_application', a.id, a.user_id, 'escalated', a.status, a.status, p_reason, false);
end;
$$;

-- Approve or reject. Higher-risk or escalated applications need an interview that passed and a second, different officer.
create function public.seller_application_decide(p_id uuid, p_decision text, p_reason text default null)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  a public.seller_applications;
  reason text := nullif(btrim(coalesce(p_reason, '')), '');
  need text[];
  missing text[];
  needs_two boolean;
  keep_ok integer := public.setting_numeric('retention.verification_approved_days', 365)::integer;
  keep_no integer := public.setting_numeric('retention.verification_rejected_days', 30)::integer;
begin
  perform public.verification_need_support();
  if p_decision not in ('approve', 'reject') then
    raise exception 'Choose approve or reject.' using errcode = 'invalid_parameter_value';
  end if;
  select * into a from public.seller_applications where id = p_id and status = 'under_review' for update;
  if not found then
    raise exception 'That application is not under review.' using errcode = 'no_data_found';
  end if;
  perform public.seller_need_not_own(a);
  if a.assigned_to is distinct from uid then
    raise exception 'Claim the application first.' using errcode = 'check_violation';
  end if;

  if p_decision = 'reject' then
    if reason is null or char_length(reason) < 10 then
      raise exception 'A rejection needs a reason the applicant can read (at least 10 characters).' using errcode = 'check_violation';
    end if;
    update public.seller_applications set status = 'rejected', decided_by = uid, decided_at = now(), decision_reason = left(reason, 500),
           assigned_to = null where id = a.id;
    update public.verification_documents set purge_after = now() + make_interval(days => keep_no)
     where subject_type = 'seller_application' and subject_id = a.id and purge_after is null;
    perform public.verification_log('seller_application', a.id, a.user_id, 'rejected', 'under_review', 'rejected', reason, true);
    perform public.seller_notify(a.user_id, a.id, 'Your seller application was not approved', 'Open your application to read the reason.');
    perform public.write_audit('seller_application.rejected', 'user', a.user_id::text, jsonb_build_object('application_id', a.id));
    return 'rejected';
  end if;

  need := public.seller_required_kinds(a.id_type);
  select coalesce(array_agg(n), '{}') into missing from unnest(need) n where not exists (
    select 1 from public.verification_documents d where d.subject_type = 'seller_application' and d.subject_id = a.id
       and d.kind = n and d.review_status = 'accepted' and d.scan_status = 'clean' and d.deleted_at is null);
  if array_length(missing, 1) > 0 then
    raise exception 'These documents are not accepted yet: %.', array_to_string(missing, ', ') using errcode = 'check_violation';
  end if;
  needs_two := a.risk_level = 'high' or a.escalated;
  if needs_two and not exists (select 1 from public.verification_interviews i where i.subject_type = 'seller_application'
                                and i.subject_id = a.id and i.outcome = 'passed') then
    raise exception 'A higher-risk application needs an interview that passed.' using errcode = 'check_violation';
  end if;
  if reason is null or char_length(reason) < 5 then
    raise exception 'Record why you approved it.' using errcode = 'check_violation';
  end if;

  if needs_two and a.first_approved_by is null then
    update public.seller_applications set first_approved_by = uid, assigned_to = null where id = a.id;
    perform public.verification_log('seller_application', a.id, a.user_id, 'first_approval', 'under_review', 'under_review', reason, false);
    return 'awaiting_second_approval';
  end if;
  if needs_two and a.first_approved_by = uid then
    raise exception 'A different officer must give the second approval.' using errcode = 'insufficient_privilege';
  end if;

  update public.seller_applications set status = 'approved', decided_by = uid, decided_at = now(), decision_reason = left(reason, 500),
         assigned_to = null where id = a.id;
  update public.profiles set seller_status = 'active',
         verification_level = case when verification_level = 'identity_verified' then verification_level else 'identity_verified' end
   where id = a.user_id;
  update public.verification_documents set purge_after = now() + make_interval(days => keep_ok)
   where subject_type = 'seller_application' and subject_id = a.id and purge_after is null;
  perform public.verification_log('seller_application', a.id, a.user_id, 'approved', 'under_review', 'approved', reason, true);
  perform public.seller_notify(a.user_id, a.id, 'You are approved to sell', 'Your seller tools are now available in your account.');
  perform public.write_audit('seller_application.approved', 'user', a.user_id::text,
    jsonb_build_object('application_id', a.id, 'two_reviewers', needs_two, 'first', a.first_approved_by));
  return 'approved';
end;
$$;

-- Suspension and revocation switch selling off. Listings are paused (not deleted) and every record stays.
create function public.seller_application_suspend(p_id uuid, p_reason text, p_revoke boolean default false)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  a public.seller_applications;
  reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform public.verification_need_support();
  select * into a from public.seller_applications where id = p_id and status in ('approved', 'suspended') for update;
  if not found then
    raise exception 'Only an approved or suspended seller can be suspended or revoked.' using errcode = 'no_data_found';
  end if;
  perform public.seller_need_not_own(a);
  if reason is null or char_length(reason) < 10 then
    raise exception 'Write the reason (at least 10 characters). The seller can read it.' using errcode = 'check_violation';
  end if;
  if a.status = 'suspended' and not p_revoke then
    raise exception 'This seller is already suspended.' using errcode = 'check_violation';
  end if;
  update public.seller_applications set status = case when p_revoke then 'revoked' else 'suspended' end,
         decided_by = (select auth.uid()), decided_at = now(), decision_reason = left(reason, 500) where id = a.id;
  update public.profiles set seller_status = case when p_revoke then 'revoked' else 'suspended' end where id = a.user_id;
  update public.listings set status = 'unavailable' where seller_id = a.user_id and status = 'active';
  perform public.verification_log('seller_application', a.id, a.user_id, case when p_revoke then 'revoked' else 'suspended' end,
                                  a.status, case when p_revoke then 'revoked' else 'suspended' end, reason, true);
  perform public.seller_notify(a.user_id, a.id, case when p_revoke then 'Your seller account was ended' else 'Your selling is suspended' end,
                               'Open your seller page to read the reason. You can appeal this decision.');
  perform public.write_audit(case when p_revoke then 'seller.revoked' else 'seller.suspended' end, 'user', a.user_id::text,
                             jsonb_build_object('application_id', a.id));
end;
$$;

-- Putting a seller back needs a different officer from the one who suspended them.
create function public.seller_application_reinstate(p_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  a public.seller_applications;
  reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform public.verification_need_support();
  select * into a from public.seller_applications where id = p_id and status = 'suspended' for update;
  if not found then
    raise exception 'Only a suspended seller can be reinstated.' using errcode = 'no_data_found';
  end if;
  perform public.seller_need_not_own(a);
  if a.decided_by = (select auth.uid()) then
    raise exception 'A different officer must reinstate a seller you suspended.' using errcode = 'insufficient_privilege';
  end if;
  if reason is null or char_length(reason) < 10 then
    raise exception 'Write why the seller is reinstated (at least 10 characters).' using errcode = 'check_violation';
  end if;
  update public.seller_applications set status = 'approved', decided_by = (select auth.uid()), decided_at = now(), decision_reason = left(reason, 500) where id = a.id;
  update public.profiles set seller_status = 'active' where id = a.user_id;
  perform public.verification_log('seller_application', a.id, a.user_id, 'reinstated', 'suspended', 'approved', reason, true);
  perform public.seller_notify(a.user_id, a.id, 'Your selling is back', 'You can publish again. Paused listings stay paused until you restock or republish them.');
  perform public.write_audit('seller.reinstated', 'user', a.user_id::text, jsonb_build_object('application_id', a.id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Retention worker (service role)
-- ---------------------------------------------------------------------------
create function public.verification_documents_due(p_limit integer default 100)
returns table (id uuid, bucket text, path text)
language sql stable security definer set search_path = ''
as $$
  select d.id, d.storage_bucket, d.storage_path from public.verification_documents d
   where d.deleted_at is null and d.purge_after is not null and d.purge_after <= now()
   order by d.purge_after limit least(greatest(coalesce(p_limit, 100), 1), 500)
$$;

create function public.verification_mark_deleted(p_ids uuid[])
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  n integer;
begin
  update public.verification_documents set deleted_at = now() where id = any (p_ids) and deleted_at is null and purge_after <= now();
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Publishing gate
-- ---------------------------------------------------------------------------
-- Creating a listing, and adding photos to one, now needs an approved seller (business listings are handled by the
-- business verification migration). Same policies as before plus the seller check.
drop policy listings_insert on public.listings;
create policy listings_insert on public.listings
  for insert to authenticated
  with check (
    seller_id = (select auth.uid())
    and public.account_can_post()
    and (business_id is not null or public.seller_can_publish())
    and (business_id is null or public.is_business_member(business_id, array['owner', 'manager', 'staff']::public.business_member_role[]))
  );

create function public.listings_seller_gate()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  -- Trusted server-side work (no signed-in user) is not gated here. Business listings are gated by their business.
  if (select auth.uid()) is null or new.business_id is not null or public.has_staff_role('moderator') then
    return new;
  end if;
  if public.seller_can_publish(new.seller_id) then
    return new;
  end if;
  if tg_op = 'INSERT' or (new.status = 'active' and old.status = 'draft') then
    raise exception 'Become an approved seller before you list items.' using errcode = 'insufficient_privilege';
  end if;
  if tg_op = 'UPDATE' and new.status = 'active' and old.status = 'unavailable' then
    -- A suspended seller's paused listing must stay paused. Stock or order code that tries to bring it back
    -- is quietly refused; the seller trying to republish by hand is told why.
    if (select auth.uid()) = new.seller_id then
      raise exception 'Your selling is switched off, so this listing cannot go live.' using errcode = 'insufficient_privilege';
    end if;
    new.status := old.status;
  end if;
  return new;
end;
$$;
create trigger listings_seller_gate before insert or update of status on public.listings
  for each row execute function public.listings_seller_gate();

-- People who were already selling before this migration keep selling: anyone with listings or a verified identity
-- is treated as an approved seller (recorded in the history as a one-off carry-over, not as a reviewed application).
with legacy as (
  select p.id from public.profiles p
   where p.seller_status = 'none' and p.account_state = 'active'
     and (p.verification_level = 'identity_verified' or exists (select 1 from public.listings l where l.seller_id = p.id and l.business_id is null))
), flip as (
  update public.profiles p set seller_status = 'active' from legacy where p.id = legacy.id returning p.id
)
insert into public.verification_events (subject_type, subject_id, applicant_id, event, to_status, note, visible_to_applicant)
select 'seller_application', gen_random_uuid(), f.id, 'carried_over', 'approved', 'Selling before seller applications existed.', false from flip f;

-- ---------------------------------------------------------------------------
-- 10. Permissions: closed first, then opened on purpose
-- ---------------------------------------------------------------------------
revoke execute on function
  public.seller_can_publish(uuid), public.verification_events_immutable(), public.verification_need_support(),
  public.verification_log(text, uuid, uuid, text, text, text, text, boolean), public.seller_notify(uuid, uuid, text, text),
  public.seller_required_kinds(text), public.seller_agreement_current(), public.seller_application_save(jsonb),
  public.seller_agreement_accept(integer), public.verification_register_document(text, uuid, text, text, text, text),
  public.verification_record_scan(uuid, text), public.seller_application_submit(), public.seller_application_withdraw(),
  public.seller_application_respond(uuid, text), public.seller_application_mine(), public.seller_need_not_own(public.seller_applications),
  public.verification_queue(text, integer, integer), public.seller_application_detail(uuid), public.seller_application_private_details(uuid),
  public.seller_application_claim(uuid), public.seller_application_assign(uuid, uuid), public.verification_review_document(uuid, boolean, text),
  public.verification_open_document(uuid), public.seller_application_request_info(uuid, text, text[]),
  public.seller_application_record_interview(uuid, text, text, jsonb, text), public.seller_application_escalate(uuid, text),
  public.seller_application_decide(uuid, text, text), public.seller_application_suspend(uuid, text, boolean),
  public.seller_application_reinstate(uuid, text), public.verification_documents_due(integer), public.verification_mark_deleted(uuid[]),
  public.listings_seller_gate()
from public, anon, authenticated;

grant execute on function public.seller_can_publish(uuid) to authenticated;
grant execute on function
  public.seller_agreement_current(), public.seller_application_save(jsonb), public.seller_agreement_accept(integer),
  public.verification_register_document(text, uuid, text, text, text, text), public.seller_application_submit(),
  public.seller_application_withdraw(), public.seller_application_respond(uuid, text), public.seller_application_mine(),
  public.verification_queue(text, integer, integer), public.seller_application_detail(uuid), public.seller_application_private_details(uuid),
  public.seller_application_claim(uuid), public.seller_application_assign(uuid, uuid), public.verification_review_document(uuid, boolean, text),
  public.verification_open_document(uuid), public.seller_application_request_info(uuid, text, text[]),
  public.seller_application_record_interview(uuid, text, text, jsonb, text), public.seller_application_escalate(uuid, text),
  public.seller_application_decide(uuid, text, text), public.seller_application_suspend(uuid, text, boolean),
  public.seller_application_reinstate(uuid, text)
to authenticated;
grant execute on function
  public.verification_record_scan(uuid, text), public.verification_documents_due(integer), public.verification_mark_deleted(uuid[])
to service_role;
