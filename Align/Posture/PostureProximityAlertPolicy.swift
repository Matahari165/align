import Foundation

nonisolated enum PostureProximityAlertDelivery: Equatable, Sendable {
    case none, foregroundBanner, backgroundNotification
}

nonisolated struct PostureProximityAlertConfiguration: Equatable, Sendable {
    var persistenceDuration: TimeInterval = 45
    var cooldown: TimeInterval = 30 * 60
    var globalWindow: TimeInterval = 24 * 60 * 60
    var maximumDeliveries = 3

    var isValid: Bool {
        persistenceDuration.isFinite && persistenceDuration >= 45 &&
            cooldown.isFinite && cooldown >= 30 * 60 && globalWindow.isFinite &&
            globalWindow > cooldown && maximumDeliveries > 0
    }
}

/// Politique pure. Elle ne reçoit qu'un état relatif déjà calibré et qualifié;
/// elle ne connaît ni image, ni coordonnées, ni distance physique.
nonisolated struct PostureProximityAlertPolicy: Sendable {
    let configuration: PostureProximityAlertConfiguration
    private(set) var attentionSince: TimeInterval?
    private(set) var deliveries: [TimeInterval]
    private var retryNotBefore: TimeInterval?
    private var requiresRecovery = false

    init(
        configuration: PostureProximityAlertConfiguration = .init(),
        restoredDeliveries: [TimeInterval] = []
    ) {
        self.configuration = configuration
        deliveries = restoredDeliveries.filter(\.isFinite).sorted()
    }

    mutating func consume(
        isProbablyTooClose: Bool,
        isEligible: Bool,
        isForeground: Bool,
        now: TimeInterval
    ) -> PostureProximityAlertDelivery {
        guard configuration.isValid, now.isFinite else { return .none }
        prune(at: now)
        guard isEligible else {
            attentionSince = nil
            return .none
        }
        guard isProbablyTooClose else {
            attentionSince = nil
            retryNotBefore = nil
            requiresRecovery = false
            return .none
        }
        guard !requiresRecovery else { return .none }
        if attentionSince == nil { attentionSince = now }
        guard let attentionSince,
              now >= attentionSince,
              now - attentionSince >= configuration.persistenceDuration,
              retryNotBefore.map({ now >= $0 }) ?? true,
              deliveries.count < configuration.maximumDeliveries,
              deliveries.last.map({ now - $0 >= configuration.cooldown }) ?? true else {
            return .none
        }
        deliveries.append(now)
        retryNotBefore = nil
        self.attentionSince = nil
        requiresRecovery = true
        return isForeground ? .foregroundBanner : .backgroundNotification
    }

    mutating func resetTracking() { attentionSince = nil }

    mutating func rollbackDelivery(at timestamp: TimeInterval) {
        if deliveries.last == timestamp {
            deliveries.removeLast()
            attentionSince = timestamp - configuration.persistenceDuration
            retryNotBefore = timestamp + 60
            requiresRecovery = false
        }
    }

    private mutating func prune(at now: TimeInterval) {
        deliveries.removeAll { now < $0 || now - $0 > configuration.globalWindow }
    }
}

nonisolated struct PostureProximityAlertHistoryStore {
    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = "posture.proximityAlert.deliveries.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [TimeInterval] { defaults.array(forKey: key) as? [TimeInterval] ?? [] }
    func save(_ values: [TimeInterval]) { defaults.set(values, forKey: key) }
}
