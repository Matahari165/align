import Foundation

// Commande macOS exacte depuis la racine Align/Align :
// env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk -module-cache-path /tmp/align-module-cache -o /tmp/person-segmentation-harness Align/Pose/PoseDetector.swift Align/Pose/PersonSegmentationDetector.swift Align/Pose/HumanRectangleDetector.swift Align/Pose/FaceOrientation.swift Align/Pose/FaceGeometrySignal.swift Align/Camera/AnalysisCadencePolicy.swift Align/Pose/PoseResultStabilizer.swift Align/Benchmark/BenchmarkSession.swift Tests/PersonSegmentationHarness.swift && /tmp/person-segmentation-harness

@main
private enum PersonSegmentationHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let blazePoseLeft = CGPoint(x: 0.2, y: 0.35)
        let blazePoseOverlay = VisionCoordinateMapper.poseOverlayPoint(
            fromBlazePoseTopLeftPoint: blazePoseLeft
        )
        let blazePosePreview = VisionCoordinateMapper.previewDevicePoint(
            fromPoseOverlayPoint: blazePoseOverlay
        )
        expect(blazePoseOverlay.x == 0.2,
               "BlazePose ne doit pas recevoir un second miroir horizontal")
        expect(abs(blazePosePreview.y - 0.65) < 0.000_001,
               "BlazePose top-left doit subir une seule conversion verticale Preview")
        let leftShoulder = PosePoint(name: "Épaule gauche",
                                     location: CGPoint(x: 0.18, y: 0.42),
                                     confidence: 0.8, source: .blazePose)
        let rightShoulder = PosePoint(name: "Épaule droite",
                                      location: CGPoint(x: 0.76, y: 0.55),
                                      confidence: 0.9, source: .blazePose)
        let partial = BlazePoseOverlayBuilder.make(
            nose: nil, leftEar: nil, rightEar: nil,
            leftShoulder: leftShoulder, rightShoulder: nil,
            leftElbow: nil, rightElbow: nil, leftHip: nil, rightHip: nil
        )
        expect(partial.points.count == 1 && partial.polylines.isEmpty,
               "un point partiel doit rester visible sans ligne inventée")
        let asymmetric = BlazePoseOverlayBuilder.make(
            nose: nil, leftEar: nil, rightEar: nil,
            leftShoulder: leftShoulder, rightShoulder: rightShoulder,
            leftElbow: nil, rightElbow: nil, leftHip: nil, rightHip: nil
        )
        let shoulderLine = asymmetric.polylines.first { $0.name == "ligne-épaules" }
        expect(shoulderLine?.locations == [leftShoulder.location, rightShoulder.location],
               "la paire asymétrique gauche/droite doit conserver ordre et coordonnées")
        let raisedRight = PosePoint(name: "Épaule droite",
                                    location: CGPoint(x: 0.30, y: 0.80),
                                    confidence: 0.9, source: .blazePose)
        let raised = BlazePoseOverlayBuilder.make(
            nose: nil, leftEar: nil, rightEar: nil,
            leftShoulder: leftShoulder, rightShoulder: raisedRight,
            leftElbow: nil, rightElbow: nil, leftHip: nil, rightHip: nil
        )
        expect(raised.polylines.count == 1,
               "une vraie asymétrie verticale supérieure à 45 degrés doit rester valide")
        let incoherentRight = PosePoint(name: "Épaule droite",
                                        location: CGPoint(x: 0.181, y: 0.421),
                                        confidence: 0.9, source: .blazePose)
        let incoherent = BlazePoseOverlayBuilder.make(
            nose: nil, leftEar: nil, rightEar: nil,
            leftShoulder: leftShoulder, rightShoulder: incoherentRight,
            leftElbow: nil, rightElbow: nil, leftHip: nil, rightHip: nil
        )
        expect(incoherent.points.count == 2 && incoherent.polylines.isEmpty,
               "une paire incohérente conserve les points réels mais ne crée aucune ligne")
        expect(BlazePoseShoulderPairValidator.isCoherent(
            left: CGPoint(x: 0.30, y: 0.30), right: CGPoint(x: 0.50, y: 0.498)
        ), "une pente 0,99 doit être mesurable")
        expect(BlazePoseShoulderPairValidator.isCoherent(
            left: CGPoint(x: 0.30, y: 0.30), right: CGPoint(x: 0.50, y: 0.502)
        ), "une pente 1,01 doit également préserver une vraie épaule levée")
        expect(BlazePoseShoulderPairValidator.isCoherent(
            left: CGPoint(x: 0.05, y: 0.50), right: CGPoint(x: 0.95, y: 0.50)
        ), "un span exactement 0,90 reste mesurable")
        let beyondSpanLeft = PosePoint(name: "Épaule gauche",
                                       location: CGPoint(x: 0.045, y: 0.50),
                                       confidence: 0.9, source: .blazePose)
        let beyondSpanRight = PosePoint(name: "Épaule droite",
                                        location: CGPoint(x: 0.955, y: 0.50),
                                        confidence: 0.9, source: .blazePose)
        let beyondSpan = BlazePoseOverlayBuilder.make(
            nose: nil, leftEar: nil, rightEar: nil,
            leftShoulder: beyondSpanLeft, rightShoulder: beyondSpanRight,
            leftElbow: nil, rightElbow: nil, leftHip: nil, rightHip: nil
        )
        expect(beyondSpan.points.count == 2 && beyondSpan.polylines.isEmpty,
               "span 0,91 : points détectés conservés, mesure de paire indisponible")

        let width = 100
        let height = 100
        let anchor = PersonSegmentationFaceAnchor(
            jawPoint: CGPoint(x: 0.50, y: 0.30),
            bounds: CGRect(x: 0.40, y: 0.10, width: 0.20, height: 0.15)
        )
        let derivedAnchor = PersonSegmentationFaceAnchor(faceContour: [
            CGPoint(x: 0.42, y: 0.12), CGPoint(x: 0.58, y: 0.14),
            CGPoint(x: 0.55, y: 0.30), CGPoint(x: 0.45, y: 0.28)
        ])
        expect(derivedAnchor?.jawPoint.y == 0.30, "l'ancre doit venir du côté mâchoire inférieur")
        expect((derivedAnchor?.jawPoint.y ?? 0) > (derivedAnchor?.bounds.maxY ?? 1) - 0.001, "la mâchoire dérivée doit être le y maximum")

        // Chaîne réelle : helper PoseDetector → ancre masque → extracteur →
        // contrat PoseOverlay → conversion Preview, avec un visage asymétrique.
        let faceBounds = CGRect(x: 0.31, y: 0.20, width: 0.38, height: 0.30)
        let asymmetricLandmarks = [
            CGPoint(x: 0.20, y: 0.90), CGPoint(x: 0.78, y: 0.84),
            CGPoint(x: 0.66, y: 0.08), CGPoint(x: 0.36, y: 0.14)
        ]
        let faceOverlayContour = asymmetricLandmarks.map {
            VisionCoordinateMapper.faceLandmarkCapturePoint(
                from: $0,
                boundingBox: faceBounds,
                orientation: .up
            )
        }
        let realFaceAnchor = PersonSegmentationFaceAnchor(faceOverlayContour: faceOverlayContour)
        expect(realFaceAnchor != nil, "l'ancre doit être dérivée du contour réel PoseDetector")
        expect(
            abs((realFaceAnchor?.jawPoint.y ?? 0) - 0.776) < 0.000_001,
            "la mâchoire réelle doit rester sur le côté bas après conversion explicite"
        )
        var chainedMask = [UInt8](repeating: 0, count: 160 * 200)
        for y in 100..<190 {
            let left = 42 - (y - 100) / 4
            let right = 108 + (y - 100) / 3
            for x in left...right { chainedMask[y * 160 + x] = 255 }
        }
        let chainedContour = realFaceAnchor.flatMap {
            extract(chainedMask, width: 160, height: 200, anchor: $0)
        }
        expect(chainedContour != nil, "le masque bas doit produire un contour après l'ancre réelle")
        if let chainedContour,
           let topLeftUpper = chainedContour.left.locations.first,
           let topLeftLower = chainedContour.left.locations.last {
            let overlayLower = VisionCoordinateMapper.poseOverlayPoint(
                fromSegmentationTopLeftPoint: topLeftLower
            )
            let previewUpper = VisionCoordinateMapper.previewDevicePoint(
                fromPoseOverlayPoint: VisionCoordinateMapper.poseOverlayPoint(
                    fromSegmentationTopLeftPoint: topLeftUpper
                )
            )
            let previewLower = VisionCoordinateMapper.previewDevicePoint(
                fromPoseOverlayPoint: overlayLower
            )
            expect(topLeftLower.y > topLeftUpper.y, "le bas du masque doit rester plus bas en top-left")
            expect(previewLower.y > previewUpper.y, "la conversion Preview doit préserver l'ordre visuel haut/bas")
            expect(
                abs(previewLower.y - topLeftLower.y) < 0.000_001,
                "la chaîne réelle doit restituer le point bas dans la Preview"
            )
        } else {
            expect(false, "la chaîne réelle doit publier deux côtés")
        }

        var clean = [UInt8](repeating: 0, count: width * height)
        for y in 32..<50 {
            let left = 35 - (y - 32) / 3
            let right = 65 + (y - 32) * 2
            for x in left...right { clean[y * width + x] = 255 }
        }
        for y in 50..<80 {
            for x in 29...78 { clean[y * width + x] = 255 }
        }
        let cleanContour = extract(clean, width: width, height: height, anchor: anchor)
        expect(cleanContour != nil, "un masque continu doit produire un contour")
        expect(
            (cleanContour?.left.locations.count ?? 0) >= 32
                && (cleanContour?.left.locations.count ?? 0) <= 64,
            "chaque polyligne doit rester compacte entre 32 et 64 points"
        )
        expect((cleanContour?.coverage ?? 0) >= 0.60, "la couverture minimale doit être respectée")
        expect(cleanContour?.jawAnchor.y == anchor.jawPoint.y, "l'ancre mâchoire doit rester dans le contrat masque")
        expect((cleanContour?.jawAnchor.y ?? 0) > anchor.bounds.maxY, "la mâchoire doit être sous la boîte faciale")
        if let lowerLeft = cleanContour?.left.locations.last,
           let lowerRight = cleanContour?.right.locations.last {
            expect(lowerLeft.y > 0.5 && lowerRight.y > 0.5, "un point bas du masque doit rester bas")
            let leftCapture = VisionCoordinateMapper.captureDevicePoint(fromTopLeftNormalized: lowerLeft)
            let rightCapture = VisionCoordinateMapper.captureDevicePoint(fromTopLeftNormalized: lowerRight)
            expect(leftCapture.y < 0.5 && rightCapture.y < 0.5, "la conversion preview doit inverser uniquement l'axe y")
            expect(
                VisionCoordinateMapper.topLeftNormalizedPoint(fromCaptureDevicePoint: leftCapture).y == lowerLeft.y
                    && VisionCoordinateMapper.topLeftNormalizedPoint(fromCaptureDevicePoint: rightCapture).y == lowerRight.y,
                "la chaîne masque → overlay → preview doit être réversible"
            )
            expect(lowerRight.x > lowerLeft.x, "les bords asymétriques doivent rester du bon côté")
        } else {
            expect(false, "les deux polylignes doivent être disponibles")
        }

        var noisy = clean
        for y in stride(from: 35, to: 66, by: 7) {
            for x in 40...42 { noisy[y * width + x] = 0 }
            for x in 15...18 { noisy[y * width + x] = 255 }
        }
        expect(
            extract(noisy, width: width, height: height, anchor: anchor) != nil,
            "des trous et une composante secondaire ne doivent pas invalider le contour principal"
        )

        var truncated = [UInt8](repeating: 0, count: width * height)
        for y in 32..<41 {
            for x in 30...70 { truncated[y * width + x] = 255 }
        }
        expect(
            extract(truncated, width: width, height: height, anchor: anchor) == nil,
            "un tronc trop court doit rester indisponible"
        )

        var jumping = clean
        for y in 50..<51 {
            for x in 30...70 { jumping[y * width + x] = 0 }
            for x in 50...90 { jumping[y * width + x] = 255 }
        }
        expect(
            extract(jumping, width: width, height: height, anchor: anchor) == nil,
            "un saut de bord supérieur à 8 pour cent doit invalider le contour"
        )

        var cadence = SilhouetteCadenceController()
        expect(
            !cadence.shouldRun(at: 10, presentation: .foreground),
            "la segmentation ne doit jamais être demandée hors benchmark"
        )
        let benchmarkPresentation = AnalysisPresentationState(
            isApplicationActive: true,
            isWindowMiniaturized: false,
            benchmarkExperiment: .silhouette
        )
        expect(
            cadence.shouldRun(at: 10, presentation: benchmarkPresentation),
            "la première tentative benchmark doit être immédiate"
        )
        expect(
            !cadence.shouldRun(at: 10.99, presentation: benchmarkPresentation),
            "la cadence silhouette doit rester à 1 Hz"
        )
        expect(
            cadence.shouldRun(at: 11, presentation: benchmarkPresentation),
            "une tentative doit être permise après une seconde"
        )
        expect(
            !cadence.shouldRun(
                at: 12,
                presentation: AnalysisPresentationState(
                    isApplicationActive: false,
                    isWindowMiniaturized: false,
                    benchmarkExperiment: nil
                )
            ),
            "la segmentation doit être inactive en arrière-plan"
        )
        cadence.reset()
        expect(
            !cadence.shouldRun(at: 20, presentation: .foreground),
            "reset hors benchmark doit rester désactivé"
        )
        expect(
            cadence.shouldRun(at: 20, presentation: benchmarkPresentation),
            "reset benchmark doit autoriser une nouvelle première tentative"
        )

        let lifecycleDetector = PersonSegmentationDetector()
        expect(!lifecycleDetector.isActive, "la segmentation doit commencer désactivée")
        lifecycleDetector.activate()
        expect(lifecycleDetector.isActive, "l'activation doit créer la requête stateful")
        lifecycleDetector.deactivate()
        expect(!lifecycleDetector.isActive, "la sortie du benchmark doit libérer la requête stateful")

        var segmentationEpoch = BenchmarkSegmentationEpoch()
        let oldToken = segmentationEpoch.begin()
        expect(segmentationEpoch.accepts(oldToken, benchmarkRunning: true), "le token courant doit autoriser le benchmark")
        segmentationEpoch.invalidate()
        expect(!segmentationEpoch.accepts(oldToken, benchmarkRunning: false), "un arrêt doit invalider immédiatement le token")
        let newToken = segmentationEpoch.begin()
        expect(newToken != oldToken, "une nouvelle session doit recevoir un token distinct")
        expect(!segmentationEpoch.accepts(oldToken, benchmarkRunning: true), "un résultat ancien doit rester inerte après reprise")
        expect(segmentationEpoch.accepts(newToken, benchmarkRunning: true), "seul le token courant doit être accepté")

        let cancellationBox = BenchmarkSegmentationCancellationBox()
        cancellationBox.activate(newToken)
        let tokenCapturedBeforeWork = newToken
        expect(cancellationBox.accepts(tokenCapturedBeforeWork), "le travail doit commencer avec un token actif")
        cancellationBox.invalidate() // simule stop pendant le perform synchrone
        expect(
            !cancellationBox.accepts(tokenCapturedBeforeWork),
            "le post-check doit refuser un résultat invalidé pendant le travail"
        )

        let invalidateWins = BenchmarkSegmentationCancellationBox()
        invalidateWins.activate(newToken)
        let invalidateFirstFinished = DispatchSemaphore(value: 0)
        let rejectedCommitFinished = DispatchSemaphore(value: 0)
        var rejectedCommitCount = 0
        DispatchQueue(label: "align.test.invalidate-first").async {
            invalidateWins.invalidate()
            invalidateFirstFinished.signal()
        }
        DispatchQueue(label: "align.test.commit-after-invalidate").async {
            invalidateFirstFinished.wait()
            _ = invalidateWins.withAcceptedToken(newToken) {
                rejectedCommitCount += 1
            }
            rejectedCommitFinished.signal()
        }
        expect(rejectedCommitFinished.wait(timeout: .now() + 1) == .success, "le commit refusé doit terminer")
        expect(rejectedCommitCount == 0, "invalidate gagnant doit empêcher tout commit")

        let commitWins = BenchmarkSegmentationCancellationBox()
        commitWins.activate(newToken)
        let commitEntered = DispatchSemaphore(value: 0)
        let allowCommitToFinish = DispatchSemaphore(value: 0)
        let commitFinished = DispatchSemaphore(value: 0)
        let invalidationStarted = DispatchSemaphore(value: 0)
        let invalidationFinished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "align.test.commit").async {
            _ = commitWins.withAcceptedToken(newToken) {
                commitEntered.signal()
                allowCommitToFinish.wait()
            }
            commitFinished.signal()
        }
        expect(commitEntered.wait(timeout: .now() + 1) == .success, "le commit concurrent doit prendre le verrou")
        DispatchQueue(label: "align.test.invalidate").async {
            invalidationStarted.signal()
            commitWins.invalidate()
            invalidationFinished.signal()
        }
        expect(invalidationStarted.wait(timeout: .now() + 1) == .success, "l'invalidation concurrente doit démarrer")
        expect(invalidationFinished.wait(timeout: .now() + 0.05) == .timedOut, "invalidate doit attendre le commit commencé")
        allowCommitToFinish.signal()
        expect(commitFinished.wait(timeout: .now() + 1) == .success, "le commit doit pouvoir finir")
        expect(invalidationFinished.wait(timeout: .now() + 1) == .success, "invalidate doit retourner après la fin du commit")
        expect(!commitWins.accepts(newToken), "le token doit être invalide au retour d'invalidate")

        var budget = VisionCallbackBudget()
        budget.beginCallback()
        expect(budget.claim(.face), "un callback doit pouvoir réserver une unité Vision")
        expect(!budget.claim(.body), "un callback ne doit jamais réserver deux unités Vision")
        budget.beginCallback()
        expect(budget.claim(.silhouette), "le budget doit être réutilisable au callback suivant")

        expect(
            VisionAnalysisSelector.select([
                VisionAnalysisCandidate(unit: .face, overdue: 1, priority: 3),
                VisionAnalysisCandidate(unit: .body, overdue: 1, priority: 2),
                VisionAnalysisCandidate(unit: .silhouette, overdue: 1, priority: 1)
            ]) == .face,
            "si les trois unités sont dues, le visage doit passer en premier"
        )
        expect(
            VisionAnalysisSelector.select([
                VisionAnalysisCandidate(unit: .body, overdue: 1, priority: 2),
                VisionAnalysisCandidate(unit: .silhouette, overdue: 1, priority: 1)
            ]) == .body,
            "après le visage, le corps doit passer au callback suivant"
        )
        expect(
            VisionAnalysisSelector.select([
                VisionAnalysisCandidate(unit: .silhouette, overdue: 1, priority: 1)
            ]) == .silhouette,
            "la silhouette doit rester une unité distincte au callback suivant"
        )

        var freshness = SilhouetteOverlayFreshnessTracker()
        freshness.reset(generation: 7)
        freshness.recordObservation(at: 30, generation: 7)
        expect(!freshness.shouldExpire(at: 30.29, generation: 7), "un contour reste frais pendant 0,30 s")
        expect(
            freshness.shouldExpire(at: 30.30, generation: 7),
            "un contour doit disparaître après 0,30 s"
        )
        expect(
            !freshness.shouldExpire(at: 31.5, generation: 8),
            "une ancienne génération ne doit jamais expirer la nouvelle"
        )

        var phaseMetrics = BenchmarkPhaseMetrics()
        phaseMetrics.record(BenchmarkMeasurement(
            faceAttempted: true,
            faceDuration: 0,
            faceSucceeded: true,
            faceHadLandmarks: true,
            faceOrientation: nil,
            bodyDuration: nil,
            bodyAttempted: false,
            bodySucceeded: false,
            overlayVisible: true,
            faceVisible: true
        ))
        phaseMetrics.record(BenchmarkMeasurement(
            faceAttempted: false,
            faceDuration: 0,
            faceSucceeded: false,
            faceHadLandmarks: false,
            faceOrientation: nil,
            bodyDuration: 0.01,
            bodyAttempted: true,
            bodySucceeded: true,
            overlayVisible: false,
            bodyVisible: true
        ))
        expect(phaseMetrics.samples == 2, "la phase doit compter toutes les mesures")
        expect(phaseMetrics.visibleOverlays == 1, "la visibilité fusionnée doit compter toutes les mesures")
        expect(
            phaseMetrics.report(for: BenchmarkPhase(instruction: "test", duration: 1, expectation: .faceVisible), index: 0).contains("50.0 %"),
            "la visibilité fusionnée doit être divisée par les mesures globales"
        )

        print("PersonSegmentationHarness: OK")
    }

    private static func extract(
        _ pixels: [UInt8],
        width: Int,
        height: Int,
        anchor: PersonSegmentationFaceAnchor
    ) -> PersonSilhouetteContour? {
        pixels.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            return PersonSilhouetteExtractor.extract(
                baseAddress: baseAddress,
                width: width,
                height: height,
                bytesPerRow: width,
                faceAnchor: anchor
            )
        }
    }
}
