-- Support (migration 0014): who can open and read tickets, staff-only notes, assignment, escalation with a
-- second resolver, resolution, rating, reopening, auto close, evidence paths, performance figures, permissions.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/support.sql

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
  ('00000000-0000-0000-0000-0000000000f2', 'finance'),
  ('00000000-0000-0000-0000-0000000000f1', 'support'),
  ('00000000-0000-0000-0000-0000000000f2', 'tech_admin');
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



create function zm_test.tstatus(p_id uuid) returns text language sql security definer as $$
  select status from public.support_tickets where id = p_id;
$$;
grant execute on function zm_test.tstatus(uuid) to anon, authenticated, service_role;

-- 1. Opening tickets
select zm_test.act_as_guest();
select zm_test.expect_error($$select public.open_ticket('other', 'Hello there', 'This is a long enough description')$$, 'guests cannot open tickets');
select zm_test.act_as(:'B');
select zm_test.expect_error($$select public.open_ticket('nonsense', 'Hello there', 'This is a long enough description')$$, 'unknown category');
select zm_test.expect_error($$select public.open_ticket('other', 'Hi', 'This is a long enough description')$$, 'subject too short');
select zm_test.expect_error($$select public.open_ticket('other', 'Hello there', 'short')$$, 'description too short');
select zm_test.expect_error($$select public.open_ticket('order_problem', 'Wrong item', 'The item is not what was described', gen_random_uuid())$$, 'order must exist and be theirs');
insert into zm_ids values ('t1', (public.open_ticket('payment_problem', 'Money taken twice', 'I was charged two times for one order')).id);
select zm_test.act_as_admin();
select zm_test.expect_equal((select priority from public.support_tickets where id = (select id from zm_ids where name = 't1')), 'high', 'payment problems start as high priority');
select zm_test.expect_equal((select count(*)::text from public.support_messages where ticket_id = (select id from zm_ids where name = 't1')), '1', 'the description is the first message');
select zm_test.expect_equal((select ((due_at - created_at) between interval '7 hours 59 minutes' and interval '8 hours 1 minute')::text from public.support_tickets where id = (select id from zm_ids where name = 't1')), 'true', 'due time follows the priority');
-- an order ticket needs a real order the person is part of
insert into zm_ids values ('l1', zm_test.fresh_listing(100));
select zm_test.act_as(:'B');
insert into zm_ids values ('o1', (public.create_order((select id from zm_ids where name = 'l1'))).id);
select zm_test.act_as(:'C');
select zm_test.expect_error($$select public.open_ticket('order_problem', 'Not my order', 'I am trying to link someone else order', (select id from zm_ids where name = 'o1'))$$, 'cannot attach someone else''s order');
select zm_test.act_as(:'B');
insert into zm_ids values ('t2', (public.open_ticket('order_problem', 'Seller not replying', 'The seller has not answered for two days', (select id from zm_ids where name = 'o1'))).id);
-- limit on open tickets
select zm_test.act_as_admin();
update public.platform_settings set value = '3' where key = 'support.max_open_per_user';
select zm_test.act_as(:'B');
insert into zm_ids values ('t3', (public.open_ticket('other', 'Third question', 'Another question about the app here')).id);
select zm_test.expect_error($$select public.open_ticket('other', 'Fourth question', 'One more question about the app here')$$, 'too many open tickets');
select zm_test.act_as_admin();
update public.platform_settings set value = '5' where key = 'support.max_open_per_user';
-- a suspended account can still ask for help
update public.profiles set account_state = 'suspended' where id = :'C';
select zm_test.act_as(:'C');
insert into zm_ids values ('t4', (public.open_ticket('account_access', 'I was suspended', 'I think my account was suspended by mistake')).id);
select zm_test.act_as_admin();
update public.profiles set account_state = 'active' where id = :'C';

-- 2. Who can read what
select zm_test.act_as(:'B');
select zm_test.expect_equal((select count(*)::text from public.support_tickets), '3', 'customer sees own tickets');
select zm_test.expect_error($$select assigned_to from public.support_tickets$$, 'assignee is hidden from customers');
select zm_test.expect_error($$select escalation_reason from public.support_tickets$$, 'escalation reason is hidden from customers');
select zm_test.expect_error($$select * from public.support_events$$, 'events are staff only');
select zm_test.expect_error($$update public.support_tickets set status = 'resolved'$$, 'customers cannot change tickets');
select zm_test.expect_error($$insert into public.support_messages (ticket_id, author_id, author_role, body) values ((select id from zm_ids where name = 't1'), '00000000-0000-0000-0000-00000000000b', 'staff', 'fake staff message')$$, 'customers cannot write messages directly');
select zm_test.act_as(:'S');
select zm_test.expect_equal((select count(*)::text from public.support_tickets), '0', 'other people see nothing');
select zm_test.expect_equal((select count(*)::text from public.support_messages), '0', 'other people see no messages');
select zm_test.expect_error($$select * from public.support_queue()$$, 'ordinary users cannot read the queue');
select zm_test.expect_error($$select public.support_ticket_detail((select id from zm_ids where name = 't1'))$$, 'ordinary users cannot read details');
select zm_test.act_as(:'MOD', 'aal2');
select zm_test.expect_error($$select * from public.support_queue()$$, 'moderators are not support');
select zm_test.act_as(:'SUP', 'aal1');
select zm_test.expect_error($$select * from public.support_queue()$$, 'support needs two-factor');

-- 3. Working a ticket
select zm_test.act_as(:'SUP', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.support_queue()), '4', 'support sees all open tickets');
select zm_test.expect_equal(((select ref from public.support_queue() limit 1) like 'SUP-%')::text, 'true', 'refs look right');
select zm_test.expect_error($$select public.support_reply((select id from zm_ids where name = 't1'), 'I will look at this', false)$$, 'must take the ticket before replying');
select public.support_claim((select id from zm_ids where name = 't1'));
select zm_test.expect_error($$select public.support_claim((select id from zm_ids where name = 't1'))$$, 'cannot take an already taken ticket');
select zm_test.act_as(:'F1', 'aal2');
select zm_test.expect_error($$select public.support_claim((select id from zm_ids where name = 't1'))$$, 'another agent cannot take it');
select zm_test.expect_error($$select public.support_reply((select id from zm_ids where name = 't1'), 'I am not the owner', false)$$, 'another agent cannot reply to it');
select zm_test.expect_error($$select public.support_resolve((select id from zm_ids where name = 't1'), 'fixed', 'I am not the owner of this one')$$, 'another agent cannot resolve it');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.tstatus((select id from zm_ids where name = 't1')), 'in_progress', 'taking moves it to in progress');
select zm_test.act_as(:'SUP', 'aal2');
select public.support_reply((select id from zm_ids where name = 't1'), 'Internal: payment looks duplicated in the ledger', true);
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.tstatus((select id from zm_ids where name = 't1')), 'in_progress', 'an internal note does not change the status');
select zm_test.expect_equal((select (first_response_at is null)::text from public.support_tickets where id = (select id from zm_ids where name = 't1')), 'true', 'an internal note is not a first response');
select zm_test.expect_equal(zm_test.count_for(:'B', 'support.reply'), '0', 'no notification for an internal note');
select zm_test.act_as(:'SUP', 'aal2');
select public.support_reply((select id from zm_ids where name = 't1'), 'Thanks, we are checking both charges now.', false);
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.tstatus((select id from zm_ids where name = 't1')), 'waiting_on_customer', 'a public reply waits for the customer');
select zm_test.expect_equal((select (first_response_at is not null)::text from public.support_tickets where id = (select id from zm_ids where name = 't1')), 'true', 'first response is recorded');
select zm_test.expect_equal(zm_test.count_for(:'B', 'support.reply'), '1', 'customer is told about the reply');
select zm_test.expect_equal((select bool_and(body not like '%checking both%' and coalesce(title, '') not like '%checking both%')::text from public.notifications where user_id = :'B' and type = 'support.reply'), 'true', 'the reply text is not in the notification');
select zm_test.act_as(:'B');
select zm_test.expect_equal((select count(*)::text from public.support_messages where ticket_id = (select id from zm_ids where name = 't1')), '2', 'customer sees the question and the public reply, not the internal note');
select zm_test.expect_equal((select bool_or(unread_reply)::text from public.my_tickets() where id = (select id from zm_ids where name = 't1')), 'true', 'reply shows as unread');
select zm_test.act_as(:'S');
select zm_test.expect_error($$select public.reply_ticket((select id from zm_ids where name = 't1'), 'I am not the owner')$$, 'strangers cannot reply');
select zm_test.act_as(:'B');
select public.reply_ticket((select id from zm_ids where name = 't1'), 'Both charges are on 3 March.');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.tstatus((select id from zm_ids where name = 't1')), 'in_progress', 'a customer reply puts it back in progress');
select zm_test.act_as(:'SUP', 'aal2');
select zm_test.expect_error($$select public.support_set_status((select id from zm_ids where name = 't1'), 'closed')$$, 'only two statuses can be set by hand');
select public.support_set_status((select id from zm_ids where name = 't1'), 'waiting_on_customer');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.tstatus((select id from zm_ids where name = 't1')), 'waiting_on_customer', 'status set by hand');
select zm_test.expect_equal((select count(*)::text from public.support_events where ticket_id = (select id from zm_ids where name = 't1') and event = 'internal_note'), '1', 'note logged as an event');

-- 4. Detail shows internal notes to staff only
select zm_test.act_as(:'SUP', 'aal2');
select zm_test.expect_equal((select jsonb_array_length(public.support_ticket_detail((select id from zm_ids where name = 't1')) -> 'messages'))::text, '4', 'staff see all messages including the internal note');
select zm_test.expect_equal((public.support_ticket_detail((select id from zm_ids where name = 't1')) -> 'requester' ->> 'other_open_tickets'), '2', 'detail shows the requester''s other open tickets');

-- 5. Evidence files
select zm_test.act_as(:'B');
select public.add_ticket_attachment((select id from zm_ids where name = 't1'), :'B' || '/' || (select id from zm_ids where name = 't1') || '/photo-1.jpg');
select zm_test.expect_error($$select public.add_ticket_attachment((select id from zm_ids where name = 't1'), '00000000-0000-0000-0000-00000000000c/' || (select id from zm_ids where name = 't1') || '/photo-2.jpg')$$, 'cannot point at someone else''s folder');
select zm_test.expect_error($$select public.add_ticket_attachment((select id from zm_ids where name = 't1'), '00000000-0000-0000-0000-00000000000b/other/photo-2.jpg')$$, 'wrong ticket folder');
select zm_test.expect_error($$select public.add_ticket_attachment((select id from zm_ids where name = 't1'), '00000000-0000-0000-0000-00000000000b/' || (select id from zm_ids where name = 't1') || '/../x.jpg')$$, 'no path tricks');
select zm_test.act_as(:'S');
select zm_test.expect_error($$select public.add_ticket_attachment((select id from zm_ids where name = 't1'), '00000000-0000-0000-0000-00000000000a/' || (select id from zm_ids where name = 't1') || '/x.jpg')$$, 'others cannot attach to it');
select zm_test.act_as(:'B');
select public.add_ticket_attachment((select id from zm_ids where name = 't1'), :'B' || '/' || (select id from zm_ids where name = 't1') || '/photo-3.jpg');
select public.add_ticket_attachment((select id from zm_ids where name = 't1'), :'B' || '/' || (select id from zm_ids where name = 't1') || '/photo-4.jpg');
select public.add_ticket_attachment((select id from zm_ids where name = 't1'), :'B' || '/' || (select id from zm_ids where name = 't1') || '/photo-5.jpg');
select public.add_ticket_attachment((select id from zm_ids where name = 't1'), :'B' || '/' || (select id from zm_ids where name = 't1') || '/photo-6.jpg');
select zm_test.expect_error($$select public.add_ticket_attachment((select id from zm_ids where name = 't1'), '00000000-0000-0000-0000-00000000000b/' || (select id from zm_ids where name = 't1') || '/photo-7.jpg')$$, 'at most five files');
select zm_test.expect_equal((select count(*)::text from public.support_attachments), '5', 'customer sees own attachments');
select zm_test.act_as(:'S');
select zm_test.expect_equal((select count(*)::text from public.support_attachments), '0', 'others see none');

-- 6. Escalation needs a second person
select zm_test.act_as(:'SUP', 'aal2');
select zm_test.expect_error($$select public.support_escalate((select id from zm_ids where name = 't1'), 'short')$$, 'escalation needs a real reason');
select public.support_escalate((select id from zm_ids where name = 't1'), 'Possible double charge, needs finance and a second look');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.tstatus((select id from zm_ids where name = 't1')), 'escalated', 'escalated');
select zm_test.expect_equal((select (assigned_to is null)::text from public.support_tickets where id = (select id from zm_ids where name = 't1')), 'true', 'escalating releases the ticket');
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action = 'support.escalated'), '1', 'escalation is audited');
select zm_test.act_as_admin();
update public.support_tickets set priority = 'urgent' where id = (select id from zm_ids where name = 't4');
select zm_test.act_as(:'SUP', 'aal2');
select zm_test.expect_error($$select public.support_claim((select id from zm_ids where name = 't1'))$$, 'the person who escalated cannot take it back');
select zm_test.expect_equal((select status from public.support_queue() limit 1), 'escalated', 'escalated tickets sort first');
select zm_test.act_as(:'F1', 'aal2');
select public.support_claim((select id from zm_ids where name = 't1'));
select zm_test.expect_error($$select public.support_resolve((select id from zm_ids where name = 't1'), 'fixed', 'short')$$, 'note needed');
select zm_test.expect_error($$select public.support_resolve((select id from zm_ids where name = 't1'), 'bogus', 'A long enough note about the fix')$$, 'unknown resolution code');
select zm_test.act_as(:'F2', 'aal2');
select zm_test.expect_error($$select public.support_assign((select id from zm_ids where name = 't1'), '00000000-0000-0000-0000-00000000000e')$$, 'cannot be handed back to the one who escalated');
select zm_test.expect_error($$select public.support_assign((select id from zm_ids where name = 't1'), '00000000-0000-0000-0000-00000000000a')$$, 'cannot assign to someone outside support');
select zm_test.act_as(:'SUP', 'aal2');
select zm_test.expect_error($$select public.support_assign((select id from zm_ids where name = 't1'), '00000000-0000-0000-0000-0000000000f1')$$, 'only tech admins can assign');
-- A tech admin can assign an open ticket to a support agent, and unassign it
select zm_test.act_as(:'SUP', 'aal2');
select zm_test.expect_error($$select public.support_assign((select id from zm_ids where name = 't2'), '00000000-0000-0000-0000-0000000000f1')$$, 'support agents cannot assign');
select zm_test.act_as(:'F2', 'aal2');
select public.support_assign((select id from zm_ids where name = 't2'), :'SUP');
select zm_test.expect_equal((select assigned_to::text from public.support_queue() where id = (select id from zm_ids where name = 't2')), :'SUP', 'tech admin assigned it');
select zm_test.expect_error($$select public.support_assign((select id from zm_ids where name = 't2'), '00000000-0000-0000-0000-00000000000a')$$, 'cannot assign to someone outside support (open ticket)');
select public.support_assign((select id from zm_ids where name = 't2'), null);
select zm_test.expect_equal(((select assigned_to::text from public.support_queue() where id = (select id from zm_ids where name = 't2')) is null)::text, 'true', 'unassigned again');

select zm_test.act_as_admin();
-- Even if it ended up with the escalator, resolving is still refused
update public.support_tickets set assigned_to = :'SUP' where id = (select id from zm_ids where name = 't1');
select zm_test.act_as(:'SUP', 'aal2');
select zm_test.expect_error($$select public.support_resolve((select id from zm_ids where name = 't1'), 'fixed', 'Trying to resolve my own escalation')$$, 'the escalator can never resolve');
select zm_test.act_as_admin();
update public.support_tickets set assigned_to = :'F1' where id = (select id from zm_ids where name = 't1');
select zm_test.act_as(:'F1', 'aal2');
select public.support_resolve((select id from zm_ids where name = 't1'), 'refunded', 'Second charge refunded by finance, customer told');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.tstatus((select id from zm_ids where name = 't1')), 'resolved', 'resolved by the second person');
select zm_test.expect_equal(zm_test.count_for(:'B', 'support.resolved'), '1', 'customer is told it was resolved');
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action = 'support.resolved'), '1', 'resolution is audited');
select zm_test.act_as(:'F1', 'aal2');
select zm_test.expect_error($$select public.support_reply((select id from zm_ids where name = 't1'), 'Too late to reply here', false)$$, 'staff cannot reply to a finished ticket');
select zm_test.expect_error($$select public.support_resolve((select id from zm_ids where name = 't1'), 'fixed', 'Resolving a second time again')$$, 'cannot resolve twice');

-- 7. Customer after resolution
select zm_test.act_as(:'C');
select zm_test.expect_error($$select public.rate_ticket((select id from zm_ids where name = 't1'), 5)$$, 'only the owner can rate');
select zm_test.act_as(:'B');
select zm_test.expect_error($$select public.rate_ticket((select id from zm_ids where name = 't1'), 9)$$, 'rating must be 1 to 5');
select zm_test.expect_error($$select public.rate_ticket((select id from zm_ids where name = 't2'), 5)$$, 'cannot rate an unfinished ticket');
select public.rate_ticket((select id from zm_ids where name = 't1'), 4, 'Quick and polite');
select zm_test.expect_error($$select public.rate_ticket((select id from zm_ids where name = 't1'), 1)$$, 'rating only once');
select zm_test.expect_equal((select resolution_note from public.support_tickets where id = (select id from zm_ids where name = 't1')), 'Second charge refunded by finance, customer told', 'customer can read the resolution');
-- reopening
select public.reply_ticket((select id from zm_ids where name = 't1'), 'The refund has not arrived on my phone yet.');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.tstatus((select id from zm_ids where name = 't1')), 'in_progress', 'a reply reopens a recently resolved ticket');
select zm_test.expect_equal((select reopened_count::text from public.support_tickets where id = (select id from zm_ids where name = 't1')), '1', 'reopen counted');
select zm_test.act_as(:'F1', 'aal2');
select public.support_resolve((select id from zm_ids where name = 't1'), 'explained', 'Refunds take up to three days to show');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.count_for(:'B', 'support.resolved'), '2', 'a second resolution notifies again');
-- too late to reopen
update public.support_tickets set resolved_at = now() - interval '8 days' where id = (select id from zm_ids where name = 't1');
select zm_test.act_as(:'B');
select zm_test.expect_error($$select public.reply_ticket((select id from zm_ids where name = 't1'), 'Writing after the reopen window')$$, 'cannot reopen after the window');
-- auto close
select zm_test.act_as_admin();
update public.platform_settings set value = '7' where key = 'support.auto_close_days';
select zm_test.act_as_service();
select zm_test.expect_equal(public.close_resolved_tickets()::text, '1', 'the old resolved ticket is closed');
select zm_test.expect_equal(public.close_resolved_tickets()::text, '0', 'nothing else to close');
select zm_test.act_as(:'B');
select zm_test.expect_error($$select public.reply_ticket((select id from zm_ids where name = 't1'), 'Writing to a closed ticket')$$, 'closed tickets take no replies');
select zm_test.expect_error($$select public.add_ticket_attachment((select id from zm_ids where name = 't1'), '00000000-0000-0000-0000-00000000000b/' || (select id from zm_ids where name = 't1') || '/late.jpg')$$, 'closed tickets take no files');
-- customer closing
select public.customer_close_ticket((select id from zm_ids where name = 't3'));
select zm_test.act_as_admin();
select zm_test.expect_equal((select status || ':' || resolution_code from public.support_tickets where id = (select id from zm_ids where name = 't3')), 'closed:customer_withdrew', 'withdrawing closes it');
select zm_test.act_as(:'S');
select zm_test.expect_error($$select public.customer_close_ticket((select id from zm_ids where name = 't2'))$$, 'others cannot close it');
select zm_test.act_as(:'SUP', 'aal2');
select zm_test.expect_error($$select public.close_resolved_tickets()$$, 'staff cannot run the auto-close job');

-- 8. Staff cannot work their own ticket
select zm_test.act_as(:'SUP', 'aal2');
insert into zm_ids values ('t5', (public.open_ticket('other', 'Staff question', 'A support agent has a question of their own')).id);
select zm_test.expect_equal((select count(*)::text from public.support_queue() where id = (select id from zm_ids where name = 't5')), '0', 'own ticket is not in the staff queue');
select zm_test.expect_error($$select public.support_claim((select id from zm_ids where name = 't5'))$$, 'cannot take their own ticket');
select zm_test.expect_error($$select public.support_ticket_detail((select id from zm_ids where name = 't5'))$$, 'cannot read their own ticket as staff');
select zm_test.expect_equal((select count(*)::text from public.support_tickets where id = (select id from zm_ids where name = 't5')), '1', 'but they can read it as a customer');
select zm_test.act_as(:'F1', 'aal2');
select public.support_claim((select id from zm_ids where name = 't5'));
select public.support_resolve((select id from zm_ids where name = 't5'), 'explained', 'Explained how the app works to the agent');
select zm_test.act_as_admin();
update public.support_tickets set resolved_at = now() - interval '1 day' where id = (select id from zm_ids where name = 't5');
select zm_test.act_as_service();
select zm_test.expect_equal(public.close_resolved_tickets()::text, '0', 'a recently resolved ticket is not closed yet');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.tstatus((select id from zm_ids where name = 't5')), 'resolved', 'still resolved');
-- credit goes to the person who resolved it, not whoever it was assigned to
update public.support_tickets set assigned_to = :'SUP' where id = (select id from zm_ids where name = 't1');

-- 9. Overdue and filters
select zm_test.act_as_admin();
update public.support_tickets set due_at = now() - interval '2 hours' where id = (select id from zm_ids where name = 't2');
select zm_test.act_as(:'SUP', 'aal2');
select zm_test.expect_equal((select id::text from public.support_queue(null, 'all', null, true)), (select id::text from zm_ids where name = 't2'), 'overdue filter finds the late ticket');
select zm_test.expect_equal((select count(*)::text from public.support_queue(null, 'unassigned')), '2', 'unassigned filter (the order ticket and the suspended user''s ticket)');
select zm_test.expect_equal((select count(*)::text from public.support_queue(null, 'all', null, false, 'wrong item')), '0', 'search finds nothing for unknown text');
select zm_test.expect_equal((select count(*)::text from public.support_queue(null, 'all', null, false, 'seller')), '1', 'search by subject');
select zm_test.expect_equal((select count(*)::text from public.support_queue(null, 'all', null, false, '%')), '2', 'a percent sign is not a wildcard (it is dropped, so this is the plain open list)');
select zm_test.expect_equal((select count(*)::text from public.support_queue('closed')), '2', 'status filter shows closed tickets (the auto-closed one and the withdrawn one)');

-- 10. Performance figures
select zm_test.act_as(:'SUP', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.support_performance(30)), '1', 'support staff see only their own performance');
select zm_test.act_as(:'F2', 'aal2');
select zm_test.expect_equal((select count(*)::text from public.support_performance(30)), '3', 'tech admins see every agent');
select zm_test.expect_equal((select resolved::text from public.support_performance(30) where agent_id = :'F1'), '2', 'resolved count (the first resolution of the first ticket was undone by the reopen; only the last counts)');
select zm_test.expect_equal((select avg_rating::text from public.support_performance(30) where agent_id = :'F1'), '4.00', 'rating shows against the resolver');
select zm_test.expect_equal((select value::text from public.support_overview(30) where metric = 'created'), '5', 'overview counts created tickets');
select zm_test.expect_equal((select value::text from public.support_overview(30) where metric = 'overdue_now'), '1', 'overview counts overdue');
select zm_test.expect_equal((select value::text from public.support_overview(30) where metric = 'category:payment_problem'), '1', 'category counts');
select zm_test.act_as(:'B');
select zm_test.expect_error($$select * from public.support_overview(30)$$, 'customers cannot see monitoring');
select zm_test.expect_error($$select * from public.support_performance(30)$$, 'customers cannot see performance');

-- 11. Appeals now notify
select zm_test.act_as(:'B');
insert into public.appeals (target_type, target_id, message) values ('listing', gen_random_uuid(), 'I think this decision was wrong, please look again.');
select zm_test.act_as(:'MOD', 'aal2');
select public.review_appeal((select id from public.appeals limit 1), 'overturned', 'Decision reversed after a second look');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.count_for(:'B', 'appeal.reviewed'), '1', 'the person is told the appeal outcome');
select zm_test.act_as(:'B');
insert into public.appeals (target_type, target_id, message) values ('listing', gen_random_uuid(), 'A second appeal that should be turned down.');
select zm_test.act_as(:'MOD', 'aal2');
select public.review_appeal((select id from public.appeals where status = 'open' limit 1), 'upheld', 'The first decision stands');
select zm_test.act_as_admin();
select zm_test.expect_equal((select body from public.notifications where user_id = :'B' and type = 'appeal.reviewed' and body like 'The original%'), 'The original decision was kept.', 'wording for a rejected appeal');
select zm_test.expect_equal((select body from public.notifications where user_id = :'B' and type = 'appeal.reviewed' and body like 'The decision%'), 'The decision was reversed.', 'wording matches the outcome');

-- 12. Function permissions
select zm_test.expect_equal((select bool_or(has_function_privilege('authenticated', p.oid, 'execute'))::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('support_log', 'support_check', 'support_work', 'support_priority_rank', 'close_resolved_tickets', 'notify_support_message', 'notify_support_resolved', 'notify_appeal_reviewed')), 'false', 'internal and job functions are closed to the app');
select zm_test.expect_equal((select has_function_privilege('service_role', 'public.close_resolved_tickets()', 'execute'))::text, 'true', 'the job can run');
select zm_test.act_as_guest();
select zm_test.expect_error($$select * from public.my_tickets()$$, 'guests have no tickets');
select zm_test.expect_error($$select * from public.support_categories$$, 'guests cannot read categories');
select zm_test.act_as(:'B');
select zm_test.expect_equal((select count(*)::text from public.support_categories), '9', 'categories are readable');

select zm_test.act_as_admin();
select 'Support checks passed' as result;
rollback;
