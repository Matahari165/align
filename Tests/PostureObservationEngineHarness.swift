import Foundation

@main
private enum PostureObservationEngineHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func evidence(
        signalID: PostureObservationSignalID = .proximity,
        value: Double?,
        time: TimeInterval,
        sampleID: UInt64,
        generation: UInt64 = 3,
        quality: PostureObservationQuality = .good,
        calibration: PostureCalibrationState = .valid
    ) -> PostureMetricEvidence {
        .init(signalID: signalID, generation: generation, sampleID: sampleID,
              capturedAt: time, producedAt: time + 0.01, normalizedValue: value,
              quality: quality, calibration: calibration,
              cameraContextID: "camera-a", framingSignature: "framing-a")
    }

    static func main() {
        var engine = PostureObservationEngine()
        _ = engine.reset(generation: 3, at: 0)

        expect(engine.ingest(evidence(value: 1.0, time: 1, sampleID: 1), now: 1.01)
            .signal(.proximity).assessment == .withinReference,
               "une proximité dans le repère doit être disponible")
        expect(engine.ingest(evidence(value: 1.30, time: 2, sampleID: 2), now: 2.01)
            .signal(.proximity).availability == .observing,
               "la variation doit attendre la persistance")
        _ = engine.ingest(evidence(value: 1.30, time: 2.5, sampleID: 3), now: 2.51)
        _ = engine.ingest(evidence(value: 1.30, time: 3.0, sampleID: 4), now: 3.01)
        _ = engine.ingest(evidence(value: 1.30, time: 3.5, sampleID: 5), now: 3.51)
        expect(engine.ingest(evidence(value: 1.30, time: 4, sampleID: 6), now: 4.01)
            .signal(.proximity).assessment == .attention,
               "la proximité persistante doit ouvrir un épisode")
        let episode = engine.snapshot.signal(.proximity).episodeID
        expect(episode != nil, "un épisode stable doit avoir une identité dédupliquable")

        let stale = engine.ingest(evidence(value: 1.30, time: 4.1, sampleID: 7), now: 5)
        expect(stale.signal(.proximity).episodeID == episode,
               "une preuve hors TTL doit être totalement inerte")
        let expired = engine.expire(at: 5, generation: 3)
        expect(expired.signal(.proximity).availability == .insufficient &&
               expired.signal(.proximity).assessment == nil,
               "l’expiration doit purger attention et valeur")

        let limited = engine.ingest(evidence(value: 1.30, time: 5.1, sampleID: 8,
                                             quality: .limited), now: 5.11)
        expect(limited.signal(.proximity).availability == .insufficient,
               "une preuve limitée ne doit jamais avancer la machine")
        let oldGeneration = engine.ingest(evidence(value: 1.30, time: 5.2, sampleID: 9,
                                                    generation: 2), now: 5.21)
        expect(oldGeneration == limited, "une ancienne génération doit être inerte")

        _ = engine.reset(generation: 4, at: 6)
        let missingCalibration = engine.ingest(
            evidence(value: 1.3, time: 6.1, sampleID: 1, generation: 4,
                     calibration: .missing), now: 6.11
        )
        expect(missingCalibration.signal(.proximity).availability == .needsCalibration,
               "l’absence de repère doit être distincte d’une valeur normale")

        var blinkEngine = PostureObservationEngine()
        _ = blinkEngine.reset(generation: 9, at: 0)
        for index in 0...302 {
            let t = 1 + Double(index)
            let value = PostureMetricEvidence(
                signalID: .estimatedBlinks, generation: 9, sampleID: UInt64(index + 1),
                capturedAt: t, producedAt: t + 0.01, normalizedValue: 0.4,
                quality: .good, calibration: .valid, cameraContextID: "camera-a",
                framingSignature: "framing-a", assessmentHint: .attention
            )
            // Rich CV supplies belowDuration; the engine consumes this scalar
            // instead of reconstructing a second blink timer.
            var valueWithDuration = value
            valueWithDuration.assessmentHint = .attention
            _ = blinkEngine.ingest(valueWithDuration, now: t + 0.01)
        }
        expect(blinkEngine.snapshot.signal(.estimatedBlinks).assessment == .attention,
               "une baisse de clignements persistante doit produire une attention après cinq minutes")

        func scalar(
            _ kind: PostureRichSignalKind,
            sampleID: UInt64,
            capturedAt: TimeInterval,
            normalizedValue: Double = 0,
            leftDelta: Double? = nil,
            rightDelta: Double? = nil,
            classification: PostureShoulderRaiseClassification? = nil
        ) -> PostureRichScalarObservation {
            .init(
                kind: kind, value: normalizedValue, state: .available,
                quality: .good, generation: 11, sampleID: sampleID,
                capturedAt: capturedAt, isEstimated2DProxy: true,
                isAttention: false, reason: "", normalizedValue: normalizedValue,
                direction: .neutral, leftShoulderDelta: leftDelta,
                rightShoulderDelta: rightDelta,
                shoulderRaiseClassification: classification
            )
        }
        func rich(bodySample: UInt64, faceSample: UInt64, at time: TimeInterval)
            -> PostureRichEvaluation {
            .init(
                torsoInclination: scalar(.torsoInclination, sampleID: bodySample,
                                         capturedAt: time),
                shoulderSlope: scalar(.shoulderSlope, sampleID: bodySample,
                                      capturedAt: time),
                shoulderOpening: scalar(.shoulderOpening, sampleID: bodySample,
                                        capturedAt: time),
                shouldersRaised: scalar(
                    .shouldersRaised, sampleID: bodySample, capturedAt: time,
                    leftDelta: 0.01, rightDelta: 0.08,
                    classification: .unilateralRight
                ),
                proximity: scalar(.proximity, sampleID: faceSample, capturedAt: time),
                blinkRate: scalar(.blinkRate, sampleID: faceSample, capturedAt: time,
                                  normalizedValue: 1),
                blinkEvent: nil,
                blinkRateAssessment: .init(
                    normalizedValue: 1, direction: .neutral, belowDuration: 0,
                    recoveryDuration: 0, quality: .good, reason: ""
                )
            )
        }

        var sourceEngine = PostureObservationEngine()
        _ = sourceEngine.reset(generation: 11, at: 0)
        let bodyPublished = sourceEngine.ingest(
            rich: rich(bodySample: 1, faceSample: 1, at: 1),
            contextKey: "camera-source", now: 1.01, calibration: .valid,
            signalIDs: PostureObservationEngine.bodySignalIDs
        )
        let torsoObservedAt = bodyPublished.signal(.torsoInclination).observedAt
        expect(bodyPublished.contextKey == "camera-source" &&
               bodyPublished.signal(.shoulderSlope).quality == .good &&
               bodyPublished.signal(.closedShoulders).quality == .good &&
               bodyPublished.signal(.raisedShoulders).shoulderRaiseClassification ==
                   .unilateralRight,
               "pente et ouverture doivent atteindre le snapshot canonique")

        let facePublished = sourceEngine.ingest(
            rich: rich(bodySample: 1, faceSample: 2, at: 1.1),
            contextKey: "camera-source", now: 1.11, calibration: .valid,
            signalIDs: PostureObservationEngine.faceSignalIDs
        )
        expect(facePublished.signal(.torsoInclination).observedAt == torsoObservedAt,
               "un tick visage ne doit pas rafraîchir artificiellement le torse")
        expect(facePublished.signal(.estimatedBlinks).quality == .good,
               "le tick visage doit alimenter les clignements")

        let bodyInvalidated = sourceEngine.invalidate(
            PostureObservationEngine.bodySignalIDs,
            at: 1.2, generation: 11
        )
        expect(bodyInvalidated.signal(.torsoInclination).availability == .insufficient &&
               bodyInvalidated.signal(.estimatedBlinks).quality == .good,
               "une invalidation corps doit préserver la preuve visage")
        let legacySnapshotData = Data(
            #"{"signalID":"raisedShoulders","generation":11,"availability":"available","assessment":"withinReference","quality":"good","observedAt":1.0,"producedAt":1.01}"#.utf8
        )
        let decodedLegacySnapshot = try? JSONDecoder().decode(
            PostureSignalSnapshot.self, from: legacySnapshotData
        )
        expect(decodedLegacySnapshot?.shoulderRaiseClassification == nil,
               "un snapshot antérieur sans classification typée doit rester décodable")
        print("PostureObservationEngineHarness: OK")
    }
}
