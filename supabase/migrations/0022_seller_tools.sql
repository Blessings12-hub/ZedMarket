-- Seller tools (Part A, chunk 2: module 3, individual and small-business listing management).
--
-- Works for a person selling on their own and for a business member, through the same functions:
--   * seller_listings          one list with status, moderation state, photos, stock and 30-day performance
--   * listing_timeline         every change of status or moderation state, with who and why (kept for good)
--   (performance for one listing already exists: listing_performance, migration 0016, reused as it is)
--   * duplicate_listing        a new DRAFT copied from a listing (details only, no photos, no stock unless asked)
--   * bulk_update_prices       set, raise or lower the price of many listings at once, all or nothing
--   * bulk_update_stock        set or adjust stock for many tracked listings at once, all or nothing
--   * reorder_listing_images   choose the cover photo and the order (up to 10 photos already allowed)
--
-- Nothing here weakens moderation:
--   * Copies are drafts and go through the normal listing rules when published.
--   * A price change is an ordinary listing update, so the listing trigger runs again: a price that crosses the
--     high-value rule, or a listing a moderator rejected, goes back to review.
--   * Stock changes go through adjust_stock (migration 0011), so movements, sold-out pausing and restocking behave
--     exactly as before.
-- Closed tables: row level security on, no table grants. Every function checks, on the server, that the caller sells
-- the listing (own listing, or business role with manage_listings / manage_inventory).

insert into public.platform_settings (key, value, note) values
  ('seller.bulk_max_items', '200', 'Most listings one bulk price or stock update can touch. Starter value.'),
  ('rate_limit.bulk_update.max', '30', 'Bulk price or stock updates per person per window. Starter value.'),
  ('rate_limit.bulk_update.window_minutes', '60', null)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 1. Status history
-- ---------------------------------------------------------------------------
create table public.listing_status_events (
  id bigint generated always as identity primary key,
  listing_id uuid not null references public.listings (id) on update cascade on delete cascade,
  status public.listing_status not null,
  moderation_status public.moderation_status not null,
  note text,
  actor_id uuid,
  created_at timestamptz not null default clock_timestamp()
);
create index listing_status_events_listing_idx on public.listing_status_events (listing_id, id);
alter table public.listing_status_events enable row level security;
-- No grants and no policies.

create function public.listing_events_record()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and old.status = new.status and old.moderation_status = new.moderation_status then
    return new;
  end if;
  insert into public.listing_status_events (listing_id, status, moderation_status, note, actor_id)
  values (new.id, new.status, new.moderation_status,
          case when tg_op = 'UPDATE' and old.moderation_status is distinct from new.moderation_status then new.moderation_note end,
          (select auth.uid()));
  return new;
end;
$$;

create trigger listings_status_history after insert or update of status, moderation_status on public.listings
  for each row execute function public.listing_events_record();

-- Listings that already exist get one starting row.
insert into public.listing_status_events (listing_id, status, moderation_status, note, created_at)
select l.id, l.status, l.moderation_status, null, l.created_at from public.listings l;

-- Events cannot be changed or removed by anyone. Only the foreign key may follow its listing (delete or new id).
create function public.listing_events_immutable()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if pg_trigger_depth() > 1 then
    return coalesce(new, old); -- the database following the listing (it was deleted or got a new id)
  end if;
  raise exception 'The status history cannot be changed.' using errcode = 'insufficient_privilege';
end;
$$;
create trigger listing_events_no_edit before update or delete on public.listing_status_events
  for each row execute function public.listing_events_immutable();

-- ---------------------------------------------------------------------------
-- 2. Who may manage a listing (internal)
-- ---------------------------------------------------------------------------
create function public.seller_can_manage(p_listing public.listings, p_permission text default 'manage_listings')
returns boolean
language sql stable security definer set search_path = ''
as $$
  select (select auth.uid()) is not null and case
    when p_listing.business_id is null then p_listing.seller_id = (select auth.uid())
    else public.business_can(p_listing.business_id, p_permission)
  end
$$;

create function public.seller_need_account()
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.account_can_post() then
    raise exception 'Your account cannot change listings right now.' using errcode = 'insufficient_privilege';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Reading
-- ---------------------------------------------------------------------------
-- p_business null = the caller's own personal listings. p_status: all, draft, live, review, rejected, paused, sold.
create function public.seller_listings(
  p_business uuid default null, p_status text default 'all', p_search text default null,
  p_limit integer default 50, p_offset integer default 0
)
returns table (
  listing_id uuid, title text, price_zmw numeric, status public.listing_status, moderation_status public.moderation_status,
  moderation_note text, photos bigint, tracked boolean, quantity integer, sku text, views_30d bigint, saves bigint,
  orders_total bigint, created_at timestamptz, updated_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  uid uuid := (select auth.uid());
  term text := nullif(btrim(coalesce(p_search, '')), '');
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;
  if p_status not in ('all', 'draft', 'live', 'review', 'rejected', 'paused', 'sold') then
    raise exception 'Unknown status filter.' using errcode = 'invalid_parameter_value';
  end if;
  if p_business is not null and not public.business_can(p_business, 'manage_listings') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;

  return query
    select l.id, l.title, l.price_zmw, l.status, l.moderation_status, l.moderation_note,
           (select count(*) from public.listing_images i where i.listing_id = l.id),
           (s.listing_id is not null), s.quantity, s.sku,
           (select count(*) from public.listing_views v where v.listing_id = l.id and v.viewed_at > now() - interval '30 days'),
           (select count(*) from public.favourites f where f.listing_id = l.id),
           (select count(*) from public.orders o where o.listing_id = l.id),
           l.created_at, l.updated_at
      from public.listings l
      left join public.listing_stock s on s.listing_id = l.id
     where case when p_business is null then l.business_id is null and l.seller_id = uid else l.business_id = p_business end
       and case p_status
             when 'all' then true
             when 'draft' then l.status = 'draft'
             when 'live' then l.status = 'active' and l.moderation_status = 'approved'
             when 'review' then l.status = 'active' and l.moderation_status = 'pending'
             when 'rejected' then l.moderation_status = 'rejected' and l.status <> 'removed'
             when 'paused' then l.status = 'unavailable'
             else l.status = 'sold' end
       and (term is null or l.title ilike '%' || term || '%' or s.sku ilike '%' || term || '%')
       and l.status <> 'removed'
     order by l.updated_at desc, l.id
     limit least(greatest(coalesce(p_limit, 50), 1), 100) offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

create function public.listing_timeline(p_listing uuid)
returns table (status public.listing_status, moderation_status public.moderation_status, note text, by_staff boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  l public.listings;
begin
  select * into l from public.listings where id = p_listing;
  if not found or not public.seller_can_manage(l) then
    raise exception 'Listing not found.' using errcode = 'no_data_found';
  end if;
  return query
    select e.status, e.moderation_status, e.note,
           (e.actor_id is not null and e.actor_id is distinct from l.seller_id and exists (select 1 from public.admin_roles r where r.user_id = e.actor_id)),
           e.created_at
      from public.listing_status_events e where e.listing_id = p_listing order by e.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Duplicate
-- ---------------------------------------------------------------------------
create function public.duplicate_listing(p_listing uuid, p_title text default null, p_sku text default null, p_quantity integer default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  l public.listings;
  new_id uuid;
  new_title text;
begin
  perform public.seller_need_account();
  select * into l from public.listings where id = p_listing;
  if not found or not public.seller_can_manage(l) then
    raise exception 'Listing not found.' using errcode = 'no_data_found';
  end if;
  if l.status = 'removed' then
    raise exception 'A removed listing cannot be copied.' using errcode = 'check_violation';
  end if;
  if (p_sku is null) <> (p_quantity is null) then
    raise exception 'Give both a SKU and a quantity, or neither.' using errcode = 'check_violation';
  end if;
  if p_sku is not null and l.business_id is null then
    raise exception 'Stock tracking is for businesses.' using errcode = 'check_violation';
  end if;
  new_title := coalesce(nullif(btrim(p_title), ''), left('Copy of ' || l.title, 120));

  insert into public.listings (seller_id, business_id, branch_id, category_id, location_id, title, description, price_zmw,
                               condition, warranty_info, return_policy, status)
  values (uid, l.business_id, l.branch_id, l.category_id, l.location_id, new_title, l.description, l.price_zmw,
          l.condition, l.warranty_info, l.return_policy, 'draft')
  returning id into new_id;

  if p_sku is not null then
    if char_length(btrim(p_sku)) not between 1 and 40 or p_quantity < 0 or p_quantity > 100000 then
      raise exception 'Enter a SKU of up to 40 characters and a quantity from 0 to 100000.' using errcode = 'check_violation';
    end if;
    if not public.business_can(l.business_id, 'manage_inventory') then
      raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
    end if;
    insert into public.listing_stock (listing_id, business_id, quantity, sku, updated_by)
    values (new_id, l.business_id, p_quantity, btrim(p_sku), uid);
    if p_quantity > 0 then
      insert into public.stock_movements (listing_id, business_id, change, quantity_after, reason, actor_id)
      values (new_id, l.business_id, p_quantity, p_quantity, 'initial', uid);
    end if;
  end if;

  perform public.write_audit('listing.duplicated', 'listing', new_id::text, jsonb_build_object('from', p_listing));
  return new_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Bulk price and stock
-- ---------------------------------------------------------------------------
create function public.bulk_update_prices(p_listings uuid[], p_mode text, p_value numeric)
returns table (listing_id uuid, old_price numeric, new_price numeric)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  cap integer := public.setting_numeric('seller.bulk_max_items', 200)::integer;
  ids uuid[];
  l public.listings;
  np numeric;
  lid uuid;
  report jsonb := '[]';
begin
  perform public.seller_need_account();
  if p_mode not in ('set', 'percent', 'amount') then
    raise exception 'Choose set, percent or amount.' using errcode = 'invalid_parameter_value';
  end if;
  if p_value is null then
    raise exception 'Enter a value.' using errcode = 'check_violation';
  end if;
  select coalesce(array_agg(distinct x order by x), '{}') into ids from unnest(p_listings) as x where x is not null;
  if coalesce(array_length(ids, 1), 0) = 0 then
    raise exception 'Choose at least one listing.' using errcode = 'check_violation';
  end if;
  if array_length(ids, 1) > cap then
    raise exception 'You can change up to % listings at once.', cap using errcode = 'check_violation';
  end if;
  perform public.enforce_rate_limit('bulk_update', 30, 60);

  -- Lock in id order so two bulk updates over the same listings cannot deadlock.
  foreach lid in array ids loop
    select * into l from public.listings x where x.id = lid for update;
    if not found or not public.seller_can_manage(l) then
      raise exception 'One of the listings was not found.' using errcode = 'no_data_found';
    end if;
    if l.status in ('removed', 'sold') then
      raise exception '"%" is closed, so its price cannot change.', l.title using errcode = 'check_violation';
    end if;
    np := round(case p_mode when 'set' then p_value when 'percent' then l.price_zmw * (1 + p_value / 100) else l.price_zmw + p_value end, 2);
    if np is null or np <= 0 or np >= 100000000 then
      raise exception 'The new price for "%" would be outside the allowed range.', l.title using errcode = 'check_violation';
    end if;
    if np <> l.price_zmw then
      update public.listings set price_zmw = np where listings.id = l.id;
    end if;
    report := report || jsonb_build_array(jsonb_build_object('id', l.id, 'old', l.price_zmw, 'new', np));
    listing_id := l.id; old_price := l.price_zmw; new_price := np;
    return next;
  end loop;
  perform public.write_audit('listing.bulk_price', 'listing', null,
    jsonb_build_object('mode', p_mode, 'value', p_value, 'count', array_length(ids, 1), 'changes', report));
end;
$$;

-- p_items: [{"listing_id": "...", "mode": "set" | "adjust", "value": 5}, ...]
create function public.bulk_update_stock(p_items jsonb)
returns table (listing_id uuid, quantity_before integer, quantity_after integer)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  cap integer := public.setting_numeric('seller.bulk_max_items', 200)::integer;
  item record;
  cur integer;
  target numeric;
  chg integer;
  report jsonb := '[]';
  n integer;
begin
  perform public.seller_need_account();
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Choose at least one listing.' using errcode = 'check_violation';
  end if;
  n := jsonb_array_length(p_items);
  if n > cap then
    raise exception 'You can change up to % listings at once.', cap using errcode = 'check_violation';
  end if;
  perform public.enforce_rate_limit('bulk_update', 30, 60);

  for item in
    select (e ->> 'listing_id')::uuid as lid, e ->> 'mode' as mode, e ->> 'value' as val
      from jsonb_array_elements(p_items) e order by (e ->> 'listing_id')::uuid
  loop
    if item.mode not in ('set', 'adjust') then
      raise exception 'Choose set or adjust.' using errcode = 'invalid_parameter_value';
    end if;
    begin
      target := item.val::numeric;
    exception when others then
      target := null;
    end;
    if target is null or target <> trunc(target) then
      raise exception 'Stock must be a whole number.' using errcode = 'check_violation';
    end if;
    perform 1 from public.listings x where x.id = item.lid for update;
    cur := null;
    select s.quantity into cur from public.listing_stock s where s.listing_id = item.lid for update;
    if cur is null then
      raise exception 'Stock is not tracked for one of the listings.' using errcode = 'no_data_found';
    end if;
    chg := case item.mode when 'set' then target::integer - cur else target::integer end;
    if chg <> 0 then
      perform public.adjust_stock(item.lid, chg, case when chg > 0 then 'restock' else 'correction' end, 'Bulk update');
    end if;
    report := report || jsonb_build_array(jsonb_build_object('id', item.lid, 'before', cur, 'after', cur + chg));
    listing_id := item.lid; quantity_before := cur; quantity_after := cur + chg;
    return next;
  end loop;
  perform public.write_audit('listing.bulk_stock', 'listing', null, jsonb_build_object('count', n, 'changes', report));
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Photos: order and cover
-- ---------------------------------------------------------------------------
create function public.reorder_listing_images(p_listing uuid, p_ids uuid[])
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  l public.listings;
  have uuid[];
begin
  select * into l from public.listings where id = p_listing for update;
  if not found or not public.seller_can_manage(l) then
    raise exception 'Listing not found.' using errcode = 'no_data_found';
  end if;
  select coalesce(array_agg(id order by id), '{}') into have from public.listing_images where listing_id = p_listing;
  if p_ids is null or (select coalesce(array_agg(x order by x), '{}') from unnest(p_ids) x) is distinct from have then
    raise exception 'List every photo of this listing exactly once.' using errcode = 'check_violation';
  end if;
  update public.listing_images i set position = o.pos - 1
    from unnest(p_ids) with ordinality as o(id, pos) where i.id = o.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Permissions
-- ---------------------------------------------------------------------------
revoke execute on function
  public.listing_events_record(), public.listing_events_immutable(), public.seller_can_manage(public.listings, text),
  public.seller_need_account(), public.seller_listings(uuid, text, text, integer, integer), public.listing_timeline(uuid),
  public.duplicate_listing(uuid, text, text, integer),
  public.bulk_update_prices(uuid[], text, numeric), public.bulk_update_stock(jsonb), public.reorder_listing_images(uuid, uuid[])
from public, anon, authenticated;

grant execute on function
  public.seller_listings(uuid, text, text, integer, integer), public.listing_timeline(uuid),
  public.duplicate_listing(uuid, text, text, integer),
  public.bulk_update_prices(uuid[], text, numeric), public.bulk_update_stock(jsonb), public.reorder_listing_images(uuid, uuid[])
to authenticated;
