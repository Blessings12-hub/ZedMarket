-- 0025: let a person delete their own selling account, and an owner delete their business.
--
-- Rules
--   * Deleting a selling account switches seller_status back to 'none'. The person is a plain buyer again and must apply
--     and be verified by the team from the start: new application, new documents, new agreement acceptance.
--   * Only an approved seller can do it. A suspended or revoked seller cannot: that is a staff decision, and deleting
--     would let someone walk away from it. They ask support for a review instead.
--   * Deleting a business removes it for good. To sell as a business again the owner registers it again and it goes
--     through business verification again. Only the owner can do it.
--   * Neither can happen while there are open orders (requested, confirmed or disputed): finish or cancel them first.
--   * Listings are taken off sale. Order history, reviews and the verification history stay. Documents are scheduled
--     for deletion using the same retention setting as a rejected application.

-- A new final state for an application whose owner closed their selling account. It is not "rejected", so it does not
-- start the re-apply waiting period, and it appears in no staff queue.
alter table public.seller_applications drop constraint seller_applications_status_check;
alter table public.seller_applications add constraint seller_applications_status_check
  check (status = any (array['draft', 'submitted', 'under_review', 'additional_information_required', 'approved', 'rejected', 'suspended', 'revoked', 'closed']));

create function public.seller_account_close(p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  prof public.profiles;
  a public.seller_applications;
  keep integer := public.setting_numeric('retention.verification_rejected_days', 30)::integer;
  open_orders integer;
  removed integer;
  why text := left(nullif(btrim(coalesce(p_reason, '')), ''), 300);
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;

  select * into prof from public.profiles where id = uid for update;
  if prof.seller_status = 'none' then
    raise exception 'You do not have a selling account to delete.' using errcode = 'check_violation';
  end if;
  if prof.seller_status <> 'active' then
    raise exception 'Your selling account was paused by our team, so it cannot be deleted here. Ask support to review it.' using errcode = 'check_violation';
  end if;

  select count(*) into open_orders from public.orders
   where seller_id = uid and business_id is null and status in ('requested', 'confirmed', 'disputed');
  if open_orders > 0 then
    raise exception 'Finish or cancel your % open order(s) first, then delete your selling account.', open_orders using errcode = 'check_violation';
  end if;

  -- Take every personal listing off sale. Business listings belong to the business and are not touched here.
  update public.listings
     set status = 'removed', moderation_note = 'Removed when the seller deleted their selling account.'
   where seller_id = uid and business_id is null and status <> 'removed';
  get diagnostics removed = row_count;

  delete from public.delivery_areas where owner_user_id = uid and business_id is null;

  -- Back to a buyer. The approved application is closed so a new one can be started straight away.
  update public.profiles set seller_status = 'none' where id = uid;
  select * into a from public.seller_applications where user_id = uid and status in ('approved', 'suspended') for update;
  if found then
    update public.seller_applications set status = 'closed' where id = a.id;
    perform public.verification_log('seller_application', a.id, uid, 'closed_by_seller', a.status, 'closed', why, true);
  end if;

  -- The next application starts from nothing: documents go on the retention clock and the agreement must be accepted again.
  update public.verification_documents set purge_after = now() + make_interval(days => keep)
   where owner_id = uid and subject_type = 'seller_application' and purge_after is null;
  delete from public.seller_agreement_acceptances where user_id = uid;

  perform public.write_audit('seller.account_closed', 'profile', uid::text,
    jsonb_build_object('reason', why, 'listings_removed', removed, 'application', a.id));
end;
$$;

create function public.business_close(p_business uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  b public.businesses;
  keep integer := public.setting_numeric('retention.verification_rejected_days', 30)::integer;
  open_orders integer;
  removed integer;
  why text := left(nullif(btrim(coalesce(p_reason, '')), ''), 300);
begin
  if uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;

  select * into b from public.businesses where id = p_business for update;
  if not found then
    raise exception 'That business was not found.' using errcode = 'no_data_found';
  end if;
  if b.owner_id <> uid and not public.is_business_member(p_business, array['owner']::public.business_member_role[]) then
    raise exception 'Only the owner can delete a business.' using errcode = 'insufficient_privilege';
  end if;

  select count(*) into open_orders from public.orders
   where business_id = p_business and status in ('requested', 'confirmed', 'disputed');
  if open_orders > 0 then
    raise exception 'Finish or cancel the % open order(s) first, then delete the business.', open_orders using errcode = 'check_violation';
  end if;

  -- Listings go off sale first. Without this they would turn into personal listings when the business row disappears.
  -- The branch is cleared too, because a listing with a branch must belong to a business.
  update public.listings
     set branch_id = null, status = 'removed', moderation_note = 'Removed when the business was deleted.'
   where business_id = p_business and (status <> 'removed' or branch_id is not null);
  get diagnostics removed = row_count;

  -- Verification documents go on the retention clock. The history of what happened is kept.
  update public.verification_documents set purge_after = now() + make_interval(days => keep)
   where subject_type = 'business_application' and purge_after is null
     and (subject_id = p_business or subject_id in (select v.id from public.business_verifications v where v.business_id = p_business));
  perform public.verification_log('business_application', p_business, uid, 'business_deleted', b.verification_status::text, null, why, true);
  perform public.write_audit('business.deleted', 'business', p_business::text,
    jsonb_build_object('name', b.name, 'slug', b.slug, 'was', b.verification_status, 'reason', why, 'listings_removed', removed));

  -- Members, invitations, branches, catalogues, stock, delivery places and verification requests go with it.
  -- Orders, chats and reviews stay, no longer tied to a business.
  delete from public.businesses where id = p_business;
end;
$$;

revoke execute on function public.seller_account_close(text), public.business_close(uuid, text) from public, anon, authenticated;
grant execute on function public.seller_account_close(text), public.business_close(uuid, text) to authenticated;
