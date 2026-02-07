#!/bin/sh
# Upload SecureNode.ipa to TestFlight.
# Requires: APPLE_ID and APP_SPECIFIC_PASSWORD (from https://appleid.apple.com/account/manage).
# Usage: APPLE_ID=your@email.com APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx ./upload-testflight.sh

set -e
cd "$(dirname "$0")"
IPA="${1:-build/Export/SecureNode.ipa}"
if [ ! -f "$IPA" ]; then
  echo "IPA not found: $IPA. Run archive and export first."
  exit 1
fi
if [ -z "$APPLE_ID" ] || [ -z "$APP_SPECIFIC_PASSWORD" ]; then
  echo "Set APPLE_ID and APP_SPECIFIC_PASSWORD (app-specific password from appleid.apple.com)."
  exit 1
fi
xcrun altool --upload-app --type ios --file "$IPA" --username "$APPLE_ID" --password "$APP_SPECIFIC_PASSWORD"
