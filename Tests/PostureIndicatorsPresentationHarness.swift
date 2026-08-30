import Foundation

@main
private enum PostureIndicatorsPresentationHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        expect(PostureIndicatorID.allCases.count == 6, "la mâchoire reste exclue")
        expect(Set(PostureIndicatorID.allCases.map(\.title)).count == 6,
               "chaque libellé est unique")
        expect(PostureIndicatorState.needsCalibration.displayName == "À calibrer",
               "libellé calibration")
        expect(PostureIndicatorState.normal.displayName == "Dans le repère", "libellé relatif au repère")
        expect(PostureIndicatorState.attention.displayName == "Attention", "libellé attention")
        expect(PostureIndicatorState.calibrating.displayName == "Calibration…", "libellé calibration active")
        expect(PostureIndicatorState.pending.displayName == "Observation…", "libellé observation")
        expect(PostureIndicatorState.unavailable.displayName == "Indisponible", "libellé indisponible")
        expect(PostureIndicatorID.estimatedBlinks.title.contains("estimés"),
               "le compteur de clignements reste observationnel")
        expect(PostureIndicatorID.estimatedForwardHead.title.contains("estimation"),
               "la tête avancée reste un proxy honnête")
        print("PostureIndicatorsPresentationHarness: OK")
    }
}
