import CoreGraphics
import Foundation

@main
private enum FaceTargetContinuityHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FaceTargetContinuityHarness: FAIL — \(message)\n", stderr)
            exit(1)
        }
    }

    static func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> FaceBoxCandidate {
        guard let candidate = FaceBoxCandidate(
            boundingBox: CGRect(x: x, y: y, width: width, height: height)
        ) else {
            fatalError("fixture rectangle invalide")
        }
        return candidate
    }

    static func detectionCandidate(
        _ candidate: FaceBoxCandidate,
        label: String
    ) -> FaceDetectionCandidate {
        FaceDetectionCandidate(
            boundingBox: candidate.boundingBox,
            polylines: [PosePolyline(
                name: label,
                locations: [CGPoint(x: candidate.boundingBox.midX, y: candidate.boundingBox.midY)],
                source: .face,
                isClosed: false
            )],
            orientation: FaceOrientationSignal(
                rollRadians: nil,
                yawRadians: nil,
                pitchRadians: nil
            )
        )
    }

    static func main() {
        let initial = box(0.40, 0.35, 0.20, 0.25)
        let shifted = box(0.42, 0.36, 0.20, 0.25)

        var tracker = FaceTargetContinuity()
        expect(tracker.ingestFullDetection([], at: 0).reason == .noFace,
               "aucune boîte doit être indisponible")
        expect(tracker.target == nil, "aucune boîte ne doit créer une cible")

        let first = tracker.ingestFullDetection([initial], at: 0.1)
        expect(first.candidate == initial && tracker.target == initial,
               "une seule boîte doit être sélectionnée initialement")
        let initialEpoch = tracker.targetEpoch
        expect(initialEpoch > 0, "une cible sélectionnée doit avoir un epoch de continuité")

        let association = tracker.ingestFullDetection([shifted], at: 0.2)
        expect(association.candidate == shifted,
               "un déplacement spatial modeste doit conserver la cible")
        if case .selected(_, let match) = association {
            expect(match?.intersectionOverUnion ?? 0 > 0.60,
                   "l'association doit exposer un recouvrement élevé")
            expect(match?.centerDistance ?? 1 < 0.05,
                   "l'association doit exposer la distance de centre")
            expect(match?.sizeSimilarity ?? 0 > 0.99,
                   "l'association doit exposer la stabilité de taille")
        } else {
            expect(false, "l'association doit être selected")
        }

        var ambiguousInitial = FaceTargetContinuity()
        let ambiguous = ambiguousInitial.ingestFullDetection([
            initial, box(0.72, 0.35, 0.20, 0.25)
        ], at: 0)
        expect(ambiguous == .ambiguous && ambiguousInitial.target == nil,
               "plusieurs visages sans cible doivent rester ambigus")
        expect(ambiguousInitial.ingestFullDetection([initial], at: 0.1).reason == .rearmRequired,
               "une personne seule ne doit pas remplacer silencieusement une cible ambiguë")
        ambiguousInitial.rearm()
        let reacquired = ambiguousInitial.ingestFullDetection([initial], at: 0.2)
        expect(reacquired.candidate == initial,
               "une réacquisition explicite peut sélectionner une nouvelle cible")

        let nearOne = box(0.398, 0.35, 0.20, 0.25)
        let nearTwo = box(0.402, 0.35, 0.20, 0.25)
        let ambiguousAssociation = ambiguousInitial.ingestFullDetection(
            [nearOne, nearTwo], at: 0.3
        )
        expect(ambiguousAssociation == .ambiguous && ambiguousInitial.target == nil,
               "deux associations proches doivent suspendre la cible, sans bascule")

        var noSwitch = FaceTargetContinuity()
        _ = noSwitch.ingestFullDetection([initial], at: 1)
        let farCandidate = box(0.72, 0.35, 0.20, 0.25)
        let lost = noSwitch.ingestFullDetection([farCandidate], at: 1.1)
        expect(lost.reason == .targetLost && lost.candidate == nil && noSwitch.target == nil,
               "un candidat éloigné ne doit pas remplacer la cible")
        expect(noSwitch.ingestFullDetection([farCandidate], at: 1.2).reason == .rearmRequired,
               "la perte d'une cible interdit une réacquisition silencieuse")
        noSwitch.rearm()
        expect(noSwitch.ingestFullDetection([farCandidate], at: 1.3).candidate == farCandidate,
               "la réacquisition explicite autorise une nouvelle personne")

        var sizeGuard = FaceTargetContinuity()
        _ = sizeGuard.ingestFullDetection([initial], at: 2)
        let resized = box(0.30, 0.225, 0.40, 0.50)
        let resizedDecision = sizeGuard.ingestFullDetection([resized], at: 2.1)
        expect(resizedDecision.reason == .targetLost && sizeGuard.target == nil,
               "un changement de taille excessif doit invalider l'association")

        var tracked = FaceTargetContinuity()
        _ = tracked.ingestFullDetection([initial], at: 3)
        let trackedDecision = tracked.ingestTrackedBox(shifted, at: 3.1)
        expect(trackedDecision.candidate == shifted,
               "une boîte de tracker doit suivre uniquement la cible amorcée")
        let jump = tracked.ingestTrackedBox(farCandidate, at: 3.2)
        expect(jump.reason == .trackingJump && tracked.target == nil,
               "un saut du tracker doit invalider la cible")

        var transientLoss = FaceTargetContinuity()
        _ = transientLoss.ingestFullDetection([initial], at: 3.5)
        let transientEpoch = transientLoss.targetEpoch
        expect(transientLoss.ingestFullDetection([], at: 3.6).reason == .targetLost,
               "une frame sans visage suspend la cible")
        let recovered = transientLoss.ingestFullDetection([shifted], at: 3.7)
        expect(recovered.candidate == shifted && !transientLoss.requiresExplicitRearm &&
               transientLoss.targetEpoch == transientEpoch,
               "le même visage spatialement cohérent peut revenir dans le gap borné")

        var expiredLoss = FaceTargetContinuity()
        _ = expiredLoss.ingestFullDetection([initial], at: 3.5)
        _ = expiredLoss.ingestFullDetection([], at: 3.6)
        expect(expiredLoss.ingestFullDetection([shifted], at: 4.2).reason == .rearmRequired,
               "une réapparition tardive exige un réarmement explicite")

        var stableLongLoss = FaceTargetContinuity()
        _ = stableLongLoss.ingestFullDetection([initial], at: 7)
        let oldEpoch = stableLongLoss.targetEpoch
        _ = stableLongLoss.ingestFullDetection([], at: 7.1)
        expect(stableLongLoss.targetEpoch == oldEpoch && stableLongLoss.target == nil,
               "une perte seule doit conserver l'epoch et invalider la cible précédente")
        expect(stableLongLoss.ingestFullDetection([shifted], at: 8.0).reason == .rearmRequired &&
               stableLongLoss.reacquisitionFrameCount == 1,
               "une réapparition longue doit commencer une fenêtre de stabilité")
        expect(stableLongLoss.ingestFullDetection([shifted], at: 8.4).reason == .rearmRequired &&
               stableLongLoss.reacquisitionFrameCount == 2,
               "deux détections ne doivent pas encore réarmer le visage")
        _ = stableLongLoss.ingestFullDetection([shifted], at: 8.8)
        let stableReacquired = stableLongLoss.ingestFullDetection([shifted], at: 9.1)
        expect(stableReacquired.candidate == shifted && stableLongLoss.target == shifted &&
               stableLongLoss.targetEpoch != oldEpoch,
               "une cible unique stable pendant plusieurs frames doit être réacquise dans un nouvel epoch")

        var jumpDuringReacquisition = FaceTargetContinuity()
        _ = jumpDuringReacquisition.ingestFullDetection([initial], at: 9)
        _ = jumpDuringReacquisition.ingestFullDetection([], at: 9.1)
        _ = jumpDuringReacquisition.ingestFullDetection([shifted], at: 10)
        let jumpReset = jumpDuringReacquisition.ingestFullDetection([farCandidate], at: 10.2)
        expect(jumpReset.reason == .trackingJump &&
               jumpDuringReacquisition.reacquisitionFrameCount == 0,
               "un saut pendant la stabilité doit remettre la fenêtre à zéro")

        var gap = FaceTargetContinuity()
        _ = gap.ingestFullDetection([initial], at: 4)
        let gapDecision = gap.ingestTrackedBox(shifted, at: 4.6)
        expect(gapDecision.reason == .trackingGap && gap.target == nil,
               "un gap supérieur au seuil doit réinitialiser le suivi")

        var miss = FaceTargetContinuity()
        _ = miss.ingestFullDetection([initial], at: 5)
        let missDecision = miss.ingestTrackingMiss(at: 5.1)
        expect(missDecision.reason == .trackingJump && miss.target == nil,
               "une perte de tracking doit vider la cible")
        expect(miss.ingestTrackedBox(shifted, at: 5.2).reason == .rearmRequired,
               "un tracker ne peut pas repartir sans réarmement explicite")

        var ordering = FaceTargetContinuity()
        _ = ordering.ingestFullDetection([initial], at: 6)
        let old = ordering.ingestTrackedBox(shifted, at: 5.9)
        expect(old.reason == .outOfOrder && ordering.target == initial,
               "une frame ancienne ne doit pas réécrire la cible")

        expect(FaceBoxCandidate(boundingBox: CGRect(x: -0.1, y: 0, width: 0.2, height: 0.2)) == nil,
               "une boîte hors image doit être refusée")
        expect(FaceBoxCandidate(boundingBox: CGRect(x: 0, y: 0, width: .nan, height: 0.2)) == nil,
               "une boîte non finie doit être refusée")

        let firstCandidate = detectionCandidate(initial, label: "person-one")
        let secondCandidate = detectionCandidate(farCandidate, label: "person-two")
        let output = FaceDetectionOutput(
            polylines: firstCandidate.polylines,
            primaryOrientation: firstCandidate.orientation,
            resultCount: 2,
            facesWithLandmarksCount: 2,
            primaryBoundingBox: initial.boundingBox,
            detectedBoundingBoxes: [initial.boundingBox, farCandidate.boundingBox],
            candidates: [firstCandidate, secondCandidate]
        )
        let selectedOutput = output.resolved(to: farCandidate)
        expect(selectedOutput?.polylines.first?.name == "person-two",
               "la boîte sélectionnée doit publier ses propres landmarks")
        let duplicateOutput = FaceDetectionOutput(
            polylines: firstCandidate.polylines,
            primaryOrientation: firstCandidate.orientation,
            resultCount: 2,
            facesWithLandmarksCount: 2,
            primaryBoundingBox: initial.boundingBox,
            detectedBoundingBoxes: [initial.boundingBox, initial.boundingBox],
            candidates: [firstCandidate, firstCandidate]
        )
        expect(duplicateOutput.resolved(to: initial) == nil,
               "une correspondance de boîte non unique doit rester indisponible")

        print("FaceTargetContinuityHarness: OK")
    }
}
