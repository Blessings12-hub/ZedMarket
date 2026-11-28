-- 0040: promoted listings, arranged by hand.
--
-- A seller asks for their listing to be promoted for 7, 14 or 30 days. Payment is arranged OUTSIDE the app between the seller
-- and the ZedMarket team (no payment provider is connected yet). When the team has been paid they approve the request and
-- type the payment reference, and the listing appears in the "Promoted" row on the home page, clearly labelled as paid.
-- This is separate from "Featured", which is picked by staff and is never paid.
--
-- The price is a STARTING VALUE in platform_settings (promotion.price_zmw_7_days). The owner must set the real price.

insert into public.platform_settings (key, value, note) values
  ('promotion.price_zmw_7_days', '50', 'Price in kwacha for 7 days of promotion; 14 days costs double, 30 days 4 times. PLACEHOLDER: set the real price before launch.'),
  ('promotion.max_open_requests', '3', 'How many promotion requests one person can have waiting at once. Starter value.')
on conflict (key) do nothing;

create table public.promotion_requests (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings (id) on delete cascade,
  requested_by uuid not null references public.profiles (id) on delete cascade,
  days integer not null check (days in (7, 14, 30)),
  price_zmw numeric(12, 2) not null check (price_zmw >= 0),
  status text not null default 'requested' check (status in ('requested', 'approved', 'rejected', 'cancelled')),
  payment_reference text check (payment_reference is null or char_length(payment_reference) between 3 and 120),
  decision_note text check (decision_note is null or char_length(decision_note) <= 300),
  decided_by uuid references public.profiles (id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  check (status <> 'approved' or payment_reference is not null),
  check (status <> 'rejected' or decision_note is not null)
);
create unique index promotion_one_open_per_listing on public.promotion_requests (listing_id) where status = 'requested';
create index promotion_requests_user_idx on public.promotion_requests (requested_by, created_at desc);
create index promotion_requests_listing_idx on public.promotion_requests (listing_id);
create index promotion_requests_decided_by_idx on public.promotion_requests (decided_by);
alter table public.promotion_requests enable row level security;
-- No grants: only the functions below.

create table public.promoted_listings (
  listing_id uuid primary key references public.listings (id) on delete cascade,
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  last_request uuid references public.promotion_requests (id) on delete set null,
  check (ends_at > starts_at)
);
create index promoted_listings_ends_idx on public.promoted_listings (ends_at);
create index promoted_listings_request_idx on public.promoted_listings (last_request);
alter table public.promoted_listings enable row level security;

-- The price list shown in the app.
create function public.promotion_prices() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object('d7', base, 'd14', base * 2, 'd30', base * 4)
    from (select public.setting_numeric('promotion.price_zmw_7_days', 50) as base) b
$$;

-- Promoted listings that are live now and still visible to buyers.
create function public.promoted_listings_now(p_limit integer default 10)
returns setof public.public_listings
language sql stable security definer set search_path = ''
as $$
  select pl.*
    from public.public_listings pl
    join public.promoted_listings p on p.listing_id = pl.id
   where p.starts_at <= now() and p.ends_at > now()
   order by p.starts_at desc, pl.id
   limit least(greatest(coalesce(p_limit, 10), 1), 30);
$$;

create function public.promotion_can_manage(p_listing public.listings) returns boolean
language sql stable security definer set search_path = ''
as $$
  select (select auth.uid()) = p_listing.seller_id
      or (p_listing.business_id is not null and public.business_can(p_listing.business_id, 'manage_listings'))
$$;

create function public.promotion_request(p_listing uuid, p_days integer) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  l public.listings;
  price numeric;
  new_id uuid;
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;
  select * into l from public.listings where id = p_listing;
  if not found or not public.promotion_can_manage(l) then
    raise exception 'That listing was not found.' using errcode = 'no_data_found';
  end if;
  if p_days not in (7, 14, 30) then
    raise exception 'Choose 7, 14 or 30 days.' using errcode = 'check_violation';
  end if;
  if l.status <> 'active' or l.moderation_status <> 'approved' then
    raise exception 'Only an active listing that has been approved can be promoted.' using errcode = 'check_violation';
  end if;
  if (select count(*) from public.promotion_requests r where r.requested_by = uid and r.status = 'requested')
       >= public.setting_numeric('promotion.max_open_requests', 3) then
    raise exception 'You already have the most promotion requests waiting. Wait for a decision first.' using errcode = 'check_violation';
  end if;
  price := (public.promotion_prices() ->> case p_days when 7 then 'd7' when 14 then 'd14' else 'd30' end)::numeric;
  begin
    insert into public.promotion_requests (listing_id, requested_by, days, price_zmw) values (l.id, uid, p_days, price) returning id into new_id;
  exception when unique_violation then
    raise exception 'This listing already has a promotion request waiting.' using errcode = 'check_violation';
  end;
  return new_id;
end;
$$;

create function public.promotion_cancel(p_request uuid) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  update public.promotion_requests set status = 'cancelled'
   where id = p_request and requested_by = (select auth.uid()) and status = 'requested';
  if not found then
    raise exception 'No waiting request with that id.' using errcode = 'no_data_found';
  end if;
end;
$$;

create function public.promotion_my() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id, 'listing_id', r.listing_id, 'title', l.title, 'days', r.days, 'price_zmw', r.price_zmw, 'status', r.status,
    'decision_note', r.decision_note, 'created_at', r.created_at,
    'live_until', (select p.ends_at from public.promoted_listings p where p.listing_id = r.listing_id and p.ends_at > now())
  ) order by r.created_at desc), '[]')
  from (select * from public.promotion_requests where requested_by = (select auth.uid()) order by created_at desc limit 30) r
  join public.listings l on l.id = r.listing_id
$$;

create function public.promotion_staff_can() returns boolean
language sql stable security definer set search_path = ''
as $$ select public.has_staff_role('moderator') or public.has_staff_role('finance') $$;

create function public.promotion_queue() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.promotion_staff_can() then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id, 'listing_id', r.listing_id, 'title', l.title, 'days', r.days, 'price_zmw', r.price_zmw,
    'seller_name', p.display_name, 'created_at', r.created_at
  ) order by r.created_at), '[]')
  from public.promotion_requests r
  join public.listings l on l.id = r.listing_id
  join public.profiles p on p.id = r.requested_by
  where r.status = 'requested');
end;
$$;

create function public.promotion_decide(p_request uuid, p_approve boolean, p_note text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  r public.promotion_requests;
  l public.listings;
  note text := left(nullif(btrim(coalesce(p_note, '')), ''), 300);
  start_from timestamptz;
begin
  if not public.promotion_staff_can() then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  select * into r from public.promotion_requests where id = p_request for update;
  if not found or r.status <> 'requested' then
    raise exception 'No waiting request with that id.' using errcode = 'no_data_found';
  end if;
  if r.requested_by = uid then
    raise exception 'You cannot decide your own request.' using errcode = 'insufficient_privilege';
  end if;

  if p_approve then
    if note is null or char_length(note) < 3 then
      raise exception 'Type the payment reference before approving.' using errcode = 'check_violation';
    end if;
    select * into l from public.listings where id = r.listing_id;
    if l.status <> 'active' or l.moderation_status <> 'approved' then
      raise exception 'The listing is no longer active and approved. Reject this request and refund the seller.' using errcode = 'check_violation';
    end if;
    select greatest(now(), coalesce((select p.ends_at from public.promoted_listings p where p.listing_id = r.listing_id), now())) into start_from;
    insert into public.promoted_listings (listing_id, starts_at, ends_at, last_request)
    values (r.listing_id, now(), start_from + make_interval(days => r.days), r.id)
    on conflict (listing_id) do update set ends_at = excluded.ends_at, last_request = excluded.last_request;
    update public.promotion_requests
       set status = 'approved', payment_reference = note, decided_by = uid, decided_at = now() where id = r.id;
    perform public.notify(r.requested_by, 'listings', 'promotion_approved', 'Your listing is promoted',
      'Your listing is promoted for ' || r.days || ' days.', '/listing/' || r.listing_id, 'promotion_approved:' || r.id);
  else
    if note is null then
      raise exception 'Say why the request is rejected.' using errcode = 'check_violation';
    end if;
    update public.promotion_requests
       set status = 'rejected', decision_note = note, decided_by = uid, decided_at = now() where id = r.id;
    perform public.notify(r.requested_by, 'listings', 'promotion_rejected', 'Promotion request not approved',
      left(note, 200), '/listing/' || r.listing_id, 'promotion_rejected:' || r.id);
  end if;
  perform public.write_audit(case when p_approve then 'promotion.approved' else 'promotion.rejected' end, 'listing', r.listing_id::text,
    jsonb_build_object('request', r.id, 'days', r.days, 'price_zmw', r.price_zmw, 'note', note));
end;
$$;

create function public.promotion_end(p_listing uuid, p_reason text) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('moderator') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A reason is required.' using errcode = 'check_violation';
  end if;
  delete from public.promoted_listings where listing_id = p_listing;
  perform public.write_audit('promotion.ended', 'listing', p_listing::text, jsonb_build_object('reason', left(p_reason, 300)));
end;
$$;

revoke execute on function public.promotion_prices(), public.promoted_listings_now(integer), public.promotion_can_manage(public.listings),
  public.promotion_request(uuid, integer), public.promotion_cancel(uuid), public.promotion_my(), public.promotion_staff_can(),
  public.promotion_queue(), public.promotion_decide(uuid, boolean, text), public.promotion_end(uuid, text) from public, anon, authenticated;
grant execute on function public.promotion_prices(), public.promoted_listings_now(integer) to anon, authenticated;
grant execute on function public.promotion_request(uuid, integer), public.promotion_cancel(uuid), public.promotion_my(),
  public.promotion_queue(), public.promotion_decide(uuid, boolean, text), public.promotion_end(uuid, text) to authenticated;
