-- 0026: seller lifecycle fixes. A corrective migration: 0023 and 0025 are already deployed, so they are not edited.
--
-- What was wrong, and what changes
--   1. seller_application_mine() returned only seller_status and application for a person with no application. The app
--      reads documents, requests and history from it, so opening Seller Status crashed for every ordinary buyer (and for
--      sellers carried over from before applications existed). It now ALWAYS returns all five keys.
--   2. A withdrawn application is stored as 'rejected' with a decision time, so withdrawing started the re-apply waiting
--      period. Only a real rejection does now.
--   3. seller_application_save() let the table's own length rules answer for a bad draft, which reached the person as a
--      raw database message. It now names the answer that is wrong.
--   4. seller_account_close():
--        * suspended sellers can now close (they were refused with nowhere to go); revoked sellers can close the selling
--          account too, but stay revoked, so a staff decision cannot be walked away from;
--        * the open-orders refusal says exactly what is open and what to do about each;
--        * only listings that are for sale or paused are taken off sale; a sold listing keeps its history;
--        * documents go on the retention clock even when approval had already set a longer one;
--        * agreement acceptances are copied into the audit log before they are cleared for the next application;
--        * the person gets a notice confirming the closure;
--        * closing twice is harmless.
--   Nothing here weakens a row-level-security policy, a grant or a verification step.

create index if not exists seller_applications_user_idx on public.seller_applications (user_id, created_at desc);

-- Small helper for readable length errors. Not callable by app users; the functions below call it as their owner.
create or replace function public.seller_check_text(p_value text, p_min integer, p_max integer, p_label text)
returns void
language plpgsql immutable set search_path = ''
as $$
declare
  v text := nullif(btrim(coalesce(p_value, '')), '');
begin
  if v is not null and char_length(v) not between p_min and p_max then
    raise exception '% must be % to % characters.', p_label, p_min, p_max using errcode = 'check_violation';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. What the applicant sees: always the same five keys
-- ---------------------------------------------------------------------------
create or replace function public.seller_application_mine()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  a public.seller_applications;
  pv public.seller_application_private;
  sstatus text;
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;
  select seller_status into sstatus from public.profiles where id = uid;
  sstatus := coalesce(sstatus, 'none');

  select * into a from public.seller_applications where user_id = uid
   order by (status in ('draft', 'submitted', 'under_review', 'additional_information_required', 'approved', 'suspended')) desc, created_at desc limit 1;
  if not found then
    return jsonb_build_object(
      'seller_status', sstatus, 'application', null,
      'documents', '[]'::jsonb, 'requests', '[]'::jsonb, 'history', '[]'::jsonb);
  end if;

  select * into pv from public.seller_application_private where application_id = a.id;
  return jsonb_build_object(
    'seller_status', sstatus,
    'application', jsonb_build_object(
      'id', a.id, 'status', a.status, 'legal_name', a.legal_name, 'nationality', a.nationality, 'is_adult', a.is_adult,
      'id_type', a.id_type, 'id_number', pv.id_number, 'residential_address', pv.residential_address,
      'selling_location_id', a.selling_location_id, 'category_ids', a.category_ids, 'sourcing_type', a.sourcing_type,
      'sourcing_info', a.sourcing_info, 'experience_level', a.experience_level, 'experience_info', a.experience_info,
      'expected_catalogue_size', a.expected_catalogue_size, 'returns_arrangements', a.returns_arrangements,
      'customer_service_arrangements', a.customer_service_arrangements, 'declarations', a.declarations,
      'submitted_at', a.submitted_at, 'decision_reason', a.decision_reason, 'decided_at', a.decided_at,
      'required_documents', public.seller_required_kinds(a.id_type),
      'agreement_accepted', exists (select 1 from public.seller_agreement_acceptances c join public.seller_agreements g
                                     on g.version = c.version and g.is_current where c.user_id = uid)),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'scan', d.scan_status, 'review', d.review_status,
                  'note', d.review_note, 'at', d.created_at) order by d.created_at)
                  from public.verification_documents d where d.subject_type = 'seller_application' and d.subject_id = a.id and d.deleted_at is null), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'message', r.message, 'document_kinds', r.document_kinds,
                  'status', r.status, 'due_at', r.due_at, 'created_at', r.created_at) order by r.created_at)
                  from public.verification_requests r where r.subject_type = 'seller_application' and r.subject_id = a.id), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(jsonb_build_object('event', e.event, 'to_status', e.to_status, 'note', e.note, 'at', e.created_at) order by e.id)
                  from public.verification_events e where e.subject_type = 'seller_application' and e.subject_id = a.id and e.visible_to_applicant), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------
-- 2 and 3. Saving a draft: readable answers, and withdrawing does not start the waiting period
-- ---------------------------------------------------------------------------
create or replace function public.seller_application_save(p_data jsonb)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  a public.seller_applications;
  prof public.profiles;
  wait_days integer := public.setting_numeric('seller.reapply_days', 7)::integer;
  last_rejected timestamptz;
  cats integer[];
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;
  select * into prof from public.profiles where id = uid;
  if prof.account_state <> 'active' then
    raise exception 'Your account cannot apply right now.' using errcode = 'insufficient_privilege';
  end if;
  if prof.seller_status in ('active', 'suspended', 'revoked') then
    raise exception 'You already have a seller account. Open it from your account.' using errcode = 'check_violation';
  end if;

  -- Say plainly which answer is wrong, instead of failing later with a raw table-rule message.
  if p_data ? 'legal_name' then perform public.seller_check_text(p_data ->> 'legal_name', 3, 120, 'Your full legal name'); end if;
  if p_data ? 'nationality' then perform public.seller_check_text(p_data ->> 'nationality', 2, 60, 'Your nationality'); end if;
  if p_data ? 'id_number' then perform public.seller_check_text(upper(p_data ->> 'id_number'), 5, 30, 'Your ID number'); end if;
  if p_data ? 'residential_address' then perform public.seller_check_text(p_data ->> 'residential_address', 10, 300, 'Your residential address'); end if;
  if p_data ? 'sourcing_info' then perform public.seller_check_text(p_data ->> 'sourcing_info', 10, 1000, 'What you wrote about where your products come from'); end if;
  if p_data ? 'experience_info' then perform public.seller_check_text(p_data ->> 'experience_info', 1, 1000, 'What you wrote about your experience'); end if;
  if p_data ? 'returns_arrangements' then perform public.seller_check_text(p_data ->> 'returns_arrangements', 10, 1000, 'Your returns arrangements'); end if;
  if p_data ? 'customer_service_arrangements' then perform public.seller_check_text(p_data ->> 'customer_service_arrangements', 10, 1000, 'How you will look after customers'); end if;
  if p_data ? 'expected_catalogue_size' and p_data ->> 'expected_catalogue_size' is not null
     and (case when p_data ->> 'expected_catalogue_size' ~ '^[0-9]{1,6}$' then (p_data ->> 'expected_catalogue_size')::integer else -1 end) not between 1 and 100000 then
    raise exception 'The number of products must be between 1 and 100000.' using errcode = 'check_violation';
  end if;

  select * into a from public.seller_applications
   where user_id = uid and status in ('draft', 'submitted', 'under_review', 'additional_information_required') for update;
  if not found then
    -- Only a real rejection starts the waiting period. A withdrawn application is stored as 'rejected' too, but the
    -- person chose to stop, so it must not stop them starting again.
    select max(r.decided_at) into last_rejected from public.seller_applications r
     where r.user_id = uid and r.status = 'rejected'
       and not exists (select 1 from public.verification_events e
                        where e.subject_type = 'seller_application' and e.subject_id = r.id and e.event = 'withdrawn');
    if last_rejected is not null and last_rejected > now() - make_interval(days => wait_days) then
      raise exception 'You can apply again after % days from the decision.', wait_days using errcode = 'check_violation';
    end if;
    insert into public.seller_applications (user_id) values (uid) returning * into a;
    insert into public.seller_application_private (application_id) values (a.id);
    perform public.verification_log('seller_application', a.id, uid, 'created', null, 'draft', null, true);
  elsif a.status in ('submitted', 'under_review') then
    raise exception 'Your application is being reviewed and cannot be changed now.' using errcode = 'check_violation';
  end if;

  if p_data ? 'category_ids' then
    select coalesce(array_agg(distinct x::integer), '{}') into cats from jsonb_array_elements_text(p_data -> 'category_ids') x;
    if exists (select 1 from unnest(cats) c where not exists (select 1 from public.categories k where k.id = c and k.is_active)) then
      raise exception 'Choose categories from the list.' using errcode = 'check_violation';
    end if;
    if coalesce(array_length(cats, 1), 0) > 20 then
      raise exception 'Choose up to 20 categories.' using errcode = 'check_violation';
    end if;
  else
    cats := a.category_ids;
  end if;
  if p_data ? 'selling_location_id' and p_data ->> 'selling_location_id' is not null
     and not exists (select 1 from public.locations l where l.id = (p_data ->> 'selling_location_id')::integer) then
    raise exception 'Choose a selling location from the list.' using errcode = 'check_violation';
  end if;

  update public.seller_applications set
    legal_name = case when p_data ? 'legal_name' then nullif(btrim(p_data ->> 'legal_name'), '') else legal_name end,
    nationality = case when p_data ? 'nationality' then nullif(btrim(p_data ->> 'nationality'), '') else nationality end,
    is_adult = case when p_data ? 'is_adult' then (p_data ->> 'is_adult')::boolean else is_adult end,
    id_type = case when p_data ? 'id_type' then nullif(p_data ->> 'id_type', '') else id_type end,
    selling_location_id = case when p_data ? 'selling_location_id' then (p_data ->> 'selling_location_id')::integer else selling_location_id end,
    category_ids = cats,
    sourcing_type = case when p_data ? 'sourcing_type' then nullif(p_data ->> 'sourcing_type', '') else sourcing_type end,
    sourcing_info = case when p_data ? 'sourcing_info' then nullif(btrim(p_data ->> 'sourcing_info'), '') else sourcing_info end,
    experience_level = case when p_data ? 'experience_level' then nullif(p_data ->> 'experience_level', '') else experience_level end,
    experience_info = case when p_data ? 'experience_info' then nullif(btrim(p_data ->> 'experience_info'), '') else experience_info end,
    expected_catalogue_size = case when p_data ? 'expected_catalogue_size' then (p_data ->> 'expected_catalogue_size')::integer else expected_catalogue_size end,
    returns_arrangements = case when p_data ? 'returns_arrangements' then nullif(btrim(p_data ->> 'returns_arrangements'), '') else returns_arrangements end,
    customer_service_arrangements = case when p_data ? 'customer_service_arrangements' then nullif(btrim(p_data ->> 'customer_service_arrangements'), '') else customer_service_arrangements end,
    declarations = case when p_data ? 'declarations' then (p_data -> 'declarations') else declarations end
   where id = a.id;
  update public.seller_application_private set
    id_number = case when p_data ? 'id_number' then upper(nullif(btrim(p_data ->> 'id_number'), '')) else id_number end,
    residential_address = case when p_data ? 'residential_address' then nullif(btrim(p_data ->> 'residential_address'), '') else residential_address end
   where application_id = a.id;
  return a.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Closing a selling account
-- ---------------------------------------------------------------------------
create or replace function public.seller_account_close(p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  prof public.profiles;
  a public.seller_applications;
  keep integer := public.setting_numeric('retention.verification_rejected_days', 30)::integer;
  n_requested integer;
  n_confirmed integer;
  n_disputed integer;
  blockers text[] := '{}';
  removed integer := 0;
  accepted jsonb := '[]'::jsonb;
  end_status text;
  why text := left(nullif(btrim(coalesce(p_reason, '')), ''), 300);
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;

  -- One person, one closure at a time: a second tap waits here, then finds the work already done.
  select * into prof from public.profiles where id = uid for update;
  if not found then
    raise exception 'We could not find your account.' using errcode = 'no_data_found';
  end if;
  if prof.seller_status = 'none' then
    if exists (select 1 from public.seller_applications where user_id = uid and status = 'closed') then
      return; -- already closed: nothing more to do
    end if;
    raise exception 'You do not have a selling account to close.' using errcode = 'check_violation';
  end if;

  select * into a from public.seller_applications
   where user_id = uid and status in ('approved', 'suspended', 'revoked')
   order by created_at desc limit 1 for update;

  -- A revoked seller who already closed has nothing left to close.
  if prof.seller_status = 'revoked' and a.id is not null
     and exists (select 1 from public.verification_events e
                  where e.subject_type = 'seller_application' and e.subject_id = a.id and e.event = 'closed_by_seller') then
    return;
  end if;

  -- Open orders block closing. Say exactly what is open and what to do about it.
  select count(*) filter (where status = 'requested'), count(*) filter (where status = 'confirmed'), count(*) filter (where status = 'disputed')
    into n_requested, n_confirmed, n_disputed
    from public.orders
   where seller_id = uid and business_id is null and status in ('requested', 'confirmed', 'disputed');
  if n_requested > 0 then
    blockers := blockers || format('%s order request(s) waiting for your answer (accept or decline them)', n_requested);
  end if;
  if n_confirmed > 0 then
    blockers := blockers || format('%s confirmed order(s) (complete or cancel them)', n_confirmed);
  end if;
  if n_disputed > 0 then
    blockers := blockers || format('%s disputed order(s) (these finish when support settles the dispute)', n_disputed);
  end if;
  if coalesce(array_length(blockers, 1), 0) > 0 then
    raise exception 'You cannot close your selling account yet. Still open: %. Settle these first, then try again.', array_to_string(blockers, '; ')
      using errcode = 'check_violation';
  end if;

  -- Personal listings that are for sale, or paused, come off sale. Sold items keep their status. Business listings are not touched.
  update public.listings
     set status = 'removed', moderation_note = 'Removed when the seller closed their selling account.'
   where seller_id = uid and business_id is null and status in ('active', 'unavailable');
  get diagnostics removed = row_count;

  delete from public.delivery_areas where owner_user_id = uid and business_id is null;

  if prof.seller_status = 'revoked' then
    -- Selling stays revoked: that was a staff decision, and closing is not a way around it.
    end_status := 'revoked';
  else
    end_status := 'closed';
    update public.profiles set seller_status = 'none' where id = uid;
    if a.id is not null then
      update public.seller_applications set status = 'closed' where id = a.id;
    end if;
    -- The next application starts from nothing, so the agreement must be accepted again. Keep the evidence first.
    select coalesce(jsonb_agg(jsonb_build_object('version', c.version, 'accepted_at', c.accepted_at, 'application_id', c.application_id)), '[]'::jsonb)
      into accepted from public.seller_agreement_acceptances c where c.user_id = uid;
    delete from public.seller_agreement_acceptances where user_id = uid;
  end if;

  -- Verification documents go on the retention clock, shortening a longer one that approval had set.
  update public.verification_documents
     set purge_after = least(coalesce(purge_after, now() + make_interval(days => keep)), now() + make_interval(days => keep))
   where owner_id = uid and subject_type = 'seller_application' and deleted_at is null;

  if a.id is not null then
    perform public.verification_log('seller_application', a.id, uid, 'closed_by_seller', a.status, end_status, why, true);
  end if;
  perform public.write_audit('seller.account_closed', 'profile', uid::text,
    jsonb_build_object('reason', why, 'previous_status', prof.seller_status, 'listings_removed', removed,
                       'application', a.id, 'agreement_acceptances_archived', accepted));
  perform public.seller_notify(uid, coalesce(a.id, uid), 'Selling account closed',
    case when prof.seller_status = 'revoked'
         then 'Your selling account was closed. Selling stays switched off. Your orders, reviews and records are kept.'
         else 'Your selling account was closed. You can keep buying on ZedMarket, and your orders, reviews and records are kept.' end);
end;
$$;

-- Same permissions as before: signed-in people only.
revoke execute on function public.seller_check_text(text, integer, integer, text) from public, anon, authenticated;
revoke execute on function public.seller_application_mine(), public.seller_application_save(jsonb), public.seller_account_close(text) from public, anon, authenticated;
grant execute on function public.seller_application_mine(), public.seller_application_save(jsonb), public.seller_account_close(text) to authenticated;
