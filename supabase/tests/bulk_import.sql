-- Bulk product import (migration 0021): permissions, row checks, preview corrections, queueing, the background job
-- (drafts only, moderation untouched, one bad row cannot spoil the rest, no double creation), resubmitting failed
-- rows, limits, history, and table and function permissions.
-- Run against a local or staging database, never production:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/bulk_import.sql

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

create function zm_test.s(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000001' || lpad(n::text, 2, '0'))::uuid
$$;


insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@example.test',   '{"display_name":"Owner Olive"}', now()),
  ('00000000-0000-0000-0000-00000000000b', 'manager@example.test', '{"display_name":"Manager Mwila"}', now()),
  ('00000000-0000-0000-0000-00000000000c', 'staff@example.test',   '{"display_name":"Staff Sipho"}', now()),
  ('00000000-0000-0000-0000-00000000000d', 'outsider@example.test','{"display_name":"Outsider Omar"}', now()),
  ('00000000-0000-0000-0000-000000000002', 'owner2@example.test',  '{"display_name":"Second Owner"}', now());
insert into public.businesses (id, owner_id, name, slug, description, location_id)
select v.id::uuid, v.o::uuid, v.n, v.s, 'x', (select id from public.locations where area = 'Kabulonga')
  from (values ('20000000-0000-0000-0000-00000000000a','00000000-0000-0000-0000-00000000000a','Olive Electronics','olive-electronics'),
               ('20000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000002','Other Shop','other-shop')) v(id, o, n, s);
insert into public.business_members (business_id, user_id, role) values
  ('20000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b', 'manager'),
  ('20000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000c', 'staff');
update public.platform_settings set value = '1000' where key = 'rate_limit.product_import.max';
update public.prohibited_terms set is_active = false;

create function zm_test.row(p_sku text, p_title text default 'Phone case', p_price text default '50', p_qty text default '5',
                            p_cat text default 'electronics', p_cond text default 'new') returns jsonb
language sql as $$
  select jsonb_build_object('sku', p_sku, 'title', p_title, 'description', 'Good', 'price_zmw', p_price,
    'category', p_cat, 'condition', p_cond, 'quantity', p_qty)
$$;
create function zm_test.counts(p_job uuid) returns text language sql security definer as $$
  select coalesce(string_agg(status || ':' || c, ',' order by status), '') from
   (select status, count(*) c from public.product_import_rows where job_id = p_job group by status) x
$$;
create temp table zm_ids (name text primary key, id uuid);
grant all on zm_ids to anon, authenticated, service_role;
create function zm_test.jid(p_name text) returns uuid language sql as $$ select id from zm_ids where name = p_name $$;
create function zm_test.rowid(p_job text, p_n integer) returns uuid language sql security definer as $$
  select id from public.product_import_rows where job_id = (select id from zm_ids where name = p_job) and row_number = p_n
$$;
grant execute on all functions in schema zm_test to anon, authenticated, service_role;

\set O '00000000-0000-0000-0000-00000000000a'
\set M '00000000-0000-0000-0000-00000000000b'
\set S '00000000-0000-0000-0000-00000000000c'
\set X '00000000-0000-0000-0000-00000000000d'
\set BIZ '20000000-0000-0000-0000-00000000000a'
\set OTHER '20000000-0000-0000-0000-000000000002'

-- 1. Permissions and closed tables
select zm_test.expect_equal((select count(*)::text from information_schema.role_table_grants where table_schema = 'public'
   and table_name like 'product_import%' and grantee in ('anon', 'authenticated')), '0', 'no table grants for app users');
select zm_test.expect_equal((select bool_and(c.relrowsecurity)::text from pg_class c where c.relname like 'product_import%' and c.relkind = 'r'), 'true', 'row level security on');
select zm_test.act_as(:'X');
select zm_test.expect_error(format($q$select public.import_create_job(%L, 'a.csv', 'csv', jsonb_build_array(zm_test.row('A1')))$q$, :'BIZ'), 'an outsider cannot import');
select zm_test.expect_error('select * from public.product_import_jobs', 'jobs table is closed');
select zm_test.expect_error('select public.import_process_jobs()', 'app users cannot run the background job');
select zm_test.act_as_guest();
select zm_test.expect_error(format($q$select public.import_create_job(%L, 'a.csv', 'csv', jsonb_build_array(zm_test.row('A1')))$q$, :'BIZ'), 'guests cannot import');
select zm_test.act_as(:'O');
select zm_test.expect_error(format($q$select public.import_create_job(%L, 'a.csv', 'csv', jsonb_build_array(zm_test.row('A1')))$q$, :'OTHER'), 'owner of another business cannot import into this one');

-- 2. Validation per row
select zm_test.act_as(:'M');
insert into zm_ids select 'j1', public.import_create_job(:'BIZ', 'stock.csv', 'csv', jsonb_build_array(
  zm_test.row('A1'),
  zm_test.row('A1', 'Duplicate in file'),
  zm_test.row('A3', 'x'),
  zm_test.row('A4', 'Phone', '-5'),
  zm_test.row('A5', 'Phone', 'abc'),
  zm_test.row('A6', 'Phone', '50', '1.5'),
  zm_test.row('A7', 'Phone', '50', '5', 'nope'),
  zm_test.row('A8', 'Phone', '50', '5', 'electronics', 'broken'),
  zm_test.row(''),
  zm_test.row('A10')
));
select zm_test.expect_equal(zm_test.counts(zm_test.jid('j1')), 'invalid:8,valid:2', 'two good rows, eight bad rows');
select zm_test.expect_equal((select errors -> 0 ->> 'field' from public.import_rows(zm_test.jid('j1')) where row_number = 7), 'category', 'error names the field');
select zm_test.expect_equal((select errors -> 0 ->> 'message' from public.import_rows(zm_test.jid('j1')) where row_number = 2), 'This SKU appears twice in the file.', 'duplicate SKU in file flagged');

insert into zm_ids select 'j_extra', public.import_create_job(:'BIZ', 'x.csv', 'csv', jsonb_build_array(zm_test.row('E1') || '{"secret":"x","seller_id":"y"}'));
select zm_test.expect_equal((select (data ? 'secret' or data ? 'seller_id')::text from public.import_rows(zm_test.jid('j_extra'))), 'false', 'unknown columns are never stored');
select public.import_cancel_job(zm_test.jid('j_extra'));

select zm_test.expect_error(format($q$select public.import_create_job(%L, 'a.csv', 'csv', '[]')$q$, :'BIZ'), 'empty file');
select zm_test.expect_error(format($q$select public.import_create_job(%L, 'a.pdf', 'pdf', jsonb_build_array(zm_test.row('Z1')))$q$, :'BIZ'), 'wrong format');
select zm_test.expect_error(format($q$select public.import_create_job(%L, 'a.csv', 'csv', '{"a":1}')$q$, :'BIZ'), 'not an array');

-- 3. Correct in the preview
select zm_test.expect_equal(public.import_correct_row(zm_test.rowid('j1', 2), '{"sku":"A2","title":"Fixed title"}') ->> 'status', 'valid', 'a corrected row becomes valid');
select zm_test.expect_equal(public.import_correct_row(zm_test.rowid('j1', 3), '{"title":"Another"}') ->> 'status', 'valid', 'row 3 fixed');
select zm_test.expect_equal(public.import_correct_row(zm_test.rowid('j1', 4), '{"price_zmw":"-1"}') ->> 'status', 'invalid', 'a bad correction stays invalid');
select zm_test.expect_equal(public.import_correct_row(zm_test.rowid('j1', 5), '{"price_zmw":"10","sku":"A1"}') ->> 'status', 'invalid', 'correcting into a duplicate SKU is caught');
select zm_test.act_as(:'X');
select zm_test.expect_error(format($q$select public.import_correct_row(%L, '{"title":"Hacked"}')$q$, zm_test.rowid('j1', 2)), 'outsider cannot correct');

-- 4. Submit
select zm_test.expect_error(format($q$select public.import_submit_job(%L)$q$, zm_test.jid('j1')), 'outsider cannot submit');
select zm_test.act_as(:'M');
select public.import_submit_job(zm_test.jid('j1'));
select zm_test.expect_equal(public.import_job_detail(zm_test.jid('j1')) ->> 'status', 'queued', 'job is queued');
select zm_test.expect_error(format($q$select public.import_submit_job(%L)$q$, zm_test.jid('j1')), 'cannot submit twice');
select zm_test.expect_error(format($q$select public.import_correct_row(%L, '{"title":"Late"}')$q$, zm_test.rowid('j1', 1)), 'no corrections after sending');
select zm_test.expect_equal(zm_test.counts(zm_test.jid('j1')), 'skipped:6,valid:4', 'invalid rows are skipped, valid rows wait');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.listings where business_id = :'BIZ'), '0', 'nothing is created before the job runs');

-- 5. Background job. Another listing takes SKU A10 after the preview, so that row must fail alone.
insert into public.listings (id, seller_id, business_id, category_id, location_id, title, price_zmw, condition, status)
select '30000000-0000-0000-0000-000000000001', :'O', :'BIZ', c.id, l.id, 'Existing', 10, 'new', 'draft'
  from public.categories c, public.locations l where c.slug = 'electronics' and l.area = 'Kabulonga';
insert into public.listing_stock (listing_id, business_id, quantity, sku) values ('30000000-0000-0000-0000-000000000001', :'BIZ', 1, 'a10');
select zm_test.act_as_service();
select zm_test.expect_equal(public.import_process_jobs()::text, '3', 'three products created, one failed');
select zm_test.act_as_admin();
select zm_test.expect_equal(zm_test.counts(zm_test.jid('j1')), 'failed:1,imported:3,skipped:6', 'row results kept');
select zm_test.expect_equal((select status from public.product_import_jobs where id = zm_test.jid('j1')), 'completed_with_errors', 'job finished with errors');
select zm_test.expect_equal((select count(*)::text from public.listings l join public.product_import_rows r on r.listing_id = l.id
   where l.status = 'draft' and l.business_id = :'BIZ' and l.seller_id = :'M'), '3', 'products are drafts owned by the importer and the business');
select zm_test.expect_equal((select count(*)::text from public.listings l join public.product_import_rows r on r.listing_id = l.id where l.status <> 'draft'), '0', 'imports never publish');
select zm_test.expect_equal((select quantity::text from public.listing_stock where sku = 'A2'), '5', 'quantity stored with the SKU');
select zm_test.expect_equal((select count(*)::text from public.stock_movements m join public.listing_stock s on s.listing_id = m.listing_id where s.sku = 'A2' and m.reason = 'initial'), '1', 'initial stock movement');
select zm_test.expect_equal((select count(*)::text from public.notifications where user_id = :'M' and type = 'import_finished'), '1', 'creator told when done');
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action = 'import.finished'), '1', 'finish audited');
select zm_test.expect_equal((select count(*)::text from public.audit_logs where action in ('import.created','import.queued')), '3', 'create and queue audited');
select zm_test.act_as_service();
select zm_test.expect_equal(public.import_process_jobs()::text, '0', 'a second run creates nothing');
select zm_test.act_as_admin();
select zm_test.expect_equal((select count(*)::text from public.listings where business_id = :'BIZ'), '4', 'no duplicates (3 imported + 1 existing)');

-- Moderation is untouched: a flagged term sends the product to review, a blocked term is stopped in the preview.
insert into public.prohibited_terms (term, action) values ('zzflag', 'flag'), ('zzblock', 'block');
select zm_test.act_as(:'S');
insert into zm_ids select 'j2', public.import_create_job(:'BIZ', 'flag.xlsx', 'xlsx', jsonb_build_array(
  zm_test.row('F1', 'zzflag charger'), zm_test.row('F2', 'zzblock charger'), zm_test.row('F3', 'Safe charger')));
select zm_test.expect_equal(zm_test.counts(zm_test.jid('j2')), 'invalid:1,valid:2', 'blocked term rejected in preview');
select zm_test.expect_equal((select jsonb_array_length(warnings)::text from public.import_rows(zm_test.jid('j2')) where row_number = 1), '1', 'flagged term warns');
select public.import_submit_job(zm_test.jid('j2'));
select zm_test.act_as_service();
select public.import_process_jobs();
select zm_test.act_as_admin();
select zm_test.expect_equal((select moderation_status::text from public.listings l join public.listing_stock s on s.listing_id = l.id where s.sku = 'F1'), 'pending', 'flagged import is pending moderation');
select zm_test.expect_equal((select moderation_status::text from public.listings l join public.listing_stock s on s.listing_id = l.id where s.sku = 'F3'), 'approved', 'clean import is approved by the normal rules but still a draft');
select zm_test.expect_equal((select count(*)::text from public.listings l join public.listing_stock s on s.listing_id = l.id where s.sku in ('F1','F3') and l.status <> 'draft'), '0', 'still drafts');
select zm_test.expect_equal((select status from public.product_import_jobs where id = zm_test.jid('j2')), 'completed_with_errors', 'skipped row means completed with errors');

-- 6. Resubmit failed rows
select zm_test.act_as(:'X');
select zm_test.expect_error(format($q$select public.import_resubmit_failed(%L)$q$, zm_test.jid('j1')), 'outsider cannot resubmit');
select zm_test.act_as(:'M');
insert into zm_ids select 'j1r', public.import_resubmit_failed(zm_test.jid('j1'));
select zm_test.expect_equal((public.import_job_detail(zm_test.jid('j1r')) ->> 'total_rows'), '7', 'failed and skipped rows copied');
select zm_test.expect_equal((public.import_job_detail(zm_test.jid('j1r')) ->> 'resubmit_of'), zm_test.jid('j1')::text, 'linked to the original');
select zm_test.expect_error(format($q$select public.import_resubmit_failed(%L)$q$, zm_test.jid('j1')), 'only once');
select zm_test.expect_error(format($q$select public.import_resubmit_failed(%L)$q$, zm_test.jid('j1r')), 'a job still being prepared cannot be resubmitted');
select public.import_cancel_job(zm_test.jid('j1r'));
select zm_test.expect_equal((public.import_job_detail(zm_test.jid('j1r')) ->> 'status'), 'cancelled', 'cancel works');
select zm_test.expect_error(format($q$select public.import_submit_job(%L)$q$, zm_test.jid('j1r')), 'cancelled job cannot be sent');
select zm_test.expect_equal((public.import_resubmit_failed(zm_test.jid('j1')) is not null)::text, 'true', 'after cancelling the retry, failed rows can be retried again');

-- 7. History and isolation
select zm_test.expect_equal((select count(*)::text from public.import_history(:'BIZ')), '5', 'history lists every job');
select zm_test.expect_equal((select imported_rows::text from public.import_history(:'BIZ') where file_name = 'stock.csv'), '3', 'history counts imported rows');
select zm_test.act_as(:'X');
select zm_test.expect_error(format($q$select * from public.import_history(%L)$q$, :'BIZ'), 'outsider cannot read history');
select zm_test.expect_error(format($q$select public.import_job_detail(%L)$q$, zm_test.jid('j1')), 'outsider cannot read a job');
select zm_test.expect_error(format($q$select * from public.import_rows(%L)$q$, zm_test.jid('j1')), 'outsider cannot read rows');
select zm_test.act_as(:'O');
select zm_test.expect_error($q$select * from public.import_rows('00000000-0000-0000-0000-0000000000ff')$q$, 'unknown id handled');

-- 8. Limits
select zm_test.act_as_admin();
update public.platform_settings set value = '3' where key = 'import.max_rows_per_file';
select zm_test.act_as(:'M');
select zm_test.expect_error(format($q$select public.import_create_job(%L, 'big.csv', 'csv', jsonb_build_array(zm_test.row('B1'),zm_test.row('B2'),zm_test.row('B3'),zm_test.row('B4')))$q$, :'BIZ'), 'file row cap');
select zm_test.act_as_admin();
update public.platform_settings set value = '1000' where key = 'import.max_rows_per_file';
update public.platform_settings set value = '15' where key = 'import.max_rows_per_business_day';
select zm_test.act_as(:'M');
select zm_test.expect_error(format($q$select public.import_create_job(%L, 'day.csv', 'csv', jsonb_build_array(zm_test.row('D1'),zm_test.row('D2'),zm_test.row('D3'),zm_test.row('D4'),zm_test.row('D5'),zm_test.row('D6'),zm_test.row('D7'),zm_test.row('D8'),zm_test.row('D9'),zm_test.row('D10')))$q$, :'BIZ'), 'daily business row cap');
select zm_test.act_as_admin();
update public.platform_settings set value = '3000' where key = 'import.max_rows_per_business_day';
delete from public.rate_limit_log;
update public.platform_settings set value = '2' where key = 'rate_limit.product_import.max';
select zm_test.act_as(:'O');
select public.import_create_job(:'BIZ', 'r1.csv', 'csv', jsonb_build_array(zm_test.row('R1')));
select public.import_create_job(:'BIZ', 'r2.csv', 'csv', jsonb_build_array(zm_test.row('R2')));
select zm_test.expect_error(format($q$select public.import_create_job(%L, 'r3.csv', 'csv', jsonb_build_array(zm_test.row('R3')))$q$, :'BIZ'), 'files per person rate limit');

-- 9. Direct edits on import tables are impossible for app users
select zm_test.act_as(:'M');
select zm_test.expect_error('update public.product_import_rows set status = ''valid''', 'rows cannot be edited directly');
select zm_test.expect_error('delete from public.product_import_jobs', 'jobs cannot be deleted directly');

-- 10. A business with no location cannot import
select zm_test.act_as_admin();
update public.businesses set location_id = null where id = :'OTHER';
select zm_test.act_as('00000000-0000-0000-0000-000000000002');
select zm_test.expect_error(format($q$select public.import_create_job(%L, 'a.csv', 'csv', jsonb_build_array(zm_test.row('L1')))$q$, :'OTHER'), 'needs a location');

rollback;
