-- Province-wide browsing.
--
-- The home screen shows every listing in the buyer's province (Lusaka to start with), not just one town. People can then
-- narrow it to one area ("search for items near you"). search_listings only knows one location or one town, so this adds
-- the same search with a province filter. The older function is left alone, so older app versions keep working.
--
-- Same rules as search_listings: open to guests, returns only the public columns, wildcard characters in the search
-- word are treated as plain text.

create function public.search_listings_in_province(
  p_province text,
  p_term text default null,
  p_category_id integer default null,
  p_location_id integer default null,
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
    from public.public_listings pl
    join public.locations loc on loc.id = pl.location_id, q
   where loc.province = p_province
     and (q.term is null
          or pl.title ilike '%' || replace(replace(replace(q.term, '\', '\\'), '%', '\%'), '_', '\_') || '%'
          or exists (select 1 from public.listings l
                      where l.id = pl.id
                        and l.description ilike '%' || replace(replace(replace(q.term, '\', '\\'), '%', '\%'), '_', '\_') || '%'))
     and (p_category_id is null or pl.category_id = p_category_id)
     and (p_location_id is null or pl.location_id = p_location_id)
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

revoke execute on function
  public.search_listings_in_province(text, text, integer, integer, public.item_condition[], numeric, numeric, boolean, text, integer, integer, uuid)
  from public, anon, authenticated;

grant execute on function
  public.search_listings_in_province(text, text, integer, integer, public.item_condition[], numeric, numeric, boolean, text, integer, integer, uuid)
  to anon, authenticated;
