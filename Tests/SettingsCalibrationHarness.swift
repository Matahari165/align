import Foundation

@main
private enum SettingsCalibrationHarness {
    static func main() {
        precondition(PostureObservationSignalID.allCases.count == 4,
                     "les réglages doivent exposer exactement quatre rappels")
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
