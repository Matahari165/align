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
        visible: Bool,
        availability: PostureValidationAvailability,
        direction: PostureValidationDirection? = nil,
        latency: Double? = 10,
        scalar: Double? = nil
    ) {
        let result = session.record(
            timestamp: timestamp,
            predictedVisible: visible,
            availability: availability,
            predictedDirection: direction,
            latencyMilliseconds: latency,
            scalarValues: scalar.map { ["neutralScale": $0] } ?? [:]
        )
        expect(result == .accepted, "échantillon refusé à t=\(timestamp)")
    }

    static func testPlansAndBoundaries() {
        let short = PostureValidationPlan.short20s
        expect(short.totalDuration == 20, "le protocole court dure 20 secondes")
        expect(short.phases.map(\.id) == ["neutral", "absent", "recovery"],
               "les trois phases courtes sont dans l'ordre")
        expect(short.phase(at: 0)?.id == "neutral", "t=0 commence par neutre")
        expect(short.phase(at: 10)?.id == "absent", "la borne 10 s passe à absent")
        expect(short.phase(at: 15)?.id == "recovery", "la borne 15 s passe à recovery")
        expect(short.phase(at: 20) == nil, "la borne finale est hors protocole")

        let guided = PostureValidationPlan.guided60s
        expect(guided.totalDuration == 60, "le protocole guidé dure 60 secondes")
        expect(guided.phases.count == 11, "le protocole guidé contient 11 phases")
        expect(guided.phases[1].expectation.expectedDirection == .yawLeft,
               "la phase gauche porte son attente de direction")
        expect(guided.phases[5].expectation.expectedDirection == .scaleIncrease,
               "la phase proche porte son attente de variation d'échelle")
        expect(guided.phases[7].expectation.expectedDirection == nil,
               "l'inclinaison d'écran ne devient pas une direction faciale")
    }

    static func testRecordingContract() {
        var session = PostureValidationSession(plan: .short20s)
        record(&session, timestamp: 0, visible: true, availability: .reliable, scalar: 1)
        expect(session.record(timestamp: 0, predictedVisible: true, availability: .reliable)
               == .rejected(.nonMonotonicTimestamp), "les timestamps dupliqués sont refusés")
        expect(session.record(timestamp: -1, predictedVisible: true, availability: .reliable)
               == .rejected(.invalidTimestamp), "un timestamp négatif est refusé")
        expect(session.record(timestamp: 20, predictedVisible: true, availability: .reliable)
               == .rejected(.outsidePlan), "un timestamp hors protocole est refusé")

        let report = session.finish()
        expect(session.isFinished, "finish verrouille la session")
        expect(session.record(timestamp: 1, predictedVisible: true, availability: .reliable)
               == .rejected(.finished), "aucun échantillon ne suit finish")
        expect(report.protocolVersion == "guided-validation-v1",
               "le rapport est versionné")
    }

    static func testShortMetrics() {
        var session = PostureValidationSession(plan: .short20s)

        // Neutre : un signal fiable sur deux, dont un résultat détecté mais limité.
        record(&session, timestamp: 0, visible: true, availability: .reliable, latency: 10, scalar: 1.0)
        record(&session, timestamp: 6, visible: true, availability: .limited, latency: 20, scalar: 1.1)
        // Absent : une détection sur deux est un faux positif.
        record(&session, timestamp: 10, visible: true, availability: .reliable, latency: 30)
        record(&session, timestamp: 11, visible: false, availability: .unavailable, latency: nil)
        // Recovery : le premier résultat fiable apparaît 2 secondes après le retour.
        record(&session, timestamp: 15, visible: false, availability: .unavailable, latency: nil)
        record(&session, timestamp: 17, visible: true, availability: .reliable, latency: 40)

        let report = session.finish()
        expect(report.visibleAttemptCount == 4, "les phases visibles comptent neutre et recovery")
        expect(report.absentAttemptCount == 2, "la phase absente a deux tentatives")
        expect(report.coverage.numerator == 2 && report.coverage.denominator == 4,
               "coverage = sorties fiables / tentatives visibles")
        expect(report.recall.numerator == 3 && report.recall.denominator == 4,
               "recall = détections / tentatives visibles")
        expect(report.falsePositiveShare.numerator == 1 && report.falsePositiveShare.denominator == 2,
               "false-positive share = détections / tentatives absentes")
        expect(report.recoveryAttemptCount == 1 && report.recoverySuccessCount == 1,
               "la récupération est comptée par phase")
        expect(report.recoveryLatency.p50 == 2 && report.recoveryLatency.p95 == 2,
               "la latence de récupération part du début de la phase")
        expect(report.latency.p95 == 40, "p95 utilise le nearest-rank déterministe")
        expect(report.stability["neutralScale"]?.sampleCount == 2,
               "la stabilité n'utilise que les scalaires neutres")
        expect(report.repeatability["neutralScale"]?.firstMedian == 1.0,
               "la première moitié neutre est conservée sous forme de médiane")
        expect(report.repeatability["neutralScale"]?.secondMedian == 1.1,
               "la seconde moitié neutre est conservée sous forme de médiane")
    }

    static func testGuidedDirectionMetrics() {
        var session = PostureValidationSession(plan: .guided60s)
        let directionalPhases = session.plan.phases.filter { $0.expectation.expectedDirection != nil }
        expect(directionalPhases.count == 6, "six phases portent une direction mesurable")

        for phase in directionalPhases {
            let direction = phase.expectation.expectedDirection
            record(&session, timestamp: phase.startTime + 0.1,
                   visible: true, availability: .reliable,
                   direction: direction, latency: 12)
        }
        // Une phase screen-tilt reste visible, mais ne participe pas à l'accuracy de direction.
        record(&session, timestamp: 40, visible: true, availability: .reliable,
               direction: .yawLeft, latency: 12)
        // Absent et recovery alimentent les métriques correspondantes sans contaminer la direction.
        record(&session, timestamp: 50, visible: false, availability: .unavailable, latency: nil)
        record(&session, timestamp: 55, visible: true, availability: .reliable, latency: 12)

        let report = session.finish()
        expect(report.directionAttemptCount == 6 && report.directionEligibleCount == 6,
               "les six directions fiables sont éligibles")
        expect(report.directionAccuracy.numerator == 6 && report.directionAccuracy.denominator == 6,
               "les directions correctement prédites donnent 100 pour cent dans ce scénario synthétique")
        expect(report.directionUnknownCount == 0, "aucune direction synthétique n'est inconnue")
        expect(report.phases.first(where: { $0.phaseID == "screen-tilt-toward" })?.directionAccuracy == nil,
               "l'inclinaison d'écran ne devient pas une vérité terrain faciale")
    }

    static func main() {
        testPlansAndBoundaries()
        testRecordingContract()
        testShortMetrics()
        testGuidedDirectionMetrics()
        print("PostureGuidedValidationHarness: OK")
    }
}
