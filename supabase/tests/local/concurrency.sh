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

# Every error a worker saw must be one of the polite refusals. A deadlock or a raw database
# error (such as a duplicate key) means the locking is not doing its job, even if the end state looks right.
unexpected=$(cat "$WORK"/*.err 2>/dev/null | grep -i "error" \
  | grep -v -e "not allowed for this order" -e "reserved for another buyer" -e "confirmed order" -e "not available" || true)
if [ -n "$unexpected" ]; then
  fail "unexpected errors from workers:"
  echo "$unexpected" | sort | uniq -c | head
fi
deadlocks=$(cat "$WORK"/*.err 2>/dev/null | grep -ci "deadlock" || true)
[ "$deadlocks" = "0" ] || fail "$deadlocks deadlock(s) detected"

if [ "$scenario_failures" -eq 0 ]; then
  echo "All race checks passed ($N items per scenario, 5 scenarios)."
else
  echo "$scenario_failures race check(s) failed."
  exit 1
fi
