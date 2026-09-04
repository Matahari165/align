import Foundation

@main
private enum PostureGuidedValidationHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("PostureGuidedValidationHarness: FAIL — \(message)\n", stderr)
            exit(1)
        }
    }

    static func record(
        _ session: inout PostureValidationSession,
        timestamp: TimeInterval,
        attention: PostureValidationAttention?,
        availability: PostureValidationAvailability,
        direction: PostureValidationDirection? = nil,
        latency: Double? = 10,
        scalar: Double? = nil
    ) {
        let result = session.record(
            timestamp: timestamp,
            predictedAttention: attention,
            availability: availability,
            predictedDirection: direction,
            latencyMilliseconds: latency,
            scalarValues: scalar.map { ["torsoScale": $0] } ?? [:]
        )
        expect(result == .accepted, "échantillon refusé à t=\(timestamp)")
    }

    static func testPlansAndBoundaries() {
        let expected: [PostureValidationExpectation] = [
            .neutral, .leftShoulderRaised, .neutral, .rightShoulderRaised, .neutral,
            .bothShouldersRaised, .shouldersClosed, .shouldersOpen,
            .torsoLeanLeft, .torsoLeanRight, .recovery
        ]

        let measurement = PostureValidationPlan.measurement20s
        expect(measurement.mode == .measurement20s, "le mode court est measurement20s")
        expect(measurement.phases.map(\.expectation) == expected,
               "measurement20s respecte l'ordre exact des 11 phases")
        expect(measurement.phases.allSatisfy { $0.duration == 20 },
               "measurement20s dure 20 secondes par phase")
        expect(measurement.totalDuration == 220,
               "measurement20s totalise 11 phases de 20 secondes")
        expect(measurement.phase(at: 0)?.id == "neutral-1", "t=0 commence par neutral")
        expect(measurement.phase(at: 20)?.id == "left-shoulder-raised",
               "la borne 20 s passe à l'attention épaule gauche")
        expect(measurement.phase(at: 220) == nil, "la borne finale est hors protocole")

        let notification = PostureValidationPlan.notification60s
        expect(notification.mode == .notification60s, "le mode long est notification60s")
        expect(notification.phases.map(\.expectation) == expected,
               "notification60s respecte le même ordre exact")
        expect(notification.phases.allSatisfy { $0.duration == 60 },
               "notification60s dure 60 secondes par phase")
        expect(notification.totalDuration == 660,
               "notification60s totalise 11 phases de 60 secondes")
        expect(notification.phases[0].expectedAttention == nil &&
               notification.phases[7].expectedAttention == nil &&
               notification.phases[10].expectedAttention == nil,
               "neutral, shouldersOpen et recovery ne demandent aucune attention")
        expect(notification.phases[1].expectedAttention == .leftShoulderRaised &&
               notification.phases[8].expectedDirection == .left &&
               notification.phases[9].expectedDirection == .right,
               "les phases portent l'attention et la direction G/D attendues")
    }

    static func testRecordingContract() {
        var blocked = PostureValidationSession(plan: .measurement20s, baselineValidated: false)
        expect(blocked.record(timestamp: 0, predictedAttention: nil, availability: .reliable)
               == .rejected(.baselineRequired),
               "un benchmark sans repère personnel valide est refusé")

        var session = PostureValidationSession(plan: .measurement20s, baselineValidated: true)
        record(&session, timestamp: 0, attention: nil, availability: .reliable, scalar: 1)
        expect(session.record(timestamp: 0, predictedAttention: nil, availability: .reliable)
               == .rejected(.nonMonotonicTimestamp), "les timestamps dupliqués sont refusés")
        expect(session.record(timestamp: -1, predictedAttention: nil, availability: .reliable)
               == .rejected(.invalidTimestamp), "un timestamp négatif est refusé")
        expect(session.record(timestamp: 220, predictedAttention: nil, availability: .reliable)
               == .rejected(.outsidePlan), "un timestamp hors protocole est refusé")

        let report = session.finish()
        expect(session.isFinished, "finish verrouille la session")
        expect(session.record(timestamp: 1, predictedAttention: nil, availability: .reliable)
               == .rejected(.finished), "aucun échantillon ne suit finish")
        expect(report.protocolVersion == "guided-validation-v1", "le rapport est versionné")
        expect(report.completionStatus == .incomplete && !report.isConclusive,
               "une session interrompue ne doit pas être présentée comme concluante")
    }

    static func testMeasurementMetrics() {
        var session = PostureValidationSession(plan: .measurement20s, baselineValidated: true)

        // Les cinq phases sans attention servent de contrôle des faux positifs.
        record(&session, timestamp: 0, attention: nil, availability: .reliable, scalar: 1.0)
        record(&session, timestamp: 20, attention: .leftShoulderRaised,
               availability: .reliable, latency: 20)
        record(&session, timestamp: 40, attention: .leftShoulderRaised,
               availability: .reliable, latency: 30, scalar: 1.1)
        record(&session, timestamp: 60, attention: .rightShoulderRaised,
               availability: .limited, latency: 40)
        record(&session, timestamp: 80, attention: nil, availability: .reliable,
               latency: 50, scalar: 0.9)
        record(&session, timestamp: 100, attention: nil, availability: .reliable, latency: 60)
        record(&session, timestamp: 120, attention: .shouldersClosed,
               availability: .reliable, latency: 70)
        record(&session, timestamp: 140, attention: .shouldersClosed,
               availability: .reliable, latency: 80)
        record(&session, timestamp: 160, attention: .torsoLeanLeft,
               availability: .reliable, direction: .left, latency: 90)
        record(&session, timestamp: 180, attention: .torsoLeanRight,
               availability: .reliable, direction: .right, latency: 100)
        record(&session, timestamp: 200, attention: nil, availability: .reliable, latency: 110)
        record(&session, timestamp: 200.6, attention: nil, availability: .reliable, latency: 110)

        let report = session.finish()
        expect(report.attentionAttemptCount == 6 && report.noAttentionAttemptCount == 6,
               "les dénominateurs séparent attention et absence d'attention")
        expect(report.predictedAttentionCount == 7, "les attentions prédites sont comptées sans notion de visibilité")
        expect(report.coverage.numerator == 11 && report.coverage.denominator == 12,
               "coverage = disponibilités fiables / échantillons")
        expect(report.recall.numerator == 5 && report.recall.denominator == 6,
               "recall = attention correctement prédite / phases avec attention")
        expect(report.falsePositiveShare.numerator == 2 && report.falsePositiveShare.denominator == 6,
               "false-positive share = attention prédite hors attention attendue")
        expect(report.reliableFalsePositiveShare.numerator == 2 &&
               report.reliableFalsePositiveShare.denominator == 6,
               "le rapport sépare les faux positifs conditionnels aux données fiables")
        expect(report.directionAttemptCount == 2 && report.directionEligibleCount == 2 &&
               report.directionAccuracy.numerator == 2 && report.directionAccuracy.denominator == 2,
               "direction G/D ne compte que les torse fiables correctement identifiés")
        expect(report.directionUnknownCount == 0, "aucune direction G/D n'est inconnue")
        expect(report.recoveryAttemptCount == 1 && report.recoverySuccessCount == 1 &&
               report.recoveryLatency.p50 == 0,
               "recovery exige une disponibilité fiable sans attention")
        expect(report.latency.p95 == 110, "p95 de latence est déterministe")
        expect(report.stability["torsoScale"]?.sampleCount == 3 &&
               report.stability["torsoScale"]?.median == 1.0 &&
               abs((report.stability["torsoScale"]?.medianAbsoluteDeviation ?? 0) - 0.1) < 0.0001,
               "stabilité utilise les scalaires fiables des trois phases neutres")
        expect(report.repeatability["torsoScale"]?.firstMedian == 1.0 &&
               report.repeatability["torsoScale"]?.secondMedian == 1.0,
               "répétabilité compare les échantillons neutres du début et de la fin")
    }

    static func testDirectionAndSignalSeparation() {
        var session = PostureValidationSession(plan: .notification60s, baselineValidated: true)
        let phases = session.plan.phases
        for phase in phases {
            let attention = phase.expectation.expectedAttention
            let direction = phase.expectation.expectedDirection
            record(&session, timestamp: phase.startTime + 0.1,
                   attention: attention, availability: .reliable, direction: direction)
        }

        let report = session.finish()
        expect(report.directionAttemptCount == 2 && report.directionAccuracy.value == 1,
               "les deux phases torse donnent une accuracy direction synthétique complète")
        expect(report.phases.first(where: { $0.phaseID == "shoulders-open" })?.recall == nil,
               "shouldersOpen n'est pas interprété comme un signal attendu")
        expect(report.phases.first(where: { $0.phaseID == "recovery" })?.falsePositiveShare?.numerator == 0,
               "recovery sans attention n'est pas un objectif de détection")
    }

    static func completeReport(neutralScalar: Double) -> PostureValidationReport {
        var session = PostureValidationSession(plan: .measurement20s, baselineValidated: true)
        for phase in session.plan.phases {
            record(
                &session,
                timestamp: phase.startTime + 0.1,
                attention: phase.expectedAttention,
                availability: .reliable,
                direction: phase.expectedDirection,
                scalar: phase.expectation == .neutral ? neutralScalar : nil
            )
            if phase.expectation == .recovery {
                record(&session, timestamp: phase.startTime + 0.7,
                       attention: nil, availability: .reliable)
            }
        }
        record(&session, timestamp: session.plan.totalDuration - 0.1,
               attention: nil, availability: .reliable)
        return session.finish()
    }

    static func testCompletionAndThreeRunRepeatability() {
        let reports = [1.00, 1.02, 0.98].map {
            completeReport(neutralScalar: $0)
        }
        expect(reports.allSatisfy(\.isConclusive),
               "les 11 phases et la fin du protocole rendent le rapport concluant")
        let repeatability = PostureValidationThreeRunRepeatability(reports: reports)
        expect(repeatability?.runCount == 3 &&
               repeatability?.metrics["torsoScale"]?.sampleCount == 3,
               "la répétabilité exige trois sessions indépendantes complètes")
        expect(PostureValidationThreeRunRepeatability(reports: Array(reports.prefix(2))) == nil,
               "deux exécutions ne suffisent pas à prouver la répétabilité")
    }

    static func main() {
        testPlansAndBoundaries()
        testRecordingContract()
        testMeasurementMetrics()
        testDirectionAndSignalSeparation()
        testCompletionAndThreeRunRepeatability()
        print("PostureGuidedValidationHarness: OK")
    }
}
