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

To stop one: `select cron.unschedule('zedmarket-orders');`.

## Settings you can change

In the `platform_settings` table: `payments.enabled` (0 = off), `payments.expiry_minutes` (30), `rate_limit.payment.max` (5), `order.request_expiry_hours` (48), `order.confirmed_expiry_days` (7), `order.auto_complete_days` (3), `rate_limit.order.max` (10) and `rate_limit.order.window_minutes` (60). Staff voting: `staff_vote.min_eligible` (3), `staff_vote.min_hours` (24), `staff_vote.max_hours` (336), `staff_vote.proposer_roles` (all four staff roles) and `rate_limit.staff_proposal.max` (10 a day). All are starting values that need a decision, not final choices.
