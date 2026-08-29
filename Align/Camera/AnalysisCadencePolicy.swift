import Foundation

nonisolated struct AnalysisPresentationState: Equatable, Sendable {
    var isApplicationActive: Bool
    var isWindowMiniaturized: Bool
    var isBenchmarkRunning: Bool

    static let foreground = AnalysisPresentationState(
        isApplicationActive: true,
        isWindowMiniaturized: false,
        isBenchmarkRunning: false
    )

    var faceInterval: TimeInterval {
        isForegroundVisible || isBenchmarkRunning ? 0.2 : 0.5
    }

    var publishesVisualUpdates: Bool {
        isForegroundVisible || isBenchmarkRunning
    }

    private var isForegroundVisible: Bool {
        isApplicationActive && !isWindowMiniaturized
    }
}

nonisolated struct AnalysisCadenceController: Sendable {
    private(set) var presentation = AnalysisPresentationState.foreground
    private(set) var lastAnalysisUptime: TimeInterval?

    mutating func updatePresentation(_ presentation: AnalysisPresentationState) {
        self.presentation = presentation
    }

    mutating func shouldAnalyze(at uptime: TimeInterval) -> Bool {
        guard let lastAnalysisUptime else {
            self.lastAnalysisUptime = uptime
            return true
        }
        let clockTolerance: TimeInterval = 0.000_001
        guard uptime - lastAnalysisUptime + clockTolerance >= presentation.faceInterval else {
            return false
        }
        self.lastAnalysisUptime = uptime
        return true
    }

    mutating func reset() {
        lastAnalysisUptime = nil
    }
}
