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
        expect(CameraCaptureRatePolicy.framesPerSecond(for: [(15, 60)]) == 20,
               "un format compatible doit capturer à 20 fps")
        expect(CameraCaptureRatePolicy.framesPerSecond(for: [(10, 24)]) == 20,
               "un format compatible avec 20 fps doit conserver la cadence cible")
        expect(CameraCaptureRatePolicy.framesPerSecond(for: [(10, 15)]) == 15,
               "un format sans 20 fps doit utiliser le fallback explicite à 15 fps")
        expect(CameraCaptureRatePolicy.framesPerSecond(for: [(8, 12)]) == 12,
               "un format atypique doit choisir sa meilleure cadence sous la cible")
        expect(CameraCaptureRatePolicy.framesPerSecond(for: [(29, 29), (40, 40)]) == 29,
               "un fallback atypique doit rester le plus proche de 20, pas le plus élevé")
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
        expect(!cadence.shouldAnalyze(at: 10.19), "le visage en arrière-plan ne doit pas dépasser 10 Hz")
        expect(cadence.shouldAnalyze(at: 10.2), "le visage en arrière-plan doit conserver 10 Hz")
        expect(!cadence.presentation.publishesVisualUpdates, "le rendu fréquent doit être coupé en arrière-plan")
        var calibrationCadence = UpperBodyCadenceController()
        var calibrationSamples = 0
        for frame in 0..<240 {
            let time = 20 + Double(frame) / 30
            let interval = cadence.presentation.upperBodyInterval(isCalibrating: true)
            if calibrationCadence.isDue(at: time, interval: interval) {
                calibrationCadence.recordAttempt(at: time)
                calibrationSamples += 1
            }
        }
        expect(calibrationSamples >= 12,
               "huit secondes de calibration doivent fournir douze corps même en arrière-plan")
        expect(cadence.presentation.upperBodyInterval(isCalibrating: false) == 1,
               "la fin de calibration doit restaurer la cadence corporelle économique")


        cadence.updatePresentation(AnalysisPresentationState(
            isApplicationActive: true,
            isWindowMiniaturized: true,
            benchmarkExperiment: nil
        ))
        expect(approximately(cadence.presentation.faceInterval, 0.1), "une fenêtre réduite doit conserver 10 Hz visage")

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
        expect(!silhouetteBenchmark.runsNormalUpperBodyEngine,
               "le benchmark silhouette doit posséder seul le budget upperBody")
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
        expect(!cadence.presentation.runsNormalUpperBodyEngine,
               "le benchmark ROI doit suspendre le moteur upperBody produit")
        expect(!AnalysisPresentationState.foreground.runsNormalBodyAnalysis,
               "Vision Body doit rester hors du suivi normal")
        expect(AnalysisPresentationState.foreground.runsNormalUpperBodyEngine,
               "hors benchmark, exactement un moteur upperBody doit être actif")

        cadence.updatePresentation(.foreground)
        expect(approximately(cadence.presentation.faceInterval, 0.1), "le retour au premier plan doit restaurer 10 Hz visage")
        cadence.reset()
        expect(cadence.shouldAnalyze(at: 20), "la reprise après pause doit accepter la première frame")

        var upperBodyCadence = UpperBodyCadenceController()
        expect(upperBodyCadence.isDue(at: 30, interval: 0.5), "upperBody doit accepter la première frame")
        upperBodyCadence.recordAttempt(at: 30)
        expect(!upperBodyCadence.isDue(at: 30.49, interval: 0.5), "upperBody ne doit pas dépasser 2 Hz visible")
        expect(upperBodyCadence.isDue(at: 30.5, interval: 0.5), "upperBody doit reprendre à 2 Hz visible")
        expect(!upperBodyCadence.isDue(at: 30.99, interval: 1), "upperBody arrière-plan doit rester à 1 Hz")
        let selected = VisionAnalysisSelector.select([
            VisionAnalysisCandidate(unit: .face, overdue: 0.02, priority: 3),
            VisionAnalysisCandidate(unit: .upperBody, overdue: 0.2, priority: 4)
        ])
        expect(selected == .upperBody, "upperBody en retard ne doit pas être affamé par le visage")
        let faceRecovers = VisionAnalysisSelector.select([
            VisionAnalysisCandidate(unit: .face, overdue: 0.11, priority: 3),
            VisionAnalysisCandidate(unit: .upperBody, overdue: 0.01, priority: 4)
        ])
        expect(faceRecovers == .face,
               "un visage en retard doit reprendre après l'unité BlazePose")
        var callbackBudget = VisionCallbackBudget()
        callbackBudget.beginCallback()
        expect(callbackBudget.claim(.face), "le callback peut réserver le visage")
        expect(!callbackBudget.claim(.upperBody),
               "un callback visage ne peut jamais lancer upperBody simultanément")

        var livenessGate = FrameLivenessGate()
        expect(livenessGate.claim(), "la première frame doit pouvoir réconcilier la liveness")
        expect(!livenessGate.claim(), "les frames suivantes ne doivent pas créer de tâche MainActor")
        livenessGate.reset()
        expect(livenessGate.claim(), "une nouvelle activation doit réarmer la liveness")

        var capacityFace = AnalysisCadenceController()
        var capacityUpperBody = UpperBodyCadenceController()
        var faceCount = 0
        var blazeCount = 0
        for frame in 0..<40 {
            let uptime = Double(frame) / CameraCaptureRatePolicy.targetFramesPerSecond
            var candidates: [VisionAnalysisCandidate] = []
            if capacityFace.isDue(at: uptime) {
                candidates.append(.init(unit: .face,
                                        overdue: capacityFace.overdue(at: uptime), priority: 3))
            }
            if capacityUpperBody.isDue(at: uptime, interval: 1.0) {
                candidates.append(.init(unit: .upperBody,
                                        overdue: capacityUpperBody.overdue(at: uptime, interval: 1.0), priority: 4))
            }
            switch VisionAnalysisSelector.select(candidates) {
            case .face:
                capacityFace.recordAnalysis(at: uptime)
                faceCount += 1
            case .upperBody:
                capacityUpperBody.recordAttempt(at: uptime)
                blazeCount += 1
            default:
                break
            }
        }
        expect(faceCount == 20,
               "20 callbacks/s doivent réellement laisser 10 unités visage par seconde")
        expect(blazeCount == 2,
               "deux secondes doivent conserver upperBody à 1 unité par seconde en arrière-plan")
        print("AnalysisCadenceHarness: OK")
    }
}
