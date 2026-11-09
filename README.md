# Cablgram for iOS

SwiftUI app. Everyone signs in with Google first. The layout follows the Facebook app: a "cablgram" bar on top, icon tabs under it.

- **News** (home icon): the Cablgram posts (the same feed the website shows, read straight from the Nutshell API) as a Threads-style feed. Hold a photo and 🥚 Egg and ✍️ Headline pop up above your finger: slide onto 🥚 and let go to throw a rotten egg where you pressed (50 steps), or onto ✍️ to write a headline for the post (500+ steps; the most steps wins the spot above the photo). Spent steps come off reward progress, not the leaderboard. Eggs and headlines are shared through Firestore (`newsPosts/{postId}`).
- **Walk**: everything about walking on one scrolling page: the reward you picked and steps to go, a race to it against other walkers, a Start a walk button for a live walk on the map, a leaderboard preview with "See all", and rewards. Uncle Bobo's Chicken (10,000), Liberty Pizza Slice and Smashed Chicken Burger (15,000), GTA 6 (75,000) and PlayStation 5 (500,000). Edit the list in `Cablgram/Walk/Rewards.swift`.
- **Discover** (ticket icon): events on now and coming up in Bangladesh, read from [tickify.live](https://tickify.live)'s public events page: Tickify's featured banners, category chips, and each event's poster, dates, venue and price. Tapping one opens its Tickify page to get tickets. Code in `Cablgram/Discover/`.
- **Menu**: your profile, stats, claimed rewards, a Haptics switch and sign out.

Haptic feedback (`Cablgram/Shared/Haptics.swift`) plays on taps, selections and tab changes, and a celebration buzz plays when you claim or unlock a reward, reach a step milestone on a walk, or move up the leaderboard.

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

Without `GoogleService-Info.plist`, debug builds show a "Skip for now" button so you can still test. Debug builds also accept a `-skipSignIn` launch argument for checking screens in the Simulator.

Steps are sent from the phone, so a determined cheater could fake them. The rules cap the numbers, but real prize payouts need a server-side check first.

## Maps: Google, with an Apple Maps fallback

A walk shows a black-and-white **Google Map** that follows you when an API key is set. Without a key it uses Apple Maps.

To turn on Google Maps:

1. In the [Google Cloud console](https://console.cloud.google.com/google/maps-apis), create a project with billing and enable **Maps SDK for iOS**.
2. Create an API key. Restrict it to iOS apps with bundle id `com.cablgram.app`.
3. Copy `Secrets.example.xcconfig` to `Secrets.xcconfig` and paste the key. `Secrets.xcconfig` is git-ignored, so the key never lands on GitHub.
4. Build and run.

## Run it

1. Install Xcode 16 or newer.
2. Open `Cablgram.xcodeproj` and pick an iPhone simulator. The first build downloads the Google Maps SDK.
3. Press Run (⌘R).

The Simulator has no real steps, so debug builds include buttons to add test steps.

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
