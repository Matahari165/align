import Foundation

nonisolated enum UpperBodyModelMode: String, CaseIterable, Identifiable, Sendable {
    case precise
    case nativeCoreML
    case compressedCoreML
    case lightweight
    case appleVision

    static let defaultsKey = "UpperBodyModelMode"

    static var availableCases: [Self] { allCases.filter(\.isAvailable) }

    var isAvailable: Bool {
        let resource: String
        switch self {
        case .nativeCoreML: resource = "rtmpose-m-halpe26-native-fp32"
        case .compressedCoreML: resource = "rtmpose-m-halpe26-native-int8"
        default: return true
        }
        return ["Pose/RTMPose/Models", "RTMPose/Models", nil].contains { folder in
            Bundle.main.url(forResource: resource, withExtension: "mlmodelc", subdirectory: folder) != nil ||
                Bundle.main.url(forResource: resource, withExtension: "mlpackage", subdirectory: folder) != nil
        }
    }

    var id: Self { self }

    var displayName: String {
        switch self {
        case .precise: "Précis"
        case .nativeCoreML: "Core ML"
        case .compressedCoreML: "Core ML allégé"
        case .lightweight: "Léger"
        case .appleVision: "Apple Vision"
        }
    }

    var explanation: String {
        switch self {
        case .precise:
            "RTMPose privilégie la fiabilité des épaules, avec une consommation plus élevée."
        case .nativeCoreML:
            "Même RTMPose exécuté directement par Core ML, sans moteur ONNX actif. Mode expérimental."
        case .compressedCoreML:
            "Même RTMPose avec des poids compressés sur 8 bits, calculés en précision normale. Qualité à comparer."
        case .lightweight:
            "BlazePose Lite réduit la charge, mais peut perdre plus souvent les épaules."
        case .appleVision:
            "Apple Vision remplace le modèle du corps. La précision des épaules doit être comparée en conditions réelles."
        }
    }

    static func stored(defaults: UserDefaults = .standard) -> Self {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let stored = Self(rawValue: rawValue), stored.isAvailable else { return .precise }
        return stored
    }

    func store(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
