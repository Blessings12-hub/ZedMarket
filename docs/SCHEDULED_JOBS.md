# Scheduled jobs

Some work has to happen on a timer. These are written as database functions that only trusted server code can call. **None of them is scheduled yet**, so until you do it the work below does not happen by itself.

| Function | What it does | How often |
|---|---|---|
| `run_order_maintenance()` | Closes unanswered requests and uncollected confirmed orders, and completes orders the buyer did not answer after hand-over | Every 10 minutes |
| `purge_old_listing_views()` | Deletes browsing history older than 90 days | Once a day |

The app stays correct without the first one, because a stale reservation is released when the next buyer asks, but requests would stay open past their deadline, and orders would not complete by themselves, until the job runs.

## Setting them up on Supabase with pg_cron

I have not been able to try this on a real Supabase project. The statements below are the standard pg_cron form; check them against the current Supabase documentation before relying on them.

1. In the Supabase dashboard, open Database, then Extensions, and enable `pg_cron`.
2. In the SQL editor:

```sql
select cron.schedule('zedmarket-orders', '*/10 * * * *', $$select public.run_order_maintenance()$$);
select cron.schedule('zedmarket-views', '17 3 * * *', $$select public.purge_old_listing_views()$$);
```

3. Check later with `select * from cron.job_run_details order by start_time desc limit 10;`.

To stop one: `select cron.unschedule('zedmarket-orders');`.

## Settings you can change

In the `platform_settings` table: `order.request_expiry_hours` (48), `order.confirmed_expiry_days` (7), `order.auto_complete_days` (3), `rate_limit.order.max` (10) and `rate_limit.order.window_minutes` (60). All are starting values that need a decision, not final choices.
