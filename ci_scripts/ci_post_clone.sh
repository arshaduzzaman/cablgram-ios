#!/bin/sh
# Xcode Cloud runs this right after cloning the repo.
#
# Secrets.xcconfig and GoogleService-Info.plist are git-ignored, so they're
# rebuilt here from secret environment variables set on the Xcode Cloud
# workflow (App Store Connect → Xcode Cloud → workflow → Environment):
#   GOOGLE_MAPS_API_KEY               the Google Maps key
#   GOOGLE_SERVICE_INFO_PLIST_BASE64  GoogleService-Info.plist, base64-encoded
set -e
cd "$CI_PRIMARY_REPOSITORY_PATH"

if [ -n "$GOOGLE_MAPS_API_KEY" ]; then
  printf 'GOOGLE_MAPS_API_KEY = %s\n' "$GOOGLE_MAPS_API_KEY" > Secrets.xcconfig
  echo "Wrote Secrets.xcconfig"
else
  echo "warning: GOOGLE_MAPS_API_KEY not set; the app will use Apple Maps."
fi

if [ -n "$GOOGLE_SERVICE_INFO_PLIST_BASE64" ]; then
  printf '%s' "$GOOGLE_SERVICE_INFO_PLIST_BASE64" | base64 --decode > Cablgram/GoogleService-Info.plist
  echo "Wrote GoogleService-Info.plist"
else
  echo "error: GOOGLE_SERVICE_INFO_PLIST_BASE64 not set; Google sign-in would not work."
  exit 1
fi

# Every TestFlight upload needs a new build number; use Xcode Cloud's.
if [ -n "$CI_BUILD_NUMBER" ]; then
  sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER;/" Cablgram.xcodeproj/project.pbxproj
  echo "Build number set to $CI_BUILD_NUMBER"
fi
