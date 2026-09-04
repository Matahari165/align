import Foundation

@main
private enum PostureSignalPipelineHarness {
    static func main() {
        precondition(PostureIndicatorsSnapshot.initial.indicators.count == 6,
                     "le contrat de présentation contient six observations")
        precondition(PostureIndicatorsSnapshot.initial.indicators.allSatisfy {
            $0.state == .unavailable && $0.observedAt == nil
        }, "l'état initial ne doit inventer aucune preuve")
        precondition(PostureIndicatorContract.calibrationDuration == 8,
                     "la durée produit de calibration reste explicite")
        precondition(PostureIndicatorID.allCases == [
            .apparentProximity, .torsoInclination, .raisedShoulders,
            .shoulderSlope, .estimatedBlinks, .closedShoulders
        ], "le DTO remplace l'ancien pipeline évaluateur sans chemin legacy actif")
        print("PostureSignalPipelineHarness: OK")
    }
}
