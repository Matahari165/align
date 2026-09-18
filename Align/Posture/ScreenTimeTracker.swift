import Foundation

nonisolated enum ScreenPresence: String, Codable, Sendable {
    case present
    case absent
    case unknown
}

nonisolated enum ScreenBreakEventKind: String, Codable, Sendable {
    case reminded
    case completed
}

nonisolated struct ScreenBreakEvent: Equatable, Codable, Sendable {
    let date: Date
    let kind: ScreenBreakEventKind
}

nonisolated struct ScreenTimeTracker: Equatable, Sendable {
    struct Configuration: Equatable, Sendable {
        var workDuration: TimeInterval = 20 * 60
        var breakDuration: TimeInterval = 20
        var maximumSampleGap: TimeInterval = 0.35

        static let `default` = Self()
    }

    enum Action: Equatable, Sendable {
        case remind
        case breakCompleted
    }

    private(set) var configuration: Configuration
    private(set) var continuousWork: TimeInterval = 0
    private(set) var breakProgress: TimeInterval = 0
    private(set) var isBreakDue = false
    private var lastSampleAt: TimeInterval?
    private var lastPresence: ScreenPresence = .unknown

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Applies a new work/break configuration while preserving the running
    /// progress. Counters are clamped so a shorter target never keeps a stale
    /// over-full value.
    mutating func applyConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
        continuousWork = min(continuousWork, configuration.workDuration)
        breakProgress = min(breakProgress, configuration.breakDuration)
        if continuousWork < configuration.workDuration {
            isBreakDue = false
        }
    }

    mutating func consume(_ presence: ScreenPresence, at uptime: TimeInterval) -> Action? {
        guard uptime.isFinite else { return nil }
        defer {
            lastSampleAt = uptime
            lastPresence = presence
        }
        guard let previous = lastSampleAt, uptime > previous else { return nil }
        let delta = uptime - previous
        guard delta <= configuration.maximumSampleGap else {
            breakProgress = 0
            return nil
        }

        if presence == .absent {
            if lastPresence == .absent {
                breakProgress += delta
            }
            guard breakProgress >= configuration.breakDuration else { return nil }
            let completedRequestedBreak = isBreakDue
            continuousWork = 0
            isBreakDue = false
            return completedRequestedBreak ? .breakCompleted : nil
        }

        breakProgress = 0
        if isBreakDue {
            return nil
        }

        guard presence == .present, lastPresence == .present else { return nil }
        continuousWork += delta
        if continuousWork >= configuration.workDuration {
            isBreakDue = true
            breakProgress = 0
            return .remind
        }
        return nil
    }

    mutating func reset() {
        self = Self(configuration: configuration)
    }
}
