import Foundation

/// User-facing screen break preferences. Raw values stay in user units.
nonisolated struct ScreenBreakSettings: Equatable, Codable, Sendable {
    var isEnabled = true
    var workMinutes: Double = 20
    var breakSeconds: Double = 20
    var usesFullscreenOverlay = true
    var sendsNotification = true

    init(
        isEnabled: Bool = true,
        workMinutes: Double = 20,
        breakSeconds: Double = 20,
        usesFullscreenOverlay: Bool = true,
        sendsNotification: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.workMinutes = Self.clampedWorkMinutes(workMinutes)
        self.breakSeconds = Self.clampedBreakSeconds(breakSeconds)
        self.usesFullscreenOverlay = usesFullscreenOverlay
        self.sendsNotification = sendsNotification
    }

    /// Clamped work interval in seconds.
    var workDuration: TimeInterval {
        Self.clampedWorkMinutes(workMinutes) * 60
    }

    /// Clamped break goal in seconds.
    var breakDuration: TimeInterval {
        Self.clampedBreakSeconds(breakSeconds)
    }

    /// Tracker input derived from the clamped durations.
    var trackerConfiguration: ScreenTimeTracker.Configuration {
        var configuration = ScreenTimeTracker.Configuration.default
        configuration.workDuration = workDuration
        configuration.breakDuration = breakDuration
        return configuration
    }

    static func clampedWorkMinutes(_ value: Double) -> Double {
        min(120, max(1, value))
    }

    static func clampedBreakSeconds(_ value: Double) -> Double {
        min(120, max(5, value))
    }
}

nonisolated struct ScreenBreakSettingsStore {
    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = "align.screenBreakSettings.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> ScreenBreakSettings {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(ScreenBreakSettings.self, from: data) else {
            return .init()
        }
        return value
    }

    func save(_ value: ScreenBreakSettings) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
