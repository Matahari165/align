import Foundation

@main
private enum SettingsCalibrationHarness {
    static func main() {
        precondition(PostureObservationSignalID.allCases.count == 8,
                     "huit observations doivent être visibles et historisées")
        precondition(PostureObservationSignalID.alertableCases == [
            .proximity, .torsoInclination, .raisedShoulders, .estimatedBlinks,
            .shoulderSlope, .closedShoulders, .headTilt, .handOnFace
        ], "les réglages doivent exposer exactement les huit rappels canoniques")
        precondition(PostureRecommendationSensitivity.defaultValue == .sensitive,
                     "Sensible doit être le défaut")
        let choices: [PostureSnoozeChoice] = [.oneHour, .today, .untilReactivation]
        precondition(choices.count == 3)
        let failed = PostureCalibrationPresentation(
            phase: .failed("Repère insuffisant"), progress: 1,
            outcomes: [.proximity: .unavailable("Repère insuffisant")]
        )
        precondition(failed.title == "Calibration incomplète")
        print("SettingsCalibrationHarness: OK")
    }
}
