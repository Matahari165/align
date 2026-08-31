import Foundation

nonisolated enum ShoulderTrackingState: Sendable {
    case detected, partial, lost, technicalError
}

@main
private enum ShoulderStatusPresentationHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let initial = ShoulderStatusPresentation.make(for: nil)
        expect(initial.title == "Recherche des épaules", "nil ne doit jamais être présenté comme Perdu")
        expect(initial.explanation == "Place le haut du corps face à la caméra.", "le premier état doit rester neutre")

        let cases: [(ShoulderTrackingState, String, String)] = [
            (.detected, "Épaules détectées", "Les deux épaules sont suivies localement."),
            (.partial, "Épaules partiellement détectées", "Une seule épaule est détectée. Ajuste ta position face à la caméra."),
            (.lost, "Épaules non détectées", "Aucune épaule n’est détectée. Place le haut du corps face à la caméra."),
            (.technicalError, "Erreur d’analyse", "L’analyse des épaules a rencontré un problème. Align réessaie automatiquement.")
        ]

        for (state, title, explanation) in cases {
            let presentation = ShoulderStatusPresentation.make(for: state)
            expect(presentation.title == title, "titre incorrect pour \(state)")
            expect(presentation.explanation == explanation, "explication incorrecte pour \(state)")
            expect(!presentation.title.contains("BlazePose"), "le moteur ne doit jamais être nommé")
        }

        // La présentation en caméra active ne reçoit volontairement aucun
        // ancien trackingMode : BlazePose est son unique entrée.
        expect(cases.count == 4, "les quatre états épaules doivent être couverts")
        print("ShoulderStatusPresentationHarness: OK")
    }
}
