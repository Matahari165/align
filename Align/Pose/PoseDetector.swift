import CoreGraphics
import CoreVideo
import ImageIO
import Vision

nonisolated enum PosePointSource: String, Sendable {
    case face
    case body
}

nonisolated struct PosePoint: Identifiable, Sendable {
    let name: String
    let location: CGPoint
    let confidence: Float
    let source: PosePointSource

    var id: String { "\(source.rawValue).\(name)" }
}

nonisolated struct PosePolyline: Identifiable, Sendable {
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
    let faceResultCount: Int
    let facesWithLandmarksCount: Int
    let facePointCount: Int
    let bodyResultCount: Int
}

nonisolated struct PoseDetectionOutput: Sendable {
    let observation: PoseObservation?
    let diagnostics: PoseInferenceDiagnostics
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
    static func captureDevicePoint(from canonicalPoint: CGPoint) -> CGPoint {
        CGPoint(x: canonicalPoint.x, y: 1 - canonicalPoint.y)
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

    func detect(in pixelBuffer: CVPixelBuffer) throws -> PoseDetectionOutput {
        let orientation = CGImagePropertyOrientation.up
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )

        try handler.perform([faceRequest, bodyRequest])

        let faceResults = faceRequest.results ?? []
        let bodyResults = bodyRequest.results ?? []
        let primaryFace = faceResults
            .max(by: { area(of: $0.boundingBox) < area(of: $1.boundingBox) })
        let facePolylines = primaryFace.map {
            self.facePolylines(
                from: $0,
                orientation: orientation
            )
        } ?? []
        let bodyPoints = try bodyPoints(
            from: bodyResults.first,
            orientation: orientation
        )
        let bodyNames = Set(bodyPoints.map(\.name))
        let hasUpperBody = bodyNames.isSuperset(of: ["neck", "leftShoulder", "rightShoulder"])
        let facePointCount = facePolylines.reduce(0) { $0 + $1.locations.count }
        let observation = !facePolylines.isEmpty || hasUpperBody
            ? PoseObservation(
                points: bodyPoints,
                polylines: facePolylines,
                mode: hasUpperBody ? .bodyAvailable : .faceOnly
            )
            : nil
        return PoseDetectionOutput(
            observation: observation,
            diagnostics: PoseInferenceDiagnostics(
                candidateOrientation: orientation.alignName,
                lockedOrientation: orientation.alignName,
                faceResultCount: faceResults.count,
                facesWithLandmarksCount: faceResults.lazy.filter { $0.landmarks != nil }.count,
                facePointCount: facePointCount,
                bodyResultCount: bodyResults.count
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
