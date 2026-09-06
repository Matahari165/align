import Foundation

@main
private enum CalibrationPresentationHarness {
    static func main() {
        let outcomes = Dictionary(uniqueKeysWithValues: PostureObservationSignalID.allCases.map {
            ($0, PostureCalibrationSignalOutcome.pending)
        })
        let collecting = PostureCalibrationPresentation(
            phase: .collecting, progress: 0.5, outcomes: outcomes
        )
        precondition(collecting.title == "Mesure de l’ouverture des yeux…")
        precondition(collecting.progress == 0.5)
        let failed = PostureCalibrationPresentation(
            phase: .failed("Repères insuffisants"), progress: 1,
            outcomes: [.proximity: .unavailable("Repère insuffisant")]
        )
        precondition(failed.title == "Référence des yeux incomplète")
        print("CalibrationPresentationHarness: OK")
    }
}
