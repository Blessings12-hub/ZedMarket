# Change report: business verification (chunk B)

**Status: built and tested locally (whole SQL suite on PostgreSQL 16, 229 app logic tests, typecheck). Not tested on a real Supabase project or a phone. Not complete until staging and device tests are done.**

## What changed
- `0027_business_verification.sql`: `businesses.publish_state` and `registration_kind`; `business_can_publish()`; applications with a private table (TPIN, representative ID), directors and beneficial owners, branches, permits and officer checks; owner-only applicant functions; support functions (claim, request info, interview, check, escalate, decide, suspend, reinstate); audited private read; publishing gate extended to business listings; sensitive-change guard on verified businesses; `public_businesses` shows the registered/informal kind; `business_close` also schedules document purge. Existing verified businesses are carried over as active.
- The old `business_verifications` table and `review_business_verification` are kept but no longer decide publishing.
- App: `/verify/business` (create profile, then full application), `/trust/business-applications` and `/trust/business-application/[id]` (support), Account Hub and storefront wording. Informal traders are never labelled as registered. A profile alone never verifies.
- Required fields are marked with a red star and a legend on the seller and business forms.

## Lessons from the seller fixes, applied here
`mine()` always returns every part; withdrawn is not a rejection for the waiting period; readable validation errors with safe casts; the app never turns an error into an empty success; single-flight loads, a dirty flag, retry states; app limits mirror database limits.

## Not done yet
Dashboard workloads (C), comparison and duplicate images (D), quantity reservations (E), delivery/payments (F), scheduled jobs and `admin_approvals` wiring (G), final docs and end-to-end tests (H). Scanner, purge worker, the Edge Function and agreement legal text are outstanding. Cart error not reproduced: need the exact message.
