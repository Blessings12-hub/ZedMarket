-- ZedMarket database, part 4: row level security and grants.
--
-- Two layers protect every table:
--   1. Grants decide which columns a signed-in user may touch at all.
--   2. Policies decide which rows.
-- Anonymous visitors get nothing. The blueprint's buyer journey starts with
-- registration, so browsing needs an account.

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

alter table public.platform_settings enable row level security;
alter table public.locations enable row level security;
alter table public.categories enable row level security;
alter table public.profiles enable row level security;
alter table public.identity_verifications enable row level security;
alter table public.businesses enable row level security;
alter table public.business_members enable row level security;
alter table public.business_verifications enable row level security;
alter table public.listings enable row level security;
alter table public.listing_images enable row level security;
alter table public.favourites enable row level security;
alter table public.prohibited_terms enable row level security;
alter table public.conversations enable row level security;
alter table public.messages enable row level security;
alter table public.blocks enable row level security;
alter table public.orders enable row level security;
alter table public.reviews enable row level security;
alter table public.deliveries enable row level security;
alter table public.delivery_drivers enable row level security;
alter table public.delivery_locations enable row level security;
alter table public.delivery_events enable row level security;
alter table public.payments enable row level security;
alter table public.payment_events enable row level security;
alter table public.reports enable row level security;
alter table public.disputes enable row level security;
alter table public.dispute_evidence enable row level security;
alter table public.appeals enable row level security;
alter table public.risk_flags enable row level security;
alter table public.admin_roles enable row level security;
alter table public.admin_approvals enable row level security;
alter table public.audit_logs enable row level security;
alter table public.rate_limit_log enable row level security;

-- ---------------------------------------------------------------------------
-- Functions that policies call, and the functions the app may call directly
-- ---------------------------------------------------------------------------

grant execute on function
  public.has_staff_role(public.admin_role),
  public.is_staff(),
  public.is_business_member(uuid, public.business_member_role[]),
  public.account_can_post(),
  public.users_blocked(uuid, uuid),
  public.is_conversation_member(uuid),
  public.conversation_is_blocked(uuid),
  public.is_order_party(uuid),
  public.is_delivery_party(uuid),
  public.delivery_is_active(uuid)
to authenticated;

grant execute on function
  public.start_conversation(uuid),
  public.create_order(uuid, public.fulfilment_method),
  public.set_order_status(uuid, public.order_status, text),
  public.open_dispute(uuid, text, text),
  public.moderate_listing(uuid, public.moderation_status, text),
  public.remove_listing(uuid, text),
  public.resolve_report(uuid, public.report_status, text),
  public.staff_read_reported_conversation(uuid),
  public.set_account_state(uuid, public.account_state, text),
  public.review_identity_verification(uuid, boolean, text),
  public.review_business_verification(uuid, boolean, text),
  public.resolve_dispute(uuid, public.dispute_status, text),
  public.review_appeal(uuid, public.appeal_status, text),
  public.grant_admin_role(uuid, public.admin_role),
  public.revoke_admin_role(uuid, public.admin_role),
  public.decide_admin_approval(uuid, boolean)
to authenticated;

-- ---------------------------------------------------------------------------
-- Settings, locations, categories
-- ---------------------------------------------------------------------------

grant select, insert, update, delete on public.platform_settings to authenticated;
create policy settings_tech_admin on public.platform_settings
  for all to authenticated
  using (public.has_staff_role('tech_admin'))
  with check (public.has_staff_role('tech_admin'));

grant select on public.locations to authenticated;
create policy locations_read on public.locations for select to authenticated using (true);
grant insert, update, delete on public.locations to authenticated;
create policy locations_tech_admin on public.locations
  for all to authenticated
  using (public.has_staff_role('tech_admin'))
  with check (public.has_staff_role('tech_admin'));

grant select, insert, update, delete on public.categories to authenticated;
create policy categories_read on public.categories
  for select to authenticated using (is_active or public.is_staff());
create policy categories_staff_write on public.categories
  for all to authenticated
  using (public.has_staff_role('moderator') or public.has_staff_role('tech_admin'))
  with check (public.has_staff_role('moderator') or public.has_staff_role('tech_admin'));

-- ---------------------------------------------------------------------------
-- Profiles. Verification level and account state are not user-editable.
-- ---------------------------------------------------------------------------

grant select on public.profiles to authenticated;
grant update (display_name, bio, avatar_path, location_id) on public.profiles to authenticated;
create policy profiles_read on public.profiles for select to authenticated using (true);
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Identity and business verification
-- ---------------------------------------------------------------------------

grant select, insert (document_type, document_path) on public.identity_verifications to authenticated;
create policy identity_own_read on public.identity_verifications
  for select to authenticated
  using (user_id = (select auth.uid()) or public.has_staff_role('support'));
create policy identity_own_insert on public.identity_verifications
  for insert to authenticated
  with check (user_id = (select auth.uid()));

grant select, insert (name, slug, description, logo_path, location_id, address_text) on public.businesses to authenticated;
grant update (name, description, logo_path, location_id, address_text) on public.businesses to authenticated;
create policy businesses_read on public.businesses for select to authenticated using (true);
create policy businesses_insert on public.businesses
  for insert to authenticated
  with check (owner_id = (select auth.uid()));
create policy businesses_update on public.businesses
  for update to authenticated
  using (public.is_business_member(id, array['owner', 'manager']::public.business_member_role[]))
  with check (public.is_business_member(id, array['owner', 'manager']::public.business_member_role[]));

grant select, insert (business_id, user_id, role), delete on public.business_members to authenticated;
create policy members_read on public.business_members
  for select to authenticated
  using (user_id = (select auth.uid()) or public.is_business_member(business_id));
create policy members_add on public.business_members
  for insert to authenticated
  with check (public.is_business_member(business_id, array['owner']::public.business_member_role[]) and role <> 'owner');
create policy members_remove on public.business_members
  for delete to authenticated
  using (public.is_business_member(business_id, array['owner']::public.business_member_role[]) and role <> 'owner');

grant select, insert (business_id, registration_number, document_path) on public.business_verifications to authenticated;
create policy business_verif_read on public.business_verifications
  for select to authenticated
  using (public.is_business_member(business_id, array['owner']::public.business_member_role[])
         or public.has_staff_role('support'));
create policy business_verif_insert on public.business_verifications
  for insert to authenticated
  with check (public.is_business_member(business_id, array['owner']::public.business_member_role[]));

-- ---------------------------------------------------------------------------
-- Listings and photos
-- ---------------------------------------------------------------------------

grant select on public.listings to authenticated;
grant insert (business_id, category_id, location_id, title, description, price_zmw, condition, warranty_info, return_policy)
  on public.listings to authenticated;
grant update (business_id, category_id, location_id, title, description, price_zmw, condition, warranty_info, return_policy, status)
  on public.listings to authenticated;
grant delete on public.listings to authenticated;

create policy listings_read on public.listings
  for select to authenticated
  using (
    (status = 'active' and moderation_status = 'approved')
    or seller_id = (select auth.uid())
    or public.is_business_member(business_id)
    or public.has_staff_role('moderator')
    or public.has_staff_role('support')
  );
create policy listings_insert on public.listings
  for insert to authenticated
  with check (
    seller_id = (select auth.uid())
    and public.account_can_post()
    and (business_id is null or public.is_business_member(business_id, array['owner', 'manager', 'staff']::public.business_member_role[]))
  );
create policy listings_update on public.listings
  for update to authenticated
  using ((seller_id = (select auth.uid()) or public.is_business_member(business_id)) and status <> 'removed')
  with check (status <> 'removed' and (seller_id = (select auth.uid()) or public.is_business_member(business_id)));
create policy listings_delete_draft on public.listings
  for delete to authenticated
  using (status = 'draft' and (seller_id = (select auth.uid()) or public.is_business_member(business_id)));

grant select, insert (listing_id, storage_path, position, content_hash), update (position), delete
  on public.listing_images to authenticated;
create policy images_read on public.listing_images
  for select to authenticated
  using (exists (select 1 from public.listings l where l.id = listing_id));
create policy images_write on public.listing_images
  for insert to authenticated
  with check (exists (
    select 1 from public.listings l
     where l.id = listing_id and (l.seller_id = (select auth.uid()) or public.is_business_member(l.business_id))
  ));
create policy images_update on public.listing_images
  for update to authenticated
  using (exists (
    select 1 from public.listings l
     where l.id = listing_id and (l.seller_id = (select auth.uid()) or public.is_business_member(l.business_id))
  ));
create policy images_delete on public.listing_images
  for delete to authenticated
  using (exists (
    select 1 from public.listings l
     where l.id = listing_id and (l.seller_id = (select auth.uid()) or public.is_business_member(l.business_id))
  ));

grant select, insert (listing_id), delete on public.favourites to authenticated;
create policy favourites_own on public.favourites
  for select to authenticated using (user_id = (select auth.uid()));
create policy favourites_add on public.favourites
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy favourites_remove on public.favourites
  for delete to authenticated using (user_id = (select auth.uid()));

grant select, insert, update, delete on public.prohibited_terms to authenticated;
create policy prohibited_terms_moderators on public.prohibited_terms
  for all to authenticated
  using (public.has_staff_role('moderator'))
  with check (public.has_staff_role('moderator'));

-- ---------------------------------------------------------------------------
-- Messaging
-- ---------------------------------------------------------------------------

grant select on public.conversations to authenticated;
create policy conversations_read on public.conversations
  for select to authenticated using (public.is_conversation_member(id));

grant select, insert (conversation_id, body), update (read_at) on public.messages to authenticated;
create policy messages_read on public.messages
  for select to authenticated using (public.is_conversation_member(conversation_id));
create policy messages_send on public.messages
  for insert to authenticated
  with check (
    sender_id = (select auth.uid())
    and public.account_can_post()
    and public.is_conversation_member(conversation_id)
    and not public.conversation_is_blocked(conversation_id)
  );
create policy messages_mark_read on public.messages
  for update to authenticated
  using (public.is_conversation_member(conversation_id) and sender_id <> (select auth.uid()))
  with check (public.is_conversation_member(conversation_id) and sender_id <> (select auth.uid()));

grant select, insert (blocked_id), delete on public.blocks to authenticated;
create policy blocks_own_read on public.blocks
  for select to authenticated using (blocker_id = (select auth.uid()));
create policy blocks_add on public.blocks
  for insert to authenticated with check (blocker_id = (select auth.uid()));
create policy blocks_remove on public.blocks
  for delete to authenticated using (blocker_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Orders and reviews. Orders change only through create_order / set_order_status.
-- ---------------------------------------------------------------------------

grant select on public.orders to authenticated;
create policy orders_read on public.orders
  for select to authenticated
  using (public.is_order_party(id) or public.has_staff_role('support') or public.has_staff_role('finance'));

grant select, insert (order_id, rating, comment) on public.reviews to authenticated;
create policy reviews_read on public.reviews
  for select to authenticated using (not is_hidden or public.has_staff_role('moderator'));
create policy reviews_insert on public.reviews
  for insert to authenticated
  with check (reviewer_id = (select auth.uid()) and public.is_order_party(order_id));

grant select on public.seller_stats to authenticated;

-- ---------------------------------------------------------------------------
-- Delivery. Clients read; only trusted server code (service role) writes.
-- ---------------------------------------------------------------------------

grant select on public.deliveries to authenticated;
create policy deliveries_read on public.deliveries
  for select to authenticated
  using (public.is_delivery_party(id) or public.has_staff_role('support'));

grant select on public.delivery_drivers to authenticated;
create policy drivers_read_while_active on public.delivery_drivers
  for select to authenticated
  using (public.is_delivery_party(delivery_id) and public.delivery_is_active(delivery_id));

grant select on public.delivery_locations to authenticated;
create policy locations_read_while_active on public.delivery_locations
  for select to authenticated
  using (public.is_delivery_party(delivery_id) and public.delivery_is_active(delivery_id));

grant select on public.delivery_events to authenticated;
create policy delivery_events_read on public.delivery_events
  for select to authenticated
  using (public.is_delivery_party(delivery_id) or public.has_staff_role('support'));

-- ---------------------------------------------------------------------------
-- Payments. Read-only for the people on the order and for finance.
-- ---------------------------------------------------------------------------

grant select on public.payments to authenticated;
create policy payments_read on public.payments
  for select to authenticated
  using (public.is_order_party(order_id) or public.has_staff_role('finance'));

grant select on public.payment_events to authenticated;
create policy payment_events_finance on public.payment_events
  for select to authenticated using (public.has_staff_role('finance'));

-- ---------------------------------------------------------------------------
-- Reports, disputes, appeals, flags
-- ---------------------------------------------------------------------------

grant select, insert (target_type, target_id, reason, details) on public.reports to authenticated;
create policy reports_read on public.reports
  for select to authenticated
  using (reporter_id = (select auth.uid()) or public.has_staff_role('moderator') or public.has_staff_role('support'));
create policy reports_insert on public.reports
  for insert to authenticated with check (reporter_id = (select auth.uid()));

grant select on public.disputes to authenticated;
create policy disputes_read on public.disputes
  for select to authenticated
  using (public.is_order_party(order_id) or public.has_staff_role('support') or public.has_staff_role('finance'));

grant select, insert (dispute_id, note, storage_path) on public.dispute_evidence to authenticated;
create policy evidence_read on public.dispute_evidence
  for select to authenticated
  using (
    exists (select 1 from public.disputes d where d.id = dispute_id and public.is_order_party(d.order_id))
    or public.has_staff_role('support')
  );
create policy evidence_insert on public.dispute_evidence
  for insert to authenticated
  with check (
    uploader_id = (select auth.uid())
    and exists (select 1 from public.disputes d where d.id = dispute_id and public.is_order_party(d.order_id))
  );

grant select, insert (target_type, target_id, message) on public.appeals to authenticated;
create policy appeals_read on public.appeals
  for select to authenticated using (user_id = (select auth.uid()) or public.has_staff_role('moderator'));
create policy appeals_insert on public.appeals
  for insert to authenticated with check (user_id = (select auth.uid()));

grant select on public.risk_flags to authenticated;
create policy risk_flags_moderators on public.risk_flags
  for select to authenticated using (public.has_staff_role('moderator'));

-- ---------------------------------------------------------------------------
-- Administration
-- ---------------------------------------------------------------------------

grant select on public.admin_roles to authenticated;
create policy admin_roles_read on public.admin_roles
  for select to authenticated
  using (user_id = (select auth.uid()) or public.has_staff_role('tech_admin'));

grant select, insert (action, target_type, target_id, payload) on public.admin_approvals to authenticated;
create policy approvals_read on public.admin_approvals
  for select to authenticated using (public.is_staff());
create policy approvals_request on public.admin_approvals
  for insert to authenticated
  with check (public.is_staff() and requested_by = (select auth.uid()));

grant select on public.audit_logs to authenticated;
create policy audit_read on public.audit_logs
  for select to authenticated using (public.has_staff_role('tech_admin'));

-- rate_limit_log has RLS on and no policies, so only trusted functions can touch it.

-- ---------------------------------------------------------------------------
-- Realtime: chat messages stream to the people allowed to read them.
-- ---------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.messages;
  end if;
end;
$$;
