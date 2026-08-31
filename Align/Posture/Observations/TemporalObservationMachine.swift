import Foundation

nonisolated enum PostureThresholdDirection: String, Codable, Sendable {
    case above
    case below
}

nonisolated struct TemporalObservationConfiguration: Equatable, Codable, Sendable {
    let direction: PostureThresholdDirection
    let enterThreshold: Double
    let exitThreshold: Double
    let attentionPersistence: TimeInterval
    let maximumSampleGap: TimeInterval
    let ttl: TimeInterval

    var isValid: Bool {
        enterThreshold.isFinite && exitThreshold.isFinite &&
            attentionPersistence.isFinite && attentionPersistence >= 0 &&
            maximumSampleGap.isFinite && maximumSampleGap > 0 &&
            ttl.isFinite && ttl > 0 &&
            (direction == .above ? enterThreshold > exitThreshold : enterThreshold < exitThreshold)
    }
}

nonisolated struct TemporalObservationMachine: Sendable {
    let signalID: PostureObservationSignalID
    let configuration: TemporalObservationConfiguration

    private var generation: UInt64 = 0
    private var lastSampleID: UInt64 = 0
    private var lastCapturedAt: TimeInterval?
    private var pendingSince: TimeInterval?
    private var isAttention = false
    private var nextEpisodeID: UInt64 = 1
    private var activeEpisodeID: UInt64?
    private(set) var snapshot: PostureSignalSnapshot

    init(signalID: PostureObservationSignalID, configuration: TemporalObservationConfiguration) {
        self.signalID = signalID
        self.configuration = configuration
        snapshot = .unavailable(signalID, generation: 0, at: 0, reason: "Non activé")
    }

    mutating func reset(generation: UInt64, at now: TimeInterval) -> PostureSignalSnapshot {
        self.generation = generation
        lastSampleID = 0
        lastCapturedAt = nil
        pendingSince = nil
        isAttention = false
        activeEpisodeID = nil
        snapshot = .unavailable(signalID, generation: generation, at: now,
                                reason: "Observation en attente")
        return snapshot
    }

    mutating func consume(_ evidence: PostureMetricEvidence, now: TimeInterval) -> PostureSignalSnapshot {
        guard configuration.isValid, now.isFinite,
              evidence.signalID == signalID,
              evidence.hasValidIdentity,
              evidence.generation == generation,
              evidence.capturedAt <= now,
              now - evidence.capturedAt <= configuration.ttl,
              evidence.sampleID > lastSampleID,
              lastCapturedAt.map({ evidence.capturedAt > $0 }) ?? true else {
            return snapshot
        }
        if let lastCapturedAt,
           evidence.capturedAt - lastCapturedAt > configuration.maximumSampleGap {
            clearTransient()
        }
        lastSampleID = evidence.sampleID
        lastCapturedAt = evidence.capturedAt

        switch evidence.calibration {
        case .missing:
            return publishUnavailable(.needsCalibration, evidence: evidence, now: now,
                                      reason: "Repère personnel absent")
        case .calibrating:
            return publishUnavailable(.calibrating, evidence: evidence, now: now,
                                      reason: "Définition du repère")
        case .invalidContext:
            return publishUnavailable(.needsCalibration, evidence: evidence, now: now,
                                      reason: "Caméra ou cadrage différent")
        case .valid:
            break
        }
        guard evidence.quality == .good,
              let value = evidence.normalizedValue, value.isFinite else {
            return publishUnavailable(.insufficient, evidence: evidence, now: now,
                                      reason: "Preuve insuffisante")
        }

        let enters: Bool
        let exits: Bool
        if let hint = evidence.assessmentHint {
            enters = hint == .attention
            exits = hint == .withinReference
        } else {
            enters = configuration.direction == .above
                ? value >= configuration.enterThreshold
                : value <= configuration.enterThreshold
            exits = configuration.direction == .above
                ? value <= configuration.exitThreshold
                : value >= configuration.exitThreshold
        }

        if isAttention {
            if exits { clearTransient() }
        } else if enters {
            pendingSince = pendingSince ?? evidence.capturedAt
            if evidence.capturedAt - (pendingSince ?? evidence.capturedAt) >=
                configuration.attentionPersistence {
                isAttention = true
                activeEpisodeID = nextEpisodeID
                nextEpisodeID &+= 1
            }
        } else {
            pendingSince = nil
        }

        snapshot = PostureSignalSnapshot(
            signalID: signalID,
            generation: generation,
            availability: isAttention || !enters ? .available : .observing,
            assessment: isAttention ? .attention : (enters ? nil : .withinReference),
            quality: .good,
            observedAt: evidence.capturedAt,
            producedAt: now,
            episodeID: activeEpisodeID,
            reason: nil
        )
        return snapshot
    }

    mutating func expire(at now: TimeInterval, generation: UInt64) -> PostureSignalSnapshot {
        guard generation == self.generation, now.isFinite else { return snapshot }
        guard let observedAt = snapshot.observedAt,
              now >= observedAt,
              now - observedAt > configuration.ttl else { return snapshot }
        clearTransient()
        snapshot = .unavailable(signalID, generation: generation, at: now,
                                reason: "Observation périmée")
        return snapshot
    }

    private mutating func publishUnavailable(
        _ availability: PostureObservationAvailability,
        evidence: PostureMetricEvidence,
        now: TimeInterval,
        reason: String
    ) -> PostureSignalSnapshot {
        clearTransient()
        snapshot = .unavailable(signalID, generation: evidence.generation, at: now,
                                availability: availability, reason: reason)
        return snapshot
    }

    private mutating func clearTransient() {
        pendingSince = nil
        isAttention = false
        activeEpisodeID = nil
    }
}
