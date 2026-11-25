# Change report: individual seller onboarding (chunk A of the Account Hub / verification spec)

**Status: built and tested locally. Not tested on a real Supabase project or a phone. Not complete until staging and device tests are done.**

## What changed
- `0023_seller_onboarding.sql`: `profiles.seller_status`, `seller_can_publish()`, seller agreement (v1 is DRAFT text for legal review), applications with a private table for ID number and address, generic verification documents, requests, interviews, immutable history; applicant and support functions; publishing gate (listings policy and trigger); carry-over of existing sellers.
- `0024_verification_storage_lockdown.sql`: support can no longer read new application documents straight from storage.
- `supabase/functions/verification-document-url`: the only way staff open those documents (audited, two-factor, scan clean, link lasts a minute). Untested.
- App: `/verify/seller` (applicant), `/trust/seller-applications` and `/trust/seller-application/[id]` (support), Account Hub shows selling tools only when approved, applicants see their state, suspended sellers see history only. Bottom navigation was already Home, Messages, Cart, Orders, Account.
- Housekeeping: `.env` untracked, stray files and the old console removed, private seller screens moved to `/selling/...`.

## Security
Closed tables with no grants; permission checks inside the database; no self-review anywhere; high risk needs an interview plus two different officers; every private read audited; no sensitive details in notices; documents never public.

## Not done yet
Business application (chunk B), dashboard workloads and deadlines (C), comparison and duplicate images (D), quantity reservations (E), delivery/payments (F), scheduled jobs and `admin_approvals` wiring (G), full docs and end-to-end tests (H). Scanner, purge worker and agreement legal text are outstanding.

## Delete on main
Files listed in `DELETE_ON_MAIN.txt` in the bundle (zip cannot carry deletions).
