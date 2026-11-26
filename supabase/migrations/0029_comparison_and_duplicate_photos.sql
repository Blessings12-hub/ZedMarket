-- Product comparison and duplicate-photo detection (chunk D).
--
-- Duplicate photos: the photo's fingerprint is read by the DATABASE from the stored file (its ETag in storage.objects),
-- never trusted from the app, so it cannot be blank or forged. A photo that matches another SELLER's photo is flagged
-- for a moderator. Nothing is blocked or removed automatically: stock photos and honest re-listings exist.
-- Limit: only byte-identical files match. A cropped or re-compressed copy is not caught; that needs an image-hashing
-- worker, which is not built.
-- Comparison: a read-only function over the public listing view, so only listings anyone can already see are returned.

create table public.listing_image_flags (
  id uuid primary key default gen_random_uuid(),
  image_id uuid not null references public.listing_images (id) on delete cascade,
  listing_id uuid not null references public.listings (id) on delete cascade,
  other_listing_id uuid not null references public.listings (id) on delete cascade,
  content_hash text not null,
  status text not null default 'open' check (status in ('open', 'dismissed', 'confirmed')),
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  note text check (note is null or char_length(note) <= 500),
  created_at timestamptz not null default now(),
  unique (image_id, other_listing_id)
);
create index listing_image_flags_open_idx on public.listing_image_flags (created_at) where status = 'open';
alter table public.listing_image_flags enable row level security;
revoke all on public.listing_image_flags from public, anon, authenticated;

-- BEFORE insert: whatever the app sent, the fingerprint comes from the stored file (or stays empty if it is not found).
create function public.listing_images_fingerprint()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  select nullif(btrim(coalesce(o.metadata ->> 'eTag', o.metadata ->> 'etag'), '"'), '') into new.content_hash
    from storage.objects o
   where o.bucket_id = 'listing-images' and o.name = new.storage_path
   limit 1;
  if not found then
    new.content_hash := null;
  end if;
  return new;
end;
$$;
create trigger listing_images_fingerprint before insert on public.listing_images
  for each row execute function public.listing_images_fingerprint();

-- AFTER insert: flag matches on another seller's listing (at most five per photo). Never fails the upload.
create function public.listing_images_flag_duplicates()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.content_hash is null then
    return new;
  end if;
  begin
    insert into public.listing_image_flags (image_id, listing_id, other_listing_id, content_hash)
    select new.id, new.listing_id, i.listing_id, new.content_hash
      from public.listing_images i
      join public.listings other on other.id = i.listing_id
      join public.listings mine on mine.id = new.listing_id
     where i.content_hash = new.content_hash and i.id <> new.id and i.listing_id <> new.listing_id
       and other.seller_id <> mine.seller_id
     limit 5
    on conflict do nothing;
  exception when others then
    raise warning 'duplicate photo check failed: %', sqlerrm;
  end;
  return new;
end;
$$;
create trigger listing_images_flag_duplicates after insert on public.listing_images
  for each row execute function public.listing_images_flag_duplicates();

-- Seller view: counts only. A seller never learns who else uses a photo.
create function public.listing_duplicate_photos(p_listing uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  l public.listings;
begin
  select * into l from public.listings where id = p_listing;
  if not found or not (l.seller_id = auth.uid() or public.is_business_member(l.business_id)) then
    raise exception 'Listing not found.' using errcode = 'no_data_found';
  end if;
  return jsonb_build_object(
    'own_other_listings', (select count(distinct i2.listing_id) from public.listing_images i
                             join public.listing_images i2 on i2.content_hash = i.content_hash and i2.listing_id <> i.listing_id
                             join public.listings l2 on l2.id = i2.listing_id and l2.seller_id = l.seller_id
                            where i.listing_id = p_listing and i.content_hash is not null),
    'other_sellers', (select count(distinct f.other_listing_id) from public.listing_image_flags f where f.listing_id = p_listing and f.status <> 'dismissed'));
end;
$$;

-- Staff queue.
create function public.image_flag_queue(p_status text default 'open', p_limit integer default 50, p_offset integer default 0)
returns table (id uuid, status text, listing_id uuid, listing_title text, seller_name text, other_listing_id uuid, other_title text,
               other_seller_name text, created_at timestamptz, note text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public.has_staff_role('moderator') or public.has_staff_role('support')) then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if p_status not in ('open', 'dismissed', 'confirmed') then
    raise exception 'Unknown status.' using errcode = 'check_violation';
  end if;
  return query
    select f.id, f.status, f.listing_id, a.title, pa.display_name, f.other_listing_id, b.title, pb.display_name, f.created_at, f.note
      from public.listing_image_flags f
      join public.listings a on a.id = f.listing_id join public.profiles pa on pa.id = a.seller_id
      join public.listings b on b.id = f.other_listing_id join public.profiles pb on pb.id = b.seller_id
     where f.status = p_status
     order by f.created_at desc
     limit least(greatest(coalesce(p_limit, 50), 1), 100) offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

create function public.image_flag_resolve(p_id uuid, p_decision text, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  f public.listing_image_flags;
  me uuid := auth.uid();
begin
  if not (public.has_staff_role('moderator') or public.has_staff_role('support')) then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if p_decision not in ('dismiss', 'confirm') then
    raise exception 'Choose dismiss or confirm.' using errcode = 'check_violation';
  end if;
  if p_note is not null and char_length(p_note) > 500 then
    raise exception 'Keep the note under 500 characters.' using errcode = 'check_violation';
  end if;
  select * into f from public.listing_image_flags where id = p_id for update;
  if not found or f.status <> 'open' then
    raise exception 'That flag is not open.' using errcode = 'no_data_found';
  end if;
  if exists (select 1 from public.listings where id in (f.listing_id, f.other_listing_id) and seller_id = me) then
    raise exception 'You cannot review a flag about your own listing.' using errcode = 'insufficient_privilege';
  end if;
  update public.listing_image_flags
     set status = case p_decision when 'confirm' then 'confirmed' else 'dismissed' end, reviewed_by = me, reviewed_at = now(), note = nullif(btrim(p_note), '')
   where id = p_id;
  perform public.write_audit('image_flag.' || p_decision, 'listing', f.listing_id::text, jsonb_build_object('flag_id', f.id, 'other_listing_id', f.other_listing_id));
end;
$$;

-- Comparison of 2 to 4 listings that anyone can see. Listings that are gone or hidden come back in "missing".
create function public.compare_listings(p_ids uuid[])
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  ids uuid[] := (select coalesce(array_agg(distinct x), '{}') from unnest(coalesce(p_ids, '{}')) x);
  items jsonb;
begin
  if array_length(ids, 1) is null or array_length(ids, 1) < 2 then
    raise exception 'Pick at least 2 listings to compare.' using errcode = 'check_violation';
  end if;
  if array_length(ids, 1) > 4 then
    raise exception 'You can compare up to 4 listings at a time.' using errcode = 'check_violation';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', d.id, 'title', d.title, 'price', d.price_zmw, 'condition', d.condition, 'warranty', d.warranty_info, 'return_policy', d.return_policy,
      'category_id', d.category_id, 'category', d.category_name, 'town', d.town, 'area', d.area, 'seller_name', d.seller_name,
      'seller_level', d.seller_level, 'rating', nullif(s.average_rating, 0), 'reviews', s.review_count, 'completed_orders', s.completed_orders,
      'image', d.image_paths[1], 'posted_at', d.created_at) order by array_position(ids, d.id)), '[]')
    into items
    from public.public_listing_details d
    left join public.seller_stats s on s.seller_id = d.seller_id
   where d.id = any (ids);
  return jsonb_build_object(
    'items', items,
    'missing', (select coalesce(jsonb_agg(x), '[]') from unnest(ids) x where not exists (select 1 from jsonb_array_elements(items) e where (e ->> 'id')::uuid = x)),
    'same_category', (select count(distinct e ->> 'category_id') <= 1 from jsonb_array_elements(items) e));
end;
$$;

revoke all on function public.listing_images_fingerprint(), public.listing_images_flag_duplicates() from public, anon, authenticated;
revoke all on function public.listing_duplicate_photos(uuid), public.image_flag_queue(text, integer, integer), public.image_flag_resolve(uuid, text, text), public.compare_listings(uuid[]) from public, anon, authenticated;
grant execute on function public.listing_duplicate_photos(uuid), public.image_flag_queue(text, integer, integer), public.image_flag_resolve(uuid, text, text) to authenticated;
grant execute on function public.compare_listings(uuid[]) to anon, authenticated;
