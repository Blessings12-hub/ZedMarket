# Getting ZedMarket into Google Play and the App Store

ZedMarket is a React Native (Expo) app, so the same code builds the Android app, the iPhone app and the web version. This page lists what is already set up in the repo, and what only you can do. Store rules change often: **check each store's current rules before you submit.** Items marked (verify) are ones I am not fully sure about.

## 1. Already set up in the repo
- App name, Android package and iPhone bundle ID `com.zedmarket.app`. **Choose the final ID before your first upload. It cannot be changed afterwards.**
- `mobile/eas.json`: a `preview` build (an Android `.apk` you can install to test) and a `production` build (an Android `.aab` for Google Play and an iPhone build for the App Store). Version numbers go up by themselves on production builds.
- `android.versionCode` and `ios.buildNumber` start at 1.
- Placeholder icon, Android adaptive icon, splash image and web icon in `mobile/assets/`. **They are a plain white "Z" on green. Replace them with your real logo, same file names and sizes** (icon 1024x1024 with no transparency; adaptive icon 1024x1024 transparent with the logo inside the middle two thirds; splash 1024x1024 transparent).
- The camera and microphone permissions are switched off, because the app only picks photos from the gallery. This keeps the permission list, and the store forms, shorter.
- The unused location package was removed, so the app does not ask for location. Add it back only when a feature really uses it, and then update the store forms.
- `ITSAppUsesNonExemptEncryption` is set to false, which tells Apple the app uses only standard HTTPS encryption (verify with Apple's export rules).
- Delete my account is inside the app (Account, Security and login), which both stores expect.
- Report and block, staff moderation, and safety tips are in the app, which stores look for in apps with user content.

## 2. What you must do first
1. Create an Expo account (free) at expo.dev and install the EAS CLI on a computer, or ask a friend with a computer to run the builds: `npm install -g eas-cli`, then in the `mobile` folder `eas login`, `eas init` (this adds your project ID to `app.json`), then `eas build --profile preview --platform android`.
2. Install the `preview` build on a real Android phone and use the app properly. **The app has not been run on a phone yet.** Fix what breaks before anything else.
3. Set the Supabase address and key for builds: in expo.dev, your project, Environment variables, add `EXPO_PUBLIC_SUPABASE_URL` and `EXPO_PUBLIC_SUPABASE_ANON_KEY` (and `EXPO_PUBLIC_WEB_URL` for share links).
4. Push notifications are not ready: the `expo-notifications` package is not installed and no Firebase file is set up. Until you add them, the app works without push.

## 3. Google Play
1. Create a Play Console developer account (one-time fee, verify the amount). Google asks for identity checks. Personal accounts created recently may need a closed test with a minimum number of testers for a minimum number of days before you can release publicly (verify the current numbers).
2. Make a new app and fill in the store listing: name, short and full description, icon 512x512, feature graphic 1024x500, at least two phone screenshots.
3. **Privacy policy:** a public web address is required. The in-app text is a draft; have a Zambian lawyer approve it, put it on a web page, and paste the link.
4. **Data safety form.** Be honest. ZedMarket collects: name, email address, the profile details people add, photos they upload, messages, orders, delivery addresses, and crash reports. Sellers also upload identity and business documents. Data is sent to Supabase. People can delete their account.
5. **Account deletion:** Google asks for the in-app way (done) and a public web page where someone can ask for deletion without installing the app (verify). Make a simple page that tells people to email or use a form, and paste the link.
6. Content rating questionnaire: it is a marketplace with user chat and user content. Answer truthfully.
7. Upload the `.aab` from `eas build --profile production --platform android`, add testers, then promote it.

## 4. Apple App Store
1. Join the Apple Developer Program (yearly fee, verify the amount). You can build and submit without a Mac through EAS: `eas build --profile production --platform ios`, then `eas submit`.
2. In App Store Connect create the app with the same bundle ID. Fill in: description, keywords, screenshots for the required iPhone sizes, privacy policy link, support link, age rating.
3. **App Privacy ("nutrition label")**: the same data list as above.
4. **App review:** Apple reviewers need to sign in. Create a **demo buyer account and a demo seller account** with real passwords and write them in the review notes, with a short explanation that sellers are verified by your team. Apple can reject marketplaces that look unmoderated. Your report, block and moderation tools help; mention them in the notes.
5. Account deletion inside the app is required by Apple (done).

## 5. Both stores
- Support email address and a working support route (Help in the app).
- A page for terms of use, approved by your lawyer.
- Screenshots that show real listings. Do not use other companies' logos or photos you do not own.
- Business rules: ZedMarket lists items and services between people. Tell the stores that payments between buyers and sellers happen outside the app, since no payment provider is connected. If you add in-app payments later for digital goods, read each store's payment rules first (verify).

## 6. Before you press submit
- [ ] Real logo in `mobile/assets/`
- [ ] Final package name / bundle ID chosen
- [ ] Tested on a real phone: sign up, sign in, post as a verified seller, chat, order, delete account
- [ ] Lawyer-approved Terms and Privacy, published on a web page
- [ ] Supabase migrations all run on the live project, and backups switched on (see `docs/BACKUPS.md`)
- [ ] Demo accounts for the reviewers
- [ ] Data safety and App Privacy forms answered honestly
