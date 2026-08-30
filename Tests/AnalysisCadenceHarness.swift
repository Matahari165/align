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
        expect(CameraCaptureRatePolicy.framesPerSecond(for: [(15, 60)]) == 30,
               "un format compatible doit capturer à 30 fps")
        expect(CameraCaptureRatePolicy.framesPerSecond(for: [(10, 24)]) == 15,
               "un format sans 30 fps doit utiliser le fallback explicite 15 fps")
        expect(CameraCaptureRatePolicy.framesPerSecond(for: [(8, 12)]) == 12,
               "un format atypique doit choisir sa meilleure cadence supportée")
        expect(CameraCaptureRatePolicy.framesPerSecond(for: [(29, 29), (40, 40)]) == 29,
               "un fallback atypique doit rester le plus proche de 30, pas le plus élevé")
        expect(CameraCaptureRatePolicy.framesPerSecond(for: []) == nil,
               "aucune plage ne doit produire une cadence inventée")

        var cadence = AnalysisCadenceController()
        expect(cadence.shouldAnalyze(at: 10), "la première frame doit être analysée")
        expect(!cadence.shouldAnalyze(at: 10.09), "le visage au premier plan ne doit pas dépasser 10 Hz")
        expect(cadence.shouldAnalyze(at: 10.1), "le visage au premier plan doit accepter 10 Hz")

        cadence.updatePresentation(AnalysisPresentationState(
            isApplicationActive: false,
            isWindowMiniaturized: false,
            benchmarkExperiment: nil
        ))
        expect(!cadence.shouldAnalyze(at: 10.59), "l’arrière-plan ne doit pas dépasser 2 Hz")
        expect(cadence.shouldAnalyze(at: 10.6), "l’arrière-plan doit accepter 2 Hz")
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
        expect(cadence.shouldAnalyze(at: 10.8), "le passage du fond au benchmark doit appliquer 5 Hz immédiatement")

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
        expect(approximately(cadence.presentation.faceInterval, 0.1), "le retour au premier plan doit restaurer 10 Hz visage")
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
        let faceRecovers = VisionAnalysisSelector.select([
            VisionAnalysisCandidate(unit: .face, overdue: 0.11, priority: 3),
            VisionAnalysisCandidate(unit: .blazePose, overdue: 0.01, priority: 4)
        ])
        expect(faceRecovers == .face,
               "un visage en retard doit reprendre après l'unité BlazePose")
        var callbackBudget = VisionCallbackBudget()
        callbackBudget.beginCallback()
        expect(callbackBudget.claim(.face), "le callback peut réserver le visage")
        expect(!callbackBudget.claim(.blazePose),
               "un callback visage ne peut jamais lancer BlazePose simultanément")

        var capacityFace = AnalysisCadenceController()
        var capacityBlaze = BlazePoseCadenceController()
        var lastBody: TimeInterval?
        var faceCount = 0
        var blazeCount = 0
        var bodyCount = 0
        for frame in 0..<30 {
            let uptime = Double(frame) / CameraCaptureRatePolicy.targetFramesPerSecond
            var candidates: [VisionAnalysisCandidate] = []
            if capacityFace.isDue(at: uptime) {
                candidates.append(.init(unit: .face,
                                        overdue: capacityFace.overdue(at: uptime), priority: 3))
            }
            if capacityBlaze.isDue(at: uptime) {
                candidates.append(.init(unit: .blazePose,
                                        overdue: capacityBlaze.overdue(at: uptime), priority: 4))
            }
            if lastBody.map({ uptime - $0 + 0.000_001 >= 0.5 }) ?? true {
                let overdue = lastBody.map { max(0, uptime - $0 - 0.5) } ?? 0
                candidates.append(.init(unit: .body, overdue: overdue, priority: 2))
            }
            switch VisionAnalysisSelector.select(candidates) {
            case .face:
                capacityFace.recordAnalysis(at: uptime)
                faceCount += 1
            case .blazePose:
                capacityBlaze.recordAttempt(at: uptime)
                blazeCount += 1
            case .body:
                lastBody = uptime
                bodyCount += 1
            default:
                break
            }
        }
        expect(faceCount == 10,
               "30 callbacks/s doivent réellement laisser 10 unités visage distinctes")
        expect(blazeCount == 2,
               "la même seconde doit conserver BlazePose à 2 unités sans le confondre avec le visage")
        expect(bodyCount == 2,
               "la même seconde doit aussi laisser deux unités corps distinctes")

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
