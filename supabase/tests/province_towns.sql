-- Province towns checks. Rolls itself back.
begin;
select 1 / (case when (select count(distinct province) from public.locations) = 10 then 1 else 0 end) as all_ten_provinces;
select 1 / (case when (select count(*) from public.locations where district is null) = 0 then 1 else 0 end) as every_place_has_a_district;
select 1 / (case when (select count(*) from public.locations where latitude is not null and town <> 'Lusaka' and area is not null) = 0 then 1 else 0 end) as no_invented_coordinates;
select 1 / (case when (select count(*) from public.locations where town = 'Livingstone' and province = 'Southern') = 1 then 1 else 0 end) as livingstone_once;
select 'Province towns checks passed' as result;
rollback;
