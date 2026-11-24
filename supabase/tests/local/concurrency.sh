#!/usr/bin/env bash
# Races between people acting at the same moment (migration 0009).
#
# The SQL tests run in one transaction, so they cannot show what happens when two people
# press a button together. This script can: it opens many real database connections, holds
# them all at a starting line, releases them at once, and then checks that the order rules
# still hold. Every scenario is repeated for several different items in the same release.
#
# Needs DATABASE_URL pointing at a superuser connection to a local or CI server, never production:
#   DATABASE_URL="postgres://postgres:postgres@localhost:5432/postgres" supabase/tests/local/concurrency.sh
set -u

if [ -z "${DATABASE_URL:-}" ]; then
  echo "Set DATABASE_URL to a superuser connection on a local or CI database." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DB="zedmarket_race_$$"
WORK="$(mktemp -d)"
N="${RACE_ROUNDS:-10}"

admin() { psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 "$@"; }
scratch() {
  local url
  url="$(python3 - "$DATABASE_URL" "$DB" <<'PY'
import sys
from urllib.parse import urlsplit, urlunsplit
u = urlsplit(sys.argv[1])
print(urlunsplit((u.scheme, u.netloc, "/" + sys.argv[2], u.query, u.fragment)))
PY
)"
  psql "$url" -X -q -v ON_ERROR_STOP=1 "$@"
}
SCRATCH_URL="$(python3 - "$DATABASE_URL" "$DB" <<'PY'
import sys
from urllib.parse import urlsplit, urlunsplit
u = urlsplit(sys.argv[1])
print(urlunsplit((u.scheme, u.netloc, "/" + sys.argv[2], u.query, u.fragment)))
PY
)"

cleanup() {
  jobs -p | xargs -r kill 2>/dev/null
  admin -c "drop database if exists \"$DB\" with (force)" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

admin -c "create database \"$DB\"" || exit 2
scratch -f "$ROOT/supabase/tests/local/supabase_shim.sql" >/dev/null || exit 2
for f in "$ROOT"/supabase/migrations/*.sql; do
  scratch -f "$f" >/dev/null || { echo "Migration failed: $f" >&2; exit 2; }
done

A=00000000-0000-0000-0000-00000000000a   # seller
B=00000000-0000-0000-0000-00000000000b   # buyer
C=00000000-0000-0000-0000-00000000000c   # buyer
D=00000000-0000-0000-0000-00000000000d   # buyer

scratch <<SQL >/dev/null
insert into auth.users (id, email, raw_user_meta_data) values
  ('$A', 'a@example.test', '{"display_name":"Seller"}'),
  ('$B', 'b@example.test', '{"display_name":"Buyer B"}'),
  ('$C', 'c@example.test', '{"display_name":"Buyer C"}'),
  ('$D', 'd@example.test', '{"display_name":"Buyer D"}');
update public.platform_settings set value = '1000' where key = 'rate_limit.order.max';

create function public.race_listing() returns uuid language plpgsql as \$\$
declare new_id uuid;
begin
  insert into public.listings (seller_id, category_id, location_id, title, description, price_zmw, condition, status, moderation_status)
  select '$A', c.id, l.id, 'Race item ' || substr(gen_random_uuid()::text, 1, 8), 'x', 500, 'used_good', 'draft', 'pending'
    from public.categories c, public.locations l where c.slug = 'electronics' and l.area = 'Kabulonga'
  returning id into new_id;
  insert into public.listing_images (listing_id, storage_path, position) values (new_id, 'x/' || new_id || '.jpg', 0);
  update public.listings set status = 'active' where id = new_id;
  update public.listings set moderation_status = 'approved' where id = new_id;
  return new_id;
end \$\$;

-- Plain table that remembers which scenario each order and item belongs to.
create table public.race_plan (scenario text, slot integer, listing_id uuid, order_b uuid, order_c uuid);
SQL

# Prepares $N items for a scenario. Mode "two": two requested orders (B and C) per item.
# Mode "one": one requested order (B) per item. Mode "none": just the item.
plan() {
  local scenario="$1" mode="$2"
  scratch <<SQL >/dev/null
do \$\$
declare i integer; lid uuid; ob uuid; oc uuid;
begin
  for i in 1..$N loop
    lid := public.race_listing();
    ob := null; oc := null;
    if '$mode' in ('one', 'two') then
      insert into public.orders (listing_id, buyer_id, seller_id, item_title, item_price_zmw, buyer_name, seller_name, expires_at)
      values (lid, '$B', '$A', 'Race item', 500, 'Buyer B', 'Seller', now() + interval '1 day') returning id into ob;
    end if;
    if '$mode' = 'two' then
      insert into public.orders (listing_id, buyer_id, seller_id, item_title, item_price_zmw, buyer_name, seller_name, expires_at)
      values (lid, '$C', '$A', 'Race item', 500, 'Buyer C', 'Seller', now() + interval '1 day') returning id into oc;
    end if;
    insert into public.race_plan values ('$scenario', i, lid, ob, oc);
  end loop;
end \$\$;
SQL
}

# Runs one statement as one person once the starting gun fires.
worker() {
  local tag="$1" uid="$2" sql="$3"
  (
    psql "$SCRATCH_URL" -X -q -v ON_ERROR_STOP=0 >"$WORK/$tag.out" 2>"$WORK/$tag.err" <<SQL
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"$uid","role":"authenticated","aal":"aal1"}', false);
select pg_advisory_lock_shared(7777);
$sql
SQL
  ) &
}

# Holds every worker at the starting line, then lets them all go together.
race() {
  psql "$SCRATCH_URL" -X -q -c "select pg_advisory_lock(7777); select pg_sleep(${RACE_HOLD:-4});" >/dev/null 2>&1 &
  sleep 0.5
}

wait_for_workers() { wait; }

scenario_failures=0
fail() { echo "FAIL: $*"; scenario_failures=$((scenario_failures + 1)); }
q() { scratch -t -A -c "$1"; }

echo "Scenario 1: two buyers are confirmed at the same moment for one item"
plan s1 two
race
for i in $(seq 1 "$N"); do
  ob=$(q "select order_b from public.race_plan where scenario='s1' and slot=$i")
  oc=$(q "select order_c from public.race_plan where scenario='s1' and slot=$i")
  worker "s1_${i}_b" "$A" "select public.confirm_order('$ob', 0);"
  worker "s1_${i}_c" "$A" "select public.confirm_order('$oc', 0);"
done
wait_for_workers
for i in $(seq 1 "$N"); do
  lid=$(q "select listing_id from public.race_plan where scenario='s1' and slot=$i")
  res=$(q "select count(*) from public.listing_reservations where listing_id='$lid'")
  conf=$(q "select count(*) from public.orders where listing_id='$lid' and status='confirmed'")
  dec=$(q "select count(*) from public.orders where listing_id='$lid' and status='cancelled' and cancel_kind='declined'")
  [ "$res" = "1" ] && [ "$conf" = "1" ] && [ "$dec" = "1" ] || fail "s1 item $i: reservations=$res confirmed=$conf declined=$dec (want 1, 1, 1)"
done

echo "Scenario 2: two buyers ask for the same item at the same moment"
plan s2 none
race
for i in $(seq 1 "$N"); do
  lid=$(q "select listing_id from public.race_plan where scenario='s2' and slot=$i")
  worker "s2_${i}_b" "$B" "select public.create_order('$lid');"
  worker "s2_${i}_c" "$C" "select public.create_order('$lid');"
done
wait_for_workers
for i in $(seq 1 "$N"); do
  lid=$(q "select listing_id from public.race_plan where scenario='s2' and slot=$i")
  open=$(q "select count(*) from public.orders where listing_id='$lid' and status='requested'")
  res=$(q "select count(*) from public.listing_reservations where listing_id='$lid'")
  [ "$open" = "2" ] && [ "$res" = "0" ] || fail "s2 item $i: requested=$open reservations=$res (want 2 and 0)"
done

echo "Scenario 3: the buyer cancels while the seller confirms"
plan s3 one
race
for i in $(seq 1 "$N"); do
  ob=$(q "select order_b from public.race_plan where scenario='s3' and slot=$i")
  worker "s3_${i}_buyer" "$B" "select public.cancel_order('$ob', 'changed my mind');"
  worker "s3_${i}_seller" "$A" "select public.confirm_order('$ob', 0);"
done
wait_for_workers
for i in $(seq 1 "$N"); do
  ob=$(q "select order_b from public.race_plan where scenario='s3' and slot=$i")
  lid=$(q "select listing_id from public.race_plan where scenario='s3' and slot=$i")
  st=$(q "select status from public.orders where id='$ob'")
  res=$(q "select count(*) from public.listing_reservations where listing_id='$lid'")
  case "$st:$res" in
    confirmed:1|cancelled:0) ;;
    *) fail "s3 item $i: order is $st with $res reservation(s)";;
  esac
done

echo "Scenario 4: the seller confirms while also marking the item sold"
plan s4 one
race
for i in $(seq 1 "$N"); do
  ob=$(q "select order_b from public.race_plan where scenario='s4' and slot=$i")
  lid=$(q "select listing_id from public.race_plan where scenario='s4' and slot=$i")
  worker "s4_${i}_confirm" "$A" "select public.confirm_order('$ob', 0);"
  worker "s4_${i}_sold" "$A" "update public.listings set status = 'sold' where id = '$lid';"
done
wait_for_workers
for i in $(seq 1 "$N"); do
  ob=$(q "select order_b from public.race_plan where scenario='s4' and slot=$i")
  lid=$(q "select listing_id from public.race_plan where scenario='s4' and slot=$i")
  ost=$(q "select status from public.orders where id='$ob'")
  lst=$(q "select status from public.listings where id='$lid'")
  res=$(q "select count(*) from public.listing_reservations where listing_id='$lid'")
  # Allowed endings: confirmed and still active (the sale was refused), or the order turned away
  # and the item sold. Never an item sold with a live confirmed order or a reservation.
  case "$ost:$lst:$res" in
    confirmed:active:1|cancelled:sold:0) ;;
    *) fail "s4 item $i: order $ost, item $lst, $res reservation(s)";;
  esac
done

echo "Scenario 5: a new buyer asks while the seller confirms someone else"
plan s5 one
race
for i in $(seq 1 "$N"); do
  ob=$(q "select order_b from public.race_plan where scenario='s5' and slot=$i")
  lid=$(q "select listing_id from public.race_plan where scenario='s5' and slot=$i")
  worker "s5_${i}_confirm" "$A" "select public.confirm_order('$ob', 0);"
  worker "s5_${i}_new" "$D" "select public.create_order('$lid');"
done
wait_for_workers
for i in $(seq 1 "$N"); do
  lid=$(q "select listing_id from public.race_plan where scenario='s5' and slot=$i")
  res=$(q "select count(*) from public.listing_reservations where listing_id='$lid'")
  stuck=$(q "select count(*) from public.orders where listing_id='$lid' and status='requested'")
  [ "$res" = "1" ] && [ "$stuck" = "0" ] || fail "s5 item $i: reservations=$res requests still waiting=$stuck (want 1 and 0)"
done

echo "Scenario 6: stock is adjusted while a buyer completes an order (migration 0011)"
scratch <<SQL >/dev/null
insert into public.businesses (id, owner_id, name, slug) values ('20000000-0000-0000-0000-0000000000aa', '$A', 'Race Shop', 'race-shop');
SQL
plan s6 one
for i in $(seq 1 "$N"); do
  lid=$(q "select listing_id from public.race_plan where scenario='s6' and slot=$i")
  ob=$(q "select order_b from public.race_plan where scenario='s6' and slot=$i")
  scratch -c "update public.listings set business_id='20000000-0000-0000-0000-0000000000aa' where id='$lid'; update public.orders set business_id='20000000-0000-0000-0000-0000000000aa' where id='$ob'; insert into public.listing_stock (listing_id, business_id, quantity) values ('$lid','20000000-0000-0000-0000-0000000000aa', 5);" >/dev/null 2>&1 || true
  scratch -c "set role authenticated; select set_config('request.jwt.claims','{\"sub\":\"$A\",\"role\":\"authenticated\",\"aal\":\"aal1\"}', false); select public.confirm_order('$ob', 0); select public.mark_handed_over('$ob');" >/dev/null 2>&1
done
race
for i in $(seq 1 "$N"); do
  lid=$(q "select listing_id from public.race_plan where scenario='s6' and slot=$i")
  ob=$(q "select order_b from public.race_plan where scenario='s6' and slot=$i")
  worker "s6_${i}_buyer" "$B" "select public.complete_order('$ob');"
  worker "s6_${i}_adj" "$A" "select public.adjust_stock('$lid', -1, 'damaged');"
done
wait_for_workers
for i in $(seq 1 "$N"); do
  lid=$(q "select listing_id from public.race_plan where scenario='s6' and slot=$i")
  ob=$(q "select order_b from public.race_plan where scenario='s6' and slot=$i")
  qty=$(q "select quantity from public.listing_stock where listing_id='$lid'")
  ost=$(q "select status from public.orders where id='$ob'")
  mv=$(q "select coalesce(sum(change),0) from public.stock_movements where listing_id='$lid'")
  [ "$ost" = "completed" ] && [ "$qty" = "3" ] || fail "s6 item $i: order $ost, quantity $qty (want completed and 3)"
  [ "$mv" = "-2" ] || fail "s6 item $i: movements add up to $mv (want -2)"
done

echo "Scenario 7: three people take stock off at the same moment when only two are left"
plan s7 none
for i in $(seq 1 "$N"); do
  lid=$(q "select listing_id from public.race_plan where scenario='s7' and slot=$i")
  scratch -c "update public.listings set business_id='20000000-0000-0000-0000-0000000000aa' where id='$lid'; insert into public.listing_stock (listing_id, business_id, quantity) values ('$lid','20000000-0000-0000-0000-0000000000aa', 2);" >/dev/null
done
race
for i in $(seq 1 "$N"); do
  lid=$(q "select listing_id from public.race_plan where scenario='s7' and slot=$i")
  for k in 1 2 3; do worker "s7_${i}_$k" "$A" "select public.adjust_stock('$lid', -1, 'damaged');"; done
done
wait_for_workers
for i in $(seq 1 "$N"); do
  lid=$(q "select listing_id from public.race_plan where scenario='s7' and slot=$i")
  qty=$(q "select quantity from public.listing_stock where listing_id='$lid'")
  st=$(q "select status from public.listings where id='$lid'")
  [ "$qty" = "0" ] && [ "$st" = "unavailable" ] || fail "s7 item $i: quantity $qty, listing $st (want 0 and unavailable)"
done


# ---------------------------------------------------------------------------------------------------------------
# Staff voting (migration 0015)
# ---------------------------------------------------------------------------------------------------------------
# Nine staff. Staff 1 and 2 are technical admins. Each worker is signed in with two-factor (aal2).
scratch <<SQL >/dev/null
insert into auth.users (id, email, raw_user_meta_data)
select ('00000000-0000-0000-0000-0000000001' || lpad(n::text, 2, '0'))::uuid, 'vstaff' || n || '@example.test',
       json_build_object('display_name', 'Voter ' || n)::jsonb
  from generate_series(1, 9) n;
insert into public.admin_roles (user_id, role)
select ('00000000-0000-0000-0000-0000000001' || lpad(n::text, 2, '0'))::uuid, case when n <= 2 then 'tech_admin' else 'moderator' end::public.admin_role
  from generate_series(1, 9) n;
update public.platform_settings set value = '0' where key = 'staff_vote.min_hours';
update public.platform_settings set value = '1000' where key = 'rate_limit.staff_proposal.max';
create table public.vote_plan (scenario text, slot integer, proposal_id uuid);
create function public.vstaff(n integer) returns uuid language sql immutable as \$\$
  select ('00000000-0000-0000-0000-0000000001' || lpad(n::text, 2, '0'))::uuid \$\$;
SQL

# Opens N proposals for a scenario, then casts the given number of FOR votes by staff 1.. on each.
vote_plan() {
  local scenario="$1" pre_for="$2"
  scratch <<SQL >/dev/null
do \$\$
declare i integer; k integer; pid uuid;
begin
  for i in 1..$N loop
    perform set_config('request.jwt.claims', json_build_object('sub', public.vstaff(1), 'role', 'authenticated', 'aal', 'aal2')::text, false);
    pid := public.create_staff_proposal('Race proposal ' || i || ' ' || '$scenario', 'A description that is long enough.', 'A reason that is long enough.', false, true);
    perform public.submit_staff_proposal(pid, null, now() + interval '2 days');
    for k in 1..$pre_for loop
      perform set_config('request.jwt.claims', json_build_object('sub', public.vstaff(k), 'role', 'authenticated', 'aal', 'aal2')::text, false);
      perform public.cast_staff_vote(pid, 'for');
    end loop;
    insert into public.vote_plan values ('$scenario', i, pid);
  end loop;
  perform set_config('request.jwt.claims', '', false);
end \$\$;
SQL
}

# Like worker(), but signed in with two-factor, as staff members must be.
staff_worker() {
  local tag="$1" n="$2" sql="$3"
  (
    psql "$SCRATCH_URL" -X -q -v ON_ERROR_STOP=0 >"$WORK/$tag.out" 2>"$WORK/$tag.err" <<SQL
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', public.vstaff($n), 'role', 'authenticated', 'aal', 'aal2')::text, false);
select pg_advisory_lock_shared(7777);
$sql
SQL
  ) &
}

echo "Scenario 8: one staff member votes twice at the same moment"
vote_plan s8 0
race
for i in $(seq 1 "$N"); do
  pid=$(q "select proposal_id from public.vote_plan where scenario='s8' and slot=$i")
  staff_worker "s8_${i}_a" 3 "select public.cast_staff_vote('$pid', 'for');"
  staff_worker "s8_${i}_b" 3 "select public.cast_staff_vote('$pid', 'against');"
done
wait_for_workers
for i in $(seq 1 "$N"); do
  pid=$(q "select proposal_id from public.vote_plan where scenario='s8' and slot=$i")
  rows=$(q "select count(*) from public.staff_votes where proposal_id='$pid' and voter_id=public.vstaff(3)")
  [ "$rows" = "1" ] || fail "s8 proposal $i: $rows vote rows for one person (want exactly 1)"
done

echo "Scenario 9: the deciding votes arrive together (5 FOR already in; 2 FOR and 2 AGAINST land at once, 6 needed of 9)"
vote_plan s9 5
race
for i in $(seq 1 "$N"); do
  pid=$(q "select proposal_id from public.vote_plan where scenario='s9' and slot=$i")
  staff_worker "s9_${i}_6" 6 "select public.cast_staff_vote('$pid', 'for');"
  staff_worker "s9_${i}_7" 7 "select public.cast_staff_vote('$pid', 'against');"
  staff_worker "s9_${i}_8" 8 "select public.cast_staff_vote('$pid', 'against');"
  staff_worker "s9_${i}_9" 9 "select public.cast_staff_vote('$pid', 'for');"
done
wait_for_workers
for i in $(seq 1 "$N"); do
  pid=$(q "select proposal_id from public.vote_plan where scenario='s9' and slot=$i")
  st=$(q "select status from public.staff_proposals where id='$pid'")
  res=$(q "select count(*) from public.staff_vote_results where proposal_id='$pid'")
  closed=$(q "select count(*) from public.staff_vote_audit_logs where proposal_id='$pid' and action='closed'")
  match=$(q "select count(*) from public.staff_vote_results r where r.proposal_id='$pid'
               and r.for_count = (select count(*) from public.staff_votes v where v.proposal_id=r.proposal_id and v.choice='for')
               and r.against_count = (select count(*) from public.staff_votes v where v.proposal_id=r.proposal_id and v.choice='against')")
  [ "$st" = "approved" ] && [ "$res" = "1" ] && [ "$closed" = "1" ] && [ "$match" = "1" ] \
    || fail "s9 proposal $i: status=$st results=$res closed_audit_rows=$closed result_matches_ballots=$match (want approved, 1, 1, 1)"
done


# ---------------------------------------------------------------------------------------------------------------
# Staff birthdays (migration 0017)
# ---------------------------------------------------------------------------------------------------------------
# All nine staff have a long-standing birthday today. Four copies of the daily job start at the same instant.
scratch <<SQL >/dev/null
insert into public.staff_birthday_profiles (user_id, birth_month, birth_day, date_changed_at)
select public.vstaff(n), extract(month from public.bd_today())::integer, extract(day from public.bd_today())::integer, '2000-01-01'
  from generate_series(1, 9) n;
SQL

echo "Scenario 10: the daily birthday job runs four times at once"
race
for k in 1 2 3 4; do
  (
    psql "$SCRATCH_URL" -X -q -v ON_ERROR_STOP=0 >"$WORK/s10_$k.out" 2>"$WORK/s10_$k.err" <<SQL
select pg_advisory_lock_shared(7777);
select public.run_staff_birthdays();
SQL
  ) &
done
wait_for_workers
events=$(q "select count(*) from public.staff_birthday_events")
greet=$(q "select count(*) from public.notifications where type='birthday.greeting'")
cast=$(q "select count(*) from public.notifications where type='birthday.today'")
logs=$(q "select count(*) from public.staff_birthday_notification_logs")
dupes=$(q "select count(*) from (select user_id, dedupe_key from public.notifications group by 1, 2 having count(*) > 1) d")
[ "$events" = "9" ] && [ "$greet" = "9" ] && [ "$cast" = "72" ] && [ "$logs" = "81" ] && [ "$dupes" = "0" ] \
  || fail "s10: events=$events greetings=$greet notices=$cast log_rows=$logs duplicate_notifications=$dupes (want 9, 9, 72, 81, 0)"

echo "Scenario 11: one person leaves five wishes at the same moment (the limit is three)"
event=$(q "select id from public.staff_birthday_events where user_id = public.vstaff(4)")
race
for k in 1 2 3 4 5; do
  staff_worker "s11_$k" 3 "select public.send_birthday_message('$event', 'Wish number $k');"
done
wait_for_workers
wishes=$(q "select count(*) from public.staff_birthday_messages where event_id='$event' and sender_id=public.vstaff(3)")
notes=$(q "select count(*) from public.notifications where user_id=public.vstaff(4) and type='birthday.message'")
[ "$wishes" = "3" ] && [ "$notes" = "3" ] || fail "s11: stored wishes=$wishes notifications=$notes (want 3 and 3)"

# Every error a worker saw must be one of the polite refusals. A deadlock or a raw database
# error (such as a duplicate key) means the locking is not doing its job, even if the end state looks right.
unexpected=$(cat "$WORK"/*.err 2>/dev/null | grep -i "error" \
  | grep -v -e "not allowed for this order" -e "reserved for another buyer" -e "confirmed order" -e "not available" -e "in stock" -e "already voted" -e "vote is not open" -e "already left" || true)
if [ -n "$unexpected" ]; then
  fail "unexpected errors from workers:"
  echo "$unexpected" | sort | uniq -c | head
fi
deadlocks=$(cat "$WORK"/*.err 2>/dev/null | grep -ci "deadlock" || true)
[ "$deadlocks" = "0" ] || fail "$deadlocks deadlock(s) detected"

if [ "$scenario_failures" -eq 0 ]; then
  echo "All race checks passed ($N items per scenario, 11 scenarios)."
else
  echo "$scenario_failures race check(s) failed."
  exit 1
fi
