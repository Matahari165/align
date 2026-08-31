import Foundation

/// Variante de modèle immuable pour toute la durée de vie d'un moteur.
/// Un bundle A/B choisit sa variante dans Info.plist avant l'activation caméra.
nonisolated enum BlazePoseModelVariant: String, Sendable {
    case lite
    case full

    static func configured(from value: String?) -> BlazePoseModelVariant? {
        guard let value else { return .lite }
        return BlazePoseModelVariant(rawValue: value.lowercased())
    }

    static var bundleConfigured: BlazePoseModelVariant? {
        configured(from: Bundle.main.object(forInfoDictionaryKey: "BlazePoseModelVariant") as? String)
    }

    var detectorResourceName: String {
        switch self {
        case .lite: "pose_detector"
        case .full: "pose_detector_full"
        }
    }

    var landmarksResourceName: String {
        switch self {
        case .lite: "pose_landmarks_detector"
        case .full: "pose_landmarks_detector_full"
        }
    }
}
