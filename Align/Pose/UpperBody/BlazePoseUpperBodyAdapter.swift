import Foundation

/// Temporary adapter for the currently selected model. A future RTMPose
/// adapter replaces this object; it never runs beside it in normal use.
nonisolated final class BlazePoseUpperBodyAdapter: UpperBodyPoseEngine, @unchecked Sendable {
    let descriptor: UpperBodyEngineDescriptor
    private let engine: BlazePoseLiveEngine
    private var generation: UInt64?

    init(modelVariant: BlazePoseModelVariant? = .bundleConfigured) {
        engine = BlazePoseLiveEngine(modelVariant: modelVariant)
        descriptor = UpperBodyEngineDescriptor(
            id: "blazepose.\(modelVariant?.rawValue ?? "invalid")",
            displayName: "BlazePose \(modelVariant?.rawValue.capitalized ?? "invalide")",
            version: "1",
            runtime: "LiteRT 2.2.0"
        )
    }

    func activate(generation: UInt64) {
        engine.reset()
        self.generation = generation
    }

    func analyze(_ frame: UpperBodyFrame) -> UpperBodyEngineOutput {
        guard generation == frame.generation else {
            return .init(state: .stale, points: [], contours: [])
        }
        guard let result = engine.analyze(
            frame.pixelBuffer,
            at: frame.capturedAt,
            generation: frame.generation
        ) else {
            return .init(state: .stale, points: [], contours: [])
        }
        let state: UpperBodyEngineState = switch result.state {
        case .detected: .detected
        case .partial: .partial
        case .lost: .noPerson
        case .technicalError: .technicalError
        }
        let mapped: [(UpperBodyLandmarkID, PosePoint?)] = [
            (.nose, result.nose),
            (.leftEar, result.leftEar),
            (.rightEar, result.rightEar),
            (.leftShoulder, result.leftShoulder),
            (.rightShoulder, result.rightShoulder),
            (.leftElbow, result.leftElbow),
            (.rightElbow, result.rightElbow),
            (.leftHip, result.leftHip),
            (.rightHip, result.rightHip)
        ]
        return UpperBodyEngineOutput(
            state: state,
            points: mapped.compactMap { id, point in
                point.map {
                    UpperBodyPoint(
                        id: id,
                        location: $0.location,
                        confidence: $0.confidence,
                        quality: $0.confidence >= 0.5 ? .good : .limited,
                        provenance: .observed
                    )
                }
            },
            contours: []
        )
    }

    func deactivate() {
        generation = nil
        engine.reset()
    }
}
