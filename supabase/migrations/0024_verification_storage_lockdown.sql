-- Verification documents uploaded through the seller/business application flow (folder <user>/seller/... and
-- <user>/business/...) can only be opened through the verification-document-url Edge Function. That function asks the
-- database first (support role, two-factor, scan clean, audit row written) and only then signs a link that lasts a minute.
-- Support therefore loses direct storage read for those folders. Older flows (dispute evidence, the earlier identity
-- check) keep working exactly as before.
drop policy if exists "private buckets: support can read for review" on storage.objects;

create policy "private buckets: support can read for review" on storage.objects
  for select to authenticated
  using (
    bucket_id in ('identity-documents', 'business-documents', 'dispute-evidence')
    and public.has_staff_role('support')
    and coalesce((storage.foldername(name))[2], '') not in ('seller', 'business')
  );
