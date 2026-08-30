import CoreGraphics
import CoreVideo
import Foundation

nonisolated enum BlazePoseLiveState: String, Sendable {
    case detected, partial, lost, technicalError
    var displayName: String {
        switch self {
        case .detected: "Détecté"
        case .partial: "Partiel"
        case .lost: "Perdu"
        case .technicalError: "Erreur"
        }
    }
}

nonisolated struct BlazePoseLiveResult: Sendable {
    static let lost = BlazePoseLiveResult(state: .lost, leftShoulder: nil, rightShoulder: nil)
    let state: BlazePoseLiveState
    let leftShoulder: PosePoint?
    let rightShoulder: PosePoint?

    var overlay: PoseOverlay {
        let shoulders = [leftShoulder, rightShoulder].compactMap { $0 }
        guard let leftShoulder, let rightShoulder else {
            return PoseOverlay(points: shoulders, polylines: [])
        }
        let center = PosePoint(
            name: "CENTRE ESTIMÉ",
            location: CGPoint(x: (leftShoulder.location.x + rightShoulder.location.x) / 2,
                              y: (leftShoulder.location.y + rightShoulder.location.y) / 2),
            confidence: min(leftShoulder.confidence, rightShoulder.confidence),
            source: .blazePose
        )
        return PoseOverlay(
            points: [leftShoulder, rightShoulder, center],
            polylines: [PosePolyline(name: "ligne-épaules",
                                    locations: [leftShoulder.location, rightShoulder.location],
                                    source: .blazePose, isClosed: false)]
        )
    }
}

/// Moteur natif in-process. Son unique instance vit sur `sampleQueue`, donc
/// LiteRT ne reçoit jamais deux inférences concurrentes.
nonisolated final class BlazePoseLiveEngine: @unchecked Sendable {
    private static let shoulderThreshold: Float = 0.5
    private static let maximumFilterGap: TimeInterval = BlazePoseOverlayFreshness.maxAge
    private var runner: OpaquePointer?

    deinit { reset() }

    func reset() {
        if let runner { AlignBlazePoseDestroy(runner) }
        runner = nil
    }

    func resetTracking() {
        if let runner { AlignBlazePoseResetTracking(runner) }
    }

    func analyze(
        _ pixelBuffer: CVPixelBuffer,
        at uptime: TimeInterval,
        generation: UInt64
    ) -> BlazePoseLiveResult {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              let runner = ensureRunner() else {
            return BlazePoseLiveResult(state: .technicalError, leftShoulder: nil, rightShoulder: nil)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return BlazePoseLiveResult(state: .technicalError, leftShoulder: nil, rightShoulder: nil)
        }
        let native = AlignBlazePoseAnalyzeBGRA(
            runner, bytes.assumingMemoryBound(to: UInt8.self),
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer),
            CVPixelBufferGetBytesPerRow(pixelBuffer), uptime,
            Self.maximumFilterGap, generation
        )
        guard native.status != AlignBlazePoseTechnicalError else {
            return BlazePoseLiveResult(state: .technicalError, leftShoulder: nil, rightShoulder: nil)
        }
        guard native.status == AlignBlazePoseDetected else { return .lost }
        let left = shoulder(name: "Épaule gauche", x: native.left_x, y: native.left_y, confidence: native.left_confidence)
        let right = shoulder(name: "Épaule droite", x: native.right_x, y: native.right_y, confidence: native.right_confidence)
        let state: BlazePoseLiveState = switch (left, right) {
        case (.some, .some): .detected
        case (.some, .none), (.none, .some): .partial
        case (.none, .none): .lost
        }
        return BlazePoseLiveResult(state: state, leftShoulder: left, rightShoulder: right)
    }

    private func ensureRunner() -> OpaquePointer? {
        if let runner { return runner }
        let detector = Bundle.main.url(
            forResource: "pose_detector", withExtension: "tflite", subdirectory: "LiteRT"
        ) ?? Bundle.main.url(forResource: "pose_detector", withExtension: "tflite")
        let landmarks = Bundle.main.url(
            forResource: "pose_landmarks_detector", withExtension: "tflite", subdirectory: "LiteRT"
        ) ?? Bundle.main.url(forResource: "pose_landmarks_detector", withExtension: "tflite")
        guard let detector, let landmarks else { return nil }
        runner = AlignBlazePoseCreate(detector.path, landmarks.path)
        return runner
    }

    private func shoulder(name: String, x: Float, y: Float, confidence: Float) -> PosePoint? {
        guard x.isFinite, y.isFinite, confidence.isFinite,
              confidence >= Self.shoulderThreshold,
              (0...1).contains(x), (0...1).contains(y) else { return nil }
        return PosePoint(name: name, location: CGPoint(x: CGFloat(x), y: CGFloat(y)),
                         confidence: confidence, source: .blazePose)
    }
}
