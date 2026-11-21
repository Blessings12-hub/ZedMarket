-- Trust and safety flows: verification, reports, disputes, appeals and reviews.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/trust_flows.sql
--
-- Everything happens inside one transaction that is rolled back at the end.
-- Each check says what it expected, so a failure message points straight at the rule.

begin;

create temp table zm_ids (
  name text primary key,
  id uuid
) on commit drop;

grant usage on schema pg_temp to authenticated;
grant all privileges on table zm_ids to authenticated;

create function zm_test.act_as(p_user uuid, p_aal text default 'aal1') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
  execute 'set local role authenticated';
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

-- Posts a listing the way the app does: draft, one photo, then publish.
create function zm_test.make_listing(p_title text) returns uuid
language plpgsql as $$
declare
  new_id uuid;
begin
  insert into public.listings (category_id, location_id, title, description, price_zmw, condition)
  select c.id, l.id, p_title, 'A test item', 200, 'used_good'
    from public.categories c, public.locations l
   where c.slug = 'household-goods' and l.area = 'Kabulonga'
  returning id into new_id;

  insert into public.listing_images (listing_id, storage_path) values (new_id, auth.uid() || '/' || new_id || '.jpg');
  update public.listings set status = 'active' where id = new_id;
  return new_id;
end $$;

-- Ids of the rows under test. Checks call functions with these ids directly, so a
-- check can never pass just because row level security hid the row and nothing ran.
create temp table zm_ids (name text primary key, id uuid);
grant all on zm_ids to authenticated;

-- People.
--   a seller, b buyer, c outsider, d moderator, e support, f technical admin
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'seller@example.test',  '{"display_name":"Seller Test"}'),
  ('00000000-0000-0000-0000-00000000000b', 'buyer@example.test',   '{"display_name":"Buyer Test"}'),
  ('00000000-0000-0000-0000-00000000000c', 'other@example.test',   '{"display_name":"Other Test"}'),
  ('00000000-0000-0000-0000-00000000000d', 'mod@example.test',     '{"display_name":"Moderator Test"}'),
  ('00000000-0000-0000-0000-00000000000e', 'support@example.test', '{"display_name":"Support Test"}'),
  ('00000000-0000-0000-0000-00000000000f', 'tech@example.test',    '{"display_name":"Tech Test"}');

insert into public.admin_roles (user_id, role) values
  ('00000000-0000-0000-0000-00000000000d', 'moderator'),
  ('00000000-0000-0000-0000-00000000000e', 'support'),
  ('00000000-0000-0000-0000-00000000000f', 'tech_admin');

-- ---------------------------------------------------------------------------
-- 1. Identity verification
-- ---------------------------------------------------------------------------
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');

insert into public.identity_verifications (document_type, document_path)
values ('national_id', '00000000-0000-0000-0000-00000000000a/id/1.jpg');

select zm_test.act_as_admin();
insert into zm_ids select 'identity_a', id from public.identity_verifications where user_id = '00000000-0000-0000-0000-00000000000a';
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');

select zm_test.expect_equal(
  (select status::text from public.identity_verifications where user_id = '00000000-0000-0000-0000-00000000000a'),
  'pending', 'new identity request starts as pending');

select zm_test.expect_error(
  $$update public.identity_verifications set status = 'approved' where user_id = '00000000-0000-0000-0000-00000000000a'$$,
  'user approving their own identity request');

select zm_test.expect_error(
  $$insert into public.identity_verifications (user_id, document_type, document_path)
    values ('00000000-0000-0000-0000-00000000000b', 'passport', 'x/y.jpg')$$,
  'submitting an identity request for someone else');

select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
select zm_test.expect_equal(
  (select count(*)::text from public.identity_verifications), '0', 'outsider seeing identity requests');

select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_error(
  $$select public.review_identity_verification((select id from zm_ids where name = 'identity_a'), true, 'ok')$$,
  'ordinary user reviewing identity requests');

select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal2');
select zm_test.expect_error(
  $$select public.review_identity_verification((select id from zm_ids where name = 'identity_a'), true, 'ok')$$,
  'moderator (not support) reviewing identity requests');

select zm_test.act_as('00000000-0000-0000-0000-00000000000e', 'aal1');
select zm_test.expect_error(
  $$select public.review_identity_verification((select id from zm_ids where name = 'identity_a'), true, 'ok')$$,
  'support without a second factor reviewing identity requests');

select zm_test.act_as('00000000-0000-0000-0000-00000000000e', 'aal2');
select public.review_identity_verification((select id from zm_ids where name = 'identity_a'), true, 'Document matches');

select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_equal(
  (select verification_level::text from public.profiles where id = '00000000-0000-0000-0000-00000000000a'),
  'identity_verified', 'level after an approved identity check');

select zm_test.act_as('00000000-0000-0000-0000-00000000000e', 'aal2');
select zm_test.expect_error(
  $$select public.review_identity_verification((select id from zm_ids where name = 'identity_a'), true, 'again')$$,
  'reviewing the same identity request twice');

-- A rejection keeps the note, and the level stays where it was.
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
insert into public.identity_verifications (document_type, document_path)
values ('passport', '00000000-0000-0000-0000-00000000000b/id/1.jpg');
select zm_test.act_as_admin();
insert into zm_ids select 'identity_b', id from public.identity_verifications where user_id = '00000000-0000-0000-0000-00000000000b';
select zm_test.act_as('00000000-0000-0000-0000-00000000000e', 'aal2');
select public.review_identity_verification((select id from zm_ids where name = 'identity_b'), false, 'Photo is blurred');
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_equal(
  (select reviewer_note from public.identity_verifications where user_id = '00000000-0000-0000-0000-00000000000b'),
  'Photo is blurred', 'rejection note visible to the person');
select zm_test.expect_equal(
  (select verification_level::text from public.profiles where id = '00000000-0000-0000-0000-00000000000b'),
  'unverified', 'level after a rejected identity check');

-- ---------------------------------------------------------------------------
-- 2. Business verification
-- ---------------------------------------------------------------------------
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');

insert into public.businesses (name, slug) values ('Seller Test Traders', 'seller-test-traders');

select zm_test.expect_equal(
  (select count(*)::text from public.business_members
    where user_id = '00000000-0000-0000-0000-00000000000a' and role = 'owner'),
  '1', 'owner is added as a member automatically');

select zm_test.expect_error(
  $$update public.businesses set verification_status = 'verified' where slug = 'seller-test-traders'$$,
  'owner verifying their own business');

insert into public.business_verifications (business_id, registration_number)
select id, '120200001234' from public.businesses where slug = 'seller-test-traders';
select zm_test.act_as_admin();
insert into zm_ids select 'business_a', id from public.business_verifications where registration_number = '120200001234';
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');

select zm_test.expect_equal(
  (select verification_status::text from public.businesses where slug = 'seller-test-traders'),
  'pending', 'business status after submitting registration details');

select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
select zm_test.expect_equal(
  (select count(*)::text from public.business_verifications), '0', 'outsider seeing business verification');
select zm_test.expect_error(
  $$insert into public.business_verifications (business_id, registration_number)
    select id, '999' from public.businesses where slug = 'seller-test-traders'$$,
  'outsider submitting details for someone else''s business');

select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal2');
select zm_test.expect_error(
  $$select public.review_business_verification((select id from zm_ids where name = 'business_a'), true, 'x')$$,
  'moderator (not support) reviewing a business');

select zm_test.act_as('00000000-0000-0000-0000-00000000000e', 'aal2');
select public.review_business_verification((select id from zm_ids where name = 'business_a'), true, 'Certificate checked');

select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_equal(
  (select verification_status::text from public.businesses where slug = 'seller-test-traders'),
  'verified', 'business status after approval');

-- ---------------------------------------------------------------------------
-- 3. Reports
-- ---------------------------------------------------------------------------
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
insert into zm_ids values ('listing1', zm_test.make_listing('Reported kettle'));

select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
insert into public.reports (target_type, target_id, reason, details)
select 'listing', id, 'scam_or_fake', 'Photos look copied' from zm_ids where name = 'listing1';

select zm_test.act_as_admin();
insert into zm_ids select 'report1', id from public.reports where reporter_id = '00000000-0000-0000-0000-00000000000b';
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_equal(
  (select count(*)::text from public.reports), '1', 'reporter seeing their own report');
select zm_test.expect_error(
  $$update public.reports set status = 'dismissed'$$,
  'reporter closing their own report');
select zm_test.expect_error(
  $$insert into public.reports (reporter_id, target_type, target_id, reason)
    values ('00000000-0000-0000-0000-00000000000c', 'user', '00000000-0000-0000-0000-00000000000a', 'other')$$,
  'filing a report in someone else''s name');

select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_equal(
  (select count(*)::text from public.reports), '0', 'reported seller seeing who reported them');
select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
select zm_test.expect_equal(
  (select count(*)::text from public.reports), '0', 'outsider seeing reports');

select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal1');
select zm_test.expect_error(
  $$select public.resolve_report((select id from zm_ids where name = 'report1'), 'actioned', 'x')$$,
  'moderator without a second factor resolving a report');
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_error(
  $$select public.resolve_report((select id from zm_ids where name = 'report1'), 'dismissed', 'x')$$,
  'ordinary user resolving a report');

select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal2');
select zm_test.expect_equal(
  (select count(*)::text from public.reports), '1', 'moderator seeing the report queue');
select public.resolve_report((select id from zm_ids where name = 'report1'), 'actioned', 'Listing removed');
select zm_test.expect_equal(
  (select status::text from public.reports limit 1), 'actioned', 'report status after resolution');

select zm_test.act_as('00000000-0000-0000-0000-00000000000f', 'aal2');
select zm_test.expect_equal(
  (select count(*)::text from public.audit_logs where action = 'report.resolved'),
  '1', 'audit trail for a resolved report');

-- ---------------------------------------------------------------------------
-- 4. Orders and disputes
-- ---------------------------------------------------------------------------
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
insert into zm_ids values ('listing2', zm_test.make_listing('Disputed lamp'));

select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
insert into zm_ids values ('order1', (select (public.create_order((select id from zm_ids where name = 'listing2'), 'collection')).id));

select zm_test.expect_error(
  $$select public.open_dispute((select id from zm_ids where name = 'order1'), 'Too early', null)$$,
  'dispute on an order the seller has not confirmed');

select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select public.set_order_status((select id from zm_ids where name = 'order1'), 'confirmed');

select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
select zm_test.expect_error(
  $$select public.open_dispute((select id from zm_ids where name = 'order1'), 'Not my order', null)$$,
  'outsider opening a dispute');

select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select public.open_dispute((select id from zm_ids where name = 'order1'), 'Item not as described', 'Cracked base');

select zm_test.expect_equal(
  (select status::text from public.orders where id = (select id from zm_ids where name = 'order1')),
  'disputed', 'order status after a dispute is opened');
select zm_test.expect_error(
  $$select public.open_dispute((select id from zm_ids where name = 'order1'), 'Again', null)$$,
  'second open dispute on one order');

select zm_test.act_as_admin();
insert into zm_ids select 'dispute1', id from public.disputes where opened_by = '00000000-0000-0000-0000-00000000000b';
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
insert into public.dispute_evidence (dispute_id, note)
values ((select id from zm_ids where name = 'dispute1'), 'Photo sent in chat');
select zm_test.expect_error(
  $$insert into public.dispute_evidence (dispute_id, uploader_id, note)
    values ((select id from zm_ids where name = 'dispute1'), '00000000-0000-0000-0000-00000000000a', 'Pretending to be the seller')$$,
  'adding evidence in the other person''s name');

select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_equal(
  (select count(*)::text from public.dispute_evidence), '1', 'other party seeing dispute evidence');

select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
select zm_test.expect_equal((select count(*)::text from public.disputes), '0', 'outsider seeing disputes');
select zm_test.expect_equal((select count(*)::text from public.dispute_evidence), '0', 'outsider seeing evidence');

select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_error(
  $$select public.resolve_dispute((select id from zm_ids where name = 'dispute1'), 'resolved', 'I win')$$,
  'a party resolving their own dispute');

select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal2');
select zm_test.expect_error(
  $$select public.resolve_dispute((select id from zm_ids where name = 'dispute1'), 'resolved', 'x')$$,
  'moderator (not support) resolving a dispute');

select zm_test.act_as('00000000-0000-0000-0000-00000000000e', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.disputes), '1', 'support seeing disputes');
select public.resolve_dispute((select id from zm_ids where name = 'dispute1'), 'resolved', 'Partial refund agreed');

select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_equal(
  (select outcome from public.disputes limit 1), 'Partial refund agreed', 'outcome visible to the buyer');

-- ---------------------------------------------------------------------------
-- 5. Appeals
-- ---------------------------------------------------------------------------
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
insert into public.appeals (target_type, target_id, message)
select 'listing', id, 'The photos are my own, please check again' from zm_ids where name = 'listing1';

select zm_test.act_as_admin();
insert into zm_ids select 'appeal1', id from public.appeals where user_id = '00000000-0000-0000-0000-00000000000a';
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_error(
  $$insert into public.appeals (user_id, target_type, target_id, message)
    values ('00000000-0000-0000-0000-00000000000b', 'user', '00000000-0000-0000-0000-00000000000b', 'In someone else''s name')$$,
  'appealing in someone else''s name');

select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_equal((select count(*)::text from public.appeals), '0', 'other user seeing an appeal');

select zm_test.act_as('00000000-0000-0000-0000-00000000000e', 'aal2');
select zm_test.expect_error(
  $$select public.review_appeal((select id from zm_ids where name = 'appeal1'), 'overturned', 'x')$$,
  'support (not moderator) deciding an appeal');

select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.appeals), '1', 'moderator seeing appeals');
select public.review_appeal((select id from zm_ids where name = 'appeal1'), 'overturned', 'Photos verified');

select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_equal(
  (select status::text || ': ' || reviewer_note from public.appeals), 'overturned: Photos verified',
  'appeal decision visible to the person who appealed');

-- ---------------------------------------------------------------------------
-- 6. Reviews
-- ---------------------------------------------------------------------------
select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
insert into zm_ids values ('listing3', zm_test.make_listing('Reviewed fan'));

select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
insert into zm_ids values ('order2', (select (public.create_order((select id from zm_ids where name = 'listing3'), 'collection')).id));

select zm_test.expect_error(
  $$insert into public.reviews (order_id, rating, comment) select id, 5, 'Early' from zm_ids where name = 'order2'$$,
  'review before the order is completed');

select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select public.set_order_status((select id from zm_ids where name = 'order2'), 'confirmed');
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select public.set_order_status((select id from zm_ids where name = 'order2'), 'completed');

select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
select zm_test.expect_error(
  $$insert into public.reviews (order_id, rating, comment) select id, 1, 'Never bought it' from zm_ids where name = 'order2'$$,
  'outsider reviewing an order');

select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
insert into public.reviews (order_id, rating, comment) select id, 5, 'Smooth and honest' from zm_ids where name = 'order2';

select zm_test.act_as_admin();
insert into zm_ids select 'review1', id from public.reviews where reviewer_id = '00000000-0000-0000-0000-00000000000b';
select zm_test.act_as('00000000-0000-0000-0000-00000000000b');
select zm_test.expect_equal(
  (select reviewee_id::text from public.reviews limit 1), '00000000-0000-0000-0000-00000000000a',
  'review is about the other person in the order');
select zm_test.expect_error(
  $$insert into public.reviews (order_id, rating) select id, 4 from zm_ids where name = 'order2'$$,
  'second review for the same order by the same person');
select zm_test.expect_error(
  $$insert into public.reviews (order_id, rating) select id, 9 from zm_ids where name = 'order2'$$,
  'rating outside 1 to 5');
select zm_test.expect_error(
  $$update public.reviews set rating = 1$$,
  'editing a review after posting');

select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
select zm_test.expect_equal((select count(*)::text from public.reviews), '1', 'public seeing a visible review');

select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_error(
  $$select public.set_review_hidden((select id from zm_ids where name = 'review1'), true, 'Unhappy seller')$$,
  'reviewed seller hiding their own review');

select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal2');
select public.set_review_hidden((select id from zm_ids where name = 'review1'), true, 'Contains personal details');

select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
select zm_test.expect_equal((select count(*)::text from public.reviews), '0', 'public seeing a hidden review');

select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal2');
select public.set_review_hidden((select id from zm_ids where name = 'review1'), false, 'Restored after edit');
select zm_test.act_as('00000000-0000-0000-0000-00000000000c');
select zm_test.expect_equal((select count(*)::text from public.reviews), '1', 'public seeing a restored review');

-- ---------------------------------------------------------------------------
-- 7. Risk flags
-- ---------------------------------------------------------------------------
select zm_test.act_as_admin();
with f as (
  insert into public.risk_flags (subject_type, subject_id, signal)
  values ('user', '00000000-0000-0000-0000-00000000000a', 'repeated_reports')
  returning id
)
insert into zm_ids select 'flag1', id from f;

select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_equal((select count(*)::text from public.risk_flags), '0', 'person seeing risk flags about themselves');
select zm_test.expect_error(
  $$select public.mark_risk_flag_reviewed((select id from zm_ids where name = 'flag1'))$$,
  'ordinary user closing a risk flag');

select zm_test.act_as('00000000-0000-0000-0000-00000000000e', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.risk_flags), '0', 'support seeing risk flags');
select zm_test.expect_error(
  $$select public.mark_risk_flag_reviewed((select id from zm_ids where name = 'flag1'))$$,
  'support closing a risk flag');

select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal1');
select zm_test.expect_error(
  $$select public.mark_risk_flag_reviewed((select id from zm_ids where name = 'flag1'))$$,
  'moderator without a second factor closing a risk flag');

select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.risk_flags where status = 'open'), '1', 'moderator seeing an open flag');
select public.mark_risk_flag_reviewed((select id from zm_ids where name = 'flag1'));
select zm_test.expect_equal((select status from public.risk_flags), 'reviewed', 'flag status after review');
select zm_test.expect_error(
  $$select public.mark_risk_flag_reviewed((select id from zm_ids where name = 'flag1'))$$,
  'closing the same risk flag twice');

-- ---------------------------------------------------------------------------
-- 8. Staff team management
-- ---------------------------------------------------------------------------
select zm_test.act_as('00000000-0000-0000-0000-00000000000d', 'aal2');
select zm_test.expect_error(
  $$select public.grant_admin_role('00000000-0000-0000-0000-00000000000c', 'support')$$,
  'moderator granting a staff role');

select zm_test.act_as('00000000-0000-0000-0000-00000000000f', 'aal1');
select zm_test.expect_error(
  $$select public.grant_admin_role('00000000-0000-0000-0000-00000000000c', 'support')$$,
  'technical admin without a second factor granting a role');

select zm_test.act_as('00000000-0000-0000-0000-00000000000f', 'aal2');
select public.grant_admin_role('00000000-0000-0000-0000-00000000000c', 'support');
select zm_test.expect_equal(
  (select count(*)::text from public.admin_roles where user_id = '00000000-0000-0000-0000-00000000000c'),
  '1', 'role after being granted');
select public.revoke_admin_role('00000000-0000-0000-0000-00000000000c', 'support');
select zm_test.expect_equal(
  (select count(*)::text from public.admin_roles where user_id = '00000000-0000-0000-0000-00000000000c'),
  '0', 'role after being revoked');

select zm_test.act_as('00000000-0000-0000-0000-00000000000a');
select zm_test.expect_equal((select count(*)::text from public.audit_logs), '0', 'ordinary user reading the audit log');

rollback;
