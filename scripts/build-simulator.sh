#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DESTINATION="generic/platform=iOS Simulator"
if [[ $# -gt 0 ]]; then
  BUILD_DESTINATION="platform=iOS Simulator,name=$1"
fi
xcodebuild -project SpeedometerGPS.xcodeproj -scheme SpeedometerGPS \
  -configuration Debug -destination "$BUILD_DESTINATION" \
  -derivedDataPath "${SPIDERROUTE_DERIVED_DATA:-/tmp/spiderroute-public-build}" \
  CODE_SIGNING_ALLOWED=NO build
