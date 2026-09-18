import Foundation

nonisolated enum UpperBodyModelMode: String, CaseIterable, Identifiable, Sendable {
    case precise
    case lightweight

    static let defaultsKey = "UpperBodyModelMode"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .precise: "Précis"
        case .lightweight: "Léger"
        }
    }

    var explanation: String {
        switch self {
        case .precise:
            "RTMPose privilégie la fiabilité des épaules, avec une consommation plus élevée."
        case .lightweight:
            "BlazePose Lite réduit la charge, mais peut perdre plus souvent les épaules."
        }
    }

    static func stored(defaults: UserDefaults = .standard) -> Self {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let stored = Self(rawValue: rawValue) else { return .precise }
        return stored
    }

    func store(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
