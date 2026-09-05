import CoreGraphics
import Foundation
import Vision

/// Translates Vision's frame-local hand/face landmarks into the small,
/// coordinate-only contract consumed by `HandFaceContactMetric`.
///
/// Vision points are normalized from the bottom-left. Align's existing face
/// overlay and metric contract are top-left, so the conversion happens once at
/// this boundary. No image, pixel buffer, or Vision observation leaves it.
nonisolated enum HandFaceVisionAdapter {
    static func handObservations(
        from observations: [VNHumanHandPoseObservation],
        orientation: CGImagePropertyOrientation
    ) -> [HandFaceHandObservation] {
        observations.compactMap { observation in
            var landmarks: [HandFaceHandPoint] = []
            append(
                .thumb,
                joints: [.thumbCMC, .thumbMP, .thumbIP, .thumbTip],
                from: observation,
                orientation: orientation,
                to: &landmarks
            )
            append(
                .indexFinger,
                joints: [.indexMCP, .indexPIP, .indexDIP, .indexTip],
                from: observation,
                orientation: orientation,
                to: &landmarks
            )
            append(
                .middleFinger,
                joints: [.middleMCP, .middlePIP, .middleDIP, .middleTip],
                from: observation,
                orientation: orientation,
                to: &landmarks
            )
            append(
                .ringFinger,
                joints: [.ringMCP, .ringPIP, .ringDIP, .ringTip],
                from: observation,
                orientation: orientation,
                to: &landmarks
            )
            append(
                .littleFinger,
                joints: [.littleMCP, .littlePIP, .littleDIP, .littleTip],
                from: observation,
                orientation: orientation,
                to: &landmarks
            )
            // Vision has no single palm landmark. The wrist and metacarpal
            // bases are the safest 2D approximation of the palm surface.
            append(
                .palm,
                joints: [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP],
                from: observation,
                orientation: orientation,
                to: &landmarks
            )
            guard !landmarks.isEmpty else { return nil }
            return HandFaceHandObservation(landmarks: landmarks)
        }
    }

    static func faceObservation(from face: FaceDetectionOutput) -> HandFaceFaceObservation? {
        let named = Dictionary(
            face.polylines.map { ($0.name, $0.locations.map(metricPoint)) },
            uniquingKeysWith: { first, _ in first }
        )
        let contour = named["faceContour"] ?? []
        var regions: [HandFaceFaceRegion] = []

        appendRegion(named["outerLips"] ?? named["innerLips"] ?? [], kind: .mouth, to: &regions)
        appendRegion(named["nose"] ?? [], kind: .nose, to: &regions)
        appendRegion(named["leftEye"] ?? [], kind: .leftEye, to: &regions)
        appendRegion(named["rightEye"] ?? [], kind: .rightEye, to: &regions)

        // The face request has no dedicated forehead polygon. Keep a bounded
        // upper-face region so a hand over the forehead is distinguished from
        // the generic face surface when the box is available.
        if let boundingBox = face.primaryBoundingBox,
           let forehead = foreheadPoints(from: boundingBox) {
            regions.append(.init(kind: .forehead, points: forehead))
            regions.append(.init(kind: .faceSurface, points: faceSurfacePoints(from: boundingBox)))
        }

        guard !contour.isEmpty || !regions.isEmpty else { return nil }
        return HandFaceFaceObservation(contour: contour, regions: regions)
    }

    private static func append(
        _ landmark: HandFaceHandLandmark,
        joints: [VNHumanHandPoseObservation.JointName],
        from observation: VNHumanHandPoseObservation,
        orientation: CGImagePropertyOrientation,
        to landmarks: inout [HandFaceHandPoint]
    ) {
        for joint in joints {
            do {
                let recognized = try observation.recognizedPoint(joint)
                let point = VisionCoordinateMapper.capturePoint(
                    from: CGPoint(
                        x: recognized.location.x,
                        y: 1 - recognized.location.y
                    ),
                    orientation: orientation
                )
                guard point.x.isFinite, point.y.isFinite,
                      (0...1).contains(point.x), (0...1).contains(point.y),
                      recognized.confidence.isFinite,
                      (0...1).contains(recognized.confidence) else { continue }
                landmarks.append(.init(
                    landmark,
                    x: Double(point.x),
                    y: Double(point.y),
                    confidence: Double(recognized.confidence)
                ))
            } catch {
                continue
            }
        }
    }

    private static func metricPoint(_ point: CGPoint) -> HandFaceMetricPoint {
        .init(x: Double(point.x), y: Double(point.y))
    }

    private static func appendRegion(
        _ points: [HandFaceMetricPoint],
        kind: HandFaceRegionKind,
        to regions: inout [HandFaceFaceRegion]
    ) {
        guard !points.isEmpty else { return }
        regions.append(.init(kind: kind, points: points))
    }

    private static func topLeftBoundingBox(_ boundingBox: CGRect) -> CGRect? {
        guard FaceBoxCandidate.isValid(boundingBox) else { return nil }
        let converted = CGRect(
            x: boundingBox.minX,
            y: 1 - boundingBox.maxY,
            width: boundingBox.width,
            height: boundingBox.height
        )
        guard converted.minX >= 0, converted.minY >= 0,
              converted.maxX <= 1, converted.maxY <= 1 else { return nil }
        return converted
    }

    private static func foreheadPoints(from boundingBox: CGRect) -> [HandFaceMetricPoint]? {
        guard let box = topLeftBoundingBox(boundingBox) else { return nil }
        let insetX = box.width * 0.16
        let top = box.minY + box.height * 0.04
        let bottom = min(box.maxY, box.minY + box.height * 0.42)
        guard bottom > top else { return nil }
        return [
            .init(x: Double(box.minX + insetX), y: Double(top)),
            .init(x: Double(box.maxX - insetX), y: Double(top)),
            .init(x: Double(box.maxX - insetX), y: Double(bottom)),
            .init(x: Double(box.minX + insetX), y: Double(bottom))
        ]
    }

    private static func faceSurfacePoints(from boundingBox: CGRect) -> [HandFaceMetricPoint] {
        guard let box = topLeftBoundingBox(boundingBox) else { return [] }
        let surface = box.insetBy(dx: box.width * 0.04, dy: box.height * 0.03)
        let center = CGPoint(x: surface.midX, y: surface.midY)
        let radiusX = surface.width / 2
        let radiusY = surface.height / 2
        return (0..<24).map { index in
            let angle = (Double(index) / 24) * 2 * .pi
            return .init(
                x: Double(center.x + radiusX * CGFloat(cos(angle))),
                y: Double(center.y + radiusY * CGFloat(sin(angle)))
            )
        }
    }
}
