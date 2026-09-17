# Align

Align is a privacy-first macOS menu bar application that uses the built-in camera to turn local visual signals into calm, actionable posture reminders.

It is a personal pilot and a portfolio project, not a medical device. The product path is designed to keep camera analysis on-device: frames are processed in memory, raw images are not stored, and the app has no analytics or upload pipeline.

## What the product does

- Captures the local camera stream after macOS permission is granted.
- Extracts face landmarks with Vision and upper-body landmarks with the active RTMPose-M Halpe26 engine.
- Computes explainable 2D signals such as torso inclination, shoulder slope, raised shoulders, head/shoulder alignment, apparent proximity, hand-to-face contact, and blink-related observations.
- Uses freshness checks, hysteresis, persistence windows, and cooldowns before showing an in-app state or delivering a notification.
- Provides a menu-bar entry point, a compact SwiftUI window, diagnostics, calibration, local statistics, and explicit camera controls.

The feedback is intentionally framed as a visual coaching signal. It is not a clinical assessment and does not infer anatomy or health status from a 2D camera view.

## Architecture at a glance

```text
AVCaptureSession
      |
      v
CameraCaptureService  -- serial capture state, cadence, freshness, lifecycle
      |
      +--> Vision face landmarks and face geometry
      |
      +--> RTMPose-M Halpe26 / ONNX Runtime 1.19.2
                    |
                    v
        typed pose observations and diagnostics
                    |
                    v
        posture observation and alert coordinators
              /             |              \
        SwiftUI UI      local history       macOS notifications
```

RTMPose is the only upper-body engine used by the product activation. BlazePose/LiteRT and MediaPipe code are retained as isolated experiments, compatibility harnesses, or packaging checks; they are not silent fallbacks in the live path. See [Docs/Architecture.md](Docs/Architecture.md) for the ownership and concurrency boundaries.

## Privacy and local data

- Camera access is declared through the macOS camera entitlement and `NSCameraUsageDescription`.
- Inference runs locally using Apple Vision and bundled model/runtime artifacts.
- No network client, telemetry service, image upload, or cloud storage path is part of the app target.
- Raw frames, videos, face landmarks, and raw pose coordinates are not persisted by the product path.
- User settings and bounded, scalar posture-history aggregates are stored locally in Application Support so the statistics view can work across launches.
- Third-party notices remain in the repository so the project is auditable.

## Technology stack

| Area | Implementation |
| --- | --- |
| Platform | macOS menu-bar application |
| UI | SwiftUI with AppKit integration |
| Capture | AVFoundation / `AVCaptureSession` |
| Face signals | Apple Vision face landmarks and derived geometry |
| Upper-body inference | RTMPose-M Halpe26, bundled ONNX model |
| Inference runtime | ONNX Runtime 1.19.2 through a small C bridge |
| State and feedback | Swift value types, serial workers, deterministic observation and alert policies |
| Persistence | Local JSON aggregates and settings only |
| Validation | Swift/C/Python harnesses and explicit packaging checks |

## Prerequisites

The project is configured for macOS 26.5 or newer and uses Swift 5 language mode. A complete Xcode installation is required for the application build and Swift harnesses. The shared `Align` scheme is committed for clean-checkout discovery.

The repository intentionally tracks the RTMPose model, ONNX Runtime dynamic library, and legacy LiteRT artifacts used by the current project layout. Review the bundled notices before redistribution:

- [RTMPose third-party notices](Align/Pose/RTMPose/Models/ThirdPartyNotices.txt)
- [LiteRT Apache notice](Align/LiteRT/LICENSE-Apache-2.0.txt)
- [LiteRT notice](Align/LiteRT/NOTICE.txt)

## Build and test status

The following two dependency-free checks were executed successfully in the repository checkout:

```sh
python3 Tools/mediapipe_pose_spike.py --dry-run
python3 Tools/mediapipe_litert_same_frame.py --dry-run
```

They validate experiment-side calculations and phase/report logic; they do not prove camera inference or application behavior.

The main verification entry point is:

```sh
./Tools/verify.sh
```

It selects the standard Xcode installation, builds a Release bundle in a temporary directory, and runs the RTMPose packaging and upper-body worker harnesses. A completed run is still pending in this checkout because the local Xcode cache layer returned I/O errors.

The equivalent build command is:

```sh
xcodebuild \
  -project Align.xcodeproj \
  -scheme Align \
  -configuration Release \
  -derivedDataPath /private/tmp/align-release-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The source-level harnesses under `Tests/` are not registered XCTest targets. Packaging harnesses require a built `Align.app` and should only be run against that artifact. See [Docs/Validation.md](Docs/Validation.md) for the evidence boundary and the exact pending checks.

## Current limitations

- Camera behavior, signing, permission transitions, and the full Release build have not been verified in this checkout because only the Command Line Tools are selected instead of Xcode.
- The repository has a shared Xcode scheme, but no CI workflow yet.
- The active signals are 2D visual proxies. They are sensitive to framing, lighting, occlusion, camera placement, and the visible body region.
- A real camera session is required to evaluate tracking quality; dry-runs and source harnesses cannot establish user-facing accuracy.
- Core ML execution remains an explicit opt-in path in the adapter and is not presented as validated.
- Historical measurements in the existing benchmark notes describe earlier commits or experiments. They are not current product guarantees; no new benchmark is claimed here.
- Model binaries are large. The RTMPose weight must not be redistributed publicly until its model-specific licence is confirmed; removing it from the public history and documenting setup is a release gate.

## Repository map

```text
Align/                         Application source and bundled resources
  Camera/                      Capture lifecycle, cadence, and frame admission
  Pose/                        Vision, RTMPose adapter, and legacy pose code
    RTMPose/                   Active ONNX bridge, model, runtime, notices
  Posture/                     Signals, observations, alerts, history, validation
  UI/                          SwiftUI/AppKit presentation and diagnostics
  LiteRT/                      Legacy BlazePose/LiteRT model assets and notices
Tests/                         Focused Swift/C harnesses and packaging checks
Tools/                         Standalone experiments, smoke tests, and metrics
Docs/                          Architecture, validation, benchmarks, and experiments
Vendor/                        Bundled LiteRT headers/runtime for legacy tooling
Align.xcodeproj/               macOS application project
```

## Project status

Align is an actively evolving local pilot. The codebase demonstrates a complete product-shaped loop—from camera lifecycle and model inference to explainable signals, guarded notifications, UI state, and local history—while keeping the verification boundary visible. A completed Release verification, an anonymized product screenshot, and resolution of the RTMPose weight licence remain gates before public publication.
