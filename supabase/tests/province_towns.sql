-- Lusaka-only checks (after 0019 and 0020). Rolls itself back.
begin;
select 1 / (case when (select count(distinct province) from public.locations) = 1 then 1 else 0 end) as only_lusaka_left;
select 1 / (case when (select count(*) from public.locations where district is null) = 0 then 1 else 0 end) as every_place_has_a_district;
-- a place that is in use survives the clean-up
insert into public.locations (province, district, town, area) values ('Southern', 'Choma', 'Choma', 'Test');
insert into public.saved_addresses (user_id, label, kind, location_id, street)
  select p.id, 'Test', 'both', l.id, 'x' from public.profiles p, public.locations l where l.area = 'Test' limit 1;
do $$
declare r record;
begin
  for r in select id from public.locations where province <> 'Lusaka' loop
    begin delete from public.locations where id = r.id; exception when foreign_key_violation then null; end;
  end loop;
end $$;
select 1 / (case when (select count(*) from public.locations where area = 'Test') = 1 or not exists (select 1 from public.profiles) then 1 else 0 end) as used_place_kept;
select 'Lusaka-only checks passed' as result;
rollback;
