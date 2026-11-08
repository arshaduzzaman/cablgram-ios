# Cablgram for iOS

SwiftUI app. Everyone signs in with Google first. The layout follows the Facebook app: a "cablgram" bar on top, icon tabs under it.

- **News** (home icon): the Cablgram post feed from `https://www.cablgram.com/api/facebook-posts`, the same one the website shows. Pull to refresh, scroll for more, tap to open, or share.
- **Walk**: everything about walking, in three sections:
  - **Rewards**: steps from Apple Health since you joined unlock Liberty Pizza Slice and Uncle Bobo's Chicken (10,000), Smashed Chicken Burger (15,000), GTA 6 (75,000) and PlayStation 5 (100,000). Edit the list in `Cablgram/Walk/Rewards.swift`.
  - **Routes**: map of your home and usual places, with walks that reach your daily goal.
  - **Leaderboard**: everyone's steps, all time and today, live from Firestore.
- **Menu**: your profile, stats, claimed rewards and sign out.

## Reward photos

Put each photo in `Cablgram/RewardImages/`, named after the reward id, and rebuild:

| Reward | File name |
| --- | --- |
| Liberty Pizza Slice | `liberty-pizza.jpg` |
| Uncle Bobo's Chicken | `unclebobos-chicken.jpg` |
| Smashed Chicken Burger | `smashed-chicken-burger.jpg` |
| GTA 6 | `gta-6.jpg` |
| PlayStation 5 | `ps5.jpg` |

`.png` works too. Square photos look best. Until a photo is added the card shows an icon. Only use photos you have permission to use (from the partner, or your own).

## Firebase: Google sign-in and the leaderboard

The app uses the same Firebase project as the website (`cablgram-6808a`).

1. Firebase console → Project settings → Your apps → **Add app → iOS**, bundle id `com.cablgram.app`. Download `GoogleService-Info.plist` into `Cablgram/` (it's git-ignored).
2. Copy `REVERSED_CLIENT_ID` from that file into `GOOGLE_REVERSED_CLIENT_ID` in `App.xcconfig` (needed for Google to return to the app).
3. Authentication → Sign-in method → enable **Google**.
4. Firestore → Rules: add the `walkers` block from `firestore.rules` to your existing rules. Don't replace them; the website uses the same database.

Without `GoogleService-Info.plist`, debug builds show a "Skip for now" button so you can still test.

Steps are sent from the phone, so a determined cheater could fake them. The rules cap the numbers, but real prize payouts need a server-side check first.

## Maps: Google, with an Apple Maps fallback

The Routes tab uses **Google Maps** (map, walking routes, place search) when an API key is set, the same platform inDrive uses. Without a key it falls back to Apple Maps. Apple Maps has no walking directions in Dhaka, so those routes are straight-line estimates (dashed, tagged "Estimated").

To turn on Google Maps:

1. In the [Google Cloud console](https://console.cloud.google.com/google/maps-apis), create a project with billing, and enable **Maps SDK for iOS**, **Routes API** and **Places API (New)**.
2. Create an API key. Restrict it to iOS apps with bundle id `com.cablgram.app`, and to those three APIs.
3. Copy `Secrets.example.xcconfig` to `Secrets.xcconfig` and paste the key. `Secrets.xcconfig` is git-ignored, so the key never lands on GitHub.
4. Build and run.

If Google rejects a request (wrong key, API not enabled), the error appears in red under the walk suggestions and the app falls back to Apple Maps.

## Run it

1. Install Xcode 16 or newer.
2. Open `Cablgram.xcodeproj` and pick an iPhone simulator. The first build downloads the Google Maps SDK.
3. Press Run (⌘R).

The Simulator has no real steps, so debug builds include buttons to add test steps, and a button on the Routes tab to load sample Dhaka places.

To run on a real iPhone, choose your team under **Signing & Capabilities**. HealthKit is already turned on in `Cablgram.entitlements`.

## Not built yet

- Claiming a reward is only saved on the phone. Delivering real prizes needs server-side step checks (to stop cheating) and voucher or shipping details for partners.

## TestFlight (Xcode Cloud)

Xcode Cloud builds the app on Apple's servers and sends it to TestFlight, so you don't need the latest Xcode on your Mac. `ci_scripts/ci_post_clone.sh` recreates the two git-ignored files from secret environment variables set on the workflow:

| Variable | Value |
| --- | --- |
| `GOOGLE_MAPS_API_KEY` | your Google Maps key |
| `GOOGLE_SERVICE_INFO_PLIST_BASE64` | output of `base64 -i Cablgram/GoogleService-Info.plist` |

It also sets the build number from Xcode Cloud, so every upload is accepted.
