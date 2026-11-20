-- ZedMarket database, part 3: helper functions, triggers and the audited
-- functions that staff and the app call.
--
-- Rules followed here:
--   * Anything privileged runs in a function that checks the caller's role
--     itself and writes to audit_logs. Clients never update those columns directly.
--   * Staff checks also require a second-factor session (aal2) because the
--     blueprint asks for mandatory MFA on administrator accounts.

-- ---------------------------------------------------------------------------
-- Settings helpers
-- ---------------------------------------------------------------------------

create function public.setting_numeric(p_key text, p_fallback numeric)
returns numeric
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select (s.value #>> '{}')::numeric from public.platform_settings s where s.key = p_key),
    p_fallback
  );
$$;

create function public.setting_bool(p_key text, p_fallback boolean)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select (s.value #>> '{}')::boolean from public.platform_settings s where s.key = p_key),
    p_fallback
  );
$$;

-- ---------------------------------------------------------------------------
-- Role and membership checks (used inside row level security policies)
-- ---------------------------------------------------------------------------

create function public.has_staff_role(p_role public.admin_role)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.admin_roles r
    where r.user_id = (select auth.uid()) and r.role = p_role
  ) and coalesce((select auth.jwt() ->> 'aal'), '') = 'aal2';
$$;

create function public.is_staff()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.admin_roles r where r.user_id = (select auth.uid())
  ) and coalesce((select auth.jwt() ->> 'aal'), '') = 'aal2';
$$;

create function public.is_business_member(p_business uuid, p_roles public.business_member_role[] default null)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_business is not null and exists (
    select 1 from public.business_members m
    where m.business_id = p_business
      and m.user_id = (select auth.uid())
      and (p_roles is null or m.role = any (p_roles))
  );
$$;

create function public.account_can_post()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select p.account_state = 'active' from public.profiles p where p.id = (select auth.uid())),
    false
  );
$$;

create function public.users_blocked(p_a uuid, p_b uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.blocks b
    where (b.blocker_id = p_a and b.blocked_id = p_b)
       or (b.blocker_id = p_b and b.blocked_id = p_a)
  );
$$;

create function public.is_conversation_member(p_conversation uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.conversations c
    where c.id = p_conversation
      and ((select auth.uid()) in (c.buyer_id, c.seller_id)
           or public.is_business_member(c.business_id))
  );
$$;

create function public.conversation_is_blocked(p_conversation uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.conversations c
    where c.id = p_conversation and public.users_blocked(c.buyer_id, c.seller_id)
  );
$$;

create function public.is_order_party(p_order uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.orders o
    where o.id = p_order
      and ((select auth.uid()) in (o.buyer_id, o.seller_id)
           or public.is_business_member(o.business_id))
  );
$$;

create function public.is_delivery_party(p_delivery uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.deliveries d
    where d.id = p_delivery
      and ((select auth.uid()) in (d.buyer_id, d.seller_id)
           or public.is_order_party(d.order_id))
  );
$$;

-- Driver details and live location are only visible while a delivery is in progress.
create function public.delivery_is_active(p_delivery uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.deliveries d
    where d.id = p_delivery and d.status in ('assigned', 'at_pickup', 'picked_up', 'in_transit')
  );
$$;

-- ---------------------------------------------------------------------------
-- Audit log and rate limiting
-- ---------------------------------------------------------------------------

create function public.write_audit(p_action text, p_target_type text, p_target_id text, p_metadata jsonb default '{}')
returns void
language sql security definer set search_path = ''
as $$
  insert into public.audit_logs (actor_id, action, target_type, target_id, metadata)
  values ((select auth.uid()), p_action, p_target_type, p_target_id, coalesce(p_metadata, '{}'));
$$;

create function public.enforce_rate_limit(p_action text, p_default_max integer, p_default_window_minutes integer)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  max_count integer := public.setting_numeric('rate_limit.' || p_action || '.max', p_default_max);
  window_minutes integer := public.setting_numeric('rate_limit.' || p_action || '.window_minutes', p_default_window_minutes);
begin
  if uid is null then
    return; -- trusted server-side work is not rate limited here
  end if;

  if (select count(*) from public.rate_limit_log
      where user_id = uid and action = p_action
        and created_at > now() - make_interval(mins => window_minutes)) >= max_count then
    raise exception 'You are doing that too often. Please wait a few minutes and try again.'
      using errcode = '54000';
  end if;

  insert into public.rate_limit_log (user_id, action) values (uid, p_action);
end;
$$;

-- ---------------------------------------------------------------------------
-- Generic triggers
-- ---------------------------------------------------------------------------

create function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_updated before update on public.profiles
  for each row execute function public.set_updated_at();
create trigger businesses_updated before update on public.businesses
  for each row execute function public.set_updated_at();
create trigger listings_updated before update on public.listings
  for each row execute function public.set_updated_at();
create trigger orders_updated before update on public.orders
  for each row execute function public.set_updated_at();
create trigger deliveries_updated before update on public.deliveries
  for each row execute function public.set_updated_at();
create trigger payments_updated before update on public.payments
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- New accounts
-- ---------------------------------------------------------------------------

create function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  chosen text := left(btrim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), 60);
begin
  if char_length(chosen) < 2 then
    chosen := left(split_part(coalesce(new.email, ''), '@', 1), 60);
  end if;
  if char_length(chosen) < 2 then
    chosen := 'Member ' || substr(new.id::text, 1, 6);
  end if;

  insert into public.profiles (id, display_name) values (new.id, chosen);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Phone and email both confirmed moves an account to contact_verified.
create function public.sync_contact_verification()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.email_confirmed_at is not null and new.phone_confirmed_at is not null then
    update public.profiles
       set verification_level = 'contact_verified'
     where id = new.id and verification_level = 'unverified';
  end if;
  return new;
end;
$$;

create trigger on_auth_user_confirmed
  after update of email_confirmed_at, phone_confirmed_at on auth.users
  for each row execute function public.sync_contact_verification();

-- A business owner is always a member of their own business.
create function public.add_business_owner()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.business_members (business_id, user_id, role)
  values (new.id, new.owner_id, 'owner');
  return new;
end;
$$;

create trigger businesses_add_owner
  after insert on public.businesses
  for each row execute function public.add_business_owner();

-- ---------------------------------------------------------------------------
-- Listings: publishing rules and the moderation queue
-- ---------------------------------------------------------------------------

create function public.listings_before_write()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  seller public.profiles;
  cat public.categories;
  rec record;
  needs_review boolean := false;
  publishing boolean := false;
  content_changed boolean := true;
  high_value numeric := public.setting_numeric('moderation.high_value_zmw', 10000);
  new_seller_days numeric := public.setting_numeric('moderation.new_seller_days', 30);
begin
  if tg_op = 'INSERT' then
    publishing := new.status = 'active';
  else
    publishing := new.status = 'active' and old.status is distinct from 'active';
    content_changed := (new.title, new.description, new.price_zmw, new.category_id)
                       is distinct from (old.title, old.description, old.price_zmw, old.category_id);
    if new.status = 'sold' and old.status is distinct from 'sold' then
      new.sold_at := now();
    end if;
    if not publishing and not content_changed then
      return new;
    end if;
  end if;

  select * into seller from public.profiles where id = new.seller_id;
  select * into cat from public.categories where id = new.category_id;

  if not cat.is_active then
    raise exception 'That category is not open yet.' using errcode = 'check_violation';
  end if;

  if publishing then
    if seller.account_state <> 'active' then
      raise exception 'Your account cannot publish listings right now.' using errcode = 'insufficient_privilege';
    end if;
    if public.setting_bool('listing.require_contact_verification', false)
       and seller.verification_level = 'unverified' then
      raise exception 'Verify your phone and email before publishing.' using errcode = 'insufficient_privilege';
    end if;
    if tg_op = 'INSERT' or not exists (select 1 from public.listing_images where listing_id = new.id) then
      raise exception 'Add at least one photo before publishing.' using errcode = 'check_violation';
    end if;
  end if;

  for rec in select t.term, t.action from public.prohibited_terms t where t.is_active loop
    if position(lower(rec.term) in lower(new.title || ' ' || coalesce(new.description, ''))) > 0 then
      if rec.action = 'block' then
        raise exception 'This listing looks like it breaks the prohibited items policy.'
          using errcode = 'check_violation';
      end if;
      needs_review := true;
    end if;
  end loop;

  needs_review := needs_review or cat.requires_review;

  if new.price_zmw >= high_value
     and seller.created_at > now() - make_interval(days => new_seller_days::integer) then
    needs_review := true;
  end if;

  -- A listing a moderator rejected goes back to a person if it is edited or republished.
  if tg_op = 'UPDATE' and old.moderation_status = 'rejected' then
    needs_review := true;
  end if;

  if needs_review then
    new.moderation_status := 'pending'::public.moderation_status;
  else
    new.moderation_status := 'approved'::public.moderation_status;
  end if;
  return new;
end;
$$;

create trigger listings_rules
  before insert or update on public.listings
  for each row execute function public.listings_before_write();

create function public.listings_rate_limit()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.enforce_rate_limit('listing', 20, 1440);
  return new;
end;
$$;

create trigger listings_rate before insert on public.listings
  for each row execute function public.listings_rate_limit();

create function public.listing_images_before_insert()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (select count(*) from public.listing_images where listing_id = new.listing_id) >= 10 then
    raise exception 'A listing can have up to 10 photos.' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger listing_images_limit before insert on public.listing_images
  for each row execute function public.listing_images_before_insert();

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

create function public.messages_before_insert()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.enforce_rate_limit('message', 60, 10);
  return new;
end;
$$;

create trigger messages_rate before insert on public.messages
  for each row execute function public.messages_before_insert();

create function public.messages_after_insert()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  update public.conversations set last_message_at = new.created_at where id = new.conversation_id;
  return new;
end;
$$;

create trigger messages_touch_conversation after insert on public.messages
  for each row execute function public.messages_after_insert();

-- Only the person receiving a message may mark it read, and only once.
create function public.messages_before_update()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.read_at is not null then
    new.read_at := old.read_at;
  end if;
  new.body := old.body;
  new.sender_id := old.sender_id;
  new.conversation_id := old.conversation_id;
  return new;
end;
$$;

create trigger messages_read_only before update on public.messages
  for each row execute function public.messages_before_update();

create function public.start_conversation(p_listing_id uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  l public.listings;
  conv uuid;
begin
  if uid is null then
    raise exception 'Sign in to message sellers.' using errcode = '28000';
  end if;
  if not public.account_can_post() then
    raise exception 'Your account cannot send messages right now.' using errcode = 'insufficient_privilege';
  end if;

  select * into l from public.listings
   where id = p_listing_id and status = 'active' and moderation_status = 'approved';
  if not found then
    raise exception 'This listing is not available.' using errcode = 'no_data_found';
  end if;
  if l.seller_id = uid then
    raise exception 'This is your own listing.' using errcode = 'check_violation';
  end if;
  if public.users_blocked(uid, l.seller_id) then
    raise exception 'You cannot message this seller.' using errcode = 'insufficient_privilege';
  end if;

  select id into conv from public.conversations where listing_id = l.id and buyer_id = uid;
  if conv is null then
    perform public.enforce_rate_limit('conversation', 30, 1440);
    insert into public.conversations (listing_id, buyer_id, seller_id, business_id)
    values (l.id, uid, l.seller_id, l.business_id)
    returning id into conv;
  end if;
  return conv;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reports
-- ---------------------------------------------------------------------------

create function public.reports_before_insert()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.enforce_rate_limit('report', 20, 1440);
  return new;
end;
$$;

create trigger reports_rate before insert on public.reports
  for each row execute function public.reports_before_insert();

-- Several reports on the same target raise a flag so a moderator notices the pattern.
create function public.reports_after_insert()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  open_count integer;
begin
  select count(distinct reporter_id) into open_count
    from public.reports
   where target_type = new.target_type and target_id = new.target_id and status in ('open', 'in_review');

  if open_count >= public.setting_numeric('moderation.repeat_report_threshold', 3)
     and not exists (
       select 1 from public.risk_flags f
        where f.subject_id = new.target_id and f.signal = 'repeated_reports' and f.status = 'open'
     ) then
    insert into public.risk_flags (subject_type, subject_id, signal, detail)
    values (new.target_type::text, new.target_id, 'repeated_reports', jsonb_build_object('reporters', open_count));
  end if;
  return new;
end;
$$;

create trigger reports_flag after insert on public.reports
  for each row execute function public.reports_after_insert();

-- ---------------------------------------------------------------------------
-- Orders
-- ---------------------------------------------------------------------------

create function public.create_order(p_listing_id uuid, p_fulfilment public.fulfilment_method default 'collection')
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  l public.listings;
  o public.orders;
begin
  if uid is null then
    raise exception 'Sign in to place an order.' using errcode = '28000';
  end if;
  if not public.account_can_post() then
    raise exception 'Your account cannot place orders right now.' using errcode = 'insufficient_privilege';
  end if;

  select * into l from public.listings
   where id = p_listing_id and status = 'active' and moderation_status = 'approved';
  if not found then
    raise exception 'This listing is not available.' using errcode = 'no_data_found';
  end if;
  if l.seller_id = uid then
    raise exception 'You cannot order your own listing.' using errcode = 'check_violation';
  end if;
  if public.users_blocked(uid, l.seller_id) then
    raise exception 'You cannot order from this seller.' using errcode = 'insufficient_privilege';
  end if;
  if exists (
    select 1 from public.orders
     where listing_id = l.id and buyer_id = uid and status in ('requested', 'confirmed')
  ) then
    raise exception 'You already have an open order for this item.' using errcode = 'unique_violation';
  end if;

  insert into public.orders (listing_id, buyer_id, seller_id, business_id, item_title, item_price_zmw, fulfilment)
  values (l.id, uid, l.seller_id, l.business_id, l.title, l.price_zmw, p_fulfilment)
  returning * into o;
  return o;
end;
$$;

create function public.set_order_status(p_order_id uuid, p_status public.order_status, p_reason text default null)
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  o public.orders;
  is_buyer boolean;
  is_seller boolean;
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'Order not found.' using errcode = 'no_data_found';
  end if;

  is_buyer := o.buyer_id = uid;
  is_seller := o.seller_id = uid or public.is_business_member(o.business_id);
  if not (is_buyer or is_seller) then
    raise exception 'This is not your order.' using errcode = 'insufficient_privilege';
  end if;

  if p_status = 'confirmed' and o.status = 'requested' and is_seller then
    null;
  elsif p_status = 'cancelled' and o.status in ('requested', 'confirmed') then
    null;
  elsif p_status = 'completed' and o.status = 'confirmed' and is_buyer then
    null;
  else
    raise exception 'That change is not allowed for this order.' using errcode = 'check_violation';
  end if;

  update public.orders
     set status = p_status,
         cancelled_reason = case when p_status = 'cancelled' then left(p_reason, 300) else cancelled_reason end
   where id = o.id
   returning * into o;

  if p_status = 'completed' then
    update public.listings set status = 'sold' where id = o.listing_id and status <> 'sold';
  end if;
  return o;
end;
$$;

-- A review needs a completed order, and each side can review once.
create function public.reviews_before_insert()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders;
begin
  select * into o from public.orders where id = new.order_id;
  if not found or o.status <> 'completed' then
    raise exception 'You can review an order once it is completed.' using errcode = 'check_violation';
  end if;
  if new.reviewer_id = o.buyer_id then
    new.reviewee_id := o.seller_id;
  elsif new.reviewer_id = o.seller_id then
    new.reviewee_id := o.buyer_id;
  else
    raise exception 'Only people on the order can review it.' using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

create trigger reviews_rules before insert on public.reviews
  for each row execute function public.reviews_before_insert();

create view public.seller_stats as
select
  p.id as seller_id,
  coalesce(round(avg(r.rating)::numeric, 1), 0) as average_rating,
  count(r.id)::integer as review_count,
  (select count(*) from public.orders o where o.seller_id = p.id and o.status = 'completed')::integer as completed_orders
from public.profiles p
left join public.reviews r on r.reviewee_id = p.id and not r.is_hidden
group by p.id;

-- ---------------------------------------------------------------------------
-- Disputes and appeals
-- ---------------------------------------------------------------------------

create function public.open_dispute(p_order_id uuid, p_reason text, p_details text default null)
returns public.disputes
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  o public.orders;
  d public.disputes;
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found or not public.is_order_party(p_order_id) then
    raise exception 'Order not found.' using errcode = 'no_data_found';
  end if;
  if o.status not in ('confirmed', 'completed') then
    raise exception 'A dispute can only be opened on a confirmed or completed order.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.disputes where order_id = o.id and status in ('open', 'awaiting_info')) then
    raise exception 'There is already an open dispute for this order.' using errcode = 'unique_violation';
  end if;

  insert into public.disputes (order_id, opened_by, reason, details)
  values (o.id, uid, p_reason, p_details)
  returning * into d;

  update public.orders set status = 'disputed' where id = o.id;
  return d;
end;
$$;

-- ---------------------------------------------------------------------------
-- Staff actions. Each one checks the role, then writes to the audit log.
-- ---------------------------------------------------------------------------

create function public.moderate_listing(p_listing_id uuid, p_decision public.moderation_status, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('moderator') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;

  update public.listings
     set moderation_status = p_decision,
         moderation_note = left(p_note, 500)
   where id = p_listing_id;
  if not found then
    raise exception 'Listing not found.' using errcode = 'no_data_found';
  end if;

  perform public.write_audit('listing.moderated', 'listing', p_listing_id::text,
    jsonb_build_object('decision', p_decision, 'note', p_note));
end;
$$;

create function public.remove_listing(p_listing_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('moderator') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;

  update public.listings
     set status = 'removed', moderation_status = 'rejected', moderation_note = left(p_reason, 500)
   where id = p_listing_id;
  if not found then
    raise exception 'Listing not found.' using errcode = 'no_data_found';
  end if;

  perform public.write_audit('listing.removed', 'listing', p_listing_id::text, jsonb_build_object('reason', p_reason));
end;
$$;

create function public.resolve_report(p_report_id uuid, p_status public.report_status, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not (public.has_staff_role('moderator') or public.has_staff_role('support')) then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;

  update public.reports
     set status = p_status, decision_note = left(p_note, 500),
         reviewed_by = (select auth.uid()), reviewed_at = now()
   where id = p_report_id;
  if not found then
    raise exception 'Report not found.' using errcode = 'no_data_found';
  end if;

  perform public.write_audit('report.resolved', 'report', p_report_id::text,
    jsonb_build_object('status', p_status, 'note', p_note));
end;
$$;

-- Staff do not have a standing right to read private messages. This opens the
-- conversation behind one reported message and records that someone looked.
create function public.staff_read_reported_conversation(p_report_id uuid)
returns setof public.messages
language plpgsql security definer set search_path = ''
as $$
declare
  r public.reports;
  conv uuid;
begin
  if not public.has_staff_role('moderator') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;

  select * into r from public.reports where id = p_report_id and target_type = 'message';
  if not found then
    raise exception 'That report is not about a message.' using errcode = 'no_data_found';
  end if;

  select conversation_id into conv from public.messages where id = r.target_id;
  if conv is null then
    raise exception 'Message not found.' using errcode = 'no_data_found';
  end if;

  perform public.write_audit('conversation.read_for_report', 'conversation', conv::text,
    jsonb_build_object('report_id', p_report_id));

  return query select * from public.messages where conversation_id = conv order by created_at;
end;
$$;

create function public.set_account_state(p_user uuid, p_state public.account_state, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('moderator') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if p_user = (select auth.uid()) then
    raise exception 'You cannot change your own account state.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A reason is required.' using errcode = 'check_violation';
  end if;

  update public.profiles set account_state = p_state where id = p_user;
  if not found then
    raise exception 'User not found.' using errcode = 'no_data_found';
  end if;

  perform public.write_audit('account.state_changed', 'user', p_user::text,
    jsonb_build_object('state', p_state, 'reason', p_reason));
end;
$$;

create function public.review_identity_verification(p_id uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v public.identity_verifications;
  keep_days integer := public.setting_numeric('retention.identity_documents_days', 30);
begin
  if not public.has_staff_role('support') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;

  update public.identity_verifications
     set status = case when p_approve then 'approved'::public.review_status else 'rejected'::public.review_status end,
         reviewed_by = (select auth.uid()), reviewed_at = now(),
         reviewer_note = left(p_note, 500),
         purge_after = now() + make_interval(days => keep_days)
   where id = p_id and status = 'pending'
   returning * into v;
  if not found then
    raise exception 'No pending request with that id.' using errcode = 'no_data_found';
  end if;

  if p_approve then
    update public.profiles set verification_level = 'identity_verified' where id = v.user_id;
  end if;

  perform public.write_audit('identity.reviewed', 'user', v.user_id::text, jsonb_build_object('approved', p_approve));
end;
$$;

create function public.review_business_verification(p_id uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v public.business_verifications;
begin
  if not public.has_staff_role('support') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;

  update public.business_verifications
     set status = case when p_approve then 'approved'::public.review_status else 'rejected'::public.review_status end,
         reviewed_by = (select auth.uid()), reviewed_at = now(), reviewer_note = left(p_note, 500)
   where id = p_id and status = 'pending'
   returning * into v;
  if not found then
    raise exception 'No pending request with that id.' using errcode = 'no_data_found';
  end if;

  update public.businesses
     set verification_status = case when p_approve then 'verified'::public.business_verification_status
                                    else 'rejected'::public.business_verification_status end
   where id = v.business_id;

  perform public.write_audit('business.reviewed', 'business', v.business_id::text, jsonb_build_object('approved', p_approve));
end;
$$;

-- Moves a business to "pending" as soon as registration details are submitted.
create function public.business_verification_submitted()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  update public.businesses set verification_status = 'pending' where id = new.business_id;
  return new;
end;
$$;

create trigger business_verifications_submitted after insert on public.business_verifications
  for each row execute function public.business_verification_submitted();

create function public.resolve_dispute(p_dispute_id uuid, p_status public.dispute_status, p_outcome text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('support') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;

  update public.disputes
     set status = p_status, outcome = left(p_outcome, 1000),
         resolved_by = (select auth.uid()),
         resolved_at = case when p_status in ('resolved', 'rejected') then now() else null end
   where id = p_dispute_id;
  if not found then
    raise exception 'Dispute not found.' using errcode = 'no_data_found';
  end if;

  perform public.write_audit('dispute.updated', 'dispute', p_dispute_id::text,
    jsonb_build_object('status', p_status, 'outcome', p_outcome));
end;
$$;

create function public.review_appeal(p_appeal_id uuid, p_status public.appeal_status, p_note text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('moderator') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;

  update public.appeals
     set status = p_status, reviewer_note = left(p_note, 500),
         reviewed_by = (select auth.uid()), reviewed_at = now()
   where id = p_appeal_id;
  if not found then
    raise exception 'Appeal not found.' using errcode = 'no_data_found';
  end if;

  perform public.write_audit('appeal.reviewed', 'appeal', p_appeal_id::text, jsonb_build_object('status', p_status));
end;
$$;

create function public.grant_admin_role(p_user uuid, p_role public.admin_role)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('tech_admin') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;

  insert into public.admin_roles (user_id, role, granted_by)
  values (p_user, p_role, (select auth.uid()))
  on conflict do nothing;

  perform public.write_audit('admin_role.granted', 'user', p_user::text, jsonb_build_object('role', p_role));
end;
$$;

create function public.revoke_admin_role(p_user uuid, p_role public.admin_role)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('tech_admin') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if p_user = (select auth.uid()) and p_role = 'tech_admin' then
    raise exception 'You cannot remove your own technical admin role.' using errcode = 'check_violation';
  end if;

  delete from public.admin_roles where user_id = p_user and role = p_role;
  perform public.write_audit('admin_role.revoked', 'user', p_user::text, jsonb_build_object('role', p_role));
end;
$$;

-- High-impact actions are requested by one staff member and approved by another.
create function public.decide_admin_approval(p_id uuid, p_approve boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('tech_admin') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;

  update public.admin_approvals
     set status = case when p_approve then 'approved' else 'rejected' end,
         approved_by = (select auth.uid()), decided_at = now()
   where id = p_id and status = 'pending' and requested_by <> (select auth.uid());
  if not found then
    raise exception 'Nothing to decide, or you requested this yourself.' using errcode = 'check_violation';
  end if;

  perform public.write_audit('admin_approval.decided', 'admin_approval', p_id::text, jsonb_build_object('approved', p_approve));
end;
$$;

-- ---------------------------------------------------------------------------
-- Retention. Schedule this with pg_cron or a scheduled edge function.
-- The periods come from platform_settings and still need to be agreed.
-- ---------------------------------------------------------------------------

create function public.purge_expired_data()
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  delete from public.delivery_locations
   where recorded_at < now() - make_interval(days => public.setting_numeric('retention.delivery_locations_days', 7)::integer);

  delete from public.rate_limit_log where created_at < now() - interval '2 days';

  -- Identity document files are not deleted here. A scheduled edge function reads
  -- rows where purge_after has passed, removes the file from storage, then clears document_path.
end;
$$;
