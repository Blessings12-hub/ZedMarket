-- Payments (migration 0013): who can start a payment, idempotency, provider results, late and mismatched
-- reports, finance reconciliation, refunds with a second approver, history visibility, permissions.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/payments.sql

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
  ('00000000-0000-0000-0000-00000000000f', 'staff@example.test',   null,           '{"display_name":"Staff Sipho"}', now(), null),
  ('00000000-0000-0000-0000-0000000000f1', 'fin1@example.test',    null,           '{"display_name":"Finance One"}', now(), null),
  ('00000000-0000-0000-0000-0000000000f2', 'fin2@example.test',    null,           '{"display_name":"Finance Two"}', now(), null);
insert into public.admin_roles (user_id, role) values
  ('00000000-0000-0000-0000-00000000000e', 'support'),
  ('00000000-0000-0000-0000-000000000001', 'moderator'),
  ('00000000-0000-0000-0000-0000000000f1', 'finance'),
  ('00000000-0000-0000-0000-0000000000f2', 'finance');
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
\set F1 '00000000-0000-0000-0000-0000000000f1'
\set F2 '00000000-0000-0000-0000-0000000000f2'
\set BIZ '20000000-0000-0000-0000-00000000000a'


create function zm_test.confirmed_order(p_price numeric default 500, p_fee numeric default 0) returns uuid
language plpgsql as $$
declare
  lid uuid; oid uuid;
begin
  perform zm_test.act_as_admin();
  lid := zm_test.fresh_listing(p_price);
  perform zm_test.act_as('00000000-0000-0000-0000-00000000000b');
  if p_fee > 0 then
    oid := (public.create_order(lid, 'delivery', '12 Kabulonga Road, Lusaka')).id;
  else
    oid := (public.create_order(lid)).id;
  end if;
  perform zm_test.act_as('00000000-0000-0000-0000-00000000000a');
  perform public.confirm_order(oid, p_fee);
  perform zm_test.act_as_admin();
  return oid;
end $$;
grant execute on function zm_test.confirmed_order(numeric, numeric) to anon, authenticated, service_role;
create function zm_test.pay_status(p_id uuid) returns text language sql security definer as $$
  select status || ':' || needs_review::text from public.payments where id = p_id;
$$;
grant execute on function zm_test.pay_status(uuid) to anon, authenticated, service_role;

-- 1. Switched off by default
select zm_test.act_as_admin();
insert into zm_ids values ('o1', zm_test.confirmed_order(500, 50));
select zm_test.act_as(:'B');
select zm_test.expect_error($$select public.start_payment((select id from zm_ids where name = 'o1'), 'mtn_momo', '+260961234567', 'key-aaaaaaaa')$$, 'payments are off until switched on');
select zm_test.expect_equal(public.payments_enabled()::text, 'false', 'switched off');
select zm_test.act_as_admin();
update public.platform_settings set value = '1' where key = 'payments.enabled';

-- 2. Starting a payment
select zm_test.act_as_admin();
update public.profiles set account_state = 'suspended' where id = :'B';
select zm_test.act_as(:'B');
select zm_test.expect_error($$select public.start_payment((select id from zm_ids where name = 'o1'), 'mtn_momo', '+260961234567', 'key-susppppp')$$, 'a suspended account cannot pay');
select zm_test.act_as_admin();
update public.profiles set account_state = 'active' where id = :'B';
select zm_test.act_as(:'C');
select zm_test.expect_error($$select public.start_payment((select id from zm_ids where name = 'o1'), 'mtn_momo', '+260961234567', 'key-cccccccc')$$, 'someone else cannot pay for the order');
select zm_test.act_as(:'S');
select zm_test.expect_error($$select public.start_payment((select id from zm_ids where name = 'o1'), 'mtn_momo', '+260961234567', 'key-ssssssss')$$, 'the seller cannot pay');
select zm_test.act_as(:'B');
select zm_test.expect_error($$select public.start_payment((select id from zm_ids where name = 'o1'), 'visa', '+260961234567', 'key-aaaaaaaa')$$, 'unknown method');
select zm_test.expect_error($$select public.start_payment((select id from zm_ids where name = 'o1'), 'mtn_momo', '0961234567', 'key-aaaaaaaa')$$, 'bad phone format');
select zm_test.expect_error($$select public.start_payment((select id from zm_ids where name = 'o1'), 'mtn_momo', '+260961234567', 'short')$$, 'key too short');
insert into zm_ids values ('p1', (public.start_payment((select id from zm_ids where name = 'o1'), 'mtn_momo', '+260961234567', 'key-aaaaaaaa')).id);
select zm_test.act_as_admin();
select zm_test.expect_equal((select amount_zmw::text from public.payments where id = (select id from zm_ids where name = 'p1')), '550.00', 'amount is item plus delivery fee, set by the database');
select zm_test.expect_equal(zm_test.pay_status((select id from zm_ids where name = 'p1')), 'pending:false', 'starts pending, never paid');
select zm_test.act_as(:'B');
select zm_test.expect_equal((public.start_payment((select id from zm_ids where name = 'o1'), 'mtn_momo', '+260961234567', 'key-aaaaaaaa')).id::text, (select id::text from zm_ids where name = 'p1'), 'same key gives the same payment');
select zm_test.expect_error($$select public.start_payment((select id from zm_ids where name = 'o1'), 'airtel_money', '+260971234567', 'key-bbbbbbbb')$$, 'a second live payment is refused');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.payments), '1', 'one payment row');

-- 3. Order must be confirmed
insert into zm_ids values ('l2', zm_test.fresh_listing(300));
select zm_test.act_as(:'B');
insert into zm_ids values ('o2', (public.create_order((select id from zm_ids where name = 'l2'))).id);
select zm_test.expect_error($$select public.start_payment((select id from zm_ids where name = 'o2'), 'mtn_momo', '+260961234567', 'key-dddddddd')$$, 'unconfirmed order cannot be paid');

-- 4. The app cannot write or read private columns
select zm_test.expect_error($$update public.payments set status = 'succeeded'$$, 'buyers cannot mark paid');
select zm_test.expect_error($$insert into public.payments (order_id, payer_id, payee_id, amount_zmw, method, payer_phone, idempotency_key, expires_at) values ((select id from zm_ids where name = 'o1'), '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000a', 1, 'mtn_momo', '+260961234567', 'key-xxxxxxxx', now())$$, 'no direct inserts');
select zm_test.expect_error($$select payer_phone from public.payments$$, 'phone number is not readable by the app');
select zm_test.expect_error($$select provider_ref from public.payments$$, 'provider reference is not readable by the app');
select zm_test.expect_equal((select count(*)::text from public.payments), '1', 'payer sees own payment');
select zm_test.act_as(:'S');
select zm_test.expect_equal((select count(*)::text from public.payments), '1', 'payee sees it too');
select zm_test.expect_equal((select direction from public.my_payments() limit 1), 'received', 'seller sees it as received');
select zm_test.act_as(:'C');
select zm_test.expect_equal((select count(*)::text from public.payments), '0', 'outsider sees nothing');
select zm_test.expect_equal((select count(*)::text from public.payment_events), '0', 'outsider sees no events');
select zm_test.act_as(:'B');
select zm_test.expect_error($$select * from public.finance_summary()$$, 'buyer is not finance');
select zm_test.expect_error($$select public.record_provider_result((select id from zm_ids where name = 'p1'), 'momo', 'REF123456', 'succeeded', 550, null)$$, 'buyer cannot report provider results');
select zm_test.expect_error($$select public.expire_stale_payments()$$, 'buyer cannot run the timeout job');

-- 5. Provider results
select zm_test.act_as_service();
select zm_test.expect_equal(public.record_provider_result((select id from zm_ids where name = 'p1'), 'momo-agg', 'REF123456', 'succeeded', 500, null), 'needs_review', 'wrong amount is flagged, not applied');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.pay_status((select id from zm_ids where name = 'p1')), 'pending:true', 'wrong amount leaves it pending and flagged');
select zm_test.act_as_service();
select zm_test.expect_error($$select public.record_provider_result((select id from zm_ids where name = 'p1'), 'momo-agg', null, 'succeeded', 550, null)$$, 'success needs a reference');
select zm_test.expect_equal(public.record_provider_result((select id from zm_ids where name = 'p1'), 'momo-agg', 'REF123456', 'succeeded', 550, null), 'succeeded', 'correct amount succeeds');
select zm_test.expect_equal(public.record_provider_result((select id from zm_ids where name = 'p1'), 'momo-agg', 'REF123456', 'succeeded', 550, null), 'duplicate', 'a resent result changes nothing');
select zm_test.expect_equal(public.record_provider_result((select id from zm_ids where name = 'p1'), 'momo-agg', 'OTHER99999', 'failed', 550, 'x'), 'ignored', 'a failure after success is ignored');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.pay_status((select id from zm_ids where name = 'p1')), 'succeeded:true', 'still succeeded (flag from the earlier mismatch stays until finance looks)');
select zm_test.expect_equal(zm_test.count_for(:'B', 'payment.succeeded'), '1', 'payer is told once');
select zm_test.expect_equal(zm_test.count_for(:'S', 'payment.received'), '1', 'seller is told once');
select zm_test.act_as(:'B');
select zm_test.expect_error($$select public.cancel_payment((select id from zm_ids where name = 'p1'))$$, 'a paid payment cannot be cancelled');
select zm_test.expect_error($$select public.start_payment((select id from zm_ids where name = 'o1'), 'mtn_momo', '+260961234567', 'key-eeeeeeee')$$, 'a paid order cannot be paid again');

-- 6. Failed, cancelled, timed out and retry
select zm_test.act_as_admin();
insert into zm_ids values ('o3', zm_test.confirmed_order(200, 0));
select zm_test.act_as(:'B');
insert into zm_ids values ('p3', (public.start_payment((select id from zm_ids where name = 'o3'), 'airtel_money', '+260971234567', 'key-33333333')).id);
select zm_test.act_as_service();
select zm_test.expect_equal(public.record_provider_result((select id from zm_ids where name = 'p3'), 'momo-agg', 'FAIL000001', 'failed', 200, 'Not enough balance'), 'failed', 'provider failure recorded');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.count_for(:'B', 'payment.failed'), '1', 'payer told about the failure');
select zm_test.expect_equal((select failure_reason from public.payments where id = (select id from zm_ids where name = 'p3')), 'Not enough balance', 'reason kept');
select zm_test.act_as(:'B');
insert into zm_ids values ('p3b', (public.start_payment((select id from zm_ids where name = 'o3'), 'airtel_money', '+260971234567', 'key-33333334')).id);
select zm_test.expect_equal((select count(*)::text from public.my_payments((select id from zm_ids where name = 'o3'))), '2', 'history shows both attempts');
select zm_test.act_as(:'C');
select zm_test.expect_error($$select public.cancel_payment((select id from zm_ids where name = 'p3b'))$$, 'someone else cannot cancel it');
select zm_test.act_as(:'B');
select public.cancel_payment((select id from zm_ids where name = 'p3b'));
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.pay_status((select id from zm_ids where name = 'p3b')), 'cancelled:false', 'buyer cancelled a waiting payment');
-- a late "paid" for the cancelled one is not applied silently
select zm_test.act_as_service();
select zm_test.expect_equal(public.record_provider_result((select id from zm_ids where name = 'p3b'), 'momo-agg', 'LATE0000001', 'succeeded', 200, null), 'needs_review', 'late success is flagged');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.pay_status((select id from zm_ids where name = 'p3b')), 'cancelled:true', 'late success leaves it cancelled and flagged');
-- timeout
insert into zm_ids values ('o4', zm_test.confirmed_order(100, 0));
select zm_test.act_as(:'B');
insert into zm_ids values ('p4', (public.start_payment((select id from zm_ids where name = 'o4'), 'mtn_momo', '+260961234567', 'key-44444444')).id);
select zm_test.act_as_service();
select zm_test.expect_equal(public.expire_stale_payments()::text, '0', 'nothing is stale yet');
select zm_test.act_as_admin();
update public.payments set expires_at = now() - interval '1 minute' where id = (select id from zm_ids where name = 'p4');
select zm_test.act_as_service();
select zm_test.expect_equal(public.expire_stale_payments()::text, '1', 'one stale payment times out');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.pay_status((select id from zm_ids where name = 'p4')), 'failed:false', 'timed-out payment is failed');
select zm_test.expect_equal(zm_test.count_for(:'B', 'payment.failed'), '2', 'timeout is notified');

-- 7. Duplicate provider references are refused
insert into zm_ids values ('o5', zm_test.confirmed_order(80, 0));
select zm_test.act_as(:'B');
insert into zm_ids values ('p5', (public.start_payment((select id from zm_ids where name = 'o5'), 'mtn_momo', '+260961234567', 'key-55555555')).id);
select zm_test.act_as_service();
select zm_test.expect_error($$select public.record_provider_result((select id from zm_ids where name = 'p5'), 'momo-agg', 'REF123456', 'succeeded', 80, null)$$, 'one provider reference cannot confirm two payments');

-- 8. Cancelling an order closes its waiting payment, and flags a paid one
select zm_test.act_as(:'B');
select public.cancel_order((select id from zm_ids where name = 'o5'), 'Changed my mind');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.pay_status((select id from zm_ids where name = 'p5')), 'cancelled:false', 'waiting payment closed with the order');
select zm_test.act_as_admin();
update public.payments set needs_review = false where id = (select id from zm_ids where name = 'p1');
select zm_test.act_as(:'B');
select public.cancel_order((select id from zm_ids where name = 'o1'), 'Changed my mind');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.pay_status((select id from zm_ids where name = 'p1')), 'succeeded:true', 'paid payment of a cancelled order is flagged for finance');

-- 9. Finance: view, reconcile
select zm_test.act_as(:'F1', 'aal1');
select zm_test.expect_error($$select * from public.finance_summary()$$, 'finance needs aal2');
select zm_test.act_as(:'F1', 'aal2');
select zm_test.expect_equal((select count::text from public.finance_summary(30) where label = 'needs_review'), '2', 'two payments need review');
select zm_test.expect_equal((select count(*)::text from public.finance_payments(null, true)), '2', 'review filter');
select zm_test.expect_equal(((select payer_phone_masked from public.finance_payments(null, false, 'PAY-') limit 1) like '%•%')::text, 'true', 'phone is masked');
select zm_test.expect_equal((select count(*)::text from public.finance_payments(null, false, '%')), '5', 'a percent sign is plain text in search (all five, none matched as wildcard errors)');
select zm_test.expect_equal((public.finance_payment_detail((select id from zm_ids where name = 'p1')) -> 'payment' ->> 'status'), 'succeeded', 'detail works');
select zm_test.expect_error($$select public.finance_reconcile_payment((select id from zm_ids where name = 'p3b'), 'succeeded', 'STMT-0001', 'short')$$, 'note too short');
select zm_test.expect_error($$select public.finance_reconcile_payment((select id from zm_ids where name = 'p3b'), 'succeeded', 'ab', 'Checked the MTN statement, money arrived')$$, 'reference needed');
select zm_test.expect_error($$select public.finance_reconcile_payment((select id from zm_ids where name = 'p4'), 'succeeded', 'STMT-0002', 'Checked the MTN statement, money arrived')$$, 'a closed payment with nothing to review is refused');
select zm_test.expect_error($$select public.finance_reconcile_payment((select id from zm_ids where name = 'p1'), 'failed', null, 'Trying to undo a paid payment')$$, 'paid cannot be marked failed');
select public.finance_reconcile_payment((select id from zm_ids where name = 'p3b'), 'succeeded', 'STMT-0001', 'Checked the MTN statement, money arrived late');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.pay_status((select id from zm_ids where name = 'p3b')), 'succeeded:false', 'finance marked it paid with evidence');
select zm_test.expect_equal((select confirmed_via from public.payments where id = (select id from zm_ids where name = 'p3b')), 'finance', 'recorded as finance-confirmed');
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action = 'payment.reconciled'), '1', 'audited');
select zm_test.act_as(:'MOD', 'aal2');
select zm_test.expect_error($$select * from public.finance_payments()$$, 'other staff roles are not finance');
select zm_test.act_as(:'SUP', 'aal2');
select zm_test.expect_error($$select public.finance_reconcile_payment((select id from zm_ids where name = 'p1'), 'succeeded', 'STMT-0003', 'Support must not do this')$$, 'support cannot reconcile');

-- Finance staff cannot reconcile a payment they are part of
select zm_test.act_as_admin();
update public.payments set payer_id = :'F1', needs_review = true where id = (select id from zm_ids where name = 'p3');
select zm_test.act_as(:'F1', 'aal2');
select zm_test.expect_error($$select public.finance_reconcile_payment((select id from zm_ids where name = 'p3'), 'failed', null, 'Checking my own payment, not allowed')$$, 'finance cannot reconcile their own payment');
select zm_test.act_as_admin();
update public.payments set payer_id = :'B', needs_review = false where id = (select id from zm_ids where name = 'p3');

-- 10. Refunds: two people, limits, results
select zm_test.act_as(:'F1', 'aal2');
select zm_test.expect_error($$select public.finance_request_refund((select id from zm_ids where name = 'p3'), 10, 'Not paid so nothing to refund')$$, 'failed payments are not refundable');
select zm_test.expect_error($$select public.finance_request_refund((select id from zm_ids where name = 'p1'), 0, 'Zero is not allowed')$$, 'zero refused');
select zm_test.expect_error($$select public.finance_request_refund((select id from zm_ids where name = 'p1'), 600, 'More than was paid')$$, 'more than paid refused');
select zm_test.expect_error($$select public.finance_request_refund((select id from zm_ids where name = 'p1'), 100, 'x')$$, 'reason needed');
insert into zm_ids values ('r1', (public.finance_request_refund((select id from zm_ids where name = 'p1'), 400, 'Order cancelled after payment')).id);
select zm_test.expect_error($$select public.finance_request_refund((select id from zm_ids where name = 'p1'), 200, 'Together they exceed the payment')$$, 'open refunds count against the limit');
select zm_test.expect_error($$select public.finance_decide_refund((select id from zm_ids where name = 'r1'), true)$$, 'the requester cannot approve their own refund');
select zm_test.act_as(:'F2', 'aal2');
select zm_test.expect_error($$select public.finance_decide_refund((select id from zm_ids where name = 'r1'), false)$$, 'rejecting needs a reason');
select zm_test.expect_error($$select public.finance_complete_refund((select id from zm_ids where name = 'r1'), true, 'RFND-0001')$$, 'cannot complete before approval');
select public.finance_decide_refund((select id from zm_ids where name = 'r1'), true, 'Checked the cancelled order');
select zm_test.expect_error($$select public.finance_decide_refund((select id from zm_ids where name = 'r1'), false, 'Changed my mind later')$$, 'decided only once');
select zm_test.expect_error($$select public.finance_complete_refund((select id from zm_ids where name = 'r1'), true, null)$$, 'a processed refund needs the reference');
select public.finance_complete_refund((select id from zm_ids where name = 'r1'), true, 'RFND-0001');
select zm_test.act_as_admin();
select zm_test.expect_equal((select refunded_zmw::text from public.payments where id = (select id from zm_ids where name = 'p1')), '400.00', 'refunded amount recorded');
select zm_test.expect_equal(zm_test.count_for(:'B', 'refund.processed'), '1', 'payer told about the refund');
select zm_test.expect_error($$select public.finance_complete_refund((select id from zm_ids where name = 'r1'), true, 'RFND-0002')$$, 'cannot complete twice');
select zm_test.act_as(:'F2', 'aal2');
select zm_test.expect_error($$select public.finance_request_refund((select id from zm_ids where name = 'p1'), 200, 'More than the 150 left')$$, 'processed refunds count too');
insert into zm_ids values ('r2', (public.finance_request_refund((select id from zm_ids where name = 'p1'), 150, 'The rest, goodwill after dispute')).id);
select zm_test.act_as(:'F1', 'aal2');
select public.finance_decide_refund((select id from zm_ids where name = 'r2'), false, 'Not justified after review');
select zm_test.act_as(:'F2', 'aal2');
insert into zm_ids values ('r3', (public.finance_request_refund((select id from zm_ids where name = 'p1'), 150, 'Asking again after more evidence')).id);
select zm_test.act_as(:'F1', 'aal2');
select public.finance_decide_refund((select id from zm_ids where name = 'r3'), true, 'Evidence accepted');
select public.finance_complete_refund((select id from zm_ids where name = 'r3'), false, null, 'Provider rejected the refund');
select zm_test.act_as_admin();
select zm_test.expect_equal((select refunded_zmw::text from public.payments where id = (select id from zm_ids where name = 'p1')), '400.00', 'a failed refund changes nothing');
select zm_test.expect_equal((select status from public.refunds where id = (select id from zm_ids where name = 'r3')), 'failed', 'failed refund recorded');
select zm_test.act_as_service();
select zm_test.expect_error($$select public.record_refund_result((select id from zm_ids where name = 'r1'), true, 'RFND-0009')$$, 'a processed refund cannot be completed again by the provider');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action in ('refund.requested','refund.approved','refund.rejected','refund.processed','refund.failed')), '8', 'every refund step is audited');
select zm_test.act_as(:'B');
select zm_test.expect_equal((select count(*)::text from public.refunds), '3', 'payer sees refunds of own payment');
select zm_test.expect_error($$select requested_by from public.refunds$$, 'staff ids are not readable');
select zm_test.expect_error($$select public.finance_complete_refund((select id from zm_ids where name = 'r1'), true, 'RFND-0010')$$, 'buyer cannot complete refunds');

-- 11. Function permissions
select zm_test.act_as_guest();
select zm_test.expect_error($$select public.start_payment(gen_random_uuid(), 'mtn_momo', '+260961234567', 'key-guestttt')$$, 'guests cannot pay');
select zm_test.expect_error($$select public.my_payments()$$, 'guests have no history');
select zm_test.act_as(:'B');
select zm_test.expect_error($$select public.refund_apply(gen_random_uuid(), true, 'x', null, 'finance', null)$$, 'internal refund function is closed');
select zm_test.expect_error($$select public.payment_log(gen_random_uuid(), 'x', 'buyer', null)$$, 'internal log function is closed');
select zm_test.expect_equal((select bool_or(has_function_privilege('authenticated', p.oid, 'execute'))::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('refund_apply', 'payment_log', 'finance_check', 'orders_payment_guard', 'notify_payment_change', 'notify_refund_processed', 'record_provider_result', 'expire_stale_payments', 'record_refund_result')), 'false', 'internal and provider functions are closed to the app');
select zm_test.expect_equal((select bool_and(has_function_privilege('service_role', p.oid, 'execute'))::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('record_provider_result', 'expire_stale_payments', 'record_refund_result')), 'true', 'the worker can call the provider functions');
select zm_test.act_as_service();
select zm_test.expect_error($$select * from public.finance_summary()$$, 'service role is not finance staff');
select zm_test.expect_error($$select public.start_payment(gen_random_uuid(), 'mtn_momo', '+260961234567', 'key-servicee')$$, 'service role cannot start payments');

select zm_test.act_as_admin();
select 'Payment checks passed' as result;
rollback;
