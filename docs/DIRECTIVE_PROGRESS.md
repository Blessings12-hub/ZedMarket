# Progress against the development directive

Status words used here: **Done** means built and tested through the whole user journey. **Built, partly tested** means the code exists and some of it is tested, but not the whole journey. **Not started** means nothing exists. Nothing is marked Done until it has been tested end to end on a real Supabase project and a real device.

| Item | Status |
|---|---|
| 1. Stabilise existing work | Built, partly tested. Migrations and database security tests run in GitHub Actions and locally. Not yet tested: real sign-up and recovery, uploads, chat delivery, screen journeys. |
| A. Advanced marketplace | Built, partly tested. See below. |
| B. Order management | Built, partly tested. See below. |
| C. Business hub | Built, partly tested. |
| D. Delivery and logistics | Not started |
| E. Notifications | Built, partly tested. See `docs/SCHEDULED_JOBS.md` for what is not scheduled. |
| F. Trust and safety (advanced) | Not started |
| G. Payments | Built, partly tested. A ledger, off by default; no payment provider is connected. |
| H. Customer support | Built, partly tested. See Module H below. |
| I. Analytics | Built, partly tested, except delivery performance (needs Module D). See Module I below. |
| J. Monetisation | Not started |
| K. Location management | Not started |
| L. Web administration dashboard | Not started |

## Module A: advanced marketplace

Migration `0008_marketplace.sql`. Nothing from earlier migrations was changed.

| Feature | What exists | Tested |
|---|---|---|
| Guest browsing | Guests read only public views and functions (active, approved listings from accounts that are not suspended; no private columns). The app lets signed-out people browse, open listings and seller pages; anything else sends them to sign in. | Database: yes. Route rules: unit tests. Screens: not run. |
| Featured | Moderators feature a listing for 1 to 30 days (two-factor, audited). Shown on the home page. | Database: yes |
| Trending | Different signed-in people who viewed it plus three per save, over seven days. | Database: yes |
| Recently viewed | Per person, private, clearable. One view per listing per hour. Views older than 90 days are deleted by `purge_old_listing_views`, **which still needs a schedule** (see below). | Database: yes. Schedule: not set up |
| Search and filters | Word (title and description), category, area, condition, price range, verified sellers only, sort. Search characters are treated as plain text. | Database: yes |
| Nearby | Items in the same town as a chosen area, same area first. This uses the town and area names, not distance. Real "near me" by distance needs coordinates and comes with the location module. | Database: yes |
| Recommendations | Newest items in categories the person viewed or saved in the last 30 days, excluding their own, already viewed and already saved items. Explained in the app as based on what they looked at. | Database: yes |
| Product alerts | Up to 10 saved searches each. A new matching listing creates an alert once, when it first becomes visible. Alerts show in the app. **Push, SMS and email delivery are part of the notifications module and do not exist yet.** | Database: yes |
| Sharing | Share sheet with the title, price and, when `EXPO_PUBLIC_WEB_URL` is set, a link. | Unit tests for the text and links. Opening a shared link in the web build has not been tested; the web host also needs to send unknown paths to the app (a single page app rewrite). |
| Seller storefront | Seller page with name, level, rating, member since, active listings and reviews (reviews for signed-in people). Business storefronts come with the business hub. | Database: yes. Screen: not run. |

### Still needed before Module A can be called done

- Run migration 0008 and `marketplace.sql` on the real staging project.
- Open the app (phone and web) and walk through: browse as a guest, sign in, search, filter, save a search, post a matching listing from another account, approve it, see the alert, share, open the seller page.
- Schedule `purge_old_listing_views` (and the other retention jobs) with pg_cron or an Edge Function.
- Install `@expo/vector-icons` with `npx expo install @expo/vector-icons` (it is in `package.json` but missing from the committed `node_modules`).

## User & Trust Management (staff section, added by instruction)

Instruction: keep **Staff tools** for staff administration and add a separate section. Staff tools only gained one button ("User & Trust Management"); nothing was moved.

Status: **built, partly tested.** The database part is tested (see `docs/TESTING.md`); the screens are type-checked but have never been opened on a phone, and there is no real Supabase project behind them yet.

| Asked for | Where |
| --- | --- |
| Pending applications | `/trust/applications` (Pending tab; people and businesses; oldest first) |
| Verified users | `/trust/users` (Verified filter) |
| Rejected applications | `/trust/applications` (Rejected tab, shows the reason and who decided) |
| Suspended accounts | `/trust/users` (Suspended and Restricted filters, with the reason) |
| Individual user profiles | `/trust/user/[id]` (state, activity counts, businesses, staff roles) |
| Document review | "Review the document" on an application (support only; the database logs the opening, then storage gives a five-minute link) |
| Approve / reject | On pending applications (support). Rejection needs a reason. Nobody can decide their own application. Suspend / restrict / reinstate on the profile (moderators, reason required) |
| Verification history | On each profile: every identity and business application with decision, reviewer and note |
| Admin audit trails | `/trust/audit` (all of this section's actions) and per person from their profile. Technical admins see every action; support and moderators see only identity, business, account-state and document entries |

Database: migration `0010_user_trust_management.sql` (functions `trust_applications`, `trust_users`, `trust_user_profile`, `trust_verification_history`, `trust_open_document`, `trust_audit_trail`; stronger `review_identity_verification` / `review_business_verification`). All need two-factor sign-in and the right role.

Known limits:
- Support can still read the private document buckets directly through storage (the 0005 policy). The audit entry is written by the screen's path, so a person with support access who goes around the app is not logged. Closing that needs documents to be served by an Edge Function with the service key; not built.
- Applications are listed by name search only (no date or reviewer filter yet).
- The second-person approval rule in the directive (Module L) is not applied to verification decisions yet.

## Module K: location management

Migration `0018_locations.sql` (run by hand after `0017`), tests in `supabase/tests/locations.sql`.

### Built and tested (database)
- Places gain a district and optional coordinates (inside Zambia only). Only a tech admin can add places or set coordinates, and each is audited. Existing places are treated as Lusaka district.
- Saved addresses (delivery, pickup or both) with landmark and directions, one default, a per-person limit set in platform settings. Only the owner can read them; staff cannot.
- Delivery areas for a personal seller or a business (area, town, district or province level). A seller with none set is unrestricted, as before. Buying with delivery is refused outside the seller's places, and a saved address fills in the order's address text.
- A seller can share one of their own pickup addresses on a confirmed collection order.
- Nearby ranking: same area, then town, then district, then province, then by distance when coordinates exist.

### Built (phone app, typechecked and unit tested, never run on a phone)
- Province, district, town, area picker; saved addresses list and edit; "Where I deliver" for sellers and businesses; checkout address choice with a coverage message; "Delivers to" on a listing; pickup address share and display on orders; Home "nearby" uses the new ranking; Saved addresses in the Account settings.

### Known limits (honest)
- No map picker and no phone GPS: both need a map package or provider key that has not been added. Coordinates exist only if staff set them; the app never guesses a position. "Open in Maps" appears only for an address that has coordinates, and the app cannot set those yet.
- Only Lusaka places are offered, by decision. `0019` added other provinces' main towns and `0020_lusaka_only.sql` removes the unused ones again (a place already in use is kept). Other provinces, towns and areas come back when you expand (staff use `admin_add_location`). No place data was invented.
- People can type an address's coordinates by hand (copied from their Maps app). That is the only way to set them; there is still no map picker or GPS.
- Distance is straight line, not road distance. Delivery fees are still set by the seller; there is no zone pricing (that belongs to Module D).

## Account Hub (Profile tab)

A separate brief, done as a layer over existing screens with no database changes. See `docs/CHANGE_REPORT_ACCOUNT_HUB.md` for what was added, what was reused and what is not done (deliveries, promotions, bulk upload, phone verification, device list, privacy and language settings).

## Module I: analytics

Migration `0016_analytics.sql` (0015 is the staff voting migration), tests in `supabase/tests/analytics.sql`. Read-only: it adds functions and nine indexes, and changes no existing table.

| Directive item | What exists | Tested |
|---|---|---|
| Seller analytics | Views, people who looked, chats, orders requested, saves, completed orders and value, average order, handling times, not-completed share, reviews, best listings, a day-by-day series. Personal listings only, or one business | Database: yes |
| Business analytics | The same figures for one business. Owner and manager only (`view_analytics`); plain staff members and outsiders are refused | Database: yes |
| Product performance | One listing: views, saves, chats, orders, conversion rates, days listed, stock | Database: yes |
| Sales reporting | Completed orders by day, week or month, and by listing, for up to a year. Shareable as CSV text from the screen. Cells that start with = + - or @ are quoted so a spreadsheet cannot run them | Database and CSV logic: yes |
| Customer engagement | Chats answered, first reply time, chats waiting over 24 hours, repeat and new customers. Buyers are counted, never named | Database: yes |
| Platform statistics | Technical admin and finance only: people, businesses, listings, orders, chats, reviews, daily series | Database: yes |
| Fraud and dispute statistics | Moderators, support and technical admin: reports, disputes, appeals, risk flags, restricted and suspended accounts, verification queues | Database: yes |
| Financial reporting | Finance and technical admin only, two-factor required. Every run writes an audit record. Counts only payments made through the app | Database: yes |
| Delivery performance | **Not built.** It needs delivery tracking, which is Module D | n/a |
| Screens | My numbers, business numbers, listing numbers, sales report, staff statistics | Not run on a phone |

### Known limits

- Money figures count item prices of completed orders. Delivery fees are shown separately. Many deals are paid in person, so these are sales records, not bank figures, and the screen says so. They are not tax or accounting statements.
- Page views are only kept for 90 days, so a longer window shows 90 days of views and says so.
- A view is counted at most once an hour per person, so a person can chat or order without a recorded view. Conversion rates are capped at 100%.
- Figures are worked out live on each open, not pre-computed. With a lot of data they will slow down; the indexes help but this has not been tested with large amounts of data.
- Times and day boundaries use Zambia time (Africa/Lusaka).
- Everything is English only.

### Still needed before Module I can be called done

- Run migration 0016 and `analytics.sql` on the staging project.
- Open each screen on a phone with real orders and check the numbers against what you expect.
- Decide who on staff should see platform and finance figures.

## Module H: customer support

Migration `0014_support.sql`, tests in `supabase/tests/support.sql`.

What already existed and is unchanged: reports, order disputes with evidence, and appeals against moderation decisions (with their staff screens). This module adds the rest.

| Directive item | What exists | Tested |
|---|---|---|
| Support tickets | Anyone signed in can open one, including a suspended account (they need a way to ask). Up to 5 open at once, 5 new per day | Database: yes |
| Complaint categories | Nine categories in a table (payment problem, scam or safety, order problem, account access, verification, listing, business account, app problem, other), each with a starting priority | Database: yes |
| Evidence uploads | Up to 5 photos per ticket in a new private bucket `support-evidence`. The file path is checked to sit in the person's own folder for that ticket. Staff open them through short-lived signed links | Paths and limits: yes. Real uploads: **no** |
| Case tracking | Status (received, being looked at, waiting for the customer, with a senior team member, resolved, closed), a first-reply target time by priority, a late flag, a history of events for staff | Database: yes |
| Support messaging | A thread per ticket. Staff can add internal notes the customer never sees. The reply notification never contains the reply text | Database: yes |
| Escalation | A support agent escalates with a written reason. The ticket goes back to the queue with no owner and high priority, and a different person must take it and resolve it. Audited | Database: yes |
| Resolution records | A resolution code and a written note the customer can read. The customer can reply within 7 days to reopen it. Resolved tickets close by themselves after 7 days. The customer can rate the help once | Database: yes |
| Customer appeals | Unchanged route. New: the person is now told the outcome of their appeal | Database: yes |
| Support performance monitoring | Overview (open, late, escalated, unassigned, average first reply, average time to resolve, average rating, tickets by category) and a per-agent table. Tech admins see every agent, other support staff see only themselves | Database: yes |
| Screens | Customer: Help list, new ticket, ticket thread with photos, rating. Staff: help desk queue with filters and search, ticket detail (take, reply, note, escalate, resolve), team performance | Not run on a phone |

### Known limits

- Staff do not get a notification when a customer replies or a ticket is escalated. They find work in the queue (escalated and late ones sort first). A staff notification channel is a later job.
- The ticket screens refresh when you open them, not live.
- Support staff can still read the older private buckets (identity and business documents, dispute evidence) straight from storage without an audit entry. This is the same gap as before; it needs an Edge Function. The new support evidence bucket has the same property.
- Target times are starter values, not promises. Nothing yet pauses the clock outside working hours.
- The performance figures can be misused as a ranking. The screen says they are a coaching guide. Whether to use ratings in reviews of staff is for you.
- Reports and order disputes still live on their own screens. A ticket is not linked to a report or dispute.
- Messages are English only, like the rest of the app.
- `close_resolved_tickets` is not scheduled yet (see `docs/SCHEDULED_JOBS.md`). Without it, resolved tickets stay "resolved" and the customer can keep replying.

### Still needed before Module H can be called done

- Run migration 0014 and `support.sql` on the staging project.
- Walk through on a phone: open a ticket with a photo, see it appear in the help desk, reply both ways, escalate and have another account resolve it, rate it.
- Decide who is on the support team and how quickly they must reply.

## Module G: payments

Migration `0013_payments.sql` (it replaces two empty placeholder tables from migrations 0002 and 0004, and refuses to run if they ever contain rows), tests in `supabase/tests/payments.sql`.

**Design rule:** ZedMarket records payments, it does not hold money. There is no wallet. Whether this set-up, or any later one that holds funds, needs a licence is a question for a lawyer and the Bank of Zambia, and I cannot answer it.

| Directive item | What exists | Tested |
|---|---|---|
| Authorised provider integration | **Not built.** No provider or aggregator has been chosen. The database has the functions a provider worker will call (`record_provider_result`, `record_refund_result`, `expire_stale_payments`, service role only). Payments are switched off (`payments.enabled = 0`) until you turn them on | Functions: yes. A real provider: **no** |
| MTN Mobile Money, Airtel Money | The buyer picks one and enters a +260 number. Which one a provider supports is for the provider to say | Format and choice: yes |
| Payment verification | A payment becomes paid only by a provider result (right amount, with a provider reference) or by finance with a provider reference and a written note. The app cannot mark anything paid. The amount is taken from the order by the database, not from the phone | Database: yes |
| Reconciliation | Finance can settle a waiting payment, or one flagged for checking, by hand against the provider statement. Every reconciliation is audited and finance staff cannot reconcile a payment they are part of | Database: yes |
| Refund management | Finance requests, a different finance person approves or rejects, then the refund is recorded as sent (or failed) with the reference. Refunds in progress count against the amount, so the total can never go above what was paid | Database: yes |
| Failed payments | Provider failure, cancel by the buyer, timeout after 30 minutes, and retry (a new attempt is allowed once the old one is closed). A late "paid" report for a closed payment, or a wrong amount, is not applied: it is flagged for finance. Cancelling an order closes its waiting payment and flags a paid one for finance | Database: yes |
| Payment history | Buyers and sellers see their own payments; the order screen shows the payment state; a Payments screen lists them | Database: yes. Screens: not run |
| Finance administration | Finance screen: counts and amounts, filters, search, payments needing a check, payment detail with its history, reconcile, refund requests and approvals. Phone numbers are masked | Database: yes. Screens: not run |

### Known limits

- Nothing can actually be paid yet. With no provider connected, a payment started in the app would only wait and time out, which is why it is switched off by default.
- Provider webhooks (and checking their signatures) will need an Edge Function written for the chosen provider. I did not write a placeholder.
- The receipt for a completed order still says ZedMarket did not take or confirm payment. That is accurate for payments made outside the app and cautious for payments made inside it. It should be reworded once payments are live.
- Money does not move between ZedMarket and the seller. Settlement to sellers, fees, and tax are the provider contract's job and are not designed here.
- Finance staff can read other people's masked phone numbers and provider references. Staff role changes still need two people (tech admin), but nothing stops a finance person looking at payment records without a case.
- Disputes and payments are not linked automatically: a dispute decision does not start a refund. Finance does that by hand.
- Two payment attempts at the same instant for one order are stopped by a database rule, but I did not add a timed race test as I did for stock.

### Still needed before Module G can be called done

- Choose a provider or aggregator, check it is authorised in Zambia, and write its worker and webhook handler.
- Get the legal and regulatory advice above.
- Run migration 0013 and `payments.sql` on the staging project, schedule `expire_stale_payments` (`docs/SCHEDULED_JOBS.md`).
- Walk through on a phone with the provider's test mode: pay, fail, time out, cancel, late success, refund.

## Module E: notifications

Migration `0012_notifications.sql`, tests in `supabase/tests/notifications.sql`.

| Directive item | What exists | Tested |
|---|---|---|
| In-app notifications | `notifications` table, written only by the database (`notify`). Triggers cover order events, chat messages (never the message text), saved-search alerts, identity and business verification decisions, account suspension and restoring, listing rejection and moderator approval, business invitations, and low stock | Database: yes |
| Push | Device tokens (`register_push_token`, at most 10 per person, a token moves to whoever registered last), a delivery queue, and an Edge Function `send-notifications` that sends through Expo | Queue: yes. Edge Function and phone: **no** |
| Email and SMS | Preferences and queue rows exist and are switched off by `notifications.email_enabled` / `notifications.sms_enabled`. **No sender is built**: no provider has been chosen | Gating only |
| Unread counts | `unread_notification_count()`, live updates through Realtime, badge on the Account screen | Count: yes |
| History | Inbox screen with category filter, read and unread, mark one or all as read; old ones are purged by `purge_old_notifications` | Database: yes |
| Preferences | Per category: in-app, push, email, SMS. Account and safety notices cannot be switched off. Switching a category off in-app mutes it completely | Database: yes |
| Deep links | Stored as plain paths, checked by the database (no `..`, no web addresses) and again by the app against a list of real screens | Both: yes |
| Retry and duplicates | A repeated event gives one notification (unique key per person). Deliveries are claimed with a 2-minute lease so two workers never take the same one, retried after 1, 5, 30, 120 and 720 minutes, then marked dead. A notification already read, or a token that was switched off or moved, is skipped. Dead tokens reported by Expo are disabled | Database: yes, including races between workers' leases |

### Known limits

- The Edge Function has never been run. Its request and response shapes come from my knowledge of Expo's push service and need checking against Expo's current documentation. It does not read Expo's delivery receipts.
- Push on a phone needs the `expo-notifications` package, a development or production build and an Expo project id. I did not change `package.json`, so the app loads the package only if it is installed. Nothing was tried on a phone.
- Nothing is scheduled yet (see `docs/SCHEDULED_JOBS.md`): without the schedule, push is never sent and old notifications are never purged. In-app notifications work without it.
- Saved-search alerts and chat messages now appear twice: in the older Alerts screen and in the notification inbox. The old screen is kept so nothing is lost.
- The in-app text is English only. Bemba and Nyanja come with the localisation pass.
- Who gets what is decided in the triggers. Each text is short and plain; staff should read them before launch.

### Still needed before Module E can be called done

- Run migration 0012 and `notifications.sql` on the real staging project.
- Deploy `send-notifications`, set its secrets, schedule it, and send a real test push.
- Choose an email and an SMS provider (cost and Zambian delivery should drive that) and build their senders, or decide not to offer those channels.
- Walk through on a phone: place an order and see the seller notified, tap it and land on the order, mute a category, sign out and confirm the phone stops receiving.

## Module C: Business Hub

Status: **built, partly tested.** Database tested (SQL tests, mutation checks and real-connection race tests). Screens type-checked and the permission table unit-tested against the same strings as the database, but never opened on a phone and never run against a real Supabase project.

| Directive item | What exists |
| --- | --- |
| Public business storefronts | `/business/[slug]` (open to signed-out visitors): description, verified badge only when staff verified the registration, branches, catalogues, search, listings. Views `public_businesses`, `public_business_branches`, `public_business_catalogues`, function `business_storefront_listings`. Suspended owners disappear. |
| Catalogues | Named groups of a business's listings, hidden or shown, up to 30 per business and 200 listings each (Business tools, Catalogues) |
| Business product listings | The Sell tab can post as yourself or as one of your businesses, pick the branch, and give a starting stock count |
| Inventory management | Stock counts per listing with a movement history, low-stock level, pause at zero and restore on restock (only for listings the system paused), one unit off per completed order |
| Employee invitations | By email, 7 days, matched to a confirmed email address; accept, decline, revoke. Direct inserts into the member table are closed |
| Role-based permissions | `business_can()` in the database, mirrored in `src/domain/business.ts` and compared string-for-string in tests. Owner: everything. Manager: everything except the team. Staff: orders, listings and stock. Suspended members have none |
| Multiple branches | Up to 20 per business, one main branch, listings and orders carry a branch, switching off needs the branch to have no active listings |
| Business order management | Order list with filters (`business_orders`); answering orders reuses the existing order screen and rules |
| Business analytics | `business_analytics`: orders, completed value, views, saves, stock warnings, top listings, split by branch, for 7, 30 or 90 days. Owner and manager only |

Database: migration `0011_business_hub.sql`. Tests: `supabase/tests/business_hub.sql` and race scenarios 6 and 7 in `supabase/tests/local/concurrency.sh`. Race scenario 6 exists because stock and order completion lock the same rows; the stock functions lock the listing first, the same order the order functions use, to avoid deadlocks.

### Known limits

- **One buyer per listing at a time.** Module B reserves a whole listing for one confirmed order, so a business holding 5 of an item can still have only one confirmed order on that listing at once. Each completed order takes one unit off. Letting several buyers hold units at the same time needs the reservation table reworked, and the race tests redone.
- Completed value is the listed price of completed orders. ZedMarket handles no payment, so it is not money received.
- No owner transfer, and no "delete business" screen.
- Staff are not limited to one branch: every member sees all of the business's orders and stock. Branch-limited staff would need changes to the order access rules.
- Business profile edit (name, description, logo, address) uses the existing owner/manager table permission; there is no screen for it yet beyond creation.
- Invitations need the invited person to have an account with a confirmed email. Nothing sends them an email or a notification yet (Module E).
- The business limit per person is not capped.

## Module B: order management

Migration `0009_orders.sql`. It changes three things from earlier migrations on purpose: `create_order` gains two optional arguments (the old two-argument version is replaced; calls with one or two arguments still work), and `set_order_status` and `open_dispute` are redefined. `set_order_status` keeps its signature and hands over to the new functions, so older app versions keep working. The `public_listings` view keeps its columns but now leaves out reserved items.

| Item | What exists | Tested |
|---|---|---|
| Checkout | Choose collection or delivery, delivery address or landmark, note to the seller. Says plainly that nothing is charged and ZedMarket does not hold money. | Rules: database and unit tests. Screen: not run. |
| Stock control | Requests do not reserve an item. When the seller confirms one order, the item is reserved (one row per item, the primary key refuses a second) and every other open request for it is turned away. Reserved items leave browsing. Row locks keep simultaneous actions in order. | Database tests, plus `concurrency.sh`: many real connections acting at the same moment (confirm against confirm, ask against ask, cancel against confirm, mark sold against confirm, ask against confirm). |
| Order expiry | Unanswered requests close after 48 hours and confirmed orders nobody hands over close after 7 days (starting values in `platform_settings`). A stale reservation is also released when the next buyer asks, so the schedule is not the only safeguard. | Database: yes. **The schedule itself is not set up** (see `docs/SCHEDULED_JOBS.md`). |
| Seller confirm, decline, cancel | Server-side only. Business members can act for a business listing. | 108 combinations of person, step and state, checked against one table. |
| Hand-over and confirmation | Seller marks collected or delivered; buyer confirms they have it. If the buyer says nothing and opens no dispute for 3 days after hand-over, the order completes by itself. | Database: yes |
| Delivery fee | The seller states it when confirming (collection orders have none). It is shown on the order and the receipt. | Database: yes |
| Event history | Every step is recorded by the database with who did it. Nobody can write or edit it from the app. | Database: yes |
| Digital receipt | Available once completed. Records the item, price, fee and total agreed. It says that ZedMarket did not take, hold or confirm any payment. It is not proof of payment. | Database and unit tests |
| Dispute initiation | Unchanged rules, now recorded in the history, and a disputed order stops expiring or completing by itself. Support staff settle a disputed order as completed or cancelled (audited, two-factor). | Database: yes |
| Item stops being for sale | A seller cannot pause or mark sold an item with a confirmed order. Removal by staff, or pausing with only open requests, closes the orders with a reason. | Database: yes |

### Known limits

- No money moves, so there is nothing to refund. Payment is between buyer and seller until the payments module.
- Collection and delivery PINs, proof of delivery and provider tracking belong to the delivery module and are not here.
- Notifications about order changes belong to the notifications module. Until then people see changes when they open the app.
- Support staff accounts see every order in their own orders list (the database allows them to read orders). A proper staff order screen comes with the admin dashboard.
- Orders made before this migration are backfilled as well as the old data allows (for example the confirmation time is taken from the last update).

### Still needed before Module B can be called done

- Run migration 0009, `orders.sql` and `concurrency.sh` on the real staging project (the race script needs a superuser connection and creates its own scratch database).
- Schedule `run_order_maintenance` (`docs/SCHEDULED_JOBS.md`).
- Walk through on a phone: request (collection and delivery), seller confirms, another buyer sees "reserved", buyer cancels, seller declines, hand-over, buyer confirms, receipt, dispute, review.
