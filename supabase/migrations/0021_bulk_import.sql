-- Bulk product import (Part A, chunk 1: modules 1 and 2).
--
-- A business uploads a CSV or Excel file. The app reads the file on the device and sends the rows here as JSON;
-- nothing is created yet. The database checks every row, keeps the result per row, lets the seller correct rows in
-- a preview, and only then queues the job. A background job (import_process_jobs, run every minute) creates the
-- products. Failed rows can be sent again as a new job. Every job is kept as history.
--
-- Reuse, not duplication:
--   * "business_inventory" already exists as a FUNCTION (migration 0011) over listing_stock and stock_movements, so no
--     table of that name is created. Imported stock goes into listing_stock with a stock_movements 'initial' row.
--   * Products are created as ordinary listings through the normal trigger, so prohibited-terms, category review and
--     high-value rules all still run. Imports never set moderation_status and never publish: every product arrives
--     as a DRAFT. The seller adds photos and publishes, and publishing goes through the usual moderation path.
--
-- Safety:
--   * Row level security is on for both tables and nobody has table grants. Everything goes through functions.
--   * Every function checks the caller's business role (manage_listings and manage_inventory) on the server.
--   * Limits: rows per file, files per day, rows per business per day (platform_settings, starter values).
--   * One bad row cannot spoil the others: each row is created inside its own sub-transaction.
--   * Running the job twice, or two runs at once, cannot create a product twice (rows are claimed with
--     FOR UPDATE SKIP LOCKED and the SKU is unique per business).
--   * Created, queued, cancelled and finished jobs are written to the audit log.

-- ---------------------------------------------------------------------------
-- 1. SKU on stock
-- ---------------------------------------------------------------------------
alter table public.listing_stock add column sku text check (sku is null or char_length(sku) between 1 and 40);
create unique index listing_stock_sku_unique on public.listing_stock (business_id, lower(sku)) where sku is not null;

insert into public.platform_settings (key, value, note) values
  ('import.max_rows_per_file', '1000', 'Most rows in one import file. Starter value.'),
  ('import.max_rows_per_business_day', '3000', 'Most rows one business can queue in 24 hours. Starter value.'),
  ('rate_limit.product_import.max', '10', 'Import files per person per window. Starter value.'),
  ('rate_limit.product_import.window_minutes', '1440', null),
  ('import.batch_rows', '100', 'Rows the background job creates per run. Starter value.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------
create table public.product_import_jobs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  created_by uuid not null references public.profiles (id),
  file_name text not null check (char_length(file_name) between 1 and 200),
  source_format text not null check (source_format in ('csv', 'xlsx')),
  status text not null default 'validated'
    check (status in ('validated', 'queued', 'processing', 'completed', 'completed_with_errors', 'failed', 'cancelled')),
  total_rows integer not null default 0,
  resubmit_of uuid references public.product_import_jobs (id),
  created_at timestamptz not null default now(),
  queued_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz
);
create index product_import_jobs_business_idx on public.product_import_jobs (business_id, created_at desc);
create index product_import_jobs_queue_idx on public.product_import_jobs (queued_at) where status in ('queued', 'processing');

create table public.product_import_rows (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.product_import_jobs (id) on delete cascade,
  row_number integer not null check (row_number > 0),
  data jsonb not null,
  status text not null default 'valid'
    check (status in ('valid', 'invalid', 'imported', 'failed', 'skipped')),
  errors jsonb not null default '[]',
  warnings jsonb not null default '[]',
  listing_id uuid references public.listings (id) on delete set null,
  failure text,
  unique (job_id, row_number)
);
create index product_import_rows_status_idx on public.product_import_rows (job_id, status);

alter table public.product_import_jobs enable row level security;
alter table public.product_import_rows enable row level security;
-- No grants and no policies: reached only through the functions below.

-- ---------------------------------------------------------------------------
-- 3. Row validation (internal)
-- ---------------------------------------------------------------------------
-- Returns {errors: [...], warnings: [...]}. p_seen holds SKUs already used earlier in the same file.
create function public.import_check_row(p_business uuid, p_data jsonb, p_seen text[], p_exclude_row uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  errs jsonb := '[]';
  warns jsonb := '[]';
  v_sku text := btrim(coalesce(p_data ->> 'sku', ''));
  v_title text := btrim(coalesce(p_data ->> 'title', ''));
  descr text := coalesce(p_data ->> 'description', '');
  price numeric;
  qty numeric;
  low numeric;
  cat public.categories;
  rec record;
begin
  if v_sku = '' then
    errs := errs || jsonb_build_array(jsonb_build_object('field', 'sku', 'message', 'SKU is required.'));
  elsif char_length(v_sku) > 40 then
    errs := errs || jsonb_build_array(jsonb_build_object('field', 'sku', 'message', 'SKU can be up to 40 characters.'));
  elsif lower(v_sku) = any (p_seen) then
    errs := errs || jsonb_build_array(jsonb_build_object('field', 'sku', 'message', 'This SKU appears twice in the file.'));
  elsif exists (select 1 from public.listing_stock s where s.business_id = p_business and lower(s.sku) = lower(v_sku)) then
    errs := errs || jsonb_build_array(jsonb_build_object('field', 'sku', 'message', 'A product with this SKU already exists.'));
  end if;

  if char_length(v_title) not between 3 and 120 then
    errs := errs || jsonb_build_array(jsonb_build_object('field', 'title', 'message', 'Title must be 3 to 120 characters.'));
  end if;
  if char_length(descr) > 4000 then
    errs := errs || jsonb_build_array(jsonb_build_object('field', 'description', 'message', 'Description can be up to 4000 characters.'));
  end if;

  begin
    price := (p_data ->> 'price_zmw')::numeric;
  exception when others then
    price := null;
  end;
  if price is null or price <= 0 or price >= 100000000 then
    errs := errs || jsonb_build_array(jsonb_build_object('field', 'price_zmw', 'message', 'Price must be a number above 0.'));
  end if;

  begin
    qty := (p_data ->> 'quantity')::numeric;
  exception when others then
    qty := null;
  end;
  if qty is null or qty <> trunc(qty) or qty < 0 or qty > 100000 then
    errs := errs || jsonb_build_array(jsonb_build_object('field', 'quantity', 'message', 'Quantity must be a whole number from 0 to 100000.'));
  end if;

  if coalesce(p_data ->> 'low_stock_at', '') <> '' then
    begin
      low := (p_data ->> 'low_stock_at')::numeric;
    exception when others then
      low := null;
    end;
    if low is null or low <> trunc(low) or low < 0 or low > 100000 then
      errs := errs || jsonb_build_array(jsonb_build_object('field', 'low_stock_at', 'message', 'Low-stock level must be a whole number from 0 to 100000.'));
    end if;
  end if;

  if coalesce(p_data ->> 'condition', '') not in ('new', 'used_like_new', 'used_good', 'used_fair') then
    errs := errs || jsonb_build_array(jsonb_build_object('field', 'condition', 'message', 'Condition must be new, used_like_new, used_good or used_fair.'));
  end if;

  select * into cat from public.categories c where c.slug = lower(btrim(coalesce(p_data ->> 'category', '')));
  if not found then
    errs := errs || jsonb_build_array(jsonb_build_object('field', 'category', 'message', 'Category not found. Use the category slug.'));
  elsif not cat.is_active then
    errs := errs || jsonb_build_array(jsonb_build_object('field', 'category', 'message', 'That category is not open yet.'));
  elsif cat.requires_review then
    warns := warns || jsonb_build_array(jsonb_build_object('field', 'category', 'message', 'This category needs a moderator check before it can go live.'));
  end if;

  if char_length(coalesce(p_data ->> 'warranty_info', '')) > 500 then
    errs := errs || jsonb_build_array(jsonb_build_object('field', 'warranty_info', 'message', 'Warranty text can be up to 500 characters.'));
  end if;
  if char_length(coalesce(p_data ->> 'return_policy', '')) > 500 then
    errs := errs || jsonb_build_array(jsonb_build_object('field', 'return_policy', 'message', 'Return policy can be up to 500 characters.'));
  end if;

  for rec in select t.term, t.action from public.prohibited_terms t where t.is_active loop
    if position(lower(rec.term) in lower(v_title || ' ' || descr)) > 0 then
      if rec.action = 'block' then
        errs := errs || jsonb_build_array(jsonb_build_object('field', 'title', 'message', 'This row looks like it breaks the prohibited items policy.'));
      else
        warns := warns || jsonb_build_array(jsonb_build_object('field', 'title', 'message', 'A moderator will check this product before it can go live.'));
      end if;
    end if;
  end loop;

  return jsonb_build_object('errors', errs, 'warnings', warns);
end;
$$;

-- Keeps only the known columns, trimmed, so stray spreadsheet columns are never stored.
create function public.import_clean_row(p_data jsonb)
returns jsonb
language sql immutable security definer set search_path = ''
as $$
  select coalesce(jsonb_object_agg(k, btrim(p_data ->> k)) filter (where p_data ->> k is not null), '{}')
    from unnest(array['sku', 'title', 'description', 'price_zmw', 'category', 'condition', 'quantity',
                      'low_stock_at', 'warranty_info', 'return_policy']) as k
$$;

create function public.import_need_member(p_business uuid)
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is null
     or not public.business_can(p_business, 'manage_listings')
     or not public.business_can(p_business, 'manage_inventory') then
    raise exception 'Business not found.' using errcode = 'no_data_found';
  end if;
end;
$$;

-- Re-checks every row of a job in order and stores the result. Used by create, correct and resubmit.
create function public.import_revalidate(p_job uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  j public.product_import_jobs;
  r record;
  seen text[] := '{}';
  res jsonb;
  bad boolean;
begin
  select * into j from public.product_import_jobs where id = p_job;
  for r in select id, data, status from public.product_import_rows where job_id = p_job order by row_number loop
    if r.status in ('imported') then
      continue;
    end if;
    res := public.import_check_row(j.business_id, r.data, seen);
    bad := jsonb_array_length(res -> 'errors') > 0;
    update public.product_import_rows
       set status = case when bad then 'invalid' else 'valid' end,
           errors = res -> 'errors', warnings = res -> 'warnings', failure = null
     where id = r.id;
    if coalesce(r.data ->> 'sku', '') <> '' then
      seen := seen || lower(btrim(r.data ->> 'sku'));
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Seller-facing functions
-- ---------------------------------------------------------------------------
create function public.import_create_job(p_business uuid, p_file_name text, p_format text, p_rows jsonb)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  max_rows integer := public.setting_numeric('import.max_rows_per_file', 1000)::integer;
  day_cap integer := public.setting_numeric('import.max_rows_per_business_day', 3000)::integer;
  n integer;
  used integer;
  new_id uuid;
  i integer := 0;
  item jsonb;
begin
  perform public.import_need_member(p_business);
  if p_format not in ('csv', 'xlsx') then
    raise exception 'Upload a CSV or Excel (.xlsx) file.' using errcode = 'check_violation';
  end if;
  if p_file_name is null or char_length(btrim(p_file_name)) not between 1 and 200 then
    raise exception 'The file name is missing.' using errcode = 'check_violation';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'The file has no rows.' using errcode = 'check_violation';
  end if;
  n := jsonb_array_length(p_rows);
  if n = 0 then
    raise exception 'The file has no rows.' using errcode = 'check_violation';
  end if;
  if n > max_rows then
    raise exception 'A file can have up to % rows. Split it into smaller files.', max_rows using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.businesses b where b.id = p_business and b.location_id is not null) then
    raise exception 'Add a location to your business profile before importing products.' using errcode = 'check_violation';
  end if;
  select coalesce(sum(total_rows), 0) into used from public.product_import_jobs
   where business_id = p_business and created_at > now() - interval '24 hours' and status <> 'cancelled';
  if used + n > day_cap then
    raise exception 'This business has reached its daily import limit. Try again tomorrow.' using errcode = '54000';
  end if;
  perform public.enforce_rate_limit('product_import', 10, 1440);

  insert into public.product_import_jobs (business_id, created_by, file_name, source_format, total_rows)
  values (p_business, (select auth.uid()), btrim(p_file_name), p_format, n)
  returning id into new_id;

  for item in select value from jsonb_array_elements(p_rows) loop
    i := i + 1;
    insert into public.product_import_rows (job_id, row_number, data)
    values (new_id, i, public.import_clean_row(case when jsonb_typeof(item) = 'object' then item else '{}' end));
  end loop;
  perform public.import_revalidate(new_id);
  perform public.write_audit('import.created', 'product_import_job', new_id::text,
    jsonb_build_object('business_id', p_business, 'rows', n));
  return new_id;
end;
$$;

-- Corrects one row in the preview. Only while the job has not been queued.
create function public.import_correct_row(p_row uuid, p_data jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  r public.product_import_rows;
  j public.product_import_jobs;
  out_row public.product_import_rows;
begin
  select * into r from public.product_import_rows where id = p_row;
  if not found then
    raise exception 'Row not found.' using errcode = 'no_data_found';
  end if;
  select * into j from public.product_import_jobs where id = r.job_id for update;
  perform public.import_need_member(j.business_id);
  if j.status <> 'validated' then
    raise exception 'This file has already been sent. Corrections are closed.' using errcode = 'check_violation';
  end if;
  update public.product_import_rows
     set data = public.import_clean_row(coalesce(data, '{}') || coalesce(p_data, '{}'))
   where id = p_row;
  perform public.import_revalidate(j.id);
  select * into out_row from public.product_import_rows where id = p_row;
  return jsonb_build_object('status', out_row.status, 'errors', out_row.errors, 'warnings', out_row.warnings);
end;
$$;

-- Queues the job. Rows with errors are skipped, not imported.
create function public.import_submit_job(p_job uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  j public.product_import_jobs;
  good integer;
begin
  select * into j from public.product_import_jobs where id = p_job for update;
  if not found then
    raise exception 'Import not found.' using errcode = 'no_data_found';
  end if;
  perform public.import_need_member(j.business_id);
  if j.status <> 'validated' then
    raise exception 'This import has already been sent.' using errcode = 'check_violation';
  end if;
  select count(*) into good from public.product_import_rows where job_id = p_job and status = 'valid';
  if good = 0 then
    raise exception 'No rows are ready to import. Fix the errors first.' using errcode = 'check_violation';
  end if;
  update public.product_import_rows set status = 'skipped', failure = 'Skipped because of errors.'
   where job_id = p_job and status = 'invalid';
  update public.product_import_jobs set status = 'queued', queued_at = now() where id = p_job;
  perform public.write_audit('import.queued', 'product_import_job', p_job::text,
    jsonb_build_object('business_id', j.business_id, 'rows', good));
end;
$$;

create function public.import_cancel_job(p_job uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  j public.product_import_jobs;
begin
  select * into j from public.product_import_jobs where id = p_job for update;
  if not found then
    raise exception 'Import not found.' using errcode = 'no_data_found';
  end if;
  perform public.import_need_member(j.business_id);
  if j.status not in ('validated', 'queued') then
    raise exception 'This import can no longer be cancelled.' using errcode = 'check_violation';
  end if;
  update public.product_import_rows set status = 'skipped', failure = 'Cancelled.'
   where job_id = p_job and status in ('valid', 'invalid');
  update public.product_import_jobs set status = 'cancelled', finished_at = now() where id = p_job;
  perform public.write_audit('import.cancelled', 'product_import_job', p_job::text, jsonb_build_object('business_id', j.business_id));
end;
$$;

-- Failed and skipped rows of a finished job become a new job to correct and send again.
create function public.import_resubmit_failed(p_job uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  j public.product_import_jobs;
  new_id uuid;
  n integer;
begin
  select * into j from public.product_import_jobs where id = p_job;
  if not found then
    raise exception 'Import not found.' using errcode = 'no_data_found';
  end if;
  perform public.import_need_member(j.business_id);
  if j.status not in ('completed_with_errors', 'failed') then
    raise exception 'Only a finished import with problems can be sent again.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.product_import_jobs x where x.resubmit_of = p_job and x.status <> 'cancelled') then
    raise exception 'The failed rows were already sent again.' using errcode = 'unique_violation';
  end if;
  select count(*) into n from public.product_import_rows where job_id = p_job and status in ('failed', 'skipped');
  if n = 0 then
    raise exception 'There are no failed rows to send again.' using errcode = 'check_violation';
  end if;
  perform public.enforce_rate_limit('product_import', 10, 1440);

  insert into public.product_import_jobs (business_id, created_by, file_name, source_format, total_rows, resubmit_of)
  values (j.business_id, (select auth.uid()), left('Retry of ' || j.file_name, 200), j.source_format, n, p_job)
  returning id into new_id;
  insert into public.product_import_rows (job_id, row_number, data)
  select new_id, row_number() over (order by row_number), data
    from public.product_import_rows where job_id = p_job and status in ('failed', 'skipped');
  perform public.import_revalidate(new_id);
  perform public.write_audit('import.resubmitted', 'product_import_job', new_id::text,
    jsonb_build_object('business_id', j.business_id, 'from', p_job, 'rows', n));
  return new_id;
end;
$$;

create function public.import_history(p_business uuid, p_limit integer default 30, p_offset integer default 0)
returns table (
  id uuid, file_name text, source_format text, status text, total_rows integer,
  imported_rows bigint, failed_rows bigint, invalid_rows bigint, resubmit_of uuid,
  created_by_name text, created_at timestamptz, finished_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  perform public.import_need_member(p_business);
  return query
    select j.id, j.file_name, j.source_format, j.status, j.total_rows,
           count(*) filter (where r.status = 'imported'),
           count(*) filter (where r.status = 'failed'),
           count(*) filter (where r.status in ('invalid', 'skipped')),
           j.resubmit_of, p.display_name, j.created_at, j.finished_at
      from public.product_import_jobs j
      join public.profiles p on p.id = j.created_by
      left join public.product_import_rows r on r.job_id = j.id
     where j.business_id = p_business
     group by j.id, p.display_name
     order by j.created_at desc
     limit least(greatest(coalesce(p_limit, 30), 1), 100) offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

create function public.import_job_detail(p_job uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  j public.product_import_jobs;
begin
  select * into j from public.product_import_jobs where id = p_job;
  if not found then
    raise exception 'Import not found.' using errcode = 'no_data_found';
  end if;
  perform public.import_need_member(j.business_id);
  return jsonb_build_object(
    'id', j.id, 'business_id', j.business_id, 'file_name', j.file_name, 'status', j.status,
    'total_rows', j.total_rows, 'resubmit_of', j.resubmit_of, 'created_at', j.created_at, 'finished_at', j.finished_at,
    'counts', (select coalesce(jsonb_object_agg(status, c), '{}') from
                (select status, count(*) c from public.product_import_rows where job_id = p_job group by status) x));
end;
$$;

create function public.import_rows(p_job uuid, p_status text default null, p_limit integer default 100, p_offset integer default 0)
returns table (
  id uuid, row_number integer, status text, data jsonb, errors jsonb, warnings jsonb, listing_id uuid, failure text
)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  biz uuid;
begin
  select business_id into biz from public.product_import_jobs where id = p_job;
  if biz is null then
    raise exception 'Import not found.' using errcode = 'no_data_found';
  end if;
  perform public.import_need_member(biz);
  return query
    select r.id, r.row_number, r.status, r.data, r.errors, r.warnings, r.listing_id, r.failure
      from public.product_import_rows r
     where r.job_id = p_job and (p_status is null or r.status = p_status)
     order by r.row_number
     limit least(greatest(coalesce(p_limit, 100), 1), 500) offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Background job
-- ---------------------------------------------------------------------------
-- Creates up to import.batch_rows products from the oldest queued job, then returns the number created.
-- Safe to run often and to run twice at once.
create function public.import_process_jobs()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  batch integer := public.setting_numeric('import.batch_rows', 100)::integer;
  j public.product_import_jobs;
  r public.product_import_rows;
  l_id uuid;
  cat_id integer;
  loc_id integer;
  done integer := 0;
  tried integer := 0;
  ok integer;
  bad integer;
  final text;
begin
  select * into j from public.product_import_jobs
   where status in ('queued', 'processing')
   order by queued_at
   for update skip locked limit 1;
  if not found then
    return 0;
  end if;
  if j.status = 'queued' then
    update public.product_import_jobs set status = 'processing', started_at = now() where id = j.id;
  end if;
  select location_id into loc_id from public.businesses where id = j.business_id;

  for r in
    select * from public.product_import_rows
     where job_id = j.id and status = 'valid'
     order by row_number
     for update skip locked
     limit batch
  loop
    tried := tried + 1;
    begin
      -- Re-check right before creating: a SKU or category may have changed since the preview.
      if jsonb_array_length(public.import_check_row(j.business_id, r.data, '{}') -> 'errors') > 0 then
        raise exception 'This row no longer passes the checks. Correct it and send it again.';
      end if;
      select id into cat_id from public.categories where slug = lower(r.data ->> 'category');
      insert into public.listings (seller_id, business_id, category_id, location_id, title, description, price_zmw,
                                   condition, warranty_info, return_policy, status)
      values (j.created_by, j.business_id, cat_id, loc_id, r.data ->> 'title', coalesce(r.data ->> 'description', ''),
              (r.data ->> 'price_zmw')::numeric, (r.data ->> 'condition')::public.item_condition,
              nullif(r.data ->> 'warranty_info', ''), nullif(r.data ->> 'return_policy', ''), 'draft')
      returning id into l_id;
      insert into public.listing_stock (listing_id, business_id, quantity, low_stock_at, sku, updated_by)
      values (l_id, j.business_id, (r.data ->> 'quantity')::integer,
              coalesce(nullif(r.data ->> 'low_stock_at', '')::integer, 2), btrim(r.data ->> 'sku'), j.created_by);
      if (r.data ->> 'quantity')::integer > 0 then
        insert into public.stock_movements (listing_id, business_id, change, quantity_after, reason, actor_id)
        values (l_id, j.business_id, (r.data ->> 'quantity')::integer, (r.data ->> 'quantity')::integer, 'initial', j.created_by);
      end if;
      update public.product_import_rows set status = 'imported', listing_id = l_id, failure = null where id = r.id;
      done := done + 1;
    exception when others then
      update public.product_import_rows set status = 'failed', failure = left(sqlerrm, 300) where id = r.id;
    end;
  end loop;

  if not exists (select 1 from public.product_import_rows where job_id = j.id and status = 'valid') then
    select count(*) filter (where status = 'imported'), count(*) filter (where status = 'failed')
      into ok, bad from public.product_import_rows where job_id = j.id;
    final := case when ok = 0 then 'failed' when bad > 0 or ok < j.total_rows then 'completed_with_errors' else 'completed' end;
    update public.product_import_jobs set status = final, finished_at = now() where id = j.id;
    perform public.notify(j.created_by, 'business', 'import_finished',
      case when final = 'completed' then 'Your import is done' else 'Your import finished with problems' end,
      ok || ' product' || case when ok = 1 then '' else 's' end || ' added as drafts. ' ||
        (j.total_rows - ok) || ' not added.',
      '/business/manage/' || j.business_id || '/imports/' || j.id, 'import:' || j.id);
    insert into public.audit_logs (actor_id, action, target_type, target_id, metadata)
    values (null, 'import.finished', 'product_import_job', j.id::text,
            jsonb_build_object('business_id', j.business_id, 'imported', ok, 'failed', bad, 'status', final));
  end if;
  return done;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Permissions: closed first, then opened on purpose
-- ---------------------------------------------------------------------------
revoke execute on function
  public.import_check_row(uuid, jsonb, text[], uuid), public.import_clean_row(jsonb), public.import_need_member(uuid),
  public.import_revalidate(uuid), public.import_create_job(uuid, text, text, jsonb), public.import_correct_row(uuid, jsonb),
  public.import_submit_job(uuid), public.import_cancel_job(uuid), public.import_resubmit_failed(uuid),
  public.import_history(uuid, integer, integer), public.import_job_detail(uuid), public.import_rows(uuid, text, integer, integer),
  public.import_process_jobs()
from public, anon, authenticated;

grant execute on function
  public.import_create_job(uuid, text, text, jsonb), public.import_correct_row(uuid, jsonb),
  public.import_submit_job(uuid), public.import_cancel_job(uuid), public.import_resubmit_failed(uuid),
  public.import_history(uuid, integer, integer), public.import_job_detail(uuid), public.import_rows(uuid, text, integer, integer)
to authenticated;

grant execute on function public.import_process_jobs() to service_role;
