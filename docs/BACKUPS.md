# Backups and restoring

ZedMarket keeps everything that matters in one Supabase project: the database (accounts, listings, orders, chats) and the file storage (photos and verification documents). If that project is lost or damaged, so is the marketplace. This page is the plan. Nothing here has been tried on the real project yet; **do a practice restore before you have real users.**

## 1. What to switch on (Supabase dashboard)

1. **Database backups.** Project Settings, Database, Backups. On the free plan there are no downloadable daily backups. A paid plan keeps daily backups for a few days (check the current number on Supabase's pricing page, because it changes). Point-in-time recovery is an add-on on paid plans.
2. **Your own copy, every week.** Until you pay for backups, take a copy yourself. On a computer with the Supabase CLI: `supabase db dump --db-url "<connection string>" -f zedmarket-backup.sql`. The connection string is in Project Settings, Database. Keep the file somewhere private that is not the same account as Supabase (an encrypted drive or a private cloud folder). It contains personal details, so treat it like the live data.
3. **Photos and documents.** Storage files are not in the database dump. Download the `listing-images` bucket now and then. Do not store the `identity-documents` bucket outside Supabase unless you have to; those files are deleted on a schedule for a reason.
4. **The migrations are already a backup of the structure.** Every file in `supabase/migrations/` can rebuild the empty database in order. Keep the repository safe too.

## 2. How to restore (practice this once)

1. Create a **new, empty** Supabase project. Never practise on the live one.
2. In its SQL editor, run every file in `supabase/migrations/` in number order.
3. Load the data from your dump into it (`psql "<new connection string>" -f zedmarket-backup.sql` for a data-only dump, or restore from the dashboard if you use paid backups).
4. Upload the saved photos back into the `listing-images` bucket.
5. Open the app with the new project's URL and anon key in `EXPO_PUBLIC_SUPABASE_URL` and `EXPO_PUBLIC_SUPABASE_ANON_KEY`, sign in, and check that listings, a chat and an order look right.
6. Write down how long it took and what went wrong. That is your real recovery time.

## 3. If something is deleted by mistake

- Stop making changes first, so the damage does not grow.
- With paid backups or point-in-time recovery: restore to just before the mistake into a **new** project, then copy back only what you need.
- Without them: use your latest weekly dump the same way, and accept that anything newer is lost.

## 4. Keep in mind

- A backup you have never restored is a hope, not a backup.
- Anyone who can read a backup can read personal data. Keep it private and delete old copies.
- Accounts deleted by their owners (Account, Security and login, Delete account) come back if you restore an older backup. If you ever restore, check the audit log for `account.deleted` entries made after the backup date and delete those accounts again.
