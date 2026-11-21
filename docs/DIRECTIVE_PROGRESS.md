# Progress against the development directive

Status words used here: **Done** means built and tested through the whole user journey. **Built, partly tested** means the code exists and some of it is tested, but not the whole journey. **Not started** means nothing exists. Nothing is marked Done until it has been tested end to end on a real Supabase project and a real device.

| Item | Status |
|---|---|
| 1. Stabilise existing work | Built, partly tested. Migrations and database security tests run in GitHub Actions and locally. Not yet tested: real sign-up and recovery, uploads, chat delivery, screen journeys. |
| A. Advanced marketplace | Built, partly tested. See below. |
| B. Order management | Not started |
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
