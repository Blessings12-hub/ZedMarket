-- Advanced marketplace (migration 0008): guest access, search, featured, trending,
-- recently viewed, nearby, similar, recommendations, saved searches and alerts.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/marketplace.sql
--
-- One transaction, rolled back at the end.

begin;

create schema zm_test;
grant usage on schema zm_test to anon, authenticated, service_role;

create function zm_test.act_as(p_user uuid, p_aal text default 'aal1') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  execute 'set local role authenticated';
end $$;

create function zm_test.act_as_guest() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
end $$;

create function zm_test.act_as_admin() returns void
language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

create function zm_test.expect_error(p_sql text, p_what text) returns void
language plpgsql as $$
begin
  execute p_sql;
  raise exception 'Expected an error but the statement worked: %', p_what;
exception
  when others then
    if sqlerrm like 'Expected an error but%' then
      raise;
    end if;
end $$;

create function zm_test.expect_equal(p_actual text, p_expected text, p_what text) returns void
language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'Wrong result for %: expected %, got %', p_what, coalesce(p_expected, 'null'), coalesce(p_actual, 'null');
  end if;
end $$;

-- Titles returned by a query, in order, as one string.
create function zm_test.titles(p_sql text) returns text
language plpgsql as $$
declare
  result text;
begin
  execute 'select coalesce(string_agg(title, '','' order by rn), '''') from (select title, row_number() over () as rn from ('
          || p_sql || ') q) r' into result;
  return result;
end $$;

grant execute on all functions in schema zm_test to anon, authenticated, service_role;

-- People: a seller, b buyer, c another buyer, d moderator, s suspended seller
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'seller@example.test', '{"display_name":"Seller Test"}'),
  ('00000000-0000-0000-0000-00000000000b', 'buyer@example.test',  '{"display_name":"Buyer Test"}'),
  ('00000000-0000-0000-0000-00000000000c', 'other@example.test',  '{"display_name":"Other Test"}'),
  ('00000000-0000-0000-0000-00000000000d', 'mod@example.test',    '{"display_name":"Moderator Test"}'),
  ('00000000-0000-0000-0000-000000000005', 'susp@example.test',   '{"display_name":"Suspended Test"}');
insert into public.admin_roles (user_id, role) values ('00000000-0000-0000-0000-00000000000d', 'moderator');

insert into public.locations (province, town, area) values ('Copperbelt', 'Kitwe', 'Kitwe CBD');

-- Listings are written directly (this is not the posting flow, which trust_flows.sql covers).
create temp table zm_ids (name text primary key, id uuid);
grant all on zm_ids to anon, authenticated, service_role;

create function zm_test.add_listing(p_name text, p_seller uuid, p_title text, p_desc text, p_price numeric,
  p_category text, p_area text, p_condition public.item_condition, p_status public.listing_status,
  p_moderation public.moderation_status) returns void
language plpgsql as $$
declare
  new_id uuid;
begin
  insert into public.listings (seller_id, category_id, location_id, title, description, price_zmw, condition, status, moderation_status)
  select p_seller, c.id, l.id, p_title, p_desc, p_price, p_condition, 'draft', 'pending'
    from public.categories c, public.locations l
   where c.slug = p_category and l.area = p_area
  returning id into new_id;
  insert into public.listing_images (listing_id, storage_path, position) values (new_id, 'x/' || new_id || '-2.jpg', 1), (new_id, 'x/' || new_id || '-1.jpg', 0);
  -- Photos first, then publish, as the app does (a listing cannot go live without a photo).
  update public.listings set status = p_status where id = new_id;
  -- Publishing may approve it automatically, so set the review state afterwards.
  update public.listings set moderation_status = p_moderation where id = new_id;
  -- Everything in one transaction shares a clock time; give each listing its own so "newest first" is testable.
  update public.listings set created_at = clock_timestamp() where id = new_id;
  insert into zm_ids values (p_name, new_id);
end $$;

select zm_test.add_listing('phone',  '00000000-0000-0000-0000-00000000000a', 'Samsung phone',  'Works well, 100% battery', 500,  'electronics', 'Kabulonga',  'used_good', 'active', 'approved');
select zm_test.add_listing('laptop', '00000000-0000-0000-0000-00000000000a', 'Dell laptop',    'Core i5',                  4200, 'electronics', 'Woodlands',  'used_like_new', 'active', 'approved');
select zm_test.add_listing('tv',     '00000000-0000-0000-0000-00000000000a', 'Old TV',         'Needs a new screen',       300,  'electronics', 'Kabulonga',  'used_fair', 'active', 'approved');
select zm_test.add_listing('sofa',   '00000000-0000-0000-0000-00000000000a', 'Three seater sofa', 'Grey fabric',          1500, 'furniture',   'Kabulonga',  'used_good', 'active', 'approved');
select zm_test.add_listing('kitwe',  '00000000-0000-0000-0000-00000000000a', 'Kitwe phone',    'Sold in Kitwe',            450,  'electronics', 'Kitwe CBD',  'used_good', 'active', 'approved');
select zm_test.add_listing('draft',  '00000000-0000-0000-0000-00000000000a', 'Hidden draft phone', 'Not posted',         100,  'electronics', 'Kabulonga',  'new', 'draft', 'approved');
select zm_test.add_listing('pending','00000000-0000-0000-0000-00000000000a', 'Pending phone',  'Waiting for review',       100,  'electronics', 'Kabulonga',  'new', 'active', 'pending');
select zm_test.add_listing('rejected','00000000-0000-0000-0000-00000000000a','Rejected phone', 'Not allowed',             100,  'electronics', 'Kabulonga',  'new', 'active', 'rejected');
select zm_test.add_listing('susp',   '00000000-0000-0000-0000-000000000005', 'Suspended phone','From a suspended seller',  100,  'electronics', 'Kabulonga',  'new', 'active', 'approved');
select zm_test.add_listing('mine_b', '00000000-0000-0000-0000-00000000000b', 'Buyer own phone','Listed by buyer b',        550,  'electronics', 'Kabulonga',  'used_good', 'active', 'approved');
-- A seller suspended after posting: their listings must drop out of the public views.
update public.profiles set account_state = 'suspended' where id = '00000000-0000-0000-0000-000000000005';

-- ---------------------------------------------------------------------------
-- 1. Guests
-- ---------------------------------------------------------------------------
select zm_test.act_as_guest();

select zm_test.expect_error($$select 1 from public.listings limit 1$$, 'guest reading the listings table');
select zm_test.expect_error($$select 1 from public.profiles limit 1$$, 'guest reading profiles');
select zm_test.expect_error($$select 1 from public.listing_views limit 1$$, 'guest reading view history');
select zm_test.expect_error($$select 1 from public.featured_listings limit 1$$, 'guest reading featured table directly');
select zm_test.expect_error($$select 1 from public.saved_searches limit 1$$, 'guest reading saved searches');
select zm_test.expect_error($$select 1 from public.listing_alerts limit 1$$, 'guest reading alerts');
select zm_test.expect_error($$select public.recently_viewed()$$, 'guest calling recently_viewed');
select zm_test.expect_error($$select public.recommended_listings()$$, 'guest calling recommended_listings');
select zm_test.expect_error($$select public.record_listing_view('10000000-0000-0000-0000-000000000001')$$, 'guest recording a view');
select zm_test.expect_error($$select public.feature_listing('10000000-0000-0000-0000-000000000001')$$, 'guest featuring a listing');
select zm_test.expect_error($$select public.purge_old_listing_views()$$, 'guest purging views');

select zm_test.expect_equal((select count(*)::text from public.categories), '4', 'guest sees the categories');
select zm_test.expect_equal((select (count(*) > 5)::text from public.locations), 'true', 'guest sees the locations');

-- Guests see only active, approved listings from accounts that are not suspended.
select zm_test.expect_equal((select count(*)::text from public.public_listings), '6',
  'guest sees 6 public listings (drafts, pending, rejected and suspended sellers hidden)');
select zm_test.expect_equal(
  (select count(*)::text from public.public_listings where title in ('Hidden draft phone', 'Pending phone', 'Rejected phone', 'Suspended phone')),
  '0', 'hidden listings never appear in the public view');
select zm_test.expect_equal((select count(*)::text from public.search_listings()), '6', 'guest search returns the same six');

-- Public views carry no private columns.
select zm_test.expect_equal(
  (select count(*)::text from information_schema.columns
    where table_schema = 'public' and table_name in ('public_listings', 'public_listing_details', 'public_seller_profiles')
      and column_name in ('status', 'moderation_status', 'moderation_note', 'email', 'phone', 'sold_at', 'business_id', 'content_hash')),
  '0', 'public views expose no moderation or contact columns');

-- Details and seller page.
select zm_test.expect_equal((select cardinality(image_paths)::text from public.public_listing_details where title = 'Samsung phone'),
  '2', 'detail view lists photos');
select zm_test.expect_equal((select image_paths[1] like '%-1.jpg' from public.public_listing_details where title = 'Samsung phone')::text,
  'true', 'photos come back in position order');
select zm_test.expect_equal((select count(*)::text from public.public_listing_details where title = 'Hidden draft phone'), '0', 'draft has no public detail page');
select zm_test.expect_equal((select active_listings::text from public.public_seller_profiles where seller_id = '00000000-0000-0000-0000-00000000000a'),
  '5', 'seller page counts active approved listings');
select zm_test.expect_equal((select count(*)::text from public.public_seller_profiles where seller_id = '00000000-0000-0000-0000-000000000005'),
  '0', 'suspended seller has no public page');

-- ---------------------------------------------------------------------------
-- 2. Search and filters
-- ---------------------------------------------------------------------------
select zm_test.expect_equal(zm_test.titles($$select * from public.search_listings(p_term => 'phone', p_sort => 'price_asc')$$),
  'Kitwe phone,Samsung phone,Buyer own phone', 'search by word, cheapest first');
select zm_test.expect_equal(zm_test.titles($$select * from public.search_listings(p_term => 'battery')$$),
  'Samsung phone', 'search also looks in the description');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_term => '%')), '1',
  'a percent sign is plain text: it matches only the one description that really contains one, not everything');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_term => '_')), '0',
  'an underscore is plain text, not a wildcard');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_term => '100%')), '1', 'literal percent text still matches');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_term => 'phone%')), '0',
  'a trailing percent sign is not a wildcard');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_term => '   ')), '6', 'blank search word means no text filter');

select zm_test.expect_equal(zm_test.titles($$select * from public.search_listings(p_min_price => 1000, p_sort => 'price_desc')$$),
  'Dell laptop,Three seater sofa', 'price range minimum, most expensive first');
select zm_test.expect_equal(zm_test.titles($$select * from public.search_listings(p_max_price => 460, p_sort => 'price_asc')$$),
  'Old TV,Kitwe phone', 'price range maximum');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_conditions => array['used_fair']::public.item_condition[])), '1', 'condition filter');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_category_id => (select id from public.categories where slug = 'furniture'))), '1', 'category filter');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_town => 'Kitwe')), '1', 'town filter');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_location_id => (select id from public.locations where area = 'Woodlands'))), '1', 'area filter');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_seller_id => '00000000-0000-0000-0000-00000000000b')), '1', 'seller filter: one seller storefront');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_seller_id => '00000000-0000-0000-0000-000000000005')), '0', 'seller filter: suspended seller storefront is empty');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_limit => 2)), '2', 'limit works');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_limit => 1000)), '6', 'limit is capped, not an error');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_limit => 2, p_offset => 5)), '1', 'offset pages through results');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_limit => -5, p_offset => -5)), '1', 'negative limit and offset are clamped');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_sort => 'drop table')), '6', 'unknown sort falls back to newest');

-- Verified-only keeps only sellers above 'unverified'. In this test sellers are
-- unverified unless set, so set seller a on the admin side and check both ways.
select zm_test.act_as_admin();
update public.profiles set verification_level = 'identity_verified' where id = '00000000-0000-0000-0000-00000000000a';
select zm_test.act_as_guest();
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_verified_only => true)), '5', 'verified-only keeps verified sellers');
select zm_test.expect_equal((select count(*)::text from public.search_listings(p_verified_only => false)), '6', 'verified filter off shows everyone');

-- ---------------------------------------------------------------------------
-- 3. Nearby and similar (guests can use both)
-- ---------------------------------------------------------------------------
select zm_test.expect_equal((select count(*)::text from public.nearby_listings((select id from public.locations where area = 'Kabulonga'))), '5',
  'nearby: everything in Lusaka, none from Kitwe');
select zm_test.expect_equal(
  (select (array_agg(title order by rn))[1] is not null and bool_and(area = 'Kabulonga') filter (where rn <= 4)
     from (select title, area, row_number() over () as rn
             from public.nearby_listings((select id from public.locations where area = 'Kabulonga'))) q)::text,
  'true', 'nearby: same area comes first');
select zm_test.expect_equal((select count(*)::text from public.nearby_listings(-1)), '0', 'nearby with an unknown place returns nothing');

-- phone (500, electronics): laptop 4200 is out of the 0.5x to 2x range; tv 300 is out (below 250? no, 300 >= 250) so in.
select zm_test.expect_equal(zm_test.titles(format($$select * from public.similar_listings(%L)$$, (select id from zm_ids where name = 'phone'))),
  'Buyer own phone,Old TV,Kitwe phone', 'similar: same category, price within half to double, same town first, closest price first');
select zm_test.expect_equal((select count(*)::text from public.similar_listings((select id from zm_ids where name = 'draft'))), '0',
  'similar to a hidden listing shows nothing');

-- ---------------------------------------------------------------------------
-- 4. Featured
-- ---------------------------------------------------------------------------
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_error(format($$select public.feature_listing(%L)$$, (select id from zm_ids where name = 'phone')),
  'ordinary user featuring a listing');
select zm_test.expect_error(format($$select public.unfeature_listing(%L)$$, (select id from zm_ids where name = 'phone')),
  'ordinary user unfeaturing a listing');
select zm_test.expect_error($$insert into public.featured_listings (listing_id, ends_at) values ('10000000-0000-0000-0000-000000000001', now() + interval '1 day')$$,
  'ordinary user inserting into featured_listings');

select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal1');
select zm_test.expect_error(format($$select public.feature_listing(%L)$$, (select id from zm_ids where name = 'phone')),
  'moderator without two-factor featuring a listing');

select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal2');
select zm_test.expect_error(format($$select public.feature_listing(%L)$$, (select id from zm_ids where name = 'draft')),
  'featuring a draft listing');
select zm_test.expect_error(format($$select public.feature_listing(%L)$$, (select id from zm_ids where name = 'pending')),
  'featuring an unapproved listing');
select zm_test.expect_error(format($$select public.feature_listing(%L, 0)$$, (select id from zm_ids where name = 'phone')), 'featuring for zero days');
select zm_test.expect_error(format($$select public.feature_listing(%L, 31)$$, (select id from zm_ids where name = 'phone')), 'featuring for 31 days');
select public.feature_listing((select id from zm_ids where name = 'sofa'), 7);
select public.feature_listing((select id from zm_ids where name = 'phone'), 3);

-- Both were featured at the same instant inside this test, so make the sofa's start earlier.
select zm_test.act_as_admin();
update public.featured_listings set starts_at = now() - interval '1 hour' where listing_id = (select id from zm_ids where name = 'sofa');
select zm_test.act_as_guest();
select zm_test.expect_equal(zm_test.titles($$select * from public.featured_listings_now()$$), 'Samsung phone,Three seater sofa',
  'guests see featured listings, newest featuring first');

select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action = 'listing.featured'), '2', 'featuring is audited');
-- An expired feature and a feature on a listing that is later removed both drop out.
update public.featured_listings set starts_at = now() - interval '10 days', ends_at = now() - interval '1 day'
 where listing_id = (select id from zm_ids where name = 'phone');
update public.listings set moderation_status = 'rejected' where id = (select id from zm_ids where name = 'sofa');
select zm_test.act_as_guest();
select zm_test.expect_equal((select count(*)::text from public.featured_listings_now()), '0', 'expired and rejected featured listings drop out');
select zm_test.act_as_admin();
update public.listings set moderation_status = 'approved' where id = (select id from zm_ids where name = 'sofa');
select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal2');
select public.unfeature_listing((select id from zm_ids where name = 'sofa'));
select zm_test.act_as_guest();
select zm_test.expect_equal((select count(*)::text from public.featured_listings_now()), '0', 'unfeature removes it');

-- ---------------------------------------------------------------------------
-- 5. Views, recently viewed, trending, recommendations
-- ---------------------------------------------------------------------------
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');

select zm_test.expect_equal((select count(*)::text from public.recently_viewed()), '0', 'no history yet');
select zm_test.expect_equal((select count(*)::text from public.recommended_listings()), '0', 'no recommendations without any history');
select zm_test.expect_error($$insert into public.listing_views (listing_id, viewer_id) values ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b')$$,
  'inserting a view row directly');
select zm_test.expect_error($$select 1 from public.listing_views$$, 'reading view rows directly');

select public.record_listing_view((select id from zm_ids where name = 'phone'));
select public.record_listing_view((select id from zm_ids where name = 'phone'));
select public.record_listing_view((select id from zm_ids where name = 'tv'));
select public.record_listing_view((select id from zm_ids where name = 'mine_b'));     -- own listing: ignored
select public.record_listing_view((select id from zm_ids where name = 'draft'));      -- hidden: ignored
select public.record_listing_view('99999999-9999-9999-9999-999999999999');             -- unknown: ignored

select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.listing_views), '2',
  'one view per listing per hour; own, hidden and unknown listings are not recorded');
-- Make the tv view older so the order is predictable.
update public.listing_views set viewed_at = now() - interval '2 hours' where listing_id = (select id from zm_ids where name = 'tv');
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');

select zm_test.expect_equal(zm_test.titles($$select * from public.recently_viewed()$$), 'Samsung phone,Old TV', 'recently viewed, latest first');

-- Someone else has their own history.
select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
select zm_test.expect_equal((select count(*)::text from public.recently_viewed()), '0', 'history is private to each person');
select public.record_listing_view((select id from zm_ids where name = 'phone'));
select public.record_listing_view((select id from zm_ids where name = 'laptop'));
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');

-- Same category as what b looked at, not own, not already viewed or saved.
select zm_test.expect_equal(zm_test.titles($$select * from public.recommended_listings()$$),
  'Kitwe phone,Dell laptop', 'recommended: electronics b has not seen, newest first');
select zm_test.expect_equal((select count(*)::text from public.recommended_listings() where seller_id = '00000000-0000-0000-0000-00000000000b'), '0', 'never recommends own listings');

insert into public.favourites (listing_id) values ((select id from zm_ids where name = 'kitwe'));
select zm_test.expect_equal(zm_test.titles($$select * from public.recommended_listings()$$), 'Dell laptop', 'saved items are not recommended again');

-- Trending: phone has 2 viewers (b, c); tv 1; laptop 1; kitwe has 1 favourite = 3 points.
select zm_test.act_as_guest();
select zm_test.expect_equal(zm_test.titles($$select * from public.trending_listings()$$),
  'Kitwe phone,Samsung phone,Old TV,Dell laptop',
  'trending: viewers plus three per save; listings with no activity are left out');
select zm_test.act_as_admin();
update public.listing_views set viewed_at = now() - interval '40 days';
select zm_test.act_as_guest();
select zm_test.expect_equal(zm_test.titles($$select * from public.trending_listings()$$), 'Kitwe phone', 'old views no longer count toward trending');

-- Clearing history.
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select public.clear_recently_viewed();
select zm_test.expect_equal((select count(*)::text from public.recently_viewed()), '0', 'clear history');

-- Retention job: service role only.
select zm_test.expect_error($$select public.purge_old_listing_views()$$, 'ordinary user running the retention job');
select zm_test.act_as_admin();
set local role service_role;
select zm_test.expect_equal(public.purge_old_listing_views(90)::text, '0', 'retention keeps recent rows (nothing older than 90 days left here)');
select zm_test.act_as_admin();
insert into public.listing_views (listing_id, viewer_id, viewed_at)
  values ((select id from zm_ids where name = 'phone'), '00000000-0000-0000-0000-00000000000c', now() - interval '100 days');
set local role service_role;
select zm_test.expect_equal(public.purge_old_listing_views(90)::text, '1', 'retention deletes rows older than 90 days');
select zm_test.act_as_admin();

-- ---------------------------------------------------------------------------
-- 6. Saved searches and alerts
-- ---------------------------------------------------------------------------
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');

select zm_test.expect_error($$insert into public.saved_searches (name) values ('Everything')$$, 'saving a search with no filter');
select zm_test.expect_error($$insert into public.saved_searches (name, term, min_price, max_price) values ('Backwards', 'x', 500, 100)$$, 'min price above max price');
select zm_test.expect_error($$insert into public.saved_searches (user_id, name, term) values ('00000000-0000-0000-0000-00000000000c', 'Not mine', 'x')$$, 'saving a search as someone else');

insert into public.saved_searches (name, term, max_price) values ('Cheap phones', 'phone', 600);
insert into public.saved_searches (name, category_id, conditions)
  values ('New furniture', (select id from public.categories where slug = 'furniture'), array['new']::public.item_condition[]);
insert into public.saved_searches (name, term) values ('Percent sign', '100%');

select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
select zm_test.expect_equal((select count(*)::text from public.saved_searches), '0', 'saved searches are private');
insert into public.saved_searches (name, term) values ('Anything Samsung', 'samsung');
select zm_test.expect_equal((select count(*)::text from public.listing_alerts), '0', 'no alerts before anything new appears');

-- Ten at most.
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
do $$
begin
  for i in 1..7 loop
    insert into public.saved_searches (name, term) values ('Extra ' || i, 'extra ' || i);
  end loop;
end $$;
select zm_test.expect_error($$insert into public.saved_searches (name, term) values ('Eleventh', 'one too many')$$, 'an eleventh saved search');
delete from public.saved_searches where name like 'Extra %';

-- A new listing that matches "Cheap phones" (phone, up to K600) and not the other two.
select zm_test.act_as_admin();
select zm_test.add_listing('draftphone', '00000000-0000-0000-0000-00000000000a', 'Draft phone', 'Not posted yet', 400, 'electronics', 'Roma', 'used_good', 'draft', 'pending');
select zm_test.expect_equal((select count(*)::text from public.listing_alerts), '0', 'a draft listing creates no alerts');
-- Electronics needs review for a moment, so this listing is published but waits for a moderator.
update public.categories set requires_review = true where slug = 'electronics';
select zm_test.add_listing('newphone', '00000000-0000-0000-0000-00000000000a', 'Tecno phone', 'Boxed', 400, 'electronics', 'Roma', 'used_good', 'active', 'pending');
update public.categories set requires_review = false where slug = 'electronics';
select zm_test.expect_equal((select moderation_status::text from public.listings where id = (select id from zm_ids where name = 'newphone')), 'pending', 'setup: listing is waiting for review');
select zm_test.expect_equal((select count(*)::text from public.listing_alerts), '0', 'a published listing still waiting for review creates no alerts');
update public.listings set moderation_status = 'approved' where id = (select id from zm_ids where name = 'newphone');
select zm_test.expect_equal((select count(*)::text from public.listing_alerts where listing_id = (select id from zm_ids where name = 'newphone')), '1',
  'approval creates one alert, for the matching search only');
select zm_test.expect_equal((select s.name from public.listing_alerts a join public.saved_searches s on s.id = a.saved_search_id
    where a.listing_id = (select id from zm_ids where name = 'newphone')), 'Cheap phones', 'alert belongs to the matching search');
-- Editing the listing again must not create a second alert.
update public.listings set moderation_status = 'rejected' where id = (select id from zm_ids where name = 'newphone');
update public.listings set moderation_status = 'approved' where id = (select id from zm_ids where name = 'newphone');
update public.listings set title = 'Tecno phone boxed' where id = (select id from zm_ids where name = 'newphone');
select zm_test.expect_equal((select count(*)::text from public.listing_alerts where listing_id = (select id from zm_ids where name = 'newphone')), '1', 'no duplicate alert');

-- Too expensive, wrong condition, a percent sign that must not match everything, and the seller's own search.
select zm_test.add_listing('pricey', '00000000-0000-0000-0000-00000000000a', 'Fancy phone', 'Imported', 900, 'electronics', 'Roma', 'new', 'active', 'approved');
select zm_test.add_listing('usedsofa', '00000000-0000-0000-0000-00000000000a', 'Corner sofa', 'Barely used', 700, 'furniture', 'Roma', 'used_good', 'active', 'approved');
select zm_test.add_listing('newsofa', '00000000-0000-0000-0000-00000000000a', 'Brand new sofa', 'Still in plastic', 900, 'furniture', 'Roma', 'new', 'active', 'approved');
select zm_test.expect_equal((select count(*)::text from public.listing_alerts a join public.saved_searches s on s.id = a.saved_search_id where s.name = 'Cheap phones'), '1',
  'price above the maximum does not alert');
select zm_test.expect_equal((select count(*)::text from public.listing_alerts a join public.saved_searches s on s.id = a.saved_search_id where s.name = 'New furniture'), '1',
  'only the new sofa alerts the new-furniture search');
select zm_test.expect_equal((select count(*)::text from public.listing_alerts a join public.saved_searches s on s.id = a.saved_search_id where s.name = 'Percent sign'), '0',
  'a percent sign in a saved search is literal');
select zm_test.expect_equal((select count(*)::text from public.listing_alerts where user_id = '00000000-0000-0000-0000-00000000000c'), '0',
  'the Samsung search does not match any of the new listings');

-- Sellers are not alerted about their own listings.
select zm_test.act_as_admin();
insert into public.saved_searches (user_id, name, term) values ('00000000-0000-0000-0000-00000000000a', 'My own stuff', 'tecno');
update public.listings set moderation_status = 'rejected' where id = (select id from zm_ids where name = 'newphone');
update public.listings set moderation_status = 'approved' where id = (select id from zm_ids where name = 'newphone');
select zm_test.expect_equal((select count(*)::text from public.listing_alerts where user_id = '00000000-0000-0000-0000-00000000000a'), '0', 'no alerts for your own listings');

-- Reading and managing alerts.
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_equal((select count(*)::text from public.listing_alerts), '2', 'buyer b sees their two alerts');
select zm_test.expect_equal((select count(*)::text from public.listing_alerts where read_at is null), '2', 'alerts start unread');
update public.listing_alerts set read_at = now() where listing_id = (select id from zm_ids where name = 'newphone');
select zm_test.expect_equal((select count(*)::text from public.listing_alerts where read_at is null), '1', 'mark one alert read');
select zm_test.expect_error($$update public.listing_alerts set user_id = '00000000-0000-0000-0000-00000000000c'$$, 'handing an alert to someone else');
select zm_test.expect_error($$update public.listing_alerts set listing_id = '10000000-0000-0000-0000-000000000001'$$, 'changing which listing an alert points to');
select zm_test.expect_error($$insert into public.listing_alerts (user_id, saved_search_id, listing_id)
  select user_id, saved_search_id, listing_id from public.listing_alerts limit 1$$, 'creating an alert by hand');

select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
select zm_test.expect_equal((select count(*)::text from public.listing_alerts), '0', 'alerts are private');
delete from public.listing_alerts;
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.listing_alerts where user_id = '00000000-0000-0000-0000-00000000000b'), '2', 'someone else deleting alerts removes none of mine');

-- Deleting a saved search takes its alerts with it.
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
delete from public.saved_searches where name = 'Cheap phones';
select zm_test.expect_equal((select count(*)::text from public.listing_alerts), '1', 'deleting a saved search deletes its alerts');

-- Another person cannot delete my saved search.
select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
delete from public.saved_searches where name = 'New furniture';
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.saved_searches where name = 'New furniture'), '1', 'only the owner can delete a saved search');

-- ---------------------------------------------------------------------------
-- 7. Existing rules still hold
-- ---------------------------------------------------------------------------
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_equal((select count(*)::text from public.listings where title = 'Hidden draft phone'), '0', 'signed-in users still cannot see other people''s drafts');

select 'Marketplace checks passed' as result;
rollback;
