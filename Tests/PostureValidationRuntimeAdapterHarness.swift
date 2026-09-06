import Foundation

@main
private enum PostureValidationRuntimeAdapterHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("PostureValidationRuntimeAdapterHarness: FAIL — \(message)\n", stderr)
            exit(1)
        }
    }

    static func signal(
        _ id: PostureObservationSignalID,
        availability: PostureObservationAvailability = .available,
        assessment: PostureObservationAssessment? = nil,
        quality: PostureObservationQuality = .good,
        observedAt: TimeInterval = 0.9,
        classification: PostureShoulderRaiseClassification? = nil
    ) -> PostureSignalSnapshot {
        PostureSignalSnapshot(
            signalID: id,
            generation: 1,
            availability: availability,
            assessment: assessment,
            quality: quality,
            observedAt: observedAt,
            producedAt: 1,
            episodeID: assessment == .attention ? 1 : nil,
            reason: nil,
            shoulderRaiseClassification: classification
        )
    }

    static func snapshot(
        torso: PostureSignalSnapshot,
        raised: PostureSignalSnapshot,
        closed: PostureSignalSnapshot,
        slope: PostureSignalSnapshot? = nil,
        head: PostureSignalSnapshot? = nil,
        proximity: PostureSignalSnapshot? = nil
    ) -> PostureObservationsSnapshot {
        PostureObservationsSnapshot(
            generation: 1,
            contextKey: "fixture",
            producedAt: 1,
            signals: [
                torso, raised, closed,
                slope ?? signal(.shoulderSlope),
                head ?? signal(.headTilt),
                proximity ?? signal(.proximity)
            ]
        )
    }

    static func scalar(
        _ kind: PostureRichSignalKind,
        value: Double?,
        attention: Bool = false,
        capturedAt: TimeInterval = 0.9,
        leftDelta: Double? = nil,
        rightDelta: Double? = nil,
        classification: PostureShoulderRaiseClassification? = nil
    ) -> PostureRichScalarObservation {
        PostureRichScalarObservation(
            kind: kind,
            value: value,
            state: .available,
            quality: .good,
            generation: 1,
            sampleID: 1,
            capturedAt: capturedAt,
            isEstimated2DProxy: true,
            isAttention: attention,
            reason: "",
            normalizedValue: value,
            direction: .unknown,
            leftShoulderDelta: leftDelta,
            rightShoulderDelta: rightDelta,
            shoulderRaiseClassification: classification
        )
    }

    static func evaluation(
        torso: Double? = 0,
        raisedClassification: PostureShoulderRaiseClassification? = PostureShoulderRaiseClassification.none,
        raisedValue: Double? = 0,
        torsoAttention: Bool = false,
        slopeAttention: Bool = false,
        headAttention: Bool = false,
        proximityAttention: Bool = false
    ) -> PostureRichEvaluation {
        let torsoScalar = scalar(.torsoInclination, value: torso, attention: torsoAttention)
        let raisedScalar = scalar(
            .shouldersRaised,
            value: raisedValue,
            attention: raisedClassification != PostureShoulderRaiseClassification.none,
            leftDelta: raisedClassification == .unilateralLeft ? 0.8 : 0,
            rightDelta: raisedClassification == .unilateralRight ? 0.8 : 0,
            classification: raisedClassification
        )
        let slope = scalar(.shoulderSlope, value: 1, attention: slopeAttention)
        let head = scalar(.headTilt, value: 0, attention: headAttention)
        let opening = scalar(.shoulderOpening, value: 1)
        let proximity = scalar(.proximity, value: 1, attention: proximityAttention)
        let blink = scalar(.blinkRate, value: 20)
        return PostureRichEvaluation(
            torsoInclination: torsoScalar,
            shoulderSlope: slope,
            headTilt: head,
            shoulderOpening: opening,
            shouldersRaised: raisedScalar,
            proximity: proximity,
            blinkRate: blink,
            blinkEvent: nil,
            blinkRateAssessment: .init(
                normalizedValue: 1,
                direction: .neutral,
                belowDuration: 0,
                recoveryDuration: 0,
                quality: .good,
                reason: ""
            )
        )
    }

    static func baseline(torso: Double = 0) -> PostureRichBaseline {
        PostureRichBaseline(
            generation: 1,
            contextKey: "fixture",
            ruleVersion: "rich-v1",
            torsoInclinationDegrees: torso,
            torsoAxisDeviation: 0,
            shoulderSlopeDegrees: 0,
            shoulderOpeningRatio: 1,
            leftShoulderElevation: 0,
            rightShoulderElevation: 0,
            proximityScale: 1,
            sampleCount: 20,
            torsoInclinationMAD: 0,
            torsoAxisMAD: 0,
            shoulderSlopeMAD: 0
        )
    }

    static func main() {
        let neutralTorso = signal(.torsoInclination)
        let neutralRaised = signal(
            .raisedShoulders,
            classification: PostureShoulderRaiseClassification.none
        )
        let neutralClosed = signal(.closedShoulders)

        let leftRaised = signal(
            .raisedShoulders,
            assessment: .attention,
            classification: .unilateralLeft
        )
        let leftSample = PostureValidationRuntimeAdapter.makeSample(
            snapshot: snapshot(torso: neutralTorso, raised: leftRaised, closed: neutralClosed),
            evaluation: evaluation(raisedClassification: .unilateralLeft, raisedValue: 0.8),
            baseline: baseline(),
            expectedAttention: .leftShoulderRaised
        )
        expect(leftSample.predictedAttention == .leftShoulderRaised,
               "la classification gauche devient l'attention gauche")
        expect(leftSample.availability == .reliable,
               "une preuve épaule fraîche est fiable même si le torse est indisponible")
        expect(leftSample.scalarValues["shoulders.leftDelta"] == 0.8,
               "le delta gauche reste scalaire")

        let torsoRight = signal(.torsoInclination, assessment: .attention)
        let torsoSample = PostureValidationRuntimeAdapter.makeSample(
            snapshot: snapshot(torso: torsoRight, raised: neutralRaised, closed: neutralClosed),
            evaluation: evaluation(torso: 6, torsoAttention: true),
            baseline: baseline(),
            expectedAttention: .torsoLeanRight
        )
        expect(torsoSample.predictedAttention == .torsoLeanRight &&
               torsoSample.predictedDirection == .right,
               "le torse conserve sa direction signée")

        let staleRaised = signal(
            .raisedShoulders,
            assessment: .attention,
            observedAt: -2,
            classification: .bilateral
        )
        let staleSample = PostureValidationRuntimeAdapter.makeSample(
            snapshot: snapshot(torso: neutralTorso, raised: staleRaised, closed: neutralClosed),
            evaluation: evaluation(raisedClassification: .bilateral, raisedValue: 1),
            baseline: baseline(),
            expectedAttention: .bothShouldersRaised
        )
        expect(staleSample.predictedAttention == nil && staleSample.availability == .limited,
               "une preuve périmée ne devient jamais une attention")

        let noAttention = PostureValidationRuntimeAdapter.makeSample(
            snapshot: snapshot(torso: neutralTorso, raised: neutralRaised, closed: neutralClosed),
            evaluation: evaluation(),
            baseline: baseline(),
            expectedAttention: nil
        )
        expect(noAttention.availability == .reliable && noAttention.predictedAttention == nil,
               "une phase neutre exige la fiabilité de toutes les preuves corporelles")

        let slopeAttention = PostureValidationRuntimeAdapter.makeSample(
            snapshot: snapshot(
                torso: neutralTorso,
                raised: neutralRaised,
                closed: neutralClosed,
                slope: signal(.shoulderSlope, assessment: .attention)
            ),
            evaluation: evaluation(slopeAttention: true),
            baseline: nil,
            expectedAttention: .shoulderSlope
        )
        expect(slopeAttention.predictedAttention == .shoulderSlope &&
               slopeAttention.availability == .reliable,
               "la pente universelle devient une attention guidée indépendante de la baseline")

        let proximityAttention = PostureValidationRuntimeAdapter.makeSample(
            snapshot: snapshot(
                torso: neutralTorso,
                raised: neutralRaised,
                closed: neutralClosed,
                proximity: signal(.proximity, assessment: .attention)
            ),
            evaluation: evaluation(proximityAttention: true),
            baseline: nil,
            expectedAttention: .apparentProximity
        )
        expect(proximityAttention.predictedAttention == .apparentProximity &&
               proximityAttention.scalarValues["proximity.scale"] == 1,
               "la proximité apparente devient une attention guidée mesurable")

        var gate = PostureValidationPublicationGate()
        expect(gate.admits(leftSample, phaseID: "shoulder-slope-1"),
               "la première preuve est publiée")
        expect(!gate.admits(leftSample, phaseID: "shoulder-slope-1"),
               "un tick visage ne recompte pas la même preuve corporelle")
        let faceRewrappedBody = PostureValidationRuntimeSample(
            predictedAttention: leftSample.predictedAttention,
            availability: leftSample.availability,
            predictedDirection: leftSample.predictedDirection,
            latencyMilliseconds: leftSample.latencyMilliseconds,
            scalarValues: leftSample.scalarValues,
            sourceSampleID: 999,
            sourceObservedAt: leftSample.sourceObservedAt
        )
        expect(!gate.admits(faceRewrappedBody, phaseID: "shoulder-slope-1"),
               "un tick visage ne recompte pas une preuve corps inchangée")
        expect(gate.admits(leftSample, phaseID: "neutral-2"),
               "un changement de phase reste publiable")

        print("PostureValidationRuntimeAdapterHarness: OK")
    }
}
