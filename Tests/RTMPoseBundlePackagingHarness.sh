#!/bin/sh
set -eu

app=${1:?usage: RTMPoseBundlePackagingHarness.sh /path/to/Align.app}
contents="$app/Contents"
resources="$contents/Resources"
frameworks="$contents/Frameworks"
binary="$contents/MacOS/Align.debug.dylib"

test "$(/usr/libexec/PlistBuddy -c 'Print :UpperBodyEngineIdentifier' "$contents/Info.plist")" = \
  "rtmpose-m-halpe26"
test -f "$resources/rtmpose-m-halpe26-end2end.onnx"
test -f "$resources/RTMPose-NOTICE.txt"
test -f "$resources/ONNXRuntime-LICENSE.txt"
test -f "$resources/ThirdPartyNotices.txt"
test -f "$frameworks/libonnxruntime.1.19.2.dylib"

model_hash=$(shasum -a 256 "$resources/rtmpose-m-halpe26-end2end.onnx" | awk '{print $1}')
test "$model_hash" = "26f3a19e61304a600dfb82d1001d41d24343b89fc70a33ffc84657e0b0bf2ecf"

test ! -e "$frameworks/libLiteRt.dylib"
test ! -e "$resources/pose_detector.tflite"
test ! -e "$resources/pose_landmarks_detector.tflite"
if otool -L "$binary" | grep -q 'libLiteRt'; then
  echo "RTMPoseBundlePackagingHarness: FAIL — dépendance LiteRT résiduelle" >&2
  exit 1
fi
if ! strings "$binary" | grep -q 'rtmpose-m-halpe26'; then
  echo "RTMPoseBundlePackagingHarness: FAIL — moteur RTMPose non identifiable" >&2
  exit 1
fi

echo "RTMPoseBundlePackagingHarness: OK"
