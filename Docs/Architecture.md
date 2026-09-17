# Align architecture

This document describes the product path that a public reader should treat as current. It separates live behavior from diagnostics and historical experiments so that a passing harness or an old benchmark cannot be mistaken for production evidence.

## Runtime flow

```text
AVCaptureSession
    |
    v
CameraCaptureService
    |  serial sample queue; cadence and lifecycle gates
    +----------------------+----------------------+
    |                      |                      |
    v                      v                      v
Vision face          RTMPose upper body    optional diagnostics
landmarks +          adapter               segmentation / ROI spikes
face geometry        (active engine)
    |                      |
    +----------+-----------+
               v
       typed posture observations
               |
               v
       freshness / quality gates
               |
       +-------+---------+----------------+
       |                 |                |
       v                 v                v
    SwiftUI          alert coordinator   local history
    presentation     + macOS delivery   scalar JSON
```

The application also owns a menu-bar scene and a single-instance guard. UI state is MainActor-isolated; camera-derived mutable state stays on the capture/sample queues. The active inference worker owns its engine session and does not allow an inference backlog to accumulate.

## Component responsibilities

| Component | Responsibility | Product status |
| --- | --- | --- |
| `Align/Camera/CameraCaptureService.swift` | Owns camera authorization, capture lifecycle, frame cadence, generation changes, freshness expiry, diagnostics, and event publication. | Active |
| Vision face pipeline in `CameraCaptureService` and `Align/Pose/` | Produces face landmarks, face geometry proxies, blink inputs, and a face-anchored ROI. | Active |
| `Align/Pose/RTMPose/RTMPoseUpperBodyAdapter.swift` | Adapts RTMPose-M Halpe26 to the typed upper-body engine boundary. | Active |
| `Align/Pose/RTMPose/rtmpose_onnx_bridge.c` | Owns the ONNX Runtime boundary, model invocation, crop/content mapping, and scalar output conversion. | Active |
| `Align/Pose/UpperBody/UpperBodyEngineSession.swift` | Admits frames, rejects stale/duplicate generations, records scalar engine diagnostics, and returns typed results. | Active |
| `Align/Posture/` | Converts observations into explainable posture signals, applies persistence/hysteresis/freshness policies, and arbitrates reminders. | Active |
| `Align/UI/` | Presents camera state, posture indicators, settings, statistics, and development diagnostics. | Active |
| `Align/Posture/History/` | Persists bounded scalar aggregates and control events in local Application Support JSON. | Active |
| `Align/Pose/BlazePose*`, `Align/LiteRT/`, `Vendor/LiteRT/` | Legacy engine and packaging assets retained for comparison or compatibility harnesses. | Not active in product inference |
| `Tools/` and `Tests/` | Standalone experiments, native smoke checks, and focused harnesses. | Validation only |

## Active upper-body engine

The live upper-body path is deliberately explicit:

```text
face anchor (same frame or recent admissible frame)
        |
        v
bounded top-down ROI
        |
        v
RTMPose-M Halpe26, ONNX Runtime 1.19.2
        |
        v
confidence-checked Halpe26 points
        |
        v
typed observations and posture signals
```

The engine descriptor is `rtmpose-m-halpe26`. The model is bundled at `Align/Pose/RTMPose/Models/rtmpose-m-halpe26-end2end.onnx`, and the CPU ONNX Runtime path is the configured default. The adapter contains no runtime fallback to BlazePose. A load or inference failure is surfaced as a technical error rather than silently changing model semantics.

When the same-frame face ROI is missing or stale, the session may use a bounded full-frame fallback crop. That crop is only an input strategy; it is not evidence that a person exists. The model output still has to pass validity and confidence checks.

## Data and concurrency contracts

- Every capture activation receives a generation. Results from an older activation cannot re-enter the current posture state.
- Frames carry capture time and a monotonically increasing sample identifier. Future, stale, duplicate, and invalid frames are rejected before inference.
- `UpperBodyEngineSession` is owned by a dedicated serial worker queue. The capture queue does not wait for model inference and does not build an unbounded work queue.
- Results expire when they are too old for the signal that consumes them. A missing or uncertain observation becomes unavailable; it is not converted into a negative posture verdict.
- Diagnostics are scalar counters, durations, scores, states, and rejection reasons. The product does not retain frames, videos, raw landmark arrays, or ROI images.

## Product versus diagnostic paths

| Path | What it is for | What it must not be interpreted as |
| --- | --- | --- |
| RTMPose + Vision | The current local product loop. | A clinical or anatomical measurement. |
| Vision body detection | A legacy/diagnostic comparison path. | The active upper-body engine. |
| Person segmentation | An explicitly triggered visual experiment. | A continuously running production dependency. |
| BlazePose/LiteRT | Legacy packaging and native smoke harnesses. | A live fallback or current benchmark. |
| MediaPipe scripts | Standalone research spikes. | A shipped dependency; the runtime's telemetry behavior is a reason it is not part of the product path. |

## Privacy boundary

The camera feed is consumed locally by AVFoundation, Vision, and the bundled inference runtime. The application target contains no network client or upload path. Raw camera frames and raw pose data are not persisted. Local settings and bounded scalar history aggregates are written to Application Support so the user can review trends across launches. Camera permission is declared in `Align/Align.entitlements` and explained in `Align/Info.plist`.

## Third-party artifacts

The repository tracks model/runtime artifacts to keep this prototype inspectable. Their accompanying notices are part of the review surface:

- `Align/Pose/RTMPose/Models/ThirdPartyNotices.txt`
- `Align/Pose/RTMPose/Models/ONNXRuntime-LICENSE.txt`
- `Align/Pose/RTMPose/Models/RTMPose-NOTICE.txt`
- `Align/LiteRT/LICENSE-Apache-2.0.txt`
- `Align/LiteRT/NOTICE.txt`

This document does not replace a legal license review before redistribution.
