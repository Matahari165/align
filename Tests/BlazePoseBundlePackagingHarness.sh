#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 /chemin/Align.app lite|full" >&2
  exit 2
fi

app_path=$1
expected_variant=$2
info_path="$app_path/Contents/Info.plist"
resources_path="$app_path/Contents/Resources"
framework_path="$app_path/Contents/Frameworks/libLiteRt.dylib"
executable_path="$app_path/Contents/MacOS/Align"

case "$expected_variant" in
  lite)
    detector_name=pose_detector.tflite
    detector_hash=46837eb883e6ec75b52c5f5ff6a9b78bd35e66c13f95e8c3566c582d146cb1d9
    landmarks_name=pose_landmarks_detector.tflite
    landmarks_hash=ad6cfd3c903eb31a4ee788b809e45ecf9fa69923b69b9f3f2d9ae616ff433e58
    ;;
  full)
    detector_name=pose_detector_full.tflite
    detector_hash=04f5a96483f8ce5913f8730ad2aa0c4c999c80a4b75653bc0e4712de18e104b2
    landmarks_name=pose_landmarks_detector_full.tflite
    landmarks_hash=82be6d591b9dad7d29fe21dc9fd892bf8b9602c458fb05209283de8282a0c488
    ;;
  *)
    echo "Variante attendue invalide : $expected_variant" >&2
    exit 2
    ;;
esac

test -f "$info_path"
if actual_variant=$(/usr/bin/plutil -extract BlazePoseModelVariant raw "$info_path" 2>/dev/null); then
  if [ "$actual_variant" != "$expected_variant" ]; then
    echo "Bundle $expected_variant annoncé comme $actual_variant" >&2
    exit 1
  fi
fi

test -f "$resources_path/LICENSE-Apache-2.0.txt"
test -f "$resources_path/NOTICE.txt"
test -f "$framework_path"
test -f "$executable_path"

verify_hash() {
  file_path=$1
  expected_hash=$2
  actual_hash=$(/usr/bin/shasum -a 256 "$file_path" | /usr/bin/awk '{ print $1 }')
  if [ "$actual_hash" != "$expected_hash" ]; then
    echo "SHA-256 inattendu pour $file_path" >&2
    exit 1
  fi
}

verify_hash "$resources_path/$detector_name" "$detector_hash"
verify_hash "$resources_path/$landmarks_name" "$landmarks_hash"
if [ "$expected_variant" = lite ]; then
  test ! -e "$resources_path/pose_detector_full.tflite"
  test ! -e "$resources_path/pose_landmarks_detector_full.tflite"
fi

runtime_id=$(/usr/bin/otool -D "$framework_path" | /usr/bin/tail -n 1)
if [ "$runtime_id" != "@rpath/libLiteRt.dylib" ]; then
  echo "Install name LiteRT inattendu : $runtime_id" >&2
  exit 1
fi

linked_image=$executable_path
if ! /usr/bin/otool -L "$linked_image" | /usr/bin/grep -q '@rpath/libLiteRt.dylib'; then
  debug_image="$app_path/Contents/MacOS/Align.debug.dylib"
  if [ -f "$debug_image" ]; then
    linked_image=$debug_image
  fi
fi
if ! /usr/bin/otool -L "$linked_image" | /usr/bin/grep -q '@rpath/libLiteRt.dylib'; then
  echo "Le binaire de l’application ne référence pas @rpath/libLiteRt.dylib" >&2
  exit 1
fi
if ! /usr/bin/otool -l "$linked_image" |
    /usr/bin/grep -A 2 'cmd LC_RPATH' |
    /usr/bin/grep -q 'path @executable_path/../Frameworks'; then
  echo "Le binaire ne résout pas @rpath dans Contents/Frameworks" >&2
  exit 1
fi

echo "BlazePoseBundlePackagingHarness: OK ($expected_variant)"
