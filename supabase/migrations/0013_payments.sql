-- Module G: payments.
--
-- What this is: a RECORD of payments made through an authorised mobile-money provider, plus refunds,
-- failed-payment handling, history and a finance view.
-- What this is not: a wallet. ZedMarket does not hold customer money here. Money moves between the
-- payer's mobile-money account and the provider's settlement to the seller; this schema only records
-- what the provider reports. Whether a different set-up needs a licence is a question for a lawyer
-- and the Bank of Zambia before launch (see docs/DIRECTIVE_PROGRESS.md).
--
-- Rules that matter:
--   * Nothing in the app can mark a payment as paid. Only the provider's result (service_role worker)
--     or a finance staff member with evidence (a provider reference and a note) can.
--   * Payments are switched off until `payments.enabled` is set to 1 in platform_settings.
--   * A late "paid" report for a payment already failed, cancelled or timed out is never applied
--     silently (money may have moved): it is flagged for finance.
--   * A refund needs a second finance person to approve it.
--   * No real provider is connected. The worker functions are ready for one; nothing calls them yet.

-- ---------------------------------------------------------------------------
-- Replace the early placeholder tables
-- ---------------------------------------------------------------------------
-- Migrations 0002 and 0004 created empty `payments` and `payment_events` tables as a sketch. Nothing
-- has ever written to them. They are replaced here with the real design, but only if they are empty,
-- so this migration can never destroy real payment data.
do $$
begin
  if (select count(*) from public.payments) > 0 or (select count(*) from public.payment_events) > 0 then
    raise exception 'The old payments tables contain rows. Move them by hand before running this migration.';
  end if;
end $$;
drop table public.payment_events;
drop table public.payments;

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

insert into public.platform_settings (key, value, note) values
  ('payments.enabled', '0', 'Set to 1 only once a provider is connected and the legal review is done.'),
  ('payments.expiry_minutes', '30', 'A payment still waiting after this long is marked failed. Starter value.'),
  ('rate_limit.payment.max', '5', 'Payment attempts per window. Starter value.'),
  ('rate_limit.payment.window_minutes', '60', null)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create sequence public.payment_ref_seq start 1000;

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  ref text not null unique default ('PAY-' || lpad(nextval('public.payment_ref_seq')::text, 6, '0')),
  order_id uuid not null references public.orders (id) on delete restrict,
  payer_id uuid not null references public.profiles (id) on delete restrict,
  payee_id uuid not null references public.profiles (id) on delete restrict,
  amount_zmw numeric(12, 2) not null check (amount_zmw > 0),
  method text not null check (method in ('mtn_momo', 'airtel_money')),
  payer_phone text not null check (payer_phone ~ '^\+260[0-9]{9}$'),
  status text not null default 'pending' check (status in ('pending', 'succeeded', 'failed', 'cancelled')),
  provider text check (char_length(provider) between 2 and 40),
  provider_ref text check (char_length(provider_ref) between 4 and 100),
  idempotency_key text not null check (char_length(idempotency_key) between 8 and 100),
  failure_reason text check (char_length(failure_reason) <= 200),
  confirmed_via text check (confirmed_via in ('provider', 'finance')),
  confirmed_by uuid references public.profiles (id) on delete set null,
  reconcile_note text check (char_length(reconcile_note) <= 500),
  needs_review boolean not null default false,
  refunded_zmw numeric(12, 2) not null default 0,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  settled_at timestamptz,
  check (payer_id <> payee_id),
  check (refunded_zmw >= 0 and refunded_zmw <= amount_zmw),
  check (status = 'succeeded' or refunded_zmw = 0),
  check (status <> 'succeeded' or (confirmed_via is not null and provider_ref is not null and settled_at is not null)),
  unique (payer_id, idempotency_key)
);
-- One live payment per order: a waiting or paid one blocks a second.
create unique index payments_one_live_per_order on public.payments (order_id) where status in ('pending', 'succeeded');
create unique index payments_provider_ref_unique on public.payments (provider, provider_ref) where provider_ref is not null;
create index payments_payer_idx on public.payments (payer_id, created_at desc);
create index payments_payee_idx on public.payments (payee_id, created_at desc);
create index payments_status_idx on public.payments (status, created_at desc);
create index payments_review_idx on public.payments (created_at desc) where needs_review;
create index payments_pending_due_idx on public.payments (expires_at) where status = 'pending';

create table public.payment_events (
  id bigint generated always as identity primary key,
  payment_id uuid not null references public.payments (id) on delete cascade,
  event text not null check (char_length(event) between 2 and 60),
  actor text not null check (actor in ('buyer', 'provider', 'finance', 'system')),
  actor_id uuid,
  detail jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index payment_events_payment_idx on public.payment_events (payment_id, id);

create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments (id) on delete restrict,
  amount_zmw numeric(12, 2) not null check (amount_zmw > 0),
  reason text not null check (char_length(reason) between 5 and 300),
  status text not null default 'requested' check (status in ('requested', 'approved', 'rejected', 'processed', 'failed')),
  requested_by uuid not null references public.profiles (id) on delete restrict,
  decided_by uuid references public.profiles (id) on delete set null,
  decision_note text check (char_length(decision_note) <= 300),
  decided_at timestamptz,
  provider_ref text check (char_length(provider_ref) between 4 and 100),
  failure_reason text check (char_length(failure_reason) <= 200),
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  check (decided_by is null or decided_by <> requested_by)
);
create index refunds_payment_idx on public.refunds (payment_id);
create index refunds_status_idx on public.refunds (status, created_at desc);
create unique index refunds_provider_ref_unique on public.refunds (provider_ref) where provider_ref is not null;

alter table public.payments enable row level security;
alter table public.payment_events enable row level security;
alter table public.refunds enable row level security;

-- People see their own payments (as payer or as payee). Finance sees all through functions.
create policy payments_party_read on public.payments for select to authenticated
  using (payer_id = (select auth.uid()) or payee_id = (select auth.uid()));
create policy payment_events_party_read on public.payment_events for select to authenticated
  using (exists (select 1 from public.payments p where p.id = payment_id
                 and (p.payer_id = (select auth.uid()) or p.payee_id = (select auth.uid()))));
create policy refunds_party_read on public.refunds for select to authenticated
  using (exists (select 1 from public.payments p where p.id = payment_id
                 and (p.payer_id = (select auth.uid()) or p.payee_id = (select auth.uid()))));

-- Column grants: the phone number, provider reference, staff ids and internal notes stay out of reach.
grant select (id, ref, order_id, payer_id, payee_id, amount_zmw, method, status, failure_reason, refunded_zmw,
              expires_at, created_at, updated_at, settled_at)
  on public.payments to authenticated;
grant select (id, payment_id, event, actor, created_at) on public.payment_events to authenticated;
grant select (id, payment_id, amount_zmw, reason, status, created_at, processed_at) on public.refunds to authenticated;

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

create function public.payment_log(p_payment uuid, p_event text, p_actor text, p_actor_id uuid, p_detail jsonb default '{}')
returns void
language sql security definer set search_path = ''
as $$
  insert into public.payment_events (payment_id, event, actor, actor_id, detail)
  values (p_payment, p_event, p_actor, p_actor_id, coalesce(p_detail, '{}'));
$$;

-- ---------------------------------------------------------------------------
-- Buyer: start and cancel a payment
-- ---------------------------------------------------------------------------

create function public.start_payment(p_order_id uuid, p_method text, p_phone text, p_key text)
returns public.payments
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  o public.orders;
  existing public.payments;
  p public.payments;
  state public.account_state;
begin
  if uid is null then
    raise exception 'Sign in to pay.' using errcode = 'insufficient_privilege';
  end if;
  if public.setting_numeric('payments.enabled', 0) <> 1 then
    raise exception 'Payments through ZedMarket are not switched on yet. Pay the seller as you agreed.' using errcode = 'check_violation';
  end if;
  if p_method not in ('mtn_momo', 'airtel_money') then
    raise exception 'Choose MTN Mobile Money or Airtel Money.' using errcode = 'check_violation';
  end if;
  if p_phone is null or p_phone !~ '^\+260[0-9]{9}$' then
    raise exception 'Enter the mobile money number as +260 followed by 9 digits.' using errcode = 'check_violation';
  end if;
  if p_key is null or char_length(p_key) < 8 then
    raise exception 'Missing payment key.' using errcode = 'check_violation';
  end if;

  select account_state into state from public.profiles where id = uid;
  if state is distinct from 'active' then
    raise exception 'Your account cannot make payments right now.' using errcode = 'insufficient_privilege';
  end if;

  -- The same key again returns the same payment, so a double tap or a retry never charges twice.
  select * into existing from public.payments where payer_id = uid and idempotency_key = p_key;
  if found then
    if existing.order_id <> p_order_id then
      raise exception 'That payment key was already used for another order.' using errcode = 'check_violation';
    end if;
    return existing;
  end if;

  perform public.enforce_rate_limit('payment', 5, 60);

  o := public.order_lock(p_order_id);
  if o.id is null or o.buyer_id <> uid then
    raise exception 'Order not found.' using errcode = 'no_data_found';
  end if;
  if o.status <> 'confirmed' then
    raise exception 'You can pay once the seller has confirmed the order.' using errcode = 'check_violation';
  end if;

  select * into existing from public.payments where order_id = o.id and status in ('pending', 'succeeded');
  if found then
    if existing.status = 'succeeded' then
      raise exception 'This order is already paid.' using errcode = 'check_violation';
    end if;
    raise exception 'A payment for this order is already waiting.' using errcode = 'check_violation';
  end if;

  insert into public.payments (order_id, payer_id, payee_id, amount_zmw, method, payer_phone, idempotency_key, expires_at)
  values (o.id, uid, o.seller_id, o.total_zmw, p_method, p_phone, p_key,
          clock_timestamp() + make_interval(mins => public.setting_numeric('payments.expiry_minutes', 30)::integer))
  returning * into p;
  perform public.payment_log(p.id, 'started', 'buyer', uid, jsonb_build_object('method', p_method));
  return p;
end;
$$;

create function public.cancel_payment(p_payment_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  p public.payments;
begin
  select * into p from public.payments where id = p_payment_id and payer_id = uid for update;
  if not found then
    raise exception 'Payment not found.' using errcode = 'no_data_found';
  end if;
  if p.status <> 'pending' then
    raise exception 'Only a payment that is still waiting can be cancelled.' using errcode = 'check_violation';
  end if;
  update public.payments set status = 'cancelled', updated_at = now(), settled_at = now() where id = p.id;
  perform public.payment_log(p.id, 'cancelled', 'buyer', uid);
end;
$$;

-- ---------------------------------------------------------------------------
-- Provider side (service_role only): results, timeouts, refund results
-- ---------------------------------------------------------------------------

create function public.record_provider_result(
  p_payment uuid, p_provider text, p_provider_ref text, p_status text, p_amount numeric, p_reason text default null
)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  p public.payments;
begin
  if p_status not in ('succeeded', 'failed') then
    raise exception 'Unknown result.' using errcode = 'check_violation';
  end if;
  select * into p from public.payments where id = p_payment for update;
  if not found then
    raise exception 'Payment not found.' using errcode = 'no_data_found';
  end if;

  -- Same report again (providers resend): nothing to do.
  if p.status = p_status and p.provider is not distinct from p_provider and p.provider_ref is not distinct from p_provider_ref then
    return 'duplicate';
  end if;

  if p_status = 'succeeded' and (p_amount is distinct from p.amount_zmw) then
    update public.payments set needs_review = true, updated_at = now() where id = p.id;
    perform public.payment_log(p.id, 'amount_mismatch', 'provider', null,
      jsonb_build_object('expected', p.amount_zmw, 'reported', p_amount, 'provider_ref', p_provider_ref));
    return 'needs_review';
  end if;

  if p.status <> 'pending' then
    -- A result for a payment that was already closed. If the provider says it was paid, money may have
    -- moved, so a person decides. If it says failed, it already is (or was paid and stays so).
    if p_status = 'succeeded' and p.status <> 'succeeded' then
      update public.payments set needs_review = true, updated_at = now() where id = p.id;
      perform public.payment_log(p.id, 'late_success', 'provider', null,
        jsonb_build_object('was', p.status, 'provider_ref', p_provider_ref));
      return 'needs_review';
    end if;
    perform public.payment_log(p.id, 'ignored_result', 'provider', null,
      jsonb_build_object('status', p_status, 'current', p.status));
    return 'ignored';
  end if;

  if p_status = 'succeeded' then
    if p_provider_ref is null or char_length(p_provider_ref) < 4 then
      raise exception 'A successful payment needs the provider reference.' using errcode = 'check_violation';
    end if;
    update public.payments
       set status = 'succeeded', provider = p_provider, provider_ref = p_provider_ref,
           confirmed_via = 'provider', settled_at = now(), updated_at = now()
     where id = p.id;
  else
    update public.payments
       set status = 'failed', provider = p_provider, provider_ref = p_provider_ref,
           failure_reason = left(coalesce(p_reason, 'The payment was not completed.'), 200),
           settled_at = now(), updated_at = now()
     where id = p.id;
  end if;
  perform public.payment_log(p.id, 'provider_' || p_status, 'provider', null,
    jsonb_build_object('provider', p_provider, 'provider_ref', p_provider_ref));
  return p_status;
end;
$$;

create function public.expire_stale_payments()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  r record;
  n integer := 0;
begin
  for r in select id from public.payments where status = 'pending' and expires_at < now() for update skip locked loop
    update public.payments
       set status = 'failed', failure_reason = 'No answer from the payment provider in time.', settled_at = now(), updated_at = now()
     where id = r.id;
    perform public.payment_log(r.id, 'timed_out', 'system', null);
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- Shared by the provider result and by finance doing it by hand.
create function public.refund_apply(p_refund uuid, p_ok boolean, p_ref text, p_reason text, p_actor text, p_actor_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.refunds;
  p public.payments;
begin
  select * into r from public.refunds where id = p_refund for update;
  if not found then
    raise exception 'Refund not found.' using errcode = 'no_data_found';
  end if;
  select * into p from public.payments where id = r.payment_id for update;
  if r.status <> 'approved' then
    raise exception 'Only an approved refund can be completed.' using errcode = 'check_violation';
  end if;
  if p_ok then
    if p_ref is null or char_length(p_ref) < 4 then
      raise exception 'Enter the reference of the money that was sent back.' using errcode = 'check_violation';
    end if;
    update public.refunds set status = 'processed', provider_ref = p_ref, processed_at = now() where id = r.id;
    update public.payments set refunded_zmw = refunded_zmw + r.amount_zmw, updated_at = now() where id = p.id;
    perform public.payment_log(p.id, 'refund_processed', p_actor, p_actor_id,
      jsonb_build_object('refund', r.id, 'amount', r.amount_zmw, 'provider_ref', p_ref));
  else
    update public.refunds set status = 'failed', failure_reason = left(coalesce(p_reason, 'The refund did not go through.'), 200) where id = r.id;
    perform public.payment_log(p.id, 'refund_failed', p_actor, p_actor_id, jsonb_build_object('refund', r.id));
  end if;
end;
$$;

create function public.record_refund_result(p_refund uuid, p_ok boolean, p_provider_ref text default null, p_reason text default null)
returns void
language sql security definer set search_path = ''
as $$
  select public.refund_apply(p_refund, p_ok, p_provider_ref, p_reason, 'provider', null);
$$;

-- ---------------------------------------------------------------------------
-- Finance staff
-- ---------------------------------------------------------------------------

create function public.finance_check()
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('finance') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
end;
$$;

-- Settle a payment by hand when the provider's answer never arrived or arrived late.
create function public.finance_reconcile_payment(p_payment uuid, p_outcome text, p_provider_ref text, p_note text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  p public.payments;
begin
  perform public.finance_check();
  if p_outcome not in ('succeeded', 'failed') then
    raise exception 'Choose succeeded or failed.' using errcode = 'check_violation';
  end if;
  if p_note is null or char_length(btrim(p_note)) < 10 then
    raise exception 'Write what you checked (at least 10 characters).' using errcode = 'check_violation';
  end if;
  select * into p from public.payments where id = p_payment for update;
  if not found then
    raise exception 'Payment not found.' using errcode = 'no_data_found';
  end if;
  if uid in (p.payer_id, p.payee_id) then
    raise exception 'You cannot reconcile a payment you are part of.' using errcode = 'insufficient_privilege';
  end if;
  if not (p.status = 'pending' or p.needs_review) then
    raise exception 'This payment does not need reconciling.' using errcode = 'check_violation';
  end if;
  if p_outcome = 'succeeded' then
    if p_provider_ref is null or char_length(btrim(p_provider_ref)) < 4 then
      raise exception 'Enter the provider reference from the statement.' using errcode = 'check_violation';
    end if;
    update public.payments
       set status = 'succeeded', provider_ref = btrim(p_provider_ref), provider = coalesce(provider, 'manual'),
           confirmed_via = 'finance', confirmed_by = uid, reconcile_note = left(btrim(p_note), 500),
           needs_review = false, failure_reason = null, settled_at = now(), updated_at = now()
     where id = p.id;
  else
    if p.status = 'succeeded' then
      raise exception 'A paid payment is reversed by a refund, not by marking it failed.' using errcode = 'check_violation';
    end if;
    update public.payments
       set status = 'failed', failure_reason = 'Checked by finance: no money received.', confirmed_by = uid,
           reconcile_note = left(btrim(p_note), 500), needs_review = false, settled_at = coalesce(settled_at, now()), updated_at = now()
     where id = p.id;
  end if;
  perform public.payment_log(p.id, 'reconciled_' || p_outcome, 'finance', uid, jsonb_build_object('provider_ref', p_provider_ref));
  perform public.write_audit('payment.reconciled', 'payment', p.id::text,
    jsonb_build_object('outcome', p_outcome, 'provider_ref', p_provider_ref));
end;
$$;

create function public.finance_request_refund(p_payment uuid, p_amount numeric, p_reason text)
returns public.refunds
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  p public.payments;
  committed numeric;
  r public.refunds;
begin
  perform public.finance_check();
  select * into p from public.payments where id = p_payment for update;
  if not found then
    raise exception 'Payment not found.' using errcode = 'no_data_found';
  end if;
  if uid in (p.payer_id, p.payee_id) then
    raise exception 'You cannot refund a payment you are part of.' using errcode = 'insufficient_privilege';
  end if;
  if p.status <> 'succeeded' then
    raise exception 'Only a paid payment can be refunded.' using errcode = 'check_violation';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Enter an amount above zero.' using errcode = 'check_violation';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) < 5 then
    raise exception 'Give a reason.' using errcode = 'check_violation';
  end if;
  -- Refunds still in progress count as already committed, so two cannot together exceed the payment.
  select coalesce(sum(amount_zmw), 0) into committed
    from public.refunds where payment_id = p.id and status in ('requested', 'approved', 'processed');
  if committed + p_amount > p.amount_zmw then
    raise exception 'That is more than is left to refund (%).', p.amount_zmw - committed using errcode = 'check_violation';
  end if;
  insert into public.refunds (payment_id, amount_zmw, reason, requested_by)
  values (p.id, p_amount, btrim(p_reason), uid) returning * into r;
  perform public.payment_log(p.id, 'refund_requested', 'finance', uid, jsonb_build_object('refund', r.id, 'amount', p_amount));
  perform public.write_audit('refund.requested', 'refund', r.id::text, jsonb_build_object('payment', p.id, 'amount', p_amount));
  return r;
end;
$$;

create function public.finance_decide_refund(p_refund uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  r public.refunds;
begin
  perform public.finance_check();
  select * into r from public.refunds where id = p_refund for update;
  if not found then
    raise exception 'Refund not found.' using errcode = 'no_data_found';
  end if;
  if r.status <> 'requested' then
    raise exception 'This refund was already decided.' using errcode = 'check_violation';
  end if;
  if r.requested_by = uid then
    raise exception 'A different person must decide this refund.' using errcode = 'insufficient_privilege';
  end if;
  if not p_approve and (p_note is null or char_length(btrim(p_note)) < 5) then
    raise exception 'Say why it is rejected.' using errcode = 'check_violation';
  end if;
  update public.refunds
     set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = uid, decided_at = now(), decision_note = left(btrim(p_note), 300)
   where id = r.id;
  perform public.payment_log(r.payment_id, case when p_approve then 'refund_approved' else 'refund_rejected' end,
    'finance', uid, jsonb_build_object('refund', r.id));
  perform public.write_audit(case when p_approve then 'refund.approved' else 'refund.rejected' end, 'refund', r.id::text,
    jsonb_build_object('payment', r.payment_id));
end;
$$;

-- Finance sent the money back outside the system (or the provider confirmed it) and records the reference.
create function public.finance_complete_refund(p_refund uuid, p_ok boolean, p_provider_ref text default null, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.finance_check();
  perform public.refund_apply(p_refund, p_ok, btrim(p_provider_ref), p_note, 'finance', (select auth.uid()));
  perform public.write_audit(case when p_ok then 'refund.processed' else 'refund.failed' end, 'refund', p_refund::text,
    jsonb_build_object('provider_ref', p_provider_ref));
end;
$$;

create function public.finance_payments(p_status text default null, p_review_only boolean default false, p_search text default null,
                                        p_limit integer default 50, p_offset integer default 0)
returns table (
  id uuid, ref text, order_ref text, amount_zmw numeric, refunded_zmw numeric, method text, payer_phone_masked text,
  status text, needs_review boolean, failure_reason text, provider text, provider_ref text,
  created_at timestamptz, open_refunds integer
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.finance_check();
  return query
    select p.id, p.ref, o.ref, p.amount_zmw, p.refunded_zmw, p.method,
           '+260' || repeat('•', 6) || right(p.payer_phone, 3),
           p.status, p.needs_review, p.failure_reason, p.provider, p.provider_ref, p.created_at,
           (select count(*)::integer from public.refunds r where r.payment_id = p.id and r.status in ('requested', 'approved'))
      from public.payments p join public.orders o on o.id = p.order_id
     where (p_status is null or p.status = p_status)
       and (not p_review_only or p.needs_review)
       and (p_search is null or p.ref ilike '%' || replace(replace(p_search, '%', ''), '_', '') || '%'
            or o.ref ilike '%' || replace(replace(p_search, '%', ''), '_', '') || '%'
            or p.provider_ref = p_search)
     order by p.created_at desc
     limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0);
end;
$$;

create function public.finance_payment_detail(p_payment uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  result jsonb;
begin
  perform public.finance_check();
  select jsonb_build_object(
      'payment', jsonb_build_object('id', p.id, 'ref', p.ref, 'order_ref', o.ref, 'amount_zmw', p.amount_zmw,
        'refunded_zmw', p.refunded_zmw, 'status', p.status, 'method', p.method, 'needs_review', p.needs_review,
        'provider', p.provider, 'provider_ref', p.provider_ref, 'confirmed_via', p.confirmed_via,
        'reconcile_note', p.reconcile_note, 'failure_reason', p.failure_reason, 'created_at', p.created_at,
        'phone_masked', '+260' || repeat('•', 6) || right(p.payer_phone, 3)),
      'events', coalesce((select jsonb_agg(jsonb_build_object('event', e.event, 'actor', e.actor, 'detail', e.detail, 'at', e.created_at) order by e.id)
                            from public.payment_events e where e.payment_id = p.id), '[]'),
      'refunds', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'amount_zmw', r.amount_zmw, 'status', r.status,
                              'reason', r.reason, 'requested_by', r.requested_by, 'decided_by', r.decided_by, 'provider_ref', r.provider_ref,
                              'created_at', r.created_at) order by r.created_at)
                            from public.refunds r where r.payment_id = p.id), '[]'))
    into result
    from public.payments p join public.orders o on o.id = p.order_id
   where p.id = p_payment;
  if result is null then
    raise exception 'Payment not found.' using errcode = 'no_data_found';
  end if;
  return result;
end;
$$;

create function public.finance_summary(p_days integer default 30)
returns table (label text, count integer, amount_zmw numeric)
language plpgsql stable security definer set search_path = ''
as $$
declare
  since timestamptz := now() - make_interval(days => least(greatest(p_days, 1), 365));
begin
  perform public.finance_check();
  return query
    select s.status, count(p.id)::integer, coalesce(sum(p.amount_zmw), 0)
      from unnest(array['pending', 'succeeded', 'failed', 'cancelled']) as s(status)
      left join public.payments p on p.status = s.status and p.created_at >= since
     group by s.status
    union all
    select 'refunded', count(*)::integer, coalesce(sum(r.amount_zmw), 0)
      from public.refunds r where r.status = 'processed' and r.processed_at >= since
    union all
    select 'refunds_waiting', count(*)::integer, coalesce(sum(r.amount_zmw), 0)
      from public.refunds r where r.status in ('requested', 'approved')
    union all
    select 'needs_review', count(*)::integer, coalesce(sum(p.amount_zmw), 0)
      from public.payments p where p.needs_review
    union all
    select 'stale_pending', count(*)::integer, coalesce(sum(p.amount_zmw), 0)
      from public.payments p where p.status = 'pending' and p.expires_at < now() - interval '1 hour';
end;
$$;

create function public.finance_refunds(p_status text default null, p_limit integer default 50)
returns table (
  id uuid, payment_ref text, amount_zmw numeric, reason text, status text,
  requested_by uuid, decided_by uuid, created_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.finance_check();
  return query
    select r.id, p.ref, r.amount_zmw, r.reason, r.status, r.requested_by, r.decided_by, r.created_at
      from public.refunds r join public.payments p on p.id = r.payment_id
     where p_status is null or r.status = p_status
     order by r.created_at desc limit least(greatest(p_limit, 1), 200);
end;
$$;

-- ---------------------------------------------------------------------------
-- Payment history for buyers and sellers
-- ---------------------------------------------------------------------------

create function public.my_payments(p_order uuid default null, p_limit integer default 50)
returns table (
  id uuid, ref text, order_id uuid, order_ref text, direction text, amount_zmw numeric, refunded_zmw numeric,
  method text, status text, failure_reason text, created_at timestamptz, expires_at timestamptz
)
language sql stable security definer set search_path = ''
as $$
  select p.id, p.ref, p.order_id, o.ref,
         case when p.payer_id = (select auth.uid()) then 'paid' else 'received' end,
         p.amount_zmw, p.refunded_zmw, p.method, p.status, p.failure_reason, p.created_at, p.expires_at
    from public.payments p join public.orders o on o.id = p.order_id
   where (p.payer_id = (select auth.uid()) or p.payee_id = (select auth.uid()))
     and (p_order is null or p.order_id = p_order)
   order by p.created_at desc limit least(greatest(p_limit, 1), 200);
$$;

create function public.payments_enabled()
returns boolean
language sql stable security definer set search_path = ''
as $$ select public.setting_numeric('payments.enabled', 0) = 1; $$;

-- ---------------------------------------------------------------------------
-- When an order ends, its payments must not be left hanging
-- ---------------------------------------------------------------------------

create function public.orders_payment_guard()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  r record;
begin
  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    for r in select id, status from public.payments where order_id = new.id and status in ('pending', 'succeeded') for update loop
      if r.status = 'pending' then
        -- The buyer may already have approved it on their phone, so the provider can still report money.
        -- Closing it here means a later "paid" report is flagged for finance rather than applied.
        update public.payments set status = 'cancelled', settled_at = now(), updated_at = now() where id = r.id;
        perform public.payment_log(r.id, 'order_cancelled', 'system', null);
      else
        update public.payments set needs_review = true, updated_at = now() where id = r.id;
        perform public.payment_log(r.id, 'order_cancelled_after_payment', 'system', null);
      end if;
    end loop;
  end if;
  return new;
end;
$$;
create trigger orders_payment_guard_trg after update of status on public.orders
  for each row when (old.status is distinct from new.status) execute function public.orders_payment_guard();

-- ---------------------------------------------------------------------------
-- Notifications for payments
-- ---------------------------------------------------------------------------

create function public.notify_payment_change()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  oref text;
begin
  select ref into oref from public.orders where id = new.order_id;
  if new.status is distinct from old.status then
    if new.status = 'succeeded' then
      perform public.notify(new.payer_id, 'orders', 'payment.succeeded', 'Payment received',
        'Your payment of K' || new.amount_zmw || ' for order ' || oref || ' went through.', '/order/' || new.order_id, 'payment:' || new.id || ':succeeded');
      perform public.notify(new.payee_id, 'orders', 'payment.received', 'You were paid',
        'A payment of K' || new.amount_zmw || ' was made for order ' || oref || '.', '/order/' || new.order_id, 'payment:' || new.id || ':received');
    elsif new.status = 'failed' then
      perform public.notify(new.payer_id, 'orders', 'payment.failed', 'Payment did not go through',
        coalesce(new.failure_reason, 'You can try again.'), '/order/' || new.order_id, 'payment:' || new.id || ':failed');
    end if;
  end if;
  return new;
end;
$$;
create trigger payments_notify after update of status on public.payments
  for each row when (old.status is distinct from new.status) execute function public.notify_payment_change();

create function public.notify_refund_processed()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  p public.payments;
begin
  select * into p from public.payments where id = new.payment_id;
  perform public.notify(p.payer_id, 'orders', 'refund.processed', 'Refund sent',
    'K' || new.amount_zmw || ' was refunded for payment ' || p.ref || '.', '/order/' || p.order_id, 'refund:' || new.id || ':processed');
  return new;
end;
$$;
create trigger refunds_notify after update of status on public.refunds
  for each row when (old.status is distinct from new.status and new.status = 'processed') execute function public.notify_refund_processed();

-- ---------------------------------------------------------------------------
-- Function permissions: closed first, then opened on purpose
-- ---------------------------------------------------------------------------

revoke execute on function
  public.payment_log(uuid, text, text, uuid, jsonb),
  public.start_payment(uuid, text, text, text),
  public.cancel_payment(uuid),
  public.record_provider_result(uuid, text, text, text, numeric, text),
  public.expire_stale_payments(),
  public.refund_apply(uuid, boolean, text, text, text, uuid),
  public.record_refund_result(uuid, boolean, text, text),
  public.finance_check(),
  public.finance_reconcile_payment(uuid, text, text, text),
  public.finance_request_refund(uuid, numeric, text),
  public.finance_decide_refund(uuid, boolean, text),
  public.finance_complete_refund(uuid, boolean, text, text),
  public.finance_payments(text, boolean, text, integer, integer),
  public.finance_payment_detail(uuid),
  public.finance_summary(integer),
  public.finance_refunds(text, integer),
  public.my_payments(uuid, integer),
  public.payments_enabled(),
  public.orders_payment_guard(),
  public.notify_payment_change(),
  public.notify_refund_processed()
from public, anon, authenticated;

grant execute on function
  public.start_payment(uuid, text, text, text),
  public.cancel_payment(uuid),
  public.my_payments(uuid, integer),
  public.payments_enabled(),
  public.finance_reconcile_payment(uuid, text, text, text),
  public.finance_request_refund(uuid, numeric, text),
  public.finance_decide_refund(uuid, boolean, text),
  public.finance_complete_refund(uuid, boolean, text, text),
  public.finance_payments(text, boolean, text, integer, integer),
  public.finance_payment_detail(uuid),
  public.finance_summary(integer),
  public.finance_refunds(text, integer)
to authenticated;

grant execute on function
  public.record_provider_result(uuid, text, text, text, numeric, text),
  public.expire_stale_payments(),
  public.record_refund_result(uuid, boolean, text, text)
to service_role;
