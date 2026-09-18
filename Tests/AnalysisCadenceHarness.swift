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
        let formatCandidates = [
            CameraFormatCandidate(index: 0, width: 1920, height: 1080, supportsTwentyFPS: true),
            CameraFormatCandidate(index: 1, width: 1280, height: 720, supportsTwentyFPS: true),
            CameraFormatCandidate(index: 2, width: 960, height: 540, supportsTwentyFPS: true),
            CameraFormatCandidate(index: 3, width: 640, height: 480, supportsTwentyFPS: true)
        ]
        expect(CameraResolutionPolicy.preferredIndex(in: formatCandidates) == 2,
               "la caméra doit préférer exactement 960×540 à 20 fps")
        expect(CameraResolutionPolicy.preferredIndex(in: Array(formatCandidates.dropFirst(3))) == 3,
               "640×480 doit être le repli compact lorsqu'il est le seul format sous la cible")
        expect(CameraResolutionPolicy.preferredIndex(in: [
            CameraFormatCandidate(index: 7, width: 960, height: 540, supportsTwentyFPS: false),
            CameraFormatCandidate(index: 8, width: 1280, height: 720, supportsTwentyFPS: true)
        ]) == 8, "la résolution ne doit jamais sacrifier les 20 fps")
        let compactWide = CompactBodyFramePolicy.dimensions(sourceWidth: 960, sourceHeight: 540)
        expect(compactWide?.width == 640 && compactWide?.height == 360,
               "le corps doit recevoir une copie 640×360 du format 16:9")
        let compactFourThree = CompactBodyFramePolicy.dimensions(sourceWidth: 640, sourceHeight: 480)
        expect(compactFourThree?.width == 480 && compactFourThree?.height == 360,
               "la copie compacte ne doit jamais déformer un format 4:3")

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

        var faceCadence = AdaptiveFaceCadenceController()
        expect(faceCadence.interval(at: 1, isCalibrating: false) == 0.1,
               "sans référence oculaire, le visage doit rester en mode sécurisé")
        faceCadence.observeEyeProbe(isReliable: true, detectedMotion: false, at: 1)
        expect(approximately(faceCadence.interval(at: 1.1, isCalibrating: false), 1.0 / 3.0),
               "une référence stable doit autoriser le suivi facial à 3 Hz")
        faceCadence.observeEyeProbe(isReliable: true, detectedMotion: true, at: 2)
        expect(faceCadence.interval(at: 2.5, isCalibrating: false) == 0.1,
               "un mouvement des yeux doit restaurer immédiatement les 10 Hz")
        expect(approximately(faceCadence.interval(at: 3.1, isCalibrating: false), 1.0 / 3.0),
               "le mode économique doit revenir après la rafale de sécurité")


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

        var handCadence = HandAnalysisCadenceController()
        expect(handCadence.shouldAnalyze(at: 20), "les mains doivent accepter la première frame")
        expect(!handCadence.shouldAnalyze(at: 20.99), "les mains au repos ne doivent pas dépasser 1 Hz")
        expect(handCadence.shouldAnalyze(at: 21), "les mains au repos doivent reprendre à 1 Hz")
        handCadence.recordResult(hasHands: true, at: 21)
        expect(!handCadence.shouldAnalyze(at: 21.49), "une main visible ne doit pas dépasser 2 Hz")
        expect(handCadence.shouldAnalyze(at: 21.5), "une main visible doit temporairement reprendre à 2 Hz")
        for halfSecond in 44...51 {
            expect(handCadence.shouldAnalyze(at: Double(halfSecond) / 2),
                   "la cadence active doit rester à 2 Hz pendant cinq secondes")
        }
        expect(!handCadence.shouldAnalyze(at: 26), "la cadence active doit expirer après cinq secondes")
        expect(handCadence.shouldAnalyze(at: 26.5), "les mains doivent revenir à 1 Hz après la phase active")

        var faceAcquisition = FaceAcquisitionCadenceController()
        let knownFace = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)
        expect(faceAcquisition.preferredFaceBounds(at: 30, latestBounds: knownFace) == nil,
               "la première analyse du visage doit chercher dans toute l'image")
        expect(faceAcquisition.preferredFaceBounds(at: 30.1, latestBounds: knownFace) == knownFace,
               "les landmarks intermédiaires doivent réutiliser le visage accepté")
        expect(faceAcquisition.preferredFaceBounds(at: 30.5, latestBounds: knownFace) == nil,
               "une recherche complète doit être répétée à 2 Hz")
        faceAcquisition.requireFullDetection()
        expect(faceAcquisition.preferredFaceBounds(at: 30.6, latestBounds: knownFace) == nil,
               "une perte doit réarmer immédiatement la recherche complète")

        var adaptiveBody = AdaptiveUpperBodyCadenceController()
        expect(approximately(adaptiveBody.interval(at: 0, isCalibrating: false), 5),
               "un corps immobile doit utiliser le contrôle toutes les 5 secondes")
        adaptiveBody.observeFace(
            bounds: CGRect(x: 0.40, y: 0.30, width: 0.20, height: 0.30),
            at: 1
        )
        expect(approximately(adaptiveBody.interval(at: 2, isCalibrating: false), 5),
               "le premier visage fiable ne doit pas simuler un mouvement")
        for step in 1...8 {
            let jitter = step.isMultiple(of: 2) ? 0.003 : -0.003
            adaptiveBody.observeFace(
                bounds: CGRect(x: 0.40 + jitter, y: 0.30, width: 0.20, height: 0.30),
                at: 2 + Double(step) * 0.1
            )
        }
        expect(approximately(adaptiveBody.interval(at: 3, isCalibrating: false), 5),
               "le bruit normal du rectangle visage ne doit pas réveiller le corps")
        expect(approximately(adaptiveBody.interval(at: 12, isCalibrating: false), 5),
               "l'analyse corporelle doit ralentir après le mouvement")
        adaptiveBody.observeFace(
            bounds: CGRect(x: 0.44, y: 0.30, width: 0.20, height: 0.30),
            at: 13
        )
        expect(approximately(adaptiveBody.interval(at: 13.1, isCalibrating: false), 5),
               "une seule variation ne doit pas réveiller le corps")
        adaptiveBody.observeFace(
            bounds: CGRect(x: 0.44, y: 0.30, width: 0.20, height: 0.30),
            at: 13.1
        )
        expect(approximately(adaptiveBody.interval(at: 14, isCalibrating: false), 1),
               "un mouvement confirmé doit réveiller le corps")

        var upperBodyCadence = UpperBodyCadenceController()
        expect(upperBodyCadence.isDue(at: 30, interval: 1), "upperBody doit accepter la première frame")
        upperBodyCadence.recordAttempt(at: 30)
        expect(!upperBodyCadence.isDue(at: 30.99, interval: 1), "upperBody ne doit pas dépasser 1 Hz")
        expect(upperBodyCadence.isDue(at: 31, interval: 1), "upperBody doit reprendre à 1 Hz")
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
