-- Media Department.
--
-- 1. A central, reusable permission layer for staff (catalogue, role defaults, per-person grants and revokes). It sits
--    beside the existing role checks (has_staff_role) and changes none of them. Future departments only add rows.
-- 2. The Media tables: library, versions, content with an approval workflow, campaigns, requests, performance.
-- 3. A private storage bucket with its own access rules.
--
-- Every write goes through a function that checks the permission in the database, writes the audit log and, where it
-- matters, the item's own history. The app only decides what to show.
-- Media staff are staff (two-factor, directory, votes, birthdays) but get NO other department's powers.

-- ---------------------------------------------------------------------------
-- 1. Permissions
-- ---------------------------------------------------------------------------

create table public.staff_permissions (
  key text primary key check (key ~ '^[a-z_]+\.[a-z_]+$'),
  department text not null,
  description text not null
);

create table public.staff_role_permissions (
  role public.admin_role not null,
  permission text not null references public.staff_permissions (key) on delete cascade,
  primary key (role, permission)
);

-- A person can be given one extra permission, or have one taken away, without changing their role.
create table public.staff_permission_overrides (
  user_id uuid not null references public.profiles (id) on delete cascade,
  permission text not null references public.staff_permissions (key) on delete cascade,
  effect text not null check (effect in ('grant', 'revoke')),
  reason text,
  set_by uuid references public.profiles (id),
  set_at timestamptz not null default now(),
  primary key (user_id, permission)
);

alter table public.staff_permissions enable row level security;
alter table public.staff_role_permissions enable row level security;
alter table public.staff_permission_overrides enable row level security;

insert into public.staff_permissions (key, department, description) values
  ('media.access',      'media', 'Open the Media dashboard and read its content'),
  ('media.upload',      'media', 'Upload files to the Media Library'),
  ('media.edit',        'media', 'Edit titles, descriptions and categories of library files'),
  ('media.archive',     'media', 'Archive and restore library files'),
  ('media.delete',      'media', 'Permanently delete library files (needs confirmation)'),
  ('media.create',      'media', 'Create and submit content for approval'),
  ('media.review',      'media', 'Approve, reject or ask for changes on submitted content'),
  ('media.publish',     'media', 'Publish or schedule approved content, and withdraw published content'),
  ('media.campaigns',   'media', 'Create and manage campaigns'),
  ('media.performance', 'media', 'Record and view content performance'),
  ('media.requests',    'media', 'Work on requests from other departments'),
  ('media.activity',    'media', 'See the Media department activity record');

insert into public.staff_role_permissions (role, permission) values
  ('media', 'media.access'), ('media', 'media.upload'), ('media', 'media.edit'), ('media', 'media.archive'),
  ('media', 'media.create'), ('media', 'media.campaigns'), ('media', 'media.performance'), ('media', 'media.requests'),
  ('tech_admin', 'media.access'), ('tech_admin', 'media.review'), ('tech_admin', 'media.publish'),
  ('tech_admin', 'media.delete'), ('tech_admin', 'media.performance'), ('tech_admin', 'media.activity'),
  ('tech_admin', 'media.requests');

-- True when the signed-in person is staff with two-factor done, has a role that carries the permission (or was granted
-- it), and has not had it taken away. Removing the role removes the access at once: nothing is cached.
create function public.staff_can(p_permission text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select auth.jwt() ->> 'aal'), '') = 'aal2'
     and exists (select 1 from public.admin_roles r where r.user_id = (select auth.uid()))
     and not exists (select 1 from public.staff_permission_overrides o
                      where o.user_id = (select auth.uid()) and o.permission = p_permission and o.effect = 'revoke')
     and (exists (select 1 from public.admin_roles r
                    join public.staff_role_permissions rp on rp.role = r.role
                   where r.user_id = (select auth.uid()) and rp.permission = p_permission)
          or exists (select 1 from public.staff_permission_overrides o
                      where o.user_id = (select auth.uid()) and o.permission = p_permission and o.effect = 'grant'));
$$;

-- The original four roles. Used where "any staff" was too wide now that Media staff exist.
create function public.is_core_staff()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.admin_roles r
                  where r.user_id = (select auth.uid()) and r.role in ('support', 'moderator', 'finance', 'tech_admin'))
     and coalesce((select auth.jwt() ->> 'aal'), '') = 'aal2';
$$;

-- Dual-control requests are for the original staff only. Media staff must not read or raise them.
drop policy if exists approvals_read on public.admin_approvals;
create policy approvals_read on public.admin_approvals
  for select to authenticated using (public.is_core_staff());
drop policy if exists approvals_request on public.admin_approvals;
create policy approvals_request on public.admin_approvals
  for insert to authenticated
  with check (public.is_core_staff() and requested_by = (select auth.uid()));

create policy staff_permissions_read on public.staff_permissions
  for select to authenticated using (public.is_staff());
create policy staff_role_permissions_read on public.staff_role_permissions
  for select to authenticated using (public.is_staff());
create policy staff_overrides_read on public.staff_permission_overrides
  for select to authenticated using (user_id = (select auth.uid()) or public.has_staff_role('tech_admin'));
grant select on public.staff_permissions, public.staff_role_permissions, public.staff_permission_overrides to authenticated;

-- The permissions the signed-in person has right now. The app reads this; it never works them out itself.
create function public.staff_effective_permissions()
returns text[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(p.key order by p.key), '{}')
    from public.staff_permissions p
   where public.staff_can(p.key);
$$;

create function public.grant_staff_permission(p_user uuid, p_permission text, p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('tech_admin') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.admin_roles where user_id = p_user) then
    raise exception 'That person is not staff.' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.staff_permissions where key = p_permission) then
    raise exception 'Unknown permission.' using errcode = 'check_violation';
  end if;
  insert into public.staff_permission_overrides (user_id, permission, effect, reason, set_by)
  values (p_user, p_permission, 'grant', left(p_reason, 300), (select auth.uid()))
  on conflict (user_id, permission) do update set effect = 'grant', reason = excluded.reason, set_by = excluded.set_by, set_at = now();
  perform public.write_audit('staff_permission.granted', 'user', p_user::text, jsonb_build_object('permission', p_permission, 'reason', left(p_reason, 300)));
end;
$$;

create function public.revoke_staff_permission(p_user uuid, p_permission text, p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('tech_admin') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.staff_permissions where key = p_permission) then
    raise exception 'Unknown permission.' using errcode = 'check_violation';
  end if;
  insert into public.staff_permission_overrides (user_id, permission, effect, reason, set_by)
  values (p_user, p_permission, 'revoke', left(p_reason, 300), (select auth.uid()))
  on conflict (user_id, permission) do update set effect = 'revoke', reason = excluded.reason, set_by = excluded.set_by, set_at = now();
  perform public.write_audit('staff_permission.revoked', 'user', p_user::text, jsonb_build_object('permission', p_permission, 'reason', left(p_reason, 300)));
end;
$$;

-- Back to what the role gives by default.
create function public.reset_staff_permission(p_user uuid, p_permission text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('tech_admin') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  delete from public.staff_permission_overrides where user_id = p_user and permission = p_permission;
  perform public.write_audit('staff_permission.reset', 'user', p_user::text, jsonb_build_object('permission', p_permission));
end;
$$;

-- ---------------------------------------------------------------------------
-- Media staff titles, and clean-up when the role is removed
-- ---------------------------------------------------------------------------

create table public.media_staff (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  title text not null default 'member' check (title in ('lead', 'designer', 'social_media', 'editor', 'member')),
  updated_by uuid references public.profiles (id),
  updated_at timestamptz not null default now()
);
alter table public.media_staff enable row level security;
create policy media_staff_read on public.media_staff
  for select to authenticated using (public.staff_can('media.access') or public.has_staff_role('tech_admin'));
grant select on public.media_staff to authenticated;

create function public.media_set_title(p_user uuid, p_title text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.has_staff_role('tech_admin') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.admin_roles where user_id = p_user and role = 'media') then
    raise exception 'That person is not in the Media department.' using errcode = 'check_violation';
  end if;
  insert into public.media_staff (user_id, title, updated_by) values (p_user, p_title, (select auth.uid()))
  on conflict (user_id) do update set title = excluded.title, updated_by = excluded.updated_by, updated_at = now();
  perform public.write_audit('media.staff.title_set', 'user', p_user::text, jsonb_build_object('title', p_title));
end;
$$;

create function public.media_staff_added() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.role = 'media' then
    insert into public.media_staff (user_id, updated_by) values (new.user_id, new.granted_by) on conflict do nothing;
  end if;
  return new;
end;
$$;
create trigger media_staff_added after insert on public.admin_roles
  for each row execute function public.media_staff_added();

-- Removing the role takes the person's Media title and every Media permission grant or revoke with it, even if they keep
-- another staff role.
-- Access itself ends the moment the admin_roles row is gone, because staff_can reads it live.
create function public.media_staff_removed() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.role = 'media' then
    delete from public.media_staff where user_id = old.user_id;
    delete from public.staff_permission_overrides where user_id = old.user_id and permission like 'media.%';
  end if;
  return old;
end;
$$;
create trigger media_staff_removed after delete on public.admin_roles
  for each row execute function public.media_staff_removed();

-- ---------------------------------------------------------------------------
-- 2. Media tables
-- ---------------------------------------------------------------------------

create table public.media_assets (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 2 and 120),
  description text check (description is null or char_length(description) <= 1000),
  category text not null check (category in ('poster', 'banner', 'advert', 'social', 'video', 'announcement', 'education', 'brand', 'other')),
  kind text not null check (kind in ('image', 'video', 'document')),
  status text not null default 'active' check (status in ('active', 'archived', 'deleted')),
  storage_path text not null unique,
  mime_type text not null,
  size_bytes bigint not null check (size_bytes > 0),
  sha256 text,
  scan_status text not null default 'pending' check (scan_status in ('pending', 'clean', 'infected', 'failed')),
  scanned_at timestamptz,
  version integer not null default 1,
  uploaded_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id),
  updated_at timestamptz not null default now(),
  archived_by uuid references public.profiles (id),
  archived_at timestamptz,
  deleted_by uuid references public.profiles (id),
  deleted_at timestamptz
);
create index media_assets_status_idx on public.media_assets (status, created_at desc);

create table public.media_asset_versions (
  id bigint generated always as identity primary key,
  asset_id uuid not null references public.media_assets (id) on delete cascade,
  version integer not null,
  title text not null,
  description text,
  category text not null,
  changed_by uuid references public.profiles (id),
  changed_at timestamptz not null default now(),
  note text
);

create table public.media_campaigns (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 2 and 120),
  description text check (description is null or char_length(description) <= 2000),
  starts_on date,
  ends_on date,
  status text not null default 'planning' check (status in ('planning', 'active', 'completed', 'cancelled')),
  created_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_on is null or starts_on is null or ends_on >= starts_on)
);

create table public.media_requests (
  id uuid primary key default gen_random_uuid(),
  requested_by uuid not null references public.profiles (id),
  from_department text not null,
  kind text not null check (kind in ('graphic', 'announcement', 'campaign', 'educational', 'statement', 'other')),
  title text not null check (char_length(btrim(title)) between 3 and 120),
  details text not null check (char_length(btrim(details)) between 3 and 2000),
  priority text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  due_on date,
  status text not null default 'open' check (status in ('open', 'in_progress', 'done', 'declined', 'cancelled')),
  assigned_to uuid references public.profiles (id),
  resolution_note text check (resolution_note is null or char_length(resolution_note) <= 1000),
  content_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index media_requests_status_idx on public.media_requests (status, created_at desc);

create table public.media_content (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('poster', 'banner', 'advert', 'social_post', 'announcement', 'notice', 'education', 'video')),
  title text not null check (char_length(btrim(title)) between 2 and 120),
  body text check (body is null or char_length(body) <= 5000),
  channel text check (channel is null or channel in ('in_app', 'facebook', 'instagram', 'tiktok', 'website', 'other')),
  campaign_id uuid references public.media_campaigns (id) on delete set null,
  request_id uuid references public.media_requests (id) on delete set null,
  status text not null default 'draft' check (status in ('draft', 'submitted', 'changes_requested', 'approved', 'rejected', 'scheduled', 'published', 'withdrawn', 'archived')),
  version integer not null default 1,
  created_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  review_note text check (review_note is null or char_length(review_note) <= 1000),
  scheduled_for timestamptz,
  published_by uuid references public.profiles (id),
  published_at timestamptz,
  -- Nobody approves their own work.
  check (reviewed_by is null or reviewed_by <> created_by)
);
create index media_content_status_idx on public.media_content (status, updated_at desc);
alter table public.media_requests add constraint media_requests_content_fk foreign key (content_id) references public.media_content (id) on delete set null;

create table public.media_content_assets (
  content_id uuid not null references public.media_content (id) on delete cascade,
  asset_id uuid not null references public.media_assets (id),
  position integer not null default 0,
  primary key (content_id, asset_id)
);

create table public.media_content_versions (
  id bigint generated always as identity primary key,
  content_id uuid not null references public.media_content (id) on delete cascade,
  version integer not null,
  title text not null,
  body text,
  changed_by uuid references public.profiles (id),
  changed_at timestamptz not null default now()
);

-- The item's own history: who did what and when. Cannot be edited or removed through the app.
create table public.media_content_events (
  id bigint generated always as identity primary key,
  content_id uuid not null references public.media_content (id) on delete cascade,
  event text not null,
  actor_id uuid references public.profiles (id),
  note text,
  created_at timestamptz not null default now()
);

create table public.media_performance (
  id bigint generated always as identity primary key,
  content_id uuid not null references public.media_content (id) on delete cascade,
  channel text not null,
  impressions integer not null default 0 check (impressions >= 0),
  clicks integer not null default 0 check (clicks >= 0),
  engagements integer not null default 0 check (engagements >= 0),
  recorded_by uuid not null references public.profiles (id),
  recorded_at timestamptz not null default now()
);

alter table public.media_assets enable row level security;
alter table public.media_asset_versions enable row level security;
alter table public.media_campaigns enable row level security;
alter table public.media_requests enable row level security;
alter table public.media_content enable row level security;
alter table public.media_content_assets enable row level security;
alter table public.media_content_versions enable row level security;
alter table public.media_content_events enable row level security;
alter table public.media_performance enable row level security;

-- Reading: Media staff (and administrators, who hold media.access) only. Unpublished work is never visible to anyone else.
-- Other departments can see only the requests they made themselves.
create policy media_assets_read on public.media_assets for select to authenticated using (public.staff_can('media.access'));
create policy media_asset_versions_read on public.media_asset_versions for select to authenticated using (public.staff_can('media.access'));
create policy media_campaigns_read on public.media_campaigns for select to authenticated using (public.staff_can('media.access'));
create policy media_content_read on public.media_content for select to authenticated using (public.staff_can('media.access'));
create policy media_content_assets_read on public.media_content_assets for select to authenticated using (public.staff_can('media.access'));
create policy media_content_versions_read on public.media_content_versions for select to authenticated using (public.staff_can('media.access'));
create policy media_content_events_read on public.media_content_events for select to authenticated using (public.staff_can('media.access'));
create policy media_performance_read on public.media_performance for select to authenticated using (public.staff_can('media.performance'));
create policy media_requests_read on public.media_requests for select to authenticated
  using (public.staff_can('media.access') or (requested_by = (select auth.uid()) and public.is_staff()));

-- No direct writes at all: everything goes through the functions below.
revoke all on public.media_assets, public.media_asset_versions, public.media_campaigns, public.media_requests,
  public.media_content, public.media_content_assets, public.media_content_versions, public.media_content_events,
  public.media_performance from anon, authenticated;
grant select on public.media_assets, public.media_asset_versions, public.media_campaigns, public.media_requests,
  public.media_content, public.media_content_assets, public.media_content_versions, public.media_content_events,
  public.media_performance to authenticated;

-- Internal helpers --------------------------------------------------------

create function public.media_need(p_permission text)
returns uuid
language plpgsql stable security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.staff_can(p_permission) then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  return (select auth.uid());
end;
$$;

create function public.media_log(p_content uuid, p_event text, p_note text default null)
returns void
language sql security definer set search_path = ''
as $$
  insert into public.media_content_events (content_id, event, actor_id, note) values (p_content, p_event, (select auth.uid()), left(p_note, 1000));
$$;

-- Versions: every edit keeps the old text.
create function public.media_asset_snapshot() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (old.title, old.description, old.category) is distinct from (new.title, new.description, new.category) then
    insert into public.media_asset_versions (asset_id, version, title, description, category, changed_by)
    values (old.id, old.version, old.title, old.description, old.category, (select auth.uid()));
    new.version := old.version + 1;
    new.updated_at := now();
  end if;
  return new;
end;
$$;
create trigger media_asset_snapshot before update on public.media_assets
  for each row execute function public.media_asset_snapshot();

create function public.media_content_snapshot() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (old.title, old.body) is distinct from (new.title, new.body) then
    insert into public.media_content_versions (content_id, version, title, body, changed_by)
    values (old.id, old.version, old.title, old.body, (select auth.uid()));
    new.version := old.version + 1;
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create trigger media_content_snapshot before update on public.media_content
  for each row execute function public.media_content_snapshot();

-- Library --------------------------------------------------------------------

-- Registers a file that is already in the media-library bucket. The type and size are checked against the real object,
-- never against what the app claims. The scan result arrives later from a trusted worker.
create function public.media_asset_register(p_title text, p_description text, p_category text, p_path text, p_sha256 text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := public.media_need('media.upload');
  obj record;
  mime text;
  size_b bigint;
  k text;
  limit_b bigint;
  new_id uuid;
begin
  if split_part(p_path, '/', 1) <> uid::text or p_path like '%..%' or char_length(p_path) > 300 then
    raise exception 'The file must be in your own folder.' using errcode = 'insufficient_privilege';
  end if;
  select o.metadata into obj from storage.objects o where o.bucket_id = 'media-library' and o.name = p_path;
  if not found then
    raise exception 'The file was not uploaded.' using errcode = 'check_violation';
  end if;
  mime := obj.metadata ->> 'mimetype';
  size_b := coalesce((obj.metadata ->> 'size')::bigint, 0);
  k := case when mime in ('image/jpeg', 'image/png', 'image/webp') then 'image'
            when mime in ('video/mp4', 'video/quicktime') then 'video'
            when mime = 'application/pdf' then 'document'
            else null end;
  if k is null then
    raise exception 'Upload a JPG, PNG, WebP, MP4, MOV or PDF file.' using errcode = 'check_violation';
  end if;
  -- The extension must agree with the type, so a renamed file is refused.
  if lower(p_path) !~ (case mime when 'image/jpeg' then '\.(jpe?g)$' when 'image/png' then '\.png$' when 'image/webp' then '\.webp$'
                               when 'video/mp4' then '\.mp4$' when 'video/quicktime' then '\.mov$' else '\.pdf$' end) then
    raise exception 'The file name does not match its type.' using errcode = 'check_violation';
  end if;
  limit_b := case k when 'image' then 10485760 when 'document' then 20971520 else 52428800 end;
  if size_b < 1 or size_b > limit_b then
    raise exception 'That file is too large. Images up to 10 MB, PDFs up to 20 MB, videos up to 50 MB.' using errcode = 'check_violation';
  end if;
  if p_category not in ('poster', 'banner', 'advert', 'social', 'video', 'announcement', 'education', 'brand', 'other') then
    raise exception 'Choose a category.' using errcode = 'check_violation';
  end if;
  perform public.enforce_rate_limit('media_upload', 60, 60);

  insert into public.media_assets (title, description, category, kind, storage_path, mime_type, size_bytes, sha256, uploaded_by)
  values (btrim(p_title), nullif(btrim(p_description), ''), p_category, k, p_path, mime, size_b, lower(p_sha256), uid)
  returning id into new_id;
  perform public.write_audit('media.asset.uploaded', 'media_asset', new_id::text, jsonb_build_object('kind', k, 'size', size_b, 'category', p_category));
  return new_id;
end;
$$;

-- Only the scanner (service role) can say a file is clean.
create function public.media_record_scan(p_asset uuid, p_result text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if p_result not in ('clean', 'infected', 'failed') then
    raise exception 'Result must be clean, infected or failed.' using errcode = 'check_violation';
  end if;
  update public.media_assets set scan_status = p_result, scanned_at = now() where id = p_asset and status <> 'deleted';
  if not found then
    raise exception 'File not found.' using errcode = 'no_data_found';
  end if;
  insert into public.audit_logs (actor_id, action, target_type, target_id, metadata)
  values (null, 'media.asset.scanned', 'media_asset', p_asset::text, jsonb_build_object('result', p_result));
end;
$$;

create function public.media_asset_update(p_asset uuid, p_title text, p_description text, p_category text, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare uid uuid := public.media_need('media.edit');
begin
  if p_category not in ('poster', 'banner', 'advert', 'social', 'video', 'announcement', 'education', 'brand', 'other') then
    raise exception 'Choose a category.' using errcode = 'check_violation';
  end if;
  update public.media_assets set title = btrim(p_title), description = nullif(btrim(p_description), ''), category = p_category, updated_by = uid
   where id = p_asset and status <> 'deleted';
  if not found then
    raise exception 'File not found.' using errcode = 'no_data_found';
  end if;
  perform public.write_audit('media.asset.edited', 'media_asset', p_asset::text, jsonb_build_object('note', left(p_note, 300)));
end;
$$;

-- A file attached to published or scheduled content cannot be archived: it would disappear from public view.
create function public.media_asset_archive(p_asset uuid, p_archive boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare uid uuid := public.media_need('media.archive');
begin
  if p_archive and exists (select 1 from public.media_content_assets ca join public.media_content c on c.id = ca.content_id
                            where ca.asset_id = p_asset and c.status in ('published', 'scheduled')) then
    raise exception 'This file is used by published content. Withdraw that content first.' using errcode = 'check_violation';
  end if;
  update public.media_assets
     set status = case when p_archive then 'archived' else 'active' end,
         archived_by = case when p_archive then uid end, archived_at = case when p_archive then now() end, updated_by = uid
   where id = p_asset and status in ('active', 'archived');
  if not found then
    raise exception 'File not found.' using errcode = 'no_data_found';
  end if;
  perform public.write_audit(case when p_archive then 'media.asset.archived' else 'media.asset.restored' end, 'media_asset', p_asset::text, '{}');
end;
$$;

-- Permanent deletion: its own permission, the file must be archived first, nothing published may use it, and the caller
-- must type the confirmation word. The record stays (marked deleted) so the history survives; the app then removes the
-- stored file and the storage policy only allows that for files marked deleted.
create function public.media_asset_delete(p_asset uuid, p_confirm text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := public.media_need('media.delete');
  a public.media_assets;
begin
  if p_confirm is distinct from 'DELETE' then
    raise exception 'Type DELETE to confirm that you want to delete this file for good.' using errcode = 'check_violation';
  end if;
  select * into a from public.media_assets where id = p_asset for update;
  if not found or a.status = 'deleted' then
    raise exception 'File not found.' using errcode = 'no_data_found';
  end if;
  if a.status <> 'archived' then
    raise exception 'Archive the file first, then delete it.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.media_content_assets ca join public.media_content c on c.id = ca.content_id
              where ca.asset_id = p_asset and c.status in ('published', 'scheduled')) then
    raise exception 'This file is used by published content and cannot be deleted.' using errcode = 'check_violation';
  end if;
  update public.media_assets set status = 'deleted', deleted_by = uid, deleted_at = now() where id = p_asset;
  perform public.write_audit('media.asset.deleted', 'media_asset', p_asset::text, jsonb_build_object('path', a.storage_path));
  return a.storage_path;
end;
$$;

-- Content --------------------------------------------------------------------

create function public.media_content_save(
  p_id uuid, p_kind text, p_title text, p_body text, p_channel text, p_campaign uuid, p_assets uuid[] default '{}', p_request uuid default null
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := public.media_need('media.create');
  c public.media_content;
  cid uuid;
  a uuid;
  pos integer := 0;
begin
  if exists (select 1 from unnest(coalesce(p_assets, '{}')) x
              where not exists (select 1 from public.media_assets m where m.id = x and m.status = 'active' and m.scan_status <> 'infected')) then
    raise exception 'One of the chosen files cannot be used (archived, deleted or failed the safety scan).' using errcode = 'check_violation';
  end if;
  if p_id is null then
    insert into public.media_content (kind, title, body, channel, campaign_id, request_id, created_by)
    values (p_kind, btrim(p_title), p_body, p_channel, p_campaign, p_request, uid)
    returning id into cid;
    perform public.media_log(cid, 'created');
  else
    select * into c from public.media_content where id = p_id for update;
    if not found then
      raise exception 'Content not found.' using errcode = 'no_data_found';
    end if;
    if c.created_by <> uid then
      raise exception 'Only the person who created this can edit it.' using errcode = 'insufficient_privilege';
    end if;
    if c.status in ('published', 'scheduled', 'archived', 'submitted', 'approved') then
      raise exception 'This content is locked. Ask a reviewer to send it back, or withdraw it first.' using errcode = 'check_violation';
    end if;
    update public.media_content
       set kind = p_kind, title = btrim(p_title), body = p_body, channel = p_channel, campaign_id = p_campaign,
           status = case when status in ('rejected', 'changes_requested', 'withdrawn') then 'draft' else status end
     where id = p_id;
    cid := p_id;
    perform public.media_log(cid, 'edited');
  end if;
  delete from public.media_content_assets where content_id = cid;
  foreach a in array coalesce(p_assets, '{}') loop
    insert into public.media_content_assets (content_id, asset_id, position) values (cid, a, pos) on conflict do nothing;
    pos := pos + 1;
  end loop;
  perform public.write_audit('media.content.saved', 'media_content', cid::text, jsonb_build_object('kind', p_kind));
  return cid;
end;
$$;

create function public.media_content_submit(p_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := public.media_need('media.create');
  c public.media_content;
begin
  select * into c from public.media_content where id = p_id for update;
  if not found or c.created_by <> uid then
    raise exception 'Content not found.' using errcode = 'no_data_found';
  end if;
  if c.status not in ('draft', 'changes_requested') then
    raise exception 'Only a draft can be submitted.' using errcode = 'check_violation';
  end if;
  if char_length(btrim(coalesce(c.body, ''))) = 0 and not exists (select 1 from public.media_content_assets where content_id = p_id) then
    raise exception 'Add some text or a file before submitting.' using errcode = 'check_violation';
  end if;
  update public.media_content set status = 'submitted', submitted_at = now(), reviewed_by = null, reviewed_at = null, review_note = null where id = p_id;
  perform public.media_log(p_id, 'submitted');
  perform public.write_audit('media.content.submitted', 'media_content', p_id::text, '{}');
end;
$$;

-- Approve, reject or ask for changes. Not your own work. A reason is required when it is not an approval.
create function public.media_content_review(p_id uuid, p_decision text, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := public.media_need('media.review');
  c public.media_content;
  next_status text;
begin
  if p_decision not in ('approve', 'reject', 'changes') then
    raise exception 'Decision must be approve, reject or changes.' using errcode = 'check_violation';
  end if;
  select * into c from public.media_content where id = p_id for update;
  if not found then
    raise exception 'Content not found.' using errcode = 'no_data_found';
  end if;
  if c.created_by = uid then
    raise exception 'You cannot review your own work.' using errcode = 'insufficient_privilege';
  end if;
  if c.status <> 'submitted' then
    raise exception 'Only submitted content can be reviewed.' using errcode = 'check_violation';
  end if;
  if p_decision <> 'approve' and char_length(btrim(coalesce(p_note, ''))) < 3 then
    raise exception 'Write the reason or the changes you want.' using errcode = 'check_violation';
  end if;
  next_status := case p_decision when 'approve' then 'approved' when 'reject' then 'rejected' else 'changes_requested' end;
  update public.media_content set status = next_status, reviewed_by = uid, reviewed_at = now(), review_note = left(p_note, 1000) where id = p_id;
  perform public.media_log(p_id, next_status, p_note);
  perform public.write_audit('media.content.' || next_status, 'media_content', p_id::text, jsonb_build_object('note', left(p_note, 300)));
end;
$$;

-- Publish now, or schedule for later. Approved content only. Every attached file must have passed the safety scan,
-- unless the platform setting media.require_scan is switched off (for example where no scanner is installed yet).
create function public.media_content_publish(p_id uuid, p_when timestamptz default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := public.media_need('media.publish');
  c public.media_content;
  future boolean := p_when is not null and p_when > now() + interval '1 minute';
begin
  select * into c from public.media_content where id = p_id for update;
  if not found then
    raise exception 'Content not found.' using errcode = 'no_data_found';
  end if;
  if c.status not in ('approved', 'scheduled') then
    raise exception 'Only approved content can be published.' using errcode = 'check_violation';
  end if;
  if c.reviewed_by is null then
    raise exception 'This content has not been reviewed.' using errcode = 'check_violation';
  end if;
  if public.setting_bool('media.require_scan', true) and exists (
       select 1 from public.media_content_assets ca join public.media_assets m on m.id = ca.asset_id
        where ca.content_id = p_id and m.scan_status <> 'clean') then
    raise exception 'A file on this content has not passed the safety scan yet.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.media_content_assets ca join public.media_assets m on m.id = ca.asset_id
              where ca.content_id = p_id and m.status <> 'active') then
    raise exception 'A file on this content was archived or deleted.' using errcode = 'check_violation';
  end if;
  update public.media_content
     set status = case when future then 'scheduled' else 'published' end,
         scheduled_for = case when future then p_when end,
         published_by = uid, published_at = case when future then null else now() end
   where id = p_id;
  perform public.media_log(p_id, case when future then 'scheduled' else 'published' end);
  perform public.write_audit(case when future then 'media.content.scheduled' else 'media.content.published' end, 'media_content', p_id::text, jsonb_build_object('when', p_when));
end;
$$;

-- Published content is never deleted. It can be withdrawn (taken down) or archived, by a publisher.
create function public.media_content_withdraw(p_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare uid uuid := public.media_need('media.publish');
begin
  if char_length(btrim(coalesce(p_reason, ''))) < 3 then
    raise exception 'Write a short reason. It is saved in the audit log.' using errcode = 'check_violation';
  end if;
  update public.media_content set status = 'withdrawn' where id = p_id and status in ('published', 'scheduled');
  if not found then
    raise exception 'Only published or scheduled content can be withdrawn.' using errcode = 'check_violation';
  end if;
  perform public.media_log(p_id, 'withdrawn', p_reason);
  perform public.write_audit('media.content.withdrawn', 'media_content', p_id::text, jsonb_build_object('reason', left(p_reason, 300), 'by', uid));
end;
$$;

-- Campaigns -------------------------------------------------------------------

create function public.media_campaign_save(p_id uuid, p_name text, p_description text, p_starts date, p_ends date, p_status text default 'planning')
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := public.media_need('media.campaigns');
  cid uuid;
begin
  if p_id is null then
    insert into public.media_campaigns (name, description, starts_on, ends_on, status, created_by)
    values (btrim(p_name), nullif(btrim(p_description), ''), p_starts, p_ends, p_status, uid) returning id into cid;
  else
    update public.media_campaigns set name = btrim(p_name), description = nullif(btrim(p_description), ''), starts_on = p_starts,
           ends_on = p_ends, status = p_status, updated_at = now() where id = p_id returning id into cid;
    if cid is null then
      raise exception 'Campaign not found.' using errcode = 'no_data_found';
    end if;
  end if;
  perform public.write_audit('media.campaign.saved', 'media_campaign', cid::text, jsonb_build_object('status', p_status));
  return cid;
end;
$$;

-- Requests from other departments -----------------------------------------------

-- Any staff member can ask Media for something. It is tracked here, not in chat.
create function public.media_request_create(p_kind text, p_title text, p_details text, p_priority text default 'normal', p_due date default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  dept text;
  new_id uuid;
begin
  if not public.is_staff() then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  select string_agg(r.role::text, ', ' order by r.role) into dept from public.admin_roles r where r.user_id = uid;
  perform public.enforce_rate_limit('media_request', 30, 1440);
  insert into public.media_requests (requested_by, from_department, kind, title, details, priority, due_on)
  values (uid, coalesce(dept, 'staff'), p_kind, btrim(p_title), btrim(p_details), p_priority, p_due)
  returning id into new_id;
  perform public.write_audit('media.request.created', 'media_request', new_id::text, jsonb_build_object('kind', p_kind, 'priority', p_priority));
  return new_id;
end;
$$;

create function public.media_request_update(p_id uuid, p_status text, p_assigned_to uuid default null, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  r public.media_requests;
begin
  select * into r from public.media_requests where id = p_id for update;
  if not found then
    raise exception 'Request not found.' using errcode = 'no_data_found';
  end if;
  if public.staff_can('media.requests') then
    if p_status not in ('open', 'in_progress', 'done', 'declined') then
      raise exception 'Choose open, in progress, done or declined.' using errcode = 'check_violation';
    end if;
    if p_status in ('done', 'declined') and char_length(btrim(coalesce(p_note, ''))) < 3 then
      raise exception 'Write a short note for the person who asked.' using errcode = 'check_violation';
    end if;
    if p_assigned_to is not null and not exists (select 1 from public.admin_roles a where a.user_id = p_assigned_to and a.role = 'media') then
      raise exception 'Assign the request to someone in the Media department.' using errcode = 'check_violation';
    end if;
  elsif r.requested_by = uid and public.is_staff() and p_status = 'cancelled' and r.status = 'open' then
    null; -- the person who asked can withdraw an open request
  else
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  update public.media_requests
     set status = p_status, assigned_to = coalesce(p_assigned_to, assigned_to), resolution_note = coalesce(left(p_note, 1000), resolution_note), updated_at = now()
   where id = p_id;
  perform public.write_audit('media.request.' || p_status, 'media_request', p_id::text, jsonb_build_object('assigned_to', p_assigned_to));
end;
$$;

-- Performance -------------------------------------------------------------------

create function public.media_record_performance(p_content uuid, p_channel text, p_impressions integer, p_clicks integer, p_engagements integer)
returns void
language plpgsql security definer set search_path = ''
as $$
declare uid uuid := public.media_need('media.performance');
begin
  if not exists (select 1 from public.media_content where id = p_content and status = 'published') then
    raise exception 'Numbers can only be recorded for published content.' using errcode = 'check_violation';
  end if;
  insert into public.media_performance (content_id, channel, impressions, clicks, engagements, recorded_by)
  values (p_content, left(btrim(p_channel), 40), greatest(p_impressions, 0), greatest(p_clicks, 0), greatest(p_engagements, 0), uid);
  perform public.write_audit('media.performance.recorded', 'media_content', p_content::text, jsonb_build_object('channel', p_channel));
end;
$$;

create function public.media_performance_summary()
returns table (content_id uuid, title text, kind text, published_at timestamptz, impressions bigint, clicks bigint, engagements bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.media_need('media.performance');
  return query
    select c.id, c.title, c.kind, c.published_at,
           coalesce(sum(p.impressions), 0)::bigint, coalesce(sum(p.clicks), 0)::bigint, coalesce(sum(p.engagements), 0)::bigint
      from public.media_content c left join public.media_performance p on p.content_id = c.id
     where c.status = 'published'
     group by c.id order by c.published_at desc nulls last limit 100;
end;
$$;

-- Overview, calendar, activity ---------------------------------------------------

create function public.media_overview()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.media_need('media.access');
  return jsonb_build_object(
    'assets', (select count(*) from public.media_assets where status = 'active'),
    'assets_awaiting_scan', (select count(*) from public.media_assets where status = 'active' and scan_status = 'pending'),
    'drafts', (select count(*) from public.media_content where status in ('draft', 'changes_requested')),
    'submitted', (select count(*) from public.media_content where status = 'submitted'),
    'approved_waiting', (select count(*) from public.media_content where status = 'approved'),
    'scheduled', (select count(*) from public.media_content where status = 'scheduled'),
    'published', (select count(*) from public.media_content where status = 'published'),
    'open_requests', (select count(*) from public.media_requests where status in ('open', 'in_progress')),
    'active_campaigns', (select count(*) from public.media_campaigns where status = 'active')
  );
end;
$$;

create function public.media_calendar(p_from date, p_to date)
returns table (kind text, id uuid, title text, at timestamptz, status text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.media_need('media.access');
  if p_to - p_from > 370 then
    raise exception 'Choose a range of one year or less.' using errcode = 'check_violation';
  end if;
  return query
    select 'content'::text, c.id, c.title, coalesce(c.scheduled_for, c.published_at), c.status
      from public.media_content c
     where c.status in ('scheduled', 'published') and coalesce(c.scheduled_for, c.published_at)::date between p_from and p_to
    union all
    select 'campaign'::text, m.id, m.name, m.starts_on::timestamptz, m.status
      from public.media_campaigns m
     where m.status <> 'cancelled' and m.starts_on is not null and m.starts_on between p_from and p_to
    order by 4;
end;
$$;

create function public.media_activity(p_limit integer default 100)
returns table (at timestamptz, actor_id uuid, actor_name text, action text, target_type text, target_id text, metadata jsonb)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.media_need('media.activity');
  return query
    select a.created_at, a.actor_id, p.display_name, a.action, a.target_type, a.target_id, a.metadata
      from public.audit_logs a left join public.profiles p on p.id = a.actor_id
     where a.action like 'media.%' or a.action like 'staff_permission.%'
     order by a.created_at desc limit least(greatest(coalesce(p_limit, 100), 1), 300);
end;
$$;

-- The public side: announcements that have been approved and published. Open to everyone, returns nothing else.
create function public.media_public_announcements(p_limit integer default 10)
returns table (id uuid, kind text, title text, body text, published_at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select c.id, c.kind, c.title, c.body, coalesce(c.published_at, c.scheduled_for)
    from public.media_content c
   where c.kind in ('announcement', 'notice')
     and c.channel in ('in_app', 'website')
     and (c.status = 'published' or (c.status = 'scheduled' and c.scheduled_for <= now()))
   order by coalesce(c.published_at, c.scheduled_for) desc
   limit least(greatest(coalesce(p_limit, 10), 1), 30);
$$;

-- ---------------------------------------------------------------------------
-- 3. Storage
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('media-library', 'media-library', false, 52428800,
   array['image/jpeg', 'image/png', 'image/webp', 'video/mp4', 'video/quicktime', 'application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- True when the stored file is attached to published content, so ordinary people may see it.
create function public.media_object_is_public(p_name text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.media_assets a
      join public.media_content_assets ca on ca.asset_id = a.id
      join public.media_content c on c.id = ca.content_id
     where a.storage_path = p_name and a.status = 'active' and a.scan_status = 'clean'
       and (c.status = 'published' or (c.status = 'scheduled' and c.scheduled_for <= now())));
$$;

create function public.media_object_is_deleted(p_name text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.media_assets a where a.storage_path = p_name and a.status = 'deleted');
$$;

create policy "media library: upload to own folder" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'media-library' and public.staff_can('media.upload')
              and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "media library: staff read" on storage.objects
  for select to authenticated
  using (bucket_id = 'media-library' and (public.staff_can('media.access') or public.media_object_is_public(name)));

create policy "media library: public files for guests" on storage.objects
  for select to anon
  using (bucket_id = 'media-library' and public.media_object_is_public(name));

-- Only a file the database has already marked as deleted can be removed from storage, and only by someone who may delete.
create policy "media library: remove deleted files" on storage.objects
  for delete to authenticated
  using (bucket_id = 'media-library' and public.staff_can('media.delete') and public.media_object_is_deleted(name));

-- ---------------------------------------------------------------------------
-- Who can call what
-- ---------------------------------------------------------------------------

revoke execute on function
  public.staff_can(text), public.is_core_staff(), public.staff_effective_permissions(),
  public.grant_staff_permission(uuid, text, text), public.revoke_staff_permission(uuid, text, text), public.reset_staff_permission(uuid, text),
  public.media_set_title(uuid, text), public.media_staff_added(), public.media_staff_removed(),
  public.media_need(text), public.media_log(uuid, text, text), public.media_asset_snapshot(), public.media_content_snapshot(),
  public.media_asset_register(text, text, text, text, text), public.media_record_scan(uuid, text),
  public.media_asset_update(uuid, text, text, text, text), public.media_asset_archive(uuid, boolean), public.media_asset_delete(uuid, text),
  public.media_content_save(uuid, text, text, text, text, uuid, uuid[], uuid), public.media_content_submit(uuid),
  public.media_content_review(uuid, text, text), public.media_content_publish(uuid, timestamptz), public.media_content_withdraw(uuid, text),
  public.media_campaign_save(uuid, text, text, date, date, text),
  public.media_request_create(text, text, text, text, date), public.media_request_update(uuid, text, uuid, text),
  public.media_record_performance(uuid, text, integer, integer, integer), public.media_performance_summary(),
  public.media_overview(), public.media_calendar(date, date), public.media_activity(integer), public.media_public_announcements(integer),
  public.media_object_is_public(text), public.media_object_is_deleted(text)
  from public, anon, authenticated;

-- Policies call these as the signed-in role, so they must stay executable.
grant execute on function public.staff_can(text), public.is_core_staff(), public.media_object_is_public(text), public.media_object_is_deleted(text)
  to anon, authenticated;

grant execute on function
  public.staff_effective_permissions(),
  public.grant_staff_permission(uuid, text, text), public.revoke_staff_permission(uuid, text, text), public.reset_staff_permission(uuid, text),
  public.media_set_title(uuid, text),
  public.media_asset_register(text, text, text, text, text),
  public.media_asset_update(uuid, text, text, text, text), public.media_asset_archive(uuid, boolean), public.media_asset_delete(uuid, text),
  public.media_content_save(uuid, text, text, text, text, uuid, uuid[], uuid), public.media_content_submit(uuid),
  public.media_content_review(uuid, text, text), public.media_content_publish(uuid, timestamptz), public.media_content_withdraw(uuid, text),
  public.media_campaign_save(uuid, text, text, date, date, text),
  public.media_request_create(text, text, text, text, date), public.media_request_update(uuid, text, uuid, text),
  public.media_record_performance(uuid, text, integer, integer, integer), public.media_performance_summary(),
  public.media_overview(), public.media_calendar(date, date), public.media_activity(integer)
  to authenticated;
grant execute on function public.media_public_announcements(integer) to anon, authenticated;
grant execute on function public.media_record_scan(uuid, text) to service_role;
