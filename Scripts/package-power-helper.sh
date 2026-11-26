#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
app="$1"
bundle_id="$2"
identity="$3"
shift 3
root="$(cd "$(dirname "$0")/.." && pwd)"
service="$bundle_id.PowerMode"
helper="$app/Contents/MacOS/OmniWMPowerHelper"
plist="$app/Contents/Library/LaunchDaemons/$service.plist"

# Use the designated requirement of the signed app executable. This binds
# incoming connections to both this app identifier and its signing identity.
requirement="$(codesign -d -r- "$app/Contents/MacOS/OmniWM" 2>&1 | sed -n 's/^designated => //p')"
[[ -n "$requirement" && "$identity" != "-" ]]
literal="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$requirement")"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -Os -Wall -Wextra -Werror -fobjc-arc \
    "-DPOWER_CLIENT_REQUIREMENT=$literal" "-DPOWER_SERVICE_NAME=\"$service\"" \
    -I "$root/Sources/OmniWMPowerMode/include" "$root/Sources/OmniWMPowerHelper/main.m" \
    -framework Foundation -framework SystemConfiguration -o "$helper"
codesign --force --options runtime --identifier "$service" --sign "$identity" "$@" "$helper"
mkdir -p "$(dirname "$plist")"
python3 - "$plist" "$service" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as stream:
    plistlib.dump({"Label": sys.argv[2], "BundleProgram": "Contents/MacOS/OmniWMPowerHelper",
                   "MachServices": {sys.argv[2]: True}}, stream)
PY
