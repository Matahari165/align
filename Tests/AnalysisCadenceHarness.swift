import Foundation

@main
private enum AnalysisCadenceHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func approximately(_ lhs: TimeInterval, _ rhs: TimeInterval) -> Bool {
        abs(lhs - rhs) < 0.000_001
    }

    static func main() {
        var cadence = AnalysisCadenceController()
        expect(cadence.shouldAnalyze(at: 10), "la première frame doit être analysée")
        expect(!cadence.shouldAnalyze(at: 10.19), "le premier plan ne doit pas dépasser 5 Hz")
        expect(cadence.shouldAnalyze(at: 10.2), "le premier plan doit accepter 5 Hz")

        cadence.updatePresentation(AnalysisPresentationState(
            isApplicationActive: false,
            isWindowMiniaturized: false,
            benchmarkExperiment: nil
        ))
        expect(!cadence.shouldAnalyze(at: 10.69), "l’arrière-plan ne doit pas dépasser 2 Hz")
        expect(cadence.shouldAnalyze(at: 10.7), "l’arrière-plan doit accepter 2 Hz")
        expect(!cadence.presentation.publishesVisualUpdates, "le rendu fréquent doit être coupé en arrière-plan")

        cadence.updatePresentation(AnalysisPresentationState(
            isApplicationActive: true,
            isWindowMiniaturized: true,
            benchmarkExperiment: nil
        ))
        expect(approximately(cadence.presentation.faceInterval, 0.5), "une fenêtre réduite doit utiliser 2 Hz")

        cadence.updatePresentation(AnalysisPresentationState(
            isApplicationActive: false,
            isWindowMiniaturized: true,
            benchmarkExperiment: .upperBodyROI
        ))
        expect(approximately(cadence.presentation.faceInterval, 0.2), "le benchmark doit rester à 5 Hz")
        expect(cadence.presentation.publishesVisualUpdates, "le benchmark doit conserver ses mesures visuelles")
        expect(cadence.presentation.runsUpperBodyROIExperiment, "le benchmark UI doit sélectionner le spike ROI")
        expect(!cadence.presentation.runsSilhouetteExperiment, "le spike ROI ne doit jamais activer la silhouette")
        expect(BenchmarkVisionExperiment.upperBodyROI.enables(.upperBodyROISpike), "le scheduler ROI doit autoriser son unité")
        expect(!BenchmarkVisionExperiment.upperBodyROI.enables(.silhouette), "le scheduler ROI doit exclure toute segmentation")
        expect(cadence.shouldAnalyze(at: 10.9), "le passage du fond au benchmark doit appliquer 5 Hz immédiatement")

        let silhouetteBenchmark = AnalysisPresentationState(
            isApplicationActive: true,
            isWindowMiniaturized: false,
            benchmarkExperiment: .silhouette
        )
        expect(silhouetteBenchmark.runsSilhouetteExperiment, "le mode silhouette doit rester disponible explicitement")
        expect(!silhouetteBenchmark.runsUpperBodyROIExperiment, "le mode silhouette ne doit pas activer le spike ROI")
        expect(silhouetteBenchmark.runsNormalBodyAnalysis, "le benchmark silhouette doit conserver l'analyse corporelle normale")
        expect(BenchmarkVisionExperiment.silhouette.enables(.silhouette), "la capacité segmentation doit rester testable")
        expect(!BenchmarkVisionExperiment.silhouette.enables(.upperBodyROISpike), "la segmentation doit exclure le spike ROI")
        expect(
            BenchmarkVisionCandidatePolicy.units(for: .upperBodyROI) == [.upperBodyROISpike],
            "le scheduler ROI doit exposer uniquement le spike ROI"
        )
        expect(
            BenchmarkVisionCandidatePolicy.units(for: .silhouette) == [.silhouette],
            "le scheduler silhouette doit exposer uniquement la segmentation"
        )
        expect(
            BenchmarkVisionCandidatePolicy.units(for: nil).isEmpty,
            "hors benchmark, aucune expérience coûteuse ne doit être candidate"
        )
        expect(!cadence.presentation.runsNormalBodyAnalysis, "le benchmark ROI doit remplacer l'analyse corporelle normale")
        expect(AnalysisPresentationState.foreground.runsNormalBodyAnalysis, "le suivi normal doit conserver l'analyse corporelle")

        cadence.updatePresentation(.foreground)
        expect(approximately(cadence.presentation.faceInterval, 0.2), "le retour au premier plan doit restaurer 5 Hz")
        cadence.reset()
        expect(cadence.shouldAnalyze(at: 20), "la reprise après pause doit accepter la première frame")

        var blazeCadence = BlazePoseCadenceController()
        expect(blazeCadence.isDue(at: 30), "BlazePose doit accepter la première frame")
        blazeCadence.recordAttempt(at: 30)
        expect(!blazeCadence.isDue(at: 30.49), "BlazePose ne doit pas dépasser 2 Hz")
        expect(blazeCadence.isDue(at: 30.5), "BlazePose doit reprendre à 2 Hz")
        let selected = VisionAnalysisSelector.select([
            VisionAnalysisCandidate(unit: .face, overdue: 0.02, priority: 3),
            VisionAnalysisCandidate(unit: .blazePose, overdue: 0.2, priority: 4)
        ])
        expect(selected == .blazePose, "une épaule en retard ne doit pas être affamée par le visage")

        var freshness = BlazePoseOverlayFreshness()
        freshness.record(at: 40, generation: 7)
        expect(!freshness.shouldExpire(at: 41.19, generation: 7), "l’overlay frais doit survivre aux misses courts")
        expect(freshness.shouldExpire(at: 41.2, generation: 7), "l’overlay doit expirer à 1,2 s")
        expect(!freshness.shouldExpire(at: 50, generation: 8), "une ancienne génération ne doit pas expirer la nouvelle")
        freshness.clear()
        expect(!freshness.shouldExpire(at: 50, generation: 7), "un reset doit purger la fraîcheur")

        print("AnalysisCadenceHarness: OK")
    }
}
