-- 0027: Business verification (replaces the basic registration-number check for publishing).
--
-- Registering a business never makes it verified. A business becomes able to publish only when support has approved a
-- business application: a reviewed file with registry details, TPIN, address, ownership, directors and beneficial
-- owners, an authorised representative, branches, permits and documents, plus checks the officer records themselves
-- (registry look-up, a telephone or video interview, confirmation that the applicant may act for the business).
--
--   * Only an OWNER of the business can start or submit an application, or change ownership and verification details.
--     Managers and staff never can. Membership gives no verification and no ownership.
--   * Two routes: 'registered' (PACRA-registered company, partnership, sole proprietorship, cooperative, NGO) and
--     'informal_trader' for eligible traders without registration. An informal trader is never shown as a registered
--     company: businesses.registration_kind says which, and the public storefront view carries it.
--   * Every business approval needs documents accepted, the required officer checks passed and an interview that passed.
--     Higher-risk applications also need a second, different officer. Nobody reviews an application they filed.
--   * Approval sets businesses.publish_state = 'active' and the verified badge. Suspension/revocation switches publishing
--     off, pauses live listings (kept, with history) and removes the badge. Drafts can always be prepared.
--   * Documents, history, retention and audited access reuse the tables and rules from 0023.
--
-- Lessons from 0026 (the seller flow) applied here from the start:
--   * business_application_mine() ALWAYS returns every part (application, parties, branches, permits, documents, requests,
--     history), even for a business that never applied, so a screen can never crash on a missing list.
--   * A withdrawn application does not start the re-apply waiting period; only a real rejection does.
--   * Every answer is checked with a readable message that names the answer, never a raw table-rule error or a failed cast.
--   * Deleting a business (business_close, 0025) also puts its application documents on the retention clock.
--
-- The earlier business_verifications table and review function are kept so history is not lost, but they no longer
-- decide who may publish. TO RETIRE LATER: their submit screen is no longer linked from the app.

-- ---------------------------------------------------------------------------
-- 1. Settings and business columns
-- ---------------------------------------------------------------------------
insert into public.platform_settings (key, value, note) values
  ('business.high_risk_catalogue_size', '500', 'Expected catalogue size at which a business application needs two reviewers. Starter value.'),
  ('business.informal_high_risk_catalogue_size', '100', 'Same, for informal traders. Starter value.'),
  ('business.reapply_days', '7', 'Days a rejected business waits before applying again. Starter value.')
on conflict (key) do nothing;

alter table public.businesses
  add column publish_state text not null default 'none' check (publish_state in ('none', 'active', 'suspended', 'revoked')),
  add column registration_kind text check (registration_kind in ('registered', 'informal_trader'));
-- The businesses grants let members update only name, description, logo, location and address, so these two columns
-- can be changed only by the functions below.

create function public.business_can_publish(p_business uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.businesses b where b.id = p_business and b.publish_state = 'active')
$$;

-- ---------------------------------------------------------------------------
-- 2. Tables (closed: RLS on, no grants, no policies)
-- ---------------------------------------------------------------------------
create table public.business_applications (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'draft' check (status in
    ('draft', 'submitted', 'under_review', 'additional_information_required', 'approved', 'rejected', 'suspended', 'revoked')),
  route text not null default 'registered' check (route in ('registered', 'informal_trader')),
  legal_name text check (char_length(legal_name) between 3 and 150),
  trading_name text check (char_length(trading_name) between 2 and 120),
  business_type text check (business_type in ('sole_proprietorship', 'partnership', 'limited_company', 'cooperative', 'ngo', 'informal_trader')),
  pacra_number text check (char_length(pacra_number) between 4 and 30),
  pacra_registered_on date,
  physical_address text check (char_length(physical_address) between 10 and 300),
  selling_location_id integer references public.locations (id),
  phone text check (phone ~ '^\+?[0-9 ]{9,16}$'),
  email text check (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  category_ids integer[] not null default '{}',
  expected_catalogue_size integer check (expected_catalogue_size between 1 and 100000),
  trading_place text check (char_length(trading_place) between 5 and 300),
  years_trading integer check (years_trading between 0 and 80),
  ownership_summary text check (char_length(ownership_summary) <= 1000),
  rep_name text check (char_length(rep_name) between 3 and 120),
  rep_role text check (char_length(rep_role) between 2 and 80),
  rep_is_director boolean,
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
  updated_at timestamptz not null default now(),
  check (business_type is null or ((route = 'informal_trader') = (business_type = 'informal_trader')))
);
create unique index business_one_open_application on public.business_applications (business_id)
  where status in ('draft', 'submitted', 'under_review', 'additional_information_required');
create unique index business_one_live_application on public.business_applications (business_id)
  where status in ('approved', 'suspended');
create index business_applications_status_idx on public.business_applications (status, submitted_at);
create trigger business_applications_updated before update on public.business_applications
  for each row execute function public.set_updated_at();

create table public.business_application_private (
  application_id uuid primary key references public.business_applications (id) on delete cascade,
  tpin text check (char_length(tpin) between 5 and 20),
  rep_id_number text check (char_length(rep_id_number) between 5 and 30)
);

create table public.business_application_parties (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.business_applications (id) on delete cascade,
  kind text not null check (kind in ('director', 'beneficial_owner')),
  full_name text not null check (char_length(full_name) between 3 and 120),
  nationality text check (char_length(nationality) between 2 and 60),
  ownership_pct numeric(5, 2) check (ownership_pct between 0 and 100),
  id_number text check (char_length(id_number) between 5 and 30)
);
create index business_application_parties_idx on public.business_application_parties (application_id);

create table public.business_application_branches (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.business_applications (id) on delete cascade,
  name text not null check (char_length(name) between 2 and 100),
  address text not null check (char_length(address) between 5 and 300),
  location_id integer references public.locations (id),
  phone text check (phone ~ '^\+?[0-9 ]{9,16}$')
);
create index business_application_branches_idx on public.business_application_branches (application_id);

create table public.business_application_permits (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.business_applications (id) on delete cascade,
  permit_type text not null check (char_length(permit_type) between 2 and 100),
  permit_number text check (char_length(permit_number) <= 60),
  issuer text check (char_length(issuer) <= 100),
  expires_on date
);
create index business_application_permits_idx on public.business_application_permits (application_id);

-- What the officer checked on their own, apart from what the applicant sent. Permanent.
create table public.business_application_checks (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.business_applications (id) on delete cascade,
  check_type text not null check (check_type in ('registry_lookup', 'tpin_check', 'phone_call', 'video_call', 'address_check', 'authority_confirmed', 'permit_check', 'other')),
  result text not null check (result in ('passed', 'failed', 'inconclusive')),
  notes text not null check (char_length(notes) between 5 and 1000),
  checked_by uuid not null references public.profiles (id),
  checked_at timestamptz not null default clock_timestamp()
);
create index business_application_checks_idx on public.business_application_checks (application_id);

alter table public.business_applications enable row level security;
alter table public.business_application_private enable row level security;
alter table public.business_application_parties enable row level security;
alter table public.business_application_branches enable row level security;
alter table public.business_application_permits enable row level security;
alter table public.business_application_checks enable row level security;

-- ---------------------------------------------------------------------------
-- 3. Helpers
-- ---------------------------------------------------------------------------
create function public.business_need_not_own(p_app public.business_applications)
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if p_app.user_id = (select auth.uid()) then
    raise exception 'You cannot review your own application.' using errcode = 'insufficient_privilege';
  end if;
end;
$$;

create function public.business_notify(p_user uuid, p_app uuid, p_title text, p_body text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.notify(p_user, 'account', 'business_application', p_title, p_body, '/verify/business',
                        'business_app:' || p_app || ':' || md5(p_title || p_body || clock_timestamp()::text));
end;
$$;

create function public.business_required_kinds(p_route text, p_rep_is_director boolean)
returns text[]
language sql immutable set search_path = ''
as $$
  select case p_route
    when 'informal_trader' then array['director_id', 'premises_evidence', 'ownership_evidence']
    else array['pacra_certificate', 'tpin_certificate', 'premises_evidence', 'director_id']
         || case when p_rep_is_director is distinct from true then array['authority_letter'] else array[]::text[] end
    end
$$;

-- Checks the officer must record as passed before approving.
create function public.business_required_checks(p_route text)
returns text[]
language sql immutable set search_path = ''
as $$
  select case p_route when 'informal_trader' then array['address_check', 'authority_confirmed']
                      else array['registry_lookup', 'authority_confirmed'] end
$$;


-- Readable answers. These are internal: app users cannot call them, the functions below call them as their owner.
create function public.business_check_int(p_value text, p_min integer, p_max integer, p_label text)
returns integer
language plpgsql immutable set search_path = ''
as $$
begin
  if nullif(btrim(coalesce(p_value, '')), '') is null then
    return null;
  end if;
  if btrim(p_value) !~ '^[0-9]{1,9}$' or btrim(p_value)::integer not between p_min and p_max then
    raise exception '% must be a whole number from % to %.', p_label, p_min, p_max using errcode = 'check_violation';
  end if;
  return btrim(p_value)::integer;
end;
$$;

create function public.business_check_date(p_value text, p_label text, p_future_ok boolean default false)
returns date
language plpgsql immutable set search_path = ''
as $$
declare
  d date;
begin
  if nullif(btrim(coalesce(p_value, '')), '') is null then
    return null;
  end if;
  if btrim(p_value) !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception '% must be a date written as YYYY-MM-DD.', p_label using errcode = 'check_violation';
  end if;
  begin
    d := btrim(p_value)::date;
  exception when others then
    raise exception '% is not a real date.', p_label using errcode = 'check_violation';
  end;
  if not p_future_ok and d > current_date then
    raise exception '% cannot be in the future.', p_label using errcode = 'check_violation';
  end if;
  return d;
end;
$$;

create function public.business_check_bool(p_value text, p_label text)
returns boolean
language plpgsql immutable set search_path = ''
as $$
begin
  if p_value is null then
    return null;
  end if;
  if p_value not in ('true', 'false') then
    raise exception '% must be yes or no.', p_label using errcode = 'check_violation';
  end if;
  return p_value::boolean;
end;
$$;

create function public.business_check_pattern(p_value text, p_pattern text, p_label text, p_hint text)
returns void
language plpgsql immutable set search_path = ''
as $$
begin
  if nullif(btrim(coalesce(p_value, '')), '') is not null and btrim(p_value) !~ p_pattern then
    raise exception '% %', p_label, p_hint using errcode = 'check_violation';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Applicant functions (owners only)
-- ---------------------------------------------------------------------------
create function public.business_need_owner(p_business uuid)
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_business_member(p_business, array['owner']::public.business_member_role[]) then
    raise exception 'Only the owner of the business can do this.' using errcode = 'insufficient_privilege';
  end if;
end;
$$;

create function public.business_application_save(p_business uuid, p_data jsonb)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  a public.business_applications;
  b public.businesses;
  wait_days integer := public.setting_numeric('business.reapply_days', 7)::integer;
  last_rejected timestamptz;
  cats integer[];
begin
  perform public.business_need_owner(p_business);
  if (select account_state from public.profiles where id = uid) <> 'active' then
    raise exception 'Your account cannot apply right now.' using errcode = 'insufficient_privilege';
  end if;
  select * into b from public.businesses where id = p_business;
  if b.publish_state <> 'none' then
    raise exception 'This business already has a verification record. Open it from the business centre.' using errcode = 'check_violation';
  end if;
  perform public.enforce_rate_limit('business_application_save', 120, 60);

  -- Say plainly which answer is wrong, instead of failing later with a raw table-rule message.
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    raise exception 'Send the answers as a list of fields.' using errcode = 'check_violation';
  end if;
  if p_data ? 'legal_name' then perform public.seller_check_text(p_data ->> 'legal_name', 3, 150, 'The legal name'); end if;
  if p_data ? 'trading_name' then perform public.seller_check_text(p_data ->> 'trading_name', 2, 120, 'The trading name'); end if;
  if p_data ? 'pacra_number' then perform public.seller_check_text(upper(p_data ->> 'pacra_number'), 4, 30, 'The registration number'); end if;
  if p_data ? 'tpin' then perform public.seller_check_text(upper(p_data ->> 'tpin'), 5, 20, 'The TPIN'); end if;
  if p_data ? 'physical_address' then perform public.seller_check_text(p_data ->> 'physical_address', 10, 300, 'The physical address'); end if;
  if p_data ? 'trading_place' then perform public.seller_check_text(p_data ->> 'trading_place', 5, 300, 'Where you trade'); end if;
  if p_data ? 'ownership_summary' then perform public.seller_check_text(p_data ->> 'ownership_summary', 1, 1000, 'The ownership summary'); end if;
  if p_data ? 'rep_name' then perform public.seller_check_text(p_data ->> 'rep_name', 3, 120, 'The representative''s name'); end if;
  if p_data ? 'rep_role' then perform public.seller_check_text(p_data ->> 'rep_role', 2, 80, 'The representative''s role'); end if;
  if p_data ? 'rep_id_number' then perform public.seller_check_text(upper(p_data ->> 'rep_id_number'), 5, 30, 'The representative''s ID number'); end if;
  if p_data ? 'phone' then perform public.business_check_pattern(p_data ->> 'phone', '^\+?[0-9 ]{9,16}$', 'The phone number', 'must be 9 to 16 digits, for example +260971000111.'); end if;
  if p_data ? 'email' then perform public.business_check_pattern(p_data ->> 'email', '^[^@\s]+@[^@\s]+\.[^@\s]+$', 'The email address', 'is not a valid email address.'); end if;
  if p_data ? 'business_type' and nullif(p_data ->> 'business_type', '') is not null
     and (p_data ->> 'business_type') not in ('sole_proprietorship', 'partnership', 'limited_company', 'cooperative', 'ngo', 'informal_trader') then
    raise exception 'Choose the type of business from the list.' using errcode = 'check_violation';
  end if;
  if p_data ? 'expected_catalogue_size' then perform public.business_check_int(p_data ->> 'expected_catalogue_size', 1, 100000, 'The number of products'); end if;
  if p_data ? 'years_trading' then perform public.business_check_int(p_data ->> 'years_trading', 0, 80, 'Years of trading'); end if;
  if p_data ? 'pacra_registered_on' then perform public.business_check_date(p_data ->> 'pacra_registered_on', 'The registration date'); end if;
  if p_data ? 'rep_is_director' and jsonb_typeof(p_data -> 'rep_is_director') not in ('boolean', 'null') then
    raise exception 'Say yes or no: is the representative a director?' using errcode = 'check_violation';
  end if;
  if p_data ? 'declarations' and jsonb_typeof(p_data -> 'declarations') not in ('object', 'null') then
    raise exception 'The declarations are not in the right form.' using errcode = 'check_violation';
  end if;
  if p_data ? 'selling_location_id' and p_data ->> 'selling_location_id' is not null
     and p_data ->> 'selling_location_id' !~ '^[0-9]{1,9}$' then
    raise exception 'Choose a location from the list.' using errcode = 'check_violation';
  end if;

  select * into a from public.business_applications
   where business_id = p_business and status in ('draft', 'submitted', 'under_review', 'additional_information_required') for update;
  if not found then
    -- Only a real rejection starts the waiting period. A withdrawn application is stored as 'rejected' too, but the owner
    -- chose to stop, so it must not stop them starting again.
    select max(r.decided_at) into last_rejected from public.business_applications r
     where r.business_id = p_business and r.status = 'rejected'
       and not exists (select 1 from public.verification_events e
                        where e.subject_type = 'business_application' and e.subject_id = r.id and e.event = 'withdrawn');
    if last_rejected is not null and last_rejected > now() - make_interval(days => wait_days) then
      raise exception 'You can apply again after % days from the decision.', wait_days using errcode = 'check_violation';
    end if;
    insert into public.business_applications (business_id, user_id) values (p_business, uid) returning * into a;
    insert into public.business_application_private (application_id) values (a.id);
    perform public.verification_log('business_application', a.id, uid, 'created', null, 'draft', null, true);
  elsif a.status in ('submitted', 'under_review') then
    raise exception 'Your application is being reviewed and cannot be changed now.' using errcode = 'check_violation';
  end if;

  if p_data ? 'category_ids' then
    if jsonb_typeof(p_data -> 'category_ids') <> 'array'
       or exists (select 1 from jsonb_array_elements_text(p_data -> 'category_ids') x where x !~ '^[0-9]{1,9}$') then
      raise exception 'Choose categories from the list.' using errcode = 'check_violation';
    end if;
    select coalesce(array_agg(distinct x::integer), '{}') into cats from jsonb_array_elements_text(p_data -> 'category_ids') x;
    if exists (select 1 from unnest(cats) c where not exists (select 1 from public.categories k where k.id = c and k.is_active)) then
      raise exception 'Choose categories from the list.' using errcode = 'check_violation';
    end if;
    if coalesce(array_length(cats, 1), 0) > 30 then
      raise exception 'Choose up to 30 categories.' using errcode = 'check_violation';
    end if;
  else
    cats := a.category_ids;
  end if;
  if p_data ? 'selling_location_id' and p_data ->> 'selling_location_id' is not null
     and not exists (select 1 from public.locations l where l.id = (p_data ->> 'selling_location_id')::integer) then
    raise exception 'Choose a location from the list.' using errcode = 'check_violation';
  end if;
  if p_data ? 'route' and (p_data ->> 'route') not in ('registered', 'informal_trader') then
    raise exception 'Choose registered business or informal trader.' using errcode = 'check_violation';
  end if;

  update public.business_applications set
    route = case when p_data ? 'route' then p_data ->> 'route' else route end,
    legal_name = case when p_data ? 'legal_name' then nullif(btrim(p_data ->> 'legal_name'), '') else legal_name end,
    trading_name = case when p_data ? 'trading_name' then nullif(btrim(p_data ->> 'trading_name'), '') else trading_name end,
    business_type = case when p_data ? 'business_type' then nullif(p_data ->> 'business_type', '') else business_type end,
    pacra_number = case when p_data ? 'pacra_number' then upper(nullif(btrim(p_data ->> 'pacra_number'), '')) else pacra_number end,
    pacra_registered_on = case when p_data ? 'pacra_registered_on' then public.business_check_date(p_data ->> 'pacra_registered_on', 'The registration date') else pacra_registered_on end,
    physical_address = case when p_data ? 'physical_address' then nullif(btrim(p_data ->> 'physical_address'), '') else physical_address end,
    selling_location_id = case when p_data ? 'selling_location_id' then nullif(p_data ->> 'selling_location_id', '')::integer else selling_location_id end,
    phone = case when p_data ? 'phone' then nullif(btrim(p_data ->> 'phone'), '') else phone end,
    email = case when p_data ? 'email' then lower(nullif(btrim(p_data ->> 'email'), '')) else email end,
    category_ids = cats,
    expected_catalogue_size = case when p_data ? 'expected_catalogue_size' then public.business_check_int(p_data ->> 'expected_catalogue_size', 1, 100000, 'The number of products') else expected_catalogue_size end,
    trading_place = case when p_data ? 'trading_place' then nullif(btrim(p_data ->> 'trading_place'), '') else trading_place end,
    years_trading = case when p_data ? 'years_trading' then public.business_check_int(p_data ->> 'years_trading', 0, 80, 'Years of trading') else years_trading end,
    ownership_summary = case when p_data ? 'ownership_summary' then nullif(btrim(p_data ->> 'ownership_summary'), '') else ownership_summary end,
    rep_name = case when p_data ? 'rep_name' then nullif(btrim(p_data ->> 'rep_name'), '') else rep_name end,
    rep_role = case when p_data ? 'rep_role' then nullif(btrim(p_data ->> 'rep_role'), '') else rep_role end,
    rep_is_director = case when p_data ? 'rep_is_director' then public.business_check_bool(p_data ->> 'rep_is_director', 'The representative question') else rep_is_director end,
    declarations = case when p_data ? 'declarations' then (p_data -> 'declarations') else declarations end
   where id = a.id;
  update public.business_application_private set
    tpin = case when p_data ? 'tpin' then upper(nullif(btrim(p_data ->> 'tpin'), '')) else tpin end,
    rep_id_number = case when p_data ? 'rep_id_number' then upper(nullif(btrim(p_data ->> 'rep_id_number'), '')) else rep_id_number end
   where application_id = a.id;
  return a.id;
end;
$$;

-- Lists replace what was there. Draft or "more information needed" only, owner only.
create function public.business_application_editable(p_id uuid)
returns public.business_applications
language plpgsql security definer set search_path = ''
as $$
declare
  a public.business_applications;
begin
  select * into a from public.business_applications where id = p_id for update;
  if not found then
    raise exception 'Application not found.' using errcode = 'no_data_found';
  end if;
  perform public.business_need_owner(a.business_id);
  if a.status not in ('draft', 'additional_information_required') then
    raise exception 'This application cannot be changed now.' using errcode = 'check_violation';
  end if;
  return a;
end;
$$;

create function public.business_application_set_parties(p_id uuid, p_parties jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  a public.business_applications := public.business_application_editable(p_id);
  x jsonb;
begin
  if p_parties is null or jsonb_typeof(p_parties) <> 'array' or jsonb_array_length(p_parties) > 30 then
    raise exception 'Send a list of up to 30 people.' using errcode = 'check_violation';
  end if;
  delete from public.business_application_parties where application_id = a.id;
  for x in select * from jsonb_array_elements(p_parties) loop
    if jsonb_typeof(x) <> 'object' then
      raise exception 'Each person must be sent as a set of fields.' using errcode = 'check_violation';
    end if;
    if coalesce(x ->> 'kind', '') not in ('director', 'beneficial_owner') then
      raise exception 'Say whether each person is a director or a beneficial owner.' using errcode = 'check_violation';
    end if;
    if char_length(btrim(coalesce(x ->> 'full_name', ''))) not between 3 and 120 then
      raise exception 'Each person''s full name must be 3 to 120 characters.' using errcode = 'check_violation';
    end if;
    perform public.seller_check_text(x ->> 'nationality', 2, 60, 'A nationality');
    perform public.seller_check_text(upper(x ->> 'id_number'), 5, 30, 'An ID number');
    if (x ->> 'kind') = 'beneficial_owner' and nullif(btrim(coalesce(x ->> 'ownership_pct', '')), '') is null then
      raise exception 'Give the ownership percentage of every beneficial owner.' using errcode = 'check_violation';
    end if;
    if nullif(btrim(coalesce(x ->> 'ownership_pct', '')), '') is not null
       and (btrim(x ->> 'ownership_pct') !~ '^[0-9]{1,3}(\.[0-9]{1,2})?$' or btrim(x ->> 'ownership_pct')::numeric > 100) then
      raise exception 'An ownership percentage must be a number from 0 to 100.' using errcode = 'check_violation';
    end if;
    insert into public.business_application_parties (application_id, kind, full_name, nationality, ownership_pct, id_number)
    values (a.id, x ->> 'kind', btrim(x ->> 'full_name'), nullif(btrim(x ->> 'nationality'), ''), nullif(btrim(coalesce(x ->> 'ownership_pct', '')), '')::numeric,
            upper(nullif(btrim(x ->> 'id_number'), '')));
  end loop;
  perform public.verification_log('business_application', a.id, a.user_id, 'parties_updated', null, null, null, false);
end;
$$;

create function public.business_application_set_branches(p_id uuid, p_branches jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  a public.business_applications := public.business_application_editable(p_id);
  x jsonb;
begin
  if p_branches is null or jsonb_typeof(p_branches) <> 'array' or jsonb_array_length(p_branches) > 30 then
    raise exception 'Send a list of up to 30 branches.' using errcode = 'check_violation';
  end if;
  delete from public.business_application_branches where application_id = a.id;
  for x in select * from jsonb_array_elements(p_branches) loop
    if jsonb_typeof(x) <> 'object' then
      raise exception 'Each branch must be sent as a set of fields.' using errcode = 'check_violation';
    end if;
    if char_length(btrim(coalesce(x ->> 'name', ''))) not between 2 and 100 then
      raise exception 'Each branch needs a name of 2 to 100 characters.' using errcode = 'check_violation';
    end if;
    if char_length(btrim(coalesce(x ->> 'address', ''))) not between 5 and 300 then
      raise exception 'Each branch needs an address of 5 to 300 characters.' using errcode = 'check_violation';
    end if;
    perform public.business_check_pattern(x ->> 'phone', '^\+?[0-9 ]{9,16}$', 'A branch phone number', 'must be 9 to 16 digits.');
    if nullif(x ->> 'location_id', '') is not null
       and ((x ->> 'location_id') !~ '^[0-9]{1,9}$' or not exists (select 1 from public.locations l where l.id = (x ->> 'location_id')::integer)) then
      raise exception 'Choose a branch location from the list.' using errcode = 'check_violation';
    end if;
    insert into public.business_application_branches (application_id, name, address, location_id, phone)
    values (a.id, btrim(x ->> 'name'), btrim(x ->> 'address'), nullif(x ->> 'location_id', '')::integer, nullif(btrim(x ->> 'phone'), ''));
  end loop;
end;
$$;

create function public.business_application_set_permits(p_id uuid, p_permits jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  a public.business_applications := public.business_application_editable(p_id);
  x jsonb;
begin
  if p_permits is null or jsonb_typeof(p_permits) <> 'array' or jsonb_array_length(p_permits) > 30 then
    raise exception 'Send a list of up to 30 permits.' using errcode = 'check_violation';
  end if;
  delete from public.business_application_permits where application_id = a.id;
  for x in select * from jsonb_array_elements(p_permits) loop
    if jsonb_typeof(x) <> 'object' then
      raise exception 'Each permit must be sent as a set of fields.' using errcode = 'check_violation';
    end if;
    if char_length(btrim(coalesce(x ->> 'permit_type', ''))) not between 2 and 100 then
      raise exception 'Each permit needs a type of 2 to 100 characters.' using errcode = 'check_violation';
    end if;
    perform public.seller_check_text(x ->> 'permit_number', 1, 60, 'A permit number');
    perform public.seller_check_text(x ->> 'issuer', 1, 100, 'A permit issuer');
    insert into public.business_application_permits (application_id, permit_type, permit_number, issuer, expires_on)
    values (a.id, btrim(x ->> 'permit_type'), nullif(btrim(x ->> 'permit_number'), ''), nullif(btrim(x ->> 'issuer'), ''),
            public.business_check_date(x ->> 'expires_on', 'A permit expiry date', true));
  end loop;
end;
$$;

create function public.business_application_submit(p_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  a public.business_applications := public.business_application_editable(p_id);
  pv public.business_application_private;
  have text[];
  need text[];
  missing text[];
  big integer;
  risky boolean;
  keys text[] := array['information_is_true', 'authorised_to_apply', 'sells_only_legal_goods', 'no_counterfeit_or_stolen', 'will_honour_returns'];
  k text;
  owner_pct numeric;
begin
  select * into pv from public.business_application_private where application_id = a.id;
  if (select verification_level from public.profiles where id = uid) = 'unverified' then
    raise exception 'Verify your phone number and email first.' using errcode = 'check_violation';
  end if;
  if a.legal_name is null or a.business_type is null or a.physical_address is null or a.selling_location_id is null
     or a.phone is null or a.email is null or coalesce(array_length(a.category_ids, 1), 0) = 0 or a.expected_catalogue_size is null
     or a.rep_name is null or a.rep_role is null or a.rep_is_director is null or pv.rep_id_number is null then
    raise exception 'Some answers are missing. Complete every section before sending.' using errcode = 'check_violation';
  end if;
  if a.route = 'registered' and (a.pacra_number is null or a.pacra_registered_on is null or pv.tpin is null) then
    raise exception 'A registered business needs its registry number, registration date and TPIN.' using errcode = 'check_violation';
  end if;
  if a.route = 'informal_trader' and (a.trading_place is null or a.years_trading is null) then
    raise exception 'An informal trader must say where they trade and for how long.' using errcode = 'check_violation';
  end if;
  foreach k in array keys loop
    if coalesce(a.declarations ->> k, '') <> 'true' then
      raise exception 'Please confirm every declaration.' using errcode = 'check_violation';
    end if;
  end loop;
  if a.route = 'registered' then
    if not exists (select 1 from public.business_application_parties where application_id = a.id and kind = 'director') then
      raise exception 'List at least one director or proprietor.' using errcode = 'check_violation';
    end if;
    select coalesce(sum(ownership_pct), 0) into owner_pct from public.business_application_parties where application_id = a.id and kind = 'beneficial_owner';
    if owner_pct < 99 or owner_pct > 100.01 then
      raise exception 'The beneficial owners you list must add up to 100 per cent (now % per cent).', owner_pct using errcode = 'check_violation';
    end if;
  end if;
  if not exists (select 1 from public.seller_agreement_acceptances c join public.seller_agreements g on g.version = c.version and g.is_current
                  where c.user_id = uid) then
    raise exception 'Accept the agreement before sending.' using errcode = 'check_violation';
  end if;

  need := public.business_required_kinds(a.route, a.rep_is_director);
  select coalesce(array_agg(distinct d.kind), '{}') into have from public.verification_documents d
   where d.subject_type = 'business_application' and d.subject_id = a.id and d.deleted_at is null and d.review_status <> 'rejected' and d.scan_status <> 'infected';
  select coalesce(array_agg(n), '{}') into missing from unnest(need) n where n <> all (have);
  if array_length(missing, 1) > 0 then
    raise exception 'Documents still needed: %.', array_to_string(missing, ', ') using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.verification_requests r where r.subject_type = 'business_application' and r.subject_id = a.id and r.status = 'open') then
    raise exception 'Answer the request for more information first.' using errcode = 'check_violation';
  end if;

  big := case when a.route = 'informal_trader' then public.setting_numeric('business.informal_high_risk_catalogue_size', 100)::integer
              else public.setting_numeric('business.high_risk_catalogue_size', 500)::integer end;
  risky := a.expected_catalogue_size >= big or a.escalated
        or exists (select 1 from public.categories c where c.id = any (a.category_ids) and c.requires_review)
        or (a.route = 'registered' and a.pacra_registered_on > current_date - interval '6 months')
        or exists (select 1 from public.business_application_parties p where p.application_id = a.id and p.kind = 'beneficial_owner'
                    and p.nationality is not null and lower(p.nationality) not in ('zambian', 'zambia'));

  update public.business_applications
     set status = 'submitted', risk_level = case when risky then 'high' else 'standard' end,
         submitted_at = coalesce(submitted_at, now()), due_at = now() + interval '3 days', assigned_to = null, claimed_at = null
   where id = a.id;
  perform public.verification_log('business_application', a.id, uid, 'submitted', a.status, 'submitted', null, true);
  perform public.business_notify(uid, a.id, 'Business application received', 'Our team will check your business. You will be told if we need more information.');
end;
$$;

create function public.business_application_withdraw(p_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  a public.business_applications;
  keep integer := public.setting_numeric('retention.verification_rejected_days', 30)::integer;
begin
  select * into a from public.business_applications where id = p_id
     and status in ('draft', 'submitted', 'under_review', 'additional_information_required') for update;
  if not found then
    raise exception 'You have no open application.' using errcode = 'no_data_found';
  end if;
  perform public.business_need_owner(a.business_id);
  update public.business_applications set status = 'rejected', decided_at = now(), decision_reason = 'Withdrawn by the applicant.' where id = a.id;
  update public.verification_documents set purge_after = now() + make_interval(days => keep)
   where subject_type = 'business_application' and subject_id = a.id and purge_after is null;
  perform public.verification_log('business_application', a.id, a.user_id, 'withdrawn', a.status, 'rejected', null, true);
end;
$$;

create function public.business_application_respond(p_request uuid, p_response text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  r public.verification_requests;
  a public.business_applications;
begin
  select * into r from public.verification_requests where id = p_request and subject_type = 'business_application' for update;
  if not found then
    raise exception 'Request not found.' using errcode = 'no_data_found';
  end if;
  select * into a from public.business_applications where id = r.subject_id for update;
  perform public.business_need_owner(a.business_id);
  if r.status <> 'open' or a.status <> 'additional_information_required' then
    raise exception 'This request is closed.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from unnest(r.document_kinds) k where not exists (
        select 1 from public.verification_documents d where d.subject_type = 'business_application' and d.subject_id = a.id
           and d.kind = k and d.created_at > r.created_at and d.deleted_at is null and d.scan_status <> 'infected')) then
    raise exception 'Upload the documents that were asked for first.' using errcode = 'check_violation';
  end if;
  update public.verification_requests set status = 'answered', response = left(btrim(coalesce(p_response, '')), 1000), answered_at = now() where id = r.id;
  if not exists (select 1 from public.verification_requests x where x.subject_type = 'business_application' and x.subject_id = a.id and x.status = 'open') then
    update public.business_applications set status = case when assigned_to is null then 'submitted' else 'under_review' end where id = a.id;
    perform public.verification_log('business_application', a.id, uid, 'information_provided', a.status, case when a.assigned_to is null then 'submitted' else 'under_review' end, null, true);
  end if;
end;
$$;

-- What the owner sees about their own application (they wrote it, so their own details are included).
create function public.business_application_mine(p_business uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  a public.business_applications;
  pv public.business_application_private;
  b public.businesses;
begin
  perform public.business_need_owner(p_business);
  select * into b from public.businesses where id = p_business;
  if not found then
    raise exception 'That business was not found.' using errcode = 'no_data_found';
  end if;
  select * into a from public.business_applications where business_id = p_business
   order by (status in ('draft', 'submitted', 'under_review', 'additional_information_required', 'approved', 'suspended')) desc, created_at desc limit 1;
  if not found then
    return jsonb_build_object(
      'publish_state', coalesce(b.publish_state, 'none'), 'registration_kind', b.registration_kind, 'application', null,
      'parties', '[]'::jsonb, 'branches', '[]'::jsonb, 'permits', '[]'::jsonb, 'documents', '[]'::jsonb, 'requests', '[]'::jsonb, 'history', '[]'::jsonb);
  end if;
  select * into pv from public.business_application_private where application_id = a.id;
  return jsonb_build_object(
    'publish_state', b.publish_state, 'registration_kind', b.registration_kind,
    'application', jsonb_build_object(
      'id', a.id, 'status', a.status, 'route', a.route, 'legal_name', a.legal_name, 'trading_name', a.trading_name,
      'business_type', a.business_type, 'pacra_number', a.pacra_number, 'pacra_registered_on', a.pacra_registered_on, 'tpin', pv.tpin,
      'physical_address', a.physical_address, 'selling_location_id', a.selling_location_id, 'phone', a.phone, 'email', a.email,
      'category_ids', a.category_ids, 'expected_catalogue_size', a.expected_catalogue_size, 'trading_place', a.trading_place,
      'years_trading', a.years_trading, 'ownership_summary', a.ownership_summary, 'rep_name', a.rep_name, 'rep_role', a.rep_role,
      'rep_is_director', a.rep_is_director, 'rep_id_number', pv.rep_id_number, 'declarations', a.declarations,
      'submitted_at', a.submitted_at, 'decision_reason', a.decision_reason, 'decided_at', a.decided_at,
      'required_documents', public.business_required_kinds(a.route, a.rep_is_director),
      'agreement_accepted', exists (select 1 from public.seller_agreement_acceptances c join public.seller_agreements g
                                     on g.version = c.version and g.is_current where c.user_id = (select auth.uid()))),
    'parties', coalesce((select jsonb_agg(jsonb_build_object('kind', p.kind, 'full_name', p.full_name, 'nationality', p.nationality,
                  'ownership_pct', p.ownership_pct, 'id_number', p.id_number) order by p.kind, p.full_name)
                  from public.business_application_parties p where p.application_id = a.id), '[]'::jsonb),
    'branches', coalesce((select jsonb_agg(jsonb_build_object('name', x.name, 'address', x.address, 'location_id', x.location_id, 'phone', x.phone) order by x.name)
                  from public.business_application_branches x where x.application_id = a.id), '[]'::jsonb),
    'permits', coalesce((select jsonb_agg(jsonb_build_object('permit_type', x.permit_type, 'permit_number', x.permit_number, 'issuer', x.issuer,
                  'expires_on', x.expires_on) order by x.permit_type) from public.business_application_permits x where x.application_id = a.id), '[]'::jsonb),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'scan', d.scan_status, 'review', d.review_status,
                  'note', d.review_note, 'at', d.created_at) order by d.created_at)
                  from public.verification_documents d where d.subject_type = 'business_application' and d.subject_id = a.id and d.deleted_at is null), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'message', r.message, 'document_kinds', r.document_kinds,
                  'status', r.status, 'due_at', r.due_at, 'created_at', r.created_at) order by r.created_at)
                  from public.verification_requests r where r.subject_type = 'business_application' and r.subject_id = a.id), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(jsonb_build_object('event', e.event, 'to_status', e.to_status, 'note', e.note, 'at', e.created_at) order by e.id)
                  from public.verification_events e where e.subject_type = 'business_application' and e.subject_id = a.id and e.visible_to_applicant), '[]'::jsonb));
end;
$$;

-- Documents for business applications go through the same registration function (extended here: owners only).
create or replace function public.verification_register_document(
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
  biz uuid;
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;
  if p_subject_type = 'seller_application' then
    select user_id into holder from public.seller_applications
     where id = p_subject_id and status in ('draft', 'additional_information_required');
    owner_ok := holder = uid;
  elsif p_subject_type = 'business_application' then
    select business_id into biz from public.business_applications
     where id = p_subject_id and status in ('draft', 'additional_information_required');
    owner_ok := biz is not null and public.is_business_member(biz, array['owner']::public.business_member_role[]);
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

-- ---------------------------------------------------------------------------
-- 5. Support functions (generated from the seller ones, then adjusted; see 0023 for the commentary)
-- ---------------------------------------------------------------------------
create function public.business_application_claim(p_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  a public.business_applications;
begin
  perform public.verification_need_support();
  select * into a from public.business_applications where id = p_id and status in ('submitted', 'under_review') for update;
  if not found then
    raise exception 'That application is not waiting for review.' using errcode = 'no_data_found';
  end if;
  perform public.business_need_not_own(a);
  if a.assigned_to is not null and a.assigned_to <> uid then
    raise exception 'Another officer is already working on this application.' using errcode = 'check_violation';
  end if;
  if a.first_approved_by = uid then
    raise exception 'A different officer must give the second approval.' using errcode = 'insufficient_privilege';
  end if;
  update public.business_applications set assigned_to = uid, claimed_at = now(), status = 'under_review' where id = a.id;
  perform public.verification_log('business_application', a.id, a.user_id, 'claimed', a.status, 'under_review', null, a.status = 'submitted');
  if a.status = 'submitted' then
    perform public.business_notify(a.user_id, a.id, 'Your application is being reviewed', 'An officer has started reviewing your business application.');
  end if;
end;
$$;

create function public.business_application_assign(p_id uuid, p_to uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  a public.business_applications;
begin
  perform public.verification_need_support();
  select * into a from public.business_applications where id = p_id and status in ('submitted', 'under_review') for update;
  if not found then
    raise exception 'That application is not waiting for review.' using errcode = 'no_data_found';
  end if;
  perform public.business_need_not_own(a);
  if p_to = a.user_id or not exists (select 1 from public.admin_roles r join public.profiles x on x.id = r.user_id
                                      where r.user_id = p_to and r.role = 'support' and x.account_state = 'active') then
    raise exception 'Assign to an active support officer who is not the applicant.' using errcode = 'check_violation';
  end if;
  if a.first_approved_by = p_to then
    raise exception 'The second approval must come from a different officer.' using errcode = 'check_violation';
  end if;
  update public.business_applications set assigned_to = p_to, claimed_at = now(), status = 'under_review' where id = a.id;
  perform public.verification_log('business_application', a.id, a.user_id, 'assigned', a.status, 'under_review', p_to::text, false);
  perform public.notify(p_to, 'account', 'verification_assigned', 'An application was assigned to you', 'Open the verification queue to review it.',
                        '/trust/applications', 'assign:' || a.id || ':' || p_to);
end;
$$;

create function public.business_application_request_info(p_id uuid, p_message text, p_kinds text[] default '{}')
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  a public.business_applications;
  new_id uuid;
  days integer := public.setting_numeric('verification.info_request_days', 14)::integer;
begin
  perform public.verification_need_support();
  select * into a from public.business_applications where id = p_id and status in ('submitted', 'under_review') for update;
  if not found then
    raise exception 'That application is not waiting for review.' using errcode = 'no_data_found';
  end if;
  perform public.business_need_not_own(a);
  if a.assigned_to is distinct from (select auth.uid()) then
    raise exception 'Claim the application first.' using errcode = 'check_violation';
  end if;
  if p_message is null or char_length(btrim(p_message)) < 5 then
    raise exception 'Say what you need from the applicant.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from unnest(coalesce(p_kinds, '{}')) k where k not in (
      'pacra_certificate', 'tpin_certificate', 'permit', 'ownership_evidence', 'authority_letter', 'director_id', 'premises_evidence', 'proof_of_address', 'product_evidence', 'other')) then
    raise exception 'Unknown document type.' using errcode = 'check_violation';
  end if;
  insert into public.verification_requests (subject_type, subject_id, requested_by, message, document_kinds, due_at)
  values ('business_application', a.id, (select auth.uid()), left(btrim(p_message), 1000), coalesce(p_kinds, '{}'), now() + make_interval(days => days))
  returning id into new_id;
  update public.business_applications set status = 'additional_information_required' where id = a.id;
  perform public.verification_log('business_application', a.id, a.user_id, 'information_requested', a.status, 'additional_information_required', p_message, true);
  perform public.business_notify(a.user_id, a.id, 'We need more information', 'Open your business application to see what we need.');
  return new_id;
end;
$$;

create function public.business_application_record_interview(p_id uuid, p_channel text, p_outcome text, p_answers jsonb, p_notes text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  a public.business_applications;
  new_id uuid;
begin
  perform public.verification_need_support();
  select * into a from public.business_applications where id = p_id and status = 'under_review' for update;
  if not found then
    raise exception 'That application is not under review.' using errcode = 'no_data_found';
  end if;
  perform public.business_need_not_own(a);
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
  values ('business_application', a.id, (select auth.uid()), p_channel, p_outcome, p_answers, left(p_notes, 2000))
  returning id into new_id;
  perform public.verification_log('business_application', a.id, a.user_id, 'interview_recorded', null, null, p_channel || ': ' || p_outcome, false);
  return new_id;
end;
$$;

create function public.business_application_escalate(p_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  a public.business_applications;
begin
  perform public.verification_need_support();
  select * into a from public.business_applications where id = p_id and status in ('submitted', 'under_review', 'additional_information_required') for update;
  if not found then
    raise exception 'That application cannot be escalated.' using errcode = 'no_data_found';
  end if;
  perform public.business_need_not_own(a);
  if p_reason is null or char_length(btrim(p_reason)) < 10 then
    raise exception 'Write why this application looks suspicious (at least 10 characters).' using errcode = 'check_violation';
  end if;
  update public.business_applications set escalated = true, escalation_reason = left(btrim(p_reason), 500), risk_level = 'high',
         first_approved_by = null, assigned_to = null
   where id = a.id;
  perform public.verification_log('business_application', a.id, a.user_id, 'escalated', a.status, a.status, p_reason, false);
end;
$$;

create function public.business_application_decide(p_id uuid, p_decision text, p_reason text default null)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  a public.business_applications;
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
  select * into a from public.business_applications where id = p_id and status = 'under_review' for update;
  if not found then
    raise exception 'That application is not under review.' using errcode = 'no_data_found';
  end if;
  perform public.business_need_not_own(a);
  if a.assigned_to is distinct from uid then
    raise exception 'Claim the application first.' using errcode = 'check_violation';
  end if;

  if p_decision = 'reject' then
    if reason is null or char_length(reason) < 10 then
      raise exception 'A rejection needs a reason the applicant can read (at least 10 characters).' using errcode = 'check_violation';
    end if;
    update public.business_applications set status = 'rejected', decided_by = uid, decided_at = now(), decision_reason = left(reason, 500),
           assigned_to = null where id = a.id;
    update public.verification_documents set purge_after = now() + make_interval(days => keep_no)
     where subject_type = 'business_application' and subject_id = a.id and purge_after is null;
    perform public.verification_log('business_application', a.id, a.user_id, 'rejected', 'under_review', 'rejected', reason, true);
    perform public.business_notify(a.user_id, a.id, 'Your business application was not approved', 'Open your application to read the reason.');
    perform public.write_audit('business_application.rejected', 'user', a.user_id::text, jsonb_build_object('application_id', a.id));
    return 'rejected';
  end if;

  need := public.business_required_kinds(a.route, a.rep_is_director);
  select coalesce(array_agg(n), '{}') into missing from unnest(need) n where not exists (
    select 1 from public.verification_documents d where d.subject_type = 'business_application' and d.subject_id = a.id
       and d.kind = n and d.review_status = 'accepted' and d.scan_status = 'clean' and d.deleted_at is null);
  if array_length(missing, 1) > 0 then
    raise exception 'These documents are not accepted yet: %.', array_to_string(missing, ', ') using errcode = 'check_violation';
  end if;
  select coalesce(array_agg(c), '{}') into missing from unnest(public.business_required_checks(a.route)) c where not exists (
    select 1 from public.business_application_checks k where k.application_id = a.id and k.check_type = c and k.result = 'passed');
  if array_length(missing, 1) > 0 then
    raise exception 'These checks are not recorded as passed yet: %.', array_to_string(missing, ', ') using errcode = 'check_violation';
  end if;
  needs_two := a.risk_level = 'high' or a.escalated;
  if not exists (select 1 from public.verification_interviews i where i.subject_type = 'business_application'
                                and i.subject_id = a.id and i.outcome = 'passed') then
    raise exception 'A business application needs a telephone or video interview that passed.' using errcode = 'check_violation';
  end if;
  if reason is null or char_length(reason) < 5 then
    raise exception 'Record why you approved it.' using errcode = 'check_violation';
  end if;

  if needs_two and a.first_approved_by is null then
    update public.business_applications set first_approved_by = uid, assigned_to = null where id = a.id;
    perform public.verification_log('business_application', a.id, a.user_id, 'first_approval', 'under_review', 'under_review', reason, false);
    return 'awaiting_second_approval';
  end if;
  if needs_two and a.first_approved_by = uid then
    raise exception 'A different officer must give the second approval.' using errcode = 'insufficient_privilege';
  end if;

  update public.business_applications set status = 'approved', decided_by = uid, decided_at = now(), decision_reason = left(reason, 500),
         assigned_to = null where id = a.id;
  update public.businesses set publish_state = 'active', verification_status = 'verified',
         registration_kind = case when a.route = 'informal_trader' then 'informal_trader' else 'registered' end where id = a.business_id;
  update public.verification_documents set purge_after = now() + make_interval(days => keep_ok)
   where subject_type = 'business_application' and subject_id = a.id and purge_after is null;
  perform public.verification_log('business_application', a.id, a.user_id, 'approved', 'under_review', 'approved', reason, true);
  perform public.business_notify(a.user_id, a.id, 'Your business is verified', 'Your business can now publish listings.');
  perform public.write_audit('business_application.approved', 'user', a.user_id::text,
    jsonb_build_object('application_id', a.id, 'two_reviewers', needs_two, 'first', a.first_approved_by));
  return 'approved';
end;
$$;

create function public.business_application_suspend(p_id uuid, p_reason text, p_revoke boolean default false)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  a public.business_applications;
  reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform public.verification_need_support();
  select * into a from public.business_applications where id = p_id and status in ('approved', 'suspended') for update;
  if not found then
    raise exception 'Only an approved or suspended business can be suspended or revoked.' using errcode = 'no_data_found';
  end if;
  perform public.business_need_not_own(a);
  if reason is null or char_length(reason) < 10 then
    raise exception 'Write the reason (at least 10 characters). The business can read it.' using errcode = 'check_violation';
  end if;
  if a.status = 'suspended' and not p_revoke then
    raise exception 'This business is already suspended.' using errcode = 'check_violation';
  end if;
  update public.business_applications set status = case when p_revoke then 'revoked' else 'suspended' end,
         decided_by = (select auth.uid()), decided_at = now(), decision_reason = left(reason, 500) where id = a.id;
  update public.businesses set publish_state = case when p_revoke then 'revoked' else 'suspended' end, verification_status = 'unverified'
   where id = a.business_id;
  update public.listings set status = 'unavailable' where business_id = a.business_id and status = 'active';
  perform public.verification_log('business_application', a.id, a.user_id, case when p_revoke then 'revoked' else 'suspended' end,
                                  a.status, case when p_revoke then 'revoked' else 'suspended' end, reason, true);
  perform public.business_notify(a.user_id, a.id, case when p_revoke then 'Your business verification was ended' else 'Your business is suspended' end,
                               'Open your business verification page to read the reason. You can appeal this decision.');
  perform public.write_audit(case when p_revoke then 'business.revoked' else 'business.suspended' end, 'user', a.user_id::text,
                             jsonb_build_object('application_id', a.id));
end;
$$;

create function public.business_application_reinstate(p_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  a public.business_applications;
  reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform public.verification_need_support();
  select * into a from public.business_applications where id = p_id and status = 'suspended' for update;
  if not found then
    raise exception 'Only a suspended business can be reinstated.' using errcode = 'no_data_found';
  end if;
  perform public.business_need_not_own(a);
  if a.decided_by = (select auth.uid()) then
    raise exception 'A different officer must reinstate a business you suspended.' using errcode = 'insufficient_privilege';
  end if;
  if reason is null or char_length(reason) < 10 then
    raise exception 'Write why the business is reinstated (at least 10 characters).' using errcode = 'check_violation';
  end if;
  update public.business_applications set status = 'approved', decided_by = (select auth.uid()), decided_at = now(), decision_reason = left(reason, 500) where id = a.id;
  update public.businesses set publish_state = 'active', verification_status = 'verified' where id = a.business_id;
  perform public.verification_log('business_application', a.id, a.user_id, 'reinstated', 'suspended', 'approved', reason, true);
  perform public.business_notify(a.user_id, a.id, 'Your business is reinstated', 'You can publish again. Paused listings stay paused until you restock or republish them.');
  perform public.write_audit('business.reinstated', 'user', a.user_id::text, jsonb_build_object('application_id', a.id));
end;
$$;

-- A member of the business cannot review its application either (conflict of interest).
create or replace function public.business_need_not_own(p_app public.business_applications)
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if p_app.user_id = (select auth.uid()) or public.is_business_member(p_app.business_id) then
    raise exception 'You cannot review an application for your own business.' using errcode = 'insufficient_privilege';
  end if;
end;
$$;

create function public.business_verification_queue(p_queue text, p_limit integer default 50, p_offset integer default 0)
returns table (
  id uuid, business_id uuid, business_name text, route text, applicant_id uuid, applicant_name text, status text, risk_level text,
  escalated boolean, awaiting_second boolean, assigned_to uuid, assigned_name text, submitted_at timestamptz, due_at timestamptz,
  overdue boolean, pending_documents bigint, mine boolean
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
    select a.id, a.business_id, b.name, a.route, a.user_id, p.display_name, a.status, a.risk_level, a.escalated,
           (a.first_approved_by is not null and a.status = 'under_review'), a.assigned_to, ap.display_name, a.submitted_at, a.due_at,
           (a.due_at is not null and a.due_at < now() and a.status in ('submitted', 'under_review')),
           (select count(*) from public.verification_documents d where d.subject_type = 'business_application' and d.subject_id = a.id
               and d.review_status = 'uploaded' and d.deleted_at is null),
           a.assigned_to = (select auth.uid())
      from public.business_applications a
      join public.businesses b on b.id = a.business_id
      join public.profiles p on p.id = a.user_id
      left join public.profiles ap on ap.id = a.assigned_to
     where a.status <> 'draft' and case p_queue
             when 'sellers' then a.status in ('submitted', 'under_review')
             when 'documents' then a.status in ('submitted', 'under_review') and exists (
                select 1 from public.verification_documents d where d.subject_type = 'business_application' and d.subject_id = a.id
                   and d.review_status = 'uploaded' and d.deleted_at is null)
             when 'info_requested' then a.status = 'additional_information_required'
             when 'escalated' then a.escalated and a.status in ('submitted', 'under_review', 'additional_information_required')
             when 'approved' then a.status = 'approved'
             when 'rejected' then a.status = 'rejected'
             else a.status in ('suspended', 'revoked') end
     order by a.submitted_at nulls last, a.created_at
     limit least(greatest(coalesce(p_limit, 50), 1), 200) offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

-- No TPIN, ID numbers or other personal identifiers here: those need the audited call below.
create function public.business_application_detail(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  a public.business_applications;
begin
  perform public.verification_need_support();
  select * into a from public.business_applications where id = p_id and status <> 'draft';
  if not found then
    raise exception 'Application not found.' using errcode = 'no_data_found';
  end if;
  perform public.business_need_not_own(a);
  return jsonb_build_object(
    'id', a.id, 'status', a.status, 'route', a.route, 'risk_level', a.risk_level, 'escalated', a.escalated, 'escalation_reason', a.escalation_reason,
    'assigned_to', a.assigned_to, 'first_approved_by', a.first_approved_by, 'submitted_at', a.submitted_at, 'due_at', a.due_at,
    'business', (select jsonb_build_object('id', b.id, 'name', b.name, 'publish_state', b.publish_state, 'created_at', b.created_at,
                    'members', (select count(*) from public.business_members m where m.business_id = b.id))
                   from public.businesses b where b.id = a.business_id),
    'applicant', (select jsonb_build_object('id', p.id, 'name', p.display_name, 'verification_level', p.verification_level, 'member_since', p.created_at)
                    from public.profiles p where p.id = a.user_id),
    'legal_name', a.legal_name, 'trading_name', a.trading_name, 'business_type', a.business_type, 'pacra_number', a.pacra_number,
    'pacra_registered_on', a.pacra_registered_on, 'physical_address', a.physical_address, 'phone', a.phone, 'email', a.email,
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'requires_review', c.requires_review)), '[]')
                     from public.categories c where c.id = any (a.category_ids)),
    'expected_catalogue_size', a.expected_catalogue_size, 'trading_place', a.trading_place, 'years_trading', a.years_trading,
    'ownership_summary', a.ownership_summary, 'rep_name', a.rep_name, 'rep_role', a.rep_role, 'rep_is_director', a.rep_is_director,
    'declarations', a.declarations, 'decision_reason', a.decision_reason,
    'required_documents', public.business_required_kinds(a.route, a.rep_is_director),
    'required_checks', public.business_required_checks(a.route),
    'parties', coalesce((select jsonb_agg(jsonb_build_object('kind', p.kind, 'full_name', p.full_name, 'nationality', p.nationality,
                  'ownership_pct', p.ownership_pct) order by p.kind, p.full_name) from public.business_application_parties p where p.application_id = a.id), '[]'),
    'branches', coalesce((select jsonb_agg(jsonb_build_object('name', x.name, 'address', x.address, 'phone', x.phone) order by x.name)
                  from public.business_application_branches x where x.application_id = a.id), '[]'),
    'permits', coalesce((select jsonb_agg(jsonb_build_object('permit_type', x.permit_type, 'permit_number', x.permit_number, 'issuer', x.issuer,
                  'expires_on', x.expires_on) order by x.permit_type) from public.business_application_permits x where x.application_id = a.id), '[]'),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'scan', d.scan_status, 'review', d.review_status,
                  'note', d.review_note, 'mime', d.mime_type, 'at', d.created_at) order by d.created_at)
                  from public.verification_documents d where d.subject_type = 'business_application' and d.subject_id = a.id and d.deleted_at is null), '[]'),
    'checks', coalesce((select jsonb_agg(jsonb_build_object('type', k.check_type, 'result', k.result, 'notes', k.notes, 'by', k.checked_by, 'at', k.checked_at) order by k.checked_at)
                  from public.business_application_checks k where k.application_id = a.id), '[]'),
    'interviews', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'channel', i.channel, 'outcome', i.outcome, 'answers', i.answers,
                  'notes', i.notes, 'at', i.conducted_at, 'by', i.conducted_by) order by i.conducted_at)
                  from public.verification_interviews i where i.subject_type = 'business_application' and i.subject_id = a.id), '[]'),
    'history', coalesce((select jsonb_agg(jsonb_build_object('event', e.event, 'from', e.from_status, 'to', e.to_status, 'note', e.note,
                  'by', e.actor_id, 'at', e.created_at) order by e.id)
                  from public.verification_events e where e.subject_type = 'business_application' and e.subject_id = a.id), '[]'));
end;
$$;

create function public.business_application_private_details(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  a public.business_applications;
  pv public.business_application_private;
begin
  perform public.verification_need_support();
  select * into a from public.business_applications where id = p_id and status <> 'draft';
  if not found then
    raise exception 'Application not found.' using errcode = 'no_data_found';
  end if;
  perform public.business_need_not_own(a);
  select * into pv from public.business_application_private where application_id = a.id;
  perform public.write_audit('verification.private_viewed', 'user', a.user_id::text, jsonb_build_object('application_id', a.id, 'subject', 'business'));
  return jsonb_build_object('tpin', pv.tpin, 'rep_id_number', pv.rep_id_number,
    'parties', coalesce((select jsonb_agg(jsonb_build_object('full_name', p.full_name, 'kind', p.kind, 'id_number', p.id_number) order by p.full_name)
                          from public.business_application_parties p where p.application_id = a.id), '[]'));
end;
$$;

-- What the officer found out for themselves. Needed before approval (see business_required_checks).
create function public.business_application_record_check(p_id uuid, p_check text, p_result text, p_notes text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  a public.business_applications;
  new_id uuid;
begin
  perform public.verification_need_support();
  select * into a from public.business_applications where id = p_id and status = 'under_review' for update;
  if not found then
    raise exception 'That application is not under review.' using errcode = 'no_data_found';
  end if;
  perform public.business_need_not_own(a);
  if a.assigned_to is distinct from (select auth.uid()) then
    raise exception 'Claim the application first.' using errcode = 'check_violation';
  end if;
  if p_check not in ('registry_lookup', 'tpin_check', 'phone_call', 'video_call', 'address_check', 'authority_confirmed', 'permit_check', 'other')
     or p_result not in ('passed', 'failed', 'inconclusive') then
    raise exception 'Choose a check and a result.' using errcode = 'check_violation';
  end if;
  if p_notes is null or char_length(btrim(p_notes)) < 5 then
    raise exception 'Write what you found.' using errcode = 'check_violation';
  end if;
  insert into public.business_application_checks (application_id, check_type, result, notes, checked_by)
  values (a.id, p_check, p_result, left(btrim(p_notes), 1000), (select auth.uid())) returning id into new_id;
  perform public.verification_log('business_application', a.id, a.user_id, 'check_recorded', null, null, p_check || ': ' || p_result, false);
  return new_id;
end;
$$;

-- Documents: the review and open functions now cover both kinds of application.
create or replace function public.verification_review_document(p_document uuid, p_accept boolean, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  d public.verification_documents;
  sa public.seller_applications;
  ba public.business_applications;
  assignee uuid;
  applicant uuid;
  note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  perform public.verification_need_support();
  select * into d from public.verification_documents where id = p_document and deleted_at is null for update;
  if not found then
    raise exception 'Document not found.' using errcode = 'no_data_found';
  end if;
  if d.subject_type = 'seller_application' then
    select * into sa from public.seller_applications where id = d.subject_id;
    perform public.seller_need_not_own(sa);
    assignee := sa.assigned_to; applicant := sa.user_id;
  else
    select * into ba from public.business_applications where id = d.subject_id;
    perform public.business_need_not_own(ba);
    assignee := ba.assigned_to; applicant := ba.user_id;
  end if;
  if assignee is distinct from (select auth.uid()) then
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
  perform public.verification_log(d.subject_type, d.subject_id, applicant, case when p_accept then 'document_accepted' else 'document_rejected' end,
                                  null, null, d.kind || coalesce(': ' || note, ''), not p_accept);
end;
$$;

create or replace function public.verification_open_document(p_document uuid)
returns table (bucket text, path text, seconds integer)
language plpgsql security definer set search_path = ''
as $$
declare
  d public.verification_documents;
  sa public.seller_applications;
  ba public.business_applications;
begin
  perform public.verification_need_support();
  select * into d from public.verification_documents where id = p_document;
  if not found or d.deleted_at is not null then
    raise exception 'Document not found.' using errcode = 'no_data_found';
  end if;
  if d.subject_type = 'seller_application' then
    select * into sa from public.seller_applications where id = d.subject_id;
    perform public.seller_need_not_own(sa);
  else
    select * into ba from public.business_applications where id = d.subject_id;
    perform public.business_need_not_own(ba);
  end if;
  if d.scan_status <> 'clean' then
    raise exception 'This file has not passed the safety scan, so it cannot be opened.' using errcode = 'check_violation';
  end if;
  perform public.write_audit('document.viewed', 'user', d.owner_id::text,
    jsonb_build_object('document_id', d.id, 'kind', d.kind, 'subject_type', d.subject_type, 'subject_id', d.subject_id));
  return query select d.storage_bucket, d.storage_path, least(public.setting_numeric('verification.document_url_seconds', 60)::integer, 300);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Publishing gate for business listings
-- ---------------------------------------------------------------------------
-- Drafts can always be prepared (including by bulk import). Going live needs a verified business. Replaces the 0023 trigger
-- function (same name) so one trigger covers both kinds of listing.
create or replace function public.listings_seller_gate()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is null or public.has_staff_role('moderator') then
    return new;
  end if;
  if new.business_id is not null then
    if public.business_can_publish(new.business_id) then
      return new;
    end if;
    if new.status = 'active' and (tg_op = 'INSERT' or old.status = 'draft') then
      raise exception 'Your business must be verified before listings can go live.' using errcode = 'insufficient_privilege';
    end if;
    if tg_op = 'UPDATE' and new.status = 'active' and old.status = 'unavailable' then
      if public.is_business_member(new.business_id) then
        raise exception 'Your business cannot publish right now, so this listing cannot go live.' using errcode = 'insufficient_privilege';
      end if;
      new.status := old.status;
    end if;
    return new;
  end if;
  if public.seller_can_publish(new.seller_id) then
    return new;
  end if;
  if tg_op = 'INSERT' or (new.status = 'active' and old.status = 'draft') then
    raise exception 'Become an approved seller before you list items.' using errcode = 'insufficient_privilege';
  end if;
  if tg_op = 'UPDATE' and new.status = 'active' and old.status = 'unavailable' then
    if (select auth.uid()) = new.seller_id then
      raise exception 'Your selling is switched off, so this listing cannot go live.' using errcode = 'insufficient_privilege';
    end if;
    new.status := old.status;
  end if;
  return new;
end;
$$;

-- Ownership and verification-sensitive details of a business that has a verification record can be changed by an owner only.
create function public.businesses_sensitive_guard()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is null or old.publish_state = 'none' then
    return new;
  end if;
  if not public.is_business_member(old.id, array['owner']::public.business_member_role[]) then
    raise exception 'Only the owner can change the name or address of a verified business.' using errcode = 'insufficient_privilege';
  end if;
  perform public.write_audit('business.sensitive_change', 'business', old.id::text, jsonb_build_object('fields', 'name,address,location'));
  return new;
end;
$$;
create trigger businesses_sensitive before update of name, address_text, location_id on public.businesses
  for each row execute function public.businesses_sensitive_guard();

-- The public storefront view says whether a business is registered or an informal trader. "verified" now means
-- "approved to publish".
create or replace view public.public_businesses as
select
  b.id,
  b.name,
  b.slug,
  b.description,
  b.logo_path,
  loc.town,
  loc.area,
  b.address_text,
  (b.publish_state = 'active') as verified,
  b.created_at,
  (select count(*) from public.listings l
    where l.business_id = b.id and l.status = 'active' and l.moderation_status = 'approved')::integer as listing_count,
  case when b.publish_state = 'active' then b.registration_kind end as registration_kind
from public.businesses b
join public.profiles p on p.id = b.owner_id
left join public.locations loc on loc.id = b.location_id
where p.account_state <> 'suspended';

-- Businesses already verified under the earlier check keep publishing (recorded as a one-off carry-over).
with legacy as (
  update public.businesses set publish_state = 'active', registration_kind = 'registered'
   where verification_status = 'verified' and publish_state = 'none' returning id, owner_id
)
insert into public.verification_events (subject_type, subject_id, applicant_id, event, to_status, note, visible_to_applicant)
select 'business_application', l.id, l.owner_id, 'carried_over', 'approved', 'Verified before business applications existed.', false from legacy l;


-- ---------------------------------------------------------------------------
-- 6b. Deleting a business (0025) must also put its application documents on the retention clock
-- ---------------------------------------------------------------------------
create or replace function public.business_close(p_business uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  b public.businesses;
  keep integer := public.setting_numeric('retention.verification_rejected_days', 30)::integer;
  open_orders integer;
  removed integer;
  why text := left(nullif(btrim(coalesce(p_reason, '')), ''), 300);
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;

  select * into b from public.businesses where id = p_business for update;
  if not found then
    raise exception 'That business was not found.' using errcode = 'no_data_found';
  end if;
  if b.owner_id <> uid and not public.is_business_member(p_business, array['owner']::public.business_member_role[]) then
    raise exception 'Only the owner can delete a business.' using errcode = 'insufficient_privilege';
  end if;

  select count(*) into open_orders from public.orders
   where business_id = p_business and status in ('requested', 'confirmed', 'disputed');
  if open_orders > 0 then
    raise exception 'Finish or cancel the % open order(s) first, then delete the business.', open_orders using errcode = 'check_violation';
  end if;

  update public.listings
     set branch_id = null, status = 'removed', moderation_note = 'Removed when the business was deleted.'
   where business_id = p_business and (status <> 'removed' or branch_id is not null);
  get diagnostics removed = row_count;

  -- Documents of the earlier check AND of business applications. Without the second part, files of a deleted business
  -- would never be scheduled for deletion, because the application row goes away with the business.
  update public.verification_documents
     set purge_after = least(coalesce(purge_after, now() + make_interval(days => keep)), now() + make_interval(days => keep))
   where subject_type = 'business_application' and deleted_at is null
     and (subject_id = p_business
          or subject_id in (select v.id from public.business_verifications v where v.business_id = p_business)
          or subject_id in (select x.id from public.business_applications x where x.business_id = p_business));
  perform public.verification_log('business_application', p_business, uid, 'business_deleted', b.verification_status::text, null, why, true);
  perform public.write_audit('business.deleted', 'business', p_business::text,
    jsonb_build_object('name', b.name, 'slug', b.slug, 'was', b.verification_status, 'publish_state', b.publish_state, 'reason', why, 'listings_removed', removed));

  delete from public.businesses where id = p_business;
end;
$$;
revoke execute on function public.business_close(uuid, text) from public, anon, authenticated;
grant execute on function public.business_close(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Permissions: closed first, then opened on purpose
-- ---------------------------------------------------------------------------
revoke execute on function
  public.business_can_publish(uuid), public.business_need_not_own(public.business_applications), public.business_notify(uuid, uuid, text, text),
  public.business_required_kinds(text, boolean), public.business_required_checks(text), public.business_need_owner(uuid),
  public.business_application_save(uuid, jsonb), public.business_application_editable(uuid),
  public.business_application_set_parties(uuid, jsonb), public.business_application_set_branches(uuid, jsonb),
  public.business_application_set_permits(uuid, jsonb), public.business_application_submit(uuid), public.business_application_withdraw(uuid),
  public.business_application_respond(uuid, text), public.business_application_mine(uuid),
  public.business_application_claim(uuid), public.business_application_assign(uuid, uuid),
  public.business_application_request_info(uuid, text, text[]), public.business_application_record_interview(uuid, text, text, jsonb, text),
  public.business_application_escalate(uuid, text), public.business_application_decide(uuid, text, text),
  public.business_application_suspend(uuid, text, boolean), public.business_application_reinstate(uuid, text),
  public.business_verification_queue(text, integer, integer), public.business_application_detail(uuid),
  public.business_application_private_details(uuid), public.business_application_record_check(uuid, text, text, text),
  public.businesses_sensitive_guard(), public.business_check_int(text, integer, integer, text), public.business_check_date(text, text, boolean),
  public.business_check_bool(text, text), public.business_check_pattern(text, text, text, text)
from public, anon, authenticated;

grant execute on function
  public.business_can_publish(uuid), public.business_application_save(uuid, jsonb),
  public.business_application_set_parties(uuid, jsonb), public.business_application_set_branches(uuid, jsonb),
  public.business_application_set_permits(uuid, jsonb), public.business_application_submit(uuid), public.business_application_withdraw(uuid),
  public.business_application_respond(uuid, text), public.business_application_mine(uuid),
  public.business_application_claim(uuid), public.business_application_assign(uuid, uuid),
  public.business_application_request_info(uuid, text, text[]), public.business_application_record_interview(uuid, text, text, jsonb, text),
  public.business_application_escalate(uuid, text), public.business_application_decide(uuid, text, text),
  public.business_application_suspend(uuid, text, boolean), public.business_application_reinstate(uuid, text),
  public.business_verification_queue(text, integer, integer), public.business_application_detail(uuid),
  public.business_application_private_details(uuid), public.business_application_record_check(uuid, text, text, text)
to authenticated;
