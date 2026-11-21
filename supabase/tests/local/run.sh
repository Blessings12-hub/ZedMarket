#!/usr/bin/env bash
# Runs every migration, then the security tests, against a throwaway database.
#
# Usage:  DATABASE_URL=postgres://postgres@localhost:5432/postgres supabase/tests/local/run.sh
#
# The URL must belong to a superuser on a disposable PostgreSQL 15 or 16 server
# (a local install or a CI service container). A fresh database is created and
# dropped again, so nothing else on the server is touched.
set -euo pipefail

: "${DATABASE_URL:?Set DATABASE_URL to a superuser connection for a throwaway PostgreSQL server}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
name="zedmarket_test_$$"
admin_url="$DATABASE_URL"
test_url="${admin_url%/*}/$name"

psql_run() { psql "$1" --set ON_ERROR_STOP=1 --quiet --no-psqlrc "${@:2}"; }

cleanup() { psql_run "$admin_url" -c "drop database if exists $name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

psql_run "$admin_url" -c "create database $name"
psql_run "$test_url" -f "$here/supabase_shim.sql"

for file in "$root"/migrations/*.sql; do
  echo "migration: $(basename "$file")"
  psql_run "$test_url" -f "$file"
done

for file in "$root"/tests/*.sql; do
  echo "test: $(basename "$file")"
  psql_run "$test_url" -f "$file"
done

echo "All migrations and tests passed."
