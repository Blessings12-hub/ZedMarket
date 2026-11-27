-- 0026: small hardening found by the Supabase advisors.
--   * set_updated_at had a role-mutable search_path. It only calls now(), so locking it changes nothing for callers.
--   * Foreign keys the app filters or joins on had no index. Harmless while the tables are small, slow once they are not
--     (member lookups run inside row-level-security checks on every request). Each index is created only if missing.

alter function public.set_updated_at() set search_path = '';

create index if not exists business_members_user_fk_idx on public.business_members (user_id);
create index if not exists businesses_owner_fk_idx on public.businesses (owner_id);
create index if not exists business_branches_location_fk_idx on public.business_branches (location_id);
create index if not exists listings_business_fk_idx on public.listings (business_id);
create index if not exists orders_branch_fk_idx on public.orders (branch_id);
create index if not exists conversations_buyer_fk_idx on public.conversations (buyer_id);
create index if not exists conversations_seller_fk_idx on public.conversations (seller_id);
create index if not exists conversations_business_fk_idx on public.conversations (business_id);
create index if not exists messages_sender_fk_idx on public.messages (sender_id);
create index if not exists reviews_reviewee_fk_idx on public.reviews (reviewee_id);
create index if not exists reviews_reviewer_fk_idx on public.reviews (reviewer_id);
create index if not exists appeals_user_fk_idx on public.appeals (user_id);
create index if not exists reports_reporter_fk_idx on public.reports (reporter_id);
create index if not exists disputes_order_fk_idx on public.disputes (order_id);
create index if not exists disputes_opened_by_fk_idx on public.disputes (opened_by);
create index if not exists dispute_evidence_dispute_fk_idx on public.dispute_evidence (dispute_id);
create index if not exists listing_alerts_listing_fk_idx on public.listing_alerts (listing_id);
create index if not exists verification_documents_owner_fk_idx on public.verification_documents (owner_id);
create index if not exists deliveries_buyer_fk_idx on public.deliveries (buyer_id);
create index if not exists deliveries_seller_fk_idx on public.deliveries (seller_id);
create index if not exists support_tickets_order_fk_idx on public.support_tickets (order_id);
create index if not exists stock_movements_business_fk_idx on public.stock_movements (business_id);
create index if not exists stock_movements_order_fk_idx on public.stock_movements (order_id);
create index if not exists product_import_jobs_created_by_fk_idx on public.product_import_jobs (created_by);
create index if not exists profiles_location_fk_idx on public.profiles (location_id);
create index if not exists delivery_areas_location_fk_idx on public.delivery_areas (location_id);
create index if not exists saved_searches_category_fk_idx on public.saved_searches (category_id);
create index if not exists saved_searches_location_fk_idx on public.saved_searches (location_id);
