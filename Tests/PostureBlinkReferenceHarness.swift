import Foundation

@main
private enum PostureBlinkReferenceHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("PostureBlinkReferenceHarness: FAIL — \(message)\n", stderr)
            exit(1)
        }
    }

    static func window(
        _ start: TimeInterval,
        observable: TimeInterval,
        blinks: Int
    ) -> PostureBlinkReferenceWindow {
        PostureBlinkReferenceWindow(
            startedAt: start,
            endedAt: start + 60,
            observableSeconds: observable,
            blinkCount: blinks
        )
    }

    static func main() {
        var reference = PostureBlinkReference()

        let backgroundOnly = reference.ingest(window(0, observable: 30, blinks: 2))
        expect(backgroundOnly == .rejected(.insufficientObservableTime),
               "une fenêtre à 2 Hz ne doit pas devenir une fréquence valide")
        expect(reference.acceptedWindows.isEmpty,
               "une couverture insuffisante ne doit pas entrer dans la médiane")

        expect(reference.ingest(window(0, observable: 60, blinks: 12)) == .accepted(windowCount: 1),
               "la première fenêtre complète doit être acceptée")
        // Douze ticks consécutifs de la même fenêtre ne sont pas douze
        // fenêtres indépendantes : le recouvrement doit les refuser.
        for index in 1...12 {
            let result = reference.ingest(PostureBlinkReferenceWindow(
                startedAt: Double(index) * 0.1,
                endedAt: 60 + Double(index) * 0.1,
                observableSeconds: 60,
                blinkCount: 12
            ))
            expect(result == .rejected(.overlappingWindow),
                   "un tick de la fenêtre courante ne doit pas avancer la calibration")
        }
        expect(reference.acceptedWindows.count == 1,
               "les ticks consécutifs doivent rester un seul échantillon")

        expect(reference.ingest(window(60, observable: 60, blinks: 18)) == .accepted(windowCount: 2),
               "la deuxième fenêtre non recouvrante doit être acceptée")
        let frozen = reference.ingest(window(120, observable: 60, blinks: 6))
        expect(frozen == .frozen(targetPerMinute: 12),
               "trois fenêtres doivent geler la médiane 12 clignements/minute")
        expect(reference.isFrozen && reference.targetPerMinute == 12,
               "la cible personnelle doit rester lisible après gel")

        let ignored = reference.ingest(window(180, observable: 60, blinks: 60))
        expect(ignored == .frozen(targetPerMinute: 12),
               "un nouveau tick ne doit pas déplacer une référence gelée")

        reference.reset()
        var invalidConfiguration = PostureBlinkReferenceConfiguration.default
        invalidConfiguration.minimumObservableSeconds = 61
        var invalidReference = PostureBlinkReference(configuration: invalidConfiguration)
        expect(invalidReference.ingest(window(0, observable: 60, blinks: 12)) ==
                   .rejected(.invalidConfiguration),
               "une configuration impossible doit rester indisponible")

        print("PostureBlinkReferenceHarness: OK")
    }
}
