# Change report: Staff Voting (Phase 10, voting half of Phases 12 and 13)

Scope of this change: **voting only**. Birthdays (Phase 11) are the next change. The Account Hub, business and
moderation modules in the same specification are not part of this change.

## Files added
- `supabase/migrations/0015_staff_voting.sql`
- `supabase/tests/staff_voting.sql`
- `mobile/src/domain/voting.ts`, `mobile/src/domain/voting.test.ts`
- `mobile/src/features/voting/api.ts`
- `mobile/app/admin/votes/index.tsx` (dashboard), `[id].tsx` (proposal), `new.tsx`, `history.tsx`
- `docs/CHANGE_REPORT_STAFF_VOTING.md`

## Files modified
- `mobile/app/admin/index.tsx`: one new "Staff voting" section with one button. Every other section is untouched.
- `mobile/app/_layout.tsx`: four new screen titles. Nothing removed.
- `mobile/src/domain/notifications.ts` and `.test.ts`: a notification may now open one exact staff screen, a single vote (`/admin/votes/<id>`). Every other `/admin/...` link is still refused, and a test pins that.
- `supabase/tests/local/concurrency.sh`: scenarios 8 and 9 added. Scenarios 1 to 7 untouched.
- `docs/SCHEDULED_JOBS.md`: the new job and settings.

## Existing functions reused
`has_staff_role`, `is_staff` (two-factor plus role), `notify` (so deduplication, preferences and push queue all apply), `write_audit`,
`enforce_rate_limit`, `setting_numeric`, `platform_settings`, `admin_roles`, `profiles`, the `zm_test` test pattern, `friendlyError`,
the `Button`/`Chip`/`Field`/`Notice` components, and the existing staff-tools two-factor gate.

## Database changes (migration 0015, additive only)
Tables, all with row level security on and **no grants for app users**: `staff_proposals`, `staff_vote_eligibility`,
`staff_votes`, `staff_vote_results`, `staff_vote_audit_logs`. One sequence for references (`SV-2026-0001`).
No existing table, policy or function was changed. Six new settings rows.

Functions callable by signed-in staff (each checks two-factor and role inside): `create_staff_proposal`, `update_staff_proposal`,
`submit_staff_proposal`, `cancel_staff_proposal`, `resubmit_staff_proposal`, `cast_staff_vote`, `list_staff_proposals`,
`get_staff_proposal`, `my_staff_votes`, `my_staff_vote_access`, and (technical admin only) `staff_vote_ballots`, `staff_vote_audit`,
`verify_staff_vote_audit`. `staff_vote_tick` is for the scheduled job only (`service_role`).

## The rules and where they are enforced
| Rule | Enforced by |
|---|---|
| required = ceiling(eligible x 2 / 3) | `sv_required`, plus a CHECK on both the proposal and the result |
| Approve only if FOR reaches it, reject only if AGAINST reaches it, else unresolved | `sv_settle`, plus a CHECK tying the outcome to the counts |
| No manual result | Final statuses need a matching result row (trigger); a result must equal the stored ballots (trigger); results, votes, eligibility and audit rows cannot be updated, deleted or truncated (triggers); no app grants |
| One vote each, no changes | Primary key (proposal, voter), row lock, and a "cannot change" refusal |
| Frozen eligibility | Snapshot rows written when the vote opens; later role or account changes do not touch them |
| Transactional | The proposal row is locked; vote, count, result, status, audit and notices happen in one transaction |
| Immutable audit | Per-proposal hash chain with a unique (proposal, seq); `verify_staff_vote_audit` detects edits. It never records a choice |

## Decisions I made that you should check
1. **Early close.** A vote closes the moment FOR or AGAINST reaches two thirds, because later votes cannot change it. Otherwise it closes at the deadline.
2. **Someone who leaves mid-vote** keeps any vote already cast, stays in the denominator, and cannot cast a new one (they lose staff access). A person suspended after the vote opens is treated the same.
3. **Who may propose:** every staff role, rate limited to 10 a day. Change `staff_vote.proposer_roles` to restrict it.
4. **Minimum 3 eligible staff**, voting period 24 hours to 14 days. Starter values, in `platform_settings`.
5. **Stopping a live vote** needs a technical admin who is not the proposer, with a reason. A proposer can cancel only their own draft or scheduled vote.
6. **Individual votes:** technical admin only, only after close, never for a confidential proposal, and every read is audited. Ordinary staff see counts and their own vote. Confidential proposals hide running counts until close.
7. **Notifications use the existing `account` category,** which cannot be muted. I did not alter the existing category constraint. The birthday work will need a mutable category, so I will decide that there.
8. **"Cannot override legal, security or emergency duties":** the proposer must confirm it (stored, required), and the UI says so. Structurally, a vote result is only a record: nothing in the system reads it to change a setting, role or listing. The confirmation is an attestation, not something software can verify.

## Tests performed (on a real PostgreSQL 16 server)
- Every existing migration and every existing database test file: pass, unchanged.
- `staff_voting.sql`: threshold maths (1, 3, 4, 9, 10, 11 eligible); exactly two thirds approves; exactly two thirds rejects; 5 of 9 either way is unresolved; one third; abstentions; non-participation; duplicate and changed votes; direct writes refused; even a database administrator cannot edit votes, results or audit rows or set a result by hand; expiry; scheduled opening; frozen eligibility (joiner, leaver, suspended); cancellation rules; resubmission once only; non-staff, no-two-factor and guest access; configurable proposer roles; confidential secrecy; ballot access; audit chain verified, and tampering detected; one notice per person per event; job re-run sends nothing twice; function and table permissions; minimum-staff rule.
- `concurrency.sh`: all 9 scenarios, 5 rounds each, no deadlocks and no unexpected errors. New: the same person voting twice at once leaves exactly one row; the deciding votes from both sides arriving at once leave exactly one result that matches the ballots.
- App: 69 unit tests pass (59 existing, 10 new in `voting.test.ts`, plus new notification link cases). `tsc` reports one error in `app/(tabs)/_layout.tsx` (`@expo/vector-icons` missing from the installed packages). It is in the untouched baseline too.

## Not done / not tested
- **Not run on a real Supabase project, a phone, Android or iOS.** The screens have been type-checked but never rendered. Please open each one.
- **No Edit-draft screen.** The database function exists (`update_staff_proposal`) and is tested; the app has no button for it yet. A draft can be opened, cancelled, or left.
- **No scheduled-start picker.** The app always opens a vote immediately. Scheduling works in the database and is tested.
- **The job is not scheduled** (see `docs/SCHEDULED_JOBS.md`).
- Push delivery of the notices depends on the existing, also unscheduled, notification worker.
- The 1,000-product import, moderation, advertising, the Account Hub and every other module in the same document are **not started**.

## Things I noticed that are outside this change
- `.env` is tracked in git although `.gitignore` lists it. Check whether it holds real keys; if it does, rotate them.
- `mobile/node_modules` (27,000 files) and `mobile/dist` are tracked in git despite `.gitignore`. That bloats every clone.
