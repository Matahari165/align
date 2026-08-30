import Foundation

nonisolated struct PostureEvaluatorConfiguration: Equatable, Sendable {
    var ttl: TimeInterval = 0.75
    var maximumSampleGap: TimeInterval = 0.75
    var requiredDuration: TimeInterval = 1.5
    var minimumFacePointCount = 40
    var maximumAbsoluteYawProxy = 0.35
    var maximumAbsoluteYawForProximity = 0.20
    var maximumAbsoluteRollForProximityDegrees = 20.0
    var maximumFaceScaleDisagreement = 0.12
    var proximityRequiredDuration: TimeInterval = 2.0
    var maximumBodySkew: TimeInterval = 0.30
    var bodyTTL: TimeInterval = 1.20
    var maximumBodySampleGap: TimeInterval = 1.50
    var browEnterContraction = 0.08
    var browExitContraction = 0.04
    var browRequiredDuration: TimeInterval = 0.40

    var isValid: Bool {
        ttl.isFinite && ttl > 0 && maximumSampleGap.isFinite && maximumSampleGap > 0 &&
            requiredDuration.isFinite && requiredDuration >= 0 && minimumFacePointCount > 0 &&
            maximumAbsoluteYawProxy.isFinite && maximumAbsoluteYawProxy >= 0 &&
            maximumAbsoluteYawForProximity.isFinite &&
            maximumAbsoluteYawForProximity >= 0 &&
            maximumAbsoluteYawForProximity <= maximumAbsoluteYawProxy &&
            maximumAbsoluteRollForProximityDegrees.isFinite &&
            maximumAbsoluteRollForProximityDegrees >= 0 &&
            maximumFaceScaleDisagreement.isFinite && maximumFaceScaleDisagreement >= 0 &&
            proximityRequiredDuration.isFinite && proximityRequiredDuration >= 0 &&
            maximumBodySkew.isFinite && maximumBodySkew >= 0 &&
            bodyTTL.isFinite && bodyTTL > 0 && maximumBodySampleGap.isFinite &&
            maximumBodySampleGap > 0 && browEnterContraction.isFinite &&
            browExitContraction.isFinite && browEnterContraction > browExitContraction &&
            browExitContraction >= 0 && browRequiredDuration.isFinite &&
            browRequiredDuration >= 0
    }
}

nonisolated struct PostureEvaluatorSuite: Sendable {
    let configuration: PostureEvaluatorConfiguration

    private var generation: UInt64?
    private var lastFace: PostureSnapshot?
    private var lastBodyTimestamp: TimeInterval?
    private var lastBodySampleID: UInt64?
    private var faceCache: FaceEvaluationCache?
    private var bodyCache: BodyEvaluationCache?
    private var headProximity = SustainedMetric(enter: 1.25, exit: 1.15)
    private var relativeHeadPosition = SustainedMetric(enter: 0.10, exit: 0.06)
    private var forwardHead = SustainedMetric(enter: 1.12, exit: 1.07)
    private var elevatedShoulders = SustainedMetric(enter: 0.08, exit: 0.04)
    private var narrowedBrows: SustainedMetric
    private var blinks = BlinkMetric()

    init(configuration: PostureEvaluatorConfiguration = .init()) {
        self.configuration = configuration
        narrowedBrows = SustainedMetric(
            enter: configuration.browEnterContraction,
            exit: configuration.browExitContraction
        )
    }

    mutating func reset() {
        generation = nil
        lastFace = nil
        lastBodyTimestamp = nil
        lastBodySampleID = nil
        faceCache = nil
        bodyCache = nil
        resetTransient()
        blinks = BlinkMetric()
    }

    mutating func consume(
        _ snapshot: PostureSnapshot?,
        calibration: PostureCalibration?,
        now: TimeInterval,
        calibrationInProgress: Bool = false
    ) -> PostureEvaluationSet {
        guard configuration.isValid, now.isFinite, let snapshot else {
            resetTransient()
            return unavailableSet(detail: "Mesure absente")
        }
        guard let faceIsNew = acceptFaceIdentity(snapshot) else {
            resetTransient()
            return unavailableSet(detail: "Mesure périmée ou dupliquée")
        }
        guard snapshot.isFresh(at: now, ttl: configuration.ttl) else {
            resetTransient()
            return unavailableSet(detail: "Mesure trop ancienne")
        }
        guard let calibration else {
            resetTransient()
            return calibrationInProgress
                ? calibratingSet()
                : unavailableSet(detail: "Repère personnel absent")
        }
        guard calibration.generation == snapshot.faceGeneration else {
            resetTransient()
            return unavailableSet(detail: "Repère d'une autre session")
        }

        let faceIsUsable = snapshot.facePointCount >= configuration.minimumFacePointCount &&
            snapshot.yawProxy.map {
                $0.isFinite && abs($0) <= configuration.maximumAbsoluteYawProxy
            } == true

        if faceIsNew {
            faceCache = FaceEvaluationCache(
                proximity: Self.evaluate(
                    metric: coherentFaceScaleRatio(snapshot, calibration),
                    usable: faceIsUsable && snapshot.yawProxy.map {
                        abs($0) <= configuration.maximumAbsoluteYawForProximity
                    } == true && snapshot.eyeLineRollDegrees.map {
                        abs($0) <= configuration.maximumAbsoluteRollForProximityDegrees
                    } == true,
                    channel: &headProximity,
                    timestamp: snapshot.faceTimestamp, attentionState: .attention,
                    requiredDuration: configuration.proximityRequiredDuration,
                    detail: "Taille apparente du visage durablement supérieure au repère personnel"
                ),
                position: Self.evaluate(
                    metric: absoluteDelta(snapshot.pitchProxy, calibration.pitchProxy),
                    usable: faceIsUsable, channel: &relativeHeadPosition,
                    timestamp: snapshot.faceTimestamp, attentionState: .attention,
                    requiredDuration: configuration.requiredDuration,
                    detail: "Position de tête relative, pas hauteur de l'écran"
                ),
                blink: blinks.consume(
                    opening: snapshot.meanEyeOpeningRatio,
                    baseline: calibration.eyeOpeningRatio,
                    timestamp: snapshot.faceTimestamp
                ),
                brows: Self.evaluate(
                    metric: contraction(snapshot.innerBrowDistanceRatio,
                                        calibration.innerBrowDistanceRatio),
                    usable: faceIsUsable, channel: &narrowedBrows,
                    timestamp: snapshot.faceTimestamp, attentionState: .attention,
                    requiredDuration: configuration.browRequiredDuration,
                    detail: "Rapprochement géométrique durable des sourcils"
                )
            )
        }
        let face = faceCache ?? FaceEvaluationCache.missing
        let body = consumeBody(snapshot, calibration: calibration, now: now,
                               faceIsUsable: faceIsUsable, faceIsNew: faceIsNew)

        return PostureEvaluationSet(
            headProximity: face.proximity,
            relativeHeadPosition: face.position,
            estimatedBlinks: face.blink,
            experimentalForwardHead: body.forward,
            elevatedShoulders: body.shoulders,
            narrowedBrows: face.brows
        )
    }

    /// `true` = nouvelle face; `false` = même face réutilisée pour un nouveau corps.
    private mutating func acceptFaceIdentity(_ snapshot: PostureSnapshot) -> Bool? {
        guard snapshot.faceTimestamp.isFinite else { return nil }
        if let generation {
            guard snapshot.faceGeneration >= generation else { return nil }
            if snapshot.faceGeneration > generation {
                if let lastFace, snapshot.faceTimestamp <= lastFace.faceTimestamp { return nil }
                self.generation = snapshot.faceGeneration
                self.lastFace = snapshot
                lastBodyTimestamp = nil
                lastBodySampleID = nil
                faceCache = nil
                bodyCache = nil
                resetTransient()
                blinks = BlinkMetric()
                return true
            }
            guard let lastFace else { return nil }
            if snapshot.sameFaceEvidence(as: lastFace) { return false }
            guard isNewer(timestamp: snapshot.faceTimestamp, sampleID: snapshot.faceSampleID,
                          than: lastFace.faceTimestamp, sampleID: lastFace.faceSampleID) else {
                return nil
            }
            if snapshot.faceTimestamp - lastFace.faceTimestamp > configuration.maximumSampleGap {
                resetTransient()
                blinks.resetTransient(keepingCount: true)
                faceCache = nil
            }
        } else {
            generation = snapshot.faceGeneration
        }
        lastFace = snapshot
        return true
    }

    private mutating func consumeBody(
        _ snapshot: PostureSnapshot,
        calibration: PostureCalibration,
        now: TimeInterval,
        faceIsUsable: Bool,
        faceIsNew: Bool
    ) -> BodyEvaluationCache {
        guard snapshot.hasNearbyBody(maximumSkew: configuration.maximumBodySkew),
              let timestamp = snapshot.bodyTimestamp, let sampleID = snapshot.bodySampleID,
              now >= timestamp, now - timestamp <= configuration.bodyTTL else {
            resetBodyTransient()
            return .missing
        }

        if let lastBodyTimestamp, let lastBodySampleID {
            if timestamp == lastBodyTimestamp && sampleID == lastBodySampleID {
                if faceIsNew {
                    let result = makeBodyEvaluation(snapshot, calibration: calibration,
                                                    faceIsUsable: faceIsUsable,
                                                    timestamp: timestamp)
                    bodyCache = result
                    return result
                }
                return bodyCache ?? .missing
            }
            guard isNewer(timestamp: timestamp, sampleID: sampleID,
                          than: lastBodyTimestamp, sampleID: lastBodySampleID) else {
                resetBodyTransient()
                return .missing
            }
            if timestamp - lastBodyTimestamp > configuration.maximumBodySampleGap {
                resetBodyTransient()
            }
        }
        lastBodyTimestamp = timestamp
        lastBodySampleID = sampleID

        let result = makeBodyEvaluation(snapshot, calibration: calibration,
                                        faceIsUsable: faceIsUsable, timestamp: timestamp)
        bodyCache = result
        return result
    }

    private mutating func makeBodyEvaluation(
        _ snapshot: PostureSnapshot,
        calibration: PostureCalibration,
        faceIsUsable: Bool,
        timestamp: TimeInterval
    ) -> BodyEvaluationCache {
        BodyEvaluationCache(
            forward: Self.evaluate(
                metric: ratio(
                    snapshot.headForwardRatio(maximumSkew: configuration.maximumBodySkew),
                    calibration.headForwardRatio
                ),
                usable: faceIsUsable,
                channel: &forwardHead,
                timestamp: timestamp,
                attentionState: .attention,
                requiredDuration: configuration.requiredDuration,
                detail: "Fusion visage-épaules proche dans le temps (≤ 0,30 s)",
                isExperimental: true
            ),
            shoulders: Self.evaluate(
                metric: delta(
                    snapshot.shoulderElevation(maximumSkew: configuration.maximumBodySkew),
                    calibration.shoulderElevation
                ),
                usable: true,
                channel: &elevatedShoulders,
                timestamp: timestamp,
                attentionState: .attention,
                requiredDuration: configuration.requiredDuration,
                detail: "Épaules proches dans le temps, jamais déclarées même frame"
            )
        )
    }

    private static func evaluate(
        metric: Double?,
        usable: Bool,
        channel: inout SustainedMetric,
        timestamp: TimeInterval,
        attentionState: PostureSignalState,
        requiredDuration: TimeInterval,
        detail: String,
        isExperimental: Bool = false
    ) -> PostureSignalEvaluation {
        guard usable, let metric, metric.isFinite else {
            channel.reset()
            return unavailable(detail: detail)
        }
        let state = channel.consume(
            metric,
            timestamp: timestamp,
            duration: requiredDuration,
            attentionState: attentionState
        )
        return .init(state: state, value: metric, quality: .good, detail: detail,
                     isExperimental: isExperimental)
    }

    private mutating func resetTransient() {
        headProximity.reset()
        relativeHeadPosition.reset()
        forwardHead.reset()
        elevatedShoulders.reset()
        narrowedBrows.reset()
        blinks.resetTransient(keepingCount: true)
        faceCache = nil
        bodyCache = nil
    }

    private mutating func resetBodyTransient() {
        forwardHead.reset()
        elevatedShoulders.reset()
        bodyCache = nil
    }

    private func unavailableSet(detail: String) -> PostureEvaluationSet {
        let value = unavailable(detail: detail)
        return .init(headProximity: value, relativeHeadPosition: value,
                     estimatedBlinks: value, experimentalForwardHead: value,
                     elevatedShoulders: value, narrowedBrows: value)
    }

    private func calibratingSet() -> PostureEvaluationSet {
        let value = PostureSignalEvaluation(state: .calibrating, value: nil,
                                            quality: .unavailable,
                                            detail: "Création du repère personnel")
        return .init(headProximity: value, relativeHeadPosition: value,
                     estimatedBlinks: value, experimentalForwardHead: value,
                     elevatedShoulders: value, narrowedBrows: value)
    }

    private func coherentFaceScaleRatio(
        _ snapshot: PostureSnapshot,
        _ calibration: PostureCalibration
    ) -> Double? {
        guard let interocular = ratio(snapshot.interocularDistance,
                                      calibration.interocularDistance),
              let faceLength = ratio(snapshot.faceLength, calibration.faceLength),
              abs(interocular - faceLength) <= configuration.maximumFaceScaleDisagreement else {
            return nil
        }
        let value = sqrt(interocular) * sqrt(faceLength)
        return value.isFinite ? value : nil
    }
}

private nonisolated struct FaceEvaluationCache: Sendable {
    let proximity: PostureSignalEvaluation
    let position: PostureSignalEvaluation
    let blink: PostureSignalEvaluation
    let brows: PostureSignalEvaluation

    static let missing = FaceEvaluationCache(
        proximity: unavailable(detail: "Mesure faciale absente"),
        position: unavailable(detail: "Mesure faciale absente"),
        blink: unavailable(detail: "Mesure faciale absente"),
        brows: unavailable(detail: "Mesure faciale absente")
    )
}

private nonisolated struct BodyEvaluationCache: Sendable {
    let forward: PostureSignalEvaluation
    let shoulders: PostureSignalEvaluation

    static let missing = BodyEvaluationCache(
        forward: PostureSignalEvaluation(
            state: .unavailable, value: nil, quality: .unavailable,
            detail: "Paire visage-épaules absente", isExperimental: true
        ),
        shoulders: unavailable(detail: "Paire visage-épaules absente")
    )
}

private nonisolated struct SustainedMetric: Sendable {
    let enter: Double
    let exit: Double
    private var pendingSince: TimeInterval?
    private var active = false

    init(enter: Double, exit: Double) {
        self.enter = enter
        self.exit = exit
    }

    mutating func reset() {
        pendingSince = nil
        active = false
    }

    mutating func consume(
        _ value: Double,
        timestamp: TimeInterval,
        duration: TimeInterval,
        attentionState: PostureSignalState
    ) -> PostureSignalState {
        if active {
            if value <= exit + 1e-9 { reset(); return .neutral }
            return attentionState
        }
        guard value >= enter else { pendingSince = nil; return .neutral }
        if pendingSince == nil { pendingSince = timestamp }
        guard let pendingSince,
              timestamp - pendingSince + 1e-9 >= duration else { return .pending }
        active = true
        return attentionState
    }
}

private nonisolated struct BlinkMetric: Sendable {
    private(set) var count = 0
    private var closedSince: TimeInterval?
    private var lastTimestamp: TimeInterval?

    mutating func resetTransient(keepingCount: Bool) {
        closedSince = nil
        lastTimestamp = nil
        if !keepingCount { count = 0 }
    }

    mutating func consume(
        opening: Double?,
        baseline: Double?,
        timestamp: TimeInterval
    ) -> PostureSignalEvaluation {
        guard let opening, let baseline, opening.isFinite, baseline.isFinite,
              opening >= 0, baseline > 0 else {
            resetTransient(keepingCount: true)
            return unavailable(detail: "Ouverture des yeux indisponible")
        }
        let interval = lastTimestamp.map { timestamp - $0 }
        lastTimestamp = timestamp
        let quality: PostureSignalQuality = interval.map { $0 > 0 && $0 <= 0.10 + 1e-9 }
            == true ? .good : .limited
        let ratio = opening / baseline
        guard ratio.isFinite else { return unavailable(detail: "Ouverture invalide") }

        if ratio <= 0.65 {
            if closedSince == nil { closedSince = timestamp }
            return .init(state: .pending, value: Double(count), quality: quality,
                         detail: "Compteur estimé; cadence actuelle susceptible d'en manquer")
        }
        if ratio >= 0.80, let closedSince {
            let duration = timestamp - closedSince
            self.closedSince = nil
            if duration >= 0.05 && duration <= 0.50 { count += 1 }
        }
        return .init(state: .neutral, value: Double(count), quality: quality,
                     detail: "Clignements visibles estimés; certains peuvent manquer")
    }
}

private nonisolated func unavailable(detail: String) -> PostureSignalEvaluation {
    .init(state: .unavailable, value: nil, quality: .unavailable, detail: detail)
}

private nonisolated func ratio(_ value: Double?, _ baseline: Double?) -> Double? {
    guard let value, let baseline, value.isFinite, baseline.isFinite,
          value > 0, baseline > 0 else { return nil }
    let result = value / baseline
    return result.isFinite ? result : nil
}

private nonisolated func delta(_ value: Double?, _ baseline: Double?) -> Double? {
    guard let value, let baseline, value.isFinite, baseline.isFinite else { return nil }
    let result = value - baseline
    return result.isFinite ? result : nil
}

private nonisolated func absoluteDelta(_ value: Double?, _ baseline: Double?) -> Double? {
    delta(value, baseline).map(abs)
}

private nonisolated func contraction(_ value: Double?, _ baseline: Double?) -> Double? {
    ratio(value, baseline).map { 1 - $0 }.flatMap { $0.isFinite ? $0 : nil }
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
