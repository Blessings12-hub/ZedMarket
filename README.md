# ZedMarket

Buy. Sell. Deliver. A marketplace for Zambia, starting in Lusaka.

This repo is the working build of the plan in `ZedMarket_Business_Blueprint.pdf`. The blueprint says to build the marketplace first, then delivery, then business tools, so the code follows that order.

`docs/BLUEPRINT_TRACKER.md` lists every item in the blueprint and says whether it is built, only in the database, planned, or waiting on a decision.

## Honest status

Release 1 (the marketplace) is written. Release 2 and 3 exist only as database tables with security rules.

**Nothing here has been run end to end.** The SQL has not been executed on a real database, and the app has not been opened on a phone. Only the plain TypeScript in `mobile/src/domain` has been type-checked and tested. Expect to fix errors on first run. Do the first run in a test Supabase project, not with real users.

## Layout

```
supabase/
  migrations/   run in order, 0001 to 0007
  tests/        rls_policies.sql, a security test that rolls itself back
mobile/
  app/          screens (Expo Router)
  src/          domain logic, Supabase calls, shared components
docs/
  BLUEPRINT_TRACKER.md
```

## Setup

1. Create a project at supabase.com (a free project is fine for testing).
2. In the SQL editor, run each file in `supabase/migrations/` in order: 0001, 0002, 0003, 0004, 0005, 0006, 0007. If one fails, stop and fix it before running the next.
3. Run `supabase/tests/rls_policies.sql` the same way. It should finish without errors and undo itself. If it errors, a security rule is wrong; do not ship until it passes.
4. In Authentication settings, keep email sign-in on and turn on leaked-password protection and rate limits if your plan offers them.
5. In `mobile/`, copy `.env.example` to `.env` and fill in the project URL and the anon (public) key. Never put the service-role key in this file.
6. From `mobile/`:
   ```
   npm install
   npx expo install --fix
   npx expo start
   ```
   `expo install --fix` is needed because the package versions in `package.json` were not checked against the current Expo release.
7. Unit tests for the plain logic: `npm test` in `mobile/`.

## First admin

Staff accounts need an entry in `admin_roles`, and admin actions require two-factor sign-in. Sign up normally in the app, enrol two-factor on that account, then in the SQL editor:

```sql
insert into public.admin_roles (user_id, role)
values ('<the user id from Authentication > Users>', 'tech_admin');
```

This is the only time you write to that table by hand. After that, roles are granted through the audited functions.

## Putting the web version on Vercel

```
cd mobile
npx expo export --platform web
```

Deploy the `dist` folder as a static site and add the two `EXPO_PUBLIC_` variables in the Vercel project settings. The phone app is the main target; the web build is a convenience and has had less attention.

## Things only the business can decide

Listed in full in the tracker. The main ones: the real prohibited-goods list, the numbers in `platform_settings` (price threshold for review, rate limits, how long data is kept), the legal documents, an SMS provider for phone checks, and approval from Yango before any delivery integration. The starter values in `0006_reference_data.sql` are placeholders.

## Rules this code follows

- No customer money is held. Payments are records of what an approved provider confirms.
- Drivers' details and live location come only from a provider, are shown only while a delivery is active, and are deleted on a schedule.
- No ETA is shown unless a source supplied it, and it is labelled an estimate.
- Secrets stay on the server. The app only has the public anon key.
