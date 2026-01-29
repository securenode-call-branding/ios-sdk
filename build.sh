#!/bin/bash
# Build SecureNode app. Use custom DerivedData in repo to avoid permission issues.
set -e
cd "$(dirname "$0")"
DERIVED="$(pwd)/DerivedData"
mkdir -p "$DERIVED"
export DERIVED_DATA_PATH="$DERIVED"
xcodebuild -project SecureNode.xcodeproj -scheme SecureNode -destination 'generic/platform=iOS' -configuration Debug build
echo "Build succeeded. Run the app from Xcode (Cmd+R) or install to a device/simulator."
