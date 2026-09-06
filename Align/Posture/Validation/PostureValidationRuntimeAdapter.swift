import Foundation

/// Projection purement scalaire du runtime riche vers le protocole guidé.
/// Les images, landmarks et coordonnées restent dans le producteur caméra.
nonisolated struct PostureValidationRuntimeSample: Equatable, Sendable {
    let predictedAttention: PostureValidationAttention?
    let availability: PostureValidationAvailability
    let predictedDirection: PostureValidationDirection?
    let latencyMilliseconds: Double?
    let scalarValues: [String: Double]
    let sourceSampleID: UInt64?
    let sourceObservedAt: TimeInterval?
}

/// Empêche qu'un tick visage à 10 Hz recompte une même preuve corporelle
/// produite à 2 Hz. Une nouvelle phase reste toutefois admise, même si elle
/// commence avant le prochain échantillon corporel.
nonisolated struct PostureValidationPublicationGate: Sendable {
    private var lastSourceSampleID: UInt64?
    private var lastSourceObservedAt: TimeInterval?
    private var lastAvailability: PostureValidationAvailability?
    private var lastPhaseID: String?

    mutating func reset() {
        lastSourceSampleID = nil
        lastSourceObservedAt = nil
        lastAvailability = nil
        lastPhaseID = nil
    }

    mutating func admits(
        _ sample: PostureValidationRuntimeSample,
        phaseID: String
    ) -> Bool {
        guard !isDuplicate(sample, phaseID: phaseID) else { return false }
        commit(sample, phaseID: phaseID)
        return true
    }

    func isDuplicate(
        _ sample: PostureValidationRuntimeSample,
        phaseID: String
    ) -> Bool {
        guard sample.availability == lastAvailability,
              phaseID == lastPhaseID else { return false }
        // Un tick visage peut reconditionner le dernier scalaire corporel avec
        // son propre identifiant de transport. L'instant d'observation de la
        // preuve canonique reste alors l'identité stable.
        if let observedAt = sample.sourceObservedAt,
           observedAt == lastSourceObservedAt {
            return true
        }
        return sample.sourceSampleID == lastSourceSampleID &&
            sample.sourceObservedAt == lastSourceObservedAt
    }

    mutating func commit(
        _ sample: PostureValidationRuntimeSample,
        phaseID: String
    ) {
        lastSourceSampleID = sample.sourceSampleID
        lastSourceObservedAt = sample.sourceObservedAt
        lastAvailability = sample.availability
        lastPhaseID = phaseID
    }
}

nonisolated enum PostureValidationRuntimeAdapter {
    static func makeSample(
        snapshot: PostureObservationsSnapshot,
        evaluation: PostureRichEvaluation?,
        baseline: PostureRichBaseline?,
        expectedAttention: PostureValidationAttention?
    ) -> PostureValidationRuntimeSample {
        let raised = snapshot.signal(.raisedShoulders)
        let closed = snapshot.signal(.closedShoulders)
        let torso = snapshot.signal(.torsoInclination)
        let slope = snapshot.signal(.shoulderSlope)
        let head = snapshot.signal(.headTilt)
        let proximity = snapshot.signal(.proximity)

        let predictedAttention: PostureValidationAttention? = {
            // L'ordre est fixe et indépendant de la phase attendue. Les
            // protocoles guidés demandent une action à la fois ; les valeurs
            // scalaires conservent néanmoins toutes les mesures disponibles.
            if isReliable(slope), slope.assessment == .attention {
                return .shoulderSlope
            }
            if isReliable(head), head.assessment == .attention {
                return .headTilt
            }
            if isReliable(proximity), proximity.assessment == .attention {
                return .apparentProximity
            }
            if isReliable(raised), raised.assessment == .attention,
               let classification = evaluation?.shouldersRaised.shoulderRaiseClassification
                    ?? raised.shoulderRaiseClassification {
                switch classification {
                case .unilateralLeft: return .leftShoulderRaised
                case .unilateralRight: return .rightShoulderRaised
                case .bilateral: return .bothShouldersRaised
                case .none, .unavailable: break
                }
            }
            if isReliable(closed), closed.assessment == .attention {
                return .shouldersClosed
            }
            if isReliable(torso), torso.assessment == .attention {
                guard let direction = torsoDirection(
                    evaluation: evaluation,
                    baseline: baseline
                ) else { return nil }
                return direction == .left ? .torsoLeanLeft : .torsoLeanRight
            }
            return nil
        }()

        let predictedDirection: PostureValidationDirection? = {
            guard predictedAttention == .torsoLeanLeft || predictedAttention == .torsoLeanRight else {
                return nil
            }
            return torsoDirection(evaluation: evaluation, baseline: baseline)
        }()

        return PostureValidationRuntimeSample(
            predictedAttention: predictedAttention,
            availability: availability(
                for: expectedAttention,
                torso: torso,
                raised: raised,
                closed: closed,
                slope: slope,
                head: head,
                proximity: proximity
            ),
            predictedDirection: predictedDirection,
            latencyMilliseconds: latencyMilliseconds(
                snapshot: snapshot,
                evaluation: evaluation
            ),
            scalarValues: scalarValues(
                snapshot: snapshot,
                evaluation: evaluation,
                baseline: baseline
            ),
            sourceSampleID: sourceSampleID(
                evaluation: evaluation,
                expectedAttention: expectedAttention
            ),
            sourceObservedAt: sourceObservedAt(
                snapshot: snapshot,
                expectedAttention: expectedAttention
            )
        )
    }

    private static func isReliable(_ signal: PostureSignalSnapshot) -> Bool {
        guard signal.availability == .available,
              signal.quality == .good,
              let observedAt = signal.observedAt,
              observedAt.isFinite,
              signal.producedAt.isFinite,
              signal.producedAt >= observedAt else { return false }
        let age = signal.producedAt - observedAt
        return age <= PostureObservationEngine.freshnessTTL(for: signal.signalID)
    }

    private static func torsoDirection(
        evaluation: PostureRichEvaluation?,
        baseline: PostureRichBaseline?
    ) -> PostureValidationDirection? {
        guard let current = evaluation?.torsoInclination.value,
              current.isFinite else { return nil }
        // The universal engine expresses torso inclination around the camera
        // geometry's horizontal axis. A posture baseline is only used by
        // legacy/direct harnesses that still provide one; production now
        // persists eye opening only.
        let deviation: Double
        if let neutral = baseline?.torsoInclinationDegrees, neutral.isFinite {
            deviation = current - neutral
        } else {
            deviation = current
        }
        guard deviation.isFinite, abs(deviation) > Double.ulpOfOne else { return nil }
        return deviation < 0 ? .left : .right
    }

    private static func sourceSampleID(
        evaluation: PostureRichEvaluation?,
        expectedAttention: PostureValidationAttention?
    ) -> UInt64? {
        let values: [PostureRichScalarObservation?] = switch expectedAttention {
        case .shoulderSlope:
            [evaluation?.shoulderSlope]
        case .headTilt:
            [evaluation?.headTilt]
        case .apparentProximity:
            [evaluation?.proximity]
        case .leftShoulderRaised, .rightShoulderRaised, .bothShouldersRaised:
            [evaluation?.shouldersRaised]
        case .shouldersClosed:
            [evaluation?.shoulderOpening]
        case .torsoLeanLeft, .torsoLeanRight:
            [evaluation?.torsoInclination]
        case nil:
            [evaluation?.torsoInclination, evaluation?.shouldersRaised,
             evaluation?.shoulderOpening, evaluation?.shoulderSlope,
             evaluation?.headTilt, evaluation?.proximity]
        }
        return values.compactMap { value in
            guard let value, value.sampleID > 0 else { return nil }
            return value.sampleID
        }.max()
    }

    private static func sourceObservedAt(
        snapshot: PostureObservationsSnapshot,
        expectedAttention: PostureValidationAttention?
    ) -> TimeInterval? {
        let signals: [PostureSignalSnapshot] = switch expectedAttention {
        case .shoulderSlope:
            [snapshot.signal(.shoulderSlope)]
        case .headTilt:
            [snapshot.signal(.headTilt)]
        case .apparentProximity:
            [snapshot.signal(.proximity)]
        case .leftShoulderRaised, .rightShoulderRaised, .bothShouldersRaised:
            [snapshot.signal(.raisedShoulders)]
        case .shouldersClosed:
            [snapshot.signal(.closedShoulders)]
        case .torsoLeanLeft, .torsoLeanRight:
            [snapshot.signal(.torsoInclination)]
        case nil:
            [snapshot.signal(.torsoInclination), snapshot.signal(.raisedShoulders),
             snapshot.signal(.closedShoulders), snapshot.signal(.shoulderSlope),
             snapshot.signal(.headTilt), snapshot.signal(.proximity)]
        }
        return signals.compactMap { value in
            guard let observedAt = value.observedAt, observedAt.isFinite else { return nil }
            return observedAt
        }.max()
    }

    private static func availability(
        for expectedAttention: PostureValidationAttention?,
        torso: PostureSignalSnapshot,
        raised: PostureSignalSnapshot,
        closed: PostureSignalSnapshot,
        slope: PostureSignalSnapshot,
        head: PostureSignalSnapshot,
        proximity: PostureSignalSnapshot
    ) -> PostureValidationAvailability {
        let relevant: [PostureSignalSnapshot] = switch expectedAttention {
        case .shoulderSlope:
            [slope]
        case .headTilt:
            [head]
        case .apparentProximity:
            [proximity]
        case .leftShoulderRaised, .rightShoulderRaised, .bothShouldersRaised:
            [raised]
        case .shouldersClosed:
            [closed]
        case .torsoLeanLeft, .torsoLeanRight:
            [torso]
        case nil:
            [torso, slope, head, proximity]
        }
        if relevant.allSatisfy(isReliable) { return .reliable }
        if relevant.contains(where: { signal in
            signal.quality == .good && (
                signal.availability == .observing || signal.availability == .available
            )
        }) {
            return .limited
        }
        return .unavailable
    }

    private static func latencyMilliseconds(
        snapshot: PostureObservationsSnapshot,
        evaluation: PostureRichEvaluation?
    ) -> Double? {
        let candidates = [
            evaluation?.torsoInclination.capturedAt,
            evaluation?.shouldersRaised.capturedAt,
            evaluation?.shoulderOpening.capturedAt,
            evaluation?.shoulderSlope.capturedAt,
            evaluation?.headTilt.capturedAt,
            evaluation?.proximity.capturedAt,
            snapshot.signal(.torsoInclination).observedAt,
            snapshot.signal(.raisedShoulders).observedAt,
            snapshot.signal(.closedShoulders).observedAt,
            snapshot.signal(.shoulderSlope).observedAt,
            snapshot.signal(.headTilt).observedAt,
            snapshot.signal(.proximity).observedAt
        ].compactMap { value -> TimeInterval? in
            guard let value, value.isFinite, value <= snapshot.producedAt else { return nil }
            return value
        }
        guard let capturedAt = candidates.max() else { return nil }
        let latency = (snapshot.producedAt - capturedAt) * 1_000
        return latency.isFinite && latency >= 0 ? latency : nil
    }

    private static func scalarValues(
        snapshot: PostureObservationsSnapshot,
        evaluation: PostureRichEvaluation?,
        baseline: PostureRichBaseline?
    ) -> [String: Double] {
        var values: [String: Double] = [:]

        func add(_ key: String, _ value: Double?) {
            guard let value, value.isFinite else { return }
            values[key] = value
        }

        add("proximity.scale", evaluation?.proximity.value)
        add("torso.inclinationDegrees", evaluation?.torsoInclination.value)
        if let current = evaluation?.torsoInclination.value, current.isFinite {
            let deviation = if let neutral = baseline?.torsoInclinationDegrees,
                                neutral.isFinite {
                current - neutral
            } else {
                current
            }
            add("torso.deviationDegrees", deviation)
        }
        add("shoulders.leftDelta", evaluation?.shouldersRaised.leftShoulderDelta
            ?? snapshot.signal(.raisedShoulders).leftShoulderDelta)
        add("shoulders.rightDelta", evaluation?.shouldersRaised.rightShoulderDelta
            ?? snapshot.signal(.raisedShoulders).rightShoulderDelta)
        add("shoulders.value", evaluation?.shouldersRaised.value)
        add("shoulders.slopeDegrees", evaluation?.shoulderSlope.value)
        add("headTilt.degrees", evaluation?.headTilt.value)
        add("shoulders.openingRatio", evaluation?.shoulderOpening.value)
        add("blinks.ratePerMinute", evaluation?.blinkRate.value)
        add("blinks.normalizedRate", evaluation?.blinkRate.normalizedValue)
        return values
    }
}
