import Foundation

@main
enum PostureIndicatorPresentationHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func result(
        _ id: PostureIndicatorID,
        state: PostureIndicatorState,
        quality: PostureSignalQuality = .good,
        observedAt: TimeInterval? = 10,
        baseline: Bool = true
    ) -> PostureIndicatorResult {
        .init(id: id, state: state, count: nil, observedAt: observedAt,
              quality: quality, hasValidBaseline: baseline,
              isExperimental: id == .estimatedForwardHead)
    }

    static func snapshot(time: TimeInterval, generation: UInt64 = 1) -> PostureSnapshot {
        let sampleID = UInt64((time * 100).rounded()) + 1
        return PostureSnapshot(
            faceGeneration: generation, faceTimestamp: time, faceSampleID: sampleID,
            facePointCount: 47, interocularDistance: 0.18, faceLength: 0.34,
            pitchProxy: 0.02, yawProxy: 0, eyeLineRollDegrees: 0,
            leftEyeOpeningRatio: 0.30, rightEyeOpeningRatio: 0.30,
            innerBrowDistanceRatio: 0.40,
            faceCenter: .init(x: 0.5, y: 0.55),
            leftShoulder: .init(x: 0.35, y: 0.35),
            rightShoulder: .init(x: 0.65, y: 0.35),
            bodyGeneration: generation, bodyTimestamp: time, bodySampleID: sampleID
        )
    }

    static func main() {
        let now = 10.5

        let normal = PostureIndicatorPresentation.make(
            for: result(.headDistance, state: .normal), producedAt: now
        )
        expect(normal.tone == .positive && normal.value == "Dans ton repère",
               "Une mesure fiable normale doit être verte.")

        let attention = PostureIndicatorPresentation.make(
            for: result(.raisedShoulders, state: .attention), producedAt: now
        )
        expect(attention.tone == .negative && attention.value == "Épaules relevées",
               "Une mesure fiable en attention doit être rouge et causale.")

        for unreliable in [
            result(.headDistance, state: .normal, quality: .limited),
            result(.headDistance, state: .attention, observedAt: nil),
            result(.headDistance, state: .normal, observedAt: 9),
            result(.raisedShoulders, state: .attention, baseline: false)
        ] {
            let presentation = PostureIndicatorPresentation.make(for: unreliable, producedAt: now)
            expect(presentation.tone == .neutral && presentation.value == "—" &&
                   presentation.accessibilityValue == "Aucune information fiable",
                   "Toute preuve incomplète doit rester neutre et muette sur le verdict.")
        }

        let pending = PostureIndicatorPresentation.make(
            for: result(.headDistance, state: .pending), producedAt: now
        )
        expect(pending.tone == .neutral && pending.value == "Observation…",
               "Une observation en stabilisation reste neutre.")

        let experimentalNormal = PostureIndicatorPresentation.make(
            for: result(.estimatedForwardHead, state: .normal), producedAt: now
        )
        let experimentalAttention = PostureIndicatorPresentation.make(
            for: result(.narrowedBrows, state: .attention), producedAt: now
        )
        expect(experimentalNormal.tone == .neutral && experimentalNormal.isExperimental &&
               experimentalNormal.value == "Indication stable" &&
               experimentalNormal.accessibilityValue ==
                   "Expérimental, Observation fiable, Indication stable",
               "Un signal expérimental normal ne doit jamais devenir vert.")
        expect(experimentalAttention.tone == .neutral && experimentalAttention.isExperimental &&
               experimentalAttention.value == "Variation possible",
               "Un signal expérimental en attention ne doit jamais devenir rouge.")

        let unavailable = PostureIndicatorPresentation.make(
            for: result(.estimatedBlinks, state: .unavailable), producedAt: now
        )
        expect(unavailable.value == "—" && unavailable.accessibilityValue ==
                   "Expérimental, Aucune information fiable",
               "Unavailable doit annoncer la maturité puis l’absence de preuve.")

        let calibration = PostureIndicatorPresentation.make(
            for: result(.headDistance, state: .calibrating, quality: .unavailable,
                        observedAt: nil, baseline: false), producedAt: now
        )
        expect(calibration.value == "Calibration…" && calibration.tone == .neutral,
               "La calibration doit rester visible et neutre.")

        expect(PostureIndicatorPresentation.orderedIDs == [
            .headDistance, .raisedShoulders, .estimatedForwardHead,
            .estimatedEyeHeight, .estimatedBlinks, .narrowedBrows
        ], "L’ordre visuel des six signaux doit rester stable.")

        var pipeline = PostureSignalPipeline()
        _ = pipeline.reset(generation: 1)
        let calibrationStart = pipeline.beginCalibration(at: 0, generation: 1)
        expect(calibrationStart.indicators.allSatisfy { $0.state == .calibrating },
               "La calibration doit être visible avant même la première frame.")
        for index in 0...24 {
            _ = pipeline.ingest(snapshot(time: Double(index) / 3), now: Double(index) / 3)
        }
        let transported = pipeline.ingest(snapshot(time: 8.5), now: 8.5)
        let distance = transported.result(for: .headDistance)
        let shoulders = transported.result(for: .raisedShoulders)
        expect(distance.quality == .good && distance.hasValidBaseline,
               "Le pipeline doit transporter qualité et baseline de Distance.")
        expect(shoulders.quality == .good && shoulders.hasValidBaseline,
               "Le pipeline doit transporter qualité et baseline des épaules.")

        print("PostureIndicatorPresentationHarness: OK")
    }
}
