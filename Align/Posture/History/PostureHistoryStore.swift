import Foundation

nonisolated struct PostureHistoryBucket: Equatable, Codable, Sendable {
    let bucketStart: Date
    let signalID: PostureObservationSignalID
    let sensitivity: PostureRecommendationSensitivity
    let ruleProfileID: String
    var observedDuration: TimeInterval
    var attentionDuration: TimeInterval
    var opportunityCount: Int
    var acceptedEventCount: Int
    /// Number of observed blink events, deliberately separate from accepted
    /// alert/opportunity events.
    var blinkEventCount: Int? = nil
    var notificationCount: Int
    var recoveryDurations: [TimeInterval]
}

nonisolated struct PostureHistoryDatabase: Equatable, Codable, Sendable {
    var buckets: [PostureHistoryBucket]
    var coverage: [PostureCoverageInterval] = []
    var controlEvents: [PostureHistoryControlEvent] = []
    var eventKeys: [String] = []

    private enum CodingKeys: String, CodingKey { case buckets, coverage, controlEvents, eventKeys }
    init(buckets: [PostureHistoryBucket], coverage: [PostureCoverageInterval] = [], controlEvents: [PostureHistoryControlEvent] = [], eventKeys: [String] = []) {
        self.buckets = buckets; self.coverage = coverage; self.controlEvents = controlEvents; self.eventKeys = eventKeys
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        buckets = try values.decode([PostureHistoryBucket].self, forKey: .buckets)
        coverage = try values.decodeIfPresent([PostureCoverageInterval].self, forKey: .coverage) ?? []
        controlEvents = try values.decodeIfPresent([PostureHistoryControlEvent].self, forKey: .controlEvents) ?? []
        eventKeys = try values.decodeIfPresent([String].self, forKey: .eventKeys) ?? []
    }

    func isSemanticallyValid(at now: Date) -> Bool {
        let nowValue = now.timeIntervalSince1970
        guard nowValue.isFinite,
              eventKeys.allSatisfy({ !$0.isEmpty }) else { return false }
        let bucketsAreValid = buckets.allSatisfy { bucket in
            let timestamp = bucket.bucketStart.timeIntervalSince1970
            return timestamp.isFinite && timestamp <= nowValue &&
                !bucket.ruleProfileID.isEmpty &&
                bucket.observedDuration.isFinite && bucket.observedDuration >= 0 &&
                bucket.attentionDuration.isFinite && bucket.attentionDuration >= 0 &&
                bucket.attentionDuration <= bucket.observedDuration &&
                bucket.opportunityCount >= 0 && bucket.acceptedEventCount >= 0 &&
                (bucket.blinkEventCount ?? 0) >= 0 && bucket.notificationCount >= 0 &&
                bucket.recoveryDurations.allSatisfy { $0.isFinite && $0 >= 0 }
        }
        let coverageIsValid = coverage.allSatisfy { interval in
            let start = interval.start.timeIntervalSince1970
            let end = interval.end.timeIntervalSince1970
            return start.isFinite && end.isFinite && start < end && end <= nowValue
        }
        let controlsAreValid = controlEvents.allSatisfy { event in
            let timestamp = event.date.timeIntervalSince1970
            return timestamp.isFinite && timestamp <= nowValue && !event.ruleProfileID.isEmpty
        }
        return bucketsAreValid && coverageIsValid && controlsAreValid
    }
}

nonisolated enum PostureCoverageChannel: String, Codable, Sendable {
    case faceAndEyes
    case upperBody
}

nonisolated struct PostureCoverageInterval: Equatable, Codable, Sendable {
    let channel: PostureCoverageChannel
    let start: Date
    let end: Date
}

nonisolated enum PostureHistoryControlAction: String, Codable, Sendable {
    case snoozed
    case disabled
    case reactivated
    case sensitivityChanged
}

nonisolated struct PostureHistoryControlEvent: Equatable, Codable, Sendable {
    let date: Date
    let signalID: PostureObservationSignalID?
    let action: PostureHistoryControlAction
    let sensitivity: PostureRecommendationSensitivity
    let ruleProfileID: String
}

nonisolated struct PostureHistoryObservation: Equatable, Sendable {
    let date: Date
    let signalID: PostureObservationSignalID
    let sensitivity: PostureRecommendationSensitivity
    let ruleProfileID: String
    let observedDuration: TimeInterval
    let attentionDuration: TimeInterval
    let beganOpportunity: Bool
    let acceptedEventCount: Int
    let blinkEventCount: Int
    let deliveredNotification: Bool
    let recoveryDuration: TimeInterval?
    var eventKey: String? = nil
    init(
        date: Date,
        signalID: PostureObservationSignalID,
        sensitivity: PostureRecommendationSensitivity,
        ruleProfileID: String,
        observedDuration: TimeInterval,
        attentionDuration: TimeInterval,
        beganOpportunity: Bool,
        acceptedEventCount: Int,
        deliveredNotification: Bool,
        recoveryDuration: TimeInterval?,
        eventKey: String? = nil,
        blinkEventCount: Int = 0
    ) {
        self.date = date
        self.signalID = signalID
        self.sensitivity = sensitivity
        self.ruleProfileID = ruleProfileID
        self.observedDuration = observedDuration
        self.attentionDuration = attentionDuration
        self.beganOpportunity = beganOpportunity
        self.acceptedEventCount = acceptedEventCount
        self.blinkEventCount = blinkEventCount
        self.deliveredNotification = deliveredNotification
        self.recoveryDuration = recoveryDuration
        self.eventKey = eventKey
    }
}

nonisolated struct PostureHistoryAccumulator: Sendable {
    static let bucketDuration: TimeInterval = 5 * 60
    static let maximumBuckets = 10_000
    static let retention: TimeInterval = 90 * 24 * 60 * 60

    private(set) var database = PostureHistoryDatabase(buckets: [])

    mutating func ingest(
        _ observation: PostureHistoryObservation,
        now: Date,
        calendar: Calendar = .current
    ) {
        guard observation.date <= now,
              observation.observedDuration.isFinite,
              observation.attentionDuration.isFinite,
              observation.acceptedEventCount >= 0,
              observation.blinkEventCount >= 0,
              observation.observedDuration >= 0,
              observation.attentionDuration >= 0,
              observation.attentionDuration <= observation.observedDuration else { return }
        prune(now: now)
        if let eventKey = observation.eventKey, database.eventKeys.contains(eventKey) { return }
        var cursor = observation.date
        let end = observation.date.addingTimeInterval(observation.observedDuration)
        var isFirstSlice = true
        while cursor < end {
            let bucketStartSeconds = floor(cursor.timeIntervalSince1970 / Self.bucketDuration) *
                Self.bucketDuration
            let bucketStart = Date(timeIntervalSince1970: bucketStartSeconds)
            let bucketEnd = bucketStart.addingTimeInterval(Self.bucketDuration)
            let dayEnd = calendar.dateInterval(of: .day, for: cursor)?.end ?? bucketEnd
            let sliceEnd = min(end, bucketEnd, dayEnd)
            let sliceDuration = sliceEnd.timeIntervalSince(cursor)
            let ratio = observation.observedDuration > 0
                ? sliceDuration / observation.observedDuration : 0
            addSlice(
                observation,
                bucketStart: bucketStart,
                observedDuration: sliceDuration,
                attentionDuration: observation.attentionDuration * ratio,
                includesEvent: isFirstSlice
            )
            cursor = sliceEnd
            isFirstSlice = false
        }
        if observation.observedDuration == 0 {
            let bucketStartSeconds = floor(observation.date.timeIntervalSince1970 / Self.bucketDuration) *
                Self.bucketDuration
            addSlice(
                observation,
                bucketStart: Date(timeIntervalSince1970: bucketStartSeconds),
                observedDuration: 0,
                attentionDuration: 0,
                includesEvent: true
            )
        }
        normalizeAndCap()
        if let eventKey = observation.eventKey {
            database.eventKeys.append(eventKey)
            if database.eventKeys.count > Self.maximumBuckets {
                database.eventKeys.removeFirst(database.eventKeys.count - Self.maximumBuckets)
            }
        }
    }

    mutating func ingestCoverage(
        channel: PostureCoverageChannel,
        interval: DateInterval,
        now: Date,
        calendar: Calendar = .current
    ) {
        guard interval.start < interval.end, interval.start <= now else { return }
        prune(now: now)
        var cursor = interval.start
        let end = min(interval.end, now)
        while cursor < end {
            let bucketStartSeconds = floor(cursor.timeIntervalSince1970 / Self.bucketDuration) *
                Self.bucketDuration
            let bucketEnd = Date(timeIntervalSince1970: bucketStartSeconds + Self.bucketDuration)
            let dayEnd = calendar.dateInterval(of: .day, for: cursor)?.end ?? bucketEnd
            let sliceEnd = min(end, bucketEnd, dayEnd)
            database.coverage.append(.init(channel: channel, start: cursor, end: sliceEnd))
            cursor = sliceEnd
        }
        database.coverage = mergeCoverage(database.coverage)
        normalizeAndCap()
    }

    private mutating func addSlice(
        _ observation: PostureHistoryObservation,
        bucketStart: Date,
        observedDuration: TimeInterval,
        attentionDuration: TimeInterval,
        includesEvent: Bool
    ) {
        let start = bucketStart
        if let index = database.buckets.firstIndex(where: {
            $0.bucketStart == start && $0.signalID == observation.signalID &&
                $0.sensitivity == observation.sensitivity &&
                $0.ruleProfileID == observation.ruleProfileID
        }) {
            database.buckets[index].observedDuration += observedDuration
            database.buckets[index].attentionDuration += attentionDuration
            database.buckets[index].opportunityCount += includesEvent && observation.beganOpportunity ? 1 : 0
            database.buckets[index].acceptedEventCount += includesEvent ? observation.acceptedEventCount : 0
            database.buckets[index].blinkEventCount =
                (database.buckets[index].blinkEventCount ?? 0) +
                (includesEvent ? observation.blinkEventCount : 0)
            database.buckets[index].notificationCount += includesEvent && observation.deliveredNotification ? 1 : 0
            if includesEvent, let recovery = observation.recoveryDuration, recovery.isFinite, recovery >= 0 {
                database.buckets[index].recoveryDurations.append(recovery)
                if database.buckets[index].recoveryDurations.count > 32 {
                    database.buckets[index].recoveryDurations.removeFirst(
                        database.buckets[index].recoveryDurations.count - 32
                    )
                }
            }
        } else {
            database.buckets.append(PostureHistoryBucket(
                bucketStart: start,
                signalID: observation.signalID,
                sensitivity: observation.sensitivity,
                ruleProfileID: observation.ruleProfileID,
                observedDuration: observedDuration,
                attentionDuration: attentionDuration,
                opportunityCount: includesEvent && observation.beganOpportunity ? 1 : 0,
                acceptedEventCount: includesEvent ? observation.acceptedEventCount : 0,
                blinkEventCount: includesEvent ? observation.blinkEventCount : 0,
                notificationCount: includesEvent && observation.deliveredNotification ? 1 : 0,
                recoveryDurations: includesEvent ? observation.recoveryDuration.map { [$0] } ?? [] : []
            ))
        }
    }

    private mutating func normalizeAndCap() {
        database.buckets.sort { $0.bucketStart < $1.bucketStart }
        if database.buckets.count > Self.maximumBuckets {
            database.buckets.removeFirst(database.buckets.count - Self.maximumBuckets)
        }
        if database.coverage.count > Self.maximumBuckets {
            database.coverage.removeFirst(database.coverage.count - Self.maximumBuckets)
        }
    }

    mutating func restore(_ database: PostureHistoryDatabase, now: Date) {
        self.database = database
        prune(now: now)
    }

    mutating func recordControlEvent(_ event: PostureHistoryControlEvent, now: Date) {
        guard event.date <= now, !event.ruleProfileID.isEmpty else { return }
        database.controlEvents.append(event)
        database.controlEvents.removeAll {
            $0.date > now || now.timeIntervalSince($0.date) > Self.retention
        }
        database.eventKeys.removeAll { $0.isEmpty }
        if database.controlEvents.count > Self.maximumBuckets {
            database.controlEvents.removeFirst(
                database.controlEvents.count - Self.maximumBuckets
            )
        }
    }

    private mutating func prune(now: Date) {
        database.buckets.removeAll {
            $0.bucketStart > now || now.timeIntervalSince($0.bucketStart) > Self.retention
        }
        database.coverage.removeAll {
            $0.end > now || now.timeIntervalSince($0.end) > Self.retention
        }
        database.controlEvents.removeAll {
            $0.date > now || now.timeIntervalSince($0.date) > Self.retention
        }
    }

    private func mergeCoverage(
        _ intervals: [PostureCoverageInterval]
    ) -> [PostureCoverageInterval] {
        let grouped = Dictionary(grouping: intervals, by: \.channel)
        return grouped.flatMap { channel, values in
            let sorted = values.sorted { $0.start < $1.start }
            var result: [PostureCoverageInterval] = []
            for value in sorted {
                if let last = result.last, value.start <= last.end {
                    result[result.count - 1] = .init(
                        channel: channel,
                        start: last.start,
                        end: max(last.end, value.end)
                    )
                } else {
                    result.append(value)
                }
            }
            return result
        }.sorted { $0.start < $1.start }
    }
}

nonisolated enum PostureHistoryPeriod: String, CaseIterable, Sendable {
    case day
    case week
    case month
}

nonisolated struct PostureHistorySignalSummary: Equatable, Sendable {
    let signalID: PostureObservationSignalID
    let observedDuration: TimeInterval
    let attentionDuration: TimeInterval
    let opportunityCount: Int
    let notificationCount: Int
    let medianRecoveryDuration: TimeInterval?
    let eventsPerObservedHour: Double?
}

nonisolated struct PostureHistorySummary: Equatable, Sendable {
    let period: PostureHistoryPeriod
    let interval: DateInterval
    let signals: [PostureHistorySignalSummary]
    let estimatedBlinksPerMinute: Double?
    let estimatedBlinkObservedDuration: TimeInterval
    let faceAndEyesCoverage: TimeInterval
    let upperBodyCoverage: TimeInterval
    let totalCoverage: TimeInterval
}

nonisolated enum PostureHistoryQuery {
    static func summary(
        database: PostureHistoryDatabase,
        period: PostureHistoryPeriod,
        containing date: Date,
        calendar: Calendar = .current
    ) -> PostureHistorySummary? {
        guard let interval = interval(for: period, containing: date, calendar: calendar) else {
            return nil
        }
        // A five-minute bucket can straddle a local period boundary. Clip
        // durations proportionally instead of attributing the whole flush to
        // whichever period contains its start.
        let included = database.buckets.filter {
            let bucketEnd = $0.bucketStart.addingTimeInterval(PostureHistoryAccumulator.bucketDuration)
            return $0.bucketStart < interval.end && bucketEnd > interval.start
        }
        let faceCoverage = coverageDuration(database.coverage, channel: .faceAndEyes, in: interval)
        let bodyCoverage = coverageDuration(database.coverage, channel: .upperBody, in: interval)
        let totalCoverage = unionDuration(database.coverage, in: interval)
        let signals = PostureObservationSignalID.allCases.map { id in
            let buckets = included.filter { $0.signalID == id }
            let observed = buckets.reduce(0) { partial, bucket in
                partial + clippedDuration(of: bucket, in: interval)
            }
            let attention = buckets.reduce(0) { partial, bucket in
                let ratio = bucket.observedDuration > 0
                    ? clippedDuration(of: bucket, in: interval) / bucket.observedDuration : 0
                return partial + bucket.attentionDuration * ratio
            }
            let eventsInPeriod = buckets.filter { interval.contains($0.bucketStart) }
            let opportunities = eventsInPeriod.reduce(0) { $0 + $1.opportunityCount }
            let notifications = eventsInPeriod.reduce(0) { $0 + $1.notificationCount }
            let recoveries = eventsInPeriod.flatMap(\.recoveryDurations).sorted()
            return PostureHistorySignalSummary(
                signalID: id,
                observedDuration: observed,
                attentionDuration: attention,
                opportunityCount: opportunities,
                notificationCount: notifications,
                medianRecoveryDuration: median(recoveries),
                eventsPerObservedHour: observed > 0
                    ? Double(opportunities) / (observed / 3_600) : nil
            )
        }
        let blinkBuckets = included.filter {
            $0.signalID == PostureObservationSignalID.estimatedBlinks && interval.contains($0.bucketStart)
        }
        let blinkSeconds = faceCoverage
        let blinkCount = blinkBuckets.reduce(0) { $0 + ($1.blinkEventCount ?? 0) }
        let required = requiredBlinkDuration(
            period: period,
            distinctDays: coveredDays(
                database.coverage,
                channel: .faceAndEyes,
                in: interval,
                calendar: calendar
            ).count
        )
        let rate = blinkSeconds >= required
            ? 60 * Double(blinkCount) / blinkSeconds
            : nil
        return PostureHistorySummary(
            period: period,
            interval: interval,
            signals: signals,
            estimatedBlinksPerMinute: rate,
            estimatedBlinkObservedDuration: blinkSeconds,
            faceAndEyesCoverage: faceCoverage,
            upperBodyCoverage: bodyCoverage,
            totalCoverage: totalCoverage
        )
    }

    static func coverageDuration(
        _ values: [PostureCoverageInterval],
        channel: PostureCoverageChannel,
        in interval: DateInterval
    ) -> TimeInterval {
        unionDuration(values.filter { $0.channel == channel }, in: interval)
    }

    private static func clippedDuration(
        of bucket: PostureHistoryBucket,
        in interval: DateInterval
    ) -> TimeInterval {
        guard bucket.observedDuration > 0 else { return 0 }
        let bucketInterval = DateInterval(
            start: bucket.bucketStart,
            end: bucket.bucketStart.addingTimeInterval(PostureHistoryAccumulator.bucketDuration)
        )
        let start = max(bucketInterval.start, interval.start)
        let end = min(bucketInterval.end, interval.end)
        guard start < end else { return 0 }
        return bucket.observedDuration * (end.timeIntervalSince(start) / bucketInterval.duration)
    }

    private static func coveredDays(
        _ values: [PostureCoverageInterval],
        channel: PostureCoverageChannel,
        in interval: DateInterval,
        calendar: Calendar
    ) -> Set<Date> {
        var days = Set<Date>()
        for value in values where value.channel == channel {
            let start = max(value.start, interval.start)
            let end = min(value.end, interval.end)
            guard start < end else { continue }
            var cursor = calendar.startOfDay(for: start)
            while cursor < end {
                days.insert(cursor)
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
        }
        return days
    }

    private static func unionDuration(
        _ values: [PostureCoverageInterval],
        in interval: DateInterval
    ) -> TimeInterval {
        let clipped = values.compactMap { value -> DateInterval? in
            let start = max(value.start, interval.start)
            let end = min(value.end, interval.end)
            return start < end ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var current: DateInterval?
        for value in clipped {
            guard let existing = current else { current = value; continue }
            if value.start <= existing.end {
                current = .init(start: existing.start, end: max(existing.end, value.end))
            } else {
                total += existing.duration
                current = value
            }
        }
        return total + (current?.duration ?? 0)
    }

    private static func interval(
        for period: PostureHistoryPeriod,
        containing date: Date,
        calendar: Calendar
    ) -> DateInterval? {
        switch period {
        case .day: calendar.dateInterval(of: .day, for: date)
        case .week: calendar.dateInterval(of: .weekOfYear, for: date)
        case .month: calendar.dateInterval(of: .month, for: date)
        }
    }

    private static func requiredBlinkDuration(
        period: PostureHistoryPeriod,
        distinctDays: Int
    ) -> TimeInterval {
        switch period {
        case .day: 5 * 60
        case .week: distinctDays >= 2 ? 30 * 60 : .infinity
        case .month: distinctDays >= 4 ? 120 * 60 : .infinity
        }
    }

    private static func median(_ sorted: [TimeInterval]) -> TimeInterval? {
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}

actor PostureHistoryStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.fileURL = base
                .appendingPathComponent("Align", isDirectory: true)
                .appendingPathComponent("posture-history-v1.json")
        }
    }

    func load() -> PostureHistoryLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        guard let data = try? Data(contentsOf: fileURL) else { return .unavailable }
        guard let value = try? decoder.decode(PostureHistoryDatabase.self, from: data),
              value.isSemanticallyValid(at: Date()) else {
            return .corrupt
        }
        return .loaded(value)
    }

    func save(_ database: PostureHistoryDatabase) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(database)
        try data.write(to: fileURL, options: .atomic)
    }

    func erase() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

nonisolated enum PostureHistoryLoadResult: Equatable, Sendable {
    case loading
    case empty
    case loaded(PostureHistoryDatabase)
    case corrupt
    case unavailable

    var database: PostureHistoryDatabase {
        if case .loaded(let value) = self { return value }
        return .init(buckets: [])
    }
}
