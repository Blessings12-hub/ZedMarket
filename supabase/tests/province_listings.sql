-- Province-wide search (migration 0030). Rolls itself back. Test data only.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/province_listings.sql
begin;

create function pg_temp.check_equal(p_actual text, p_expected text, p_what text) returns void
language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'Wrong result for %: expected %, got %', p_what, coalesce(p_expected, 'null'), coalesce(p_actual, 'null');
  end if;
end $$;

insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000a1', 'prov-seller@example.test', '{"display_name":"Prov Seller"}', now());

-- One place outside Lusaka province, only for this test.
insert into public.locations (province, district, town, area) values ('Southern', 'Choma', 'Choma', 'Test Area');

create function pg_temp.listing_in(p_area text, p_title text) returns uuid
language plpgsql as $$
declare new_id uuid;
begin
  insert into public.listings (seller_id, category_id, location_id, title, description, price_zmw, condition, status, moderation_status)
  select '00000000-0000-0000-0000-0000000000a1', c.id, l.id, p_title, 'Test item', 100, 'used_good', 'draft', 'pending'
    from public.categories c, public.locations l
   where c.slug = 'electronics' and l.area = p_area
  returning id into new_id;
  insert into public.listing_images (listing_id, storage_path, position) values (new_id, 'x/' || new_id || '.jpg', 0);
  update public.listings set status = 'active' where id = new_id;
  update public.listings set moderation_status = 'approved' where id = new_id;
  return new_id;
end $$;

select pg_temp.listing_in('Kabulonga', 'ProvTest Kabulonga phone');
select pg_temp.listing_in('Test Area', 'ProvTest Choma phone');

-- A guest can search a province and only gets that province.
set local role anon;
select pg_temp.check_equal((select count(*)::text from public.search_listings_in_province('Lusaka', 'ProvTest')), '1', 'Lusaka shows only Lusaka');
select pg_temp.check_equal((select count(*)::text from public.search_listings_in_province('Southern', 'ProvTest')), '1', 'Southern shows only Southern');
select pg_temp.check_equal((select count(*)::text from public.search_listings_in_province('Copperbelt', 'ProvTest')), '0', 'an empty province shows nothing');
select pg_temp.check_equal((select title from public.search_listings_in_province('Lusaka', 'ProvTest') limit 1), 'ProvTest Kabulonga phone', 'right item');

-- Narrowing to one area still works inside the province, and an area from another province gives nothing.
select pg_temp.check_equal(
  (select count(*)::text from public.search_listings_in_province('Lusaka', 'ProvTest', null, (select id from public.locations where area = 'Kabulonga'))),
  '1', 'area filter inside the province');
select pg_temp.check_equal(
  (select count(*)::text from public.search_listings_in_province('Lusaka', 'ProvTest', null, (select id from public.locations where area = 'Test Area'))),
  '0', 'an area from another province is not shown under Lusaka');
reset role;

-- Hidden listings stay hidden.
update public.listings set status = 'unavailable' where title = 'ProvTest Kabulonga phone';
set local role anon;
select pg_temp.check_equal((select count(*)::text from public.search_listings_in_province('Lusaka', 'ProvTest')), '0', 'unavailable listings are not shown');
reset role;

select 'Province search checks passed' as result;
rollback;
