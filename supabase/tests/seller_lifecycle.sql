-- Seller lifecycle (migrations 0023, 0025 and the corrective 0026): the whole journey of a buyer who becomes a seller and
-- later closes the selling account, with the cases that used to fail.
--   * a buyer who never applied gets a complete answer from seller_application_mine() (the missing-array crash)
--   * draft, resume, submit, review, more information, approval
--   * closing: blocked with an exact explanation while orders are open, then allowed; buyer account, orders and records stay
--   * suspended sellers can close; revoked sellers can close but stay revoked
--   * a withdrawn application does not start the waiting period; a rejected one still does
--   * closing twice is harmless; permissions are unchanged
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/seller_lifecycle.sql

begin;

create schema zm_test;
grant usage on schema zm_test to anon, authenticated, service_role;

create function zm_test.act_as(p_user uuid, p_aal text default 'aal1') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
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
    if sqlerrm like 'Expected an error but%' then raise; end if;
end $$;
-- The error must be the readable one we wrote, not any error.
create function zm_test.expect_message(p_sql text, p_like text, p_what text) returns void
language plpgsql as $$
begin
  execute p_sql;
  raise exception 'Expected an error but the statement worked: %', p_what;
exception
  when others then
    if sqlerrm like 'Expected an error but%' then raise; end if;
    if sqlerrm not like p_like then
      raise exception 'Wrong error for %: expected something like %, got %', p_what, p_like, sqlerrm;
    end if;
end $$;
create function zm_test.expect_equal(p_actual text, p_expected text, p_what text) returns void
language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'Wrong result for %: expected %, got %', p_what, coalesce(p_expected, 'null'), coalesce(p_actual, 'null');
  end if;
end $$;

-- Fixed people, numbered so the checks below read clearly.
create function zm_test.u(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000002' || lpad(n::text, 2, '0'))::uuid
$$;
-- 1 buyer who never applies, 2 Anna (full journey), 3 suspended seller, 4 revoked seller, 5 withdrawer, 6 rejected applicant,
-- 7 legacy seller (no application), 8 and 9 support officers, 10 a buyer who places orders

insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at)
select zm_test.u(n), 'life' || n || '@example.test', jsonb_build_object('display_name', 'Life ' || n), now() from generate_series(1, 10) n;
insert into public.admin_roles (user_id, role) values (zm_test.u(8), 'support'), (zm_test.u(9), 'support');
update public.profiles set verification_level = 'contact_verified' where id in (select zm_test.u(n) from generate_series(1, 10) n);
update public.platform_settings set value = '1000' where key in ('rate_limit.verification_upload.max', 'rate_limit.listing.max');
update public.prohibited_terms set is_active = false;

create function zm_test.status_of(p_user uuid) returns text language sql security definer as $$
  select status from public.seller_applications where user_id = p_user order by (status in ('draft','submitted','under_review','additional_information_required')) desc, created_at desc limit 1 $$;
create function zm_test.app_of(p_user uuid) returns uuid language sql security definer as $$
  select id from public.seller_applications where user_id = p_user order by (status in ('draft','submitted','under_review','additional_information_required')) desc, created_at desc limit 1 $$;
create function zm_test.seller_status(p_user uuid) returns text language sql security definer as $$
  select seller_status from public.profiles where id = p_user $$;
create function zm_test.audits(p_action text) returns text language sql security definer as $$
  select count(*)::text from public.audit_logs where action = p_action $$;
create function zm_test.notes(p_user uuid, p_title text) returns text language sql security definer as $$
  select count(*)::text from public.notifications where user_id = p_user and type = 'seller_application' and title = p_title $$;
create function zm_test.event_count(p_user uuid, p_event text) returns text language sql security definer as $$
  select count(*)::text from public.verification_events where applicant_id = p_user and event = p_event $$;
create function zm_test.q(p_sql text) returns text language plpgsql security definer as $$
declare r text; begin execute p_sql into r; return r; end $$;
create function zm_test.listing_status(p_title text) returns text language sql security definer as $$
  select status::text from public.listings where title = p_title $$;

create function zm_test.doc(p_user uuid, p_kind text) returns void language plpgsql security definer as $$
begin
  insert into public.verification_documents (owner_id, subject_type, subject_id, kind, storage_path, mime_type, size_bytes, scan_status, created_at)
  values (p_user, 'seller_application', zm_test.app_of(p_user), p_kind, p_user || '/seller/' || p_kind || '-' || gen_random_uuid() || '.jpg', 'image/jpeg', 1000, 'clean', clock_timestamp());
end $$;
create function zm_test.full_form(p_name text default 'Anna Mwansa') returns jsonb language sql as $$
  select jsonb_build_object('legal_name', p_name, 'nationality', 'Zambian', 'is_adult', true, 'id_type', 'nrc', 'id_number', '123456/10/1',
    'residential_address', 'Plot 5, Kabulonga Road, Lusaka', 'selling_location_id', (select id from public.locations where area = 'Kabulonga'),
    'category_ids', jsonb_build_array((select id from public.categories where slug = 'electronics')),
    'sourcing_type', 'local_purchase', 'sourcing_info', 'I buy phones and chargers from a licensed wholesaler in Lusaka.',
    'experience_level', 'one_to_three_years', 'experience_info', 'Sold at Soweto market', 'expected_catalogue_size', 20,
    'returns_arrangements', 'Seven day returns on unopened items.', 'customer_service_arrangements', 'I answer messages within a day.',
    'declarations', jsonb_build_object('sells_only_legal_goods', true, 'no_counterfeit_or_stolen', true, 'information_is_true', true, 'will_honour_returns', true))
$$;
-- Ready to send: saved, agreement accepted, documents in. (Documents are added the way the scanner leaves them.)
create function zm_test.submitted(p_user uuid) returns void language plpgsql as $$
begin
  perform zm_test.act_as(p_user);
  perform public.seller_application_save(zm_test.full_form());
  perform public.seller_agreement_accept(1);
  perform zm_test.act_as_admin();
  perform zm_test.doc(p_user, 'id_front'); perform zm_test.doc(p_user, 'id_back');
  perform zm_test.doc(p_user, 'selfie_with_id'); perform zm_test.doc(p_user, 'proof_of_address');
  perform zm_test.act_as(p_user);
  perform public.seller_application_submit();
  perform zm_test.act_as_admin();
end $$;
create function zm_test.review_all(p_user uuid) returns void language plpgsql security definer as $$
declare d uuid; begin
  for d in select id from public.verification_documents where owner_id = p_user and deleted_at is null and scan_status = 'clean' loop
    perform public.verification_review_document(d, true);
  end loop; end $$;
create function zm_test.claim(p_user uuid) returns void language plpgsql as $$
begin
  perform zm_test.act_as(zm_test.u(8), 'aal2');
  perform public.seller_application_claim(zm_test.app_of(p_user));
  perform zm_test.act_as_admin();
end $$;
create function zm_test.approve(p_user uuid) returns void language plpgsql as $$
begin
  perform zm_test.claim(p_user);
  perform zm_test.act_as(zm_test.u(8), 'aal2');
  perform zm_test.review_all(p_user);
  perform public.seller_application_decide(zm_test.app_of(p_user), 'approve', 'Documents match and answers are consistent');
  perform zm_test.act_as_admin();
end $$;
-- A live, photographed listing for a seller (made without a signed-in user, so only the normal listing rules apply).
create function zm_test.listing(p_seller uuid, p_title text, p_price numeric default 500) returns uuid language plpgsql security definer as $$
declare lid uuid;
begin
  insert into public.listings (seller_id, category_id, location_id, title, description, price_zmw, condition)
  select p_seller, c.id, l.id, p_title, 'A good item', p_price, 'used_good' from public.categories c, public.locations l
   where c.slug = 'electronics' and l.area = 'Kabulonga' returning id into lid;
  insert into public.listing_images (listing_id, storage_path, position) values (lid, p_seller || '/' || p_title || '.jpg', 0);
  update public.listings set status = 'active' where id = lid;
  return lid;
end $$;
create function zm_test.order_for(p_listing uuid, p_buyer uuid, p_status public.order_status) returns uuid language plpgsql security definer as $$
declare oid uuid; l public.listings;
begin
  select * into l from public.listings where id = p_listing;
  insert into public.orders (listing_id, buyer_id, seller_id, item_title, item_price_zmw, status, buyer_name, seller_name)
  values (p_listing, p_buyer, l.seller_id, l.title, l.price_zmw, p_status,
          (select display_name from public.profiles where id = p_buyer), (select display_name from public.profiles where id = l.seller_id))
  returning id into oid;
  return oid;
end $$;
-- Runs as the signed-in person (not security definer), so the row-level rules apply.
create function zm_test.try_revive(p_title text) returns integer language plpgsql as $$
declare n integer;
begin
  update public.listings set status = 'active' where title = p_title;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on all functions in schema zm_test to anon, authenticated, service_role;

-- 1. The crash: a buyer who never applied --------------------------------------------------------------------------
select zm_test.act_as(zm_test.u(1));
select zm_test.expect_equal(public.seller_application_mine() ->> 'seller_status', 'none', 'buyer: status is none');
select zm_test.expect_equal((select string_agg(k, ',' order by k) from jsonb_object_keys(public.seller_application_mine()) k), 'application,documents,history,requests,seller_status',
  'buyer: all five keys are present');
select zm_test.expect_equal(jsonb_typeof(public.seller_application_mine() -> 'application'), 'null', 'buyer: application is null');
select zm_test.expect_equal(jsonb_typeof(public.seller_application_mine() -> 'documents'), 'array', 'buyer: documents is an array (the app calls .filter on it)');
select zm_test.expect_equal(jsonb_typeof(public.seller_application_mine() -> 'requests'), 'array', 'buyer: requests is an array');
select zm_test.expect_equal(jsonb_typeof(public.seller_application_mine() -> 'history'), 'array', 'buyer: history is an array');
select zm_test.expect_equal(jsonb_array_length(public.seller_application_mine() -> 'documents')::text, '0', 'buyer: no documents');
select zm_test.expect_equal(public.seller_can_publish()::text, 'false', 'buyer is not forced to be, and is not, a seller');
-- closing a selling account that does not exist is a readable message, not a crash
select zm_test.expect_message('select public.seller_account_close(''no reason'')', 'You do not have a selling account to close.%', 'a buyer has nothing to close');
select zm_test.act_as_guest();
select zm_test.expect_error('select public.seller_application_mine()', 'guests cannot read seller status');
select zm_test.expect_error('select public.seller_account_close(null)', 'guests cannot close a selling account');
select zm_test.act_as_admin();
-- permissions stay as they were
select zm_test.expect_equal(has_function_privilege('anon', 'public.seller_application_mine()', 'execute')::text, 'false', 'anon cannot run mine');
select zm_test.expect_equal(has_function_privilege('anon', 'public.seller_account_close(text)', 'execute')::text, 'false', 'anon cannot run close');
select zm_test.expect_equal(has_function_privilege('authenticated', 'public.seller_account_close(text)', 'execute')::text, 'true', 'signed-in people can run close');
select zm_test.expect_equal(has_function_privilege('authenticated', 'public.seller_check_text(text, integer, integer, text)', 'execute')::text, 'false', 'the length helper is not callable by app users');

-- 2. A buyer starts registration; readable draft errors; draft is saved and reopened ---------------------------------
select zm_test.act_as(zm_test.u(2));
select zm_test.expect_message($q$select public.seller_application_save('{"legal_name":"A"}')$q$, 'Your full legal name must be 3 to 120 characters.', 'short name');
select zm_test.expect_message($q$select public.seller_application_save('{"residential_address":"Lusaka"}')$q$, 'Your residential address must be 10 to 300 characters.', 'short address');
select zm_test.expect_message($q$select public.seller_application_save('{"id_number":"12"}')$q$, 'Your ID number must be 5 to 30 characters.', 'short ID number');
select zm_test.expect_message($q$select public.seller_application_save('{"returns_arrangements":"ok"}')$q$, 'Your returns arrangements must be 10 to 1000 characters.', 'short returns text');
select zm_test.expect_message($q$select public.seller_application_save('{"expected_catalogue_size":"lots"}')$q$, 'The number of products must be between 1 and 100000.', 'catalogue size not a number');
select zm_test.expect_message($q$select public.seller_application_save('{"expected_catalogue_size":0}')$q$, 'The number of products must be between 1 and 100000.', 'catalogue size zero');
select zm_test.expect_equal(zm_test.status_of(zm_test.u(2)), null, 'refused drafts create nothing');
select zm_test.expect_equal(public.seller_application_mine() ->> 'seller_status', 'none', 'still a buyer after refused drafts');
-- a partly filled draft is saved
select public.seller_application_save('{"legal_name":"Anna Mwansa","nationality":"Zambian"}');
select zm_test.expect_equal(zm_test.status_of(zm_test.u(2)), 'draft', 'draft saved');
select zm_test.act_as(zm_test.u(2));
select zm_test.expect_equal(public.seller_application_mine() -> 'application' ->> 'legal_name', 'Anna Mwansa', 'reopening the draft loads what was saved');
select zm_test.expect_equal(public.seller_application_mine() -> 'application' ->> 'status', 'draft', 'draft status shown');
select zm_test.expect_equal(jsonb_typeof(public.seller_application_mine() -> 'documents'), 'array', 'draft: documents still an array');
select zm_test.expect_equal(jsonb_typeof(public.seller_application_mine() -> 'history'), 'array', 'draft: history still an array');
-- save again later: the same draft is updated, not duplicated
select public.seller_application_save(zm_test.full_form());
select zm_test.expect_equal(zm_test.q($z$select count(*) from public.seller_applications where user_id = '00000000-0000-0000-0000-000000000202'$z$), '1', 'one draft only');
select zm_test.expect_equal(public.seller_application_mine() -> 'application' ->> 'id_number', '123456/10/1', 'later saves keep earlier answers');
select zm_test.expect_equal(public.seller_application_mine() -> 'application' ->> 'agreement_accepted', 'false', 'agreement not yet accepted');
select zm_test.expect_error('select public.seller_application_submit()', 'cannot send without the agreement and documents');
select public.seller_agreement_accept(1);
select zm_test.expect_equal(public.seller_application_mine() -> 'application' ->> 'agreement_accepted', 'true', 'agreement accepted');
select zm_test.act_as_admin();
select zm_test.doc(zm_test.u(2), 'id_front'); select zm_test.doc(zm_test.u(2), 'id_back');
select zm_test.doc(zm_test.u(2), 'selfie_with_id'); select zm_test.doc(zm_test.u(2), 'proof_of_address');
select zm_test.act_as(zm_test.u(2));
select zm_test.expect_equal(jsonb_array_length(public.seller_application_mine() -> 'documents')::text, '4', 'documents listed');
select public.seller_application_submit();
select zm_test.expect_equal(public.seller_application_mine() -> 'application' ->> 'status', 'submitted', 'submitted is shown');
select zm_test.expect_equal(zm_test.q($z$select count(*) from public.notifications where user_id = '00000000-0000-0000-0000-000000000202' and title = 'Application received'$z$), '1', 'the applicant is told it arrived');
select zm_test.expect_error($q$select public.seller_application_save('{"legal_name":"Changed Name"}')$q$, 'cannot edit while it is being reviewed');

-- 3. Review, more information, approval ----------------------------------------------------------------------------
select zm_test.act_as_admin();
select zm_test.claim(zm_test.u(2));
select zm_test.act_as(zm_test.u(2));
select zm_test.expect_equal(public.seller_application_mine() -> 'application' ->> 'status', 'under_review', 'under review is shown');
select zm_test.act_as(zm_test.u(8), 'aal2');
select public.seller_application_request_info(zm_test.app_of(zm_test.u(2)), 'Please explain who supplies your phones.', '{}');
select zm_test.act_as(zm_test.u(2));
select zm_test.expect_equal(public.seller_application_mine() -> 'application' ->> 'status', 'additional_information_required', 'more information requested is shown');
select zm_test.expect_equal(jsonb_array_length(public.seller_application_mine() -> 'requests')::text, '1', 'the request is listed');
select zm_test.expect_equal(public.seller_application_mine() -> 'requests' -> 0 ->> 'status', 'open', 'the request is open');
select public.seller_application_respond(((public.seller_application_mine() -> 'requests' -> 0) ->> 'id')::uuid, 'Supplier: Lusaka Phone Wholesale Ltd.');
select zm_test.expect_equal(public.seller_application_mine() -> 'application' ->> 'status', 'under_review', 'after answering it goes back to review');
select zm_test.act_as_admin();
select zm_test.act_as(zm_test.u(8), 'aal2');
select zm_test.review_all(zm_test.u(2));
select public.seller_application_decide(zm_test.app_of(zm_test.u(2)), 'approve', 'Documents match and answers are consistent');
select zm_test.act_as(zm_test.u(2));
select zm_test.expect_equal(public.seller_application_mine() ->> 'seller_status', 'active', 'approved: seller status is active');
select zm_test.expect_equal(public.seller_application_mine() -> 'application' ->> 'status', 'approved', 'approved is shown');
select zm_test.expect_equal(public.seller_can_publish()::text, 'true', 'approved seller can use seller tools');
select zm_test.expect_equal(jsonb_typeof(public.seller_application_mine() -> 'history'), 'array', 'approved: history is an array');
select zm_test.expect_equal(zm_test.q($z$select count(*) from public.verification_documents where owner_id = '00000000-0000-0000-0000-000000000202' and purge_after > now() + interval '300 days'$z$), '4', 'approval set the longer retention');

-- 4. Closing is blocked while orders are open, with an exact explanation --------------------------------------------
select zm_test.act_as_admin();
select zm_test.listing(zm_test.u(2), 'Anna phone one');
select zm_test.listing(zm_test.u(2), 'Anna phone two');
select zm_test.listing(zm_test.u(2), 'Anna phone three');
select zm_test.listing(zm_test.u(2), 'Anna phone four');
select zm_test.order_for((select id from public.listings where title = 'Anna phone one'), zm_test.u(10), 'requested');
select zm_test.order_for((select id from public.listings where title = 'Anna phone two'), zm_test.u(10), 'confirmed');
select zm_test.order_for((select id from public.listings where title = 'Anna phone three'), zm_test.u(10), 'disputed');
select zm_test.order_for((select id from public.listings where title = 'Anna phone four'), zm_test.u(10), 'completed');
select zm_test.act_as(zm_test.u(2));
select zm_test.expect_message($q$select public.seller_account_close('stopping')$q$,
  'You cannot close your selling account yet. Still open: 1 order request(s) waiting for your answer (accept or decline them); 1 confirmed order(s) (complete or cancel them); 1 disputed order(s) (these finish when support settles the dispute). Settle these first, then try again.',
  'open orders block closing and say exactly what is open');
select zm_test.expect_equal(zm_test.seller_status(zm_test.u(2)), 'active', 'a blocked closure changes nothing: still a seller');
select zm_test.expect_equal(zm_test.listing_status('Anna phone one'), 'active', 'a blocked closure changes nothing: listing still on sale');
select zm_test.expect_equal(zm_test.status_of(zm_test.u(2)), 'approved', 'a blocked closure changes nothing: application still approved');
-- each blocker alone is named alone
select zm_test.act_as_admin();
update public.orders set status = 'cancelled', cancel_kind = 'cancelled', cancelled_by = 'buyer' where item_title in ('Anna phone one', 'Anna phone two');
select zm_test.act_as(zm_test.u(2));
select zm_test.expect_message($q$select public.seller_account_close(null)$q$, '%Still open: 1 disputed order(s) (these finish when support settles the dispute).%', 'only the dispute remains');
select zm_test.act_as_admin();
update public.orders set status = 'cancelled', cancel_kind = 'cancelled', cancelled_by = 'staff' where item_title = 'Anna phone three';

-- 5. Closing: the buyer account, orders and records stay --------------------------------------------------------------
select zm_test.act_as(zm_test.u(2));
select public.seller_account_close('I no longer want to sell');
select zm_test.expect_equal(zm_test.seller_status(zm_test.u(2)), 'none', 'closed: back to a buyer');
select zm_test.expect_equal(zm_test.status_of(zm_test.u(2)), 'closed', 'closed: the application is closed');
select zm_test.expect_equal(public.seller_can_publish()::text, 'false', 'closed: seller permissions are gone');
select zm_test.expect_error($q$insert into public.listings (category_id, location_id, title, description, price_zmw, condition)
   select c.id, l.id, 'After closing', 'x', 10, 'new' from public.categories c, public.locations l limit 1$q$, 'a closed seller cannot create listings');
-- the seller dashboard screen is hidden by the app (see sellerAccess tests); in the database, a closed seller cannot put an item back on sale
select zm_test.expect_equal(zm_test.try_revive('Anna phone one')::text, '0', 'a closed seller cannot put a removed listing back on sale');
select zm_test.expect_equal(zm_test.listing_status('Anna phone one'), 'removed', 'the removed listing stays removed');
select zm_test.expect_equal(zm_test.listing_status('Anna phone one'), 'removed', 'closed: for-sale listing taken off sale');
select zm_test.expect_equal(zm_test.listing_status('Anna phone four'), 'removed', 'closed: every active listing is off sale');
select zm_test.expect_equal(public.seller_application_mine() ->> 'seller_status', 'none', 'closed: status read back is none');
select zm_test.expect_equal(public.seller_application_mine() -> 'application' ->> 'status', 'closed', 'closed: application read back is closed');
select zm_test.expect_equal(jsonb_typeof(public.seller_application_mine() -> 'documents'), 'array', 'closed: documents is an array');
select zm_test.expect_equal(jsonb_typeof(public.seller_application_mine() -> 'requests'), 'array', 'closed: requests is an array');
-- the buyer account is intact
select zm_test.expect_equal((select display_name from public.profiles where id = zm_test.u(2)), 'Life 2', 'closed: the profile is intact');
update public.profiles set bio = 'Still here as a buyer' where id = zm_test.u(2);
select zm_test.expect_equal((select bio from public.profiles where id = zm_test.u(2)), 'Still here as a buyer', 'closed: the buyer can still use their account');
select zm_test.act_as_admin();
-- history and records are kept
select zm_test.expect_equal(zm_test.q($z$select count(*) from public.orders where seller_id = '00000000-0000-0000-0000-000000000202'$z$), '4', 'closed: orders are kept');
select zm_test.expect_equal(zm_test.audits('seller.account_closed'), '1', 'closed: an audit record was written');
select zm_test.expect_equal(zm_test.event_count(zm_test.u(2), 'closed_by_seller'), '1', 'closed: the verification history records it');
select zm_test.expect_equal((zm_test.q($z$select count(*) from public.verification_events where applicant_id = '00000000-0000-0000-0000-000000000202'$z$)::int > 5)::text, 'true', 'closed: earlier history is kept');
select zm_test.expect_equal(zm_test.q($z$select jsonb_array_length(metadata -> 'agreement_acceptances_archived') from public.audit_logs where action = 'seller.account_closed'$z$), '1', 'closed: the agreement acceptance is copied into the audit log');
select zm_test.expect_equal(zm_test.q($z$select count(*) from public.seller_agreement_acceptances where user_id = '00000000-0000-0000-0000-000000000202'$z$), '0', 'closed: the next application must accept the agreement again');
select zm_test.expect_equal(zm_test.q($z$select count(*) from public.verification_documents where owner_id = '00000000-0000-0000-0000-000000000202' and purge_after < now() + interval '31 days'$z$), '4', 'closed: documents are on the 30 day retention clock, not left on the longer one');
select zm_test.expect_equal(zm_test.q($z$select count(*) from public.verification_documents where owner_id = '00000000-0000-0000-0000-000000000202' and deleted_at is null$z$), '4', 'closed: documents are scheduled, not deleted on the spot');
-- the person is told
select zm_test.expect_equal(zm_test.notes(zm_test.u(2), 'Selling account closed'), '1', 'closed: the person gets a confirmation notice');
-- closing again (a second tap) is harmless
select zm_test.act_as(zm_test.u(2));
select public.seller_account_close('second tap');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.audits('seller.account_closed'), '1', 'closing twice records nothing twice');
select zm_test.expect_equal(zm_test.notes(zm_test.u(2), 'Selling account closed'), '1', 'closing twice does not notify twice');

-- 6. A closed seller can apply again straight away -------------------------------------------------------------------
select zm_test.act_as(zm_test.u(2));
select public.seller_application_save(zm_test.full_form('Anna Mwansa'));
select zm_test.expect_equal(zm_test.status_of(zm_test.u(2)), 'draft', 'a new application starts straight after closing');
select zm_test.expect_equal(public.seller_application_mine() -> 'application' ->> 'status', 'draft', 'the new draft is what is shown');
select zm_test.expect_equal(public.seller_application_mine() -> 'application' ->> 'agreement_accepted', 'false', 'the new application starts without an accepted agreement');
select zm_test.expect_equal(zm_test.q($z$select count(*) from public.seller_applications where user_id = '00000000-0000-0000-0000-000000000202'$z$), '2', 'the closed application is kept next to the new one');

-- 7. Withdrawing does not start the waiting period; a real rejection does -----------------------------------------------
select zm_test.submitted(zm_test.u(5));
select zm_test.act_as(zm_test.u(5));
select public.seller_application_withdraw();
select zm_test.expect_equal(zm_test.status_of(zm_test.u(5)), 'rejected', 'a withdrawn application is stored as rejected');
select public.seller_application_save(zm_test.full_form('Withdrawer One'));
select zm_test.expect_equal(zm_test.status_of(zm_test.u(5)), 'draft', 'after withdrawing, a new application starts immediately');
select zm_test.submitted(zm_test.u(6));
select zm_test.claim(zm_test.u(6));
select zm_test.act_as(zm_test.u(8), 'aal2');
select public.seller_application_decide(zm_test.app_of(zm_test.u(6)), 'reject', 'Documents do not match the answers given');
select zm_test.act_as(zm_test.u(6));
select zm_test.expect_message($q$select public.seller_application_save('{"legal_name":"Rejected Person"}')$q$, 'You can apply again after % days from the decision.', 'a rejection still starts the waiting period');
select zm_test.act_as_admin();
update public.seller_applications set decided_at = now() - interval '8 days' where user_id = zm_test.u(6);
select zm_test.act_as(zm_test.u(6));
select public.seller_application_save(zm_test.full_form('Rejected Person'));
select zm_test.expect_equal(zm_test.status_of(zm_test.u(6)), 'draft', 'after the waiting period a rejected applicant can apply again');

-- 8. A suspended seller can close; their record of suspension stays ----------------------------------------------------
select zm_test.act_as_admin();
select zm_test.submitted(zm_test.u(3));
select zm_test.approve(zm_test.u(3));
select zm_test.listing(zm_test.u(3), 'Suspended seller item');
select zm_test.act_as(zm_test.u(9), 'aal2');
select public.seller_application_suspend(zm_test.app_of(zm_test.u(3)), 'Buyers reported items not as described', false);
select zm_test.act_as(zm_test.u(3));
select zm_test.expect_equal(public.seller_application_mine() ->> 'seller_status', 'suspended', 'suspended is shown');
select zm_test.expect_equal(zm_test.listing_status('Suspended seller item'), 'unavailable', 'suspension paused the listing');
select public.seller_account_close('Closing while suspended');
select zm_test.expect_equal(zm_test.seller_status(zm_test.u(3)), 'none', 'suspended seller: closed, back to a buyer');
select zm_test.expect_equal(zm_test.status_of(zm_test.u(3)), 'closed', 'suspended seller: application closed');
select zm_test.expect_equal(zm_test.listing_status('Suspended seller item'), 'removed', 'suspended seller: paused listing is taken off sale');
select zm_test.expect_equal(public.seller_can_publish()::text, 'false', 'suspended seller: cannot sell after closing');
select zm_test.expect_equal(zm_test.event_count(zm_test.u(3), 'suspended'), '1', 'suspended seller: the suspension stays in the history');
select zm_test.expect_equal(zm_test.event_count(zm_test.u(3), 'closed_by_seller'), '1', 'suspended seller: the closure is recorded');
select zm_test.expect_equal(zm_test.notes(zm_test.u(3), 'Selling account closed'), '1', 'suspended seller: told it closed');

-- 9. A revoked seller can close, but selling stays revoked ---------------------------------------------------------------
select zm_test.act_as_admin();
select zm_test.submitted(zm_test.u(4));
select zm_test.approve(zm_test.u(4));
select zm_test.listing(zm_test.u(4), 'Revoked seller item');
select zm_test.act_as(zm_test.u(9), 'aal2');
select public.seller_application_suspend(zm_test.app_of(zm_test.u(4)), 'Sold counterfeit goods after a warning', true);
select zm_test.act_as(zm_test.u(4));
select zm_test.expect_equal(public.seller_application_mine() ->> 'seller_status', 'revoked', 'revoked is shown');
select public.seller_account_close('Closing a revoked account');
select zm_test.expect_equal(zm_test.seller_status(zm_test.u(4)), 'revoked', 'revoked seller: selling stays revoked, the staff decision stands');
select zm_test.expect_equal(zm_test.status_of(zm_test.u(4)), 'revoked', 'revoked seller: the application keeps its revoked status');
select zm_test.expect_equal(zm_test.listing_status('Revoked seller item'), 'removed', 'revoked seller: listing taken off sale');
select zm_test.expect_equal(public.seller_can_publish()::text, 'false', 'revoked seller: cannot sell');
select zm_test.expect_message($q$select public.seller_application_save('{"legal_name":"Try Again Person"}')$q$, 'You already have a seller account.%', 'revoked seller cannot start a new application by closing');
select zm_test.expect_equal(zm_test.event_count(zm_test.u(4), 'closed_by_seller'), '1', 'revoked seller: the closure is recorded');
select zm_test.expect_equal(zm_test.notes(zm_test.u(4), 'Selling account closed'), '1', 'revoked seller: told it closed');
select public.seller_account_close('second tap');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.event_count(zm_test.u(4), 'closed_by_seller'), '1', 'revoked seller: closing again records nothing twice');
select zm_test.expect_equal(zm_test.notes(zm_test.u(4), 'Selling account closed'), '1', 'revoked seller: closing again does not notify twice');

-- 10. A seller from before applications existed (no application row) ------------------------------------------------------
update public.profiles set seller_status = 'active' where id = zm_test.u(7);
select zm_test.listing(zm_test.u(7), 'Legacy seller item');
select zm_test.act_as(zm_test.u(7));
select zm_test.expect_equal(public.seller_application_mine() ->> 'seller_status', 'active', 'legacy seller: status is active');
select zm_test.expect_equal(jsonb_typeof(public.seller_application_mine() -> 'application'), 'null', 'legacy seller: no application');
select zm_test.expect_equal(jsonb_typeof(public.seller_application_mine() -> 'documents'), 'array', 'legacy seller: documents is an array, not missing');
select zm_test.expect_equal(jsonb_typeof(public.seller_application_mine() -> 'history'), 'array', 'legacy seller: history is an array, not missing');
select public.seller_account_close('Legacy close');
select zm_test.expect_equal(zm_test.seller_status(zm_test.u(7)), 'none', 'legacy seller: closed without an application row');
select zm_test.expect_equal(zm_test.listing_status('Legacy seller item'), 'removed', 'legacy seller: listing taken off sale');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.notes(zm_test.u(7), 'Selling account closed'), '1', 'legacy seller: told it closed');

-- 11. Other people's selling accounts are not touched ----------------------------------------------------------------------
select zm_test.expect_equal(zm_test.listing_status('Revoked seller item'), 'removed', 'only the closing seller was affected (revoked item)');
select zm_test.expect_equal(zm_test.q($z$select count(*) from public.profiles where seller_status = 'active'$z$), '0', 'no other seller was switched off by accident (none were active)');

rollback;
