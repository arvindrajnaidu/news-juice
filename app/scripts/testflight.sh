#!/usr/bin/env bash
# Archive the iOS app, export an App Store IPA, and upload it to TestFlight.
# Uses an App Store Connect API key, so no interactive Apple ID login is needed.
#
#   npm run testflight
#
# Overridable via env:
#   ASC_ISSUER_ID  App Store Connect API issuer id
#   ASC_KEY_ID     API key id (key file at ~/.appstoreconnect/private_keys/AuthKey_<id>.p8)
#   ASC_TEAM_ID    Apple Developer team id (Buzzie LLC)
#   BUILD_NUMBER   CFBundleVersion (default: timestamp, unique per upload)
#
# One-time prereq: an app with bundle id com.buzzie.newslens exists in App Store
# Connect (Apple's API can't create app records). The key needs Admin access so
# cloud signing can create the iOS Distribution certificate if it's missing.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${ASC_TEAM_ID:-P3F54L5BAH}"
KEY_ID="${ASC_KEY_ID:-GN653SWQKQ}"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-69a6de7e-a2a9-47e3-e053-5b8c7c11a4d1}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
ARCHIVE="ios/build/App.xcarchive"
EXPORT_DIR="ios/build/export"

[ -f "$KEY_PATH" ] || { echo "Missing API key: $KEY_PATH"; exit 1; }

AUTH=(-allowProvisioningUpdates
  -authenticationKeyPath "$KEY_PATH"
  -authenticationKeyID "$KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID")

npm run sync

echo "▸ Archiving (build $BUILD_NUMBER, team $TEAM_ID)…"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild -project ios/App/App.xcodeproj -scheme App -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" DEVELOPMENT_TEAM="$TEAM_ID" \
  "${AUTH[@]}" archive

echo "▸ Exporting IPA…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist ios/ExportOptions.plist -exportPath "$EXPORT_DIR" "${AUTH[@]}"

[ "${SKIP_UPLOAD:-}" = 1 ] && { echo "Skipping upload; IPA at $EXPORT_DIR/App.ipa"; exit 0; }

echo "▸ Uploading to TestFlight…"
xcrun altool --upload-app -f "$EXPORT_DIR/App.ipa" -t ios \
  --apiKey "$KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "✅ Uploaded build $BUILD_NUMBER. It appears in TestFlight once Apple finishes processing."
