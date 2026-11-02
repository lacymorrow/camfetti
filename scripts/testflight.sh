#!/bin/bash
# Archive a Release build and upload it to App Store Connect (TestFlight).
# Usage: scripts/testflight.sh [export]   ("export" builds the signed IPA without uploading)
# Auth: set ASC_KEY_ID and ASC_ISSUER_ID (or put them in ~/.appstoreconnect/env), with the key in ~/.appstoreconnect/private_keys.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f "$HOME/.appstoreconnect/env" ] && source "$HOME/.appstoreconnect/env"
KEY_ID="${ASC_KEY_ID:?set ASC_KEY_ID}"
ISSUER="${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
KEY="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
DEST="upload"; [ "${1:-}" = "export" ] && DEST="export"
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")
# Builds 1 to 9 came from the history before the public repo started.
BUILD="$((9 + $(git rev-list --count HEAD)))"
ARCHIVE="build/CamFetti-$BUILD.xcarchive"

xcodegen generate --quiet
xcodebuild -scheme CamFetti -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" CURRENT_PROJECT_VERSION="$BUILD" "${AUTH[@]}" -quiet archive
echo "OK archive build $BUILD"

sed "s/DESTINATION/$DEST/" scripts/ExportOptions-AppStore.plist > build/ExportOptions.plist
rm -rf build/appstore
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath build/appstore \
  -exportOptionsPlist build/ExportOptions.plist "${AUTH[@]}" -quiet
echo "OK $DEST build $BUILD"
