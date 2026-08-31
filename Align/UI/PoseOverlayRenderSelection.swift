import Foundation

nonisolated enum PoseOverlayRenderSelection {
    static let shoulderPointNames = Set(["Épaule gauche", "Épaule droite"])

    static func select(_ overlay: PoseOverlay, diagnosticsEnabled: Bool) -> PoseOverlay {
        if diagnosticsEnabled {
            let developmentSources: Set<PosePointSource> = [
                .upperBodyHead, .upperBodyShoulders, .upperBodyTorso,
                .upperBodyDerived, .upperBodyROI
            ]
            return PoseOverlay(
                points: overlay.points.filter { developmentSources.contains($0.source) },
                polylines: overlay.polylines.filter { developmentSources.contains($0.source) }
            )
        }
        return PoseOverlay(
            points: overlay.points.filter {
                ($0.source == .upperBodyShoulders || $0.source == .blazePose) &&
                    shoulderPointNames.contains($0.name)
            },
            polylines: overlay.polylines.filter {
                ($0.source == .upperBodyShoulders || $0.source == .blazePose) &&
                    $0.name == "ligne-épaules"
            }
        )
    }
}
