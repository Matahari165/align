import CoreVideo
import Foundation
import ImageIO
import Vision

/// Experimental replacement for the RTMPose body engine. The existing face
/// request and blink tracking remain untouched; only the body inference changes.
nonisolated final class AppleVisionUpperBodyAdapter: UpperBodyPoseEngine, @unchecked Sendable {
    let descriptor = UpperBodyEngineDescriptor(
        id: "apple-vision-body", displayName: "Apple Vision Body",
        version: "2D", runtime: "Vision"
    )

    private var generation: UInt64?
    private var shoulderStabilizer = UpperBodyShoulderStabilizer()
    // Keep tentative joints visible for comparison, but mark them limited so
    // downstream alert policy cannot treat them as reliable posture evidence.
    private let minimumConfidence: Float = 0.25

    func activate(generation: UInt64) {
        self.generation = generation
        shoulderStabilizer.reset()
    }

    func analyze(_ frame: UpperBodyFrame) -> UpperBodyEngineOutput {
        guard generation == frame.generation else {
            return .init(state: .stale, points: [], contours: [])
        }
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: .up)
        do {
            try handler.perform([request])
            guard let observation = request.results?.max(by: { $0.confidence < $1.confidence }) else {
                shoulderStabilizer.reset()
                return .init(state: .noPerson, points: [], contours: [])
            }
            let points = Self.joints.compactMap { id, joint -> UpperBodyPoint? in
                guard let recognized = try? observation.recognizedPoint(joint),
                      recognized.confidence >= minimumConfidence else { return nil }
                let location = CGPoint(x: recognized.location.x, y: 1 - recognized.location.y)
                guard location.x.isFinite, location.y.isFinite,
                      (0...1).contains(location.x), (0...1).contains(location.y) else { return nil }
                return UpperBodyPoint(
                    id: id, location: location, confidence: recognized.confidence,
                    quality: recognized.confidence >= 0.5 ? .good : .limited,
                    provenance: .observed
                )
            }
            let stabilized = shoulderStabilizer.stabilize(
                points: points, generation: frame.generation, sampleID: frame.sampleID,
                capturedAt: frame.capturedAt, regionSource: nil
            )
            let hasShoulders = stabilized.contains { $0.id == .leftShoulder } &&
                stabilized.contains { $0.id == .rightShoulder }
            return .init(
                state: stabilized.isEmpty ? .noPerson : (hasShoulders ? .detected : .partial),
                points: stabilized, contours: [],
                diagnostics: .init(
                    usedCoreML: false, validLandmarkCount: stabilized.count,
                    simCCMinimum: nil, simCCMaximum: nil,
                    scoreMinimum: stabilized.map(\.confidence).min(),
                    scoreMaximum: stabilized.map(\.confidence).max(),
                    leftShoulderScore: stabilized.first { $0.id == .leftShoulder }?.confidence,
                    rightShoulderScore: stabilized.first { $0.id == .rightShoulder }?.confidence
                )
            )
        } catch {
            shoulderStabilizer.reset()
            return .init(state: .technicalError, points: [], contours: [])
        }
    }

    func deactivate() {
        generation = nil
        shoulderStabilizer.reset()
    }

    private static let joints: [(UpperBodyLandmarkID, VNHumanBodyPoseObservation.JointName)] = [
        (.nose, .nose), (.leftEar, .leftEar), (.rightEar, .rightEar),
        (.neck, .neck), (.leftShoulder, .leftShoulder),
        (.rightShoulder, .rightShoulder), (.leftElbow, .leftElbow),
        (.rightElbow, .rightElbow), (.leftHip, .leftHip), (.rightHip, .rightHip)
    ]
}
