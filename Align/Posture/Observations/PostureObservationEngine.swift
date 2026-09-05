import Foundation

nonisolated struct PostureObservationEngine: Sendable {
    static let faceSignalIDs: Set<PostureObservationSignalID> = [
        .proximity, .estimatedBlinks
    ]
    static let bodySignalIDs: Set<PostureObservationSignalID> = [
        .torsoInclination, .raisedShoulders, .shoulderSlope, .closedShoulders, .headTilt
    ]

    static let proximityConfiguration = TemporalObservationConfiguration(
        direction: .above,
        enterThreshold: 1.25,
        exitThreshold: 1.15,
        attentionPersistence: 2,
        maximumSampleGap: 0.75,
        ttl: 0.75
    )

    static let richConfiguration = TemporalObservationConfiguration(
        direction: .above, enterThreshold: 0.6, exitThreshold: 0.4,
        attentionPersistence: 0, maximumSampleGap: 10, ttl: 2
    )
    static let blinkLowRateDuration: TimeInterval = 5 * 60

    private var generation: UInt64 = 0
    private var machines: [PostureObservationSignalID: TemporalObservationMachine]
    private(set) var snapshot: PostureObservationsSnapshot

    init(configurations: [PostureObservationSignalID: TemporalObservationConfiguration] = [
        .proximity: Self.proximityConfiguration,
        .torsoInclination: Self.richConfiguration,
        .raisedShoulders: Self.richConfiguration,
        .shoulderSlope: Self.richConfiguration,
        .estimatedBlinks: TemporalObservationConfiguration(
            direction: .below, enterThreshold: 0.4, exitThreshold: 0.6,
            attentionPersistence: 0, maximumSampleGap: 0.25, ttl: 0.75
        ),
        .closedShoulders: Self.richConfiguration,
        .headTilt: Self.richConfiguration
    ]) {
        machines = [:]
        for (id, configuration) in configurations {
            machines[id] = TemporalObservationMachine(signalID: id, configuration: configuration)
        }
        snapshot = .init(generation: 0, producedAt: 0, signals: [])
    }

    mutating func ingest(
        rich evaluation: PostureRichEvaluation,
        contextKey: String,
        now: TimeInterval,
        calibration: PostureCalibrationState = .valid,
        signalIDs: Set<PostureObservationSignalID> = Set(PostureObservationSignalID.allCases)
    ) -> PostureObservationsSnapshot {
        let values = [evaluation.proximity, evaluation.torsoInclination,
                      evaluation.shouldersRaised, evaluation.shoulderSlope, evaluation.blinkRate,
                      evaluation.shoulderOpening, evaluation.headTilt]
        for value in values {
            let id: PostureObservationSignalID
            switch value.kind {
            case .proximity: id = .proximity
            case .torsoInclination: id = .torsoInclination
            case .shouldersRaised: id = .raisedShoulders
            case .shoulderSlope: id = .shoulderSlope
            case .blinkRate: id = .estimatedBlinks
            case .shoulderOpening: id = .closedShoulders
            case .headTilt: id = .headTilt
            }
            guard signalIDs.contains(id) else { continue }
            let usable = value.quality == .good && value.value?.isFinite == true &&
                value.state == .available
            let evidenceCalibration: PostureCalibrationState = if id == .estimatedBlinks {
                value.normalizedValue?.isFinite == true ? .valid : .missing
            } else {
                calibration
            }
            let evidence = PostureMetricEvidence(
                signalID: id, generation: value.generation, sampleID: value.sampleID,
                capturedAt: value.capturedAt, producedAt: now,
                normalizedValue: value.normalizedValue ?? value.value,
                quality: usable ? .good : .limited,
                calibration: evidenceCalibration, cameraContextID: contextKey,
                framingSignature: contextKey,
                assessmentHint: usable
                    ? (value.isAttention ? .attention : .withinReference) : nil,
                leftShoulderDelta: id == .raisedShoulders
                    ? evaluation.shouldersRaised.leftShoulderDelta : nil,
                rightShoulderDelta: id == .raisedShoulders
                    ? evaluation.shouldersRaised.rightShoulderDelta : nil,
                shoulderRaiseClassification: id == .raisedShoulders
                    ? evaluation.shouldersRaised.shoulderRaiseClassification : nil,
                numericValue: value.numericValue,
                referenceDelta: value.referenceDelta,
                observationReason: value.reason.isEmpty ? nil : value.reason
            )
            _ = ingest(evidence, now: now)
        }
        // Metadata is scoped to this publication only.  In particular,
        // face/eyes coverage is independent from blink-rate baseline maturity.
        snapshot = .init(
            generation: snapshot.generation,
            contextKey: contextKey,
            producedAt: snapshot.producedAt,
            signals: snapshot.signals,
            blinkEventCount: signalIDs.contains(.estimatedBlinks) && evaluation.blinkEvent != nil ? 1 : 0,
            faceAndEyesReliable: signalIDs.contains(.estimatedBlinks) &&
                evaluation.blinkRate.quality == .good,
            faceAndEyesObservedAt: signalIDs.contains(.estimatedBlinks)
                ? evaluation.blinkRate.capturedAt : nil
        )
        return snapshot
    }

    mutating func reset(generation: UInt64, at now: TimeInterval) -> PostureObservationsSnapshot {
        self.generation = generation
        let values = PostureObservationSignalID.allCases.map { id -> PostureSignalSnapshot in
            guard var machine = machines[id] else {
                return .unavailable(id, generation: generation, at: now,
                                    reason: "Évaluateur non raccordé")
            }
            let value = machine.reset(generation: generation, at: now)
            machines[id] = machine
            return value
        }
        snapshot = .init(generation: generation, contextKey: "",
                         producedAt: now, signals: values)
        return snapshot
    }

    mutating func ingest(_ evidence: PostureMetricEvidence, now: TimeInterval) -> PostureObservationsSnapshot {
        guard evidence.generation == generation, var machine = machines[evidence.signalID] else {
            return snapshot
        }
        let value = machine.consume(evidence, now: now)
        machines[evidence.signalID] = machine
        publish(value, at: now)
        return snapshot
    }

    mutating func expire(at now: TimeInterval, generation: UInt64) -> PostureObservationsSnapshot {
        guard generation == self.generation else { return snapshot }
        for id in machines.keys {
            guard var machine = machines[id] else { continue }
            let value = machine.expire(at: now, generation: generation)
            machines[id] = machine
            publish(value, at: now)
        }
        return snapshot
    }

    /// Invalidation explicite d'une source. Les machines de l'autre source
    /// conservent leur identité et leur épisode jusqu'à leur propre expiration.
    mutating func invalidate(
        _ signalIDs: Set<PostureObservationSignalID>,
        at now: TimeInterval,
        generation: UInt64,
        faceEvidenceObservedAt: TimeInterval? = nil,
        reason: String = "Observation en attente"
    ) -> PostureObservationsSnapshot {
        guard generation == self.generation, now.isFinite else { return snapshot }
        for id in signalIDs {
            guard var machine = machines[id] else { continue }
            let value = machine.reset(generation: generation, at: now, reason: reason)
            machines[id] = machine
            publish(value, at: now)
        }
        snapshot = .init(
            generation: snapshot.generation,
            contextKey: snapshot.contextKey,
            producedAt: snapshot.producedAt,
            signals: snapshot.signals,
            faceAndEyesReliable: false,
            faceAndEyesObservedAt: faceEvidenceObservedAt
        )
        return snapshot
    }

    static func freshnessTTL(for id: PostureObservationSignalID) -> TimeInterval {
        switch id {
        case .proximity, .estimatedBlinks:
            proximityConfiguration.ttl
        case .torsoInclination, .raisedShoulders, .shoulderSlope, .closedShoulders, .headTilt:
            richConfiguration.ttl
        }
    }

    private mutating func publish(_ value: PostureSignalSnapshot, at now: TimeInterval) {
        var values = snapshot.signals.filter { $0.signalID != value.signalID }
        values.append(value)
        values.sort { $0.signalID.rawValue < $1.signalID.rawValue }
        snapshot = .init(generation: generation, contextKey: snapshot.contextKey,
                         producedAt: now, signals: values)
    }
}
