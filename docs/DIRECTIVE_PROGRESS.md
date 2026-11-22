# Progress against the development directive

Status words used here: **Done** means built and tested through the whole user journey. **Built, partly tested** means the code exists and some of it is tested, but not the whole journey. **Not started** means nothing exists. Nothing is marked Done until it has been tested end to end on a real Supabase project and a real device.

| Item | Status |
|---|---|
| 1. Stabilise existing work | Built, partly tested. Migrations and database security tests run in GitHub Actions and locally. Not yet tested: real sign-up and recovery, uploads, chat delivery, screen journeys. |
| A. Advanced marketplace | Built, partly tested. See below. |
| B. Order management | Built, partly tested. See below. |
| C. Business hub | Not started |
| D. Delivery and logistics | Not started |
| E. Notifications | Not started |
| F. Trust and safety (advanced) | Not started |
| G. Payments | Not started |
| H. Customer support | Not started |
| I. Analytics | Not started |
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
