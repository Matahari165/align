import Foundation

@main
private enum AnalysisCadenceHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func approximately(_ lhs: TimeInterval, _ rhs: TimeInterval) -> Bool {
        abs(lhs - rhs) < 0.000_001
    }

    static func main() {
        var cadence = AnalysisCadenceController()
        expect(cadence.shouldAnalyze(at: 10), "la première frame doit être analysée")
        expect(!cadence.shouldAnalyze(at: 10.19), "le premier plan ne doit pas dépasser 5 Hz")
        expect(cadence.shouldAnalyze(at: 10.2), "le premier plan doit accepter 5 Hz")

        cadence.updatePresentation(AnalysisPresentationState(
            isApplicationActive: false,
            isWindowMiniaturized: false,
            isBenchmarkRunning: false
        ))
        expect(!cadence.shouldAnalyze(at: 10.69), "l’arrière-plan ne doit pas dépasser 2 Hz")
        expect(cadence.shouldAnalyze(at: 10.7), "l’arrière-plan doit accepter 2 Hz")
        expect(!cadence.presentation.publishesVisualUpdates, "le rendu fréquent doit être coupé en arrière-plan")

        cadence.updatePresentation(AnalysisPresentationState(
            isApplicationActive: true,
            isWindowMiniaturized: true,
            isBenchmarkRunning: false
        ))
        expect(approximately(cadence.presentation.faceInterval, 0.5), "une fenêtre réduite doit utiliser 2 Hz")

        cadence.updatePresentation(AnalysisPresentationState(
            isApplicationActive: false,
            isWindowMiniaturized: true,
            isBenchmarkRunning: true
        ))
        expect(approximately(cadence.presentation.faceInterval, 0.2), "le benchmark doit rester à 5 Hz")
        expect(cadence.presentation.publishesVisualUpdates, "le benchmark doit conserver ses mesures visuelles")
        expect(cadence.shouldAnalyze(at: 10.9), "le passage du fond au benchmark doit appliquer 5 Hz immédiatement")

        cadence.updatePresentation(.foreground)
        expect(approximately(cadence.presentation.faceInterval, 0.2), "le retour au premier plan doit restaurer 5 Hz")
        cadence.reset()
        expect(cadence.shouldAnalyze(at: 20), "la reprise après pause doit accepter la première frame")

        print("AnalysisCadenceHarness: OK")
    }
}
