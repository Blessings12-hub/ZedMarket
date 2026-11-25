# Change report: seller tools (Part A, chunk 2, module 3)

Migration `0022_seller_tools.sql`. Built on top of chunk 1 (bulk import, migration 0021). Works for a person selling alone and for a business member.

## What a seller gets
- **One tracker** (`/seller/listings`, and `?business=<id>` for a business): status, review state, rejection reason, photos, stock and SKU, 30-day views, saves and orders. Filters: all, live, in review, not approved, drafts, paused, sold. Search by title or SKU.
- **Status history** per listing (`listing_status_events`): every change of status or review state with the moderator's reason, kept permanently, nobody can edit or delete it. Existing listings got one starting row.
- **Duplicate** a listing: a new draft with the same details. Photos and stock are not copied. A business can give the copy its own SKU and quantity.
- **Bulk prices**: set, change by percent, or add/take off an amount for up to 200 listings. All or nothing. Preview shown first.
- **Bulk stock**: set or adjust many tracked listings. All or nothing. Uses the existing `adjust_stock`, so movements, sold-out pausing and restocking work as before.
- **Photo order**: choose the cover and the order (the 10-photo limit already existed).
- **Performance** for one listing reuses `listing_performance` from the analytics migration (owner or manager for a business).

## Moderation is not bypassed
Copies are drafts. A price change is an ordinary listing update, so the listing rules run again; tested: a new seller's big price jump goes back to review.

## Safety
Row level security with no grants on the history table; every function checks on the server that the caller sells the listing (own listing, or business role); suspended or restricted accounts cannot use the write tools; per-person rate limit (30 bulk updates an hour) and a per-call cap (200); every bulk change and copy is audited with before and after values.

## Known limits
- Copies count toward the existing 20-listings-a-day limit.
- Removing the last photo of a live listing is still allowed by the older photo rules (not changed here).
- Imported or copied drafts must get photos in the existing posting flow before they can be published.
- Screens were type-checked, not run on a device. Nothing was run on a real Supabase project.

## Verified
All 22 migrations from scratch; all SQL test files including `supabase/tests/seller_tools.sql` (closed tables, permissions per role, filters, history, copy, bulk prices and stock including all-or-nothing, moderation, closed listings, caps, suspended accounts, rate limit, photo order); two deliberate breakages (permission helper always true, history made editable) make the tests fail. 128 app tests pass; `tsc` shows only the known `@expo/vector-icons` error.
