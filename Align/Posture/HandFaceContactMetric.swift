import Foundation

/// A normalized Vision-like point. Coordinates are expected in [0, 1], with
/// confidence expressed in the same range.
nonisolated struct HandFaceMetricPoint: Equatable, Sendable {
    let x: Double
    let y: Double
    let confidence: Double

    init(x: Double, y: Double, confidence: Double = 1) {
        self.x = x
        self.y = y
        self.confidence = confidence
    }

    var isNormalized: Bool {
        x.isFinite && y.isFinite && confidence.isFinite &&
            (0...1).contains(x) && (0...1).contains(y) &&
            (0...1).contains(confidence)
    }
}

nonisolated enum HandFaceRegionKind: String, CaseIterable, Sendable {
    case mouth
    case nose
    case leftEye
    case rightEye
    case forehead
    case faceSurface
}

nonisolated struct HandFaceFaceRegion: Equatable, Sendable {
    let kind: HandFaceRegionKind
    let points: [HandFaceMetricPoint]

    init(kind: HandFaceRegionKind, points: [HandFaceMetricPoint]) {
        self.kind = kind
        self.points = points
    }
}

/// Face geometry can be populated directly from Vision landmarks. A region
/// may contain one landmark, a short polyline, or a polygon-like outline.
nonisolated struct HandFaceFaceObservation: Equatable, Sendable {
    let contour: [HandFaceMetricPoint]
    let regions: [HandFaceFaceRegion]

    init(
        contour: [HandFaceMetricPoint],
        regions: [HandFaceFaceRegion] = []
    ) {
        self.contour = contour
        self.regions = regions
    }

    init(
        contour: [HandFaceMetricPoint],
        mouth: [HandFaceMetricPoint] = [],
        nose: [HandFaceMetricPoint] = [],
        leftEye: [HandFaceMetricPoint] = [],
        rightEye: [HandFaceMetricPoint] = [],
        forehead: [HandFaceMetricPoint] = []
    ) {
        self.init(
            contour: contour,
            regions: [
                (HandFaceRegionKind.mouth, mouth),
                (HandFaceRegionKind.nose, nose),
                (HandFaceRegionKind.leftEye, leftEye),
                (HandFaceRegionKind.rightEye, rightEye),
                (HandFaceRegionKind.forehead, forehead)
            ].compactMap { kind, points in
                points.isEmpty ? nil : HandFaceFaceRegion(kind: kind, points: points)
            }
        )
    }
}

nonisolated enum HandFaceHandLandmark: String, CaseIterable, Sendable {
    case thumb
    case indexFinger
    case middleFinger
    case ringFinger
    case littleFinger
    case palm
}

nonisolated struct HandFaceHandPoint: Equatable, Sendable {
    let landmark: HandFaceHandLandmark
    let point: HandFaceMetricPoint

    init(_ landmark: HandFaceHandLandmark, x: Double, y: Double, confidence: Double = 1) {
        self.landmark = landmark
        self.point = HandFaceMetricPoint(x: x, y: y, confidence: confidence)
    }

    init(landmark: HandFaceHandLandmark, point: HandFaceMetricPoint) {
        self.landmark = landmark
        self.point = point
    }
}

nonisolated struct HandFaceHandObservation: Equatable, Sendable {
    let landmarks: [HandFaceHandPoint]

    init(landmarks: [HandFaceHandPoint]) {
        self.landmarks = landmarks
    }
}

nonisolated struct HandFaceContactMetricConfiguration: Equatable, Sendable {
    /// Proposed starting value: contact must persist for 2.5 seconds.
    var persistenceDuration: TimeInterval = 2.5
    /// The point must be within this face-width ratio to enter contact.
    var enterDistanceRatio: Double = 0.20
    /// Once in contact, this wider ratio prevents jitter around the boundary.
    var exitDistanceRatio: Double = 0.30
    /// Missing or low-confidence samples inside this window do not break a hold.
    var briefLossGrace: TimeInterval = 0.35
    /// A confirmed separated pose must last this long before rearming.
    var stableExitDuration: TimeInterval = 0.75
    var minimumConfidence: Double = 0.55

    var isValid: Bool {
        persistenceDuration.isFinite && persistenceDuration > 0 &&
            enterDistanceRatio.isFinite && enterDistanceRatio >= 0 &&
            exitDistanceRatio.isFinite && exitDistanceRatio > enterDistanceRatio &&
            briefLossGrace.isFinite && briefLossGrace >= 0 &&
            stableExitDuration.isFinite && stableExitDuration > 0 &&
            minimumConfidence.isFinite && (0...1).contains(minimumConfidence)
    }
}

nonisolated enum HandFaceContactObservationQuality: String, Sendable {
    case unavailable
    case limited
    case good
}

/// Geometry-only output for one analysis tick. It is deliberately separate
/// from the temporal event so a runtime can publish a metric evidence on each
/// tick without causing a notification.
nonisolated struct HandFaceContactObservation: Equatable, Sendable {
    let observedAt: TimeInterval?
    let distanceRatio: Double?
    let quality: HandFaceContactObservationQuality
    let isContact: Bool
    let zone: HandFaceRegionKind?
    let handIndex: Int?
    let landmark: HandFaceHandLandmark?

    static let unavailable = Self(
        observedAt: nil,
        distanceRatio: nil,
        quality: .unavailable,
        isContact: false,
        zone: nil,
        handIndex: nil,
        landmark: nil
    )

    fileprivate func at(_ timestamp: TimeInterval) -> Self {
        .init(
            observedAt: timestamp,
            distanceRatio: distanceRatio,
            quality: quality,
            isContact: isContact,
            zone: zone,
            handIndex: handIndex,
            landmark: landmark
        )
    }
}

/// Scalar hand/face evidence plus the runtime identity needed to reject late
/// frames. Landmarks never cross this boundary.
nonisolated struct HandFaceContactSample: Equatable, Sendable {
    let generation: UInt64
    let sampleID: UInt64
    let capturedAt: TimeInterval
    let contextKey: String
    let observation: HandFaceContactObservation

    var hasValidIdentity: Bool {
        generation > 0 && sampleID > 0 && capturedAt.isFinite && !contextKey.isEmpty
    }
}

nonisolated enum HandFaceContactMetricEvent: Equatable, Sendable {
    case none
    case sustainedContact(HandFaceContactEvidence)
}

nonisolated struct HandFaceContactEvidence: Equatable, Sendable {
    let at: TimeInterval
    let duration: TimeInterval
    let distanceRatio: Double
    let handIndex: Int
    let landmark: HandFaceHandLandmark
    let region: HandFaceRegionKind?
}

nonisolated enum HandFaceContactMetricPhase: Equatable, Sendable {
    case idle
    case tracking(since: TimeInterval)
    case alerted
}

/// Pure temporal policy. It only consumes normalized landmarks and timestamps;
/// Vision, camera capture, and notification delivery stay outside this type.
nonisolated struct HandFaceContactMetric: Sendable {
    let configuration: HandFaceContactMetricConfiguration
    private(set) var phase: HandFaceContactMetricPhase = .idle
    private(set) var currentObservation: HandFaceContactObservation = .unavailable

    private var lastTimestamp: TimeInterval?
    private var lastUsableTimestamp: TimeInterval?
    private var exitStartedAt: TimeInterval?

    init(configuration: HandFaceContactMetricConfiguration = .init()) {
        self.configuration = configuration
    }

    mutating func reset() {
        phase = .idle
        currentObservation = .unavailable
        lastTimestamp = nil
        lastUsableTimestamp = nil
        exitStartedAt = nil
    }

    mutating func consume(
        face: HandFaceFaceObservation?,
        hands: [HandFaceHandObservation],
        now: TimeInterval
    ) -> HandFaceContactMetricEvent {
        guard configuration.isValid, now.isFinite else { return .none }
        if let lastTimestamp, now < lastTimestamp { return .none }
        lastTimestamp = now

        let observation = Self.observe(face: face, hands: hands, configuration: configuration)
        currentObservation = observation.at(now)
        guard observation.quality == .good,
              let distanceRatio = observation.distanceRatio,
              let handIndex = observation.handIndex,
              let landmark = observation.landmark else {
            return consumeUnavailable(at: now)
        }
        lastUsableTimestamp = now

        let evidence = HandFaceContactEvidence(
            at: now,
            duration: 0,
            distanceRatio: distanceRatio,
            handIndex: handIndex,
            landmark: landmark,
            region: observation.zone
        )

        switch phase {
        case .idle:
            guard distanceRatio <= configuration.enterDistanceRatio else { return .none }
            phase = .tracking(since: now)
            return .none

        case .tracking(let since):
            guard distanceRatio <= configuration.exitDistanceRatio else {
                phase = .idle
                return .none
            }
            guard now >= since, now - since >= configuration.persistenceDuration else { return .none }
            phase = .alerted
            exitStartedAt = nil
            return .sustainedContact(
                .init(
                    at: now,
                    duration: now - since,
                    distanceRatio: evidence.distanceRatio,
                    handIndex: evidence.handIndex,
                    landmark: evidence.landmark,
                    region: evidence.region
                )
            )

        case .alerted:
            if evidence.distanceRatio <= configuration.exitDistanceRatio {
                exitStartedAt = nil
                return .none
            }

            if exitStartedAt == nil { exitStartedAt = now }
            guard let exitStartedAt,
                  now >= exitStartedAt,
                  now - exitStartedAt >= configuration.stableExitDuration else {
                return .none
            }
            phase = .idle
            self.exitStartedAt = nil
            return .none
        }
    }

    /// Pure geometry observation for a single Vision-like tick. It has no
    /// temporal state and never emits an alert.
    static func observe(
        face: HandFaceFaceObservation?,
        hands: [HandFaceHandObservation],
        configuration: HandFaceContactMetricConfiguration = .init()
    ) -> HandFaceContactObservation {
        guard configuration.isValid,
              let face,
              let geometry = FaceGeometry(face: face, minimumConfidence: configuration.minimumConfidence) else {
            return .unavailable
        }

        var best: (distance: Double, handIndex: Int, landmark: HandFaceHandLandmark, region: HandFaceRegionKind?)?
        for (handIndex, hand) in hands.enumerated() {
            for landmark in hand.landmarks where landmark.point.isNormalized &&
                landmark.point.confidence >= configuration.minimumConfidence {
                guard let candidate = geometry.closestDistance(to: landmark.point) else { continue }
                let region = candidate.region
                if best == nil || candidate.distance < best!.distance {
                    best = (candidate.distance, handIndex, landmark.landmark, region)
                }
            }
        }

        guard let best else {
            return .init(
                observedAt: nil,
                distanceRatio: nil,
                quality: .limited,
                isContact: false,
                zone: nil,
                handIndex: nil,
                landmark: nil
            )
        }
        let ratio = best.distance / geometry.width
        guard ratio.isFinite else { return .unavailable }
        return .init(
            observedAt: nil,
            distanceRatio: ratio,
            quality: .good,
            isContact: ratio <= configuration.enterDistanceRatio,
            zone: best.region,
            handIndex: best.handIndex,
            landmark: best.landmark
        )
    }

    private mutating func consumeUnavailable(at now: TimeInterval) -> HandFaceContactMetricEvent {
        guard let lastUsableTimestamp, now >= lastUsableTimestamp else {
            if case .tracking = phase {
                phase = .idle
            }
            return .none
        }
        guard now - lastUsableTimestamp <= configuration.briefLossGrace else {
            // A missing hand/face sample cannot prove physical separation. It
            // may, however, last long enough that keeping the episode locked
            // would make a later, genuinely new contact impossible to alert on.
            phase = .idle
            exitStartedAt = nil
            return .none
        }
        // A missing hand/face sample cannot prove physical separation. It may,
        // within this grace window preserve a pending contact without
        // manufacturing a new duration from the missing sample.
        return .none
    }

}

private nonisolated struct FaceGeometry {
    let contour: [HandFaceMetricPoint]
    let regions: [(kind: HandFaceRegionKind, points: [HandFaceMetricPoint])]
    let width: Double

    init?(face: HandFaceFaceObservation, minimumConfidence: Double) {
        let validContour = face.contour.filter {
            $0.isNormalized && $0.confidence >= minimumConfidence
        }
        let validRegions = face.regions.compactMap { region -> (HandFaceRegionKind, [HandFaceMetricPoint])? in
            let points = region.points.filter {
                $0.isNormalized && $0.confidence >= minimumConfidence
            }
            return points.isEmpty ? nil : (region.kind, points)
        }
        let allPoints = validContour + validRegions.flatMap(\.1)
        guard allPoints.count >= 2,
              let minimumX = allPoints.map(\.x).min(),
              let maximumX = allPoints.map(\.x).max() else { return nil }
        let width = maximumX - minimumX
        guard width.isFinite, width > 0 else { return nil }
        contour = validContour
        regions = validRegions.map { (kind: $0.0, points: $0.1) }
        self.width = width
    }

    func closestDistance(to point: HandFaceMetricPoint) -> (distance: Double, region: HandFaceRegionKind?)? {
        var best: (Double, HandFaceRegionKind?)?
        if contour.count >= 2 {
            best = (distanceToPolyline(point, contour), nil)
        }
        for region in regions {
            let distance = distanceToPolygon(point, region.points)
            if best == nil || distance < best!.0 { best = (distance, region.kind) }
        }
        guard let best else { return nil }
        return (best.0, best.1)
    }
}

private nonisolated func distanceToPolyline(_ point: HandFaceMetricPoint, _ polyline: [HandFaceMetricPoint]) -> Double {
    guard let first = polyline.first else { return .infinity }
    guard polyline.count >= 2 else { return hypot(point.x - first.x, point.y - first.y) }
    var minimum = Double.infinity
    for index in 0..<(polyline.count - 1) {
        minimum = min(minimum, distanceToSegment(point, polyline[index], polyline[index + 1]))
    }
    return minimum
}

private nonisolated func distanceToPolygon(_ point: HandFaceMetricPoint, _ polygon: [HandFaceMetricPoint]) -> Double {
    guard let first = polygon.first else { return .infinity }
    if polygon.count == 1 { return hypot(point.x - first.x, point.y - first.y) }

    var minimum = Double.infinity
    for index in polygon.indices {
        let next = polygon.index(after: index) == polygon.endIndex
            ? polygon.startIndex
            : polygon.index(after: index)
        minimum = min(minimum, distanceToSegment(point, polygon[index], polygon[next]))
    }
    if polygon.count >= 3 && isInsidePolygon(point, polygon) { return 0 }
    return minimum
}

private nonisolated func distanceToSegment(
    _ point: HandFaceMetricPoint,
    _ start: HandFaceMetricPoint,
    _ end: HandFaceMetricPoint
) -> Double {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
    let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
    let clamped = min(1, max(0, projection))
    return hypot(point.x - (start.x + clamped * dx), point.y - (start.y + clamped * dy))
}

private nonisolated func isInsidePolygon(_ point: HandFaceMetricPoint, _ polygon: [HandFaceMetricPoint]) -> Bool {
    var inside = false
    var previous = polygon.count - 1
    for current in polygon.indices {
        let currentPoint = polygon[current]
        let previousPoint = polygon[previous]
        let crosses = (currentPoint.y > point.y) != (previousPoint.y > point.y)
        if crosses {
            let intersectionX = (previousPoint.x - currentPoint.x) *
                (point.y - currentPoint.y) / (previousPoint.y - currentPoint.y) + currentPoint.x
            if point.x < intersectionX { inside.toggle() }
        }
        previous = current
    }
    return inside
}
