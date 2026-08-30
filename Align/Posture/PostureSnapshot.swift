import Foundation

nonisolated enum PostureSignalState: Equatable, Sendable {
    case unavailable
    case calibrating
    case neutral
    case pending
    case attention
    case experimental
}

nonisolated enum PostureSignalQuality: Equatable, Sendable {
    case unavailable
    case limited
    case good
}

nonisolated struct PostureMetricPoint: Equatable, Sendable {
    let x: Double
    let y: Double

    var isFinite: Bool { x.isFinite && y.isFinite }
}

/// Mesures éphémères d'une analyse. Aucune image ni coordonnée faciale brute
/// n'est conservée au-delà du calcul de ce snapshot.
nonisolated struct PostureSnapshot: Equatable, Sendable {
    let faceGeneration: UInt64
    let faceTimestamp: TimeInterval
    let faceSampleID: UInt64

    let facePointCount: Int
    let interocularDistance: Double?
    let faceLength: Double?
    let pitchProxy: Double?
    let yawProxy: Double?
    let leftEyeOpeningRatio: Double?
    let rightEyeOpeningRatio: Double?
    let innerBrowDistanceRatio: Double?

    let faceCenter: PostureMetricPoint?
    let leftShoulder: PostureMetricPoint?
    let rightShoulder: PostureMetricPoint?
    let bodyGeneration: UInt64?
    let bodyTimestamp: TimeInterval?
    let bodySampleID: UInt64?

    func isFresh(at now: TimeInterval, ttl: TimeInterval) -> Bool {
        faceTimestamp.isFinite && now.isFinite && ttl.isFinite && ttl > 0 &&
            now >= faceTimestamp && now - faceTimestamp <= ttl
    }

    /// Une paire proche dans le temps n'est jamais présentée comme « même frame ».
    /// Les identifiants restent propres à chaque source et ne sont pas comparés.
    func hasNearbyBody(maximumSkew: TimeInterval) -> Bool {
        guard let bodyGeneration, let bodyTimestamp, let bodySampleID,
              bodyTimestamp.isFinite, maximumSkew.isFinite, maximumSkew >= 0,
              let leftShoulder, let rightShoulder,
              leftShoulder.isFinite, rightShoulder.isFinite else {
            return false
        }
        _ = bodySampleID // L'identité est validée temporellement par l'évaluateur.
        return bodyGeneration == faceGeneration &&
            abs(bodyTimestamp - faceTimestamp) <= maximumSkew
    }

    func sameFaceEvidence(as other: PostureSnapshot) -> Bool {
        faceGeneration == other.faceGeneration && faceTimestamp == other.faceTimestamp &&
            faceSampleID == other.faceSampleID && facePointCount == other.facePointCount &&
            interocularDistance == other.interocularDistance && faceLength == other.faceLength &&
            pitchProxy == other.pitchProxy && yawProxy == other.yawProxy &&
            leftEyeOpeningRatio == other.leftEyeOpeningRatio &&
            rightEyeOpeningRatio == other.rightEyeOpeningRatio &&
            innerBrowDistanceRatio == other.innerBrowDistanceRatio &&
            faceCenter == other.faceCenter
    }

    var faceScale: Double? {
        guard let interocularDistance, let faceLength,
              interocularDistance.isFinite, interocularDistance > 0,
              faceLength.isFinite, faceLength > 0 else { return nil }
        let value = sqrt(interocularDistance) * sqrt(faceLength)
        return value.isFinite ? value : nil
    }

    var meanEyeOpeningRatio: Double? {
        guard let leftEyeOpeningRatio, let rightEyeOpeningRatio,
              leftEyeOpeningRatio.isFinite, rightEyeOpeningRatio.isFinite,
              leftEyeOpeningRatio >= 0, rightEyeOpeningRatio >= 0 else { return nil }
        let value = leftEyeOpeningRatio / 2 + rightEyeOpeningRatio / 2
        return value.isFinite ? value : nil
    }

    func withoutBody() -> PostureSnapshot {
        attaching(nil)
    }

    func attaching(_ body: PostureShoulderSnapshot?) -> PostureSnapshot {
        PostureSnapshot(
            faceGeneration: faceGeneration,
            faceTimestamp: faceTimestamp,
            faceSampleID: faceSampleID,
            facePointCount: facePointCount,
            interocularDistance: interocularDistance,
            faceLength: faceLength,
            pitchProxy: pitchProxy,
            yawProxy: yawProxy,
            leftEyeOpeningRatio: leftEyeOpeningRatio,
            rightEyeOpeningRatio: rightEyeOpeningRatio,
            innerBrowDistanceRatio: innerBrowDistanceRatio,
            faceCenter: faceCenter,
            leftShoulder: body?.leftShoulder,
            rightShoulder: body?.rightShoulder,
            bodyGeneration: body?.generation,
            bodyTimestamp: body?.timestamp,
            bodySampleID: body?.sampleID
        )
    }

    func shoulderWidth(maximumSkew: TimeInterval = 0.30) -> Double? {
        guard hasNearbyBody(maximumSkew: maximumSkew),
              let leftShoulder, let rightShoulder,
              leftShoulder.isFinite, rightShoulder.isFinite else { return nil }
        let value = hypot(rightShoulder.x - leftShoulder.x, rightShoulder.y - leftShoulder.y)
        return value.isFinite && value > 0 ? value : nil
    }

    func shoulderElevation(maximumSkew: TimeInterval = 0.30) -> Double? {
        guard let faceCenter, faceCenter.isFinite, let scale = faceScale,
              let leftShoulder, let rightShoulder,
              leftShoulder.isFinite, rightShoulder.isFinite,
              hasNearbyBody(maximumSkew: maximumSkew) else { return nil }
        let midpointY = leftShoulder.y / 2 + rightShoulder.y / 2
        let value = (faceCenter.y - midpointY) / scale
        return value.isFinite ? value : nil
    }

    func headForwardRatio(maximumSkew: TimeInterval = 0.30) -> Double? {
        guard let scale = faceScale, let width = shoulderWidth(maximumSkew: maximumSkew) else {
            return nil
        }
        let value = scale / width
        return value.isFinite && value > 0 ? value : nil
    }
}

nonisolated struct PostureShoulderSnapshot: Equatable, Sendable {
    let generation: UInt64
    let timestamp: TimeInterval
    let sampleID: UInt64
    let leftShoulder: PostureMetricPoint
    let rightShoulder: PostureMetricPoint

    var isValid: Bool {
        timestamp.isFinite && leftShoulder.isFinite && rightShoulder.isFinite
    }
}

/// Fusion déterministe de deux sources asynchrones. Elle peut réémettre la
/// dernière face lorsqu'un nouveau corps arrive, mais ne fabrique jamais une
/// identité « même frame ».
nonisolated struct PostureAsyncFusion: Sendable {
    let maximumSkew: TimeInterval
    private var latestFace: PostureSnapshot?
    private var latestBody: PostureShoulderSnapshot?
    private var bodyWatermark: PostureSourceWatermark?

    init?(maximumSkew: TimeInterval = 0.30) {
        guard maximumSkew.isFinite, maximumSkew >= 0 else { return nil }
        self.maximumSkew = maximumSkew
    }

    mutating func reset() {
        latestFace = nil
        latestBody = nil
        bodyWatermark = nil
    }

    mutating func ingestFace(_ input: PostureSnapshot) -> PostureSnapshot? {
        let face = input.withoutBody()
        guard face.faceTimestamp.isFinite, face.faceSampleID > 0 else { return nil }
        if let latestFace {
            if face.sameFaceEvidence(as: latestFace) { return nil }
            guard face.faceGeneration >= latestFace.faceGeneration else { return nil }
            if face.faceGeneration == latestFace.faceGeneration {
                guard isNewer(timestamp: face.faceTimestamp, sampleID: face.faceSampleID,
                              than: latestFace.faceTimestamp,
                              sampleID: latestFace.faceSampleID),
                      face.faceSampleID != latestFace.faceSampleID else { return nil }
            } else if face.faceTimestamp <= latestFace.faceTimestamp {
                return nil
            }
        }
        latestFace = face
        if latestBody?.generation != face.faceGeneration { latestBody = nil }
        return mergedFace()
    }

    mutating func ingestBody(_ body: PostureShoulderSnapshot) -> PostureSnapshot? {
        guard body.isValid, body.sampleID > 0 else { return nil }
        if let bodyWatermark {
            guard body.generation >= bodyWatermark.generation else { return nil }
            if body.generation == bodyWatermark.generation {
                if body.timestamp == bodyWatermark.timestamp &&
                    body.sampleID == bodyWatermark.sampleID { return nil }
                guard isNewer(timestamp: body.timestamp, sampleID: body.sampleID,
                              than: bodyWatermark.timestamp,
                              sampleID: bodyWatermark.sampleID),
                      body.sampleID != bodyWatermark.sampleID else { return nil }
            } else if body.timestamp <= bodyWatermark.timestamp {
                return nil
            }
        }
        bodyWatermark = .init(generation: body.generation, timestamp: body.timestamp,
                              sampleID: body.sampleID)
        latestBody = body
        return mergedFace(requireNearbyBody: true)
    }

    /// `partial`, `lost` et `technicalError` doivent appeler cette méthode :
    /// elle purge la géométrie sans faire reculer le watermark de la source.
    mutating func discardBody(
        generation: UInt64,
        timestamp: TimeInterval,
        sampleID: UInt64
    ) -> PostureSnapshot? {
        guard timestamp.isFinite, sampleID > 0 else { return nil }
        if let bodyWatermark {
            guard generation >= bodyWatermark.generation else { return nil }
            if generation == bodyWatermark.generation {
                guard isNewer(timestamp: timestamp, sampleID: sampleID,
                              than: bodyWatermark.timestamp,
                              sampleID: bodyWatermark.sampleID),
                      sampleID != bodyWatermark.sampleID else { return nil }
            } else if timestamp <= bodyWatermark.timestamp {
                return nil
            }
        }
        bodyWatermark = .init(generation: generation, timestamp: timestamp, sampleID: sampleID)
        latestBody = nil
        guard latestFace?.faceGeneration == generation else { return nil }
        return latestFace?.withoutBody()
    }

    private func mergedFace(requireNearbyBody: Bool = false) -> PostureSnapshot? {
        guard let latestFace else { return nil }
        guard let latestBody, latestBody.generation == latestFace.faceGeneration,
              abs(latestBody.timestamp - latestFace.faceTimestamp) <= maximumSkew else {
            return requireNearbyBody ? nil : latestFace
        }
        return latestFace.attaching(latestBody)
    }
}

private nonisolated struct PostureSourceWatermark: Sendable {
    let generation: UInt64
    let timestamp: TimeInterval
    let sampleID: UInt64
}

private nonisolated func isNewer(
    timestamp: TimeInterval,
    sampleID: UInt64,
    than previousTimestamp: TimeInterval,
    sampleID previousSampleID: UInt64
) -> Bool {
    timestamp > previousTimestamp ||
        (timestamp == previousTimestamp && sampleID > previousSampleID)
}

nonisolated struct PostureSignalEvaluation: Equatable, Sendable {
    let state: PostureSignalState
    let value: Double?
    let quality: PostureSignalQuality
    let detail: String
    let isExperimental: Bool

    init(
        state: PostureSignalState,
        value: Double?,
        quality: PostureSignalQuality,
        detail: String,
        isExperimental: Bool = false
    ) {
        self.state = state
        self.value = value
        self.quality = quality
        self.detail = detail
        self.isExperimental = isExperimental
    }
}

nonisolated struct PostureEvaluationSet: Equatable, Sendable {
    let headProximity: PostureSignalEvaluation
    let relativeHeadPosition: PostureSignalEvaluation
    let estimatedBlinks: PostureSignalEvaluation
    let experimentalForwardHead: PostureSignalEvaluation
    let elevatedShoulders: PostureSignalEvaluation
    let narrowedBrows: PostureSignalEvaluation
}
