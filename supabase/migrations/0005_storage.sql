-- ZedMarket database, part 5: storage buckets and their access rules.
--
-- Product photos and avatars are public to read. Identity documents, business
-- documents and dispute evidence are private and only reachable through signed
-- URLs. Every upload goes into a folder named after the uploader's user id.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('listing-images',      'listing-images',      true,  5242880, array['image/jpeg', 'image/png', 'image/webp']),
  ('avatars',             'avatars',             true,  2097152, array['image/jpeg', 'image/png', 'image/webp']),
  ('identity-documents',  'identity-documents',  false, 8388608, array['image/jpeg', 'image/png', 'application/pdf']),
  ('business-documents',  'business-documents',  false, 8388608, array['image/jpeg', 'image/png', 'application/pdf']),
  ('dispute-evidence',    'dispute-evidence',    false, 8388608, array['image/jpeg', 'image/png', 'application/pdf'])
on conflict (id) do nothing;

-- Public buckets: anyone signed in can upload to their own folder and manage their own files.
create policy "public buckets: upload to own folder" on storage.objects
  for insert to authenticated
  with check (
    bucket_id in ('listing-images', 'avatars')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "public buckets: replace own files" on storage.objects
  for update to authenticated
  using (
    bucket_id in ('listing-images', 'avatars')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "public buckets: delete own files" on storage.objects
  for delete to authenticated
  using (
    bucket_id in ('listing-images', 'avatars')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- Private buckets: the owner can upload and read their own files. Support staff
-- can read identity and business documents for review. Nobody can overwrite or
-- delete through the API; removal is done by the retention job.
create policy "private buckets: upload to own folder" on storage.objects
  for insert to authenticated
  with check (
    bucket_id in ('identity-documents', 'business-documents', 'dispute-evidence')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "private buckets: read own files" on storage.objects
  for select to authenticated
  using (
    bucket_id in ('identity-documents', 'business-documents', 'dispute-evidence')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "private buckets: support can read for review" on storage.objects
  for select to authenticated
  using (
    bucket_id in ('identity-documents', 'business-documents', 'dispute-evidence')
    and public.has_staff_role('support')
  );
