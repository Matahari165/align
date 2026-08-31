import CoreGraphics
import CoreVideo
import ImageIO
import Vision

nonisolated enum PosePointSource: String, Hashable, Sendable {
    case face
    case body
    case silhouette
    case blazePose
    case upperBodyHead
    case upperBodyShoulders
    case upperBodyTorso
    case upperBodyDerived
    case upperBodyROI
}

nonisolated struct PosePoint: Identifiable, Sendable {
    let name: String
    let location: CGPoint
    let confidence: Float
    let source: PosePointSource
    let isLimited: Bool

    init(
        name: String,
        location: CGPoint,
        confidence: Float,
        source: PosePointSource,
        isLimited: Bool = false
    ) {
        self.name = name
        self.location = location
        self.confidence = confidence
        self.source = source
        self.isLimited = isLimited
    }

    var id: String { "\(source.rawValue).\(name)" }
}

nonisolated struct PosePolyline: Identifiable, Sendable {
    /// Existing face/body overlay coordinates. Their numeric convention is
    /// preserved for the live-validated face renderer; segmentation crosses an
    /// explicit boundary before entering this type.
    let name: String
    let locations: [CGPoint]
    let source: PosePointSource
    let isClosed: Bool

    var id: String { "\(source.rawValue).\(name)" }
}

nonisolated struct PoseOverlay: Sendable {
    static let empty = PoseOverlay(points: [], polylines: [])

    let points: [PosePoint]
    let polylines: [PosePolyline]

    var isEmpty: Bool { points.isEmpty && polylines.isEmpty }
}

nonisolated enum BlazePoseOverlayBuilder {
    static func make(
        nose: PosePoint?, leftEar: PosePoint?, rightEar: PosePoint?,
        leftShoulder: PosePoint?, rightShoulder: PosePoint?,
        leftElbow: PosePoint?, rightElbow: PosePoint?,
        leftHip: PosePoint?, rightHip: PosePoint?
    ) -> PoseOverlay {
        // Usage normal volontairement minimal : les autres repères restent
        // disponibles dans le bridge pour diagnostic, jamais affichés ici.
        let points = [leftShoulder, rightShoulder].compactMap { $0 }
        var lines: [PosePolyline] = []
        func connect(_ name: String, _ first: PosePoint?, _ second: PosePoint?) {
            guard let first, let second else { return }
            lines.append(PosePolyline(name: name,
                                      locations: [first.location, second.location],
                                      source: .blazePose, isClosed: false))
        }
        if BlazePoseShoulderPairValidator.isCoherent(
            left: leftShoulder?.location,
            right: rightShoulder?.location
        ) {
            connect("ligne-épaules", leftShoulder, rightShoulder)
        }
        return PoseOverlay(points: points, polylines: lines)
    }
}

/// Garde géométrique volontairement permissive : elle élimine uniquement une
/// paire manifestement dégénérée. Une épaule levée reste un mouvement valide.
nonisolated enum BlazePoseShoulderPairValidator {
    static let minimumSeparation: CGFloat = 0.08
    static let maximumSeparation: CGFloat = 0.90

    static func isCoherent(left: CGPoint?, right: CGPoint?) -> Bool {
        guard let left, let right,
              left.x.isFinite, left.y.isFinite,
              right.x.isFinite, right.y.isFinite,
              (0...1).contains(left.x), (0...1).contains(left.y),
              (0...1).contains(right.x), (0...1).contains(right.y) else { return false }
        let horizontal = abs(right.x - left.x)
        let vertical = abs(right.y - left.y)
        let separation = hypot(horizontal, vertical)
        // La pente n'est pas un critère de validité : une épaule réellement
        // levée peut produire une forte asymétrie. La paire est rejetée
        // uniquement si elle est confondue, hors cadre ou invraisemblablement
        // éloignée dans l'image normalisée.
        return separation >= minimumSeparation && separation <= maximumSeparation
    }
}

nonisolated enum PoseTrackingMode: Sendable {
    case faceOnly
    case bodyAvailable
}

nonisolated struct PoseTrackingStatus: Sendable {
    let mode: PoseTrackingMode
    let recognizedPointCount: Int
}

nonisolated struct PoseObservation: Sendable {
    let points: [PosePoint]
    let polylines: [PosePolyline]
    let mode: PoseTrackingMode

    var overlay: PoseOverlay {
        PoseOverlay(points: points, polylines: polylines)
    }
    var status: PoseTrackingStatus {
        PoseTrackingStatus(
            mode: mode,
            recognizedPointCount: points.count + polylines.reduce(0) { $0 + $1.locations.count }
        )
    }
}

nonisolated struct PoseInferenceDiagnostics: Sendable {
    let candidateOrientation: String
    let lockedOrientation: String?
    let faceOrientation: FaceOrientationSignal?
    let faceGeometry: FaceGeometrySignal?
    let faceResultCount: Int
    let facesWithLandmarksCount: Int
    let facePointCount: Int
    let bodyResultCount: Int
}

nonisolated struct PoseDetectionOutput: Sendable {
    let observation: PoseObservation?
    let diagnostics: PoseInferenceDiagnostics
}

nonisolated struct FaceDetectionOutput: Sendable {
    static let empty = FaceDetectionOutput(
        polylines: [],
        primaryOrientation: nil,
        resultCount: 0,
        facesWithLandmarksCount: 0
    )

    let polylines: [PosePolyline]
    let primaryOrientation: FaceOrientationSignal?
    let resultCount: Int
    let facesWithLandmarksCount: Int
}

nonisolated struct BodyDetectionOutput: Sendable {
    let points: [PosePoint]
    let resultCount: Int
    let hasUpperBody: Bool
    let upperBodyLandmarks: UpperBodyLandmarkDiagnostics
}

nonisolated enum UpperBodyLandmark: String, CaseIterable, Sendable {
    case neck
    case leftShoulder
    case rightShoulder

    var visionJointName: VNHumanBodyPoseObservation.JointName {
        switch self {
        case .neck: .neck
        case .leftShoulder: .leftShoulder
        case .rightShoulder: .rightShoulder
        }
    }
}

/// Presence and confidence of the real Vision joints used by Align.
/// Missing joints stay missing: this type never extrapolates anatomy.
nonisolated struct UpperBodyLandmarkDiagnostics: Sendable, Equatable {
    static let recognitionThreshold: Float = 0.35
    static let empty = UpperBodyLandmarkDiagnostics(confidenceByLandmark: [:])

    let neckConfidence: Float?
    let leftShoulderConfidence: Float?
    let rightShoulderConfidence: Float?

    init(confidenceByLandmark: [UpperBodyLandmark: Float]) {
        neckConfidence = confidenceByLandmark[.neck]
        leftShoulderConfidence = confidenceByLandmark[.leftShoulder]
        rightShoulderConfidence = confidenceByLandmark[.rightShoulder]
    }

    var recognizedCount: Int {
        UpperBodyLandmark.allCases
            .filter(isRecognized)
            .count
    }

    func isRecognized(_ landmark: UpperBodyLandmark) -> Bool {
        confidence(for: landmark).map { $0 >= Self.recognitionThreshold } == true
    }

    func confidence(for landmark: UpperBodyLandmark) -> Float? {
        switch landmark {
        case .neck: neckConfidence
        case .leftShoulder: leftShoulderConfidence
        case .rightShoulder: rightShoulderConfidence
        }
    }
}

nonisolated extension CGImagePropertyOrientation {
    var alignName: String {
        switch self {
        case .up: "up"
        case .upMirrored: "upMirrored"
        case .down: "down"
        case .downMirrored: "downMirrored"
        case .leftMirrored: "leftMirrored"
        case .right: "right"
        case .rightMirrored: "rightMirrored"
        case .left: "left"
        }
    }
}

nonisolated enum VisionCoordinateMapper {
    /// Converts the shared Align top-left overlay contract to the normalized
    /// coordinate space expected by `AVCaptureVideoPreviewLayer`.
    static func captureDevicePoint(fromTopLeftNormalized point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: 1 - point.y)
    }

    /// Converts an already-published PoseOverlay location to the Preview layer
    /// point used by the live renderer. Kept separate from the mask conversion
    /// so the two contracts cannot be confused at call sites.
    static func previewDevicePoint(fromPoseOverlayPoint point: CGPoint) -> CGPoint {
        captureDevicePoint(fromTopLeftNormalized: point)
    }

    /// BlazePose is decoded in the unmirrored camera-buffer coordinate space,
    /// already normalized from the top-left. Preview mirroring is owned by
    /// `AVCaptureVideoPreviewLayer`; applying `1 - x` here would swap sides.
    static func poseOverlayPoint(fromBlazePoseTopLeftPoint point: CGPoint) -> CGPoint {
        point
    }

    /// Testable inverse of the preview conversion. No Vision or image data is
    /// involved; it documents the exact round-trip expected by the overlay.
    static func topLeftNormalizedPoint(fromCaptureDevicePoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: 1 - point.y)
    }

    /// Boundary between the existing face/overlay coordinates and the mask
    /// extractor's top-left coordinates. The face helper's `y = 1 - (...)`
    /// already is the required vertical contract, so this boundary is an
    /// intentional identity and prevents a second y inversion.
    static func segmentationTopLeftPoint(fromFaceOverlayPoint point: CGPoint) -> CGPoint {
        point
    }

    /// Boundary between the top-left mask extractor and the existing
    /// `PoseOverlay` contract. It is the inverse of the face-anchor conversion.
    static func poseOverlayPoint(fromSegmentationTopLeftPoint point: CGPoint) -> CGPoint {
        captureDevicePoint(fromTopLeftNormalized: point)
    }

    static func faceLandmarkCapturePoint(
        from normalizedFacePoint: CGPoint,
        boundingBox: CGRect,
        orientation: CGImagePropertyOrientation
    ) -> CGPoint {
        capturePoint(
            from: CGPoint(
                x: boundingBox.minX + normalizedFacePoint.x * boundingBox.width,
                y: 1 - (boundingBox.minY + normalizedFacePoint.y * boundingBox.height)
            ),
            orientation: orientation
        )
    }

    static func capturePoint(
        from visionPoint: CGPoint,
        orientation: CGImagePropertyOrientation
    ) -> CGPoint {
        switch orientation {
        case .up:
            visionPoint
        case .upMirrored:
            CGPoint(x: 1 - visionPoint.x, y: visionPoint.y)
        case .down:
            CGPoint(x: 1 - visionPoint.x, y: 1 - visionPoint.y)
        case .downMirrored:
            CGPoint(x: visionPoint.x, y: 1 - visionPoint.y)
        case .leftMirrored:
            CGPoint(x: visionPoint.y, y: visionPoint.x)
        case .right:
            CGPoint(x: 1 - visionPoint.y, y: visionPoint.x)
        case .rightMirrored:
            CGPoint(x: 1 - visionPoint.y, y: 1 - visionPoint.x)
        case .left:
            CGPoint(x: visionPoint.y, y: 1 - visionPoint.x)
        }
    }

    /// Vision body points are bottom-left and ROI-local. Align's overlay is
    /// full-image top-left, so both the ROI expansion and Y flip happen here.
    static func bodyOverlayPoint(fromROILocalVisionPoint point: CGPoint, regionOfInterest: CGRect) -> CGPoint {
        CGPoint(
            x: regionOfInterest.minX + point.x * regionOfInterest.width,
            y: 1 - (regionOfInterest.minY + point.y * regionOfInterest.height)
        )
    }

    static func canonicalized(
        _ point: PosePoint,
        orientation: CGImagePropertyOrientation
    ) -> PosePoint {
        PosePoint(
            name: point.name,
            location: capturePoint(from: point.location, orientation: orientation),
            confidence: point.confidence,
            source: point.source
        )
    }
}

nonisolated final class PoseDetector: @unchecked Sendable {

    private let faceRequest = VNDetectFaceLandmarksRequest()
    private let bodyRequest = VNDetectHumanBodyPoseRequest()

    func detectFace(in pixelBuffer: CVPixelBuffer) throws -> FaceDetectionOutput {
        let orientation = CGImagePropertyOrientation.up
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )

        try handler.perform([faceRequest])

        let faceResults = faceRequest.results ?? []
        let primaryFace = faceResults
            .max(by: { area(of: $0.boundingBox) < area(of: $1.boundingBox) })
        let facePolylines = primaryFace.map {
            self.facePolylines(
                from: $0,
                orientation: orientation
            )
        } ?? []
        return FaceDetectionOutput(
            polylines: facePolylines,
            primaryOrientation: primaryFace.map {
                FaceOrientationSignal(
                    rollRadians: $0.roll?.doubleValue,
                    yawRadians: $0.yaw?.doubleValue,
                    pitchRadians: $0.pitch?.doubleValue
                )
            },
            resultCount: faceResults.count,
            facesWithLandmarksCount: faceResults.lazy.filter { $0.landmarks != nil }.count
        )
    }

    func detectBody(
        in pixelBuffer: CVPixelBuffer,
        regionOfInterest: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) throws -> BodyDetectionOutput {
        let orientation = CGImagePropertyOrientation.up
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        bodyRequest.regionOfInterest = regionOfInterest
        defer { bodyRequest.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1) }
        try handler.perform([bodyRequest])

        let bodyResults = bodyRequest.results ?? []
        let detection = try bodyDetection(
            from: bodyResults.first,
            orientation: orientation,
            regionOfInterest: regionOfInterest
        )
        return BodyDetectionOutput(
            points: detection.points,
            resultCount: bodyResults.count,
            hasUpperBody: detection.landmarks.recognizedCount == UpperBodyLandmark.allCases.count,
            upperBodyLandmarks: detection.landmarks
        )
    }

    func combine(
        face: FaceDetectionOutput,
        body: BodyDetectionOutput?,
        bodyStatusAvailable: Bool
    ) -> PoseDetectionOutput {
        let bodyPoints = body?.points ?? []
        let hasUpperBody = bodyStatusAvailable
        let faceGeometry = FaceGeometrySignal.from(polylines: face.polylines)
        let facePointCount = face.polylines.reduce(0) { $0 + $1.locations.count }
        let observation = !face.polylines.isEmpty || hasUpperBody
            ? PoseObservation(
                points: bodyPoints,
                polylines: face.polylines,
                mode: hasUpperBody ? .bodyAvailable : .faceOnly
            )
            : nil
        return PoseDetectionOutput(
            observation: observation,
            diagnostics: PoseInferenceDiagnostics(
                candidateOrientation: "up",
                lockedOrientation: "up",
                faceOrientation: face.primaryOrientation,
                faceGeometry: faceGeometry,
                faceResultCount: face.resultCount,
                facesWithLandmarksCount: face.facesWithLandmarksCount,
                facePointCount: facePointCount,
                bodyResultCount: body?.resultCount ?? 0
            )
        )
    }

    private func facePolylines(
        from observation: VNFaceObservation,
        orientation: CGImagePropertyOrientation
    ) -> [PosePolyline] {
        guard let landmarks = observation.landmarks else { return [] }
        let boundingBox = observation.boundingBox
        return [
            polyline(from: landmarks.faceContour, name: "faceContour", boundingBox: boundingBox, orientation: orientation, isClosed: false),
            polyline(from: landmarks.leftEye, name: "leftEye", boundingBox: boundingBox, orientation: orientation, isClosed: true),
            polyline(from: landmarks.rightEye, name: "rightEye", boundingBox: boundingBox, orientation: orientation, isClosed: true),
            polyline(from: landmarks.leftEyebrow, name: "leftEyebrow", boundingBox: boundingBox, orientation: orientation, isClosed: false),
            polyline(from: landmarks.rightEyebrow, name: "rightEyebrow", boundingBox: boundingBox, orientation: orientation, isClosed: false),
            polyline(from: landmarks.nose, name: "nose", boundingBox: boundingBox, orientation: orientation, isClosed: false),
            polyline(from: landmarks.medianLine, name: "medianLine", boundingBox: boundingBox, orientation: orientation, isClosed: false)
        ].compactMap { $0 }
    }

    private func polyline(
        from region: VNFaceLandmarkRegion2D?,
        name: String,
        boundingBox: CGRect,
        orientation: CGImagePropertyOrientation,
        isClosed: Bool
    ) -> PosePolyline? {
        guard let region, region.pointCount > 1 else { return nil }
        let locations = region.normalizedPoints.map { normalizedPoint in
            VisionCoordinateMapper.faceLandmarkCapturePoint(
                from: normalizedPoint,
                boundingBox: boundingBox,
                orientation: orientation
            )
        }
        return PosePolyline(
            name: name,
            locations: locations,
            source: .face,
            isClosed: isClosed
        )
    }

    private func bodyDetection(
        from observation: VNHumanBodyPoseObservation?,
        orientation: CGImagePropertyOrientation,
        regionOfInterest: CGRect
    ) throws -> (points: [PosePoint], landmarks: UpperBodyLandmarkDiagnostics) {
        guard let observation else { return ([], .empty) }

        var confidences: [UpperBodyLandmark: Float] = [:]
        var points: [PosePoint] = []
        for landmark in UpperBodyLandmark.allCases {
            let point = try observation.recognizedPoint(landmark.visionJointName)
            confidences[landmark] = point.confidence
            guard point.confidence >= UpperBodyLandmarkDiagnostics.recognitionThreshold else {
                continue
            }
            let fullImageTopLeft = VisionCoordinateMapper.bodyOverlayPoint(
                fromROILocalVisionPoint: point.location,
                regionOfInterest: regionOfInterest
            )
            points.append(VisionCoordinateMapper.canonicalized(PosePoint(
                name: landmark.rawValue,
                location: fullImageTopLeft,
                confidence: point.confidence,
                source: .body
            ), orientation: orientation))
        }
        return (points, UpperBodyLandmarkDiagnostics(confidenceByLandmark: confidences))
    }

    private func area(of rectangle: CGRect) -> CGFloat {
        rectangle.width * rectangle.height
    }
}
