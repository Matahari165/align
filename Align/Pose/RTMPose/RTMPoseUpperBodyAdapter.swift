import CoreVideo
import Foundation

/// Adaptateur isolé RTMPose-M Halpe26. Il implémente la frontière upper-body
/// sans modifier le scheduler, l'UI ou le renderer. Aucun fallback BlazePose.
nonisolated final class RTMPoseUpperBodyAdapter: UpperBodyPoseEngine, @unchecked Sendable {
    let descriptor = UpperBodyEngineDescriptor(
        id: "rtmpose-m-halpe26",
        displayName: "RTMPose-M Halpe26",
        version: "20230605-4d3e73dd",
        runtime: "ONNX Runtime 1.19.2"
    )

    private let modelURL: URL?
    private let runtimeURL: URL?
    private let useCoreML: Bool
    private let confidenceThreshold: Float
    private var runner: OpaquePointer?
    private var activeGeneration: UInt64?

    init(
        modelURL: URL? = nil,
        runtimeURL: URL? = nil,
        // CPU ONNX Runtime is the verified path. Core ML remains explicit
        // opt-in until a converted model/provider bundle is validated.
        useCoreML: Bool = false,
        confidenceThreshold: Float = 0.20
    ) {
        self.modelURL = modelURL ?? Self.bundledURL(
            resource: "rtmpose-m-halpe26-end2end", extension: "onnx"
        )
        self.runtimeURL = runtimeURL ?? Self.bundledRuntimeURL()
        self.useCoreML = useCoreML
        self.confidenceThreshold = confidenceThreshold
    }

    deinit {
        if let runner { AlignRTMPoseDestroy(runner) }
    }

    func activate(generation: UInt64) {
        deactivate()
        activeGeneration = generation
        guard runner == nil, let modelURL, let runtimeURL else { return }
        runner = AlignRTMPoseCreate(
            modelURL.path, runtimeURL.path, useCoreML ? 1 : 0
        )
    }

    func analyze(_ frame: UpperBodyFrame) -> UpperBodyEngineOutput {
        guard activeGeneration == frame.generation else {
            return UpperBodyEngineOutput(state: .stale, points: [], contours: [])
        }
        guard let runner,
              frame.capturedAt.isFinite,
              frame.sampleID > 0,
              confidenceThreshold.isFinite,
              CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_32BGRA
        else {
            return UpperBodyEngineOutput(state: .technicalError, points: [], contours: [])
        }

        guard let regionOfInterest = frame.regionOfInterest,
              regionOfInterest.isAdmissible(
                forFrameCapturedAt: frame.capturedAt,
                generation: frame.generation,
                maximumSkew: RTMPoseUpperBodyCropPolicy.maximumFaceAnchorSkew
              )
        else {
            // A top-down model cannot localize a person without an admissible
            // face/upper-body ROI. Fail closed instead of silently stretching a
            // full-frame crop and placing shoulders at its edges.
            return UpperBodyEngineOutput(state: .partial, points: [], contours: [])
        }

        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        let crop = AlignRTMPoseNormalizedCrop(
            x: Float(regionOfInterest.rect.minX),
            y: Float(regionOfInterest.rect.minY),
            width: Float(regionOfInterest.rect.width),
            height: Float(regionOfInterest.rect.height)
        )
        CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(frame.pixelBuffer) else {
            return UpperBodyEngineOutput(state: .technicalError, points: [], contours: [])
        }

        var native = AlignRTMPoseResult()
        let ok = AlignRTMPoseAnalyzeBGRA(
            runner,
            baseAddress.assumingMemoryBound(to: UInt8.self),
            width,
            height,
            CVPixelBufferGetBytesPerRow(frame.pixelBuffer),
            crop,
            1,
            frame.sampleID,
            frame.capturedAt,
            frame.generation,
            confidenceThreshold,
            &native
        )
        guard ok != 0 else {
            return UpperBodyEngineOutput(state: .technicalError, points: [], contours: [])
        }

        let diagnostics = UpperBodyEngineDiagnostics(
            validLandmarkCount: max(0, Int(native.valid_count)),
            simCCMinimum: finite(native.simcc_min),
            simCCMaximum: finite(native.simcc_max),
            scoreMinimum: finite(native.score_min),
            scoreMaximum: finite(native.score_max),
            leftShoulderScore: finite(native.left_shoulder_score),
            rightShoulderScore: finite(native.right_shoulder_score)
        )

        let state: UpperBodyEngineState
        switch Int32(native.status) {
        case Int32(ALIGN_RTMPOSE_AVAILABLE): state = .detected
        case Int32(ALIGN_RTMPOSE_NO_PERSON): state = .noPerson
        case Int32(ALIGN_RTMPOSE_INVALID_INPUT): state = .technicalError
        default: state = .technicalError
        }
        guard state == .detected else {
            return UpperBodyEngineOutput(
                state: state, points: [], contours: [],
                regionOfInterest: regionOfInterest, diagnostics: diagnostics
            )
        }

        let mapping = UpperBodyLandmarkID.rtmposeMapping
        let points = mapping.compactMap { index, id -> UpperBodyPoint? in
            let point = AlignRTMPoseResultPointAt(&native, index)
            guard point.valid != 0,
                  point.x.isFinite, point.y.isFinite, point.confidence.isFinite,
                  (0...1).contains(point.x), (0...1).contains(point.y),
                  (0...1).contains(point.confidence) else { return nil }
            return UpperBodyPoint(
                id: id,
                location: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)),
                confidence: point.confidence,
                quality: point.confidence >= 0.5 ? .good : .limited,
                provenance: .observed
            )
        }
        return UpperBodyEngineOutput(
            state: points.isEmpty ? .noPerson : .detected,
            points: points,
            contours: [],
            regionOfInterest: regionOfInterest,
            diagnostics: diagnostics
        )
    }

    func deactivate() {
        activeGeneration = nil
        if let runner {
            AlignRTMPoseDestroy(runner)
            self.runner = nil
        }
    }

    private static func bundledURL(resource: String, extension: String) -> URL? {
        let subdirectories = ["Pose/RTMPose/Models", "RTMPose/Models", nil]
        for subdirectory in subdirectories {
            if let url = Bundle.main.url(
                forResource: resource, withExtension: `extension`, subdirectory: subdirectory
            ) { return url }
        }
        return nil
    }

    private static func bundledRuntimeURL() -> URL? {
        if let resourceURL = bundledURL(
            resource: "libonnxruntime.1.19.2", extension: "dylib"
        ) {
            return resourceURL
        }
        // The dylib is embedded in Contents/Frameworks so @rpath remains
        // valid if this adapter is activated by the host application.
        let frameworkURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks", isDirectory: true)
            .appendingPathComponent("libonnxruntime.1.19.2.dylib")
        return FileManager.default.fileExists(atPath: frameworkURL.path)
            ? frameworkURL : nil
    }

    private func finite(_ value: Float) -> Float? {
        value.isFinite ? value : nil
    }
}
