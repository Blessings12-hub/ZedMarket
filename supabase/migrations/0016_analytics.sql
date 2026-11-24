-- Module I: analytics.
--
-- Everything here is read-only. Sellers and businesses see their own numbers; staff see platform,
-- trust and financial numbers according to their role. Results are counts and totals only: no
-- buyer names, no message text, no phone numbers.
--
-- Honest limits (also in docs/DIRECTIVE_PROGRESS.md):
--   * Delivery performance is NOT here. Real delivery figures need the delivery module (Module D).
--   * Page views are kept for 90 days by the retention job, so view-based numbers never look back
--     further than that, even when a longer period is asked for.
--   * Payment figures only cover payments recorded through the app. Most sales are paid outside it
--     today, so "paid in app" is not the same as sales.
--   * These are live queries over the raw tables, with indexes. They are fine at the size of an early
--     marketplace. A nightly summary table will be needed before the volume is large.
--   * Times and days are in Zambia time (Africa/Lusaka).

-- ---------------------------------------------------------------------------
-- Indexes for the date ranges below
-- ---------------------------------------------------------------------------

create index if not exists orders_completed_at_idx on public.orders (completed_at) where status = 'completed';
create index if not exists orders_created_at_idx on public.orders (created_at);
create index if not exists conversations_listing_created_idx on public.conversations (listing_id, created_at);
create index if not exists favourites_listing_created_idx on public.favourites (listing_id, created_at);
create index if not exists profiles_created_at_idx on public.profiles (created_at);
create index if not exists reports_created_at_idx on public.reports (created_at);
create index if not exists disputes_created_at_idx on public.disputes (created_at);
create index if not exists payments_settled_at_idx on public.payments (settled_at) where status = 'succeeded';
create index if not exists refunds_processed_at_idx on public.refunds (processed_at) where status = 'processed';

-- ---------------------------------------------------------------------------
-- Helpers (not callable from the app)
-- ---------------------------------------------------------------------------

create function public.analytics_days(p_days integer)
returns integer
language sql immutable set search_path = ''
as $$ select least(greatest(coalesce(p_days, 30), 1), 365); $$;

-- A business, or (when p_business is null) the signed-in person's own listings.
create function public.analytics_owner_check(p_business uuid)
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in to see your numbers.' using errcode = 'insufficient_privilege';
  end if;
  if p_business is not null and not public.business_can(p_business, 'view_analytics') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
end;
$$;

create function public.analytics_listings(p_business uuid)
returns setof public.listings
language sql stable security definer set search_path = ''
as $$
  select l.* from public.listings l
   where (p_business is not null and l.business_id = p_business)
      or (p_business is null and l.seller_id = (select auth.uid()) and l.business_id is null);
$$;

create function public.analytics_orders(p_business uuid)
returns setof public.orders
language sql stable security definer set search_path = ''
as $$
  select o.* from public.orders o
   where (p_business is not null and o.business_id = p_business)
      or (p_business is null and o.seller_id = (select auth.uid()) and o.business_id is null);
$$;

-- Staff access by kind of report.
create function public.analytics_staff_check(p_kind text)
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if p_kind = 'platform' and (public.has_staff_role('tech_admin') or public.has_staff_role('finance')) then return; end if;
  if p_kind = 'trust' and (public.has_staff_role('tech_admin') or public.has_staff_role('moderator') or public.has_staff_role('support')) then return; end if;
  if p_kind = 'finance' and (public.has_staff_role('tech_admin') or public.has_staff_role('finance')) then return; end if;
  raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
end;
$$;

create function public.analytics_pct(p_part numeric, p_whole numeric)
returns numeric
language sql immutable set search_path = ''
as $$ select case when coalesce(p_whole, 0) = 0 then null else round(100 * p_part / p_whole, 1) end; $$;

-- Conversion rates are capped at 100. People can chat or order without a recorded view (views are
-- counted once per hour and kept for 90 days), so a raw ratio could otherwise exceed 100.
create function public.analytics_rate(p_part numeric, p_whole numeric)
returns numeric
language sql immutable set search_path = ''
as $$ select case when coalesce(p_whole, 0) = 0 then null else round(least(100, 100 * p_part / p_whole), 1) end; $$;

-- ---------------------------------------------------------------------------
-- Seller and business dashboard
-- ---------------------------------------------------------------------------

create function public.seller_analytics(p_business uuid default null, p_days integer default 30)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  days integer := public.analytics_days(p_days);
  since timestamptz := now() - make_interval(days => public.analytics_days(p_days));
  -- page views are only kept for 90 days
  views_days integer := least(public.analytics_days(p_days), 90);
  vsince timestamptz := now() - make_interval(days => least(public.analytics_days(p_days), 90));
  today date := (now() at time zone 'Africa/Lusaka')::date;
  views_n bigint;
  uniq_n bigint;
  chats_n bigint;
  requested_n bigint;
  completed_n bigint;
  result jsonb;
begin
  perform public.analytics_owner_check(p_business);

  select count(*), count(distinct v.viewer_id) into views_n, uniq_n
    from public.listing_views v where v.listing_id in (select a.id from public.analytics_listings(p_business) a) and v.viewed_at >= vsince;
  select count(*) into chats_n
    from public.conversations c where c.listing_id in (select a.id from public.analytics_listings(p_business) a) and c.created_at >= vsince;
  select count(*) into requested_n from public.analytics_orders(p_business) o where o.created_at >= vsince;
  select count(*) into completed_n from public.analytics_orders(p_business) o where o.status = 'completed' and o.completed_at >= since;

  select jsonb_build_object(
    'period_days', days,
    'views_period_days', views_days,
    'timezone', 'Africa/Lusaka',
    'active_listings', (select count(*) from public.analytics_listings(p_business) l where l.status = 'active'),
    'funnel', jsonb_build_object(
      'views', views_n, 'unique_viewers', uniq_n, 'chats_started', chats_n, 'orders_requested', requested_n,
      'chat_rate_pct', public.analytics_rate(chats_n, uniq_n), 'order_rate_pct', public.analytics_rate(requested_n, uniq_n)),
    'saves_in_period', (select count(*) from public.favourites f where f.listing_id in (select a.id from public.analytics_listings(p_business) a) and f.created_at >= since),
    'sales', jsonb_build_object(
      'completed_orders', completed_n,
      'completed_value_zmw', (select coalesce(sum(o.item_price_zmw), 0) from public.analytics_orders(p_business) o where o.status = 'completed' and o.completed_at >= since),
      'average_order_zmw', (select round(avg(o.item_price_zmw), 2) from public.analytics_orders(p_business) o where o.status = 'completed' and o.completed_at >= since),
      'by_fulfilment', (select coalesce(jsonb_object_agg(x.f, x.n), '{}'::jsonb) from
                          (select o.fulfilment::text f, count(*) n from public.analytics_orders(p_business) o
                            where o.status = 'completed' and o.completed_at >= since group by o.fulfilment) x)),
    'order_handling', jsonb_build_object(
      'requested', requested_n,
      'cancelled', (select count(*) from public.analytics_orders(p_business) o where o.created_at >= since and o.status = 'cancelled' and o.cancel_kind = 'cancelled'),
      'declined', (select count(*) from public.analytics_orders(p_business) o where o.created_at >= since and o.cancel_kind = 'declined'),
      'expired', (select count(*) from public.analytics_orders(p_business) o where o.created_at >= since and o.cancel_kind = 'expired'),
      'disputed', (select count(*) from public.analytics_orders(p_business) o where o.created_at >= since and o.status = 'disputed'),
      'avg_hours_to_confirm', (select round(avg(extract(epoch from (o.confirmed_at - o.created_at)) / 3600)::numeric, 1)
                                 from public.analytics_orders(p_business) o where o.created_at >= since and o.confirmed_at is not null),
      'avg_hours_to_complete', (select round(avg(extract(epoch from (o.completed_at - o.confirmed_at)) / 3600)::numeric, 1)
                                  from public.analytics_orders(p_business) o where o.completed_at >= since and o.confirmed_at is not null),
      'not_completed_pct', public.analytics_pct(
        (select count(*) from public.analytics_orders(p_business) o where o.created_at >= since and o.cancel_kind is not null),
        requested_n)),
    'reviews', jsonb_build_object(
      'count', (select count(*) from public.reviews r join public.analytics_orders(p_business) o on o.id = r.order_id
                 where r.reviewee_id = o.seller_id and not r.is_hidden and r.created_at >= since),
      'average', (select round(avg(r.rating)::numeric, 2) from public.reviews r join public.analytics_orders(p_business) o on o.id = r.order_id
                   where r.reviewee_id = o.seller_id and not r.is_hidden and r.created_at >= since)),
    'top_listings', (
      select coalesce(jsonb_agg(to_jsonb(t) order by t.completed desc, t.views desc, t.title), '[]'::jsonb)
        from (select l.id, l.title,
                     (select count(*) from public.listing_views v where v.listing_id = l.id and v.viewed_at >= vsince) as views,
                     (select count(*) from public.favourites f where f.listing_id = l.id) as saves,
                     (select count(*) from public.orders o where o.listing_id = l.id and o.status = 'completed' and o.completed_at >= since) as completed
                from public.analytics_listings(p_business) l where l.status <> 'removed'
               order by 5 desc, 3 desc, l.title limit 5) t),
    'daily', (
      select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'views', coalesce(v.n, 0), 'orders', coalesce(r.n, 0),
                                                     'completed_value_zmw', coalesce(c.val, 0)) order by d.day), '[]'::jsonb)
        from (select g::date as day from generate_series(today - (views_days - 1), today, interval '1 day') g) d
        left join (select (vw.viewed_at at time zone 'Africa/Lusaka')::date as day, count(*) n
                     from public.listing_views vw where vw.listing_id in (select a.id from public.analytics_listings(p_business) a) and vw.viewed_at >= vsince
                    group by 1) v on v.day = d.day
        left join (select (o.created_at at time zone 'Africa/Lusaka')::date as day, count(*) n
                     from public.analytics_orders(p_business) o where o.created_at >= vsince group by 1) r on r.day = d.day
        left join (select (o.completed_at at time zone 'Africa/Lusaka')::date as day, sum(o.item_price_zmw) val
                     from public.analytics_orders(p_business) o where o.status = 'completed' and o.completed_at >= vsince group by 1) c on c.day = d.day)
  ) into result;
  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- One listing
-- ---------------------------------------------------------------------------

create function public.listing_performance(p_listing uuid, p_days integer default 30)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  l public.listings;
  days integer := public.analytics_days(p_days);
  since timestamptz := now() - make_interval(days => public.analytics_days(p_days));
  views_days integer := least(public.analytics_days(p_days), 90);
  vsince timestamptz := now() - make_interval(days => least(public.analytics_days(p_days), 90));
  today date := (now() at time zone 'Africa/Lusaka')::date;
  views_n bigint;
  uniq_n bigint;
  chats_n bigint;
  requested_n bigint;
begin
  select * into l from public.listings where id = p_listing;
  if not found
     or (select auth.uid()) is null
     or not (l.seller_id = (select auth.uid()) or (l.business_id is not null and public.business_can(l.business_id, 'view_analytics'))) then
    raise exception 'Listing not found.' using errcode = 'no_data_found';
  end if;

  select count(*), count(distinct viewer_id) into views_n, uniq_n from public.listing_views where listing_id = l.id and viewed_at >= vsince;
  select count(*) into chats_n from public.conversations where listing_id = l.id and created_at >= vsince;
  select count(*) into requested_n from public.orders where listing_id = l.id and created_at >= vsince;

  return jsonb_build_object(
    'listing_id', l.id, 'title', l.title, 'status', l.status, 'price_zmw', l.price_zmw,
    'period_days', days, 'views_period_days', views_days,
    'days_listed', greatest((now()::date - l.created_at::date), 0),
    'views', views_n, 'unique_viewers', uniq_n,
    'saves_total', (select count(*) from public.favourites where listing_id = l.id),
    'saves_in_period', (select count(*) from public.favourites where listing_id = l.id and created_at >= since),
    'chats_started', chats_n, 'orders_requested', requested_n,
    'orders_completed', (select count(*) from public.orders where listing_id = l.id and status = 'completed' and completed_at >= since),
    'completed_value_zmw', (select coalesce(sum(item_price_zmw), 0) from public.orders where listing_id = l.id and status = 'completed' and completed_at >= since),
    'chat_rate_pct', public.analytics_rate(chats_n, uniq_n),
    'order_rate_pct', public.analytics_rate(requested_n, uniq_n),
    'stock', (select jsonb_build_object('quantity', s.quantity, 'low_stock_at', s.low_stock_at) from public.listing_stock s where s.listing_id = l.id),
    'daily_views', (
      select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'views', coalesce(v.n, 0)) order by d.day), '[]'::jsonb)
        from (select g::date as day from generate_series(today - (views_days - 1), today, interval '1 day') g) d
        left join (select (vw.viewed_at at time zone 'Africa/Lusaka')::date as day, count(*) n
                     from public.listing_views vw where vw.listing_id = l.id and vw.viewed_at >= vsince group by 1) v on v.day = d.day));
end;
$$;

-- ---------------------------------------------------------------------------
-- Sales reporting
-- ---------------------------------------------------------------------------

create function public.sales_report(p_business uuid, p_from date, p_to date, p_group text default 'day')
returns table (period date, orders_completed integer, items_zmw numeric, delivery_fees_zmw numeric, total_zmw numeric)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.analytics_owner_check(p_business);
  if p_group not in ('day', 'week', 'month') then
    raise exception 'Group by day, week or month.' using errcode = 'check_violation';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'Choose a start date that is not after the end date.' using errcode = 'check_violation';
  end if;
  if p_to - p_from > 366 then
    raise exception 'Choose a period of at most one year.' using errcode = 'check_violation';
  end if;
  return query
    select date_trunc(p_group, o.completed_at at time zone 'Africa/Lusaka')::date,
           count(*)::integer, sum(o.item_price_zmw), sum(o.delivery_fee_zmw), sum(o.total_zmw)
      from public.analytics_orders(p_business) o
     where o.status = 'completed'
       and (o.completed_at at time zone 'Africa/Lusaka')::date between p_from and p_to
     group by 1 order by 1;
end;
$$;

create function public.sales_by_listing(p_business uuid, p_from date, p_to date)
returns table (listing_id uuid, title text, orders_completed integer, items_zmw numeric)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.analytics_owner_check(p_business);
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 366 then
    raise exception 'Choose a period of at most one year.' using errcode = 'check_violation';
  end if;
  return query
    select o.listing_id, max(o.item_title), count(*)::integer, sum(o.item_price_zmw)
      from public.analytics_orders(p_business) o
     where o.status = 'completed' and (o.completed_at at time zone 'Africa/Lusaka')::date between p_from and p_to
     group by o.listing_id order by 4 desc, 3 desc limit 100;
end;
$$;

-- ---------------------------------------------------------------------------
-- Customer engagement
-- ---------------------------------------------------------------------------

create function public.engagement_stats(p_business uuid default null, p_days integer default 30)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  days integer := public.analytics_days(p_days);
  since timestamptz := now() - make_interval(days => public.analytics_days(p_days));
  result jsonb;
begin
  perform public.analytics_owner_check(p_business);
  with conv as (
    select c.id, c.buyer_id, c.created_at,
           (select min(m.created_at) from public.messages m where m.conversation_id = c.id and m.sender_id = c.buyer_id) as first_buyer_at,
           (select min(m.created_at) from public.messages m where m.conversation_id = c.id and m.sender_id <> c.buyer_id) as first_reply_at
      from public.conversations c
     where c.listing_id in (select a.id from public.analytics_listings(p_business) a) and c.created_at >= since
  ), buyers as (
    select o.buyer_id, count(*) filter (where o.status = 'completed') as completed_all,
           min(o.completed_at) filter (where o.status = 'completed') as first_completed
      from public.analytics_orders(p_business) o group by o.buyer_id
  )
  select jsonb_build_object(
    'period_days', days,
    'conversations_started', (select count(*) from conv),
    'conversations_answered', (select count(*) from conv where first_reply_at is not null),
    'reply_rate_pct', public.analytics_pct((select count(*) from conv where first_reply_at is not null), (select count(*) from conv)),
    'avg_first_reply_minutes', (select round(avg(extract(epoch from (first_reply_at - first_buyer_at)) / 60)::numeric, 1)
                                  from conv where first_reply_at is not null and first_buyer_at is not null and first_reply_at >= first_buyer_at),
    'unanswered_over_24h', (select count(*) from conv where first_reply_at is null and first_buyer_at is not null and first_buyer_at < now() - interval '24 hours'),
    'repeat_customers', (select count(*) from buyers where completed_all >= 2),
    'new_customers', (select count(*) from buyers where first_completed >= since),
    'customers_all_time', (select count(*) from buyers where completed_all >= 1)
  ) into result;
  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- Platform statistics (tech admin, finance)
-- ---------------------------------------------------------------------------

create function public.platform_stats(p_days integer default 30)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  days integer := public.analytics_days(p_days);
  since timestamptz := now() - make_interval(days => public.analytics_days(p_days));
  today date := (now() at time zone 'Africa/Lusaka')::date;
  series_days integer := least(public.analytics_days(p_days), 90);
  result jsonb;
begin
  perform public.analytics_staff_check('platform');
  select jsonb_build_object(
    'period_days', days, 'timezone', 'Africa/Lusaka',
    'users', jsonb_build_object(
      'total', (select count(*) from public.profiles),
      'new', (select count(*) from public.profiles where created_at >= since),
      'by_verification', (select coalesce(jsonb_object_agg(x.v, x.n), '{}'::jsonb) from (select verification_level::text v, count(*) n from public.profiles group by 1) x),
      'by_state', (select coalesce(jsonb_object_agg(x.s, x.n), '{}'::jsonb) from (select account_state::text s, count(*) n from public.profiles group by 1) x)),
    'businesses', jsonb_build_object('total', (select count(*) from public.businesses), 'new', (select count(*) from public.businesses where created_at >= since)),
    'listings', jsonb_build_object(
      'active', (select count(*) from public.listings where status = 'active' and moderation_status = 'approved'),
      'new', (select count(*) from public.listings where created_at >= since),
      'by_category', (select coalesce(jsonb_agg(to_jsonb(x) order by x.n desc, x.category), '[]'::jsonb)
                        from (select c.name as category, count(*) n from public.listings l join public.categories c on c.id = l.category_id
                               where l.status = 'active' and l.moderation_status = 'approved' group by c.name order by 2 desc limit 10) x)),
    'orders', jsonb_build_object(
      'created', (select count(*) from public.orders where created_at >= since),
      'completed', (select count(*) from public.orders where status = 'completed' and completed_at >= since),
      'agreed_value_completed_zmw', (select coalesce(sum(total_zmw), 0) from public.orders where status = 'completed' and completed_at >= since),
      'by_status', (select coalesce(jsonb_object_agg(x.s, x.n), '{}'::jsonb) from (select status::text s, count(*) n from public.orders where created_at >= since group by 1) x),
      'by_fulfilment_completed', (select coalesce(jsonb_object_agg(x.f, x.n), '{}'::jsonb) from (select fulfilment::text f, count(*) n from public.orders where status = 'completed' and completed_at >= since group by 1) x),
      'not_completed_pct', public.analytics_pct((select count(*) from public.orders where created_at >= since and cancel_kind is not null),
                                                (select count(*) from public.orders where created_at >= since))),
    'conversations_started', (select count(*) from public.conversations where created_at >= since),
    'reviews', jsonb_build_object('count', (select count(*) from public.reviews where created_at >= since and not is_hidden),
                                  'average', (select round(avg(rating)::numeric, 2) from public.reviews where created_at >= since and not is_hidden)),
    'daily', (
      select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'new_users', coalesce(u.n, 0), 'orders', coalesce(o.n, 0), 'listings', coalesce(l.n, 0)) order by d.day), '[]'::jsonb)
        from (select g::date as day from generate_series(today - (series_days - 1), today, interval '1 day') g) d
        left join (select (created_at at time zone 'Africa/Lusaka')::date as day, count(*) n from public.profiles where created_at >= now() - make_interval(days => series_days) group by 1) u on u.day = d.day
        left join (select (created_at at time zone 'Africa/Lusaka')::date as day, count(*) n from public.orders where created_at >= now() - make_interval(days => series_days) group by 1) o on o.day = d.day
        left join (select (created_at at time zone 'Africa/Lusaka')::date as day, count(*) n from public.listings where created_at >= now() - make_interval(days => series_days) group by 1) l on l.day = d.day)
  ) into result;
  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- Fraud and dispute statistics (moderators, support, tech admin)
-- ---------------------------------------------------------------------------

create function public.trust_stats(p_days integer default 30)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  days integer := public.analytics_days(p_days);
  since timestamptz := now() - make_interval(days => public.analytics_days(p_days));
  result jsonb;
begin
  perform public.analytics_staff_check('trust');
  select jsonb_build_object(
    'period_days', days,
    'reports', jsonb_build_object(
      'opened', (select count(*) from public.reports where created_at >= since),
      'open_now', (select count(*) from public.reports where status in ('open', 'in_review')),
      'oldest_open_hours', (select round(extract(epoch from (now() - min(created_at))) / 3600) from public.reports where status in ('open', 'in_review')),
      'by_reason', (select coalesce(jsonb_object_agg(x.r, x.n), '{}'::jsonb) from (select reason::text r, count(*) n from public.reports where created_at >= since group by 1) x),
      'by_target', (select coalesce(jsonb_object_agg(x.t, x.n), '{}'::jsonb) from (select target_type::text t, count(*) n from public.reports where created_at >= since group by 1) x),
      'actioned', (select count(*) from public.reports where status = 'actioned' and reviewed_at >= since),
      'dismissed', (select count(*) from public.reports where status = 'dismissed' and reviewed_at >= since),
      'avg_hours_to_decide', (select round(avg(extract(epoch from (reviewed_at - created_at)) / 3600)::numeric, 1)
                                from public.reports where reviewed_at >= since and status in ('actioned', 'dismissed'))),
    'disputes', jsonb_build_object(
      'opened', (select count(*) from public.disputes where created_at >= since),
      'open_now', (select count(*) from public.disputes where status in ('open', 'awaiting_info')),
      'resolved', (select count(*) from public.disputes where status = 'resolved' and resolved_at >= since),
      'rejected', (select count(*) from public.disputes where status = 'rejected' and resolved_at >= since),
      'avg_hours_to_resolve', (select round(avg(extract(epoch from (resolved_at - created_at)) / 3600)::numeric, 1)
                                 from public.disputes where resolved_at >= since),
      'dispute_rate_pct', public.analytics_pct(
        (select count(*) from public.disputes where created_at >= since),
        (select count(*) from public.orders where created_at >= since))),
    'appeals', jsonb_build_object(
      'opened', (select count(*) from public.appeals where created_at >= since),
      'open_now', (select count(*) from public.appeals where status = 'open'),
      'upheld', (select count(*) from public.appeals where status = 'upheld' and reviewed_at >= since),
      'overturned', (select count(*) from public.appeals where status = 'overturned' and reviewed_at >= since),
      'overturn_rate_pct', public.analytics_pct(
        (select count(*) from public.appeals where status = 'overturned' and reviewed_at >= since),
        (select count(*) from public.appeals where status in ('upheld', 'overturned') and reviewed_at >= since))),
    'risk_flags', jsonb_build_object(
      'open_now', (select count(*) from public.risk_flags where status = 'open'),
      'raised', (select count(*) from public.risk_flags where created_at >= since),
      'by_signal', (select coalesce(jsonb_object_agg(x.s, x.n), '{}'::jsonb) from (select signal s, count(*) n from public.risk_flags where created_at >= since group by 1) x)),
    'accounts', jsonb_build_object(
      'restricted_now', (select count(*) from public.profiles where account_state = 'restricted'),
      'suspended_now', (select count(*) from public.profiles where account_state = 'suspended')),
    'listings', jsonb_build_object(
      'rejected_now', (select count(*) from public.listings where moderation_status = 'rejected' and status <> 'removed'),
      'waiting_for_review', (select count(*) from public.listings where moderation_status = 'pending' and status = 'active')),
    'verification', jsonb_build_object(
      'identity_waiting', (select count(*) from public.identity_verifications where status = 'pending'),
      'business_waiting', (select count(*) from public.business_verifications where status = 'pending'))
  ) into result;
  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- Financial reporting (finance, tech admin). Reading it is written to the audit log.
-- ---------------------------------------------------------------------------

create function public.financial_report(p_from date, p_to date, p_group text default 'day')
returns table (period date, payments_succeeded integer, paid_zmw numeric, refunds_processed integer, refunded_zmw numeric,
               net_zmw numeric, payments_failed integer)
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.analytics_staff_check('finance');
  if p_group not in ('day', 'week', 'month') then
    raise exception 'Group by day, week or month.' using errcode = 'check_violation';
  end if;
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 366 then
    raise exception 'Choose a period of at most one year.' using errcode = 'check_violation';
  end if;
  perform public.write_audit('analytics.financial_report', 'report', 'financial_report',
    jsonb_build_object('from', p_from, 'to', p_to, 'group', p_group));
  return query
    with paid as (
      select date_trunc(p_group, p.settled_at at time zone 'Africa/Lusaka')::date as per, count(*) as n, sum(p.amount_zmw) as amt
        from public.payments p
       where p.status = 'succeeded' and (p.settled_at at time zone 'Africa/Lusaka')::date between p_from and p_to group by 1
    ), failed as (
      select date_trunc(p_group, p.settled_at at time zone 'Africa/Lusaka')::date as per, count(*) as n
        from public.payments p
       where p.status = 'failed' and (p.settled_at at time zone 'Africa/Lusaka')::date between p_from and p_to group by 1
    ), refunded as (
      select date_trunc(p_group, r.processed_at at time zone 'Africa/Lusaka')::date as per, count(*) as n, sum(r.amount_zmw) as amt
        from public.refunds r
       where r.status = 'processed' and (r.processed_at at time zone 'Africa/Lusaka')::date between p_from and p_to group by 1
    ), periods as (
      select per from paid union select per from refunded union select per from failed
    )
    select pd.per, coalesce(paid.n, 0)::integer, coalesce(paid.amt, 0), coalesce(refunded.n, 0)::integer, coalesce(refunded.amt, 0),
           coalesce(paid.amt, 0) - coalesce(refunded.amt, 0), coalesce(failed.n, 0)::integer
      from periods pd left join paid on paid.per = pd.per left join refunded on refunded.per = pd.per left join failed on failed.per = pd.per
     order by pd.per;
end;
$$;

create function public.financial_totals(p_from date, p_to date)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  paid numeric;
  agreed numeric;
  result jsonb;
begin
  perform public.analytics_staff_check('finance');
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 366 then
    raise exception 'Choose a period of at most one year.' using errcode = 'check_violation';
  end if;
  perform public.write_audit('analytics.financial_totals', 'report', 'financial_totals', jsonb_build_object('from', p_from, 'to', p_to));
  select coalesce(sum(amount_zmw), 0) into paid from public.payments
   where status = 'succeeded' and (settled_at at time zone 'Africa/Lusaka')::date between p_from and p_to;
  select coalesce(sum(total_zmw), 0) into agreed from public.orders
   where status = 'completed' and (completed_at at time zone 'Africa/Lusaka')::date between p_from and p_to;
  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'paid_in_app_zmw', paid,
    'refunded_zmw', (select coalesce(sum(amount_zmw), 0) from public.refunds where status = 'processed' and (processed_at at time zone 'Africa/Lusaka')::date between p_from and p_to),
    'agreed_value_completed_orders_zmw', agreed,
    'paid_in_app_share_pct', public.analytics_pct(paid, agreed),
    'by_method', (select coalesce(jsonb_object_agg(x.m, x.amt), '{}'::jsonb)
                    from (select method m, sum(amount_zmw) amt from public.payments
                           where status = 'succeeded' and (settled_at at time zone 'Africa/Lusaka')::date between p_from and p_to group by 1) x),
    'by_status', (select coalesce(jsonb_object_agg(x.s, jsonb_build_object('count', x.n, 'amount_zmw', x.amt)), '{}'::jsonb)
                    from (select status s, count(*) n, sum(amount_zmw) amt from public.payments
                           where (created_at at time zone 'Africa/Lusaka')::date between p_from and p_to group by 1) x),
    'needs_review_now', (select jsonb_build_object('count', count(*), 'amount_zmw', coalesce(sum(amount_zmw), 0)) from public.payments where needs_review),
    'waiting_over_1h_now', (select jsonb_build_object('count', count(*), 'amount_zmw', coalesce(sum(amount_zmw), 0)) from public.payments
                              where status = 'pending' and created_at < now() - interval '1 hour'),
    'refunds_waiting_now', (select jsonb_build_object('count', count(*), 'amount_zmw', coalesce(sum(amount_zmw), 0)) from public.refunds where status in ('requested', 'approved')),
    'note', 'Only payments made through the app are counted. Payments made outside the app are not visible here.'
  ) into result;
  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- Function permissions: closed first, then opened on purpose
-- ---------------------------------------------------------------------------

revoke execute on function
  public.analytics_days(integer),
  public.analytics_owner_check(uuid),
  public.analytics_listings(uuid),
  public.analytics_orders(uuid),
  public.analytics_staff_check(text),
  public.analytics_pct(numeric, numeric),
  public.analytics_rate(numeric, numeric),
  public.seller_analytics(uuid, integer),
  public.listing_performance(uuid, integer),
  public.sales_report(uuid, date, date, text),
  public.sales_by_listing(uuid, date, date),
  public.engagement_stats(uuid, integer),
  public.platform_stats(integer),
  public.trust_stats(integer),
  public.financial_report(date, date, text),
  public.financial_totals(date, date)
from public, anon, authenticated;

grant execute on function
  public.seller_analytics(uuid, integer),
  public.listing_performance(uuid, integer),
  public.sales_report(uuid, date, date, text),
  public.sales_by_listing(uuid, date, date),
  public.engagement_stats(uuid, integer),
  public.platform_stats(integer),
  public.trust_stats(integer),
  public.financial_report(date, date, text),
  public.financial_totals(date, date)
to authenticated;
