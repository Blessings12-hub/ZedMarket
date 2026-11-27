-- Limits from the chunk E report (migration 0032):
--   * analytics: "completed value", "items" and sales reports now count price x quantity handed over, not one unit per order
--   * the stock count shown to buyers is capped by a setting instead of a fixed 20
-- Payments and delivery are not touched.

-- price x what was handed over (or ordered). Existing orders have quantity 1, so their numbers do not change.
alter table public.orders add column items_zmw numeric(14, 2)
  generated always as (item_price_zmw * coalesce(quantity_delivered, quantity)) stored;

insert into public.platform_settings (key, value, note) values
  ('listing.stock_display_cap', '100', 'Largest stock count shown to buyers, so exact inventory is not published. 0 shows the exact count. Starter value.')
on conflict (key) do nothing;

create or replace function public.listing_stock_info(p_listing uuid)
returns integer
language sql stable security definer set search_path = ''
as $$
  select case when exists (select 1 from public.listing_stock where listing_id = p_listing)
              then case when public.setting_numeric('listing.stock_display_cap', 100) > 0
                        then least(public.listing_available_quantity(p_listing), public.setting_numeric('listing.stock_display_cap', 100)::integer)
                        else public.listing_available_quantity(p_listing) end
         end;
$$;


-- seller_analytics: item_price_zmw -> items_zmw (3 places)
create or replace function public.seller_analytics(p_business uuid default null, p_days integer default 30)
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
      'completed_value_zmw', (select coalesce(sum(o.items_zmw), 0) from public.analytics_orders(p_business) o where o.status = 'completed' and o.completed_at >= since),
      'average_order_zmw', (select round(avg(o.items_zmw), 2) from public.analytics_orders(p_business) o where o.status = 'completed' and o.completed_at >= since),
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
        left join (select (o.completed_at at time zone 'Africa/Lusaka')::date as day, sum(o.items_zmw) val
                     from public.analytics_orders(p_business) o where o.status = 'completed' and o.completed_at >= vsince group by 1) c on c.day = d.day)
  ) into result;
  return result;
end;
$$;


-- listing_performance: item_price_zmw -> items_zmw (1 places)
create or replace function public.listing_performance(p_listing uuid, p_days integer default 30)
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
    'completed_value_zmw', (select coalesce(sum(items_zmw), 0) from public.orders where listing_id = l.id and status = 'completed' and completed_at >= since),
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


-- sales_report: item_price_zmw -> items_zmw (1 places)
create or replace function public.sales_report(p_business uuid, p_from date, p_to date, p_group text default 'day')
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
           count(*)::integer, sum(o.items_zmw), sum(o.delivery_fee_zmw), sum(o.total_zmw)
      from public.analytics_orders(p_business) o
     where o.status = 'completed'
       and (o.completed_at at time zone 'Africa/Lusaka')::date between p_from and p_to
     group by 1 order by 1;
end;
$$;


-- sales_by_listing: item_price_zmw -> items_zmw (1 places)
create or replace function public.sales_by_listing(p_business uuid, p_from date, p_to date)
returns table (listing_id uuid, title text, orders_completed integer, items_zmw numeric)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.analytics_owner_check(p_business);
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 366 then
    raise exception 'Choose a period of at most one year.' using errcode = 'check_violation';
  end if;
  return query
    select o.listing_id, max(o.item_title), count(*)::integer, sum(o.items_zmw)
      from public.analytics_orders(p_business) o
     where o.status = 'completed' and (o.completed_at at time zone 'Africa/Lusaka')::date between p_from and p_to
     group by o.listing_id order by 4 desc, 3 desc limit 100;
end;
$$;
