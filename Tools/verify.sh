#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$repo_root"
if [ "${ALIGN_SKIP_PRIVATE_MODEL:-0}" = "1" ]; then
  echo "== Modèle RTMPose privé ignoré pour la CI publique =="
else
  echo "== Modèle RTMPose local =="
  Tools/setup-local-model.sh
fi

if [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
  echo "Xcode introuvable : $DEVELOPER_DIR" >&2
  exit 1
fi

derived_data=$(mktemp -d /private/tmp/align-verify.XXXXXX)
trap 'rm -rf "$derived_data"' EXIT HUP INT TERM

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

if [ "${ALIGN_SKIP_PRIVATE_MODEL:-0}" = "1" ]; then
  if find "$app_path" \( -name 'rtmpose-m-halpe26-end2end.onnx' -o -name 'rtmpose-m-halpe26-native-*.mlmodelc' -o -name 'rtmpose-m-halpe26-native-*.mlpackage' \) -print -quit | grep -q .; then
    echo "Le bundle public ne doit pas contenir le modèle RTMPose privé." >&2
    exit 1
  fi
else
  echo "== RTMPose bundle =="
  Tests/RTMPoseBundlePackagingHarness.sh "$app_path"
fi

echo "== Upper-body inference worker =="
Tests/UpperBodyInferenceWorkerHarness.sh

echo "Verification Align : OK"
