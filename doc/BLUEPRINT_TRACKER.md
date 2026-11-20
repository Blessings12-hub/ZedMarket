# Blueprint tracker

This maps every requirement in `ZedMarket_Business_Blueprint.pdf` (18 pages, 15 sections) to where it lives in this repo and how far along it is.

Status key:

- **Built**: written in this repo. Nothing has been run against a real Supabase project or a phone yet, so "built" means "written", not "proven".
- **Schema**: database tables, rules and permissions exist; no screen or server code yet.
- **Planned**: not started, scheduled for the release shown.
- **Owner**: needs a decision, document or approval from the business, not code.
- **External**: depends on a third party (provider, regulator, lawyer).

Release numbers follow blueprint section 11: R1 marketplace MVP, R2 delivery, R3 business platform.

## 1. Executive summary

| Requirement | Release | Status | Where |
|---|---|---|---|
| Buy, Sell, Deliver as three pillars | R1-R3 | Built (Buy, Sell), Schema (Deliver) | `mobile/app`, `supabase/migrations` |
| Marketplace first, then delivery, then payments | all | Built (order of work follows this) | this file |
| Not a fund holder, insurer or driver employer | all | Built | no wallet table; `payments` is read-only; drivers are provider data |

## 2. Product concept and target users

| Requirement | Release | Status | Where |
|---|---|---|---|
| Buyers, individual sellers, businesses, delivery providers | R1-R2 | Built (buyers, sellers), Schema (businesses, providers) | `profiles`, `businesses`, `deliveries` |
| Launch categories: electronics, fashion, furniture, household | R1 | Built | `0006_reference_data.sql` |
| Add more categories only when moderation is ready | R1 | Built | `categories.requires_review`, `is_active` |
| ZMW prices | R1 | Built | `domain/money.ts` |
| Province / town / area filters | R1 | Built (Lusaka starter list) | `locations`, `FilterSheet.tsx` |
| Condition labels | R1 | Built | `item_condition` enum, `domain/listing.ts` |
| Transparent delivery charges | R2 | Planned | disclosed before commitment, see section 8D |
| Prohibited goods as a moderation issue | R1 | Built (starter terms) | `prohibited_terms`, `listings_before_write` |

## 3. Concept map

| Item on the map | Release | Status | Where |
|---|---|---|---|
| Buy and sell, all categories | R1 | Built (4 launch categories) | `app/(tabs)` |
| Smart search and filters (location, price) | R1 | Built | `domain/search.ts`, `index.tsx` |
| In-app chat | R1 | Built | `chat/[id].tsx`, realtime |
| In-app calls | later | Planned | not in any release table in the blueprint; decide after R1 pilot |
| Integrated delivery (Yango, inDrive) | R2 | Schema; External | `deliveries`, provider approval needed |
| Live tracking (map + ETA) | R2 | Schema | `delivery_locations`; maps SDK not added |
| Seller and buyer verification | R1 | Built (not run) | submit screens `app/verify`, staff review `app/admin/verifications.tsx`; phone check still needs an SMS provider |
| Reviews and ratings | R1 | Built (not run) | `app/review`, `app/seller/[id].tsx`, staff can hide a review (migration 0007) |
| Safe payments (mobile money, cards) | R3 | Schema; External | `payments`, `payment_events` read-only |
| Notifications and alerts | R1-R2 | Planned | Expo Notifications, needs edge function |
| Revenue: commission, promotions, subscriptions, delivery fees, featured stores | R3 | Planned | see section 10 |
| Modules: marketplace, delivery, safety, business tools, admin panel | R1-R3 | Mixed | see sections 9 and 11 |
| Security and anti-fraud list | R1 | Mixed | see section 7 |
| How it works (6 steps) | R1-R2 | Built to step 2, Schema after | see section 4 |
| Success strategy: local needs, low data usage, clear design | R1 | Built (small images, paged lists) | `listings/api.ts` PAGE_SIZE 20, image resize |
| Legal and risk protection list | all | Owner | see section 8 |
| Disadvantages and risks | all | see section 6 | |

## 4. How the application works

### Buyer journey

| Step | Status | Where |
|---|---|---|
| Register and search by product, category, price, condition, location | Built | `sign-up.tsx`, `index.tsx` |
| Listing details, seller profile, verification status | Built | `listing/[id].tsx`, `seller_stats` view |
| Warranty / return information | Planned | no field yet; add with terms of sale (Owner) |
| Contact seller through messaging, agree terms | Built | `start_conversation`, chat |
| Seller confirms the order | Built | `create_order`, `set_order_status`, `orders.tsx` |
| Seller requests delivery through a provider workflow | R2 | Schema | `deliveries` |
| Buyer sees only driver details the provider may share | R2 | Schema | `delivery_drivers` RLS, active deliveries only |
| ETA only from an authorised source | R2 | Schema | check constraint: ETA needs a source |
| Collection and delivery confirmation, report a problem, feedback | R1 report: Built; R2 confirmation: Schema | `report.tsx`, PIN columns |

### Seller journey

| Step | Status |
|---|---|
| Create account, individual or business verification | Schema; submit screens Planned |
| Publish listing with photos, description, condition, price, category, location | Built (`sell.tsx`, 1 to 8 photos) |
| Respond to enquiries, confirm stock | Built |
| Arrange pickup | R2 |
| Monitor delivery status, retain evidence | R2 (`delivery_events`) |
| Mark sold / unavailable | Built (`setListingStatus`) |

### Delivery-provider journey and three-screen model

| Item | Release | Status |
|---|---|---|
| Receive request via approved integration or manual booking | R2 | Schema |
| Accept / decline under provider rules | R2 | External |
| Driver and tracking info from provider | R2 | Schema (`delivery_drivers.source = 'provider'`) |
| Collection by order reference or PIN | R2 | Schema (hashed PINs) |
| Status updates and proof of delivery | R2 | Schema (`delivery_events`) |
| Exceptions under provider agreement | R2 | Owner / External |
| Buyer screen, seller screen, driver screen | R2 | Planned (driver screen depends on provider route) |

### Delivery timeline

Order confirmed, driver assigned, at pickup, collected, in transit, delivered, with the recipients named in the blueprint table. Statuses exist in the `delivery_status` enum; recipients of each update are enforced by who can read the row (`is_delivery_party`). The "never promise an ETA" warning is enforced by the ETA source constraint and by `etaLabel` in `domain/delivery.ts`, which says "estimate".

## 5. Yango and inDrive strategy

| Requirement | Status |
|---|---|
| Investigate Yango business delivery, request formal discussion | Owner / External |
| Ask for API docs, sandbox, commercial terms, coverage, vehicle classes, tracking events, cancellation rules, data-sharing terms | Owner / External |
| Confirm driver data may legally be passed on | Owner / External |
| Written agreement: service levels, liability, insurance, escalation, retention, incident notice | Owner / External |
| inDrive: do not assume an API; manual workflow with booking reference only | Schema (provider enum has yango, indrive, zedmarket; manual flow means a booking reference only, no UI yet) |
| Never scrape, automate unauthorised access, share driver info without permission, or show a fabricated map | Built (nothing of the kind exists; no fake map in the app) |
| Provider-neutral architecture, adapters convert provider events to standard statuses | R2 Planned (`supabase/functions/` adapters) |
| Standard statuses: requested, assigned, at_pickup, picked_up, in_transit, delivered, cancelled / failed with reason | Built (enum + check constraint) |

## 6. Advantages, disadvantages, threats

| Risk in blueprint | Mitigation in blueprint | Status in this repo |
|---|---|---|
| Marketplace fraud | verification, reports, moderation, evidence | Built (reports, moderation, risk flags); verification partial |
| Delivery failure | contracts, handover evidence, insurance review | R2 / Owner |
| Third-party dependency | multiple providers, manual fallback | Schema (provider enum, manual flow) |
| Low initial adoption | concentrated launch, recruited businesses | Owner (section 12) |
| Operating costs | narrow MVP, unit economics | Built (small scope) |
| Privacy exposure | minimisation, access controls, retention, incident response | Built (RLS, retention settings); incident plan Owner |
| Legal and regulatory risk | legal review | Owner |
| Threat: seller takes money and vanishes | no money held; evidence; reports | Built by design |
| Threat: courier fails to deliver high-value item | PINs, evidence, provider contract | Schema |
| Threat: compromised seller or admin account | MFA, audit, approvals | Built (staff MFA, `audit_logs`, `admin_approvals`) |

## 7. Security and anti-fraud

### A. Identity and account security

| Requirement | Status | Where |
|---|---|---|
| Phone and email verification | Built (email via Supabase); phone needs an SMS provider (External) | `sync_contact_verification` |
| Proportionate ID checks for higher-risk sellers | Schema + review RPC | `identity_verifications`, `review_identity_verification` |
| Verify businesses, never show documents publicly | Schema + private bucket | `business_verifications`, `business-documents` bucket |
| MFA for administrators | Built in database (aal2 required) | `has_staff_role` |
| MFA strongly encouraged for business accounts | Planned (account screen prompt) | |
| Rate limits, login throttling, suspicious-login alerts, session management, recovery | Rate limits Built; login throttling and alerts rely on Supabase Auth settings (Owner to enable), alerts Planned | `rate_limit_log` |
| Account recovery and appeals not based on guessable details | Appeals Built (not run); password recovery screen Planned | `appeals` |

### B. Listing and marketplace fraud

| Requirement | Status | Where |
|---|---|---|
| Duplicate photos | Schema (`content_hash`); hashing edge function Planned | |
| Repeated listing text | Planned | |
| Unusual price patterns | Partly (high-value rule); statistical check Planned | `listings_before_write` |
| Rapid listing / deletion behaviour | Rate limits Built; deletion pattern Planned | |
| Repeated reports | Built | `repeated_reports` risk flag |
| Suspicious contact changes, account clusters | Planned (staff can already see and close flags, `app/admin/flags.tsx`) | `risk_flags` table |
| Moderation queues for high-risk categories and new high-value listings | Built (rules and the staff review screen) | `requires_review`, high-value + new seller rule, `app/admin/listings.tsx` |
| Report and block tools | Built | `report.tsx`, chat block |
| Route to challenge moderation | Built (not run): `app/appeal.tsx`, staff `app/admin/appeals.tsx` | |
| No permanent bans by automated scoring | Built | `set_account_state` is staff-only and audited |

### C. Payment security (R3)

| Requirement | Status |
|---|---|
| Authorised provider, no wallet | Built by design |
| Server-side verification via callbacks, reconciliation | Planned (edge function) |
| Unique references, idempotency | Schema (`payment_events` unique provider event) |
| Screenshot or SMS never proof | Built by design (no upload path for it) |
| No card numbers or CVVs | Built by design |

### D. Delivery security (R2)

| Requirement | Status |
|---|---|
| Provider-verified driver details only | Schema (source check) |
| Unique references, separate collection and delivery PINs | Schema |
| Handover and delivery evidence with retention limits | Schema + purge function |
| GPS only during an active delivery, to authorised people | Schema (`delivery_is_active`, RLS) |
| Lost, damaged, delayed, cancelled, failed procedures | Owner / External |

### E. Backend and infrastructure

| Requirement | Status | Where |
|---|---|---|
| RLS on every exposed table, tested with buyer, seller, business, support, admin roles | Built; tests written, never run | `0004`, `supabase/tests/rls_policies.sql` |
| No service-role keys or secrets in the app | Built (`.env.example` holds only URL and anon key) | |
| Privileged work server-side, validate every field | Built (SECURITY DEFINER functions, column grants, checks) | |
| Least privilege, signed URLs, encryption, audit logs, backups | Least privilege, audit logs Built; private buckets Built; signed URL use in the app Planned; backups Owner (Supabase plan) | |
| Rate limiting, dependency scanning, patching, secrets rotation, monitoring, incident plan | Rate limiting Built; the rest Owner / Planned | |
| Test restore procedures, recovery plan | Owner | |

### F. Administrator security

| Requirement | Status | Where |
|---|---|---|
| Individual staff accounts, MFA, role-based access | Built | `admin_roles` |
| Separate support, moderation, finance, technical roles | Built | `admin_role` enum |
| Log suspensions, refunds, role changes, exports, delivery overrides | Built for the staff functions that exist; technical admins can read the log in the app | `write_audit`, `app/admin/audit.tsx` |
| Extra approval for high-impact actions, alerts on unusual admin behaviour | Approval table and decide screen Built; no action asks for approval yet, so nothing enforces it; alerts Planned | `admin_approvals`, `app/admin/team.tsx` |

## 8. Legal and regulatory readiness

Almost all of this is business and legal work, not code. This repo only provides the places the finished documents plug into.

| Item | Status |
|---|---|
| A. PACRA registration, tax registrations, business bank account, written agreements, insurance review | Owner / External |
| B. Review of Data Protection Act 2021, ECT Act 2021, CCPA Act, Cyber Security and Cyber Crimes Acts, National Payment Systems Act, PACRA and ZRA obligations | External (Zambian lawyer) |
| C. Terms of Service, Business Seller Agreement, Privacy Policy, Delivery Terms and Provider Agreement, Payments / refunds / disputes policy, Prohibited goods policy, Advertising rules, Staff access policy, incident plan, retention schedule | Owner / External. No sign-up consent line has been added because there are no approved documents to link to. |
| D. State ZedMarket's role in each transaction; do not call couriers employees; no promises about driver data; disclose fees; no blanket disclaimer; fair complaints and appeals | Owner / External. App wording avoids employee claims and avoids promising tracking. |
| E. Privacy by design: collect only needed data, retention periods, restricted and logged staff access, visible time-limited location sharing, assess processors and cross-border transfers, DPIA / DPO / registration | Retention settings and staff-read logging Built (values are placeholders, see below); the rest Owner / External |

## 9. Feature table (priority per blueprint)

| Feature | Priority | Status |
|---|---|---|
| Verified seller badge | MVP | Built (badge shown; set when staff approve an ID check) |
| Business storefronts | MVP / early | Business can be created and verified (`app/verify/business.tsx`); public storefront page and posting as a business Planned |
| Reviews and ratings | MVP / early | Built (not run) |
| In-app messaging | MVP | Built |
| Report and block | MVP | Built |
| Dispute centre | MVP / early | Built (not run): `app/dispute`, staff `app/admin/disputes.tsx` |
| Live delivery tracking | R2 | Schema |
| Business analytics | Later | Planned |
| Price alerts and recommendations | Later | Planned |
| Multiple delivery providers | Later | Schema (provider enum) |
| Buyer protection programme | Only after operational and legal design | Not started on purpose |

## 10. Revenue model (R3)

| Stream | Status |
|---|---|
| Promoted listings (clearly labelled) | Planned |
| Business subscriptions | Planned |
| Featured storefronts (labelled) | Planned |
| Delivery coordination fee (disclosed, needs provider agreement) | Planned |
| Advertising (privacy-compliant, labelled) | Planned |
| Illustrative revenue figures | Not product requirements; the blueprint says they are arithmetic examples only |

## 11. Roadmap, stack, entities

### Releases

| Release | Scope in blueprint | Status |
|---|---|---|
| R1 | Authentication, profiles, listings, photos, categories, search, filters, messaging, favourites, basic verification, reports, admin moderation | Built (not run). Admin moderation screens are written inside the app (`mobile/app/admin`): staff two-factor setup, listing review queue, report queue and report detail with listing removal, account restrict/suspend/restore and audited conversation reading. Not run yet. |
| R2 | Delivery records, manual provider workflow, adapter, Yango if approved, tracking, ETA, collection confirmation | Schema only |
| R3 | Storefronts, inventory, subscriptions, promoted listings, payments, analytics, multiple providers, advanced fraud detection | Schema for payments; rest Planned |

### Stack

| Blueprint item | Status |
|---|---|
| React Native + Expo, TypeScript | Built (versions unverified, see README) |
| Supabase Auth, Postgres, Storage, Realtime | Built |
| Edge Functions / trusted backend | Planned (none written yet) |
| Maps SDK | R2 Planned |
| Expo Notifications | Planned |

### Database entities

| Blueprint entity | Table |
|---|---|
| users / profiles | `profiles` |
| businesses | `businesses`, `business_members`, `business_verifications` |
| categories | `categories` |
| listings / listing_images | `listings`, `listing_images` |
| locations | `locations` |
| conversations / messages | `conversations`, `messages` |
| orders | `orders` |
| deliveries / delivery_events | `deliveries`, `delivery_events`, plus `delivery_drivers`, `delivery_locations` |
| payments / payment_events | `payments`, `payment_events` |
| reviews / favourites | `reviews`, `favourites` |
| reports / disputes | `reports`, `disputes`, `dispute_evidence`, `appeals` |
| audit_logs / admin_roles | `audit_logs`, `admin_roles`, `admin_approvals` |

### Illustrative TypeScript delivery model

The blueprint's type has `provider: 'yango' | 'indrive' | 'zedmarket'` and six statuses. The repo's version (`domain/delivery.ts`) adds `at_pickup` and `failed`, to match the blueprint's own status table in section 5, and keeps driver personal data and precise location out of the main record, as the note under the type asks.

## 12. Launch and growth strategy

All business activity. Nothing here is code.

| Item | Status |
|---|---|
| Interview 15 to 20 potential buyers and sellers | Owner |
| Recruit about 20 to 30 pilot businesses | Owner |
| Create and verify their storefronts, seed listings with permission | Owner, using staff tools (admin panel Planned) |
| Pilot enquiries before promising delivery | Owner |
| One-provider delivery pilot under written agreement | Owner / External |
| Measure, fix, then expand | Owner |
| KPIs: liquidity, conversion, delivery, trust and safety, customer experience, business health | Planned: staff reporting views (not built) |
| Go-to-market: retailers, simple onboarding, local social media and QR codes, safety guidance, no fake reviews or unconfirmed coverage | Owner. No fake reviews or inflated counts exist in the code; seed data contains only categories and locations. |

## 13. Pre-launch checklist

| Item | Status |
|---|---|
| MVP scope documented and user-tested | Documented here; user testing Owner |
| Seller onboarding and moderation processes | Moderation logic Built; staff process Owner |
| Prohibited and restricted goods rules defined | Starter list only; Owner must define the real list |
| Support and escalation staffed | Owner |
| Delivery workflow tested end to end | R2 |
| Provider integration authorised and documented | External |
| RLS enabled and tested for every table | Enabled; test file written but not yet run |
| Admin MFA and role separation | Built in database; needs real check with a staff account |
| Secrets server-side | Built |
| Payment callbacks verified and reconciled | R3 |
| Privacy notice, data inventory, retention and deletion approved | Owner / External |
| Backups and restore tests | Owner |
| Vulnerability assessment and incident-response procedure | Owner / External |
| Location tracking limited to active deliveries and authorised viewers | Schema |
| All legal and commercial items | Owner / External |

## 14. Official resources

The blueprint lists the Data Protection Commission, CCPC, Bank of Zambia, PACRA and three ZambiaLII acts as starting points for the lawyer. They are reference material only.

## 15. Final recommendation

Followed: marketplace first, then delivery, then the business platform, and growth no faster than operations, security and compliance allow.

## Placeholders that need an owner decision

These numbers and lists are starter values chosen so the system works. None come from the blueprint.

- `listing.high_value_zmw` (10000), `listing.new_seller_days` (30), repeated-report threshold (3)
- Rate limits for listings, messages and reports
- Retention days (30 and 7) for delivery locations and similar data
- Prohibited-terms list (all set to "flag", none to "block")
- Whether electronics should need review before going live (currently they do not)
- Whether phone verification is required to post (off until an SMS provider exists)
- Lusaka area list and category list

## Admin and trust screens (added after the first hand-over)

Where: `mobile/app/admin/` for staff, and `app/verify`, `app/review`, `app/seller`, `app/dispute`, `app/appeal.tsx` for everyone else. Staff tools open from the Account tab, only for accounts with a row in `admin_roles`.

| Role | Screens |
|---|---|
| Any staff | Two-factor setup and sign-in |
| Moderator | Listings waiting for review, open reports (also support), appeals, risk flags |
| Support | Verification requests (ID and business, documents shown through short-lived links), disputes, open reports |
| Technical admin | Staff team (give or remove roles), pending approvals, audit log |
| Finance | None yet. Payments are Release 3. |

Honest limits:

- No action currently asks for a second person's approval, so the approvals list will stay empty until one is wired in.
- Overturning an appeal records the decision; putting the listing or account back is a separate button on the same card. Approving a listing that staff earlier removed may not bring it back live; check this when testing.
- Risk flags are only created by the repeated-report rule. The other signals in section 7B are not built.
- Verification documents are not deleted automatically yet. The database sets a delete-after date, but the job that removes the files is not written.
- The admin screens live in the phone app. A separate web panel is still an option.

## Known gaps in what exists

- Nothing in this repo has been run (20 tests pass for the plain logic, including admin and trust rules; every screen is untested). SQL has not met a Postgres server; the app has not been compiled or opened. Only the pure TypeScript in `mobile/src/domain` has been type-checked and tested.
- Expo package versions were chosen from memory and need `npx expo install --fix`.
- No edge functions exist yet (photo hashing, file purge after retention, provider webhooks, payment callbacks, push notifications).
- `pg_cron` schedules for `purge_expired_data` are not set up.
- Anonymous browsing is off: you need an account to see listings. The blueprint does not say either way; this was a safety-first choice and can be changed.
