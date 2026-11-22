-- 0011: Business Hub (Module C)
--
-- What this adds, in order:
--   1. A permission table for businesses (owner / manager / staff) in one function, business_can().
--   2. Team invitations by email, role changes, removal. Direct inserts into business_members are closed.
--   3. Branches, and a branch on listings and orders.
--   4. Catalogues (named groups of a business's listings).
--   5. A public storefront (views and one search function a signed-out visitor can use).
--   6. Inventory: stock counts with a movement history, hiding sold-out items and restoring them on restock.
--   7. Business order list and analytics.
--
-- Rules:
--   * Business data is written only through functions that check business_can(); tables have no write grants.
--   * Suspended members lose all business permissions.
--   * New functions are closed to everyone first, then opened on purpose.
--
-- Known limit (also in docs/DIRECTIVE_PROGRESS.md): orders from migration 0009 reserve the whole listing for one
-- buyer at a time, so a business with 5 in stock can still only have one confirmed order per listing at once.
-- Each completed order takes one unit off the stock.

-- ---------------------------------------------------------------------------
-- 1. Permissions
-- ---------------------------------------------------------------------------

create function public.business_can(p_business uuid, p_permission text)
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
declare
  allowed public.business_member_role[];
begin
  allowed := case p_permission
    when 'view_team'        then array['owner', 'manager', 'staff']::public.business_member_role[]
    when 'manage_team'      then array['owner']::public.business_member_role[]
    when 'edit_profile'     then array['owner', 'manager']::public.business_member_role[]
    when 'manage_branches'  then array['owner', 'manager']::public.business_member_role[]
    when 'manage_catalogues' then array['owner', 'manager']::public.business_member_role[]
    when 'manage_listings'  then array['owner', 'manager', 'staff']::public.business_member_role[]
    when 'manage_inventory' then array['owner', 'manager', 'staff']::public.business_member_role[]
    when 'manage_orders'    then array['owner', 'manager', 'staff']::public.business_member_role[]
    when 'view_analytics'   then array['owner', 'manager']::public.business_member_role[]
    else null
  end;
  if allowed is null then
    raise exception 'Unknown permission: %', p_permission using errcode = 'invalid_parameter_value';
  end if;

  return p_business is not null and exists (
    select 1
      from public.business_members m
      join public.profiles pr on pr.id = m.user_id
     where m.business_id = p_business
       and m.user_id = (select auth.uid())
       and m.role = any (allowed)
       and pr.account_state <> 'suspended'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Team: invitations, roles, removal
-- ---------------------------------------------------------------------------

create table public.business_invitations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  email text not null check (email = lower(btrim(email)) and email like '_%@_%' and char_length(email) <= 254),
  role public.business_member_role not null check (role in ('manager', 'staff')),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'revoked')),
  invited_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  responded_at timestamptz
);
create unique index business_invitations_one_pending on public.business_invitations (business_id, email) where status = 'pending';
create index business_invitations_email_idx on public.business_invitations (email) where status = 'pending';
alter table public.business_invitations enable row level security;
-- No policies and no grants: only the functions below can read or write invitations.

-- Team changes go through functions only, so the rules below cannot be skipped.
drop policy members_add on public.business_members;
drop policy members_remove on public.business_members;
revoke insert, delete on public.business_members from authenticated;

create function public.invite_member(p_business uuid, p_email text, p_role public.business_member_role)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  mail text := lower(btrim(coalesce(p_email, '')));
  new_id uuid;
begin
  if not public.business_can(p_business, 'manage_team') then
    raise exception 'Only the owner can invite people.' using errcode = 'insufficient_privilege';
  end if;
  if p_role not in ('manager', 'staff') then
    raise exception 'People can be invited as manager or staff.' using errcode = 'check_violation';
  end if;
  if mail not like '_%@_%.__%' or char_length(mail) > 254 then
    raise exception 'Enter a valid email address.' using errcode = 'check_violation';
  end if;

  perform public.enforce_rate_limit('business_invite', 20, 60);

  -- An old invitation that was never answered stops blocking a new one.
  update public.business_invitations set status = 'revoked', responded_at = now()
   where business_id = p_business and email = mail and status = 'pending' and expires_at <= now();

  if exists (
    select 1 from public.business_members m join auth.users u on u.id = m.user_id
     where m.business_id = p_business and lower(u.email) = mail
  ) then
    raise exception 'That person is already on the team.' using errcode = 'unique_violation';
  end if;
  if (select count(*) from public.business_members where business_id = p_business)
     + (select count(*) from public.business_invitations where business_id = p_business and status = 'pending' and expires_at > now()) >= 30 then
    raise exception 'A business can have at most 30 team members and open invitations.' using errcode = 'check_violation';
  end if;

  insert into public.business_invitations (business_id, email, role, invited_by, expires_at)
  values (p_business, mail, p_role, (select auth.uid()), now() + interval '7 days')
  returning id into new_id;

  perform public.write_audit('business.invited', 'business', p_business::text, jsonb_build_object('email', mail, 'role', p_role));
  return new_id;
exception
  when unique_violation then
    if sqlerrm like '%business_invitations_one_pending%' then
      raise exception 'That email already has an open invitation.' using errcode = 'unique_violation';
    end if;
    raise;
end;
$$;

create function public.revoke_invitation(p_invitation uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  inv public.business_invitations;
begin
  select * into inv from public.business_invitations where id = p_invitation and status = 'pending';
  if not found or not public.business_can(inv.business_id, 'manage_team') then
    raise exception 'Invitation not found.' using errcode = 'no_data_found';
  end if;
  update public.business_invitations set status = 'revoked', responded_at = now() where id = p_invitation;
  perform public.write_audit('business.invitation_revoked', 'business', inv.business_id::text, jsonb_build_object('email', inv.email));
end;
$$;

-- Invitations waiting for the signed-in person, matched on their confirmed email address.
create function public.my_invitations()
returns table (id uuid, business_id uuid, business_name text, role public.business_member_role, invited_by_name text, expires_at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select i.id, i.business_id, b.name, i.role, p.display_name, i.expires_at
    from public.business_invitations i
    join public.businesses b on b.id = i.business_id
    join public.profiles p on p.id = i.invited_by
    join auth.users u on u.id = (select auth.uid())
   where i.status = 'pending' and i.expires_at > now()
     and u.email_confirmed_at is not null
     and lower(u.email) = i.email
   order by i.created_at desc;
$$;

create function public.respond_invitation(p_invitation uuid, p_accept boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  inv public.business_invitations;
  uid uuid := (select auth.uid());
begin
  select i.* into inv
    from public.business_invitations i
    join auth.users u on u.id = uid
   where i.id = p_invitation and i.status = 'pending' and i.expires_at > now()
     and u.email_confirmed_at is not null and lower(u.email) = i.email
   for update of i;
  if not found then
    raise exception 'Invitation not found or expired.' using errcode = 'no_data_found';
  end if;

  if p_accept then
    if (select account_state from public.profiles where id = uid) = 'suspended' then
      raise exception 'This account cannot join a business right now.' using errcode = 'insufficient_privilege';
    end if;
    insert into public.business_members (business_id, user_id, role) values (inv.business_id, uid, inv.role)
    on conflict do nothing;
    update public.business_invitations set status = 'accepted', responded_at = now() where id = inv.id;
    perform public.write_audit('business.member_joined', 'business', inv.business_id::text, jsonb_build_object('role', inv.role));
  else
    update public.business_invitations set status = 'declined', responded_at = now() where id = inv.id;
  end if;
end;
$$;

create function public.set_member_role(p_business uuid, p_user uuid, p_role public.business_member_role)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.business_can(p_business, 'manage_team') then
    raise exception 'Only the owner can change roles.' using errcode = 'insufficient_privilege';
  end if;
  if p_role not in ('manager', 'staff') then
    raise exception 'Roles can be manager or staff.' using errcode = 'check_violation';
  end if;
  if p_user = (select auth.uid()) then
    raise exception 'You cannot change your own role.' using errcode = 'check_violation';
  end if;
  update public.business_members set role = p_role
   where business_id = p_business and user_id = p_user and role <> 'owner';
  if not found then
    raise exception 'Team member not found.' using errcode = 'no_data_found';
  end if;
  perform public.write_audit('business.role_changed', 'business', p_business::text, jsonb_build_object('user', p_user, 'role', p_role));
end;
$$;

-- The owner removes someone, or a non-owner leaves.
create function public.remove_member(p_business uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
begin
  if p_user <> uid and not public.business_can(p_business, 'manage_team') then
    raise exception 'Only the owner can remove people.' using errcode = 'insufficient_privilege';
  end if;
  delete from public.business_members where business_id = p_business and user_id = p_user and role <> 'owner';
  if not found then
    raise exception 'Team member not found, or this is the owner.' using errcode = 'no_data_found';
  end if;
  perform public.write_audit('business.member_removed', 'business', p_business::text,
    jsonb_build_object('user', p_user, 'left_by_choice', p_user = uid));
end;
$$;

create function public.business_team(p_business uuid)
returns table (user_id uuid, display_name text, role public.business_member_role, joined_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.business_can(p_business, 'view_team') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  return query
    select m.user_id, p.display_name, m.role, m.created_at
      from public.business_members m join public.profiles p on p.id = m.user_id
     where m.business_id = p_business
     order by (m.role = 'owner') desc, m.created_at;
end;
$$;

create function public.business_open_invitations(p_business uuid)
returns table (id uuid, email text, role public.business_member_role, created_at timestamptz, expires_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.business_can(p_business, 'manage_team') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  return query
    select i.id, i.email, i.role, i.created_at, i.expires_at
      from public.business_invitations i
     where i.business_id = p_business and i.status = 'pending' and i.expires_at > now()
     order by i.created_at desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Branches
-- ---------------------------------------------------------------------------

create table public.business_branches (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name text not null check (char_length(name) between 2 and 60),
  location_id integer references public.locations (id),
  address_text text check (char_length(address_text) <= 200),
  phone text check (phone ~ '^\+?[0-9 ]{7,15}$'),
  is_main boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (business_id, name)
);
create unique index business_one_main_branch on public.business_branches (business_id) where is_main;
create index business_branches_business_idx on public.business_branches (business_id);
alter table public.business_branches enable row level security;
grant select on public.business_branches to authenticated;
create policy branches_members_read on public.business_branches
  for select to authenticated using (public.is_business_member(business_id));

alter table public.listings add column branch_id uuid references public.business_branches (id) on delete set null;
alter table public.orders add column branch_id uuid references public.business_branches (id) on delete set null;
create index listings_branch_idx on public.listings (branch_id) where branch_id is not null;
create index orders_business_idx on public.orders (business_id, created_at desc) where business_id is not null;

grant insert (branch_id) on public.listings to authenticated;
grant update (branch_id) on public.listings to authenticated;

create function public.listings_branch_check()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.branch_id is not null and not exists (
    select 1 from public.business_branches b
     where b.id = new.branch_id and b.business_id = new.business_id and b.active
  ) then
    raise exception 'Choose one of your business''s active branches.' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger listings_branch_guard before insert or update of branch_id, business_id on public.listings
  for each row execute function public.listings_branch_check();

-- An order remembers which branch holds the item.
create function public.orders_copy_branch()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.branch_id := (select l.branch_id from public.listings l where l.id = new.listing_id);
  return new;
end;
$$;
create trigger orders_branch_copy before insert on public.orders
  for each row execute function public.orders_copy_branch();

create function public.create_branch(
  p_business uuid, p_name text, p_location_id integer default null,
  p_address text default null, p_phone text default null, p_is_main boolean default false
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  new_id uuid;
  nm text := btrim(coalesce(p_name, ''));
  first_branch boolean;
begin
  if not public.business_can(p_business, 'manage_branches') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if (select count(*) from public.business_branches where business_id = p_business) >= 20 then
    raise exception 'A business can have at most 20 branches.' using errcode = 'check_violation';
  end if;
  first_branch := not exists (select 1 from public.business_branches where business_id = p_business);
  if p_is_main or first_branch then
    update public.business_branches set is_main = false where business_id = p_business and is_main;
  end if;
  insert into public.business_branches (business_id, name, location_id, address_text, phone, is_main)
  values (p_business, nm, p_location_id, nullif(btrim(coalesce(p_address, '')), ''), nullif(btrim(coalesce(p_phone, '')), ''), p_is_main or first_branch)
  returning id into new_id;
  perform public.write_audit('business.branch_created', 'business', p_business::text, jsonb_build_object('branch', new_id, 'name', nm));
  return new_id;
exception
  when unique_violation then
    raise exception 'You already have a branch with that name.' using errcode = 'unique_violation';
end;
$$;

create function public.update_branch(
  p_branch uuid, p_name text, p_location_id integer, p_address text, p_phone text, p_active boolean, p_is_main boolean
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  b public.business_branches;
begin
  select * into b from public.business_branches where id = p_branch for update;
  if not found or not public.business_can(b.business_id, 'manage_branches') then
    raise exception 'Branch not found.' using errcode = 'no_data_found';
  end if;
  if b.is_main and not p_is_main then
    raise exception 'Make another branch the main one instead.' using errcode = 'check_violation';
  end if;
  if b.is_main and not p_active then
    raise exception 'The main branch cannot be switched off.' using errcode = 'check_violation';
  end if;
  if not p_active and exists (
    select 1 from public.listings l where l.branch_id = p_branch and l.status in ('active', 'draft')
  ) then
    raise exception 'Move this branch''s listings to another branch before switching it off.' using errcode = 'check_violation';
  end if;
  if p_is_main and not b.is_main then
    update public.business_branches set is_main = false where business_id = b.business_id and is_main;
  end if;
  update public.business_branches
     set name = btrim(p_name), location_id = p_location_id,
         address_text = nullif(btrim(coalesce(p_address, '')), ''), phone = nullif(btrim(coalesce(p_phone, '')), ''),
         active = p_active, is_main = p_is_main
   where id = p_branch;
  perform public.write_audit('business.branch_updated', 'business', b.business_id::text, jsonb_build_object('branch', p_branch, 'active', p_active));
exception
  when unique_violation then
    raise exception 'You already have a branch with that name.' using errcode = 'unique_violation';
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Catalogues
-- ---------------------------------------------------------------------------

create table public.business_catalogues (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name text not null check (char_length(name) between 2 and 60),
  description text check (char_length(description) <= 300),
  position integer not null default 0,
  is_visible boolean not null default true,
  created_at timestamptz not null default now(),
  unique (business_id, name)
);
create table public.catalogue_listings (
  catalogue_id uuid not null references public.business_catalogues (id) on delete cascade,
  listing_id uuid not null references public.listings (id) on delete cascade,
  position integer not null default 0,
  primary key (catalogue_id, listing_id)
);
create index catalogue_listings_listing_idx on public.catalogue_listings (listing_id);
alter table public.business_catalogues enable row level security;
alter table public.catalogue_listings enable row level security;
grant select on public.business_catalogues, public.catalogue_listings to authenticated;
create policy catalogues_members_read on public.business_catalogues
  for select to authenticated using (public.is_business_member(business_id));
create policy catalogue_listings_members_read on public.catalogue_listings
  for select to authenticated
  using (exists (select 1 from public.business_catalogues c where c.id = catalogue_id and public.is_business_member(c.business_id)));

create function public.create_catalogue(p_business uuid, p_name text, p_description text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  new_id uuid;
begin
  if not public.business_can(p_business, 'manage_catalogues') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if (select count(*) from public.business_catalogues where business_id = p_business) >= 30 then
    raise exception 'A business can have at most 30 catalogues.' using errcode = 'check_violation';
  end if;
  insert into public.business_catalogues (business_id, name, description, position)
  values (p_business, btrim(coalesce(p_name, '')), nullif(btrim(coalesce(p_description, '')), ''),
          coalesce((select max(position) + 1 from public.business_catalogues where business_id = p_business), 0))
  returning id into new_id;
  return new_id;
exception
  when unique_violation then
    raise exception 'You already have a catalogue with that name.' using errcode = 'unique_violation';
end;
$$;

create function public.update_catalogue(p_catalogue uuid, p_name text, p_description text, p_visible boolean, p_position integer)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  c public.business_catalogues;
begin
  select * into c from public.business_catalogues where id = p_catalogue;
  if not found or not public.business_can(c.business_id, 'manage_catalogues') then
    raise exception 'Catalogue not found.' using errcode = 'no_data_found';
  end if;
  update public.business_catalogues
     set name = btrim(p_name), description = nullif(btrim(coalesce(p_description, '')), ''),
         is_visible = p_visible, position = greatest(coalesce(p_position, 0), 0)
   where id = p_catalogue;
exception
  when unique_violation then
    raise exception 'You already have a catalogue with that name.' using errcode = 'unique_violation';
end;
$$;

create function public.delete_catalogue(p_catalogue uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  c public.business_catalogues;
begin
  select * into c from public.business_catalogues where id = p_catalogue;
  if not found or not public.business_can(c.business_id, 'manage_catalogues') then
    raise exception 'Catalogue not found.' using errcode = 'no_data_found';
  end if;
  delete from public.business_catalogues where id = p_catalogue;
end;
$$;

-- Replaces what is in a catalogue. Listings keep the order they are given in.
create function public.set_catalogue_listings(p_catalogue uuid, p_listing_ids uuid[])
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  c public.business_catalogues;
  ids uuid[] := coalesce(p_listing_ids, '{}');
begin
  select * into c from public.business_catalogues where id = p_catalogue for update;
  if not found or not public.business_can(c.business_id, 'manage_catalogues') then
    raise exception 'Catalogue not found.' using errcode = 'no_data_found';
  end if;
  if cardinality(ids) > 200 then
    raise exception 'A catalogue can hold at most 200 listings.' using errcode = 'check_violation';
  end if;
  if (select count(*) from public.listings l where l.id = any (ids) and l.business_id = c.business_id and l.status <> 'removed')
     <> (select count(distinct x) from unnest(ids) x) then
    raise exception 'Every listing must belong to this business.' using errcode = 'check_violation';
  end if;
  delete from public.catalogue_listings where catalogue_id = p_catalogue;
  insert into public.catalogue_listings (catalogue_id, listing_id, position)
  select p_catalogue, x.id, min(x.ord)::integer
    from unnest(ids) with ordinality as x(id, ord)
   group by x.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Public storefront
-- ---------------------------------------------------------------------------

create view public.public_businesses as
select
  b.id,
  b.name,
  b.slug,
  b.description,
  b.logo_path,
  loc.town,
  loc.area,
  b.address_text,
  (b.verification_status = 'verified') as verified,
  b.created_at,
  (select count(*) from public.listings l
    where l.business_id = b.id and l.status = 'active' and l.moderation_status = 'approved')::integer as listing_count
from public.businesses b
join public.profiles p on p.id = b.owner_id
left join public.locations loc on loc.id = b.location_id
where p.account_state <> 'suspended';

create view public.public_business_branches as
select br.id, br.business_id, br.name, loc.town, loc.area, br.address_text, br.phone, br.is_main
from public.business_branches br
join public.public_businesses pb on pb.id = br.business_id
left join public.locations loc on loc.id = br.location_id
where br.active;

create view public.public_business_catalogues as
select c.id, c.business_id, c.name, c.description, c.position,
  (select count(*) from public.catalogue_listings cl
     join public.listings l on l.id = cl.listing_id
    where cl.catalogue_id = c.id and l.status = 'active' and l.moderation_status = 'approved')::integer as listing_count
from public.business_catalogues c
join public.public_businesses pb on pb.id = c.business_id
where c.is_visible;

grant select on public.public_businesses, public.public_business_branches, public.public_business_catalogues to anon, authenticated;

create function public.business_storefront_listings(
  p_business uuid, p_catalogue uuid default null, p_term text default null, p_limit integer default 24, p_offset integer default 0
)
returns table (
  id uuid, title text, price_zmw numeric, condition public.item_condition, town text, area text,
  image_path text, branch_name text, created_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $$
declare
  lim integer := least(greatest(coalesce(p_limit, 24), 1), 60);
  off integer := greatest(coalesce(p_offset, 0), 0);
  term text := lower(btrim(coalesce(p_term, '')));
begin
  return query
    select pl.id, pl.title, pl.price_zmw, pl.condition, pl.town, pl.area, pl.image_path, br.name, pl.created_at
      from public.public_listings pl
      join public.listings l on l.id = pl.id
      join public.public_businesses pb on pb.id = l.business_id
      left join public.business_branches br on br.id = l.branch_id and br.active
     where l.business_id = p_business
       and (p_catalogue is null or exists (
             select 1 from public.catalogue_listings cl
               join public.business_catalogues c on c.id = cl.catalogue_id
              where cl.catalogue_id = p_catalogue and cl.listing_id = l.id and c.business_id = p_business and c.is_visible))
       and (term = '' or strpos(lower(pl.title), term) > 0)
     order by pl.created_at desc
     limit lim offset off;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Inventory
-- ---------------------------------------------------------------------------

create table public.listing_stock (
  listing_id uuid primary key references public.listings (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  quantity integer not null check (quantity between 0 and 100000),
  low_stock_at integer not null default 2 check (low_stock_at between 0 and 100000),
  auto_hidden boolean not null default false,
  updated_by uuid references public.profiles (id),
  updated_at timestamptz not null default now()
);
create index listing_stock_business_idx on public.listing_stock (business_id);

create table public.stock_movements (
  id bigint generated always as identity primary key,
  listing_id uuid not null references public.listings (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  change integer not null check (change <> 0),
  quantity_after integer not null check (quantity_after >= 0),
  reason text not null check (reason in ('initial', 'restock', 'correction', 'damaged', 'return', 'sale')),
  note text check (char_length(note) <= 200),
  order_id uuid references public.orders (id) on delete set null,
  actor_id uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
create index stock_movements_listing_idx on public.stock_movements (listing_id, id desc);
alter table public.listing_stock enable row level security;
alter table public.stock_movements enable row level security;
-- No grants: stock is read and changed only through the functions below.

-- Sold-out items are paused; a restock brings back only the ones this feature paused.
create function public.stock_apply_effects(p_listing uuid, p_quantity integer)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if p_quantity = 0 then
    update public.listings set status = 'unavailable'
     where id = p_listing and status = 'active'
       and not exists (select 1 from public.listing_reservations r where r.listing_id = p_listing);
    if found then
      update public.listing_stock set auto_hidden = true where listing_id = p_listing;
    end if;
  else
    update public.listings set status = 'active'
     where id = p_listing and status = 'unavailable' and moderation_status = 'approved'
       and exists (select 1 from public.listing_stock s where s.listing_id = p_listing and s.auto_hidden);
    update public.listing_stock set auto_hidden = false where listing_id = p_listing and auto_hidden;
  end if;
end;
$$;

-- Called when an order completes. Returns the stock left, or null if this listing is not tracked.
create function public.stock_record_sale(p_listing uuid, p_order uuid)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  s public.listing_stock;
  after_qty integer;
begin
  select * into s from public.listing_stock where listing_id = p_listing for update;
  if not found then
    return null;
  end if;
  after_qty := greatest(s.quantity - 1, 0);
  update public.listing_stock set quantity = after_qty, updated_at = now() where listing_id = p_listing;
  if after_qty <> s.quantity then
    insert into public.stock_movements (listing_id, business_id, change, quantity_after, reason, order_id, actor_id)
    values (p_listing, s.business_id, after_qty - s.quantity, after_qty, 'sale', p_order, (select auth.uid()));
  end if;
  return after_qty;
end;
$$;

-- Same as 0009, plus: a tracked listing loses one unit and is only closed when none are left.
create or replace function public.order_finish(p_order_id uuid, p_by text)
returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders;
  remaining integer;
begin
  update public.orders
     set status = 'completed', completed_at = coalesce(completed_at, now()), expires_at = null
   where id = p_order_id
   returning * into o;
  delete from public.listing_reservations where order_id = p_order_id;

  remaining := public.stock_record_sale(o.listing_id, o.id);
  if remaining is null then
    update public.listings set status = 'sold', sold_at = coalesce(sold_at, now())
     where id = o.listing_id and status <> 'sold';
  else
    perform public.stock_apply_effects(o.listing_id, remaining);
  end if;

  perform public.order_add_event(p_order_id, p_by,
    case when p_by = 'system' then 'auto_completed' when p_by = 'staff' then 'settled_by_staff' else 'completed' end,
    case when p_by = 'staff' then 'Settled as completed.' end);
  return o;
end;
$$;

create function public.track_stock(p_listing uuid, p_quantity integer, p_low_stock_at integer default 2)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  l public.listings;
begin
  select * into l from public.listings where id = p_listing for update;
  if not found or l.business_id is null or not public.business_can(l.business_id, 'manage_inventory') then
    raise exception 'Listing not found.' using errcode = 'no_data_found';
  end if;
  if l.status in ('removed', 'sold') then
    raise exception 'This listing is closed.' using errcode = 'check_violation';
  end if;
  if p_quantity is null or p_quantity < 0 or p_quantity > 100000 then
    raise exception 'Enter a stock quantity between 0 and 100000.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.listing_stock where listing_id = p_listing) then
    raise exception 'Stock is already tracked for this listing. Adjust it instead.' using errcode = 'unique_violation';
  end if;

  insert into public.listing_stock (listing_id, business_id, quantity, low_stock_at, updated_by)
  values (p_listing, l.business_id, p_quantity, greatest(coalesce(p_low_stock_at, 2), 0), (select auth.uid()));
  if p_quantity > 0 then
    insert into public.stock_movements (listing_id, business_id, change, quantity_after, reason, actor_id)
    values (p_listing, l.business_id, p_quantity, p_quantity, 'initial', (select auth.uid()));
  end if;
  perform public.stock_apply_effects(p_listing, p_quantity);
end;
$$;

create function public.adjust_stock(p_listing uuid, p_change integer, p_reason text, p_note text default null)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  s public.listing_stock;
  after_qty integer;
begin
  -- Lock the listing before its stock, the same order the order functions use, so the two cannot deadlock.
  perform 1 from public.listings where id = p_listing for update;
  select * into s from public.listing_stock where listing_id = p_listing for update;
  if not found or not public.business_can(s.business_id, 'manage_inventory') then
    raise exception 'Stock is not tracked for this listing.' using errcode = 'no_data_found';
  end if;
  if p_reason not in ('restock', 'correction', 'damaged', 'return') then
    raise exception 'Reason must be restock, correction, damaged or return.' using errcode = 'invalid_parameter_value';
  end if;
  if p_change is null or p_change = 0 then
    raise exception 'The change cannot be zero.' using errcode = 'check_violation';
  end if;
  if p_reason in ('restock', 'return') and p_change < 0 then
    raise exception 'A % adds stock.', p_reason using errcode = 'check_violation';
  end if;
  if p_reason = 'damaged' and p_change > 0 then
    raise exception 'Damaged stock is taken off.' using errcode = 'check_violation';
  end if;
  after_qty := s.quantity + p_change;
  if after_qty < 0 then
    raise exception 'There are only % in stock.', s.quantity using errcode = 'check_violation';
  end if;
  if after_qty > 100000 then
    raise exception 'That is more than the limit of 100000.' using errcode = 'check_violation';
  end if;

  update public.listing_stock set quantity = after_qty, updated_by = (select auth.uid()), updated_at = now()
   where listing_id = p_listing;
  insert into public.stock_movements (listing_id, business_id, change, quantity_after, reason, note, actor_id)
  values (p_listing, s.business_id, p_change, after_qty, p_reason, left(nullif(btrim(coalesce(p_note, '')), ''), 200), (select auth.uid()));
  perform public.stock_apply_effects(p_listing, after_qty);
  return after_qty;
end;
$$;

create function public.set_low_stock_level(p_listing uuid, p_level integer)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  b uuid;
begin
  select business_id into b from public.listing_stock where listing_id = p_listing;
  if b is null or not public.business_can(b, 'manage_inventory') then
    raise exception 'Stock is not tracked for this listing.' using errcode = 'no_data_found';
  end if;
  if p_level is null or p_level < 0 or p_level > 100000 then
    raise exception 'Enter a level between 0 and 100000.' using errcode = 'check_violation';
  end if;
  update public.listing_stock set low_stock_at = p_level where listing_id = p_listing;
end;
$$;

create function public.business_inventory(
  p_business uuid, p_filter text default 'all', p_limit integer default 50, p_offset integer default 0
)
returns table (
  listing_id uuid, title text, status public.listing_status, branch_id uuid, branch_name text,
  tracked boolean, quantity integer, low_stock_at integer, is_low boolean, updated_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $$
declare
  lim integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  off integer := greatest(coalesce(p_offset, 0), 0);
begin
  if not public.business_can(p_business, 'manage_inventory') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  if p_filter not in ('all', 'tracked', 'untracked', 'low', 'out') then
    raise exception 'Filter must be all, tracked, untracked, low or out.' using errcode = 'invalid_parameter_value';
  end if;

  return query
    select l.id, l.title, l.status, l.branch_id, br.name, (s.listing_id is not null), s.quantity, s.low_stock_at,
           (s.listing_id is not null and s.quantity <= s.low_stock_at), s.updated_at
      from public.listings l
      left join public.listing_stock s on s.listing_id = l.id
      left join public.business_branches br on br.id = l.branch_id
     where l.business_id = p_business and l.status <> 'removed'
       and (p_filter = 'all'
            or (p_filter = 'tracked' and s.listing_id is not null)
            or (p_filter = 'untracked' and s.listing_id is null)
            or (p_filter = 'low' and s.listing_id is not null and s.quantity <= s.low_stock_at)
            or (p_filter = 'out' and s.listing_id is not null and s.quantity = 0))
     order by (s.listing_id is not null and s.quantity <= s.low_stock_at) desc, l.title
     limit lim offset off;
end;
$$;

create function public.stock_history(p_listing uuid, p_limit integer default 30)
returns table (id bigint, change integer, quantity_after integer, reason text, note text, actor_name text, created_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
declare
  b uuid;
begin
  select business_id into b from public.listing_stock where listing_id = p_listing;
  if b is null or not public.business_can(b, 'manage_inventory') then
    raise exception 'Stock is not tracked for this listing.' using errcode = 'no_data_found';
  end if;
  return query
    select m.id, m.change, m.quantity_after, m.reason, m.note, p.display_name, m.created_at
      from public.stock_movements m left join public.profiles p on p.id = m.actor_id
     where m.listing_id = p_listing
     order by m.id desc
     limit least(greatest(coalesce(p_limit, 30), 1), 100);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Business orders and analytics
-- ---------------------------------------------------------------------------

create function public.business_orders(
  p_business uuid, p_status public.order_status default null, p_branch uuid default null,
  p_limit integer default 30, p_offset integer default 0
)
returns table (
  id uuid, listing_id uuid, item_title text, item_price_zmw numeric, status public.order_status,
  fulfilment public.fulfilment_method, buyer_name text, delivery_address text,
  branch_id uuid, branch_name text, created_at timestamptz, expires_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.business_can(p_business, 'manage_orders') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  return query
    select o.id, o.listing_id, o.item_title, o.item_price_zmw, o.status, o.fulfilment, o.buyer_name, o.delivery_address,
           o.branch_id, br.name, o.created_at, o.expires_at
      from public.orders o
      left join public.business_branches br on br.id = o.branch_id
     where o.business_id = p_business
       and (p_status is null or o.status = p_status)
       and (p_branch is null or o.branch_id = p_branch)
     order by (o.status = 'requested') desc, o.created_at desc
     limit least(greatest(coalesce(p_limit, 30), 1), 100) offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

-- Figures here come from orders ZedMarket recorded. ZedMarket does not handle payment,
-- so "completed value" is the listed price of completed orders, not money received.
create function public.business_analytics(p_business uuid, p_days integer default 30)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  days integer := least(greatest(coalesce(p_days, 30), 1), 365);
  since timestamptz;
  result jsonb;
begin
  if not public.business_can(p_business, 'view_analytics') then
    raise exception 'Not allowed.' using errcode = 'insufficient_privilege';
  end if;
  since := now() - make_interval(days => days);

  select jsonb_build_object(
    'period_days', days,
    'orders_received', (select count(*) from public.orders o where o.business_id = p_business and o.created_at >= since),
    'orders_by_status', (
      select coalesce(jsonb_object_agg(x.status, x.n), '{}'::jsonb)
        from (select o.status::text as status, count(*) as n from public.orders o
               where o.business_id = p_business and o.created_at >= since group by o.status) x),
    'orders_open_now', (select count(*) from public.orders o where o.business_id = p_business and o.status in ('requested', 'confirmed', 'disputed')),
    'completed_orders', (select count(*) from public.orders o where o.business_id = p_business and o.status = 'completed' and o.completed_at >= since),
    'completed_value_zmw', (select coalesce(sum(o.item_price_zmw), 0) from public.orders o where o.business_id = p_business and o.status = 'completed' and o.completed_at >= since),
    'listing_views', (select count(*) from public.listing_views v join public.listings l on l.id = v.listing_id
                       where l.business_id = p_business and v.viewed_at >= since),
    'saves_total', (select count(*) from public.favourites f join public.listings l on l.id = f.listing_id where l.business_id = p_business),
    'active_listings', (select count(*) from public.listings l where l.business_id = p_business and l.status = 'active'),
    'low_stock', (select count(*) from public.listing_stock s where s.business_id = p_business and s.quantity > 0 and s.quantity <= s.low_stock_at),
    'out_of_stock', (select count(*) from public.listing_stock s where s.business_id = p_business and s.quantity = 0),
    'top_listings', (
      select coalesce(jsonb_agg(to_jsonb(t) order by t.completed desc, t.views desc, t.title), '[]'::jsonb)
        from (
          select l.id, l.title,
                 (select count(*) from public.orders o where o.listing_id = l.id and o.status = 'completed' and o.completed_at >= since) as completed,
                 (select count(*) from public.listing_views v where v.listing_id = l.id and v.viewed_at >= since) as views,
                 (select count(*) from public.favourites f where f.listing_id = l.id) as saves
            from public.listings l
           where l.business_id = p_business and l.status <> 'removed'
           order by 3 desc, 4 desc, l.title
           limit 5) t),
    'by_branch', (
      select coalesce(jsonb_agg(to_jsonb(x) order by x.orders desc, x.branch), '[]'::jsonb)
        from (
          select coalesce(br.name, 'No branch') as branch, count(*) as orders,
                 coalesce(sum(o.item_price_zmw) filter (where o.status = 'completed'), 0) as completed_value_zmw
            from public.orders o left join public.business_branches br on br.id = o.branch_id
           where o.business_id = p_business and o.created_at >= since
           group by br.id, br.name) x)
  ) into result;
  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissions: closed first, then opened on purpose
-- ---------------------------------------------------------------------------

revoke execute on function
  public.business_can(uuid, text),
  public.invite_member(uuid, text, public.business_member_role),
  public.revoke_invitation(uuid),
  public.my_invitations(),
  public.respond_invitation(uuid, boolean),
  public.set_member_role(uuid, uuid, public.business_member_role),
  public.remove_member(uuid, uuid),
  public.business_team(uuid),
  public.business_open_invitations(uuid),
  public.listings_branch_check(),
  public.orders_copy_branch(),
  public.create_branch(uuid, text, integer, text, text, boolean),
  public.update_branch(uuid, text, integer, text, text, boolean, boolean),
  public.create_catalogue(uuid, text, text),
  public.update_catalogue(uuid, text, text, boolean, integer),
  public.delete_catalogue(uuid),
  public.set_catalogue_listings(uuid, uuid[]),
  public.business_storefront_listings(uuid, uuid, text, integer, integer),
  public.stock_apply_effects(uuid, integer),
  public.stock_record_sale(uuid, uuid),
  public.track_stock(uuid, integer, integer),
  public.adjust_stock(uuid, integer, text, text),
  public.set_low_stock_level(uuid, integer),
  public.business_inventory(uuid, text, integer, integer),
  public.stock_history(uuid, integer),
  public.business_orders(uuid, public.order_status, uuid, integer, integer),
  public.business_analytics(uuid, integer)
from public, anon, authenticated;

grant execute on function
  public.business_can(uuid, text),
  public.invite_member(uuid, text, public.business_member_role),
  public.revoke_invitation(uuid),
  public.my_invitations(),
  public.respond_invitation(uuid, boolean),
  public.set_member_role(uuid, uuid, public.business_member_role),
  public.remove_member(uuid, uuid),
  public.business_team(uuid),
  public.business_open_invitations(uuid),
  public.create_branch(uuid, text, integer, text, text, boolean),
  public.update_branch(uuid, text, integer, text, text, boolean, boolean),
  public.create_catalogue(uuid, text, text),
  public.update_catalogue(uuid, text, text, boolean, integer),
  public.delete_catalogue(uuid),
  public.set_catalogue_listings(uuid, uuid[]),
  public.track_stock(uuid, integer, integer),
  public.adjust_stock(uuid, integer, text, text),
  public.set_low_stock_level(uuid, integer),
  public.business_inventory(uuid, text, integer, integer),
  public.stock_history(uuid, integer),
  public.business_orders(uuid, public.order_status, uuid, integer, integer),
  public.business_analytics(uuid, integer)
to authenticated;

-- The storefront is public, so signed-out visitors may call this one too.
grant execute on function public.business_storefront_listings(uuid, uuid, text, integer, integer) to anon, authenticated;
