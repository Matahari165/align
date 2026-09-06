import CoreGraphics
import Foundation

@main
private enum PostureRuntimeCoordinatorHarness {
    static func main() {
        var coordinator = PostureRuntimeCoordinator()
        let context = PostureFramingContext(pixelWidth: 1280, pixelHeight: 720, cameraID: "camera-a")!
        let otherCameraContext = PostureFramingContext(pixelWidth: 1280, pixelHeight: 720, cameraID: "camera-b")!
        precondition(context.stableContextKey != otherCameraContext.stableContextKey,
                     "deux caméras de même format doivent avoir des contextes distincts")
        coordinator.reset(generation: 7, contextKey: context.key)
        let duplicate = coordinator.consume(geometry: nil, face: nil, baseline: nil, now: 1)
        precondition(duplicate == nil, "une entrée sans identité doit rester inactive")
        let descriptor = UpperBodyEngineDescriptor(id: "harness", displayName: "Harness", version: "1", runtime: "test")
        func point(_ id: UpperBodyLandmarkID, _ x: CGFloat, _ y: CGFloat) -> UpperBodyPoint {
            .init(id: id, location: .init(x: x, y: y), confidence: 0.95, quality: .good, provenance: .observed)
        }
        let points: [UpperBodyPoint] = [
            point(.nose, 0.5, 0.2), point(.leftEar, 0.44, 0.22), point(.rightEar, 0.56, 0.22),
            point(.neck, 0.5, 0.36), point(.leftShoulder, 0.35, 0.5), point(.rightShoulder, 0.65, 0.5),
            point(.leftHip, 0.4, 0.8), point(.rightHip, 0.6, 0.8)
        ]
        let preCalibrationBody = UpperBodyResult(descriptor: descriptor, state: .detected, generation: 7,
                                                 sampleID: 1, capturedAt: 1.1, producedAt: 1.11,
                                                 points: points, contours: [])
        let preCalibrationGeometry = PostureRichGeometryEvaluator.make(result: preCalibrationBody, face: nil, context: context)
        let preCalibration = coordinator.consume(geometry: preCalibrationGeometry, face: nil, baseline: nil, now: 1.11)
        precondition(preCalibration?.snapshot.signal(.torsoInclination).quality == .good,
                     "la géométrie universelle doit être exploitable sans clic explicite")
        coordinator.reset(generation: 7, contextKey: context.key)
        coordinator.beginCalibration()
        var lastSnapshot: PostureObservationsSnapshot?
        var firstBodySnapshot: PostureObservationsSnapshot?
        var firstInterleavedFaceSnapshot: PostureObservationsSnapshot?
        for sample in 1...12 {
            let body = UpperBodyResult(descriptor: descriptor, state: .detected, generation: 7,
                                       sampleID: UInt64(sample), capturedAt: 1 + Double(sample) * 0.1,
                                       producedAt: 1.01 + Double(sample) * 0.1,
                                       points: points, contours: [])
            let face = PostureFaceObservation(
                generation: 7, sampleID: UInt64(sample), capturedAt: body.capturedAt,
                facePointCount: 50, contextKey: context.key,
                signal: .init(eyeLineRollDegrees: 0, yawProxy: 0, pitchProxy: 0,
                              interocularDistance: 0.1, faceLength: 0.3,
                              leftEyeOpeningRatio: 0.3, rightEyeOpeningRatio: 0.3,
                              innerBrowDistanceRatio: 0.4, faceCenter: .init(x: 0.5, y: 0.3))
            )
            let geometry = PostureRichGeometryEvaluator.make(result: body, face: face, context: context)
            lastSnapshot = coordinator.consume(geometry: geometry, face: face, baseline: nil, now: body.producedAt)?.snapshot
            if sample == 1 {
                firstBodySnapshot = lastSnapshot
            }
            for tick in 1...3 {
                let faceTick = PostureFaceObservation(
                    generation: 7, sampleID: UInt64(sample * 10 + tick),
                    capturedAt: body.capturedAt + Double(tick) * 0.01,
                    facePointCount: 50, contextKey: context.key, signal: face.signal
                )
                lastSnapshot = coordinator.consume(geometry: geometry, face: faceTick, baseline: nil,
                                                   now: faceTick.capturedAt + 0.01)?.snapshot
                if sample == 1, tick == 1 {
                    firstInterleavedFaceSnapshot = lastSnapshot
                }
            }
        }
        if let firstBodySnapshot, let firstInterleavedFaceSnapshot {
            precondition(
                firstInterleavedFaceSnapshot.signal(.torsoInclination).availability ==
                    firstBodySnapshot.signal(.torsoInclination).availability,
                "un tick visage intercalé ne doit pas réinitialiser l'état corporel"
            )
            precondition(
                firstInterleavedFaceSnapshot.signal(.raisedShoulders).availability ==
                    firstBodySnapshot.signal(.raisedShoulders).availability,
                "un tick visage intercalé ne doit pas réinitialiser les épaules"
            )
        } else {
            preconditionFailure("le scénario intercalé doit publier ses deux snapshots")
        }
        precondition(coordinator.baselineSnapshot?.sampleCount ?? 0 >= 12,
                     "douze corps uniques doivent figer une baseline exploitable")
        precondition(coordinator.finishCalibration(), "la session explicite doit produire une baseline")
        let savedBaseline = coordinator.baselineSnapshot
        precondition(savedBaseline?.blinkOpeningBaseline != nil,
                     "la calibration doit conserver un repère séparé pour les deux yeux")
        var resumed = PostureRuntimeCoordinator()
        resumed.reset(generation: 8, contextKey: context.key)
        if let savedBaseline {
            resumed.restoreBaseline(savedBaseline, for: 8, contextKey: context.key)
            precondition(
                resumed.baselineSnapshot?.blinkOpeningBaseline ==
                    savedBaseline.blinkOpeningBaseline,
                "le repère oculaire gauche/droite doit survivre à la restauration"
            )
        }
        let resumedBody = UpperBodyResult(descriptor: descriptor, state: .detected, generation: 8,
                                          sampleID: 1, capturedAt: 10, producedAt: 10.01,
                                          points: points, contours: [])
        let resumedGeometry = PostureRichGeometryEvaluator.make(result: resumedBody, face: nil, context: context)
        precondition(resumed.consume(geometry: resumedGeometry, face: nil, baseline: nil, now: 10.01)?
            .snapshot.signal(.torsoInclination).quality == .good,
            "une baseline valide doit survivre à une nouvelle activation du même contexte")
        let duplicateBody = UpperBodyResult(descriptor: descriptor, state: .detected, generation: 7,
                                            sampleID: 1, capturedAt: 1, producedAt: 1.01,
                                            points: points, contours: [])
        let duplicateGeometry = PostureRichGeometryEvaluator.make(result: duplicateBody, face: nil, context: context)
        precondition(coordinator.consume(geometry: duplicateGeometry, face: nil, baseline: nil, now: 3) == nil,
                     "un échantillon corps ancien ne doit pas revenir")
        let mismatchedFace = PostureFaceObservation(
            generation: 7, sampleID: 999, capturedAt: 3.1, facePointCount: 50,
            contextKey: "camera-other", signal: faceAfterLossSignal()
        )
        precondition(coordinator.consume(geometry: duplicateGeometry, face: mismatchedFace,
                                         baseline: nil, now: 3.2) == nil,
                     "des contextes visage/corps différents ne doivent jamais être fusionnés")
        coordinator.reset(generation: 8, contextKey: "camera-v2")
        precondition(coordinator.consume(geometry: nil, face: nil, baseline: nil, now: 2) == nil,
                     "un contexte sans source ne doit rien publier")

        // Les cadences source-specifices ne doivent pas se bloquer entre
        // elles, mais aucune preuve d'un autre contexte ne peut entrer dans
        // le coordinateur courant.
        var sourceCoordinator = PostureRuntimeCoordinator()
        sourceCoordinator.reset(generation: 9, contextKey: context.key)
        let bodyA = UpperBodyResult(descriptor: descriptor, state: .detected, generation: 9,
                                    sampleID: 1, capturedAt: 1, producedAt: 1.01,
                                    points: points, contours: [])
        _ = sourceCoordinator.consumeBody(
            PostureRichGeometryEvaluator.make(result: bodyA, face: nil, context: context),
            now: 1.01
        )
        let faceB = PostureFaceObservation(
            generation: 9, sampleID: 1, capturedAt: 1.1, facePointCount: 50,
            contextKey: "camera-other", signal: faceAfterLossSignal()
        )
        precondition(sourceCoordinator.consumeFace(faceB, now: 1.11) == nil,
                     "un tick visage d'un autre contexte doit être rejeté")

        var sourceCalibration = PostureRuntimeCoordinator()
        sourceCalibration.reset(generation: 10, contextKey: context.key)
        sourceCalibration.beginCalibration()
        for sample in 1...12 {
            let body = UpperBodyResult(descriptor: descriptor, state: .detected, generation: 10,
                                       sampleID: UInt64(sample), capturedAt: Double(sample),
                                       producedAt: Double(sample) + 0.01,
                                       points: points, contours: [])
            let geometry = PostureRichGeometryEvaluator.make(result: body, face: nil, context: context)
            _ = sourceCalibration.consumeBody(geometry, now: body.producedAt)
        }
        precondition(!sourceCalibration.finishCalibration(),
                     "une mesure des yeux incomplète ne doit pas être validée par le seul corps")

        var shoulderOnlyCalibration = PostureRuntimeCoordinator()
        shoulderOnlyCalibration.reset(generation: 11, contextKey: context.key)
        shoulderOnlyCalibration.beginCalibration()
        let shoulderOnlyPoints = points.filter { point in
            point.id != .leftHip && point.id != .rightHip
        }
        var shoulderOnlyLastSnapshot: PostureObservationsSnapshot?
        for sample in 1...12 {
            let body = UpperBodyResult(
                descriptor: descriptor, state: .detected, generation: 11,
                sampleID: UInt64(sample), capturedAt: Double(sample),
                producedAt: Double(sample) + 0.01,
                points: shoulderOnlyPoints, contours: []
            )
            let geometry = PostureRichGeometryEvaluator.make(
                result: body, face: nil, context: context
            )
            shoulderOnlyLastSnapshot = shoulderOnlyCalibration.consumeBody(
                geometry, now: body.producedAt
            )?.snapshot
        }
        precondition(!shoulderOnlyCalibration.finishCalibration(),
                     "les épaules seules ne doivent pas fabriquer une référence oculaire")
        precondition(
            shoulderOnlyLastSnapshot?.signal(.shoulderSlope).availability == .available &&
            shoulderOnlyLastSnapshot?.signal(.torsoInclination).availability == .insufficient,
            "la géométrie doit rester disponible indépendamment de la mesure des yeux")

        var faceOnlyCalibration = PostureRuntimeCoordinator()
        faceOnlyCalibration.reset(generation: 13, contextKey: context.key)
        faceOnlyCalibration.beginCalibration()
        var faceOnlyLastSnapshot: PostureObservationsSnapshot?
        for sample in 1...12 {
            let face = PostureFaceObservation(
                generation: 13, sampleID: UInt64(sample), capturedAt: Double(sample),
                facePointCount: 50, contextKey: context.key,
                signal: faceAfterLossSignal()
            )
            faceOnlyLastSnapshot = faceOnlyCalibration.consumeFace(
                face, now: face.capturedAt + 0.01
            )?.snapshot
        }
        precondition(faceOnlyCalibration.finishCalibration(),
                     "le visage doit pouvoir calibrer la proximité indépendamment du corps")
        precondition(
            faceOnlyCalibration.baselineSnapshot?.familySampleCounts?.proximity == 0 &&
            faceOnlyCalibration.baselineSnapshot?.familySampleCounts?.blinkOpening == 12 &&
            faceOnlyCalibration.baselineSnapshot?.proximityScale == nil &&
            faceOnlyLastSnapshot?.signal(.proximity).availability == .available,
            "la mesure visage doit conserver seulement l'ouverture des yeux et laisser la proximité géométrique")

        var slowMixedCalibration = PostureRuntimeCoordinator()
        slowMixedCalibration.reset(generation: 14, contextKey: context.key)
        slowMixedCalibration.beginCalibration()
        var faceSampleID: UInt64 = 1
        for bodyIndex in 0..<16 { // huit secondes de corps à environ 2 Hz
            let intervalStart = Double(bodyIndex) * 0.5
            var latestFace: PostureFaceObservation?
            for tick in 0..<5 { // visage à environ 10 Hz
                let face = PostureFaceObservation(
                    generation: 14, sampleID: faceSampleID,
                    capturedAt: intervalStart + Double(tick) * 0.1,
                    facePointCount: 50, contextKey: context.key,
                    signal: faceAfterLossSignal()
                )
                faceSampleID += 1
                latestFace = face
                _ = slowMixedCalibration.consumeFace(face, now: face.capturedAt + 0.01)
            }
            guard let latestFace else { preconditionFailure("face fixture absent") }
            let body = UpperBodyResult(
                descriptor: descriptor, state: .detected, generation: 14,
                sampleID: UInt64(bodyIndex + 1), capturedAt: intervalStart + 0.45,
                producedAt: intervalStart + 0.46, points: points, contours: []
            )
            let geometry = PostureRichGeometryEvaluator.make(
                result: body, face: latestFace, context: context
            )
            _ = slowMixedCalibration.consumeBody(geometry, now: body.producedAt)
        }
        precondition(slowMixedCalibration.finishCalibration(),
                     "le flux mixte lent doit produire une baseline")
        precondition(
            (slowMixedCalibration.baselineSnapshot?.familySampleCounts?.blinkOpening ?? 0) >= 16 &&
            slowMixedCalibration.baselineSnapshot?.familySampleCounts?.shoulderOpening == 0,
            "la fenêtre visage doit produire la référence oculaire sans réintroduire une posture calibrée")

        var isolatedSources = PostureRuntimeCoordinator()
        isolatedSources.reset(generation: 12, contextKey: context.key)
        if let savedBaseline {
            isolatedSources.restoreBaseline(savedBaseline, for: 12, contextKey: context.key)
        }
        let isolatedFace = PostureFaceObservation(
            generation: 12, sampleID: 1, capturedAt: 20, facePointCount: 50,
            contextKey: context.key, signal: faceAfterLossSignal()
        )
        guard isolatedSources.consumeFace(isolatedFace, now: 20.01) != nil else {
            preconditionFailure("le visage source-specific doit être accepté")
        }
        let isolatedBody = UpperBodyResult(
            descriptor: descriptor, state: .detected, generation: 12,
            sampleID: 1, capturedAt: 20.1, producedAt: 20.11,
            points: points, contours: []
        )
        guard isolatedSources.consumeBody(
            PostureRichGeometryEvaluator.make(
                result: isolatedBody, face: isolatedFace, context: context
            ),
            now: 20.11
        ) != nil else {
            preconditionFailure("le corps source-specific doit être accepté")
        }
        let resetTarget = isolatedSources.resetFaceTarget(at: 20.15)
        precondition(resetTarget.signal(.proximity).availability == .insufficient &&
                     resetTarget.signal(.estimatedBlinks).availability == .insufficient &&
                     resetTarget.signal(.headTilt).availability == .insufficient &&
                     resetTarget.signal(.shoulderSlope).availability == .available,
                     "une nouvelle cible visage invalide ses signaux et conserve les épaules")
        let faceBeforeBodyLoss = resetTarget.signal(.proximity)
        let blinkBeforeBodyLoss = resetTarget.signal(.estimatedBlinks)
        guard let bodyLoss = isolatedSources.invalidateBody(at: 20.2) else {
            preconditionFailure("l'invalidation corps doit publier")
        }
        precondition(bodyLoss.snapshot.signal(.torsoInclination).availability == .insufficient,
                     "noPerson corps doit invalider le torse")
        precondition(bodyLoss.snapshot.signal(.proximity).observedAt == faceBeforeBodyLoss.observedAt,
                     "noPerson corps doit préserver la proximité visage")
        precondition(bodyLoss.snapshot.signal(.estimatedBlinks).observedAt ==
                        blinkBeforeBodyLoss.observedAt,
                     "noPerson corps doit préserver les clignements")
        // A no-person/error invalidation must be a hard barrier: a subsequent
        // 10 Hz face tick cannot resurrect the previous body's torso/shoulder
        // evidence or advance an alertable body signal.
        let cleared = coordinator.invalidate(at: 3)
        precondition(cleared.signal(.torsoInclination).availability == .insufficient,
                     "invalidate doit vider le torse immédiatement")
        precondition(cleared.signal(.raisedShoulders).availability == .insufficient,
                     "invalidate doit vider les épaules immédiatement")
        let faceAfterLoss = PostureFaceObservation(
            generation: 8, sampleID: 900, capturedAt: 3.1,
            facePointCount: 50, contextKey: "camera-v2", signal: .init(
                eyeLineRollDegrees: 0, yawProxy: 0, pitchProxy: 0,
                interocularDistance: 0.1, faceLength: 0.3,
                leftEyeOpeningRatio: 0.3, rightEyeOpeningRatio: 0.3,
                innerBrowDistanceRatio: 0.4, faceCenter: .init(x: 0.5, y: 0.3)))
        let afterLoss = coordinator.consume(geometry: nil, face: faceAfterLoss,
                                            baseline: nil, now: 3.11)
        precondition(afterLoss?.snapshot.signal(.torsoInclination).availability != .available,
                     "un tick visage ne doit pas réinjecter un torse stale")
        precondition(afterLoss?.snapshot.signal(.raisedShoulders).availability != .available,
                     "un tick visage ne doit pas réinjecter des épaules stale")
        precondition(afterLoss?.snapshot.signal(.torsoInclination).assessment == nil,
                     "aucune alerte corporelle après noPerson")
        var alerts = PostureAlertCoordinator(
            signalConfigurations: Dictionary(uniqueKeysWithValues:
                PostureObservationSignalID.allCases.map {
                    ($0, .init(persistence: 1, recovery: 1, cooldown: 1, dailyMaximum: 2))
                }),
            globalConfiguration: .normal
        )
        if let afterLoss {
            precondition(alerts.consume(afterLoss.snapshot, now: 3.2) == nil,
                         "noPerson suivi d’un tick visage ne doit produire aucune alerte")
        }
        var proximityCoordinator = PostureRuntimeCoordinator()
        proximityCoordinator.reset(generation: 20, contextKey: context.key)
        var proximityBeforeAttention: PostureObservationsSnapshot?
        var proximityAttention: PostureObservationsSnapshot?
        for sample in 1...21 {
            let timestamp = Double(sample) * 0.1
            let closeFace = PostureFaceObservation(
                generation: 20, sampleID: UInt64(sample), capturedAt: timestamp,
                facePointCount: 50, contextKey: context.key,
                signal: .init(
                    eyeLineRollDegrees: 0, yawProxy: 0, pitchProxy: 0,
                    interocularDistance: 0.2, faceLength: 0.6,
                    leftEyeOpeningRatio: 0.3, rightEyeOpeningRatio: 0.3,
                    innerBrowDistanceRatio: 0.4, faceCenter: .init(x: 0.5, y: 0.3)
                )
            )
            proximityAttention = proximityCoordinator.consumeFace(
                closeFace, now: timestamp + 0.01
            )?.snapshot
            if sample == 19 { proximityBeforeAttention = proximityAttention }
        }
        precondition(proximityBeforeAttention?.signal(.proximity).assessment != .attention &&
                     proximityAttention?.signal(.proximity).assessment == .attention,
                     "la proximité universelle doit attendre deux secondes une seule fois, sans double temporisation")
        print("PostureRuntimeCoordinatorHarness: OK")
    }

    private static func faceAfterLossSignal() -> FaceGeometrySignal {
        .init(eyeLineRollDegrees: 0, yawProxy: 0, pitchProxy: 0,
              interocularDistance: 0.1, faceLength: 0.3,
              leftEyeOpeningRatio: 0.3, rightEyeOpeningRatio: 0.3,
              innerBrowDistanceRatio: 0.4, faceCenter: .init(x: 0.5, y: 0.3))
    }
}
