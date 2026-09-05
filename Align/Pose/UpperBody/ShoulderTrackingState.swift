import CoreGraphics
import Foundation

/// Product-facing shoulder availability, independent from the active engine.
nonisolated enum ShoulderTrackingState: String, Sendable {
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

/// Filtre court appliqué uniquement aux deux épaules avant de publier la
/// géométrie RTMPose. Il atténue les oscillations d'un pixel ou deux sans
/// conserver un point lorsqu'il disparaît : une frame incomplète reste donc
/// incomplète dans la couche suivante.
nonisolated struct UpperBodyShoulderStabilizer: Equatable, Sendable {
    private static let maximumGap: TimeInterval = 1.5
    private static let smoothingTimeConstant: TimeInterval = 0.18
    private static let minimumAlpha: CGFloat = 0.68
    private static let maximumAlpha: CGFloat = 0.92
    private static let fastMovementDistance: CGFloat = 0.12

    private var generation: UInt64?
    private var regionSource: UpperBodyRegionOfInterestSource?
    private var lastSampleID: UInt64?
    private var lastCapturedAt: TimeInterval?
    private var leftShoulder: CGPoint?
    private var rightShoulder: CGPoint?

    mutating func reset() {
        generation = nil
        regionSource = nil
        lastSampleID = nil
        lastCapturedAt = nil
        leftShoulder = nil
        rightShoulder = nil
    }

    mutating func stabilize(
        points: [UpperBodyPoint],
        generation: UInt64,
        sampleID: UInt64,
        capturedAt: TimeInterval,
        regionSource: UpperBodyRegionOfInterestSource?
    ) -> [UpperBodyPoint] {
        guard generation > 0, sampleID > 0, capturedAt.isFinite else {
            reset()
            return points
        }

        let rawLeftPoint = points.first(where: { $0.id == .leftShoulder && $0.isValid })
        let rawRightPoint = points.first(where: { $0.id == .rightShoulder && $0.isValid })
        let rawLeft = rawLeftPoint?.location
        let rawRight = rawRightPoint?.location
        let rawPairIsGood = rawLeftPoint?.quality == .good && rawRightPoint?.quality == .good
        let smoothableLeft = rawPairIsGood ? rawLeft : nil
        let smoothableRight = rawPairIsGood ? rawRight : nil
        let sameStream = self.generation == generation &&
            self.regionSource == regionSource &&
            (lastSampleID.map { sampleID > $0 } ?? true) &&
            (lastCapturedAt.map { capturedAt > $0 && capturedAt - $0 <= Self.maximumGap } ?? true)

        guard sameStream, let smoothableLeft, let smoothableRight,
              let previousLeft = leftShoulder,
              let previousRight = rightShoulder,
              let previousTimestamp = lastCapturedAt else {
            self.generation = generation
            self.regionSource = regionSource
            self.lastSampleID = sampleID
            self.lastCapturedAt = capturedAt
            self.leftShoulder = smoothableLeft
            self.rightShoulder = smoothableRight
            return points
        }

        let elapsed = capturedAt - previousTimestamp
        let baseAlpha = CGFloat(elapsed / (Self.smoothingTimeConstant + elapsed))
        let movement = max(distance(smoothableLeft, previousLeft),
                           distance(smoothableRight, previousRight))
        let alpha = movement >= Self.fastMovementDistance
            ? Self.maximumAlpha
            : min(Self.maximumAlpha, max(Self.minimumAlpha, baseAlpha))
        let filteredLeft = blend(previousLeft, smoothableLeft, alpha: alpha)
        let filteredRight = blend(previousRight, smoothableRight, alpha: alpha)

        self.generation = generation
        self.regionSource = regionSource
        self.lastSampleID = sampleID
        self.lastCapturedAt = capturedAt
        self.leftShoulder = filteredLeft
        self.rightShoulder = filteredRight

        return points.map { point in
            switch point.id {
            case .leftShoulder:
                point.replacingLocation(filteredLeft)
            case .rightShoulder:
                point.replacingLocation(filteredRight)
            default:
                point
            }
        }
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func blend(_ previous: CGPoint, _ current: CGPoint, alpha: CGFloat) -> CGPoint {
        CGPoint(
            x: previous.x + (current.x - previous.x) * alpha,
            y: previous.y + (current.y - previous.y) * alpha
        )
    }
}

private extension UpperBodyPoint {
    nonisolated func replacingLocation(_ location: CGPoint) -> Self {
        Self(id: id, location: location, confidence: confidence,
             quality: quality, provenance: provenance)
    }
}
