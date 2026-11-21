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
| `trust_flows.sql` | Identity checks (submit, review, rejection note, level change, double review); business verification; reports (who sees them, who resolves them, audit trail); disputes (who can open, evidence access, who resolves); appeals; reviews (only after completion, one per order, hiding); risk flags; staff roles |

Every check that expects an error calls the database function with an explicit id, so it cannot pass just because a policy hid the row and nothing ran. The checks were also tried against deliberately broken copies of the rules (a policy opened to everyone, a role check removed), and each one failed as it should.

## What is not tested yet

- Screens and user journeys. There are no end-to-end tests on the app itself. A good next step is to run the web build (`npm run build:web`) in a browser test tool against a staging project.
- Real sign-up, email confirmation and password recovery, which need a real Supabase project (the local server has only a stand-in for sign-in).
- Storage policies on real uploads, and realtime chat delivery.
- Anything involving SMS, push notifications, payments or delivery providers, which do not exist yet.
- Speed with large amounts of data.

## Notes from the first full run

- The first run of `rls_policies.sql` failed with `permission denied for table listings`. The cause was in the test: it chose a listing `id` itself, but users are (correctly) only allowed to supply the listing's content columns. The test now posts listings the way the app does, and adds checks that a user cannot choose the id or post as someone else. No migration was changed.
- All seven migrations apply cleanly on PostgreSQL 16.
- Every relationship name used by the app's list queries (for example `reviews_reviewer_id_fkey`) exists in the schema.
