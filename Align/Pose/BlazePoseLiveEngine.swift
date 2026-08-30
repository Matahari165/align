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
    let nose: PosePoint?
    let leftEar: PosePoint?
    let rightEar: PosePoint?
    let leftShoulder: PosePoint?
    let rightShoulder: PosePoint?
    let leftElbow: PosePoint?
    let rightElbow: PosePoint?
    let leftHip: PosePoint?
    let rightHip: PosePoint?

    init(
        state: BlazePoseLiveState,
        nose: PosePoint? = nil,
        leftEar: PosePoint? = nil,
        rightEar: PosePoint? = nil,
        leftShoulder: PosePoint?,
        rightShoulder: PosePoint?,
        leftElbow: PosePoint? = nil,
        rightElbow: PosePoint? = nil,
        leftHip: PosePoint? = nil,
        rightHip: PosePoint? = nil
    ) {
        self.state = state
        self.nose = nose
        self.leftEar = leftEar
        self.rightEar = rightEar
        self.leftShoulder = leftShoulder
        self.rightShoulder = rightShoulder
        self.leftElbow = leftElbow
        self.rightElbow = rightElbow
        self.leftHip = leftHip
        self.rightHip = rightHip
    }

    var overlay: PoseOverlay {
        BlazePoseOverlayBuilder.make(
            nose: nose, leftEar: leftEar, rightEar: rightEar,
            leftShoulder: leftShoulder, rightShoulder: rightShoulder,
            leftElbow: leftElbow, rightElbow: rightElbow,
            leftHip: leftHip, rightHip: rightHip
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
    ) -> BlazePoseLiveResult? {
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
        return Self.liveResult(from: native)
    }

    static func liveResult(from native: AlignBlazePoseResult) -> BlazePoseLiveResult? {
        guard native.status != AlignBlazePoseStale else { return nil }
        guard native.status != AlignBlazePoseTechnicalError else {
            return BlazePoseLiveResult(state: .technicalError, leftShoulder: nil, rightShoulder: nil)
        }
        guard native.status == AlignBlazePoseDetected else { return .lost }
        let nose = point(name: "Nez", native.nose)
        let leftEar = point(name: "Oreille gauche", native.left_ear)
        let rightEar = point(name: "Oreille droite", native.right_ear)
        let left = point(name: "Épaule gauche", native.left_shoulder)
        let right = point(name: "Épaule droite", native.right_shoulder)
        let leftElbow = point(name: "Coude gauche", native.left_elbow)
        let rightElbow = point(name: "Coude droit", native.right_elbow)
        let leftHip = point(name: "Hanche gauche", native.left_hip)
        let rightHip = point(name: "Hanche droite", native.right_hip)
        let state: BlazePoseLiveState = switch (left, right) {
        case (.some, .some): .detected
        case (.some, .none), (.none, .some): .partial
        case (.none, .none): .lost
        }
        return BlazePoseLiveResult(
            state: state, nose: nose, leftEar: leftEar, rightEar: rightEar,
            leftShoulder: left, rightShoulder: right,
            leftElbow: leftElbow, rightElbow: rightElbow,
            leftHip: leftHip, rightHip: rightHip
        )
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

    private static func point(name: String, _ native: AlignBlazePosePoint) -> PosePoint? {
        guard native.valid != 0,
              native.x.isFinite, native.y.isFinite, native.confidence.isFinite,
              native.confidence >= Self.shoulderThreshold,
              (0...1).contains(native.x), (0...1).contains(native.y) else { return nil }
        let location = VisionCoordinateMapper.poseOverlayPoint(
            fromBlazePoseTopLeftPoint: CGPoint(x: CGFloat(native.x), y: CGFloat(native.y))
        )
        return PosePoint(name: name, location: location,
                         confidence: native.confidence, source: .blazePose)
    }
}
