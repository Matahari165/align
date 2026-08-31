import CoreGraphics
import Foundation

/// Independent observable families. A family may be partial without making
/// another family unavailable (for example, shoulders remain usable when
/// hips are outside a close webcam crop).
nonisolated enum UpperBodyGeometryFamily: String, CaseIterable, Hashable, Sendable {
    case shoulders
    case neckShoulders
    case arms
    case hips
    case torso
    case head
}

nonisolated enum UpperBodyGeometryQuality: String, Equatable, Sendable {
    case complete
    case partial
    case unavailable
}

nonisolated struct UpperBodyGeometryFamilyStatus: Equatable, Sendable {
    let family: UpperBodyGeometryFamily
    let quality: UpperBodyGeometryQuality
    let observedCount: Int
    let requiredCount: Int

    var isComplete: Bool { quality == .complete }
    var isAvailable: Bool { observedCount > 0 }
}

nonisolated struct UpperBodyDerivedSegment: Equatable, Sendable {
    let family: UpperBodyGeometryFamily
    let name: String
    let startID: UpperBodyLandmarkID
    let endID: UpperBodyLandmarkID
    let start: CGPoint
    let end: CGPoint

    var isValid: Bool {
        start.x.isFinite && start.y.isFinite && end.x.isFinite && end.y.isFinite &&
            (0...1).contains(start.x) && (0...1).contains(start.y) &&
            (0...1).contains(end.x) && (0...1).contains(end.y) &&
            hypot(end.x - start.x, end.y - start.y) > 0.000_001
    }
}

nonisolated struct UpperBodyDerivedAxis: Equatable, Sendable {
    let family: UpperBodyGeometryFamily
    let name: String
    let startIDs: [UpperBodyLandmarkID]
    let endIDs: [UpperBodyLandmarkID]
    let start: CGPoint
    let end: CGPoint

    var isValid: Bool {
        start.x.isFinite && start.y.isFinite && end.x.isFinite && end.y.isFinite &&
            (0...1).contains(start.x) && (0...1).contains(start.y) &&
            (0...1).contains(end.x) && (0...1).contains(end.y) &&
            hypot(end.x - start.x, end.y - start.y) > 0.000_001
    }
}

/// Same-result, scalar/geometry-only snapshot. It is safe to publish across
/// queues because it contains no image, tensor or mutable model state.
nonisolated struct UpperBodyGeometrySnapshot: Equatable, Sendable {
    let generation: UInt64
    let sampleID: UInt64
    let capturedAt: TimeInterval
    let families: [UpperBodyGeometryFamilyStatus]
    let segments: [UpperBodyDerivedSegment]
    let axes: [UpperBodyDerivedAxis]

    func status(for family: UpperBodyGeometryFamily) -> UpperBodyGeometryFamilyStatus {
        families.first { $0.family == family } ?? UpperBodyGeometryFamilyStatus(
            family: family, quality: .unavailable, observedCount: 0, requiredCount: 0
        )
    }

    func segment(named name: String) -> UpperBodyDerivedSegment? {
        segments.first { $0.name == name }
    }

    func axis(named name: String) -> UpperBodyDerivedAxis? {
        axes.first { $0.name == name }
    }
}

nonisolated enum UpperBodyGeometryDeriver {
    private static let requiredLandmarks: [UpperBodyGeometryFamily: [UpperBodyLandmarkID]] = [
        .shoulders: [.leftShoulder, .rightShoulder],
        .neckShoulders: [.neck, .leftShoulder, .rightShoulder],
        .arms: [.leftShoulder, .rightShoulder, .leftElbow, .rightElbow],
        .hips: [.leftHip, .rightHip],
        .torso: [.leftShoulder, .rightShoulder, .leftHip, .rightHip],
        .head: [.nose, .leftEar, .rightEar, .neck]
    ]

    private static let segmentSpecs: [(UpperBodyGeometryFamily, String, UpperBodyLandmarkID, UpperBodyLandmarkID)] = [
        (.shoulders, "ligne-épaules", .leftShoulder, .rightShoulder),
        (.neckShoulders, "cou-épaule-gauche", .neck, .leftShoulder),
        (.neckShoulders, "cou-épaule-droite", .neck, .rightShoulder),
        (.arms, "épaule-coude-gauche", .leftShoulder, .leftElbow),
        (.arms, "épaule-coude-droite", .rightShoulder, .rightElbow),
        (.hips, "ligne-hanches", .leftHip, .rightHip),
        (.torso, "torse-gauche", .leftShoulder, .leftHip),
        (.torso, "torse-droit", .rightShoulder, .rightHip),
        (.head, "ligne-oreilles", .leftEar, .rightEar)
    ]

    static func make(from result: UpperBodyResult) -> UpperBodyGeometrySnapshot {
        var locations: [UpperBodyLandmarkID: CGPoint] = [:]
        // A derived segment is meaningful only for a fresh result. Keeping
        // this gate here prevents a stale/error payload that accidentally
        // retains points from being interpreted as a new observation.
        if result.isFreshGeometry {
            for point in result.points where point.isValid {
                locations[point.id] = point.location
            }
        }

        let families = UpperBodyGeometryFamily.allCases.map { family in
            let required = requiredLandmarks[family] ?? []
            let observedCount = required.reduce(into: 0) { count, id in
                if locations[id] != nil { count += 1 }
            }
            let quality: UpperBodyGeometryQuality
            if observedCount == 0 {
                quality = .unavailable
            } else if observedCount == required.count {
                quality = .complete
            } else {
                quality = .partial
            }
            return UpperBodyGeometryFamilyStatus(
                family: family,
                quality: quality,
                observedCount: observedCount,
                requiredCount: required.count
            )
        }

        let segments: [UpperBodyDerivedSegment] = segmentSpecs.compactMap { spec in
            let (family, name, startID, endID) = spec
            guard let start = locations[startID], let end = locations[endID] else { return nil }
            let segment = UpperBodyDerivedSegment(
                family: family, name: name, startID: startID, endID: endID,
                start: start, end: end
            )
            return segment.isValid ? segment : nil
        }

        var axes: [UpperBodyDerivedAxis] = []
        if let leftShoulder = locations[.leftShoulder],
           let rightShoulder = locations[.rightShoulder],
           let leftHip = locations[.leftHip],
           let rightHip = locations[.rightHip] {
            let shoulderCenter = midpoint(leftShoulder, rightShoulder)
            let hipCenter = midpoint(leftHip, rightHip)
            let axis = UpperBodyDerivedAxis(
                family: .torso,
                name: "axe-torse",
                startIDs: [.leftShoulder, .rightShoulder],
                endIDs: [.leftHip, .rightHip],
                start: shoulderCenter,
                end: hipCenter
            )
            if axis.isValid { axes.append(axis) }
        }
        if let neck = locations[.neck], let nose = locations[.nose] {
            let axis = UpperBodyDerivedAxis(
                family: .head,
                name: "axe-tête",
                startIDs: [.neck],
                endIDs: [.nose],
                start: neck,
                end: nose
            )
            if axis.isValid { axes.append(axis) }
        }

        return UpperBodyGeometrySnapshot(
            generation: result.generation,
            sampleID: result.sampleID,
            capturedAt: result.capturedAt,
            families: families,
            segments: segments,
            axes: axes
        )
    }

    private static func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
        CGPoint(x: (first.x + second.x) * 0.5, y: (first.y + second.y) * 0.5)
    }
}
