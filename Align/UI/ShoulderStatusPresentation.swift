import Foundation

nonisolated struct ShoulderStatusPresentation: Equatable, Sendable {
    let title: String
    let explanation: String
    let symbolName: String

    static func make(for state: ShoulderTrackingState?) -> Self {
        guard let state else {
            return Self(
                title: "Recherche des épaules",
                explanation: "Place le haut du corps face à la caméra.",
                symbolName: "viewfinder"
            )
        }
        return make(for: state)
    }

    static func make(for state: ShoulderTrackingState) -> Self {
        switch state {
        case .detected:
            Self(
                title: "Épaules détectées",
                explanation: "Les deux épaules sont suivies localement.",
                symbolName: "viewfinder.circle.fill"
            )
        case .partial:
            Self(
                title: "Épaules partiellement détectées",
                explanation: "Une seule épaule est détectée. Ajuste ta position face à la caméra.",
                symbolName: "viewfinder"
            )
        case .lost:
            Self(
                title: "Épaules non détectées",
                explanation: "Aucune épaule n’est détectée. Place le haut du corps face à la caméra.",
                symbolName: "viewfinder"
            )
        case .technicalError:
            Self(
                title: "Erreur d’analyse",
                explanation: "L’analyse des épaules a rencontré un problème. Align réessaie automatiquement.",
                symbolName: "exclamationmark.triangle.fill"
            )
        }
    }
}
