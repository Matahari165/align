# Experiments and decisions

Align has accumulated several pose and signal experiments. This inventory keeps the public story honest: an experiment can be valuable without being part of the shipped product path.

## Decision matrix

| Experiment | Decision | Current role | Evidence boundary |
| --- | --- | --- | --- |
| RTMPose-M Halpe26 through ONNX Runtime 1.19.2 | **Selected in product code** | Sole configured upper-body engine for the product activation. | Source wiring and typed adapter contract are verified. A complete Release build and real camera verification remain pending in this checkout. |
| Face-anchored RTMPose ROI with bounded fallback | **Adopted with guards** | Uses same-frame or recent admissible face context; falls back to a bounded crop only when the anchor is unavailable. | Admission and ROI harnesses cover geometry and freshness. The fallback is not itself a person detection. |
| Apple Vision face landmarks and derived face geometry | **Adopted** | Supplies face observations, blink inputs, geometry proxies, and the upper-body ROI anchor. | Implemented in the local capture path. Signals remain 2D proxies and can become unavailable under poor framing or occlusion. |
| Universal geometric posture reference | **Selected in product code** | Current posture rules use shared camera geometry and guarded signal availability rather than treating a personal calibration pose as a universal “correct” posture. | Signal and runtime harnesses exist; camera-real accuracy still needs a fresh protocol. |
| BlazePose with LiteRT | **Retained as legacy** | Model/runtime assets, native bridge, and packaging/smoke harnesses remain for historical comparison and compatibility work. | Not in the active target path and never a silent RTMPose fallback. Existing checks describe a legacy bundle. |
| MediaPipe Pose Landmarker spike | **Rejected for product runtime** | Standalone Python research tool for comparing shoulder visibility and timing. | Dry-run passes without camera; the runtime's external telemetry behavior is incompatible with the local-only product boundary. |
| Person segmentation | **Diagnostic only** | Explicit benchmark/visual experiment for silhouette quality. | Not continuously scheduled in the product loop; its cost and intermittency require a separate decision. |
| Vision body detection comparison | **Diagnostic only** | Historical baseline and harness input. | It is not the current upper-body engine and should not be used to describe the active architecture. |
| Core ML execution provider | **Not yet adopted** | Explicit opt-in in the adapter for future evaluation. | No public claim of Core ML performance or compatibility is made. |
| Blink reference and reminder policy | **Adopted with safeguards** | Learns bounded local references and uses observation freshness, persistence, and cooldowns before reminders. | Pure state/policy harnesses exist; it is not a medical eye-health measurement. |

## Why RTMPose is the product engine

The active code keeps the upper-body engine behind a small typed protocol. That boundary lets capture cadence, observation evaluation, UI presentation, and notifications remain independent of model-specific tensor details. RTMPose-M Halpe26 is selected explicitly in the worker, and a model/runtime error is published as a technical state rather than silently switching to an older model.

## Why the other paths remain

The legacy and research paths are useful for engineering work:

- BlazePose/LiteRT provides a prior native bridge and bundle checks that make packaging regressions visible.
- MediaPipe scripts let a researcher inspect a hypothesis without adding the dependency to the macOS app.
- Segmentation and Vision body detection provide diagnostic comparisons when a signal needs a visual or geometric sanity check.

They are kept separate so the portfolio can show iteration and rejection decisions without implying that every prototype is production code.

## Evidence and limits

The repository contains focused harnesses for geometry, state transitions, frame admission, ROI mapping, presentation, and bundle packaging. The dependency-free Python dry-runs currently pass. None of these checks establishes end-to-end camera accuracy, user comfort, medical validity, or long-term resource usage.

Historical benchmark notes should be read with their commit/date context. They are not reproduced as current metrics here, and no new benchmark result is invented for this cleanup.

## Privacy and licensing decisions

All experiments are intended to run locally. MediaPipe was not adopted into the product path because its runtime behavior did not meet the project's local-only boundary. Camera-derived data is not committed, and the product path does not persist raw frames or raw coordinates. Bundled models and runtimes retain their accompanying notices; a final license review remains required before redistribution.
