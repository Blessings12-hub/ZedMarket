-- Staff voting (migration 0015): the two-thirds rule at its boundaries, abstentions, non-participation, duplicate
-- votes, expiry, frozen eligibility, access control, secrecy, audit integrity, resubmission, cancellation,
-- notifications and function permissions.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/staff_voting.sql

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

-- Staff member number n (1..99).
create function zm_test.s(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000001' || lpad(n::text, 2, '0'))::uuid
$$;

-- Nine staff: 1-2 tech admin, 3 and 6-9 moderator, 4 support, 5 finance.
insert into auth.users (id, email, raw_user_meta_data)
select zm_test.s(n), 'staff' || n || '@example.test', json_build_object('display_name', 'Staff ' || n)::jsonb
  from generate_series(1, 9) n;
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000b', 'buyer@example.test', '{"display_name":"Buyer Bwalya"}'),
  (zm_test.s(50), 'late@example.test', '{"display_name":"Late Joiner"}');
insert into public.admin_roles (user_id, role) values
  (zm_test.s(1), 'tech_admin'), (zm_test.s(2), 'tech_admin'), (zm_test.s(3), 'moderator'),
  (zm_test.s(4), 'support'), (zm_test.s(5), 'finance'),
  (zm_test.s(6), 'moderator'), (zm_test.s(7), 'moderator'), (zm_test.s(8), 'moderator'), (zm_test.s(9), 'moderator');

update public.platform_settings set value = '0' where key = 'staff_vote.min_hours';
update public.platform_settings set value = '1000' where key = 'rate_limit.staff_proposal.max';

-- Opens a vote straight away as the given proposer and returns its id.
create function zm_test.new_vote(p_proposer integer, p_confidential boolean default false) returns uuid
language plpgsql as $$
declare pid uuid;
begin
  perform zm_test.act_as(zm_test.s(p_proposer), 'aal2');
  pid := public.create_staff_proposal('Test proposal ' || gen_random_uuid()::text, 'A description that is long enough.', 'A reason that is long enough.', p_confidential, true);
  perform public.submit_staff_proposal(pid, null, now() + interval '2 days');
  return pid;
end $$;

-- Staff n casts a choice; returns the proposal status afterwards.
create function zm_test.vote(p_n integer, p_id uuid, p_choice text) returns text
language plpgsql as $$
begin
  perform zm_test.act_as(zm_test.s(p_n), 'aal2');
  return public.cast_staff_vote(p_id, p_choice);
end $$;

-- Casts the same choice for staff first..last.
create function zm_test.vote_range(p_first integer, p_last integer, p_id uuid, p_choice text) returns text
language plpgsql as $$
declare r text;
begin
  for n in p_first..p_last loop
    r := zm_test.vote(n, p_id, p_choice);
  end loop;
  return r;
end $$;

-- Pretends the voting deadline has passed.
create function zm_test.expire(p_id uuid) returns void
language plpgsql as $$
begin
  perform zm_test.act_as_admin();
  alter table public.staff_proposals disable trigger staff_proposals_guard;
  update public.staff_proposals set opens_at = now() - interval '3 days', closes_at = now() - interval '1 minute' where id = p_id;
  alter table public.staff_proposals enable trigger staff_proposals_guard;
end $$;

-- What staff 1 sees of a proposal.
create function zm_test.seen(p_id uuid, p_column text) returns text
language plpgsql as $$
declare r text;
begin
  perform zm_test.act_as(zm_test.s(1), 'aal2');
  execute format('select %I::text from public.get_staff_proposal($1)', p_column) into r using p_id;
  return r;
end $$;

create function zm_test.notes(p_user uuid, p_type text) returns text language sql as $$
  select count(*)::text from public.notifications where user_id = p_user and type = p_type
$$;

-- 1. The threshold maths -----------------------------------------------------------------------------------
select zm_test.expect_equal(public.sv_required(1)::text, '1', 'required for 1');
select zm_test.expect_equal(public.sv_required(3)::text, '2', 'required for 3');
select zm_test.expect_equal(public.sv_required(4)::text, '3', 'required for 4 (2.67 rounds up)');
select zm_test.expect_equal(public.sv_required(9)::text, '6', 'required for 9 (exactly 6)');
select zm_test.expect_equal(public.sv_required(10)::text, '7', 'required for 10 (6.67 rounds up)');
select zm_test.expect_equal(public.sv_required(11)::text, '8', 'required for 11 (7.33 rounds up)');

-- 2. Opening: snapshot, threshold, reference, notifications --------------------------------------------------
select set_config('zm.v1', zm_test.new_vote(3)::text, true);
select zm_test.expect_equal(zm_test.seen(current_setting('zm.v1')::uuid, 'status'), 'active', 'vote opens straight away');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.v1')::uuid, 'eligible_count'), '9', 'nine staff are eligible');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.v1')::uuid, 'required_votes'), '6', 'two thirds of nine is six');
select zm_test.expect_equal((zm_test.seen(current_setting('zm.v1')::uuid, 'reference') ~ '^SV-[0-9]{4}-[0-9]{4}$')::text, 'true', 'proposal has a reference');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.staff_vote_eligibility where proposal_id = current_setting('zm.v1')::uuid), '9', 'snapshot holds nine rows');
select zm_test.expect_equal(zm_test.notes(zm_test.s(4), 'staff_vote.opened'), '1', 'each eligible person is told once');
select zm_test.expect_equal(zm_test.notes('00000000-0000-0000-0000-00000000000b', 'staff_vote.opened'), '0', 'non-staff are not told');

-- 3. Exactly two thirds FOR approves, and closes the vote at once --------------------------------------------
select zm_test.expect_equal(zm_test.vote_range(1, 5, current_setting('zm.v1')::uuid, 'for'), 'active', 'five of six: still open');
select zm_test.expect_equal(zm_test.vote(6, current_setting('zm.v1')::uuid, 'for'), 'approved', 'sixth FOR approves');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.v1')::uuid, 'outcome'), 'approved', 'outcome is shown');
select zm_test.expect_error($$select zm_test.vote(7, current_setting('zm.v1')::uuid, 'against')$$, 'no votes after the vote has closed');
select zm_test.act_as_admin();
select zm_test.expect_equal((select for_count || '/' || against_count || '/' || abstain_count from public.staff_vote_results where proposal_id = current_setting('zm.v1')::uuid), '6/0/0', 'stored counts');
select zm_test.expect_equal(zm_test.notes(zm_test.s(7), 'staff_vote.closed'), '1', 'everyone eligible hears the result');

-- 4. Exactly two thirds AGAINST rejects ----------------------------------------------------------------------
select set_config('zm.v2', zm_test.new_vote(4)::text, true);
select zm_test.vote_range(1, 5, current_setting('zm.v2')::uuid, 'against');
select zm_test.expect_equal(zm_test.vote(6, current_setting('zm.v2')::uuid, 'against'), 'rejected', 'sixth AGAINST rejects');

-- 5. More than two thirds: the vote is decided on the sixth, later votes are refused -------------------------
select set_config('zm.v3', zm_test.new_vote(5)::text, true);
select zm_test.vote_range(1, 5, current_setting('zm.v3')::uuid, 'abstain');
select zm_test.expect_equal(zm_test.vote_range(6, 9, current_setting('zm.v3')::uuid, 'for'), 'active', 'four FOR and five abstain: not decided');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.v3')::uuid, 'status'), 'active', 'abstentions never approve');

-- 6. A simple majority is never enough (5 FOR, 4 AGAINST of 9) ------------------------------------------------
select set_config('zm.v4', zm_test.new_vote(6)::text, true);
select zm_test.vote_range(1, 5, current_setting('zm.v4')::uuid, 'for');
select zm_test.expect_equal(zm_test.vote_range(6, 9, current_setting('zm.v4')::uuid, 'against'), 'active', 'five to four stays open');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.v4')::uuid, 'status'), 'active', 'a simple majority does not decide');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.v4')::uuid, 'for_count'), '5', 'live count FOR');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.v4')::uuid, 'against_count'), '4', 'live count AGAINST');
select zm_test.expire(current_setting('zm.v4')::uuid);
select zm_test.expect_equal(zm_test.seen(current_setting('zm.v4')::uuid, 'status'), 'unresolved', 'at the deadline a majority is still unresolved');
select zm_test.act_as_admin();
select zm_test.expect_equal((select closed_by from public.staff_vote_results where proposal_id = current_setting('zm.v4')::uuid), 'deadline', 'closed by the deadline');

-- 7. One vote short of two thirds (5 of 9), and the one-third boundary ---------------------------------------
select set_config('zm.v5', zm_test.new_vote(7)::text, true);
select zm_test.vote_range(1, 3, current_setting('zm.v5')::uuid, 'for');
select zm_test.vote_range(4, 6, current_setting('zm.v5')::uuid, 'against');
select zm_test.expire(current_setting('zm.v5')::uuid);
select zm_test.expect_equal(zm_test.seen(current_setting('zm.v5')::uuid, 'status'), 'unresolved', 'a third each is unresolved');

-- 8. Non-participation counts towards neither side -------------------------------------------------------------
select set_config('zm.v6', zm_test.new_vote(8)::text, true);
select zm_test.vote_range(1, 5, current_setting('zm.v6')::uuid, 'for'); -- 5 FOR, 4 did not vote
select zm_test.expire(current_setting('zm.v6')::uuid);
select zm_test.expect_equal(zm_test.seen(current_setting('zm.v6')::uuid, 'status'), 'unresolved', 'five FOR and four silent is not approval');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.v6')::uuid, 'eligible_count'), '9', 'silent staff stay in the denominator');

-- 9. Abstentions count towards neither side (6 FOR needed; 5 FOR + 4 abstain) -------------------------------
select set_config('zm.v7', zm_test.new_vote(9)::text, true);
select zm_test.vote_range(1, 5, current_setting('zm.v7')::uuid, 'for');
select zm_test.vote_range(6, 9, current_setting('zm.v7')::uuid, 'abstain');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.v7')::uuid, 'status'), 'active', 'abstentions do not help either side');
select zm_test.expire(current_setting('zm.v7')::uuid);
select zm_test.expect_equal(zm_test.seen(current_setting('zm.v7')::uuid, 'abstain_count'), '4', 'abstentions are recorded');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.v7')::uuid, 'status'), 'unresolved', 'ends unresolved');

-- 10. Duplicate and changed votes; direct writes ----------------------------------------------------------------
select set_config('zm.v8', zm_test.new_vote(1)::text, true);
select zm_test.vote(2, current_setting('zm.v8')::uuid, 'for');
select zm_test.expect_error($$select zm_test.vote(2, current_setting('zm.v8')::uuid, 'for')$$, 'the same vote twice');
select zm_test.expect_error($$select zm_test.vote(2, current_setting('zm.v8')::uuid, 'against')$$, 'a vote cannot be changed');
select zm_test.expect_error($$select zm_test.vote(3, current_setting('zm.v8')::uuid, 'maybe')$$, 'only for, against or abstain');
select zm_test.expect_error($$insert into public.staff_votes (proposal_id, voter_id, choice) values (current_setting('zm.v8')::uuid, zm_test.s(3), 'for')$$, 'no direct vote inserts');
select zm_test.expect_error($$select * from public.staff_votes$$, 'no direct reads of votes');
select zm_test.expect_error($$select * from public.staff_vote_results$$, 'no direct reads of results');
select zm_test.expect_error($$update public.staff_proposals set status = 'approved'$$, 'no direct proposal edits');
select zm_test.act_as_admin();
select zm_test.expect_error($$update public.staff_votes set choice = 'against'$$, 'even an administrator cannot edit a vote');
select zm_test.expect_error($$delete from public.staff_votes$$, 'even an administrator cannot delete a vote');
select zm_test.expect_error($$truncate public.staff_votes$$, 'nor empty the table');
select zm_test.expect_error($$update public.staff_vote_results set outcome = 'approved'$$, 'results cannot be edited');
select zm_test.expect_error($$delete from public.staff_vote_results$$, 'results cannot be deleted');
select zm_test.expect_error($$update public.staff_proposals set status = 'approved' where id = current_setting('zm.v8')::uuid$$, 'an active vote cannot be approved by hand');
select zm_test.expect_error($$update public.staff_proposals set title = 'A changed title here' where id = current_setting('zm.v8')::uuid$$, 'a submitted proposal cannot be edited');
select zm_test.expect_error($$update public.staff_proposals set title = 'A changed title here' where id = current_setting('zm.v1')::uuid$$, 'a closed proposal cannot be edited');
select zm_test.expect_error($$insert into public.staff_vote_results (proposal_id, eligible_count, required_votes, for_count, against_count, abstain_count, outcome, closed_by, ballot_digest)
  values (current_setting('zm.v8')::uuid, 9, 6, 5, 0, 0, 'approved', 'threshold', 'x')$$, 'a result that contradicts the counts cannot be stored');
select zm_test.expect_error($$insert into public.staff_vote_results (proposal_id, eligible_count, required_votes, for_count, against_count, abstain_count, outcome, closed_by, ballot_digest)
  values (current_setting('zm.v8')::uuid, 9, 5, 5, 0, 0, 'approved', 'threshold', 'x')$$, 'a wrong threshold cannot be stored');

-- 11. Eligibility is frozen when the vote opens --------------------------------------------------------------
select set_config('zm.v9', zm_test.new_vote(1)::text, true);
select zm_test.act_as_admin();
insert into public.admin_roles (user_id, role) values (zm_test.s(50), 'support');         -- joins after the vote opened
delete from public.admin_roles where user_id = zm_test.s(9);                                -- leaves after the vote opened
select zm_test.vote(8, current_setting('zm.v9')::uuid, 'for');
select zm_test.act_as_admin();
update public.profiles set account_state = 'suspended' where id = zm_test.s(8);             -- suspended after voting
select zm_test.expect_error($$select zm_test.vote(50, current_setting('zm.v9')::uuid, 'for')$$, 'someone who joined later cannot vote');
select zm_test.expect_error($$select zm_test.vote(9, current_setting('zm.v9')::uuid, 'for')$$, 'someone who left can no longer use staff tools');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.v9')::uuid, 'eligible_count'), '9', 'the denominator does not change');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.v9')::uuid, 'for_count'), '1', 'a vote already cast stays counted');
select zm_test.vote(1, current_setting('zm.v9')::uuid, 'for');
select zm_test.vote(2, current_setting('zm.v9')::uuid, 'for');
select zm_test.vote(3, current_setting('zm.v9')::uuid, 'for');
select zm_test.expect_equal(zm_test.vote(4, current_setting('zm.v9')::uuid, 'for'), 'active', 'five FOR with nine in the snapshot');
select zm_test.expect_equal(zm_test.vote(5, current_setting('zm.v9')::uuid, 'for'), 'approved', 'six FOR approves even though two people left or were suspended');
select zm_test.act_as_admin();
update public.profiles set account_state = 'active' where id = zm_test.s(8);
insert into public.admin_roles (user_id, role) values (zm_test.s(9), 'moderator');
delete from public.admin_roles where user_id = zm_test.s(50);

-- 12. Voting period rules ------------------------------------------------------------------------------------
select zm_test.act_as(zm_test.s(2), 'aal2');
select set_config('zm.d1', public.create_staff_proposal('Draft for period checks', 'A description that is long enough.', 'A reason that is long enough.', false, true)::text, true);
select zm_test.act_as_admin();
update public.platform_settings set value = '24' where key = 'staff_vote.min_hours';
update public.platform_settings set value = '336' where key = 'staff_vote.max_hours';
select zm_test.act_as(zm_test.s(2), 'aal2');
select zm_test.expect_error($$select public.submit_staff_proposal(current_setting('zm.d1')::uuid, null, now() + interval '2 hours')$$, 'too short a voting period');
select zm_test.expect_error($$select public.submit_staff_proposal(current_setting('zm.d1')::uuid, null, now() + interval '30 days')$$, 'too long a voting period');
select zm_test.expect_error($$select public.submit_staff_proposal(current_setting('zm.d1')::uuid, null, null)$$, 'a closing time is required');
select zm_test.expect_error($$select public.submit_staff_proposal(current_setting('zm.d1')::uuid, now() - interval '2 hours', now() + interval '3 days')$$, 'start time in the past');
select zm_test.act_as(zm_test.s(3), 'aal2');
select zm_test.expect_error($$select public.submit_staff_proposal(current_setting('zm.d1')::uuid, null, now() + interval '3 days')$$, 'only the proposer submits');
select zm_test.expect_error($$select public.update_staff_proposal(current_setting('zm.d1')::uuid, 'Someone elses edit', 'A description that is long enough.', 'A reason that is long enough.', false)$$, 'only the proposer edits a draft');
select zm_test.act_as(zm_test.s(2), 'aal2');
select public.update_staff_proposal(current_setting('zm.d1')::uuid, 'Draft after an edit', 'A description that is long enough.', 'A reason that is long enough.', false);
select zm_test.expect_equal(zm_test.seen(current_setting('zm.d1')::uuid, 'title'), null, 'a draft is private to its proposer');
select zm_test.act_as(zm_test.s(2), 'aal2');
select zm_test.expect_equal((select title from public.get_staff_proposal(current_setting('zm.d1')::uuid)), 'Draft after an edit', 'the proposer sees their draft');
select zm_test.expect_equal(public.submit_staff_proposal(current_setting('zm.d1')::uuid, now() + interval '1 day', now() + interval '3 days'), 'pending', 'a future start is scheduled');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.notifications where type = 'staff_vote.opened' and link like '%' || current_setting('zm.d1')), '0', 'a scheduled vote has not told anyone yet');
select zm_test.act_as(zm_test.s(2), 'aal2');
select zm_test.expect_error($$select zm_test.vote(3, current_setting('zm.d1')::uuid, 'for')$$, 'a pending vote cannot be voted on');
-- time passes: the scheduled start arrives
select zm_test.act_as_admin();
update public.staff_proposals set opens_at = now() - interval '1 minute' where id = current_setting('zm.d1')::uuid;
select zm_test.expect_equal(zm_test.seen(current_setting('zm.d1')::uuid, 'status'), 'active', 'a scheduled vote opens when its time comes');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.d1')::uuid, 'eligible_count'), '9', 'and freezes eligibility then');

-- 13. Cancelling -----------------------------------------------------------------------------------------------
select zm_test.act_as(zm_test.s(2), 'aal2');
select zm_test.expect_error($$select public.cancel_staff_proposal(current_setting('zm.d1')::uuid, 'I do not like how it is going')$$, 'a proposer cannot stop their own live vote');
select zm_test.act_as(zm_test.s(3), 'aal2');
select zm_test.expect_error($$select public.cancel_staff_proposal(current_setting('zm.d1')::uuid, 'Moderators cannot stop votes')$$, 'a non-admin cannot stop a live vote');
select zm_test.act_as(zm_test.s(1), 'aal2');
select zm_test.expect_error($$select public.cancel_staff_proposal(current_setting('zm.d1')::uuid, '  ')$$, 'a reason is required');
select public.cancel_staff_proposal(current_setting('zm.d1')::uuid, 'Wrong proposal text, will be redone');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.d1')::uuid, 'status'), 'cancelled', 'another tech admin can cancel');
select zm_test.expect_error($$select zm_test.vote(3, current_setting('zm.d1')::uuid, 'for')$$, 'no voting on a cancelled vote');
select zm_test.act_as(zm_test.s(3), 'aal2');
select set_config('zm.d2', public.create_staff_proposal('A draft I will withdraw', 'A description that is long enough.', 'A reason that is long enough.', false, true)::text, true);
select public.cancel_staff_proposal(current_setting('zm.d2')::uuid, 'Changed my mind');
select zm_test.expect_error($$select public.cancel_staff_proposal(current_setting('zm.d2')::uuid, 'Again')$$, 'already closed');

-- 14. Resubmitting an unresolved vote --------------------------------------------------------------------------
select zm_test.act_as(zm_test.s(6), 'aal2');
select set_config('zm.r1', public.resubmit_staff_proposal(current_setting('zm.v4')::uuid)::text, true);
select zm_test.expect_equal((select (n.reference <> o.reference)::text from public.get_staff_proposal(current_setting('zm.r1')::uuid) n, public.get_staff_proposal(current_setting('zm.v4')::uuid) o), 'true', 'new reference');
select zm_test.expect_equal((select status from public.get_staff_proposal(current_setting('zm.r1')::uuid)), 'draft', 'it starts as a draft');
select zm_test.expect_error($$select public.resubmit_staff_proposal(current_setting('zm.v4')::uuid)$$, 'only once');
select zm_test.act_as(zm_test.s(3), 'aal2');
select zm_test.expect_error($$select public.resubmit_staff_proposal(current_setting('zm.v5')::uuid)$$, 'a different non-admin cannot resubmit it');
select zm_test.expect_error($$select public.resubmit_staff_proposal(current_setting('zm.v1')::uuid)$$, 'an approved vote cannot be resubmitted');
select zm_test.expect_equal((select resubmitted_as::text from public.get_staff_proposal(current_setting('zm.v4')::uuid)), current_setting('zm.r1'), 'the original points at its resubmission');

-- 15. Who can do what --------------------------------------------------------------------------------------------
select zm_test.act_as('00000000-0000-0000-0000-00000000000b', 'aal2');
select zm_test.expect_error($$select * from public.list_staff_proposals()$$, 'non-staff cannot list');
select zm_test.expect_error($$select public.cast_staff_vote(current_setting('zm.v8')::uuid, 'for')$$, 'non-staff cannot vote');
select zm_test.expect_error($$select public.create_staff_proposal('Not allowed title', 'A description that is long enough.', 'A reason that is long enough.', false, true)$$, 'non-staff cannot propose');
select zm_test.act_as(zm_test.s(3), 'aal1');
select zm_test.expect_error($$select * from public.list_staff_proposals()$$, 'staff without two-factor cannot list');
select zm_test.expect_error($$select public.cast_staff_vote(current_setting('zm.v8')::uuid, 'for')$$, 'staff without two-factor cannot vote');
select zm_test.act_as_guest();
select zm_test.expect_error($$select * from public.list_staff_proposals()$$, 'guests cannot list');
select zm_test.expect_error($$select public.cast_staff_vote(current_setting('zm.v8')::uuid, 'for')$$, 'guests cannot vote');
select zm_test.act_as(zm_test.s(3), 'aal2');
select zm_test.expect_error($$select public.create_staff_proposal('Needs the confirmation', 'A description that is long enough.', 'A reason that is long enough.', false, false)$$, 'the no-override confirmation is required');
select zm_test.act_as_admin();
update public.platform_settings set value = '["tech_admin"]' where key = 'staff_vote.proposer_roles';
select zm_test.act_as(zm_test.s(3), 'aal2');
select zm_test.expect_error($$select public.create_staff_proposal('Role not allowed', 'A description that is long enough.', 'A reason that is long enough.', false, true)$$, 'proposer roles are configurable');
select zm_test.expect_equal((select can_propose::text from public.my_staff_vote_access()), 'false', 'the app is told');
select zm_test.act_as_admin();
update public.platform_settings set value = '["tech_admin","moderator","support","finance"]' where key = 'staff_vote.proposer_roles';

-- 16. Secrecy -----------------------------------------------------------------------------------------------------
select zm_test.act_as(zm_test.s(3), 'aal2');
select zm_test.expect_equal((select my_choice from public.get_staff_proposal(current_setting('zm.v8')::uuid)), null, 'staff 3 has not voted on v8');
select zm_test.act_as(zm_test.s(2), 'aal2');
select zm_test.expect_equal((select my_choice from public.get_staff_proposal(current_setting('zm.v8')::uuid)), 'for', 'a person sees their own vote');
select zm_test.expect_equal((select count(*)::text from public.my_staff_votes()), '9', 'history lists only my votes (staff 2 voted on nine proposals so far)');
select zm_test.expect_error($$select * from public.staff_vote_ballots(current_setting('zm.v8')::uuid)$$, 'ballots need a tech admin');
select zm_test.act_as(zm_test.s(3), 'aal2');
select zm_test.expect_error($$select * from public.staff_vote_ballots(current_setting('zm.v1')::uuid)$$, 'a moderator cannot read ballots');
select zm_test.expect_error($$select * from public.staff_vote_audit(current_setting('zm.v1')::uuid)$$, 'a moderator cannot read the audit trail');
select zm_test.act_as(zm_test.s(1), 'aal1');
select zm_test.expect_error($$select * from public.staff_vote_ballots(current_setting('zm.v1')::uuid)$$, 'a tech admin without two-factor cannot read ballots');
select zm_test.act_as(zm_test.s(1), 'aal2');
select zm_test.expect_error($$select * from public.staff_vote_ballots(current_setting('zm.v8')::uuid)$$, 'ballots stay closed while the vote is open');
select zm_test.expect_equal((select count(*)::text from public.staff_vote_ballots(current_setting('zm.v1')::uuid)), '6', 'a tech admin can read ballots of a closed vote');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action = 'staff_vote.ballots_read'), '1', 'reading ballots is audited');

-- confidential matter
select set_config('zm.c1', zm_test.new_vote(1, true)::text, true);
select zm_test.vote(2, current_setting('zm.c1')::uuid, 'for');
select zm_test.vote(3, current_setting('zm.c1')::uuid, 'against');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.c1')::uuid, 'for_count'), null, 'running counts are hidden on a confidential vote');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.c1')::uuid, 'counts_hidden'), 'true', 'and the app is told why');
select zm_test.act_as_admin();
select zm_test.expect_equal((select title from public.notifications where user_id = zm_test.s(5) and link like '%' || current_setting('zm.c1') limit 1), 'A confidential staff vote is open', 'the notification does not reveal the title');
select zm_test.vote_range(4, 8, current_setting('zm.c1')::uuid, 'for');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.c1')::uuid, 'status'), 'approved', 'six FOR approves');
select zm_test.expect_equal(zm_test.seen(current_setting('zm.c1')::uuid, 'for_count'), '6', 'counts appear once it has closed');
select zm_test.act_as(zm_test.s(1), 'aal2');
select zm_test.expect_error($$select * from public.staff_vote_ballots(current_setting('zm.c1')::uuid)$$, 'individual votes on a confidential matter are never shown');

-- 17. Audit integrity -----------------------------------------------------------------------------------------------
select zm_test.act_as(zm_test.s(1), 'aal2');
select zm_test.expect_equal(public.verify_staff_vote_audit(current_setting('zm.v1')::uuid)::text, 'true', 'the chain checks out');
select zm_test.expect_equal((select string_agg(action, ',' order by seq) from public.staff_vote_audit(current_setting('zm.v1')::uuid)), 'created,opened,vote_cast,vote_cast,vote_cast,vote_cast,vote_cast,vote_cast,closed,ballots_read', 'every step is recorded in order');
select zm_test.expect_equal((select count(*)::text from public.staff_vote_audit(current_setting('zm.v1')::uuid) where details::text ~* '(for|against|abstain)"? *:? *"?(for|against|abstain)'), '0', 'no vote choice appears in the audit trail');
select zm_test.act_as_admin();
select zm_test.expect_error($$update public.staff_vote_audit_logs set action = 'edited_row'$$, 'audit rows cannot be edited');
select zm_test.expect_error($$delete from public.staff_vote_audit_logs$$, 'audit rows cannot be deleted');
select zm_test.expect_error($$truncate public.staff_vote_audit_logs$$, 'the audit table cannot be emptied');
select zm_test.expect_error($$insert into public.staff_vote_audit_logs (proposal_id, seq, action, row_hash) values (current_setting('zm.v1')::uuid, 3, 'forged', 'x')$$, 'the chain cannot be forked');
-- an insider who switches the guard off and edits a row is caught by the hash chain
alter table public.staff_vote_audit_logs disable trigger staff_vote_audit_frozen;
update public.staff_vote_audit_logs set details = '{"eligible": 3}' where proposal_id = current_setting('zm.v1')::uuid and action = 'opened';
alter table public.staff_vote_audit_logs enable trigger staff_vote_audit_frozen;
select zm_test.act_as(zm_test.s(1), 'aal2');
select zm_test.expect_equal(public.verify_staff_vote_audit(current_setting('zm.v1')::uuid)::text, 'false', 'tampering is detected');
select zm_test.expect_equal(public.verify_staff_vote_audit(current_setting('zm.v2')::uuid)::text, 'true', 'other chains are unaffected');
-- the ballot digest lets someone check the ballots against the closed result
select zm_test.act_as_admin();
select zm_test.expect_equal((select ballot_digest from public.staff_vote_results where proposal_id = current_setting('zm.v1')::uuid),
  (select encode(sha256(convert_to(string_agg(voter_id::text || ':' || choice, ',' order by voter_id), 'utf8')), 'hex') from public.staff_votes where proposal_id = current_setting('zm.v1')::uuid), 'ballot digest matches');

-- 18. Notifications are sent once --------------------------------------------------------------------------------------
select zm_test.expect_equal((select count(*)::text from public.notifications where type = 'staff_vote.opened' and user_id = zm_test.s(4) and link like '%' || current_setting('zm.v1')), '1', 'one opening notice per person per vote');
select zm_test.expect_equal((select count(*)::text from public.notifications where type = 'staff_vote.closed' and user_id = zm_test.s(4) and link like '%' || current_setting('zm.v1')), '1', 'one closing notice per person per vote');
select zm_test.act_as_service();
select public.staff_vote_tick();
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.notifications where type = 'staff_vote.closed' and user_id = zm_test.s(4) and link like '%' || current_setting('zm.v1')), '1', 'running the job again sends nothing twice');

-- 19. The job closes a finished vote without anyone looking at it -------------------------------------------------------
select set_config('zm.j1', zm_test.new_vote(1)::text, true);
select zm_test.vote(2, current_setting('zm.j1')::uuid, 'for');
select zm_test.expire(current_setting('zm.j1')::uuid);
select zm_test.act_as_service();
select public.staff_vote_tick();
select zm_test.act_as_admin();
select zm_test.expect_equal((select status from public.staff_proposals where id = current_setting('zm.j1')::uuid), 'unresolved', 'the job closed it');
select zm_test.expect_error($$select zm_test.vote(3, current_setting('zm.j1')::uuid, 'for')$$, 'a vote after the deadline is refused');

-- 20. Function permissions ----------------------------------------------------------------------------------------------
select zm_test.expect_equal((select bool_or(has_function_privilege('authenticated', p.oid, 'execute'))::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('sv_log', 'sv_open', 'sv_settle', 'sv_advance', 'sv_advance_all', 'sv_view', 'sv_need_staff', 'sv_required', 'staff_vote_tick', 'sv_guard_proposal', 'sv_guard_vote', 'sv_guard_result', 'sv_block_change')), 'false', 'internal and job functions are closed to the app');
select zm_test.expect_equal((select bool_or(has_function_privilege('anon', p.oid, 'execute'))::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and (p.proname like '%staff_vote%' or p.proname like '%staff_proposal%' or p.proname = 'cast_staff_vote' or p.proname = 'list_staff_proposals' or p.proname = 'get_staff_proposal')), 'false', 'guests can run none of them');
select zm_test.expect_equal(has_function_privilege('service_role', 'public.staff_vote_tick()', 'execute')::text, 'true', 'the job can run');
select zm_test.expect_equal((select bool_and(c.relrowsecurity)::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname in ('staff_proposals', 'staff_vote_eligibility', 'staff_votes', 'staff_vote_results', 'staff_vote_audit_logs')), 'true', 'row level security is on for every voting table');
select zm_test.expect_equal((select count(*)::text from information_schema.role_table_grants where table_schema = 'public'
   and table_name in ('staff_proposals', 'staff_vote_eligibility', 'staff_votes', 'staff_vote_results', 'staff_vote_audit_logs') and grantee in ('anon', 'authenticated')), '0', 'no table grants for app users');

-- 21. A vote cannot open without enough staff ---------------------------------------------------------------------------
select zm_test.act_as(zm_test.s(1), 'aal2');
select set_config('zm.m1', public.create_staff_proposal('Too few staff to vote', 'A description that is long enough.', 'A reason that is long enough.', false, true)::text, true);
select zm_test.act_as_admin();
delete from public.admin_roles where user_id not in (zm_test.s(1), zm_test.s(2));
select zm_test.act_as(zm_test.s(1), 'aal2');
select zm_test.expect_error($$select public.submit_staff_proposal(current_setting('zm.m1')::uuid, null, now() + interval '2 days')$$, 'two staff are not enough to vote');

select zm_test.act_as_admin();
select 'Staff voting checks passed' as result;
rollback;
