import Foundation

@main
private enum PostureSignalPipelineHarness {
    static func main() {
        precondition(PostureIndicatorsSnapshot.initial.indicators.count == 8,
                     "le contrat de présentation contient huit observations")
        precondition(PostureIndicatorsSnapshot.initial.indicators.allSatisfy {
            $0.state == .unavailable && $0.observedAt == nil
        }, "l'état initial ne doit inventer aucune preuve")
        precondition(PostureIndicatorContract.calibrationDuration == 8,
                     "la durée produit de calibration reste explicite")
        precondition(PostureIndicatorID.allCases == [
            .apparentProximity, .torsoInclination, .raisedShoulders,
            .shoulderSlope, .estimatedBlinks, .closedShoulders, .headTilt,
            .handOnFace
        ], "le DTO remplace l'ancien pipeline évaluateur sans chemin legacy actif")
        print("PostureSignalPipelineHarness: OK")
    }
}
