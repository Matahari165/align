import Foundation

nonisolated enum PostureAlertOperatingMode: String, Codable, Sendable {
    case validation
    case normal
}

nonisolated struct PostureSignalAlertConfiguration: Equatable, Codable, Sendable {
    let persistence: TimeInterval
    let recovery: TimeInterval
    let cooldown: TimeInterval
    let dailyMaximum: Int

    var isValid: Bool {
        persistence.isFinite && persistence > 0 && recovery.isFinite && recovery > 0 &&
            cooldown.isFinite && cooldown > 0 && dailyMaximum > 0
    }
}

nonisolated struct PostureGlobalAlertConfiguration: Equatable, Codable, Sendable {
    let mode: PostureAlertOperatingMode
    let minimumIntervalBetweenSignals: TimeInterval
    let dailyMaximum: Int
    let dailyWindow: TimeInterval

    static let validation = Self(
        mode: .validation,
        minimumIntervalBetweenSignals: 5 * 60,
        dailyMaximum: 12,
        dailyWindow: 24 * 60 * 60
    )

    static let normal = Self(
        mode: .normal,
        minimumIntervalBetweenSignals: 30,
        dailyMaximum: 1_440,
        dailyWindow: 24 * 60 * 60
    )

    var isValid: Bool {
        minimumIntervalBetweenSignals.isFinite && minimumIntervalBetweenSignals > 0 &&
            dailyMaximum > 0 && dailyWindow.isFinite && dailyWindow > 0
    }
}

nonisolated struct PostureAlertCandidate: Equatable, Codable, Sendable {
    let identifier: String
    let signalID: PostureObservationSignalID
    let generation: UInt64
    let contextKey: String
    let episodeID: UInt64
    /// Identifie une réservation précise, y compris quand le même épisode
    /// reste actif et produit plusieurs rappels.
    let reservationID: UInt64
    let createdAt: TimeInterval
    let isExperimental: Bool
    let sensitivity: PostureRecommendationSensitivity
    let ruleProfileID: String

    init(
        identifier: String,
        signalID: PostureObservationSignalID,
        generation: UInt64,
        contextKey: String = "",
        episodeID: UInt64,
        reservationID: UInt64,
        createdAt: TimeInterval,
        isExperimental: Bool,
        sensitivity: PostureRecommendationSensitivity = .sensitive,
        ruleProfileID: String = "runtime-v2"
    ) {
        self.identifier = identifier
        self.signalID = signalID
        self.generation = generation
        self.contextKey = contextKey
        self.episodeID = episodeID
        self.reservationID = reservationID
        self.createdAt = createdAt
        self.isExperimental = isExperimental
        self.sensitivity = sensitivity
        self.ruleProfileID = ruleProfileID
    }
}

nonisolated struct PostureAlertDeliveryState: Codable, Sendable, Equatable {
    var globalDeliveries: [TimeInterval] = []
    var perSignal: [String: [TimeInterval]] = [:]
    var requiresRecovery: [String: Bool] = [:]

    private enum CodingKeys: String, CodingKey {
        case globalDeliveries, perSignal, requiresRecovery
    }

    init(
        globalDeliveries: [TimeInterval] = [],
        perSignal: [String: [TimeInterval]] = [:],
        requiresRecovery: [String: Bool] = [:]
    ) {
        self.globalDeliveries = globalDeliveries
        self.perSignal = perSignal
        self.requiresRecovery = requiresRecovery
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        globalDeliveries = try values.decodeIfPresent(
            [TimeInterval].self, forKey: .globalDeliveries
        ) ?? []
        perSignal = try values.decodeIfPresent(
            [String: [TimeInterval]].self, forKey: .perSignal
        ) ?? [:]
        requiresRecovery = try values.decodeIfPresent(
            [String: Bool].self, forKey: .requiresRecovery
        ) ?? [:]
    }
}

nonisolated struct PostureAlertControl: Equatable, Codable, Sendable {
    var isEnabled = true
    var snoozedUntil: TimeInterval?
    var isSnoozedUntilReactivation = false

    func permits(at now: TimeInterval) -> Bool {
        isEnabled && !isSnoozedUntilReactivation &&
            (snoozedUntil.map { now >= $0 } ?? true)
    }
}

nonisolated enum PostureSnoozeChoice: String, Codable, Sendable {
    case oneHour
    case today
    case untilReactivation
}

nonisolated struct PostureAlertSettings: Equatable, Codable, Sendable {
    var sensitivity: PostureRecommendationSensitivity = .defaultValue
    var sensitivityWasChosenByUser = false
    var controls = Dictionary(uniqueKeysWithValues:
        PostureObservationSignalID.alertableCases.map { ($0, PostureAlertControl()) })
}

nonisolated struct PostureAlertSettingsStore {
    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = "posture.alertSettings.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> PostureAlertSettings {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(PostureAlertSettings.self, from: data) else {
            return .init()
        }
        return value
    }

    func save(_ value: PostureAlertSettings) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Pure arbitration. Delivery and authorization remain MainActor side effects.
nonisolated struct PostureAlertCoordinator: Sendable {
    private let baseSignalConfigurations: [PostureObservationSignalID: PostureSignalAlertConfiguration]
    private(set) var signalConfigurations: [PostureObservationSignalID: PostureSignalAlertConfiguration]
    let globalConfiguration: PostureGlobalAlertConfiguration
    let priority: [PostureObservationSignalID]

    private var states: [PostureObservationSignalID: SignalAlertState] = [:]
    private var nextReservationID: UInt64 = 0
    private(set) var controls: [PostureObservationSignalID: PostureAlertControl]
    private(set) var globalDeliveries: [TimeInterval] = []
    private(set) var sensitivity: PostureRecommendationSensitivity

    init(
        signalConfigurations: [PostureObservationSignalID: PostureSignalAlertConfiguration],
        globalConfiguration: PostureGlobalAlertConfiguration,
        sensitivity: PostureRecommendationSensitivity = .sensitive,
        priority: [PostureObservationSignalID] = [
            .proximity, .raisedShoulders, .torsoInclination, .headTilt,
            .shoulderSlope, .closedShoulders, .estimatedBlinks, .handOnFace
        ]
    ) {
        self.baseSignalConfigurations = signalConfigurations
        self.signalConfigurations = signalConfigurations
        self.globalConfiguration = globalConfiguration
        self.sensitivity = sensitivity
        self.priority = priority
        controls = Dictionary(uniqueKeysWithValues:
            PostureObservationSignalID.alertableCases.map { ($0, PostureAlertControl()) })
    }

    mutating func consume(
        _ snapshot: PostureObservationsSnapshot,
        now: TimeInterval,
        freshnessNow: TimeInterval? = nil
    ) -> PostureAlertCandidate? {
        guard globalConfiguration.isValid, now.isFinite else { return nil }
        let evidenceNow = freshnessNow ?? snapshot.producedAt
        guard evidenceNow.isFinite else { return nil }
        globalDeliveries.removeAll { now < $0 || now - $0 > globalConfiguration.dailyWindow }

        var eligible: [(Int, PostureSignalSnapshot, PostureSignalAlertConfiguration)] = []
        for signal in snapshot.signals {
            guard PostureObservationSignalID.alertableCases.contains(signal.signalID),
                  let configuration = signalConfigurations[signal.signalID],
                  configuration.isValid,
                  controls[signal.signalID, default: .init()].permits(at: now) else { continue }
            var state = states[signal.signalID] ?? .init()
            if state.generation != snapshot.generation || state.contextKey != snapshot.contextKey {
                state.clearRuntimeIdentity()
                state.generation = snapshot.generation
                state.contextKey = snapshot.contextKey
            }
            updateRecovery(signal, configuration: configuration, now: now, state: &state)
            let isFresh = signal.observedAt.map { observedAt in
                observedAt.isFinite && evidenceNow >= observedAt &&
                    evidenceNow - observedAt <= PostureObservationEngine.freshnessTTL(for: signal.signalID)
            } ?? false
            if signal.availability == .available,
               signal.assessment == .attention,
               signal.quality == .good,
               isFresh,
               let episodeID = signal.episodeID {
                if state.attentionEpisodeID != episodeID {
                    state.reservedEpisodeID = nil
                    state.reservedReservationID = nil
                    state.attentionEpisodeID = episodeID
                    state.attentionSince = now
                }
                let ttl = PostureObservationEngine.freshnessTTL(for: signal.signalID)
                let evidenceAge = signal.observedAt.map { evidenceNow - $0 } ?? .infinity
                let freshnessRemaining = ttl - evidenceAge
                state.freshnessExpiresAt = now + freshnessRemaining
                if state.reservedEpisodeID == nil,
                   now >= state.retryNotBefore,
                   now - (state.attentionSince ?? now) >= configuration.persistence,
                   state.deliveryTimes.filter({ now >= $0 && now - $0 <= 24 * 60 * 60 }).count <
                       configuration.dailyMaximum,
                   state.deliveryTimes.last.map({ now - $0 >= configuration.cooldown }) ?? true {
                    eligible.append((priority.firstIndex(of: signal.signalID) ?? Int.max,
                                     signal, configuration))
                }
            } else {
                state.attentionSince = nil
                state.attentionEpisodeID = nil
                state.reservedEpisodeID = nil
                state.reservedReservationID = nil
                state.freshnessExpiresAt = nil
            }
            states[signal.signalID] = state
        }

        guard globalDeliveries.count < globalConfiguration.dailyMaximum,
              globalDeliveries.last.map({ now - $0 >= globalConfiguration.minimumIntervalBetweenSignals }) ?? true,
              let (_, signal, _) = eligible.min(by: { lhs, rhs in
                  let lhsState = states[lhs.1.signalID] ?? .init()
                  let rhsState = states[rhs.1.signalID] ?? .init()
                  switch (lhsState.lastScheduledAt, rhsState.lastScheduledAt) {
                  case (nil, nil):
                      return lhs.0 < rhs.0
                  case (nil, .some):
                      return true
                  case (.some, nil):
                      return false
                  case let (.some(lhsAt), .some(rhsAt)) where lhsAt != rhsAt:
                      return lhsAt < rhsAt
                  default:
                      return lhs.0 < rhs.0
                  }
              }),
              let episodeID = signal.episodeID else { return nil }

        var state = states[signal.signalID] ?? .init()
        nextReservationID &+= 1
        let reservationID = nextReservationID
        state.reservedEpisodeID = episodeID
        state.reservedReservationID = reservationID
        state.lastScheduledAt = now
        states[signal.signalID] = state
        return PostureAlertCandidate(
            identifier: "posture.\(signal.signalID.rawValue).g\(snapshot.generation).e\(episodeID).r\(reservationID)",
            signalID: signal.signalID,
            generation: snapshot.generation,
            contextKey: snapshot.contextKey,
            episodeID: episodeID,
            reservationID: reservationID,
            createdAt: now,
            isExperimental: signal.signalID == .estimatedBlinks ||
                signal.signalID == .closedShoulders || signal.signalID == .handOnFace,
            sensitivity: sensitivity,
            ruleProfileID: "runtime-v2"
        )
    }

    func ownsReservation(_ candidate: PostureAlertCandidate, now: TimeInterval) -> Bool {
        guard now.isFinite,
              let state = states[candidate.signalID],
              state.generation == candidate.generation,
              state.contextKey == candidate.contextKey,
              state.reservedEpisodeID == candidate.episodeID,
              state.reservedReservationID == candidate.reservationID,
              state.freshnessExpiresAt.map({ now <= $0 }) ?? false,
              controls[candidate.signalID, default: .init()].permits(at: now)
        else { return false }
        return true
    }

    /// Commits a reservation only after macOS accepted the notification.
    /// Failed delivery must remain retryable and must not consume quota.
    mutating func commitDelivery(_ candidate: PostureAlertCandidate, now: TimeInterval) -> Bool {
        guard now.isFinite,
              var state = states[candidate.signalID],
              state.generation == candidate.generation,
              state.contextKey == candidate.contextKey,
              state.reservedEpisodeID == candidate.episodeID,
              state.reservedReservationID == candidate.reservationID else { return false }
        guard state.freshnessExpiresAt.map({ now <= $0 }) ?? false else {
            state.reservedEpisodeID = nil
            state.reservedReservationID = nil
            state.freshnessExpiresAt = nil
            states[candidate.signalID] = state
            return false
        }
        state.reservedEpisodeID = nil
        state.reservedReservationID = nil
        state.retryNotBefore = 0
        state.deliveredEpisodeID = candidate.episodeID
        state.requiresRecovery = true
        state.recoverySince = nil
        state.deliveryTimes.append(now)
        states[candidate.signalID] = state
        globalDeliveries.append(now)
        return true
    }

    /// Releases a failed reservation without marking delivery or consuming a
    /// daily budget. A short backoff avoids a tight retry loop on permission or
    /// transport errors while keeping the episode eligible.
    mutating func releaseDelivery(_ candidate: PostureAlertCandidate, now: TimeInterval) {
        guard var state = states[candidate.signalID],
              state.generation == candidate.generation,
              state.contextKey == candidate.contextKey,
              state.reservedEpisodeID == candidate.episodeID,
              state.reservedReservationID == candidate.reservationID else { return }
        state.reservedEpisodeID = nil
        state.reservedReservationID = nil
        state.retryNotBefore = now + 5
        states[candidate.signalID] = state
    }

    mutating func resetTracking() {
        for id in states.keys {
            states[id]?.clearRuntimeIdentity()
        }
    }

    func deliveryState() -> PostureAlertDeliveryState {
        .init(
            globalDeliveries: globalDeliveries,
            perSignal: Dictionary(uniqueKeysWithValues: states.map {
                ($0.key.rawValue, $0.value.deliveryTimes)
            }),
            requiresRecovery: Dictionary(uniqueKeysWithValues: states.map {
                ($0.key.rawValue, $0.value.requiresRecovery)
            })
        )
    }

    mutating func restoreDeliveryState(
        _ value: PostureAlertDeliveryState,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        guard now.isFinite else { return }
        globalDeliveries = value.globalDeliveries.filter {
            $0.isFinite && $0 >= 0 && $0 <= now && now - $0 <= globalConfiguration.dailyWindow
        }.sorted()
        for (rawID, times) in value.perSignal {
            guard let id = PostureObservationSignalID(rawValue: rawID) else { continue }
            states[id, default: .init()].deliveryTimes = times.filter {
                $0.isFinite && $0 >= 0 && $0 <= now && now - $0 <= globalConfiguration.dailyWindow
            }.sorted()
        }
        for (rawID, requiresRecovery) in value.requiresRecovery where requiresRecovery {
            guard let id = PostureObservationSignalID(rawValue: rawID),
                  PostureObservationSignalID.alertableCases.contains(id) else { continue }
            states[id, default: .init()].requiresRecovery = true
        }
    }

    mutating func setSensitivity(_ value: PostureRecommendationSensitivity) {
        sensitivity = value
        let persistenceScale: Double = switch value {
        case .discreet: 1.5
        case .balanced: 1.0
        case .sensitive: 0.5
        }
        signalConfigurations = baseSignalConfigurations.mapValues { configuration in
            .init(
                persistence: configuration.persistence * persistenceScale,
                recovery: configuration.recovery,
                cooldown: configuration.cooldown,
                dailyMaximum: configuration.dailyMaximum
            )
        }
        resetTracking()
    }

    mutating func setEnabled(_ isEnabled: Bool, for id: PostureObservationSignalID) {
        controls[id, default: .init()].isEnabled = isEnabled
        if !isEnabled { clearRuntime(for: id) }
    }

    mutating func snooze(_ id: PostureObservationSignalID, until: TimeInterval?) {
        controls[id, default: .init()].snoozedUntil = until
        controls[id, default: .init()].isSnoozedUntilReactivation = false
        clearRuntime(for: id)
    }

    mutating func snooze(
        _ id: PostureObservationSignalID,
        choice: PostureSnoozeChoice,
        now: Date,
        calendar: Calendar = .current
    ) {
        switch choice {
        case .oneHour:
            controls[id, default: .init()].snoozedUntil = now.addingTimeInterval(3_600)
                .timeIntervalSince1970
            controls[id, default: .init()].isSnoozedUntilReactivation = false
        case .today:
            controls[id, default: .init()].snoozedUntil = calendar.date(
                byAdding: .day, value: 1, to: calendar.startOfDay(for: now)
            )?.timeIntervalSince1970
            controls[id, default: .init()].isSnoozedUntilReactivation = false
        case .untilReactivation:
            controls[id, default: .init()].snoozedUntil = nil
            controls[id, default: .init()].isSnoozedUntilReactivation = true
        }
        clearRuntime(for: id)
    }

    mutating func reactivate(_ id: PostureObservationSignalID) {
        controls[id, default: .init()] = .init()
        clearRuntime(for: id)
    }

    private mutating func clearRuntime(for id: PostureObservationSignalID) {
        states[id]?.attentionSince = nil
        states[id]?.attentionEpisodeID = nil
        states[id]?.recoverySince = nil
        states[id]?.reservedEpisodeID = nil
        states[id]?.retryNotBefore = 0
        states[id]?.freshnessExpiresAt = nil
    }

    private func updateRecovery(
        _ signal: PostureSignalSnapshot,
        configuration: PostureSignalAlertConfiguration,
        now: TimeInterval,
        state: inout SignalAlertState
    ) {
        guard state.requiresRecovery else { return }
        let recovered = signal.availability == .available &&
            signal.assessment == .withinReference && signal.quality == .good
        guard recovered else { state.recoverySince = nil; return }
        state.recoverySince = state.recoverySince ?? now
        if now - (state.recoverySince ?? now) >= configuration.recovery {
            state.requiresRecovery = false
            state.recoverySince = nil
        }
    }
}

private nonisolated struct SignalAlertState: Sendable {
    var generation: UInt64 = 0
    var contextKey = ""
    var attentionSince: TimeInterval?
    var attentionEpisodeID: UInt64?
    var deliveredEpisodeID: UInt64?
    var requiresRecovery = false
    var recoverySince: TimeInterval?
    var reservedEpisodeID: UInt64?
    var reservedReservationID: UInt64?
    var freshnessExpiresAt: TimeInterval?
    var retryNotBefore: TimeInterval = 0
    var lastScheduledAt: TimeInterval?
    var deliveryTimes: [TimeInterval] = []

    /// Efface uniquement l'épisode lié au runtime courant. Les quotas et
    /// l'obligation de récupération survivent aux arrêts et redémarrages.
    mutating func clearRuntimeIdentity() {
        generation = 0
        contextKey = ""
        attentionSince = nil
        attentionEpisodeID = nil
        deliveredEpisodeID = nil
        recoverySince = nil
        reservedEpisodeID = nil
        reservedReservationID = nil
        freshnessExpiresAt = nil
        retryNotBefore = 0
        lastScheduledAt = nil
    }
}
