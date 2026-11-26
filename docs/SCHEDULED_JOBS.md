# Scheduled jobs

Some work has to happen on a timer. These are written as database functions that only trusted server code can call. **None of them is scheduled yet**, so until you do it the work below does not happen by itself.

| Function | What it does | How often |
|---|---|---|
| `run_order_maintenance()` | Closes unanswered requests and uncollected confirmed orders, and completes orders the buyer did not answer after hand-over | Every 10 minutes |
| `purge_old_listing_views()` | Deletes browsing history older than 90 days | Once a day |
| Edge Function `send-notifications` | Sends queued push notifications and reports each result back for retry | Every minute |
| `expire_stale_payments()` | Closes payments still waiting after 30 minutes as failed | Every minute |
| `close_resolved_tickets()` | Closes support tickets that were resolved more than 7 days ago | Once an hour |
| `purge_old_notifications()` | Deletes old read notifications and very old unread ones | Once a day |
| `staff_vote_tick()` | Opens staff votes whose start time has come and closes votes whose deadline has passed (migration 0015) | Every 5 minutes |
| `run_staff_birthdays()` | Creates today's staff birthday events (organisation timezone) and sends the greeting and the colleague notices, once each (migration 0017) | Every 15 minutes |
| `purge_old_birthday_access_logs()` | Deletes birthday calendar and board access logs older than 90 days | Once a day |

The app stays correct without the first one, because a stale reservation is released when the next buyer asks, but requests would stay open past their deadline, and orders would not complete by themselves, until the job runs.

## Setting them up on Supabase with pg_cron

I have not been able to try this on a real Supabase project. The statements below are the standard pg_cron form; check them against the current Supabase documentation before relying on them.

1. In the Supabase dashboard, open Database, then Extensions, and enable `pg_cron`.
2. In the SQL editor:

```sql
select cron.schedule('zedmarket-orders', '*/10 * * * *', $$select public.run_order_maintenance()$$);
select cron.schedule('zedmarket-views', '17 3 * * *', $$select public.purge_old_listing_views()$$);
```

3. Notifications: deploy `supabase/functions/send-notifications` (`supabase functions deploy send-notifications`), set a secret `WORKER_SECRET`, then call it every minute with the header `x-worker-secret`. That needs `pg_net` plus pg_cron, or any outside scheduler that can send an HTTP request. I have not tried either. The purge is called like the others: `select cron.schedule('zedmarket-notes', '23 3 * * *', $$select public.purge_old_notifications()$$);` only works if the function is callable by the job's role; check, because it is granted to `service_role` only.
4. Check later with `select * from cron.job_run_details order by start_time desc limit 10;`.

Staff voting: `select cron.schedule('zedmarket-votes', '*/5 * * * *', $$select public.staff_vote_tick()$$);`. Without it the app stays correct, because every list, detail view, vote and cancel first moves any due vote forward, but a vote nobody opens would stay open past its deadline and its closing notice would wait until someone does. It is granted to `service_role` only. Untested on a real Supabase project.

Staff birthdays: `select cron.schedule('zedmarket-birthdays', '*/15 * * * *', $$select public.run_staff_birthdays()$$);` and `select cron.schedule('zedmarket-birthday-logs', '29 3 * * *', $$select public.purge_old_birthday_access_logs()$$);`. Running the first one often is safe: a second run, or two at once, sends nothing twice. Every 15 minutes means greetings go out within 15 minutes after midnight in the organisation timezone. **If it is never scheduled, no birthday greeting or notice is ever sent** (the calendar and message boards still work). Both are granted to `service_role` only. Untested on a real Supabase project.

Bulk product import: `select cron.schedule('zedmarket-imports', '* * * * *', $$select public.import_process_jobs()$$);`. Each run adds up to `import.batch_rows` (100) products from the oldest queued import, so a 1000-row file takes about ten minutes. Two runs at once cannot create a product twice. **If it is never scheduled, imports stay at "Waiting to start" for ever** (nothing is lost; they start as soon as the job runs). Granted to `service_role` only. Untested on a real Supabase project.

To stop one: `select cron.unschedule('zedmarket-orders');`.

## Settings you can change

In the `platform_settings` table: `payments.enabled` (0 = off), `payments.expiry_minutes` (30), `rate_limit.payment.max` (5), `order.request_expiry_hours` (48), `order.confirmed_expiry_days` (7), `order.auto_complete_days` (3), `rate_limit.order.max` (10) and `rate_limit.order.window_minutes` (60). Staff voting: `staff_vote.min_eligible` (3), `staff_vote.min_hours` (24), `staff_vote.max_hours` (336), `staff_vote.proposer_roles` (all four staff roles) and `rate_limit.staff_proposal.max` (10 a day). Staff birthdays: `org.timezone` ("Africa/Lusaka"; any name from `pg_timezone_names`, an unknown name falls back to Lusaka), `staff_birthday.message_days` (3), `staff_birthday.max_messages_per_sender` (3), `rate_limit.birthday_profile.max` (5 a day), `rate_limit.birthday_message.max` (30 an hour) and `rate_limit.birthday_report.max` (10 an hour). Bulk import: `import.max_rows_per_file` (1000), `import.max_rows_per_business_day` (3000), `import.batch_rows` (100), `rate_limit.product_import.max` (10 files a day). All are starting values that need a decision, not final choices.

## Verification documents: retention and scanning (migrations 0023 and 0024)

Nothing runs these yet; they need a worker you provide (an Edge Function or script using the service role key):

- **Scan**: for each `verification_documents` row with `scan_status = 'pending'`, scan the stored file and call `verification_record_scan(document, 'clean' | 'infected' | 'failed')`. A file that is not `clean` can never be accepted or opened by staff. **A malware scanner is an external dependency and has not been chosen or connected.**
- **Purge**: call `verification_documents_due(100)`, delete each returned `bucket`/`path` from storage, then call `verification_mark_deleted(array of ids)`. Dates come from `retention.verification_rejected_days` (30) and `retention.verification_approved_days` (365). Both functions are `service_role` only.
- Application deadlines: `verification.info_request_days` (14). Escalation deadlines and overdue alerts arrive with the dashboard chunk.

## Business application documents
Closing a business (`business_close`) schedules its application documents for purge with the same retention worker as seller documents. The worker, and the malware scanner that moves documents from `pending` to `clean`, are still not built: until the scanner exists no business document can be opened by staff, so no business can be approved in production.
