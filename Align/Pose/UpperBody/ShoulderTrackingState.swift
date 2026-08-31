import Foundation

/// Product-facing shoulder availability, independent from the active engine.
nonisolated enum ShoulderTrackingState: String, Sendable {
    case detected, partial, lost, technicalError

    var displayName: String {
        switch self {
        case .detected: "Détecté"
        case .partial: "Partiel"
        case .lost: "Perdu"
        case .technicalError: "Erreur"
        }
    }
}
