#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
  echo "Xcode introuvable : $DEVELOPER_DIR" >&2
  exit 1
fi

derived_data=$(mktemp -d /private/tmp/align-verify.XXXXXX)
trap 'rm -rf "$derived_data"' EXIT HUP INT TERM

cd "$repo_root"
echo "== Build Release =="
"$DEVELOPER_DIR/usr/bin/xcodebuild" \
  -project Align.xcodeproj \
  -scheme Align \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

app_path="$derived_data/Build/Products/Release/Align.app"
if [ ! -d "$app_path" ]; then
  echo "Bundle Release introuvable : $app_path" >&2
  exit 1
fi

echo "== RTMPose bundle =="
Tests/RTMPoseBundlePackagingHarness.sh "$app_path"

echo "== Upper-body inference worker =="
Tests/UpperBodyInferenceWorkerHarness.sh

echo "Verification Align : OK"
