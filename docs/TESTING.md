# Testing

## What runs automatically

`.github/workflows/ci.yml` runs on every push and pull request:

1. **Database job**: starts a clean PostgreSQL 16 server, applies every file in `supabase/migrations` in order, then runs every file in `supabase/tests`.
2. **App job**: installs the app, runs `npm run typecheck` (the whole app, every screen) and `npm test` (the plain logic in `mobile/src/domain`).

## Running the database tests yourself

On any computer with PostgreSQL 15 or 16 installed, using a throwaway server (never a real project):

```
DATABASE_URL=postgres://postgres@localhost:5432/postgres supabase/tests/local/run.sh
```

The script creates a fresh database, loads `supabase/tests/local/supabase_shim.sql` (small stand-ins for the Supabase roles, `auth` and `storage` schemas), applies the migrations, runs the tests, and drops the database.

To run on a real Supabase staging project instead, run each migration, then each file in `supabase/tests` in the SQL editor. Each test file runs in one transaction and rolls itself back.

## What the database tests cover

| File | Covers |
|---|---|
| `rls_policies.sql` | Row level security is on for every table; draft listings hidden; sellers cannot change protected profile columns; publishing needs a photo; automatic moderation; orders and who may move them; outsiders cannot read orders or messages; staff actions need the right role and two-factor |
| `marketplace.sql` | Module A: what guests can and cannot read (no base tables, no private columns, no drafts, unapproved or suspended sellers); search and every filter, wildcard characters treated as plain text, limits clamped; nearby, similar; featured (moderator with two-factor only, expiry, audit); view history and trending (one view per hour, own and hidden listings ignored, private history, old views stop counting); recommendations; the retention job (service role only); saved searches (limit of 10, private) and alerts (only when a listing becomes visible, matching filters only, no duplicates, none for your own listing) |
| `orders.sql` | Module B: placing orders (every refusal); stock control (one reservation per item, others turned away, reserved items hidden, database-level backstops); **108 combinations** of person, step and order state, each either allowed or refused for the right kind of reason; delivery address and fee; expiry (job, stale reservation, late confirmation); automatic completion; items stopping being for sale; event history and who can read it; receipts (who, when, unchanged by later edits, says no payment was handled); disputes and staff settlement; the rate limit; business orders; older app calls |
| `user_trust.sql` | User & Trust Management: guests, ordinary users and support without two-factor are refused; queues for pending, verified and rejected applications (people and businesses; oldest first, search, page size capped); moderators read but cannot open documents or decide; every document opening is audited; rejection needs a reason; nobody can review their own application; user lists (verified, suspended, restricted) with reasons; profiles; verification history with reviewers; audit trail (support and moderators see only this section's actions, technical admins see all); functions closed to signed-out callers |
| `business_hub.sql` | Module C: the permission table (owner, manager, staff, outsider, suspended member, unknown permission); invitations (only the owner invites, bad and duplicate emails, wrong person, unconfirmed email, expiry, revoke, decline, accept once); role changes, removal and leaving; direct member inserts closed; branches (one main, cannot switch off main or a branch with active listings, other businesses' branches refused, orders remember the branch); catalogues; the public storefront (guests, hidden catalogues, unapproved listings, suspended owners, `%` as plain text, page cap); stock (tracking, every refused adjustment, pausing at zero and restocking, hand-paused listings left alone, completed orders take one unit, history); business order list; analytics (window, roles, branch split); function permissions |
| `notifications.sql` | Module E: the right people are notified for order events, messages (no text, blocked senders skipped, push batched), alerts, verification, account state, moderation, invitations and low stock; repeated events make one notification; link rules; reading, unread counts and marking read only for yourself; preferences (defaults, account notices fixed, muted categories, email and SMS gated by settings and confirmed contacts); push tokens (limits, moving, unregistering only your own); the delivery queue (lease, back-off, dead, success, no retry and token disabling, lease expiry, skipped reads and moved tokens); function permissions; purge |
| `trust_flows.sql` | Identity checks (submit, review, rejection note, level change, double review); business verification; reports (who sees them, who resolves them, audit trail); disputes (who can open, evidence access, who resolves); appeals; reviews (only after completion, one per order, hiding); risk flags; staff roles |

`business_hub.sql` was tried against 29 deliberately broken copies of migration 0011 (a manager who can manage the team, a suspended member who keeps access, an expired invitation that can be accepted, a hidden catalogue shown publicly, a sale that does not reduce stock, and so on). 24 were caught straight away. Five slipped through at first: three were real gaps in my tests (accepting an expired invitation with a confirmed email, the storefront page cap, the analytics time window), and tests were added so those are now caught. The other two (changing your own role, and negative stock) are protected twice, by a function check and by a table rule, so removing one layer changes nothing visible.

`notifications.sql` was tried against 31 deliberately broken copies of migration 0012. All but three are caught. The three that are not (account notices becoming mutable, the actor being told about their own action, the claim ignoring the attempts limit) are each protected twice, by a table rule or another check, so removing one layer changes nothing visible. One survivor at first (automatic approval of a published listing sending a "your listing was approved" notice) was a gap in my test, which put the listing in the wrong starting state; it is now caught.

`user_trust.sql` was tried against 12 deliberately broken copies of migration 0010 (for example allowing self-review, skipping the audit entry on documents, letting moderators open documents, not capping page size, opening the functions to signed-out callers). Two survived the first version of the tests, so tests were added; now every break is caught.

Each rule in `marketplace.sql` was also tried against a deliberately broken copy of the migration (twelve breaks, such as showing unapproved listings, letting anyone feature a listing, or not escaping `%`), and every break made the tests fail.

Every check that expects an error calls the database function with an explicit id, so it cannot pass just because a policy hid the row and nothing ran. The checks were also tried against deliberately broken copies of the rules (a policy opened to everyone, a role check removed), and each one failed as it should.

## Race tests

`supabase/tests/local/concurrency.sh` is for what one transaction cannot show: people acting at the same moment. It creates its own scratch database, opens many real connections, holds them at a starting line, releases them together and checks the order rules afterwards. Five scenarios, ten items each: two confirmations of one item, two buyers asking at once, cancel against confirm, mark sold against confirm, a new request against a confirmation. It also fails on any deadlock or raw database error, because a clean refusal is the only acceptable way to lose a race. It runs in CI after the other tests and takes about 35 seconds.

I broke the locking on purpose (no locks, no locks and no primary key, no lock when asking, others not turned away) and each break made it fail. One rule, "a seller cannot mark an item sold while it has a confirmed order", is not an invariant the race test checks (if it were missing, the order would be cancelled instead). That rule is covered by `orders.sql`.

`orders.sql` was tried against 25 deliberately broken copies of the migration. Five survived at first; three of those turned out to be protected twice (a function check and a table rule), and each was caught once both layers were removed. The other two had only broken the first of two identical checks.

## What is not tested yet

- Screens and user journeys, including everything in the Module A and B screens (guest browsing, home rails, filters, sharing, alerts, seller page, checkout, order detail, receipt). Those files typecheck and the plain logic behind them has unit tests (`routes`, `share`, `describeSearch`, `orders`), but they have not been opened on a phone or in a browser. In the sandbox the web build stopped at one missing package (`@expo/vector-icons`), so a full app build has not been confirmed either. There are no end-to-end tests on the app itself. A good next step is to run the web build (`npm run build:web`) in a browser test tool against a staging project.
- Real sign-up, email confirmation and password recovery, which need a real Supabase project (the local server has only a stand-in for sign-in).
- Storage policies on real uploads, and realtime chat delivery.
- Anything involving SMS, push notifications, payments or delivery providers, which do not exist yet.
- Speed with large amounts of data.

## Notes from the first full run

- The first run of `rls_policies.sql` failed with `permission denied for table listings`. The cause was in the test: it chose a listing `id` itself, but users are (correctly) only allowed to supply the listing's content columns. The test now posts listings the way the app does, and adds checks that a user cannot choose the id or post as someone else. No migration was changed.
- All nine migrations apply cleanly on PostgreSQL 16.
- Writing the Module A tests found two real bugs in the first draft of migration 0008: search and the featured list read tables that guests are not allowed to read, so they failed for guests. Both functions now run with the owner's rights and return only the public columns. The new functions were also executable by everyone by default; the migration now revokes that and grants only what is meant.
- Every relationship name used by the app's list queries (for example `reviews_reviewer_id_fkey`) exists in the schema.
