# Connectivity fix: MTN, Airtel, Zamtel

## Status: partly investigated, NOT yet verified on any Zambian network

I could not run anything on MTN, Airtel or Zamtel data. The work was done from a cloud server outside Zambia, so
the real-network tests in the brief are still to be done by a person with SIMs. Nothing below should be read as
"fixed on MTN". It is "hardened against the failure types mobile networks cause, and the server side looks healthy".

## What was checked

| Check | Result |
|---|---|
| Supabase project `ZedMarket` (eu-west-1) | Status ACTIVE_HEALTHY |
| Supabase edge logs, 26 Nov, ~2,000 requests | Almost all 200. Auth, REST, storage, realtime (101) all served. Requests came from several IPs including ones in ranges that look local (45.215.x.x, 102.212.x.x). I believe these are Zambian but have not verified the ISP of each. |
| Errors in those logs | One `400` on `/auth/v1/token` (normally a wrong password) and two `300` on `/rest/v1/favourites` (see below). No 403, 429 or 5xx. |
| Vercel project, domain, DNS, certificate, firewall | NOT checked. Vercel asked you to approve access for team `blessings-dev` (link was shown to you). Until that is approved I cannot read these. |
| DNS comparison MTN vs Airtel, TLS from each network | NOT possible from here (outbound requests are restricted). |

## Most likely causes (not confirmed)

Because Supabase is serving Zambian-looking traffic fine, the failure is more likely on the path to the web host or
in how the app copes with weak connections. Candidates, in order of how likely I think they are:

1. Short connection drops or slow responses with no retry. The app made a single attempt with no time limit.
2. DNS or routing for the web domain on one network. Needs the Vercel and domain details.
3. A network-level block or slow route to a Cloudflare, Vercel or Supabase address on MTN. Needs a test on MTN.

## What changed

- `mobile/src/lib/resilientFetch.ts` (new): every Supabase request now has a 20 second limit (60 for uploads).
  Reads, sign-in token calls and read-only database functions retry up to 3 times with a growing pause after a network
  error, timeout, 408, 425, 429, 502, 503 or 504. Anything that changes data is never repeated automatically, so an
  order or message cannot be created twice.
- `mobile/src/lib/supabase.ts`: uses that fetch for auth, database, storage and realtime HTTP calls.
- `mobile/src/lib/storage.ts` (new): photo reading and uploading with retry. If a first attempt reached the server and
  the repeat gets "already exists", it counts as success. Used for listing photos, avatars, seller ID, business
  documents and dispute or support evidence. Uploads now carry a one-year cache header (file names are unique).
- `mobile/src/components/RetryImage.tsx` (new): listing images retry 3 times if they fail to load. Used on listing
  cards and the listing page.
- `mobile/src/lib/errors.ts`: clearer messages for timeouts and gateway errors.
- `mobile/src/features/listings/api.ts`: Saved items query now names the exact relationship, because the server
  returned HTTP 300 (ambiguous relationship) for it twice. This is a real bug, though not a network one. Not
  verified against the live database; check the Saved screen after deploying.
- `mobile/vercel.json` (new): builds the web version, sends every route to `index.html`, and caches static files for a year.
  If your Vercel project already sets these in its dashboard, check they do not clash. Root directory must be `mobile`.
- `mobile/src/lib/resilientFetch.test.ts` (new): 6 tests.

## Tests run here

- Typecheck: passes.
- Unit tests: 257 pass, 0 fail (including the 6 new ones).
- Web export builds.

## Still to do (needs you or a phone on each network)

1. Approve the Vercel access link so DNS, certificate, firewall and logs can be checked.
2. On MTN, Airtel, Zamtel and Wi-Fi, test: home page, sign-in, browsing, seller registration, account changes,
   photo upload, saving an item, placing an order. Record results in the table below.
3. If MTN still fails, note exactly which URL fails (the web domain, `*.supabase.co`, or images) and the error shown.
4. Check Supabase Auth rate limits and the Cloudflare or Vercel firewall for blocks on Zambian networks.

| Test | MTN | Airtel | Zamtel | Wi-Fi |
|---|---|---|---|---|
| Home page | | | | |
| Sign-in | | | | |
| Browse products | | | | |
| Seller registration | | | | |
| Account management | | | | |
| Image upload | | | | |
| Saved items / orders | | | | |
