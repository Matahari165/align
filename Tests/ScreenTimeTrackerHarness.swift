import Foundation

@main private enum ScreenTimeTrackerHarness {
    static func main() {
        var tracker = ScreenTimeTracker(configuration: .init(
            workDuration: 2,
            breakDuration: 1,
            maximumSampleGap: 0.25
        ))

        precondition(tracker.consume(.present, at: 0) == nil)
        for index in 1...20 {
            let action = tracker.consume(.present, at: Double(index) / 10)
            precondition(action == (index == 20 ? .remind : nil))
        }
        precondition(tracker.isBreakDue)

        // Une mesure inconnue ne valide jamais une pause.
        precondition(tracker.consume(.unknown, at: 2.1) == nil)
        for index in 22...31 {
            precondition(tracker.consume(.absent, at: Double(index) / 10) == nil)
        }
        precondition(tracker.consume(.absent, at: 3.2) == .breakCompleted)
        precondition(!tracker.isBreakDue && tracker.continuousWork == 0)

        // Un trou de capture ne doit pas être ajouté au temps de travail.
        precondition(tracker.consume(.present, at: 10) == nil)
        precondition(tracker.consume(.present, at: 11) == nil)
        precondition(tracker.continuousWork == 0)

        var proactiveBreak = ScreenTimeTracker(configuration: .init(
            workDuration: 2,
            breakDuration: 1,
            maximumSampleGap: 0.25
        ))
        _ = proactiveBreak.consume(.present, at: 0)
        for index in 1...10 {
            precondition(proactiveBreak.consume(.present, at: Double(index) / 10) == nil)
        }
        for index in 11...21 {
            precondition(proactiveBreak.consume(.absent, at: Double(index) / 10) == nil)
        }
        precondition(proactiveBreak.continuousWork == 0)
        for index in 22...31 {
            precondition(proactiveBreak.consume(.present, at: Double(index) / 10) == nil)
        }
        precondition(!proactiveBreak.isBreakDue, "une pause spontanée doit relancer vingt minutes")

        print("ScreenTimeTrackerHarness: OK")
    }
}
