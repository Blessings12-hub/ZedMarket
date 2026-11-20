-- ZedMarket database, part 1: extensions, enum types and default privileges.
-- Run the migration files in numeric order.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;

-- Tables, sequences and functions start closed. Every grant is written out
-- in 0004_rls_and_grants.sql, so a new table is never exposed by accident.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;

create type public.verification_level as enum ('unverified', 'contact_verified', 'identity_verified');
create type public.account_state as enum ('active', 'restricted', 'suspended');
create type public.business_verification_status as enum ('unverified', 'pending', 'verified', 'rejected');
create type public.business_member_role as enum ('owner', 'manager', 'staff');
create type public.review_status as enum ('pending', 'approved', 'rejected');

create type public.item_condition as enum ('new', 'used_like_new', 'used_good', 'used_fair');
create type public.listing_status as enum ('draft', 'active', 'sold', 'unavailable', 'removed');
create type public.moderation_status as enum ('pending', 'approved', 'rejected');

create type public.order_status as enum ('requested', 'confirmed', 'cancelled', 'completed', 'disputed');
create type public.fulfilment_method as enum ('collection', 'delivery');

create type public.delivery_provider as enum ('yango', 'indrive', 'zedmarket');
create type public.delivery_status as enum (
  'requested', 'assigned', 'at_pickup', 'picked_up', 'in_transit', 'delivered', 'cancelled', 'failed'
);

create type public.payment_status as enum (
  'initiated', 'pending', 'verified', 'failed', 'refunded', 'partially_refunded'
);

create type public.report_target as enum ('listing', 'user', 'message', 'business', 'review');
create type public.report_reason as enum (
  'scam_or_fake', 'prohibited_item', 'counterfeit_or_stolen', 'harassment', 'wrong_details', 'other'
);
create type public.report_status as enum ('open', 'in_review', 'actioned', 'dismissed');
create type public.dispute_status as enum ('open', 'awaiting_info', 'resolved', 'rejected');
create type public.appeal_status as enum ('open', 'upheld', 'overturned');

create type public.admin_role as enum ('support', 'moderator', 'finance', 'tech_admin');
