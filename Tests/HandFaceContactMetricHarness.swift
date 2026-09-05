import Foundation

@main private enum HandFaceContactMetricHarness {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static let face = HandFaceFaceObservation(
        contour: [
            point(0.30, 0.20), point(0.70, 0.20),
            point(0.70, 0.80), point(0.30, 0.80)
        ],
        mouth: [point(0.46, 0.56), point(0.54, 0.56), point(0.54, 0.64), point(0.46, 0.64)],
        nose: [point(0.48, 0.44), point(0.52, 0.44)],
        leftEye: [point(0.37, 0.38), point(0.43, 0.38)],
        rightEye: [point(0.57, 0.38), point(0.63, 0.38)],
        forehead: [point(0.43, 0.25), point(0.57, 0.25)]
    )

    static func point(_ x: Double, _ y: Double, _ confidence: Double = 1) -> HandFaceMetricPoint {
        .init(x: x, y: y, confidence: confidence)
    }

    static func hand(x: Double = 0.50, y: Double = 0.60, confidence: Double = 1) -> HandFaceHandObservation {
        .init(landmarks: [
            .init(.indexFinger, x: x, y: y, confidence: confidence),
            .init(.palm, x: x + 0.02, y: y + 0.02, confidence: confidence)
        ])
    }

    static func separatedHand() -> HandFaceHandObservation { hand(x: 0.92, y: 0.90) }

    static func main() {
        contactAndOneSecondPassageDoNotAlert()
        sustainedContactAlertsOnce()
        briefInterruptionPreservesHold()
        repeatedLossesDoNotExtendHold()
        confidenceLossResetsPendingHold()
        hysteresisUsesWiderExitBoundary()
        observationExposesCurrentGeometry()
        faceSurfaceCoversCheeksAndForehead()
        stableExitRearms()
        longLossAfterAlertRearms()
        print("HandFaceContactMetricHarness: OK")
    }

    static func contactAndOneSecondPassageDoNotAlert() {
        var metric = HandFaceContactMetric()
        expect(metric.consume(face: face, hands: [hand()], now: 0) == .none,
               "un contact commence sans alerte immédiate")
        expect(metric.consume(face: face, hands: [hand()], now: 1) == .none,
               "un simple passage d'une seconde ne déclenche rien")
        expect(metric.consume(face: face, hands: [separatedHand()], now: 1.1) == .none,
               "la sortie avant 2,5 secondes annule le maintien")
        expect(metric.phase == .idle, "la métrique revient au repos après le passage")
    }

    static func sustainedContactAlertsOnce() {
        var metric = HandFaceContactMetric()
        _ = metric.consume(face: face, hands: [hand()], now: 10)
        expect(metric.consume(face: face, hands: [hand()], now: 12.49) == .none,
               "pas d'événement avant la durée significative")
        guard case .sustainedContact(let evidence) = metric.consume(
            face: face, hands: [hand()], now: 12.5
        ) else {
            expect(false, "maintien de 2,5 secondes déclenche un événement")
            return
        }
        expect(evidence.duration == 2.5 && evidence.landmark == .indexFinger,
               "l'événement expose une durée et le repère déclencheur")
        expect(metric.consume(face: face, hands: [hand()], now: 14) == .none,
               "un contact continu ne répète pas l'événement")
    }

    static func briefInterruptionPreservesHold() {
        var metric = HandFaceContactMetric()
        _ = metric.consume(face: face, hands: [hand()], now: 20)
        _ = metric.consume(face: face, hands: [hand()], now: 21)
        expect(metric.consume(face: nil, hands: [], now: 21.2) == .none,
               "une perte brève reste silencieuse")
        expect(metric.consume(face: face, hands: [hand()], now: 22.5) != .none,
               "la perte de 0,2 seconde ne remet pas le maintien à zéro")
    }

    static func repeatedLossesDoNotExtendHold() {
        var metric = HandFaceContactMetric()
        _ = metric.consume(face: face, hands: [hand()], now: 25)
        _ = metric.consume(face: nil, hands: [], now: 25.20)
        _ = metric.consume(face: nil, hands: [], now: 25.34)
        _ = metric.consume(face: nil, hands: [], now: 25.36)
        expect(metric.phase == .idle, "les pertes sans nouvelle preuve expirent depuis le dernier tick valide")
        expect(metric.consume(face: face, hands: [hand()], now: 25.40) == .none,
               "une nouvelle preuve repart d'un maintien frais")
    }

    static func confidenceLossResetsPendingHold() {
        var metric = HandFaceContactMetric()
        _ = metric.consume(face: face, hands: [hand()], now: 30)
        _ = metric.consume(face: face, hands: [hand()], now: 31)
        _ = metric.consume(face: face, hands: [hand(confidence: 0.20)], now: 31.5)
        expect(metric.consume(face: face, hands: [hand()], now: 32) == .none,
               "une perte de confiance prolongée ne déclenche pas sur l'ancien maintien")
        expect(metric.consume(face: face, hands: [hand()], now: 34.5) != .none,
               "le maintien repart après une nouvelle persistance complète")
    }

    static func hysteresisUsesWiderExitBoundary() {
        var metric = HandFaceContactMetric()
        expect(metric.consume(face: face, hands: [hand(x: 0.50, y: 0.15)], now: 40) == .none,
               "le seuil d'entrée accepte la proximité du contour")
        expect(metric.consume(face: face, hands: [hand(x: 0.50, y: 0.10)], now: 40.1) == .none,
               "la zone d'hystérésis conserve le contact")
        expect(metric.phase == .tracking(since: 40), "l'hystérésis conserve le suivi")
        _ = metric.consume(face: face, hands: [hand(x: 0.50, y: 0.03)], now: 40.2)
        expect(metric.phase == .idle, "la sortie au-delà du seuil large abandonne le suivi")
    }

    static func observationExposesCurrentGeometry() {
        let observation = HandFaceContactMetric.observe(face: face, hands: [hand()])
        expect(observation.quality == .good && observation.isContact,
               "l'observation courante expose un contact géométrique")
        expect(observation.distanceRatio == 0 && observation.zone == .mouth,
               "l'observation expose la zone et la distance")

        let openContourFace = HandFaceFaceObservation(contour: [
            point(0.40, 0.20), point(0.50, 0.30), point(0.60, 0.20)
        ])
        let openContourObservation = HandFaceContactMetric.observe(
            face: openContourFace,
            hands: [.init(landmarks: [.init(.indexFinger, x: 0.50, y: 0.20)])]
        )
        expect(openContourObservation.quality == .good,
               "un contour ouvert reste une observation exploitable")
        expect((openContourObservation.distanceRatio ?? 0) > 0.30,
               "un contour ouvert ne ferme pas artificiellement le dernier segment")

        var metric = HandFaceContactMetric()
        _ = metric.consume(face: face, hands: [hand()], now: 45)
        expect(metric.currentObservation.observedAt == 45 &&
            metric.currentObservation.distanceRatio == 0 &&
            metric.currentObservation.quality == .good,
            "la dernière observation publique est horodatée pour le runtime")
    }

    static func faceSurfaceCoversCheeksAndForehead() {
        let faceWithSurface = HandFaceFaceObservation(
            contour: face.contour,
            regions: face.regions + [
                .init(kind: .faceSurface, points: [
                    point(0.32, 0.24), point(0.68, 0.24),
                    point(0.68, 0.76), point(0.32, 0.76)
                ])
            ]
        )
        let cheek = HandFaceContactMetric.observe(
            face: faceWithSurface,
            hands: [hand(x: 0.65, y: 0.70)]
        )
        expect(cheek.isContact && cheek.zone == .faceSurface,
               "la surface faciale couvre aussi une joue hors des repères détaillés")
    }

    static func stableExitRearms() {
        var metric = HandFaceContactMetric()
        _ = metric.consume(face: face, hands: [hand()], now: 50)
        expect(metric.consume(face: face, hands: [hand()], now: 52.5) != .none,
               "première alerte après maintien")
        _ = metric.consume(face: face, hands: [separatedHand()], now: 52.6)
        _ = metric.consume(face: face, hands: [separatedHand()], now: 53.0)
        expect(metric.phase == .alerted, "une sortie trop courte ne réarme pas")
        _ = metric.consume(face: face, hands: [separatedHand()], now: 53.35)
        expect(metric.phase == .idle, "une sortie stable réarme la métrique")
        _ = metric.consume(face: face, hands: [hand()], now: 54)
        expect(metric.consume(face: face, hands: [hand()], now: 56.5) != .none,
               "un second maintien peut déclencher après réarmement")
    }

    static func longLossAfterAlertRearms() {
        var metric = HandFaceContactMetric()
        _ = metric.consume(face: face, hands: [hand()], now: 60)
        expect(metric.consume(face: face, hands: [hand()], now: 62.5) != .none,
               "le maintien doit d'abord produire une alerte")
        _ = metric.consume(face: nil, hands: [], now: 62.6)
        expect(metric.phase == .alerted, "une perte brève ne réarme pas une alerte")
        _ = metric.consume(face: nil, hands: [], now: 63.0)
        expect(metric.phase == .idle,
               "une perte prolongée doit permettre un nouvel épisode")
        _ = metric.consume(face: face, hands: [hand()], now: 63.1)
        expect(metric.consume(face: face, hands: [hand()], now: 65.7) != .none,
               "un contact suivant peut à nouveau notifier")
    }
}
