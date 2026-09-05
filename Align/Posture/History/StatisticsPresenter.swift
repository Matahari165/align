import Foundation

nonisolated struct StatisticsSeriesPoint: Equatable, Sendable, Identifiable {
    let start: Date
    let label: String
    let value: Double?
    let coverage: TimeInterval
    var id: Date { start }
}

nonisolated struct StatisticsSignalRow: Equatable, Sendable, Identifiable {
    let id: PostureObservationSignalID
    let title: String
    let experimental: Bool
    let primary: String
    let secondary: String
    let accessibilityLabel: String
}

nonisolated struct StatisticsCoverageMetric: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let value: String
}

nonisolated enum StatisticsContentState: Equatable, Sendable {
    case loading
    case empty(String)
    case insufficient(String)
    case content
    case corrupt(String)
    case unavailable(String)
}

nonisolated struct StatisticsViewState: Equatable, Sendable {
    let state: StatisticsContentState
    let periodLabel: String
    let coverageTitle: String
    let coverageDetail: String
    let coverageAccessibilityLabel: String
    let coverageMetrics: [StatisticsCoverageMetric]
    let insights: [PostureInsight]
    let series: [StatisticsSeriesPoint]
    let rows: [StatisticsSignalRow]
    let blinkDetail: String
}

nonisolated struct PostureInsight: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let detail: String
}

nonisolated enum PostureInsights {
    static func make(summary: PostureHistorySummary, comparable: Bool) -> [PostureInsight] {
        var values: [PostureInsight] = []
        if summary.totalCoverage > 0 {
            values.append(.init(
                id: "coverage",
                title: "Observation disponible",
                detail: "Basé sur \(StatisticsPresenter.duration(summary.totalCoverage)) réellement observées."
            ))
        }
        guard comparable else { return Array(values.prefix(1)) }
        if let strongest = summary.signals
            .filter({ $0.eventsPerObservedHour != nil })
            .max(by: { ($0.eventsPerObservedHour ?? 0) < ($1.eventsPerObservedHour ?? 0) }) {
            values.append(.init(
                id: "frequent-\(strongest.signalID.rawValue)",
                title: "\(StatisticsPresenter.title(strongest.signalID)) · variation la plus fréquente",
                detail: String(format: "%.1f par heure observée.", strongest.eventsPerObservedHour ?? 0)
            ))
        }
        if let recovery = summary.signals.compactMap({ item -> (PostureObservationSignalID, Double)? in
            item.medianRecoveryDuration.map { (item.signalID, $0) }
        }).min(by: { $0.1 < $1.1 }) {
            values.append(.init(
                id: "recovery-\(recovery.0.rawValue)",
                title: "Retour au repère",
                detail: "\(StatisticsPresenter.duration(recovery.1)) en médiane après \(StatisticsPresenter.title(recovery.0).lowercased())."
            ))
        }
        return Array(values.prefix(3))
    }

    static func make(
        summary: PostureHistorySummary,
        database: PostureHistoryDatabase,
        period: PostureHistoryPeriod,
        date: Date,
        calendar: Calendar
    ) -> [PostureInsight] {
        let comparable = isComparable(database: database, interval: summary.interval)
        var values: [PostureInsight] = []
        let component: Calendar.Component = switch period {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        if let previousDate = calendar.date(byAdding: component, value: -1, to: date),
           let previous = PostureHistoryQuery.summary(database: database, period: period, containing: previousDate, calendar: calendar),
           comparable && isComparable(database: database, interval: previous.interval),
           profiles(database: database, interval: summary.interval) ==
                profiles(database: database, interval: previous.interval),
           previous.totalCoverage > 0,
           summary.totalCoverage > 0,
           let current = summary.signals.first(where: { $0.signalID == .shoulderSlope })?.eventsPerObservedHour,
           let old = previous.signals.first(where: { $0.signalID == .shoulderSlope })?.eventsPerObservedHour {
            let direction = current <= old ? "moins fréquentes" : "plus fréquentes"
            values.append(.init(
                id: "trend-shoulders",
                title: "Tendance observée",
                detail: String(format: "Les déséquilibres des épaules sont %@ cette période : %.1f par heure observée, contre %.1f précédemment. Basé sur %@ observées.", direction, current, old, StatisticsPresenter.duration(summary.totalCoverage))
            ))
        }
        values.append(contentsOf: make(summary: summary, comparable: comparable))
        return Array(values.prefix(3))
    }

    private static func isComparable(database: PostureHistoryDatabase, interval: DateInterval) -> Bool {
        let values = database.buckets.filter { interval.contains($0.bucketStart) }
        return Set(values.map(\.sensitivity)).count <= 1 && Set(values.map(\.ruleProfileID)).count <= 1
    }

    private static func profiles(database: PostureHistoryDatabase, interval: DateInterval) -> Set<String> {
        Set(database.buckets.filter { interval.contains($0.bucketStart) }
            .map { "\($0.ruleProfileID)-\($0.sensitivity.rawValue)" })
    }
}

nonisolated enum StatisticsPresenter {
    static func make(
        loadResult: PostureHistoryLoadResult,
        database: PostureHistoryDatabase,
        period: PostureHistoryPeriod,
        date: Date,
        selectedSignal: PostureObservationSignalID = .shoulderSlope,
        calendar: Calendar = .current
    ) -> StatisticsViewState {
        if case .loading = loadResult { return terminal(.loading, period: period, date: date) }
        if case .corrupt = loadResult { return terminal(.corrupt("L’historique local ne peut pas être lu."), period: period, date: date) }
        if case .unavailable = loadResult { return terminal(.unavailable("L’historique local est temporairement indisponible."), period: period, date: date) }
        guard let summary = PostureHistoryQuery.summary(database: database, period: period, containing: date, calendar: calendar) else {
            return terminal(.unavailable("Cette période ne peut pas être affichée."), period: period, date: date)
        }
        let hasObservations = summary.totalCoverage > 0 || summary.signals.contains { $0.observedDuration > 0 }
        let contentState: StatisticsContentState = hasObservations
            ? .content : .empty("Aucune observation fiable pour cette période.")
        let rows = summary.signals.map { row($0, summary: summary) }
        let blink = summary.estimatedBlinksPerMinute.map {
            String(format: "%.1f/min · calculé sur %@ de visage et deux yeux fiables", $0, duration(summary.estimatedBlinkObservedDuration))
        } ?? "Données insuffisantes — \(duration(summary.estimatedBlinkObservedDuration)) fiables sur \(blinkRequirement(for: period)) requises"
        return .init(
            state: contentState,
            periodLabel: periodLabel(period, date: date, calendar: calendar),
            coverageTitle: summary.totalCoverage > 0 ? "\(duration(summary.totalCoverage)) observées" : "Données insuffisantes",
            coverageDetail: "Seul le temps réellement fiable est compté.",
            coverageAccessibilityLabel: "Couverture fiable. Total \(duration(summary.totalCoverage)). Visage et deux yeux \(duration(summary.faceAndEyesCoverage)). Haut du corps \(duration(summary.upperBodyCoverage)).",
            coverageMetrics: [
                .init(id: "total", title: "Total fiable", value: duration(summary.totalCoverage)),
                .init(id: "face", title: "Visage + yeux", value: duration(summary.faceAndEyesCoverage)),
                .init(id: "body", title: "Haut du corps", value: duration(summary.upperBodyCoverage))
            ],
            insights: PostureInsights.make(summary: summary, database: database, period: period, date: date, calendar: calendar),
            series: series(database: database, summary: summary, period: period, date: date, signalID: selectedSignal, calendar: calendar),
            rows: rows,
            blinkDetail: blink
        )
    }

    static func title(_ id: PostureObservationSignalID) -> String {
        switch id {
        case .proximity: "Proximité apparente"
        case .torsoInclination: "Torse incliné"
        case .raisedShoulders: "Épaules relevées"
        case .shoulderSlope: "Inclinaison des épaules"
        case .estimatedBlinks: "Clignements estimés"
        case .closedShoulders: "Tête–épaules"
        case .headTilt: "Tête penchée"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60)"
    }

    private static func blinkRequirement(for period: PostureHistoryPeriod) -> String {
        switch period {
        case .day: "5 min"
        case .week: "30 min"
        case .month: "120 min"
        }
    }

    private static func row(_ value: PostureHistorySignalSummary, summary: PostureHistorySummary) -> StatisticsSignalRow {
        if value.signalID == .estimatedBlinks {
            let primary = summary.estimatedBlinksPerMinute.map {
                String(format: "%.1f/min · visage et deux yeux fiables", $0)
            } ?? "Données insuffisantes"
            let secondary = summary.estimatedBlinkObservedDuration > 0
                ? "Estimation · \(duration(summary.estimatedBlinkObservedDuration)) fiables · \(value.notificationCount) rappel(s)"
                : "Estimation · Aucune information fiable"
            return .init(id: value.signalID, title: title(value.signalID), experimental: true,
                         primary: primary, secondary: secondary,
                         accessibilityLabel: "Clignements estimés. \(primary). \(secondary).")
        }
        let hasData = value.observedDuration > 0
        let primary = hasData && value.eventsPerObservedHour != nil
            ? String(format: "%.1f variation/h observée", value.eventsPerObservedHour!) : "Données insuffisantes"
        let isExperimental = value.signalID == .closedShoulders
        let secondary: String
        if !hasData {
            secondary = "Aucune information fiable"
        } else {
            secondary = "\(value.notificationCount) rappel(s) · retour médian \(value.medianRecoveryDuration.map(shortDuration) ?? "indisponible")"
        }
        return .init(
            id: value.signalID,
            title: title(value.signalID),
            experimental: isExperimental,
            primary: primary,
            secondary: secondary,
            accessibilityLabel: "\(title(value.signalID))\(isExperimental ? ", estimation" : ""). \(primary). \(secondary)."
        )
    }

    private static func shortDuration(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : duration(seconds)
    }

    private static func series(database: PostureHistoryDatabase, summary: PostureHistorySummary, period: PostureHistoryPeriod, date: Date, signalID: PostureObservationSignalID, calendar: Calendar) -> [StatisticsSeriesPoint] {
        guard let outer = interval(period, date: date, calendar: calendar) else { return [] }
        let component: Calendar.Component = period == .day ? .hour : (period == .week ? .day : .weekOfMonth)
        var cursor = outer.start
        var result: [StatisticsSeriesPoint] = []
        let formatter = DateFormatter(); formatter.locale = .current; formatter.dateFormat = period == .day ? "HH" : (period == .week ? "EEE" : "'S'w")
        while cursor < outer.end {
            let next = min(calendar.date(byAdding: component, value: 1, to: cursor) ?? outer.end, outer.end)
            let buckets = database.buckets.filter { $0.signalID == signalID && $0.bucketStart >= cursor && $0.bucketStart < next }
            let observed = buckets.reduce(0) { $0 + $1.observedDuration }
            let events = signalID == .estimatedBlinks
                ? buckets.reduce(0) { $0 + ($1.blinkEventCount ?? 0) }
                : buckets.reduce(0) { $0 + $1.opportunityCount }
            let bucketCoverage: TimeInterval = signalID == .estimatedBlinks
                ? PostureHistoryQuery.coverageDuration(database.coverage, channel: .faceAndEyes, in: .init(start: cursor, end: next))
                : observed
            result.append(.init(start: cursor, label: formatter.string(from: cursor), value: bucketCoverage > 0 ? (signalID == .estimatedBlinks ? 60 * Double(events) / bucketCoverage : Double(events) / (observed / 3600)) : nil, coverage: bucketCoverage))
            cursor = next
        }
        return result
    }

    private static func isComparable(database: PostureHistoryDatabase, interval: DateInterval) -> Bool {
        let values = database.buckets.filter { interval.contains($0.bucketStart) }
        return Set(values.map(\.sensitivity)).count <= 1 && Set(values.map(\.ruleProfileID)).count <= 1
    }

    private static func interval(_ period: PostureHistoryPeriod, date: Date, calendar: Calendar) -> DateInterval? {
        switch period { case .day: calendar.dateInterval(of: .day, for: date); case .week: calendar.dateInterval(of: .weekOfYear, for: date); case .month: calendar.dateInterval(of: .month, for: date) }
    }

    private static func periodLabel(_ period: PostureHistoryPeriod, date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter(); formatter.locale = .current; formatter.dateStyle = period == .day ? .long : .medium; return formatter.string(from: date)
    }

    private static func terminal(_ state: StatisticsContentState, period: PostureHistoryPeriod, date: Date) -> StatisticsViewState {
        .init(state: state, periodLabel: periodLabel(period, date: date, calendar: .current), coverageTitle: "Données indisponibles", coverageDetail: "", coverageAccessibilityLabel: "Couverture indisponible", coverageMetrics: [], insights: [], series: [], rows: [], blinkDetail: "Données insuffisantes")
    }
}
