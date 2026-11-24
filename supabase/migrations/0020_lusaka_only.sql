-- Decision: ZedMarket launches with Lusaka only. 0019 added the main towns of the other provinces;
-- this removes the ones nobody has used yet, so pickers show Lusaka only. Other provinces come back
-- when the business expands (staff add them with admin_add_location).
-- A place that is already used by a listing, address, delivery area, order, branch or saved search is kept,
-- because deleting it would break that record. Safe to run twice.
do $$
declare
  r record;
begin
  for r in select id from public.locations where province <> 'Lusaka' loop
    begin
      delete from public.locations where id = r.id;
    exception when foreign_key_violation then
      null;
    end;
  end loop;
end;
$$;
