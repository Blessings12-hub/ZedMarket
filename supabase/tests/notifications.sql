-- Notifications (migration 0012): which events notify whom, duplicate-event prevention, unread counts,
-- preferences, push tokens, and the delivery queue (leases, retries, dead letters).
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/notifications.sql

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

create function zm_test.act_as_service() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  execute 'set local role service_role';
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



insert into auth.users (id, email, phone, raw_user_meta_data, email_confirmed_at, phone_confirmed_at) values
  ('00000000-0000-0000-0000-00000000000a', 'seller@example.test', '+260971000001', '{"display_name":"Seller Sam"}', now(), now()),
  ('00000000-0000-0000-0000-00000000000b', 'buyer@example.test',  null,            '{"display_name":"Buyer Bwalya"}', now(), null),
  ('00000000-0000-0000-0000-00000000000c', 'third@example.test',  null,            '{"display_name":"Third Thandi"}', now(), null),
  ('00000000-0000-0000-0000-00000000000e', 'support@example.test', null,           '{"display_name":"Support Sue"}', now(), null),
  ('00000000-0000-0000-0000-000000000001', 'mod@example.test',    null,            '{"display_name":"Moderator Mo"}', now(), null),
  ('00000000-0000-0000-0000-00000000000d', 'manager@example.test', null,           '{"display_name":"Manager Mwila"}', now(), null),
  ('00000000-0000-0000-0000-00000000000f', 'staff@example.test',   null,           '{"display_name":"Staff Sipho"}', now(), null);
insert into public.admin_roles (user_id, role) values
  ('00000000-0000-0000-0000-00000000000e', 'support'),
  ('00000000-0000-0000-0000-000000000001', 'moderator');
insert into public.businesses (id, owner_id, name, slug) values
  ('20000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000a', 'Sam Shop', 'sam-shop');
insert into public.business_members (business_id, user_id, role) values
  ('20000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000d', 'manager'),
  ('20000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000f', 'staff');

-- Listings are written directly (the posting flow is covered by trust_flows.sql).
create function zm_test.fresh_listing(p_price numeric default 500, p_business uuid default null) returns uuid
language plpgsql as $$
declare
  new_id uuid;
begin
  insert into public.listings (seller_id, business_id, category_id, location_id, title, description, price_zmw, condition, status, moderation_status)
  select '00000000-0000-0000-0000-00000000000a', p_business, c.id, l.id,
         'Item ' || substr(gen_random_uuid()::text, 1, 8), 'Test item', p_price, 'used_good', 'draft', 'pending'
    from public.categories c, public.locations l
   where c.slug = 'electronics' and l.area = 'Kabulonga'
  returning id into new_id;
  insert into public.listing_images (listing_id, storage_path, position) values (new_id, 'x/' || new_id || '.jpg', 0);
  update public.listings set status = 'active' where id = new_id;
  update public.listings set moderation_status = 'approved' where id = new_id;
  return new_id;
end $$;



create function zm_test.count_for(p_user uuid, p_type text default null) returns text language sql as $$
  select count(*)::text from public.notifications where user_id = p_user and (p_type is null or type = p_type);
$$;
create function zm_test.did() returns bigint language sql security definer as $$
  select id from public.notification_deliveries order by id desc limit 1;
$$;
create temp table zm_ids (name text primary key, id uuid);
grant all on zm_ids to anon, authenticated, service_role;
grant execute on all functions in schema zm_test to anon, authenticated, service_role;

\set S '00000000-0000-0000-0000-00000000000a'
\set B '00000000-0000-0000-0000-00000000000b'
\set C '00000000-0000-0000-0000-00000000000c'
\set SUP '00000000-0000-0000-0000-00000000000e'
\set MOD '00000000-0000-0000-0000-000000000001'
\set MGR '00000000-0000-0000-0000-00000000000d'
\set BIZ '20000000-0000-0000-0000-00000000000a'

-- 1. Orders create notifications for the right people
select zm_test.act_as_admin();
insert into zm_ids values ('l1', zm_test.fresh_listing(500));
select zm_test.act_as(:'B');
insert into zm_ids values ('o1', (public.create_order((select id from zm_ids where name = 'l1'))).id);
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.count_for(:'S', 'order.requested'), '1', 'the seller hears about the request');
select zm_test.expect_equal(zm_test.count_for(:'B'), '0', 'the buyer is not told about their own request');
select zm_test.expect_equal((select title || '|' || link from public.notifications where user_id = :'S'), 'New order request|/order/' || (select id from zm_ids where name = 'o1'), 'title and deep link');
select zm_test.act_as(:'S');
select public.confirm_order((select id from zm_ids where name = 'o1'), 0);
select public.mark_handed_over((select id from zm_ids where name = 'o1'));
select zm_test.act_as(:'B');
select public.complete_order((select id from zm_ids where name = 'o1'));
select zm_test.act_as_admin();
select zm_test.expect_equal((select string_agg(type, ',' order by created_at, type) from public.notifications where user_id = :'B'), 'order.confirmed,order.handed_over', 'buyer: confirmed and handed over');
select zm_test.expect_equal(zm_test.count_for(:'S'), '2', 'seller: request and completion');
select zm_test.expect_equal(zm_test.count_for(:'S', 'order.completed'), '1', 'seller hears about completion');

-- 2. Duplicate events are dropped
select zm_test.expect_equal((select public.notify(:'C', 'orders', 'order.test', 'Hello', null, '/orders', 'same-key') is not null)::text, 'true', 'first notification is created');
select zm_test.expect_equal((select public.notify(:'C', 'orders', 'order.test', 'Hello', null, '/orders', 'same-key') is null)::text, 'true', 'the same event again is dropped');
select zm_test.expect_equal(zm_test.count_for(:'C', 'order.test'), '1', 'only one row');
select zm_test.expect_error(format($$insert into public.notifications (user_id, category, type, title, link, dedupe_key) values (%L, 'orders', 'order.test', 'x', 'https://evil.example', 'bad-link')$$, :'C'), 'a link that is not an app path');
select zm_test.expect_error(format($$insert into public.notifications (user_id, category, type, title, link, dedupe_key) values (%L, 'orders', 'order.test', 'x', '/../admin', 'bad-link2')$$, :'C'), 'a link that climbs out');

-- 3. Reading: own rows only, unread counts, marking read
select zm_test.act_as_guest();
select zm_test.expect_error($$select * from public.notifications$$, 'a guest reading notifications');
select zm_test.act_as(:'S');
select zm_test.expect_equal((select count(*)::text from public.notifications), '2', 'the seller sees only their own');
select zm_test.expect_equal((select public.unread_notification_count())::text, '2', 'two unread');
select zm_test.expect_error($$update public.notifications set read_at = now()$$, 'updating notifications directly');
select zm_test.expect_error($$delete from public.notifications$$, 'deleting notifications directly');
select zm_test.expect_equal((select public.mark_notifications_read(array[(select id from public.notifications where type = 'order.requested')]))::text, '1', 'one marked read');
select zm_test.expect_equal((select public.unread_notification_count())::text, '1', 'one left');
select zm_test.act_as(:'B');
select zm_test.expect_equal((select public.mark_notifications_read(array[(select id from zm_ids where false)]))::text, '0', 'nothing to mark');
select zm_test.act_as_admin();
insert into zm_ids select 'seller_note', id from public.notifications where user_id = :'S' and type = 'order.completed';
select zm_test.act_as(:'B');
select zm_test.expect_equal((select public.mark_notifications_read(array[(select id from zm_ids where name = 'seller_note')]))::text, '0', 'cannot mark someone else''s notification');
select zm_test.expect_equal((select public.mark_all_notifications_read('messages'))::text, '0', 'mark all in another category does nothing');
select zm_test.expect_equal((select public.mark_all_notifications_read())::text, '2', 'mark all');
select zm_test.expect_equal((select public.unread_notification_count())::text, '0', 'zero unread');
select zm_test.act_as(:'S');
select zm_test.expect_equal((select public.unread_notification_count())::text, '1', 'the seller''s count is not affected');

-- 4. Preferences
select zm_test.act_as(:'B');
select zm_test.expect_equal((select string_agg(category || ':' || in_app::text || push::text || email::text || sms::text, ',') from public.my_notification_settings()), 'orders:truetruefalsefalse,messages:truetruefalsefalse,alerts:truetruefalsefalse,listings:truetruefalsefalse,business:truetruefalsefalse,account:truetruefalsefalse', 'defaults');
select zm_test.expect_error($$select public.set_notification_preference('account', false, true, false, false)$$, 'muting account notices');
select zm_test.expect_error($$select public.set_notification_preference('account', true, false, false, false)$$, 'turning off account push');
select zm_test.expect_error($$select public.set_notification_preference('weather', true, true, false, false)$$, 'unknown category');
select public.set_notification_preference('orders', false, true, false, false);
select zm_test.expect_equal((select in_app::text from public.my_notification_settings() where category = 'orders'), 'false', 'the setting is saved');
select zm_test.act_as_admin();
select zm_test.expect_equal((select public.notify(:'B', 'orders', 'order.test', 'Muted', null, null, 'muted-1') is null)::text, 'true', 'a muted category makes no notification');
select zm_test.expect_equal((select public.notify(:'B', 'account', 'account.test', 'Cannot mute', null, null, 'acc-1') is not null)::text, 'true', 'account notices always arrive');
select zm_test.act_as(:'B');
select public.set_notification_preference('orders', true, true, false, false);
select zm_test.act_as_guest();
select zm_test.expect_error($$select public.set_notification_preference('orders', true, true, false, false)$$, 'a guest saving preferences');
select zm_test.act_as(:'B');
select zm_test.expect_equal((select public.notification_channels()::text), '{"sms": false, "push": true, "email": false}', 'only push is live by default');

-- Email and SMS: nothing is queued while the provider switches are off
select public.set_notification_preference('orders', true, true, true, true);
select zm_test.act_as_admin();
select public.notify(:'B', 'orders', 'order.test', 'Email me', null, null, 'email-1');
select zm_test.expect_equal((select count(*)::text from public.notification_deliveries where channel in ('email', 'sms')), '0', 'email and sms are not queued while switched off');
update public.platform_settings set value = '1' where key in ('notifications.email_enabled', 'notifications.sms_enabled');
select public.notify(:'B', 'orders', 'order.test', 'Email me 2', null, null, 'email-2');
select zm_test.expect_equal((select count(*)::text from public.notification_deliveries where channel = 'email'), '1', 'email is queued once the switch is on');
select zm_test.expect_equal((select count(*)::text from public.notification_deliveries where channel = 'sms'), '0', 'no sms: the buyer has no confirmed phone');
select zm_test.act_as(:'S');
select public.set_notification_preference('orders', true, true, false, true);
select zm_test.act_as_admin();
select public.notify(:'S', 'orders', 'order.test', 'Text me', null, null, 'sms-1');
select zm_test.expect_equal((select count(*)::text from public.notification_deliveries d join public.notifications n on n.id = d.notification_id where d.channel = 'sms' and n.user_id = :'S'), '1', 'sms queued for a confirmed phone');
update auth.users set phone = '+260971000002' where id = :'B';
select public.notify(:'B', 'orders', 'order.test', 'Text me too', null, null, 'sms-2');
select zm_test.expect_equal((select count(*)::text from public.notification_deliveries d join public.notifications n on n.id = d.notification_id where d.channel = 'sms' and n.user_id = :'B'), '0', 'an unconfirmed phone gets no sms');
update public.platform_settings set value = '0' where key in ('notifications.email_enabled', 'notifications.sms_enabled');

-- 5. Push tokens
select zm_test.act_as_guest();
select zm_test.expect_error($$select public.register_push_token('ExponentPushToken[aaaaaaaaaaaaaaa]', 'android')$$, 'a guest registering a token');
select zm_test.act_as(:'B');
select zm_test.expect_error($$select public.register_push_token('short', 'android')$$, 'a token that is too short');
select zm_test.expect_error($$select public.register_push_token('ExponentPushToken[aaaaaaaaaaaaaaa]', 'toaster')$$, 'unknown platform');
select public.register_push_token('ExponentPushToken[aaaaaaaaaaaaaaa]', 'android');
select public.register_push_token('ExponentPushToken[bbbbbbbbbbbbbbb]', 'ios');
select public.register_push_token('ExponentPushToken[aaaaaaaaaaaaaaa]', 'android');
select zm_test.expect_error($$select * from public.push_tokens$$, 'reading tokens directly');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.push_tokens where user_id = :'B' and disabled_at is null), '2', 'registering the same token twice keeps one row');
-- one notification for the buyer now creates one delivery per live token
select public.notify(:'B', 'orders', 'order.test', 'Push me', 'body', '/orders', 'push-1');
select zm_test.expect_equal((select count(*)::text from public.notification_deliveries d join public.notifications n on n.id = d.notification_id where n.dedupe_key = 'push-1' and d.channel = 'push'), '2', 'one push per live token');
select public.notify(:'B', 'orders', 'order.test', 'Push me', 'body', '/orders', 'push-1');
select zm_test.expect_equal((select count(*)::text from public.notification_deliveries d join public.notifications n on n.id = d.notification_id where n.dedupe_key = 'push-1'), '2', 'a repeated event makes no extra deliveries');
-- the 11th token switches off the oldest
select zm_test.act_as(:'B');
select public.register_push_token('ExponentPushToken[' || repeat(chr(97 + i), 15) || ']', 'android') from generate_series(2, 11) i;
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.push_tokens where user_id = :'B' and disabled_at is null), '10', 'at most ten live tokens');
-- a phone passed to another account moves the token
select zm_test.act_as(:'C');
select public.register_push_token('ExponentPushToken[zzzzzzzzzzzzzzz]', 'android');
select zm_test.act_as(:'B');
select public.register_push_token('ExponentPushToken[zzzzzzzzzzzzzzz]', 'android');
select zm_test.act_as_admin();
select zm_test.expect_equal((select user_id::text from public.push_tokens where token = 'ExponentPushToken[zzzzzzzzzzzzzzz]'), :'B', 'the token belongs to whoever registered last');
select zm_test.act_as(:'C');
select public.unregister_push_token('ExponentPushToken[zzzzzzzzzzzzzzz]');
select zm_test.act_as_admin();
select zm_test.expect_equal((select (disabled_at is null)::text from public.push_tokens where token = 'ExponentPushToken[zzzzzzzzzzzzzzz]'), 'true', 'you cannot switch off someone else''s token');
select zm_test.act_as(:'B');
select public.unregister_push_token('ExponentPushToken[zzzzzzzzzzzzzzz]');
select zm_test.act_as_admin();
select zm_test.expect_equal((select (disabled_at is not null)::text from public.push_tokens where token = 'ExponentPushToken[zzzzzzzzzzzzzzz]'), 'true', 'you can switch off your own');

-- 6. The delivery queue
delete from public.notification_deliveries;
delete from public.push_tokens;
select zm_test.act_as(:'B');
select public.register_push_token('ExponentPushToken[queue00000000001]', 'android');
select zm_test.act_as_admin();
select public.notify(:'B', 'orders', 'order.test', 'Queue 1', 'body1', '/orders', 'q-1');
select zm_test.act_as(:'B');
select zm_test.expect_error($$select * from public.claim_notification_deliveries()$$, 'an app user claiming deliveries');
select zm_test.expect_error($$select public.report_notification_delivery(1, true)$$, 'an app user reporting a delivery');
select zm_test.expect_error($$select public.purge_old_notifications()$$, 'an app user purging');
select zm_test.act_as_guest();
select zm_test.expect_error($$select * from public.claim_notification_deliveries()$$, 'a guest claiming deliveries');
select zm_test.act_as_service();
select zm_test.expect_equal((select count(*)::text from public.claim_notification_deliveries()), '1', 'the worker gets the due delivery');
select zm_test.expect_equal((select count(*)::text from public.claim_notification_deliveries()), '0', 'a leased delivery is not handed out twice');
select zm_test.act_as_admin();
select zm_test.expect_equal((select status || ':' || attempts::text from public.notification_deliveries), 'sending:1', 'leased');
select zm_test.act_as_service();
select zm_test.expect_equal((select public.report_notification_delivery(zm_test.did(), false, 'Expo said no'))::text, 'failed', 'a failure is queued for retry');
select zm_test.expect_equal((select count(*)::text from public.claim_notification_deliveries()), '0', 'not due yet');
select zm_test.expect_equal((select public.report_notification_delivery(zm_test.did(), true))::text, 'ignored', 'reporting a delivery that is not leased is ignored');
select zm_test.act_as_admin();
select zm_test.expect_equal((select (next_attempt_at > now() + interval '30 seconds')::text from public.notification_deliveries), 'true', 'back-off: first retry is about a minute away');
-- Walk it through the remaining attempts: waits grow, then it is marked dead
update public.notification_deliveries set next_attempt_at = now() - interval '1 second';
select zm_test.act_as_service();
select zm_test.expect_equal((select count(*)::text from public.claim_notification_deliveries()), '1', 'due again after the wait');
select zm_test.expect_equal((select public.report_notification_delivery(zm_test.did(), false, 'again'))::text, 'failed', 'second failure');
select zm_test.act_as_admin();
select zm_test.expect_equal((select (next_attempt_at > now() + interval '4 minutes')::text from public.notification_deliveries), 'true', 'second wait is about five minutes');
update public.notification_deliveries set next_attempt_at = now() - interval '1 second';
select zm_test.act_as_service();
select count(*) from public.claim_notification_deliveries();
select public.report_notification_delivery(zm_test.did(), false, '3');
select zm_test.act_as_admin();
update public.notification_deliveries set next_attempt_at = now() - interval '1 second';
select zm_test.act_as_service();
select count(*) from public.claim_notification_deliveries();
select public.report_notification_delivery(zm_test.did(), false, '4');
select zm_test.act_as_admin();
update public.notification_deliveries set next_attempt_at = now() - interval '1 second';
select zm_test.act_as_service();
select zm_test.expect_equal((select count(*)::text from public.claim_notification_deliveries()), '1', 'fifth attempt is handed out');
select zm_test.expect_equal((select public.report_notification_delivery(zm_test.did(), false, 'fifth failure'))::text, 'dead', 'out of attempts: dead');
select zm_test.act_as_admin();
update public.notification_deliveries set next_attempt_at = now() - interval '1 second';
select zm_test.act_as_service();
select zm_test.expect_equal((select count(*)::text from public.claim_notification_deliveries()), '0', 'a dead delivery is never handed out again');

-- Success, no-retry, token clean-up, lease expiry, skipping read notifications and moved tokens
select zm_test.act_as_admin();
delete from public.notification_deliveries;
select public.notify(:'B', 'orders', 'order.test', 'Queue 2', 'body2', '/orders', 'q-2');
select zm_test.act_as_service();
select count(*) from public.claim_notification_deliveries();
select zm_test.expect_equal((select public.report_notification_delivery(zm_test.did(), true, null, 'ticket-123'))::text, 'sent', 'success');
select zm_test.act_as_admin();
select zm_test.expect_equal((select status || ':' || provider_ref from public.notification_deliveries), 'sent:ticket-123', 'sent with the provider reference');
delete from public.notification_deliveries;
select public.notify(:'B', 'orders', 'order.test', 'Queue 3', 'body3', '/orders', 'q-3');
select zm_test.act_as_service();
select count(*) from public.claim_notification_deliveries();
select zm_test.expect_equal((select public.report_notification_delivery(zm_test.did(), false, 'DeviceNotRegistered', null, false, true))::text, 'dead', 'a permanent failure is not retried');
select zm_test.act_as_admin();
select zm_test.expect_equal((select (disabled_at is not null)::text from public.push_tokens where token = 'ExponentPushToken[queue00000000001]'), 'true', 'the dead token was switched off');
-- a worker that died: lease runs out, delivery is handed out again
update public.push_tokens set disabled_at = null where token = 'ExponentPushToken[queue00000000001]';
delete from public.notification_deliveries;
select public.notify(:'B', 'orders', 'order.test', 'Queue 4', 'body4', '/orders', 'q-4');
select zm_test.act_as_service();
select count(*) from public.claim_notification_deliveries();
select zm_test.act_as_admin();
update public.notification_deliveries set locked_until = now() - interval '1 second';
select zm_test.act_as_service();
select zm_test.expect_equal((select attempts::text from public.claim_notification_deliveries()), '2', 'an abandoned lease is picked up again');
select zm_test.act_as_admin();
update public.notification_deliveries set locked_until = now() - interval '1 second', attempts = 5;
select zm_test.act_as_service();
select zm_test.expect_equal((select count(*)::text from public.claim_notification_deliveries()), '0', 'abandoned with no attempts left');
select zm_test.act_as_admin();
select zm_test.expect_equal((select status from public.notification_deliveries), 'dead', 'is marked dead');
-- Already read: skipped
delete from public.notification_deliveries;
select public.notify(:'B', 'orders', 'order.test', 'Queue 5', 'body5', '/orders', 'q-5');
update public.notifications set read_at = now() where dedupe_key = 'q-5';
select zm_test.act_as_service();
select zm_test.expect_equal((select count(*)::text from public.claim_notification_deliveries()), '0', 'a push for something already read is not sent');
select zm_test.act_as_admin();
select zm_test.expect_equal((select status from public.notification_deliveries), 'skipped', 'it is marked skipped');
-- Token moved to another account: skipped
delete from public.notification_deliveries;
select public.notify(:'B', 'orders', 'order.test', 'Queue 6', 'body6', '/orders', 'q-6');
update public.push_tokens set user_id = :'C' where token = 'ExponentPushToken[queue00000000001]';
select zm_test.act_as_service();
select zm_test.expect_equal((select count(*)::text from public.claim_notification_deliveries()), '0', 'a push is not sent to a token that now belongs to someone else');
select zm_test.act_as_admin();
update public.push_tokens set user_id = :'B' where token = 'ExponentPushToken[queue00000000001]';

-- 7. Messages: who, never what
delete from public.notification_deliveries;
delete from public.notifications where type = 'message.new';
insert into zm_ids values ('l2', zm_test.fresh_listing(300));
insert into public.conversations (id, listing_id, buyer_id, seller_id) values ('50000000-0000-0000-0000-000000000001', (select id from zm_ids where name = 'l2'), :'B', :'S');
insert into public.push_tokens (user_id, token, platform) values (:'S', 'ExponentPushToken[sellerdevice0001]', 'android');
insert into public.messages (conversation_id, sender_id, body) values ('50000000-0000-0000-0000-000000000001', :'B', 'my secret bank details are 12345');
select zm_test.expect_equal(zm_test.count_for(:'S', 'message.new'), '1', 'the seller is told about the message');
select zm_test.expect_equal(zm_test.count_for(:'B', 'message.new'), '0', 'the sender is not');
select zm_test.expect_equal((select (position('secret' in title || coalesce(body, '')) = 0)::text from public.notifications where user_id = :'S' and type = 'message.new'), 'true', 'the message text is not in the notification');
select zm_test.expect_equal((select link from public.notifications where user_id = :'S' and type = 'message.new'), '/chat/50000000-0000-0000-0000-000000000001', 'deep link to the chat');
insert into public.messages (conversation_id, sender_id, body) values ('50000000-0000-0000-0000-000000000001', :'B', 'hello again');
select zm_test.expect_equal(zm_test.count_for(:'S', 'message.new'), '2', 'both messages are in the inbox');
select zm_test.expect_equal((select count(*)::text from public.notification_deliveries d join public.notifications n on n.id = d.notification_id where n.user_id = :'S' and n.type = 'message.new'), '1', 'but only one push goes out while the first is unread');
insert into public.messages (conversation_id, sender_id, body) values ('50000000-0000-0000-0000-000000000001', :'S', 'reply');
select zm_test.expect_equal(zm_test.count_for(:'B', 'message.new'), '1', 'the buyer hears about the reply');
insert into public.blocks (blocker_id, blocked_id) values (:'S', :'B');
insert into public.messages (conversation_id, sender_id, body) values ('50000000-0000-0000-0000-000000000001', :'B', 'are you there');
select zm_test.expect_equal(zm_test.count_for(:'S', 'message.new'), '2', 'a blocked person''s message makes no notification');
delete from public.blocks;
-- Business conversations reach the team
insert into zm_ids values ('l3', zm_test.fresh_listing(300, :'BIZ'));
insert into public.conversations (id, listing_id, buyer_id, seller_id, business_id) values ('50000000-0000-0000-0000-000000000002', (select id from zm_ids where name = 'l3'), :'B', :'S', :'BIZ');
insert into public.messages (conversation_id, sender_id, body) values ('50000000-0000-0000-0000-000000000002', :'B', 'is this available');
select zm_test.expect_equal(zm_test.count_for(:'MGR', 'message.new'), '1', 'a business team member is told about a shop chat');

-- 8. Alerts
insert into public.saved_searches (id, user_id, name, term) values ('60000000-0000-0000-0000-000000000001', :'B', 'Cheap phones', 'phone');
insert into public.listing_alerts (user_id, saved_search_id, listing_id) values (:'B', '60000000-0000-0000-0000-000000000001', (select id from zm_ids where name = 'l2'));
select zm_test.expect_equal((select title || '|' || link from public.notifications where user_id = :'B' and type = 'alert.match'), 'New match: Cheap phones|/listing/' || (select id from zm_ids where name = 'l2'), 'search alert notification');

-- 9. Verification, account state, moderation
insert into public.identity_verifications (id, user_id, document_type, document_path) values ('10000000-0000-0000-0000-00000000000b', :'B', 'national_id', 'b/id.jpg');
select zm_test.act_as(:'SUP', 'aal2');
select public.review_identity_verification('10000000-0000-0000-0000-00000000000b', false, 'Photo is blurry');
select zm_test.act_as_admin();
select zm_test.expect_equal((select title || '|' || body from public.notifications where user_id = :'B' and type = 'verification.identity'), 'Your ID check was not approved|Photo is blurry', 'rejection tells the person why');
insert into public.identity_verifications (id, user_id, document_type, document_path) values ('10000000-0000-0000-0000-00000000010b', :'B', 'passport', 'b/pp.jpg');
select zm_test.act_as(:'SUP', 'aal2');
select public.review_identity_verification('10000000-0000-0000-0000-00000000010b', true);
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.count_for(:'B', 'verification.identity'), '2', 'approval is a second notification');
select zm_test.act_as(:'MOD', 'aal2');
select public.set_account_state(:'B', 'suspended', 'Fake documents');
select public.set_account_state(:'B', 'active', 'Appeal accepted');
select zm_test.act_as_admin();
select zm_test.expect_equal((select string_agg(title, ',' order by created_at, title) from public.notifications where user_id = :'B' and type = 'account.state'), 'Your account is active again,Your account was suspended', 'account state changes');
select zm_test.expect_equal((select bool_and(position('Fake' in coalesce(body, '')) = 0)::text from public.notifications where user_id = :'B' and type = 'account.state'), 'true', 'the internal reason is not in any notification');
-- Moderation
insert into public.listings (id, seller_id, category_id, location_id, title, description, price_zmw, condition, status, moderation_status)
  select '70000000-0000-0000-0000-000000000001', :'S', c.id, l.id, 'Auto approved item', 'x', 100, 'used_good', 'draft', 'pending'
    from public.categories c, public.locations l where c.slug = 'electronics' and l.area = 'Kabulonga';
insert into public.listing_images (listing_id, storage_path, position) values ('70000000-0000-0000-0000-000000000001', 'x/auto.jpg', 0);
-- The insert already auto-approved it; put it back to pending so publishing really changes the status.
alter table public.listings disable trigger listings_rules;
update public.listings set moderation_status = 'pending' where id = '70000000-0000-0000-0000-000000000001';
alter table public.listings enable trigger listings_rules;
select zm_test.act_as(:'S');
update public.listings set status = 'active' where id = '70000000-0000-0000-0000-000000000001';
select zm_test.act_as_admin();
select zm_test.expect_equal((select moderation_status::text from public.listings where id = '70000000-0000-0000-0000-000000000001'), 'approved', 'publishing approved the listing by itself');
select zm_test.expect_equal(zm_test.count_for(:'S', 'listing.approved'), '0', 'automatic approval on publishing makes no notification');
select zm_test.act_as(:'MOD', 'aal2');
select public.moderate_listing((select id from zm_ids where name = 'l2'), 'rejected', 'Photo does not show the item');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.count_for(:'S', 'listing.rejected'), '1', 'rejection is notified');
select zm_test.act_as(:'MOD', 'aal2');
select public.moderate_listing((select id from zm_ids where name = 'l2'), 'approved');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.count_for(:'S', 'listing.approved'), '1', 'a moderator approving is notified');

-- 10. Business: invitations and low stock
select zm_test.act_as(:'S');
select public.invite_member(:'BIZ', 'third@example.test', 'staff');
select public.invite_member(:'BIZ', 'nobody@example.test', 'staff');
select zm_test.act_as_admin();
select zm_test.expect_equal((select title || '|' || link from public.notifications where user_id = :'C' and type = 'business.invited'), 'You were invited to join Sam Shop|/business/invitations', 'an existing account is told about the invitation');
select zm_test.expect_equal((select count(*)::text from public.notifications where type = 'business.invited'), '1', 'an unknown email makes no notification');
select zm_test.act_as(:'S');
select public.track_stock((select id from zm_ids where name = 'l3'), 5, 2);
select public.adjust_stock((select id from zm_ids where name = 'l3'), -2, 'damaged');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.count_for(:'S', 'business.low_stock'), '0', '3 left is not low');
select zm_test.act_as(:'S');
select public.adjust_stock((select id from zm_ids where name = 'l3'), -1, 'damaged');
select public.adjust_stock((select id from zm_ids where name = 'l3'), -1, 'damaged');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.count_for(:'S', 'business.low_stock') || ',' || zm_test.count_for(:'MGR', 'business.low_stock'), '1,1', 'owner and manager are told once when stock crosses the line');
select zm_test.expect_equal(zm_test.count_for('00000000-0000-0000-0000-00000000000f', 'business.low_stock'), '0', 'staff are not sent stock warnings');
-- A business order reaches the team
select zm_test.act_as(:'B');
select public.create_order((select id from zm_ids where name = 'l3')) is not null;
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.count_for(:'MGR', 'order.requested'), '1', 'the business team hears about an order request');

-- 11. Permissions and clean-up
select zm_test.expect_equal((select string_agg(p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('notify','order_seller_side','notify_order_event','notify_new_message','notify_listing_alert','notify_identity_decision','notify_business_decision','notify_account_state','notify_moderation','notify_business_invitation','notify_low_stock','claim_notification_deliveries','report_notification_delivery','purge_old_notifications')
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), null, 'internal and worker functions are closed to the app');
select zm_test.expect_equal((select string_agg(p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('unread_notification_count','mark_notifications_read','mark_all_notifications_read','my_notification_settings','set_notification_preference','notification_channels','register_push_token','unregister_push_token')
     and has_function_privilege('anon', p.oid, 'execute')), null, 'app functions are closed to signed-out callers');
select zm_test.expect_equal((select string_agg(p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('claim_notification_deliveries','report_notification_delivery','purge_old_notifications')
     and not has_function_privilege('service_role', p.oid, 'execute')), null, 'the worker can call its functions');
update public.notifications set read_at = now() - interval '100 days', created_at = now() - interval '100 days' where user_id = :'B' and type = 'order.test';
update public.notifications set created_at = now() - interval '10 days' where user_id = :'S';
select zm_test.act_as_service();
select zm_test.expect_equal((select public.purge_old_notifications(90, 365) > 0)::text, 'true', 'old read notifications are purged');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.notifications where user_id = :'B' and type = 'order.test' and read_at is not null), '0', 'the old read ones are gone');
select zm_test.expect_equal((select (count(*) > 0)::text from public.notifications where user_id = :'S'), 'true', 'recent ones stay');

select 'Notification checks passed' as result;
rollback;
