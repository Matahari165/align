#!/bin/sh
set -eu

app=${1:?usage: RTMPoseCoreMLBundleHarness.sh /path/to/Align.app}
resources="$app/Contents/Resources"
test -d "$resources/rtmpose-m-halpe26-native-fp32.mlmodelc"
test -d "$resources/rtmpose-m-halpe26-native-int8.mlmodelc"
test ! -e "$resources/rtmpose-m-halpe26-native-fp16.mlmodelc"
test -f "$resources/rtmpose-m-halpe26-end2end.onnx"
echo "RTMPoseCoreMLBundleHarness: OK (FP32 + INT8, private model remains local)"
