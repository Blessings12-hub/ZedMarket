-- New staff role: Media. This is its own migration because a new enum value cannot be used in the same transaction that
-- adds it. Everything that uses the role is in 0034_media_department.sql.
alter type public.admin_role add value if not exists 'media';
