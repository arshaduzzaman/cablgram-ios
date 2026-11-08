# Cablgram for iOS

SwiftUI app with three tabs:

- **News**: the Cablgram post feed from `https://www.cablgram.com/api/facebook-posts`, the same one the website's home page shows. Pull to refresh, scroll to load more, tap a post to open it, or share it.
- **Walk**: reads steps from Apple Health. Steps taken since you first open the app unlock rewards, from a 5,000-step badge, through free food from partners (Uncle Bobo's chicken and a Liberty Pizza slice at 10,000 steps), up to a PlayStation 5 at 100,000 steps. Edit the prize list in `Cablgram/Walk/Rewards.swift`.
- **Routes**: a full-screen map of your home and the places you go often (saved only on the phone). A bottom panel suggests walks from home through one or two of those places that reach your daily step goal; tap one to draw it on the map.

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

- Claiming a reward is only saved on the phone. Delivering real prizes needs a backend with accounts, server-side step checks (to stop cheating), and shipping or voucher details for partners.
- App icon (`Assets.xcassets/AppIcon`) is empty.
