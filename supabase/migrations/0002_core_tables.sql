-- ZedMarket database, part 2: tables.
-- Names follow the "suggested database entities" table in the blueprint.
-- Row level security is switched on in 0004; do not skip that file.

-- ---------------------------------------------------------------------------
-- Settings and reference data
-- ---------------------------------------------------------------------------

create table public.platform_settings (
  key text primary key,
  value jsonb not null,
  note text,
  updated_at timestamptz not null default now()
);

create table public.locations (
  id integer generated always as identity primary key,
  province text not null,
  town text not null,
  area text,
  unique nulls not distinct (province, town, area)
);

create table public.categories (
  id integer generated always as identity primary key,
  slug text not null unique,
  name text not null,
  parent_id integer references public.categories (id),
  is_active boolean not null default true,
  requires_review boolean not null default false,
  sort_order integer not null default 0
);

-- ---------------------------------------------------------------------------
-- Accounts, verification and businesses
-- ---------------------------------------------------------------------------

-- Public profile only. Email and phone stay in auth.users.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 2 and 60),
  bio text check (char_length(bio) <= 500),
  avatar_path text,
  location_id integer references public.locations (id),
  verification_level public.verification_level not null default 'unverified',
  account_state public.account_state not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.identity_verifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  document_type text not null check (document_type in ('national_id', 'passport', 'drivers_licence')),
  document_path text not null,          -- object in the private identity-documents bucket
  status public.review_status not null default 'pending',
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  reviewer_note text,
  purge_after timestamptz,              -- set when reviewed; a scheduled job deletes the file
  created_at timestamptz not null default now()
);
create unique index identity_one_pending_per_user
  on public.identity_verifications (user_id) where status = 'pending';

create table public.businesses (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references public.profiles (id) on delete restrict,
  name text not null check (char_length(name) between 2 and 80),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,58}[a-z0-9]$'),
  description text check (char_length(description) <= 1000),
  logo_path text,
  location_id integer references public.locations (id),
  address_text text check (char_length(address_text) <= 200),
  verification_status public.business_verification_status not null default 'unverified',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.business_members (
  business_id uuid not null references public.businesses (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role public.business_member_role not null default 'staff',
  created_at timestamptz not null default now(),
  primary key (business_id, user_id)
);

-- Registration details are kept apart from the public business row.
create table public.business_verifications (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  registration_number text not null check (char_length(registration_number) between 3 and 40),
  document_path text,                   -- object in the private business-documents bucket
  status public.review_status not null default 'pending',
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  reviewer_note text,
  created_at timestamptz not null default now()
);
create unique index business_one_pending
  on public.business_verifications (business_id) where status = 'pending';

-- ---------------------------------------------------------------------------
-- Listings
-- ---------------------------------------------------------------------------

create table public.listings (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  business_id uuid references public.businesses (id) on delete set null,
  category_id integer not null references public.categories (id),
  location_id integer not null references public.locations (id),
  title text not null check (char_length(title) between 3 and 120),
  description text not null default '' check (char_length(description) <= 4000),
  price_zmw numeric(12, 2) not null check (price_zmw > 0 and price_zmw < 100000000),
  condition public.item_condition not null,
  warranty_info text check (char_length(warranty_info) <= 500),
  return_policy text check (char_length(return_policy) <= 500),
  status public.listing_status not null default 'draft',
  moderation_status public.moderation_status not null default 'pending',
  moderation_note text,
  sold_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index listings_feed_idx on public.listings (status, moderation_status, created_at desc);
create index listings_category_idx on public.listings (category_id);
create index listings_location_idx on public.listings (location_id);
create index listings_price_idx on public.listings (price_zmw);
create index listings_seller_idx on public.listings (seller_id);
create index listings_title_trgm on public.listings using gin (title extensions.gin_trgm_ops);
create index listings_description_trgm on public.listings using gin (description extensions.gin_trgm_ops);

create table public.listing_images (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings (id) on delete cascade,
  storage_path text not null,
  position smallint not null default 0,
  content_hash text,                    -- sha-256 of the file, used to spot reused photos
  created_at timestamptz not null default now()
);
create index listing_images_listing_idx on public.listing_images (listing_id, position);
create index listing_images_hash_idx on public.listing_images (content_hash) where content_hash is not null;

create table public.favourites (
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  listing_id uuid not null references public.listings (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, listing_id)
);

create table public.prohibited_terms (
  id integer generated always as identity primary key,
  term text not null unique,
  action text not null default 'flag' check (action in ('flag', 'block')),
  is_active boolean not null default true
);

-- ---------------------------------------------------------------------------
-- Messaging and blocking
-- ---------------------------------------------------------------------------

create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings (id) on delete cascade,
  buyer_id uuid not null references public.profiles (id) on delete cascade,
  seller_id uuid not null references public.profiles (id) on delete cascade,
  business_id uuid references public.businesses (id) on delete set null,
  last_message_at timestamptz,
  created_at timestamptz not null default now(),
  unique (listing_id, buyer_id),
  check (buyer_id <> seller_id)
);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  sender_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index messages_conversation_idx on public.messages (conversation_id, created_at);

create table public.blocks (
  blocker_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

-- ---------------------------------------------------------------------------
-- Orders and reviews
-- ---------------------------------------------------------------------------

create sequence public.order_ref_seq start 1000;

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  ref text not null unique default ('ZM-' || lpad(nextval('public.order_ref_seq')::text, 6, '0')),
  listing_id uuid not null references public.listings (id) on delete restrict,
  buyer_id uuid not null references public.profiles (id) on delete restrict,
  seller_id uuid not null references public.profiles (id) on delete restrict,
  business_id uuid references public.businesses (id) on delete set null,
  -- Snapshot of the item as agreed, so later edits to the listing do not change the record.
  item_title text not null,
  item_price_zmw numeric(12, 2) not null check (item_price_zmw > 0),
  fulfilment public.fulfilment_method not null default 'collection',
  delivery_fee_zmw numeric(12, 2) not null default 0 check (delivery_fee_zmw >= 0),
  total_zmw numeric(12, 2) generated always as (item_price_zmw + delivery_fee_zmw) stored,
  status public.order_status not null default 'requested',
  cancelled_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (buyer_id <> seller_id)
);
create index orders_buyer_idx on public.orders (buyer_id, created_at desc);
create index orders_seller_idx on public.orders (seller_id, created_at desc);

create table public.reviews (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  reviewer_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  reviewee_id uuid not null references public.profiles (id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  comment text check (char_length(comment) <= 1000),
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  unique (order_id, reviewer_id)
);

-- ---------------------------------------------------------------------------
-- Delivery (Release 2 tables are created now so row level security covers them from day one)
-- ---------------------------------------------------------------------------

create table public.deliveries (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete restrict,
  seller_id uuid not null references public.profiles (id),
  buyer_id uuid not null references public.profiles (id),
  provider public.delivery_provider not null,
  provider_reference text,              -- booking reference for the manual inDrive workflow
  status public.delivery_status not null default 'requested',
  status_reason text,
  pickup_address text not null,
  destination_address text not null,
  estimated_arrival timestamptz,
  estimated_arrival_source text check (estimated_arrival_source in ('provider', 'routing')),
  tracking_url text,
  pickup_pin_hash text,
  dropoff_pin_hash text,
  pin_attempts smallint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- An ETA is only stored with a source, so the app can label it as an estimate.
  check (estimated_arrival is null or estimated_arrival_source is not null),
  -- A cancelled or failed delivery must say why.
  check (status not in ('cancelled', 'failed') or status_reason is not null)
);
create index deliveries_order_idx on public.deliveries (order_id);

-- Driver details come from the provider, never typed in by a seller.
create table public.delivery_drivers (
  delivery_id uuid primary key references public.deliveries (id) on delete cascade,
  driver_name text not null,
  vehicle_registration text,
  photo_path text,
  source text not null default 'provider' check (source = 'provider'),
  created_at timestamptz not null default now()
);

create table public.delivery_locations (
  id bigint generated always as identity primary key,
  delivery_id uuid not null references public.deliveries (id) on delete cascade,
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  recorded_at timestamptz not null default now()
);
create index delivery_locations_idx on public.delivery_locations (delivery_id, recorded_at desc);

create table public.delivery_events (
  id bigint generated always as identity primary key,
  delivery_id uuid not null references public.deliveries (id) on delete cascade,
  status public.delivery_status not null,
  source text not null check (source in ('provider', 'seller', 'driver', 'system', 'admin')),
  actor_id uuid references public.profiles (id),
  note text,
  created_at timestamptz not null default now()
);
create index delivery_events_idx on public.delivery_events (delivery_id, created_at);

-- ---------------------------------------------------------------------------
-- Payments (Release 3). ZedMarket does not hold funds; these rows only record
-- what an authorised payment provider confirmed.
-- ---------------------------------------------------------------------------

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete restrict,
  provider text not null,
  provider_reference text,
  idempotency_key text not null unique,
  amount_zmw numeric(12, 2) not null check (amount_zmw > 0),
  refunded_zmw numeric(12, 2) not null default 0,
  status public.payment_status not null default 'initiated',
  verified_at timestamptz,
  reconciled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider, provider_reference),
  check (refunded_zmw >= 0 and refunded_zmw <= amount_zmw)
);

create table public.payment_events (
  id bigint generated always as identity primary key,
  payment_id uuid not null references public.payments (id) on delete cascade,
  provider_event_id text not null,
  event_type text not null,
  payload jsonb not null,
  received_at timestamptz not null default now(),
  unique (payment_id, provider_event_id)
);

-- ---------------------------------------------------------------------------
-- Trust and safety
-- ---------------------------------------------------------------------------

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  target_type public.report_target not null,
  target_id uuid not null,
  reason public.report_reason not null,
  details text check (char_length(details) <= 1000),
  status public.report_status not null default 'open',
  decision_note text,
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create index reports_open_idx on public.reports (status, created_at);
create index reports_target_idx on public.reports (target_type, target_id);

create table public.disputes (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete restrict,
  opened_by uuid not null references public.profiles (id),
  reason text not null check (char_length(reason) between 3 and 200),
  details text check (char_length(details) <= 2000),
  status public.dispute_status not null default 'open',
  outcome text,
  resolved_by uuid references public.profiles (id),
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.dispute_evidence (
  id uuid primary key default gen_random_uuid(),
  dispute_id uuid not null references public.disputes (id) on delete cascade,
  uploader_id uuid not null default auth.uid() references public.profiles (id),
  note text check (char_length(note) <= 1000),
  storage_path text,                    -- object in the private dispute-evidence bucket
  created_at timestamptz not null default now(),
  check (note is not null or storage_path is not null)
);

-- A way to challenge a moderation decision.
create table public.appeals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  target_type public.report_target not null,
  target_id uuid not null,
  message text not null check (char_length(message) between 10 and 1500),
  status public.appeal_status not null default 'open',
  reviewer_note text,
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

-- Automated signals only ever raise a flag for a person to look at.
create table public.risk_flags (
  id uuid primary key default gen_random_uuid(),
  subject_type text not null,
  subject_id uuid not null,
  signal text not null,
  detail jsonb not null default '{}',
  status text not null default 'open' check (status in ('open', 'reviewed')),
  created_at timestamptz not null default now()
);
create index risk_flags_open_idx on public.risk_flags (status, created_at);

-- ---------------------------------------------------------------------------
-- Administration
-- ---------------------------------------------------------------------------

create table public.admin_roles (
  user_id uuid not null references public.profiles (id) on delete cascade,
  role public.admin_role not null,
  granted_by uuid references public.profiles (id),
  granted_at timestamptz not null default now(),
  primary key (user_id, role)
);

create table public.admin_approvals (
  id uuid primary key default gen_random_uuid(),
  action text not null,
  target_type text,
  target_id text,
  payload jsonb not null default '{}',
  requested_by uuid not null default auth.uid() references public.profiles (id),
  approved_by uuid references public.profiles (id),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  check (approved_by is null or approved_by <> requested_by)
);

create table public.audit_logs (
  id bigint generated always as identity primary key,
  actor_id uuid,
  action text not null,
  target_type text,
  target_id text,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index audit_logs_actor_idx on public.audit_logs (actor_id, created_at desc);
create index audit_logs_target_idx on public.audit_logs (target_type, target_id);

create table public.rate_limit_log (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  action text not null,
  created_at timestamptz not null default now()
);
create index rate_limit_log_idx on public.rate_limit_log (user_id, action, created_at);
