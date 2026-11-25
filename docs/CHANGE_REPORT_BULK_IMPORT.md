# Change report: bulk product import and finance jobs (Part A, chunk 1)

Migration `0021_bulk_import.sql`. Covers Module 2 (bulk import) and the import side of Module 1 (business inventory), plus written, enforced finance jobs.

## What it does
1. A business owner, manager or staff member (needs `manage_listings` and `manage_inventory`) pastes a CSV, or cells copied from Excel, into **Business tools > Import products**.
2. The server checks every row and stores the result per row: SKU (required, unique in the file and in the business), title, price, quantity, category, condition, lengths, and blocked words. Flagged words and categories that need review show as warnings.
3. In the preview the seller fixes rows one at a time (each fix is re-checked) or sends the file as it is. Rows with errors are skipped, never added.
4. Sending queues the job. A background job (`import_process_jobs`, every minute) creates the products, 100 rows per run. Each row has its own sub-transaction, so one bad row fails alone and is recorded with a reason.
5. The seller is notified when the job ends. Failed and skipped rows can be sent again as a new linked job (once per job). Every job stays in the history.

## Decisions
- **No `business_inventory` table.** That name is already a function over `listing_stock` and `stock_movements`. Imported stock goes into `listing_stock` (new `sku` column, unique per business, case-insensitive) with an `initial` stock movement.
- **Imports never publish and never touch moderation.** Products are created as ordinary listing drafts through the normal trigger, so blocked terms, review categories and the high-value rule still apply. The seller adds photos and publishes; publishing goes through the usual path.
- Images are not part of the import file (they need uploads). They are added after import.
- The app reads the pasted text itself. No file-picker package was added because installs were not possible here; a file picker can be added later without changing the database.

## Safety
RLS on both tables with no grants; every function checks the business role on the server; limits per file, per business per day, and per person per day; every created, queued, cancelled, resubmitted and finished job is in the audit log; the background job is service-role only.

## Finance jobs
`ROLE_JOBS` in `mobile/src/domain/admin.ts` lists, per role, what is enforced today (finance: reconcile payments with a written check, request refunds, decide refunds that someone else requested, record payouts, read payments, refunds and summaries) and what is not built yet (advertising payments, arriving with the advertising chunk). Shown at **Staff tools > What finance is responsible for** (`/admin/jobs`). The Staff tools home was reorganised in the same change: the `/console` shell was removed and `/admin` now groups tools into Moderation, People and support, Finance, Platform and Our team, with a one-line description per row (`staffMenu.ts`, tested).

## Verified
All 21 migrations from scratch; every SQL test file, including the new `supabase/tests/bulk_import.sql` (permissions, validation, corrections, queueing, stale SKU failing alone, drafts only, moderation, no double creation, resubmit, history, limits, closed tables); breaking the permission check or the job makes the tests fail. 127 app tests pass; `tsc` shows only the known `@expo/vector-icons` error.

## Not verified
Two background runs at the same moment (protected by `FOR UPDATE SKIP LOCKED`, but not race-tested like the votes); the screens were not run on a device; nothing was run on a real Supabase project.
