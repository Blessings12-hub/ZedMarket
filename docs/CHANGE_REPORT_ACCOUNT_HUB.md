# Change report: Account Hub

The brief called the app "Zedlivo". The app name stays **ZedMarket** on your instruction, and the suggested colour palette was not applied, because the rest of the app keeps its current green theme and a navy hub would look out of place. If you later choose a new name or palette, it is one file (`mobile/src/theme.ts`).

This is a layer over the existing Profile tab. No existing screen, route, table or function was removed or renamed, and there are **no database changes**.

## What the Profile tab was before (recorded first)

Name, email, verification badge, account-state notice with appeal, and buttons for Notifications, selling numbers, Help, Payments, Orders, Get verified, Business tools, Saved items, Saved searches and alerts, Staff tools (staff only), a "My listings" list with appeal links, and Sign out. Every one of these is still reachable.

## What it is now (in the order the brief asks)

1. Identity: photo or initial, name, email, verification badge, email confirmed or not, member since, Edit profile, Share profile.
2. Account switcher (only shown if you belong to a business): Personal or one of your businesses.
3. Quick access: Orders, Listings, Saved, Messages, with real counts.
4. My purchases: orders, saved products, saved searches and alerts, reviews, and Payments only when payments are switched on.
5. My selling account: seller dashboard, my products, post a listing, selling orders, customer enquiries, seller verification, with a live summary.
6. Business centre: only for the business chosen in the switcher, and only the tools that person's role allows.
7. Communication and support: notifications, messages, help and support, disputes/appeals/reports.
8. Account settings: personal information, security and login, notification preferences.
9. Staff section (staff only), then Sign out.

## Files added

- `mobile/src/features/account-hub/hub.ts` (what each person sees, in one testable place), `hub.test.ts`, `api.ts`, `components.tsx` (AccountHeader, AccountTypeSwitcher, AccountQuickActions, AccountSection, AccountMenuItem, SellerSummary, BusinessSummary)
- `mobile/app/profile/edit.tsx`, `mobile/app/settings/security.tsx`
- `mobile/app/account/listings.tsx` (the old "My listings" list, moved), `reviews.tsx`, `cases.tsx`
- `supabase/tests/account_hub.sql`

## Files modified

- `mobile/app/(tabs)/account.tsx` (now the hub), `mobile/app/_layout.tsx` (titles for the new screens), docs and README.

## Existing functions reused

Sign-out and push removal, `fetchMyListings`, `fetchMyRoles`, `countUnreadNotifications`, `watchNotifications`, `countUnreadAlerts`, `paymentsEnabled`, `fetchReviewsAbout`, dispute and appeal types and labels, `pickOnePhoto`, share links, `roleCan` (business permissions), and every existing screen the rows open.

## New functions

Loading the hub in one go, saving the profile, changing the photo (public avatars bucket, own folder), change password, resend confirmation, reset email, sign out of other devices, reviews I wrote, my cases.

## Tests

- 12 unit tests for the hub rules (ordinary user, staff, business roles, unverified business, wrong business id, counts, no deliveries/promotions items). All 98 unit tests pass.
- `account_hub.sql`: checks the exact queries the hub makes against the security rules (own cases only, outsiders and guests see nothing, staff who can read every dispute still get only their own in "my cases", profile edits cannot change verification or account state or someone else's profile). One deliberate break (making disputes readable by everyone) was caught.
- Typecheck: clean apart from the known missing `@expo/vector-icons` package.

## Not done, and why

- **Deliveries / delivery tracking:** Module D, not built yet. No item is shown.
- **Promotions and advertising:** Module J, moved to the end. No item is shown.
- **Bulk CSV or Excel upload:** does not exist in the backend yet; not shown.
- **Phone verification:** needs an SMS provider. Only email status is shown.
- **Session management:** supported is "sign out of my other devices". A list of each device is not available from the sign-in service on the phone.
- **Privacy preferences, language, username:** nothing in the database yet. Adding them needs a migration and your decisions, so they are not shown.
- **Help centre and FAQs:** "Help and support" is the ticket system. There are no articles yet.
- **Addresses:** arrives with Module K.
- **Unverified businesses:** the database does not restrict business tools by verification, only the badge. The hub shows a "Not verified yet" label and a verify button to the owner. Restricting tools until verified would be a new rule and a migration; tell me if you want it.
- **The switcher** changes what the hub shows. It does not change who you are signed in as.
- **Not tried** on Android or iOS or in a browser. There is no lint script in the project.
