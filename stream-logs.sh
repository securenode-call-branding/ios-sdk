#!/bin/sh
# Stream console logs from the booted iOS Simulator. Run the app first (Cmd+R), then: ./stream-logs.sh
# Optional: pass a filter string, e.g. ./stream-logs.sh "call directory"

FILTER="${1:-SecureNode|call directory|snapshot|reload|sync}"
echo "Streaming simulator logs (matching: $FILTER) — Ctrl+C to stop"
echo "If no output: ensure a simulator is booted and the app is running (Cmd+R in Xcode)."
xcrun simctl spawn booted log stream --level debug 2>/dev/null | grep --line-buffered -iE "$FILTER" || true
