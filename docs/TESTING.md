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
| `trust_flows.sql` | Identity checks (submit, review, rejection note, level change, double review); business verification; reports (who sees them, who resolves them, audit trail); disputes (who can open, evidence access, who resolves); appeals; reviews (only after completion, one per order, hiding); risk flags; staff roles |

Each rule in `marketplace.sql` was also tried against a deliberately broken copy of the migration (twelve breaks, such as showing unapproved listings, letting anyone feature a listing, or not escaping `%`), and every break made the tests fail.

Every check that expects an error calls the database function with an explicit id, so it cannot pass just because a policy hid the row and nothing ran. The checks were also tried against deliberately broken copies of the rules (a policy opened to everyone, a role check removed), and each one failed as it should.

## What is not tested yet

- Screens and user journeys, including everything in Module A's screens (guest browsing, home rails, filters, sharing, alerts, seller page). Those files typecheck and the plain logic behind them has unit tests (`routes`, `share`, `describeSearch`), but they have not been opened on a phone or in a browser. In the sandbox the web build stopped at one missing package (`@expo/vector-icons`), so a full app build has not been confirmed either. There are no end-to-end tests on the app itself. A good next step is to run the web build (`npm run build:web`) in a browser test tool against a staging project.
- Real sign-up, email confirmation and password recovery, which need a real Supabase project (the local server has only a stand-in for sign-in).
- Storage policies on real uploads, and realtime chat delivery.
- Anything involving SMS, push notifications, payments or delivery providers, which do not exist yet.
- Speed with large amounts of data.

## Notes from the first full run

- The first run of `rls_policies.sql` failed with `permission denied for table listings`. The cause was in the test: it chose a listing `id` itself, but users are (correctly) only allowed to supply the listing's content columns. The test now posts listings the way the app does, and adds checks that a user cannot choose the id or post as someone else. No migration was changed.
- All eight migrations apply cleanly on PostgreSQL 16.
- Writing the Module A tests found two real bugs in the first draft of migration 0008: search and the featured list read tables that guests are not allowed to read, so they failed for guests. Both functions now run with the owner's rights and return only the public columns. The new functions were also executable by everyone by default; the migration now revokes that and grants only what is meant.
- Every relationship name used by the app's list queries (for example `reviews_reviewer_id_fkey`) exists in the schema.
