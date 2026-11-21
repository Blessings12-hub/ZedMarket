-- 0008: Advanced marketplace (Module A)
--
-- Adds: guest-safe public views, search, featured and trending listings,
-- recently viewed, nearby, similar and recommended listings, saved searches
-- with an alerts inbox.
--
-- Nothing earlier is changed. Guests (the anon role) get read access only
-- through the views and functions below, never through the base tables.
-- The views run with their owner's rights, so each one picks its columns and
-- rows by hand: only active, approved listings from accounts that are not
-- suspended, and no private columns.

-- ---------------------------------------------------------------------------
-- Reference data that guests need to build filters
-- ---------------------------------------------------------------------------

grant select on public.categories to anon;
create policy categories_read_guest on public.categories
  for select to anon using (is_active);

grant select on public.locations to anon;
create policy locations_read_guest on public.locations
  for select to anon using (true);

-- ---------------------------------------------------------------------------
-- Public views
-- ---------------------------------------------------------------------------

create view public.public_listings as
select
  l.id,
  l.title,
  l.price_zmw,
  l.condition,
  l.category_id,
  l.location_id,
  loc.town,
  loc.area,
  l.seller_id,
  p.display_name as seller_name,
  p.verification_level as seller_level,
  l.created_at,
  (select i.storage_path from public.listing_images i
    where i.listing_id = l.id order by i.position, i.created_at limit 1) as image_path
from public.listings l
join public.profiles p on p.id = l.seller_id
join public.locations loc on loc.id = l.location_id
where l.status = 'active'
  and l.moderation_status = 'approved'
  and p.account_state <> 'suspended';

create view public.public_listing_details as
select
  l.id,
  l.title,
  l.description,
  l.price_zmw,
  l.condition,
  l.warranty_info,
  l.return_policy,
  l.category_id,
  c.name as category_name,
  l.location_id,
  loc.town,
  loc.area,
  l.seller_id,
  p.display_name as seller_name,
  p.verification_level as seller_level,
  l.created_at,
  coalesce((select array_agg(i.storage_path order by i.position, i.created_at)
              from public.listing_images i where i.listing_id = l.id), '{}') as image_paths
from public.listings l
join public.profiles p on p.id = l.seller_id
join public.locations loc on loc.id = l.location_id
join public.categories c on c.id = l.category_id
where l.status = 'active'
  and l.moderation_status = 'approved'
  and p.account_state <> 'suspended';

-- A seller's public page: name, level, rating and how many things they have for sale.
create view public.public_seller_profiles as
select
  p.id as seller_id,
  p.display_name,
  p.bio,
  p.avatar_path,
  p.verification_level,
  p.created_at as member_since,
  s.average_rating,
  s.review_count,
  s.completed_orders,
  (select count(*) from public.listings l
    where l.seller_id = p.id and l.status = 'active' and l.moderation_status = 'approved')::integer as active_listings
from public.profiles p
join public.seller_stats s on s.seller_id = p.id
where p.account_state <> 'suspended';

grant select on public.public_listings, public.public_listing_details, public.public_seller_profiles
  to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Views, featured listings, saved searches, alerts
-- ---------------------------------------------------------------------------

-- One row per person per listing per hour at most. Nobody can read other
-- people's rows; the counts below are only used inside trending.
create table public.listing_views (
  id bigint generated always as identity primary key,
  listing_id uuid not null references public.listings (id) on delete cascade,
  viewer_id uuid not null references public.profiles (id) on delete cascade,
  viewed_at timestamptz not null default now()
);
create index listing_views_viewer_idx on public.listing_views (viewer_id, viewed_at desc);
create index listing_views_listing_idx on public.listing_views (listing_id, viewed_at desc);
alter table public.listing_views enable row level security;
-- No grants and no policies: clients only go through the functions.

create table public.featured_listings (
  listing_id uuid primary key references public.listings (id) on delete cascade,
  featured_by uuid references public.profiles (id) on delete set null,
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index featured_listings_ends_idx on public.featured_listings (ends_at);
alter table public.featured_listings enable row level security;

create table public.saved_searches (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  term text check (char_length(term) <= 100),
  category_id integer references public.categories (id),
  location_id integer references public.locations (id),
  min_price numeric(12, 2) check (min_price >= 0),
  max_price numeric(12, 2) check (max_price >= 0),
  conditions public.item_condition[] not null default '{}',
  created_at timestamptz not null default now(),
  check (min_price is null or max_price is null or min_price <= max_price)
);
create index saved_searches_user_idx on public.saved_searches (user_id);
alter table public.saved_searches enable row level security;

grant select, delete on public.saved_searches to authenticated;
grant insert (name, term, category_id, location_id, min_price, max_price, conditions)
  on public.saved_searches to authenticated;
create policy saved_searches_own_read on public.saved_searches
  for select to authenticated using (user_id = (select auth.uid()));
create policy saved_searches_own_add on public.saved_searches
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy saved_searches_own_delete on public.saved_searches
  for delete to authenticated using (user_id = (select auth.uid()));

-- Ten saved searches each keeps the alert matching cheap.
create function public.saved_searches_before_insert()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (select count(*) from public.saved_searches where user_id = new.user_id) >= 10 then
    raise exception 'You can save up to 10 searches. Delete one first.' using errcode = 'check_violation';
  end if;
  if new.term is null and new.category_id is null and new.location_id is null
     and new.min_price is null and new.max_price is null and cardinality(new.conditions) = 0 then
    raise exception 'Pick at least one filter or a search word to save.' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger saved_searches_before_insert before insert on public.saved_searches
  for each row execute function public.saved_searches_before_insert();

-- The alerts inbox. Delivery as push, SMS or email arrives with the notifications module.
create table public.listing_alerts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  saved_search_id uuid not null references public.saved_searches (id) on delete cascade,
  listing_id uuid not null references public.listings (id) on delete cascade,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  unique (saved_search_id, listing_id)
);
create index listing_alerts_user_idx on public.listing_alerts (user_id, created_at desc);
alter table public.listing_alerts enable row level security;

grant select on public.listing_alerts to authenticated;
grant update (read_at) on public.listing_alerts to authenticated;
grant delete on public.listing_alerts to authenticated;
create policy alerts_own_read on public.listing_alerts
  for select to authenticated using (user_id = (select auth.uid()));
create policy alerts_own_update on public.listing_alerts
  for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy alerts_own_delete on public.listing_alerts
  for delete to authenticated using (user_id = (select auth.uid()));

-- When a listing first becomes visible, tell the people whose saved search matches it.
create function public.create_listing_alerts()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.status <> 'active' or new.moderation_status <> 'approved' then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.status = 'active' and old.moderation_status = 'approved' then
    return new;
  end if;

  insert into public.listing_alerts (user_id, saved_search_id, listing_id)
  select s.user_id, s.id, new.id
    from public.saved_searches s
   where s.user_id <> new.seller_id
     and (s.category_id is null or s.category_id = new.category_id)
     and (s.location_id is null or s.location_id = new.location_id)
     and (s.min_price is null or new.price_zmw >= s.min_price)
     and (s.max_price is null or new.price_zmw <= s.max_price)
     and (cardinality(s.conditions) = 0 or new.condition = any (s.conditions))
     and (s.term is null or s.term = ''
          or new.title ilike '%' || replace(replace(replace(s.term, '\', '\\'), '%', '\%'), '_', '\_') || '%'
          or new.description ilike '%' || replace(replace(replace(s.term, '\', '\\'), '%', '\%'), '_', '\_') || '%')
  on conflict (saved_search_id, listing_id) do nothing;
  return new;
end;
$$;
create trigger listings_create_alerts after insert or update of status, moderation_status on public.listings
  for each row execute function public.create_listing_alerts();

-- ---------------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------------

-- Search. Anyone, including guests. Wildcard characters in the search word are
-- treated as plain text. It runs with the owner's rights only so it can look inside
-- descriptions; it returns nothing except the public columns.
create function public.search_listings(
  p_term text default null,
  p_category_id integer default null,
  p_location_id integer default null,
  p_town text default null,
  p_conditions public.item_condition[] default '{}',
  p_min_price numeric default null,
  p_max_price numeric default null,
  p_verified_only boolean default false,
  p_sort text default 'newest',
  p_limit integer default 20,
  p_offset integer default 0,
  p_seller_id uuid default null
)
returns setof public.public_listings
language sql stable security definer set search_path = ''
as $$
  with q as (
    select nullif(btrim(p_term), '') as term
  )
  select pl.*
    from public.public_listings pl, q
   where (q.term is null
          or pl.title ilike '%' || replace(replace(replace(q.term, '\', '\\'), '%', '\%'), '_', '\_') || '%'
          or exists (select 1 from public.listings l
                      where l.id = pl.id
                        and l.description ilike '%' || replace(replace(replace(q.term, '\', '\\'), '%', '\%'), '_', '\_') || '%'))
     and (p_category_id is null or pl.category_id = p_category_id)
     and (p_location_id is null or pl.location_id = p_location_id)
     and (p_town is null or pl.town = p_town)
     and (p_seller_id is null or pl.seller_id = p_seller_id)
     and (cardinality(coalesce(p_conditions, '{}')) = 0 or pl.condition = any (p_conditions))
     and (p_min_price is null or pl.price_zmw >= p_min_price)
     and (p_max_price is null or pl.price_zmw <= p_max_price)
     and (not coalesce(p_verified_only, false) or pl.seller_level <> 'unverified')
   order by
     case when p_sort = 'price_asc' then pl.price_zmw end asc,
     case when p_sort = 'price_desc' then pl.price_zmw end desc,
     pl.created_at desc, pl.id
   limit least(greatest(coalesce(p_limit, 20), 1), 50)
  offset greatest(coalesce(p_offset, 0), 0);
$$;

-- Listings in the same town as a chosen place, same area first. This uses the
-- town and area names already in the database. Distance-based "near me" needs
-- real coordinates and comes with the location module.
create function public.nearby_listings(p_location_id integer, p_limit integer default 20, p_offset integer default 0)
returns setof public.public_listings
language sql stable set search_path = ''
as $$
  select pl.*
    from public.public_listings pl
    join public.locations here on here.id = p_location_id
   where pl.town = here.town
   order by (pl.location_id = p_location_id) desc, pl.created_at desc, pl.id
   limit least(greatest(coalesce(p_limit, 20), 1), 50)
  offset greatest(coalesce(p_offset, 0), 0);
$$;

-- Featured by a moderator, within the dates they set.
create function public.featured_listings_now(p_limit integer default 10)
returns setof public.public_listings
language sql stable security definer set search_path = ''
as $$
  select pl.*
    from public.public_listings pl
    join public.featured_listings f on f.listing_id = pl.id
   where f.starts_at <= now() and f.ends_at > now()
   order by f.starts_at desc, pl.id
   limit least(greatest(coalesce(p_limit, 10), 1), 30);
$$;

create function public.feature_listing(p_listing_id uuid, p_days integer default 7)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('moderator') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if p_days is null or p_days < 1 or p_days > 30 then
    raise exception 'Choose between 1 and 30 days.' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.listings
                  where id = p_listing_id and status = 'active' and moderation_status = 'approved') then
    raise exception 'Only active, approved listings can be featured.' using errcode = 'check_violation';
  end if;

  insert into public.featured_listings (listing_id, featured_by, starts_at, ends_at)
  values (p_listing_id, (select auth.uid()), now(), now() + make_interval(days => p_days))
  on conflict (listing_id) do update
    set featured_by = excluded.featured_by, starts_at = excluded.starts_at, ends_at = excluded.ends_at;

  perform public.write_audit('listing.featured', 'listing', p_listing_id::text, jsonb_build_object('days', p_days));
end;
$$;

create function public.unfeature_listing(p_listing_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('moderator') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  delete from public.featured_listings where listing_id = p_listing_id;
  perform public.write_audit('listing.unfeatured', 'listing', p_listing_id::text);
end;
$$;

-- Trending: how many different signed-in people looked at it, plus three times
-- the number who saved it, over the last few days. Nothing shows as trending
-- with a score of zero.
create function public.trending_listings(p_days integer default 7, p_limit integer default 10)
returns setof public.public_listings
language sql stable security definer set search_path = ''
as $$
  with window_start as (
    select now() - make_interval(days => least(greatest(coalesce(p_days, 7), 1), 30)) as ts
  ), scores as (
    select listing_id, sum(points) as score from (
      select v.listing_id, count(distinct v.viewer_id) as points
        from public.listing_views v, window_start w where v.viewed_at >= w.ts group by v.listing_id
      union all
      select f.listing_id, 3 * count(*) as points
        from public.favourites f, window_start w where f.created_at >= w.ts group by f.listing_id
    ) x group by listing_id
  )
  select pl.*
    from public.public_listings pl
    join scores s on s.listing_id = pl.id
   where s.score > 0
   order by s.score desc, pl.created_at desc, pl.id
   limit least(greatest(coalesce(p_limit, 10), 1), 30);
$$;

create function public.record_listing_view(p_listing_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    return;
  end if;
  if not exists (select 1 from public.listings
                  where id = p_listing_id and status = 'active' and moderation_status = 'approved'
                    and seller_id <> uid) then
    return;
  end if;
  if exists (select 1 from public.listing_views
              where listing_id = p_listing_id and viewer_id = uid and viewed_at > now() - interval '1 hour') then
    return;
  end if;
  insert into public.listing_views (listing_id, viewer_id) values (p_listing_id, uid);
end;
$$;

create function public.recently_viewed(p_limit integer default 20)
returns setof public.public_listings
language sql stable security definer set search_path = ''
as $$
  select pl.*
    from public.public_listings pl
    join (select listing_id, max(viewed_at) as last_seen
            from public.listing_views
           where viewer_id = (select auth.uid())
           group by listing_id) v on v.listing_id = pl.id
   order by v.last_seen desc, pl.id
   limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;

create function public.clear_recently_viewed()
returns void
language sql security definer set search_path = ''
as $$
  delete from public.listing_views where viewer_id = (select auth.uid());
$$;

-- More like this one: same category, similar price, same town first.
create function public.similar_listings(p_listing_id uuid, p_limit integer default 10)
returns setof public.public_listings
language sql stable set search_path = ''
as $$
  select pl.*
    from public.public_listings pl
    join public.public_listings base on base.id = p_listing_id
   where pl.id <> base.id
     and pl.category_id = base.category_id
     and pl.price_zmw between base.price_zmw * 0.5 and base.price_zmw * 2
   order by (pl.town = base.town) desc,
            abs(pl.price_zmw - base.price_zmw) asc,
            pl.created_at desc, pl.id
   limit least(greatest(coalesce(p_limit, 10), 1), 30);
$$;

-- Recommended for you: newest listings in the categories this person has viewed
-- or saved in the last 30 days, leaving out their own listings and ones they
-- have already looked at. The app explains it as "because you looked at <category>".
create function public.recommended_listings(p_limit integer default 10)
returns setof public.public_listings
language sql stable security definer set search_path = ''
as $$
  with me as (select (select auth.uid()) as uid),
  interest as (
    select l.category_id, count(*) as weight
      from public.listing_views v
      join public.listings l on l.id = v.listing_id, me
     where v.viewer_id = me.uid and v.viewed_at > now() - interval '30 days'
     group by l.category_id
    union all
    select l.category_id, 2 * count(*)
      from public.favourites f
      join public.listings l on l.id = f.listing_id, me
     where f.user_id = me.uid and f.created_at > now() - interval '30 days'
     group by l.category_id
  ), ranked as (
    select category_id, sum(weight) as weight from interest group by category_id
  )
  select pl.*
    from public.public_listings pl
    join ranked r on r.category_id = pl.category_id, me
   where pl.seller_id <> me.uid
     and not exists (select 1 from public.listing_views v where v.viewer_id = me.uid and v.listing_id = pl.id)
     and not exists (select 1 from public.favourites f where f.user_id = me.uid and f.listing_id = pl.id)
   order by r.weight desc, pl.created_at desc, pl.id
   limit least(greatest(coalesce(p_limit, 10), 1), 30);
$$;

-- Retention: nobody needs a browsing trail older than 90 days. Run on a schedule
-- by trusted server code (service role); the schedule itself is set up with the
-- other scheduled jobs.
create function public.purge_old_listing_views(p_keep_days integer default 90)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  removed integer;
begin
  delete from public.listing_views where viewed_at < now() - make_interval(days => greatest(p_keep_days, 7));
  get diagnostics removed = row_count;
  return removed;
end;
$$;

-- ---------------------------------------------------------------------------
-- Who can call what
-- ---------------------------------------------------------------------------

-- New functions are executable by everyone unless that is revoked, so start from
-- nothing for every function in this file and then grant only what is meant.
revoke execute on function
  public.saved_searches_before_insert(), public.create_listing_alerts(),
  public.search_listings(text, integer, integer, text, public.item_condition[], numeric, numeric, boolean, text, integer, integer, uuid),
  public.nearby_listings(integer, integer, integer),
  public.featured_listings_now(integer),
  public.trending_listings(integer, integer),
  public.similar_listings(uuid, integer),
  public.record_listing_view(uuid),
  public.recently_viewed(integer),
  public.clear_recently_viewed(),
  public.recommended_listings(integer),
  public.feature_listing(uuid, integer),
  public.unfeature_listing(uuid),
  public.purge_old_listing_views(integer)
  from public, anon, authenticated;

grant execute on function
  public.search_listings(text, integer, integer, text, public.item_condition[], numeric, numeric, boolean, text, integer, integer, uuid),
  public.nearby_listings(integer, integer, integer),
  public.featured_listings_now(integer),
  public.trending_listings(integer, integer),
  public.similar_listings(uuid, integer)
  to anon, authenticated;

grant execute on function
  public.record_listing_view(uuid),
  public.recently_viewed(integer),
  public.clear_recently_viewed(),
  public.recommended_listings(integer),
  public.feature_listing(uuid, integer),
  public.unfeature_listing(uuid)
  to authenticated;

grant execute on function public.purge_old_listing_views(integer) to service_role;
