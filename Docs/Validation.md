# Validation and evidence

Align uses several kinds of checks. They are intentionally kept separate: a pure calculation harness can prove a geometry rule, while only a real camera run can establish capture behavior and tracking quality.

## Evidence matrix

| Check | Command or evidence | Current status | What it proves |
| --- | --- | --- | --- |
| MediaPipe phase/report dry-run | `python3 Tools/mediapipe_pose_spike.py --dry-run` | **Passed in this checkout** | Experiment-side phase timing, percentile, loss, and jitter calculations without camera dependencies. |
| MediaPipe/LiteRT same-frame dry-run | `python3 Tools/mediapipe_litert_same_frame.py --dry-run` | **Passed in this checkout** | Standalone comparison tool's deterministic validation path without camera dependencies. |
| Local RTMPose model setup | `./Tools/setup-local-model.sh` | **Required before build** | Verifies the owner-supplied model SHA-256 and atomically stages it in the ignored checkout; it performs no download. |
| Project discovery | `xcodebuild -project Align.xcodeproj -list` | **Blocked here** | The active developer directory is Command Line Tools; full Xcode is not selected. |
| Application build | `./Tools/verify.sh` | **Pending locally** | Release compilation, bundle assembly, model packaging, and worker checks through the committed shared scheme. Public CI uses `ALIGN_SKIP_PRIVATE_MODEL=1`, builds without the private weight, and asserts it is absent from the bundle. |
| Swift/C focused harnesses | Files under `Tests/` | **Available, not XCTest-integrated** | Isolated state machines, geometry, presentation, packaging, and runtime contracts when invoked with their required SDK/artifact inputs. |
| RTMPose bundle packaging | `Tests/RTMPoseBundlePackagingHarness.sh /path/to/Align.app` | **Pending built app** | Model identifier, model hash, notices, runtime embedding, and removal of the legacy LiteRT bundle from an RTMPose app. |
| BlazePose bundle packaging | `Tests/BlazePoseBundlePackagingHarness.sh /path/to/Align.app lite|full` | **Legacy check only** | Historical LiteRT package layout; it is not evidence for the current product engine. |
| Worker harness | `Tests/UpperBodyInferenceWorkerHarness.sh` | **Pending full Xcode SDK** | Serial worker ownership, generation handling, and no-backlog admission behavior. |
| Camera permission and runtime | Manual run on a Mac with camera access | **Not verified here** | Authorization, denial, unavailable camera, freshness, overlay, and notification behavior. |
| Public release review | Repository diff, secret scan, third-party notices | **In progress** | That the public tree contains no personal credentials or accidental local state and that bundled artifacts are documented. |

The two dry-run passes are useful but intentionally modest evidence. They do not prove model quality, camera performance, notifications, or the macOS UI. The local model setup proves provenance by hash and safe staging only; it does not prove the model's licence or posture accuracy.

## What is verified statically

The source and project configuration support these claims:

- `UpperBodyEngineIdentifier` is `rtmpose-m-halpe26` in `Align/Info.plist`.
- `CameraCaptureService` constructs `RTMPoseUpperBodyAdapter` as the product upper-body engine.
- The active adapter advertises ONNX Runtime 1.19.2 and defaults to the CPU path.
- The app declares the camera entitlement and a camera usage description.
- Frame admission, generation checks, result freshness, and fail-closed technical/partial states are represented in the typed runtime code.
- No `URLSession`, HTTP endpoint, image export, or upload path was found in the app source during this documentation pass.
- Local history is scalar JSON in Application Support; the history store does not write camera frames or raw landmark arrays.

These are implementation facts, not a substitute for a built-and-run release check.

## Camera acceptance protocol

Once a full Xcode build is available, the minimum manual pass should cover:

1. First launch with camera permission not yet decided.
2. Permission granted: preview, face signals, upper-body inference, overlay, and diagnostics become live.
3. Permission denied or camera unavailable: the UI explains the state and offers macOS Settings without producing posture alerts.
4. Normal seated framing: RTMPose results remain fresh and incomplete/uncertain observations do not trigger reminders.
5. Face occlusion, movement, and a changed camera context: old overlays and pending notifications expire or are cancelled.
6. Stop/restart and background/menu-bar operation: no stale result from the previous generation is accepted.
7. Local statistics: only bounded scalar history is written and can be erased through the existing product path.

Record the macOS version, Xcode version, device, camera, build configuration, model hash, and observed outcome. Do not add camera frames or personal recordings to the repository.

## Performance evidence policy

The existing benchmark notes contain historical measurements for earlier commits and isolated experiments. They remain useful as context, but they are not a current release claim. A new performance statement should include:

- the exact commit and build configuration;
- machine, macOS, Xcode, camera resolution, and capture cadence;
- warm-up period, duration, sampling interval, and whether the window was visible;
- CPU/RSS measurement method and sample count;
- model/runtime identifiers and hashes;
- known limitations and whether the result was camera-real or synthetic.

No benchmark is claimed by this public cleanup.

## Reproducibility gaps

- The repository now has a committed shared `Align` scheme and ignores user-specific Xcode state.
- The RTMPose weight is intentionally ignored and must be supplied from a stable user-owned path. `Tools/setup-local-model.sh` verifies SHA-256 `26f3a19e61304a600dfb82d1001d41d24343b89fc70a33ffc84657e0b0bf2ec`, then copies it atomically into the build checkout. It does not download or remove the source.
- The standard Xcode installation is available, but its cache/FSEvents layer returned I/O errors during this cleanup, so a completed build is still pending.
- Harnesses are source-level executables/scripts rather than a single XCTest target.
- A real camera run, signing, notification authorization, and UI resizing have not been re-verified as part of this cleanup. A clean public checkout also cannot build until an authorized local RTMPose weight is supplied.

These gaps are recorded so a recruiter can distinguish demonstrated engineering intent from evidence that still requires a Mac/Xcode validation pass.
