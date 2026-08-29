import CoreGraphics
import CoreVideo
import ImageIO
import Vision

nonisolated enum PosePointSource: String, Sendable {
    case face
    case body
    case silhouette
}

nonisolated struct PosePoint: Identifiable, Sendable {
    let name: String
    let location: CGPoint
    let confidence: Float
    let source: PosePointSource

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

    var confidenceByName: [String: Float] {
        Dictionary(uniqueKeysWithValues: points.map { ($0.name, $0.confidence) })
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
    private let bodyJoints: [VNHumanBodyPoseObservation.JointName] = [
        .neck,
        .leftShoulder,
        .rightShoulder
    ]

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

    func detectBody(in pixelBuffer: CVPixelBuffer) throws -> BodyDetectionOutput {
        let orientation = CGImagePropertyOrientation.up
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        try handler.perform([bodyRequest])

        let bodyResults = bodyRequest.results ?? []
        let points = try bodyPoints(from: bodyResults.first, orientation: orientation)
        let names = Set(points.map(\.name))
        return BodyDetectionOutput(
            points: points,
            resultCount: bodyResults.count,
            hasUpperBody: names.isSuperset(of: ["neck", "leftShoulder", "rightShoulder"])
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

    private func bodyPoints(
        from observation: VNHumanBodyPoseObservation?,
        orientation: CGImagePropertyOrientation
    ) throws -> [PosePoint] {
        guard let observation else { return [] }

        return try bodyJoints.compactMap { jointName in
            let point = try observation.recognizedPoint(jointName)
            guard point.confidence >= 0.35 else { return nil }
            return VisionCoordinateMapper.canonicalized(PosePoint(
                name: jointName.rawValue.rawValue,
                location: point.location,
                confidence: point.confidence,
                source: .body
            ), orientation: orientation)
        }
    }

    private func area(of rectangle: CGRect) -> CGFloat {
        rectangle.width * rectangle.height
    }
}
