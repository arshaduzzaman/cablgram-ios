# Cablgram for iOS

SwiftUI app with two tabs:

- **News**: the Cablgram post feed from `https://www.cablgram.com/api/facebook-posts`, the same one the website's home page shows. Pull to refresh, scroll to load more, tap a post to open it.
- **Walk**: reads steps from Apple Health. Steps taken since you first open the app unlock rewards, from a 5,000-step badge up to a PlayStation 5 at 100,000 steps. Edit the prize list in `Cablgram/Walk/Rewards.swift`.
- **Routes**: a map of your home and the places you go often (saved only on the phone). It suggests walks from home through one or two of those places that reach your daily step goal, and draws the selected walk on the map. Where Apple Maps has no walking directions (currently the case for the Dhaka places tested), it falls back to a straight-line estimate, shown dashed and tagged "Estimated".

## Run it

1. Install Xcode 16 or newer from the App Store.
2. Open `Cablgram.xcodeproj` and pick an iPhone simulator.
3. Press Run (⌘R).

The Simulator has no real steps, so debug builds include buttons to add test steps, and a button on the Routes tab to load sample Dhaka places.

To run on a real iPhone, choose your team under **Signing & Capabilities**. HealthKit is already turned on in `Cablgram.entitlements`.

## Not built yet

- Claiming a reward is only saved on the phone. Delivering real prizes needs a backend with accounts, server-side step checks (to stop cheating), and shipping details.
- App icon (`Assets.xcassets/AppIcon`) is empty.
