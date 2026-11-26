-- Product comparison and duplicate photos (migration 0029).
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/comparison_and_photos.sql
begin;
create schema zm_test;
grant usage on schema zm_test to anon, authenticated, service_role;
create function zm_test.act_as(p_user uuid, p_aal text default 'aal1') returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true); execute 'set local role authenticated'; end $$;
create function zm_test.act_as_guest() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon'; end $$;
create function zm_test.act_as_admin() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create function zm_test.expect_error(p_sql text, p_what text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'Expected an error but the statement worked: %', p_what;
exception when others then if sqlerrm like 'Expected an error but%' then raise; end if; end $$;
create function zm_test.expect_equal(p_actual text, p_expected text, p_what text) returns void language plpgsql as $$
begin if p_actual is distinct from p_expected then raise exception 'Wrong result for %: expected %, got %', p_what, coalesce(p_expected,'null'), coalesce(p_actual,'null'); end if; end $$;
create function zm_test.msg(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'no error'; exception when others then return sqlerrm; end $$;
grant execute on all functions in schema zm_test to anon, authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000a1', 'a@example.test', '{"display_name":"Seller A"}', now()),
  ('00000000-0000-0000-0000-0000000000a2', 'b@example.test', '{"display_name":"Seller B"}', now()),
  ('00000000-0000-0000-0000-0000000000c1', 'c@example.test', '{"display_name":"Buyer"}', now()),
  ('00000000-0000-0000-0000-000000000054', 'm@example.test', '{"display_name":"Moderator"}', now()),
  ('00000000-0000-0000-0000-000000000055', 'm2@example.test', '{"display_name":"Moderator Two"}', now());
insert into public.admin_roles (user_id, role) values
  ('00000000-0000-0000-0000-000000000054', 'moderator'), ('00000000-0000-0000-0000-000000000055', 'moderator');
update public.profiles set seller_status = 'active';

-- listings (draft is enough for the photo checks; the active ones are for comparison)
insert into public.listings (id, seller_id, category_id, location_id, title, description, price_zmw, condition, status, moderation_status)
select ('30000000-0000-0000-0000-00000000000' || n)::uuid, case when n in (1, 3) then '00000000-0000-0000-0000-0000000000a1'::uuid else '00000000-0000-0000-0000-0000000000a2'::uuid end,
       (select id from public.categories order by id limit 1), (select id from public.locations order by id limit 1),
       'Phone ' || n, 'A phone', 1000 * n, 'used_good', 'draft', 'pending'
  from generate_series(1, 5) n;

-- the stored files: 1 and 2 are the same bytes (same ETag) but belong to different sellers; 3 repeats 1 inside one seller
insert into storage.objects (bucket_id, name, metadata) values
  ('listing-images', 'a/1.jpg', '{"eTag":"\"aaa\""}'), ('listing-images', 'b/2.jpg', '{"eTag":"\"aaa\""}'),
  ('listing-images', 'a/3.jpg', '{"eTag":"\"aaa\""}'), ('listing-images', 'b/4.jpg', '{"eTag":"\"zzz\""}');

-- a forged hash from the app is overwritten by the real fingerprint; a missing file leaves it empty
insert into public.listing_images (listing_id, storage_path, content_hash) values ('30000000-0000-0000-0000-000000000001', 'a/1.jpg', 'forged');
select zm_test.expect_equal((select content_hash from public.listing_images where storage_path = 'a/1.jpg'), 'aaa', 'fingerprint comes from the stored file');
insert into public.listing_images (listing_id, storage_path, content_hash) values ('30000000-0000-0000-0000-000000000004', 'nowhere.jpg', 'forged');
select zm_test.expect_equal((select content_hash is null from public.listing_images where storage_path = 'nowhere.jpg')::text, 'true', 'no file, no fingerprint, no crash');
select zm_test.expect_equal((select count(*)::text from public.listing_image_flags), '0', 'the first use of a photo is not flagged');

insert into public.listing_images (listing_id, storage_path) values ('30000000-0000-0000-0000-000000000002', 'b/2.jpg');
select zm_test.expect_equal((select count(*)::text from public.listing_image_flags where status = 'open'), '1', 'the same photo on another seller is flagged');
insert into public.listing_images (listing_id, storage_path) values ('30000000-0000-0000-0000-000000000003', 'a/3.jpg');
select zm_test.expect_equal((select count(*)::text from public.listing_image_flags), '2', 'seller A reusing it also hits seller B but not their own listing');
insert into public.listing_images (listing_id, storage_path) values ('30000000-0000-0000-0000-000000000004', 'b/4.jpg');
select zm_test.expect_equal((select count(*)::text from public.listing_image_flags), '2', 'a different photo is not flagged');

update public.listings set status = 'active', moderation_status = 'approved' where id::text < '30000000-0000-0000-0000-000000000005';

-- seller view: counts only
select zm_test.act_as('00000000-0000-0000-0000-0000000000a1');
select zm_test.expect_equal((public.listing_duplicate_photos('30000000-0000-0000-0000-000000000001')->>'own_other_listings'), '1', 'own repeated photo counted');
select zm_test.expect_equal((public.listing_duplicate_photos('30000000-0000-0000-0000-000000000001')->>'other_sellers'), '0', 'flag sits on the later listing');
select zm_test.expect_equal((public.listing_duplicate_photos('30000000-0000-0000-0000-000000000003')->>'other_sellers'), '1', 'later listing shows one other seller');
select zm_test.expect_error($$select public.listing_duplicate_photos('30000000-0000-0000-0000-000000000002')$$, 'not their listing');
select zm_test.expect_error($$select * from public.image_flag_queue()$$, 'a seller cannot read the queue');
select zm_test.expect_error($$select * from public.listing_image_flags$$, 'no table access');

-- staff
select zm_test.act_as('00000000-0000-0000-0000-000000000054');
select zm_test.expect_error($$select * from public.image_flag_queue()$$, 'moderator without two-factor refused');
select zm_test.act_as('00000000-0000-0000-0000-000000000054', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.image_flag_queue('open')), '2', 'queue lists open flags');
select zm_test.expect_error($$select * from public.image_flag_queue('bogus')$$, 'unknown status');
select zm_test.expect_error(format($f$select public.image_flag_resolve(%L, 'ban')$f$, (select id from public.image_flag_queue('open') limit 1)), 'unknown decision');
select public.image_flag_resolve((select id from public.image_flag_queue('open') limit 1), 'dismiss', 'stock photo');
select public.image_flag_resolve((select id from public.image_flag_queue('open') limit 1), 'confirm', 'same photo, different sellers');
select zm_test.expect_equal((select count(*)::text from public.image_flag_queue('open')), '0', 'all resolved');
select zm_test.expect_equal((select count(*)::text from public.image_flag_queue('confirmed')), '1', 'confirmed kept');
select zm_test.expect_error(format($f$select public.image_flag_resolve(%L, 'dismiss')$f$, (select id from public.image_flag_queue('confirmed') limit 1)), 'cannot resolve twice');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action in ('image_flag.dismiss', 'image_flag.confirm')), '2', 'decisions are audited');

-- comparison: public, 2 to 4, hidden listings come back as missing
select zm_test.act_as_guest();
select zm_test.expect_equal(public.compare_listings(array['30000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002']::uuid[])->'items'->0->>'title', 'Phone 1', 'order kept');
select zm_test.expect_equal(jsonb_array_length(public.compare_listings(array['30000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002']::uuid[])->'items')::text, '2', 'two items');
select zm_test.expect_equal(jsonb_array_length(public.compare_listings(array['30000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000005']::uuid[])->'missing')::text, '1', 'a draft is reported missing, never shown');
select zm_test.expect_equal(jsonb_array_length(public.compare_listings(array['30000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000005']::uuid[])->'items')::text, '1', 'a draft is not leaked');
select zm_test.expect_equal(zm_test.msg($$select public.compare_listings(array['30000000-0000-0000-0000-000000000001']::uuid[])$$), 'Pick at least 2 listings to compare.', 'one is too few');
select zm_test.expect_equal(zm_test.msg($$select public.compare_listings(null)$$), 'Pick at least 2 listings to compare.', 'null is handled');
select zm_test.expect_equal(zm_test.msg($$select public.compare_listings(array['30000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001']::uuid[])$$), 'Pick at least 2 listings to compare.', 'duplicates collapse');
select zm_test.expect_equal(zm_test.msg($$select public.compare_listings(array(select ('30000000-0000-0000-0000-00000000000' || n)::uuid from generate_series(1,5) n))$$), 'You can compare up to 4 listings at a time.', 'five is too many');
select zm_test.act_as_admin();
select 'Comparison and duplicate photo checks passed' as result;
rollback;
