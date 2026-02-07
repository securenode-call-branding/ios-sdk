#!/bin/sh
# Stream logs from a connected iOS device — use Console.app (no brew required).
#
# 1. Connect the device and run your app (Xcode Cmd+R).
# 2. In Xcode: Window → Devices and Simulators.
# 3. Select your device → Open Console.
# 4. In the filter box, type:  SecureNode   or   call directory
# 5. Trigger a sync in the app; watch for "call directory snapshot: written N entries" and "call directory reload: ok N entries".

echo "Device logs: use Console.app (no brew needed)"
echo ""
echo "  Xcode → Window → Devices and Simulators → [your device] → Open Console"
echo "  Filter: SecureNode   or   call directory"
echo ""
open -a Console 2>/dev/null || echo "Open Console.app from Applications/Utilities, then select your device in the sidebar."
