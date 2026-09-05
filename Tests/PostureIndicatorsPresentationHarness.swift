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
        expect(PostureIndicatorID.allCases.count == 7,
               "le rail doit contenir les sept observations raccordées")
        expect(Set(PostureIndicatorID.allCases.map(\.title)).count == 7,
               "chaque observation doit garder un libellé unique")
        expect(PostureIndicatorID.shoulderSlope.title == "Inclinaison des épaules",
               "la pente doit être une observation principale explicite")
        expect(PostureIndicatorID.closedShoulders.title == "Tête–épaules",
               "le rapport commun ne doit pas affirmer laquelle des deux causes le modifie")
        expect(PostureIndicatorID.estimatedBlinks.title.contains("estimés"),
               "les clignements restent présentés comme une estimation")
        expect(PostureIndicatorState.needsCalibration.displayName == "À calibrer",
               "libellé calibration")
        expect(PostureIndicatorState.normal.displayName == "Dans le repère",
               "libellé relatif au repère")
        print("PostureIndicatorsPresentationHarness: OK")
    }
}
