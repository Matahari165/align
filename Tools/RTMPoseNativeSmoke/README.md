# RTMPose native smoke harness

This harness performs one in-process arm64 macOS invocation of the isolated C
bridge with the official RTMPose-M Halpe26 ONNX asset and ONNX Runtime dylib.
It also checks the deterministic crop/projection contract and the no-person
gate. It never opens a camera and does not persist frames, tensors or output
coordinates.

From the repository root (`Align/`):

```sh
clang -std=c17 -Wall -Wextra -Werror \
  -IAlign/Pose/RTMPose -IAlign/Pose/RTMPose/Support \
  Align/Pose/RTMPose/rtmpose_onnx_bridge.c \
  Tools/RTMPoseNativeSmoke/rtmpose_onnx_bridge_harness.c \
  -ldl -o /private/tmp/rtmpose_onnx_harness
/private/tmp/rtmpose_onnx_harness \
  Align/Pose/RTMPose/Models/rtmpose-m-halpe26-end2end.onnx \
  Align/Pose/RTMPose/Models/libonnxruntime.1.19.2.dylib
```

Expected output includes:

```text
RTMPose geometry: OK ...
RTMPose invoke: OK status=available valid=26/26 provider=CPU
RTMPose noPerson gate: OK
```

The model archive, hashes, source and licence caveats are recorded in
`Align/Pose/RTMPose/Models/RTMPose-NOTICE.txt`. Core ML execution is an explicit
unproven option; this smoke command intentionally exercises the verified CPU
path and never falls back silently to another pose engine.
