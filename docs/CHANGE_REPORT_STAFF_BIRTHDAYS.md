# Change report: Staff Birthdays (Phase 11, birthday half of Phases 12 and 13)

Scope: **staff birthdays only.** Staff Voting was delivered earlier and is already on `main`. The Account Hub, business, moderation and
advertising modules in the same specification are not part of this change.

Built on top of `main` as of the analytics merge. The birthday migration is therefore **0017** (0016 is analytics).

## Files added
- `supabase/migrations/0017_staff_birthdays.sql`
- `supabase/tests/staff_birthdays.sql`
- `mobile/src/domain/birthdays.ts`, `mobile/src/domain/birthdays.test.ts`
- `mobile/src/features/birthdays/api.ts`, `mobile/src/features/birthdays/Avatar.tsx`
- `mobile/app/admin/birthdays/index.tsx` (today, coming up, month calendar), `[id].tsx` (message board), `mine.tsx` (my birthday and settings), `reports.tsx` (moderator queue)
- `docs/CHANGE_REPORT_STAFF_BIRTHDAYS.md`

## Files modified
- `mobile/app/admin/index.tsx`: one new "Staff birthdays" section with one button.
- `mobile/app/_layout.tsx`: four screen titles.
- `mobile/src/domain/notifications.ts` and `.test.ts`: a `staff` category (mutable), and a notification may open one exact birthday board (`/admin/birthdays/<id>`). Every other `/admin/...` link is still refused; tests pin that.
- `supabase/tests/local/concurrency.sh`: scenarios 10 and 11 added (1 to 9 untouched).
- `docs/SCHEDULED_JOBS.md`: the two new jobs and the settings.

## Existing functions reused
`is_staff`, `has_staff_role`, `notify` (so dedupe, preferences and the push queue apply), `write_audit`, `enforce_rate_limit`,
`setting_numeric`, `platform_settings`, `admin_roles`, `profiles` (display name and the existing public avatar), `set_notification_preference`,
the `zm_test` pattern, `friendlyError`, `fetchMyRoles`, `canModerate`/`canManageTeam`, and the `Button`/`Chip`/`Field`/`Notice` components.

## Database changes (migration 0017)
New tables, all with row level security on and **no grants for app users**: `staff_birthday_profiles`, `staff_birthday_events`,
`staff_birthday_notification_logs`, `staff_birthday_messages`, `staff_birthday_reports`, `staff_birthday_access_logs`. Nine settings rows.

**Existing objects touched (widened only, nothing removed or tightened):** the category CHECK on `notifications` and on
`notification_preferences` now also allows `staff`; `my_notification_settings()` and `set_notification_preference()` were re-created
with the same behaviour plus the `staff` category, which only people holding a staff role can see or set. The existing notification test
(six categories for an ordinary user) still passes unchanged.

Functions for signed-in staff (two-factor and staff role checked inside): `my_birthday_profile`, `set_my_birthday`, `clear_my_birthday`,
`staff_birthdays_today`, `staff_birthdays_upcoming`, `staff_birthdays_month`, `birthday_event`, `birthday_messages`, `send_birthday_message`,
`my_birthday_events`, `report_birthday_message`. Moderator or technical admin: `birthday_reports_queue`, `resolve_birthday_report`.
Technical admin: `staff_birthday_access_log`. Job only (`service_role`): `run_staff_birthdays`, `purge_old_birthday_access_logs`.

## How the requirements are met
| Requirement | How |
|---|---|
| Do not expose the birth year or full date | **Never stored.** Only month and day exist; a test asserts no column anywhere is year- or DOB-shaped. The audit log records visibility, never the date |
| Staff-only, not on marketplace profiles | Tables closed to app users; every read needs two-factor and a staff role; nothing touches public profile views |
| Visibility preference | `staff` or `hidden`. Hidden: not in anyone else's calendar, no colleague notice, others cannot open or write on the board. The person still sees their own and gets a greeting |
| Validate dates | Database CHECK (month 1-12, day within the month, 29 Feb allowed) plus function checks plus the app form |
| Correct date and organisation timezone | `org.timezone` setting (default Africa/Lusaka, unknown names fall back to it). Tested at 23:30 and 00:30 either side of midnight, and in Auckland |
| One notice per birthday event | Unique event per (person, date), unique log row per (event, kind, recipient), and `notify()`'s own dedupe key: three layers. A muted notice is logged as not sent and is not resent later |
| Multiple birthdays the same day | Each gets its own event, greeting and notices (tested with three) |
| Greeting, colleague notice, link to board | `birthday.greeting` and `birthday.today`, both linking to `/admin/birthdays/<event>` |
| Message fields, chronological order, history kept | sender, recipient, body, created time, event reference. Ordered by a real clock timestamp. Messages cannot be edited or deleted, even by a database administrator |
| Prevent impersonation | The sender is read from the signed-in session inside the function; no direct inserts exist |
| Notify the birthday person | One notice per wish, naming the sender. **It never contains the wish text** |
| Reporting and moderation | Any viewer can report; moderators and technical admins hide or dismiss with a mandatory reason, audited. Hiding removes the text from the board but the record keeps it. A moderator cannot decide a report about their own message or one they filed |
| Access logs | Calendar and board reads are logged (technical admins can read, 90-day retention) |
| Deactivated staff | Someone who loses their staff role or whose account is not active gets no celebration, is not listed, and receives no notices |

## Decisions I made that you should check
1. **29 February** is celebrated on 28 February in non-leap years.
2. **A birthday saved today does not notify anyone today.** It starts next time the date comes round. Otherwise anyone could ping every colleague on demand.
3. **Wishes** are allowed from the day itself for 3 days, up to 3 wishes per person per board. You cannot write on your own board. Starter values in `platform_settings`.
4. **Photograph:** the app shows the person's existing public avatar (or initials), with a "show my photo" switch. **There is no avatar upload screen in the app**, so this module cannot add photos. The notification table has no image column, so the photograph appears on the board and calendar, not inside the notice itself.
5. **Notices use a new, mutable `staff` category**, unlike the voting notices, which use the unmutable `account` category. A person who mutes it still gets the calendar and board, but no in-app or push notice for birthdays or wishes.
6. **Edit and removal:** staff can change or remove their own birthday; old boards are kept.
7. **Event dates:** an event is created by the job. If the job does not run on a given day, that day's greeting and notices are not sent later (the job only looks at "today").

## Tests performed (real PostgreSQL 16)
- All earlier migrations and test files, including analytics: pass unchanged.
- `staff_birthdays.sql`: privacy (no year column, no grants, RLS), date validation, access (non-staff, no two-factor, guests), audit contents, the job on the right date and in other timezones, an unknown timezone, once-only sending across re-runs and the same local day, muted notices, three birthdays on one day, 29 February in leap and non-leap years, hidden visibility, suspended and departed staff, calendar and upcoming window, board reading and writing, caps, closed window, history, impersonation attempts, edit and delete attempts, reports and moderation (including conflicts of interest), access log and purge, notification category visibility, function and table permissions.
- Mutation check: I deliberately broke the migration six ways. Four were caught immediately. Two were not caught because the mutation was equivalent to the original or hit a deliberate second layer of protection (the notification table's own dedupe). One real weakness in my own test (a closed wish window masking the visibility rule) was found this way and fixed.
- `concurrency.sh`, 11 scenarios: four job runs at once leave exactly 9 events, 9 greetings, 72 notices and no duplicates; five wishes from one person at once leave exactly 3, with no deadlocks.
- App: 86 unit tests pass (8 new in `birthdays.test.ts`, plus new link and category cases). `tsc` reports one error, the missing `@expo/vector-icons` in `app/(tabs)/_layout.tsx`, which is in `main` already.

## Not done / not tested
- **Not run on a real Supabase project, a phone, Android or iOS.** The screens are type-checked but never rendered.
- **The job is not scheduled.** Until `run_staff_birthdays()` is, no greeting or colleague notice is sent. See `docs/SCHEDULED_JOBS.md`.
- Push delivery depends on the existing, also unscheduled, notification worker.
- No avatar upload, no pagination on boards (fine at staff scale), no way for the birthday person to hide a message themselves (they can report it).
- The "Staff" filter chip on the notifications screen is visible to everyone; it simply shows nothing for non-staff.

## Noticed in `main`, outside this change
- `staff-voting.patch` sits at the repository root (an upload by mistake); it can be deleted.
- `.env` and `mobile/node_modules` are tracked in git despite `.gitignore`.
