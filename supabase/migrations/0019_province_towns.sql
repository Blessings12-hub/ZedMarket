-- Adds the main town of each province so people outside Lusaka can pick a place.
-- Names only: no coordinates are set (staff can add them with admin_set_location_coordinates),
-- and no neighbourhoods are listed, because those need local checking before they are published.
-- Safe to run twice.
insert into public.locations (province, district, town, area) values
  ('Copperbelt', 'Ndola', 'Ndola', null),
  ('Copperbelt', 'Kitwe', 'Kitwe', null),
  ('Copperbelt', 'Chingola', 'Chingola', null),
  ('Copperbelt', 'Mufulira', 'Mufulira', null),
  ('Copperbelt', 'Luanshya', 'Luanshya', null),
  ('Central', 'Kabwe', 'Kabwe', null),
  ('Eastern', 'Chipata', 'Chipata', null),
  ('Luapula', 'Mansa', 'Mansa', null),
  ('Muchinga', 'Chinsali', 'Chinsali', null),
  ('Northern', 'Kasama', 'Kasama', null),
  ('North-Western', 'Solwezi', 'Solwezi', null),
  ('Southern', 'Choma', 'Choma', null),
  ('Southern', 'Livingstone', 'Livingstone', null),
  ('Western', 'Mongu', 'Mongu', null)
on conflict (province, town, area) do nothing;
