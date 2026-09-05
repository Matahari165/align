#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/align-worker-harness.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
python3 - "$work_dir/WorkerTest.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Align/Camera/CameraCaptureService.swift').read_text()
generation = source[source.index('nonisolated private struct PoseProcessingGeneration'):source.index('nonisolated private enum PoseProcessingEvent')]
worker = source[source.index('/// Requête upper-body'):source.index('private enum CameraSessionStartResult')]
fixture = Path('Tests/UpperBodyInferenceWorkerHarness.swift').read_text()
Path(sys.argv[1]).write_text('import Foundation\n' + generation + worker + fixture)
PY
"$(xcrun --find swiftc)" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path "$work_dir/module-cache" \
  Align/Pose/PoseDetector.swift Align/Pose/FaceOrientation.swift \
  Align/Pose/FaceTargetContinuity.swift Align/Pose/FaceGeometrySignal.swift \
  Align/Pose/UpperBody/UpperBodyTypes.swift Align/Pose/UpperBody/UpperBodyGeometry.swift \
  Align/Pose/UpperBody/UpperBodyEngineSession.swift Align/Posture/PostureSnapshot.swift \
  Align/Posture/Observations/PostureObservationTypes.swift \
  Align/Posture/Observations/TemporalObservationMachine.swift \
  Align/Posture/Observations/PostureObservationEngine.swift \
  Align/Posture/PostureBlinkReference.swift Align/Posture/PostureBlinkPause.swift \
  Align/Posture/PostureRichSignals.swift "$work_dir/WorkerTest.swift" \
  -o "$work_dir/worker-test"
"$work_dir/worker-test"
