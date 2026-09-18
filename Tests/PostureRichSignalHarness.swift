import CoreGraphics
import Foundation

@main
private enum PostureRichSignalHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("PostureRichSignalHarness: FAIL — \(message)\n", stderr)
            exit(1)
        }
    }

    static func point(_ id: UpperBodyLandmarkID, _ x: CGFloat, _ y: CGFloat,
                      quality: UpperBodyPointQuality = .good,
                      confidence: Float = 0.9) -> UpperBodyPoint {
        UpperBodyPoint(id: id, location: CGPoint(x: x, y: y), confidence: confidence,
                       quality: quality, provenance: .observed)
    }

    static func face(
        generation: UInt64 = 1,
        sampleID: UInt64 = 1,
        timestamp: TimeInterval = 0,
        contextKey: String,
        faceScaleMultiplier: Double = 1,
        eyeOpeningRatio: Double = 0.30,
        yawProxy: Double? = 0,
        eyeLineRollDegrees: Double? = 0,
        facePointCount: Int = 50
    ) -> PostureFaceObservation {
        PostureFaceObservation(
            generation: generation, sampleID: sampleID, capturedAt: timestamp,
            facePointCount: facePointCount, contextKey: contextKey,
            signal: FaceGeometrySignal(
                eyeLineRollDegrees: eyeLineRollDegrees, yawProxy: yawProxy, pitchProxy: 0,
                interocularDistance: 0.10 * faceScaleMultiplier,
                faceLength: 0.30 * faceScaleMultiplier,
                leftEyeOpeningRatio: eyeOpeningRatio, rightEyeOpeningRatio: eyeOpeningRatio,
                innerBrowDistanceRatio: 0.40, faceCenter: CGPoint(x: 0.5, y: 0.3)
            )
        )
    }

    static func rotatedFaceFromPolylines(
        generation: UInt64 = 1,
        sampleID: UInt64 = 1,
        timestamp: TimeInterval = 0,
        context: PostureFramingContext,
        cameraRollDegrees: CGFloat
    ) -> PostureFaceObservation {
        let center = CGPoint(x: 0.5, y: 0.38)
        let leftEye = [
            CGPoint(x: 0.422, y: 0.300), CGPoint(x: 0.458, y: 0.300),
            CGPoint(x: 0.458, y: 0.312), CGPoint(x: 0.422, y: 0.312)
        ]
        let rightEye = [
            CGPoint(x: 0.542, y: 0.300), CGPoint(x: 0.578, y: 0.300),
            CGPoint(x: 0.578, y: 0.312), CGPoint(x: 0.542, y: 0.312)
        ]
        let contour = (0..<40).map { index in
            let angle = 2 * CGFloat.pi * CGFloat(index) / 40
            return CGPoint(x: center.x + 0.15 * cos(angle),
                           y: center.y + 0.22 * sin(angle))
        }
        let basePolylines = [
            PosePolyline(name: "leftEye", locations: leftEye, source: .face, isClosed: true),
            PosePolyline(name: "rightEye", locations: rightEye, source: .face, isClosed: true),
            PosePolyline(name: "nose", locations: [CGPoint(x: 0.5, y: 0.38)], source: .face, isClosed: false),
            PosePolyline(name: "medianLine", locations: [CGPoint(x: 0.5, y: 0.22), CGPoint(x: 0.5, y: 0.50)], source: .face, isClosed: false),
            PosePolyline(name: "leftEyebrow", locations: [CGPoint(x: 0.42, y: 0.27), CGPoint(x: 0.46, y: 0.27)], source: .face, isClosed: false),
            PosePolyline(name: "rightEyebrow", locations: [CGPoint(x: 0.54, y: 0.27), CGPoint(x: 0.58, y: 0.27)], source: .face, isClosed: false),
            PosePolyline(name: "faceContour", locations: contour, source: .face, isClosed: true)
        ]
        let radians = Double(cameraRollDegrees) * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        func rotate(_ point: CGPoint) -> CGPoint {
            let pixelX = Double(point.x) * Double(context.pixelWidth)
            let pixelY = Double(point.y) * Double(context.pixelHeight)
            let centerX = Double(center.x) * Double(context.pixelWidth)
            let centerY = Double(center.y) * Double(context.pixelHeight)
            let dx = pixelX - centerX
            let dy = pixelY - centerY
            return CGPoint(
                x: (dx * cosine - dy * sine + centerX) / Double(context.pixelWidth),
                y: (dx * sine + dy * cosine + centerY) / Double(context.pixelHeight)
            )
        }
        let polylines = basePolylines.map { polyline in
            PosePolyline(name: polyline.name, locations: polyline.locations.map(rotate),
                         source: polyline.source, isClosed: polyline.isClosed)
        }
        let signal = FaceGeometrySignal.from(polylines: polylines)!
        return PostureFaceObservation(
            generation: generation, sampleID: sampleID, capturedAt: timestamp,
            facePointCount: polylines.reduce(0) { $0 + $1.locations.count },
            contextKey: context.key, signal: signal
        )
    }

    static func result(
        generation: UInt64 = 1,
        sampleID: UInt64 = 1,
        timestamp: TimeInterval = 0,
        hipOffset: CGFloat = 0,
        shoulderDeltaY: CGFloat = 0,
        leftShoulderDeltaY: CGFloat? = nil,
        rightShoulderDeltaY: CGFloat? = nil,
        shoulderSpanX: CGFloat = 0.30,
        shoulderConfidence: Float = 0.9,
        includeLeftShoulder: Bool = true,
        includeRightShoulder: Bool = true,
        includeHips: Bool = true,
        includeNeck: Bool = true,
        limitedShoulders: Bool = false,
        cameraRollDegrees: CGFloat = 0,
        cameraRollPixelWidth: CGFloat = 1600,
        cameraRollPixelHeight: CGFloat = 900,
        regionOfInterest: UpperBodyRegionOfInterest? = nil
    ) -> UpperBodyResult {
        let descriptor = UpperBodyEngineDescriptor(
            id: "harness", displayName: "Harness", version: "1", runtime: "test"
        )
        var points = [
            point(.nose, 0.50, 0.20), point(.leftEar, 0.44, 0.22),
            point(.rightEar, 0.56, 0.22),
            point(.leftShoulder, 0.50 - shoulderSpanX / 2,
                  0.50 + (leftShoulderDeltaY ?? 0),
                  quality: limitedShoulders ? .limited : .good,
                  confidence: shoulderConfidence),
            point(.rightShoulder, 0.50 + shoulderSpanX / 2,
                  0.50 + (rightShoulderDeltaY ?? shoulderDeltaY),
                  quality: limitedShoulders ? .limited : .good,
                  confidence: shoulderConfidence)
        ]
        if !includeLeftShoulder {
            points.removeAll { $0.id == .leftShoulder }
        }
        if !includeRightShoulder {
            points.removeAll { $0.id == .rightShoulder }
        }
        if includeNeck {
            points.append(point(.neck, 0.50, 0.36))
        }
        if includeHips {
            points.append(point(.leftHip, 0.40 + hipOffset, 0.80))
            points.append(point(.rightHip, 0.60 + hipOffset, 0.80))
        }
        if cameraRollDegrees != 0 {
            let radians = cameraRollDegrees * .pi / 180
            let cosine = cos(radians)
            let sine = sin(radians)
            points = points.map { bodyPoint in
                let source = bodyPoint.location
                let pixelX = source.x * cameraRollPixelWidth
                let pixelY = source.y * cameraRollPixelHeight
                let dx = pixelX - cameraRollPixelWidth / 2
                let dy = pixelY - cameraRollPixelHeight / 2
                let rotatedX = dx * cosine - dy * sine + cameraRollPixelWidth / 2
                let rotatedY = dx * sine + dy * cosine + cameraRollPixelHeight / 2
                return UpperBodyPoint(
                    id: bodyPoint.id,
                    location: CGPoint(x: rotatedX / cameraRollPixelWidth, y: rotatedY / cameraRollPixelHeight),
                    confidence: bodyPoint.confidence,
                    quality: bodyPoint.quality,
                    provenance: bodyPoint.provenance
                )
            }
        }
        return UpperBodyResult(
            descriptor: descriptor, state: .detected, generation: generation,
            sampleID: sampleID, capturedAt: timestamp, producedAt: timestamp + 0.01,
            points: points, contours: [], regionOfInterest: regionOfInterest
        )
    }

    static func main() {
        let context = PostureFramingContext(pixelWidth: 1600, pixelHeight: 900)!
        let mirrored = PostureFramingContext(pixelWidth: 1600, pixelHeight: 900,
                                              canonicalMirror: true)!
        expect(context.key == mirrored.key, "le miroir d'affichage ne change pas la baseline")
        let roiJitterA = PostureFramingContext(
            pixelWidth: 1600, pixelHeight: 900,
            normalizedROI: CGRect(x: 0.05, y: 0.10, width: 0.90, height: 0.80)
        )!
        let roiJitterB = PostureFramingContext(
            pixelWidth: 1600, pixelHeight: 900,
            normalizedROI: CGRect(x: 0.051, y: 0.099, width: 0.899, height: 0.801)
        )!
        expect(roiJitterA.stableContextKey == roiJitterB.stableContextKey &&
               roiJitterA.dynamicROISignature != roiJitterB.dynamicROISignature,
               "un bruit de ROI conserve la clé stable mais change la signature dynamique")
        let rotatedCamera = PostureFramingContext(pixelWidth: 1600, pixelHeight: 900,
                                                   revision: "v2")!
        expect(rotatedCamera.key != context.key,
               "un changement de framing/caméra force un nouveau contexte")
        let formatChanged = PostureFramingContext(pixelWidth: 1280, pixelHeight: 720)!
        expect(formatChanged.stableContextKey != context.stableContextKey,
               "un changement de format caméra force une nouvelle calibration")
        let horizontal = context.pixelDistance(CGPoint(x: 0.1, y: 0.2),
                                               CGPoint(x: 0.6, y: 0.2))!
        let vertical = context.pixelDistance(CGPoint(x: 0.1, y: 0.2),
                                             CGPoint(x: 0.1, y: 0.7))!
        expect(abs(horizontal - 800) < 0.001 && abs(vertical - 450) < 0.001,
               "les distances 16:9 doivent être calculées en pixels")

        let neutralFace = face(contextKey: context.key)
        let neutral = PostureRichGeometryEvaluator.make(
            result: result(), face: neutralFace, context: context
        )
        expect(neutral.shouldersState == .available &&
               neutral.shoulderSlopeState == .available &&
               neutral.openingState == .available,
               "les deux épaules et le cou doivent être disponibles")
        expect(abs(neutral.shoulderSlopeDegrees ?? 99) < 0.001,
               "une position neutre doit conserver une pente numérique nulle")
        expect(neutral.torsoState == .available && neutral.torsoInclinationDegrees != nil,
               "le torse complet doit produire un angle")
        expect(neutral.shoulderOpeningRatio != nil && neutral.leftShoulderElevation != nil,
               "les proxys d'ouverture et d'élévation doivent être finis")
        expect(abs((neutral.shoulderTriangleHeightRatio ?? 99) - 0.2625) < 0.001,
               "le triangle neutre doit produire un ratio hauteur/base stable")
        let noNeck = PostureRichGeometryEvaluator.make(
            result: result(includeNeck: false), face: neutralFace, context: context
        )
        expect(noNeck.openingState == .partial &&
               noNeck.openingRatioState == .available &&
               noNeck.shoulderOpeningRatio != nil,
               "le ratio épaules/visage reste disponible sans cou, tandis que l'angle reste partiel")
        var noNeckSamples: [PostureRichGeometryMetrics] = []
        for index in 0..<12 {
            noNeckSamples.append(PostureRichGeometryEvaluator.make(
                result: result(sampleID: UInt64(1200 + index),
                               timestamp: Double(index) * 0.1,
                               includeNeck: false),
                face: face(sampleID: UInt64(1200 + index),
                           timestamp: Double(index) * 0.1,
                           contextKey: context.key),
                context: context
            ))
        }
        let noNeckBaseline = PostureRichBaselineBuilder.make(
            samples: noNeckSamples, generation: 1, contextKey: context.key
        )
        expect(noNeckBaseline?.shoulderOpeningRatio != nil &&
               noNeckBaseline?.familySampleCounts?.shoulderOpening == 12,
               "le ratio épaules/visage doit pouvoir être calibré sans cou")
        expect(neutral.headTiltState == .available &&
               abs(neutral.headTiltDegrees ?? 99) < 0.001,
               "la tête neutre doit être mesurée relativement à la ligne des épaules")
        let lowPointHeadTilt = PostureRichGeometryEvaluator.make(
            result: result(),
            face: face(contextKey: context.key, facePointCount: 12),
            context: context
        )
        expect(lowPointHeadTilt.headTiltDegrees != nil &&
               lowPointHeadTilt.headTiltState != .available,
               "un visage trop pauvre ne doit pas rendre la géométrie tête-épaules disponible")
        let yawOutOfDomainHeadTilt = PostureRichGeometryEvaluator.make(
            result: result(),
            face: face(contextKey: context.key, yawProxy: 0.5),
            context: context
        )
        expect(yawOutOfDomainHeadTilt.headTiltDegrees != nil &&
               yawOutOfDomainHeadTilt.headTiltState != .available,
               "un yaw hors domaine ne doit pas alimenter headTilt")
        let tiltedFaceGeometry = PostureRichGeometryEvaluator.make(
            result: result(),
            face: rotatedFaceFromPolylines(context: context, cameraRollDegrees: 8),
            context: context
        )
        expect(tiltedFaceGeometry.headTiltState == .available &&
               abs((tiltedFaceGeometry.headTiltDegrees ?? 99) - 8) < 0.5,
               "une rotation de tête seule doit produire environ huit degrés relatifs")
        let rolledTogetherContext = PostureFramingContext(
            pixelWidth: 1280, pixelHeight: 720, revision: "camera-roll-shared"
        )!
        let rolledTogether = PostureRichGeometryEvaluator.make(
            result: result(cameraRollDegrees: 8, cameraRollPixelWidth: 1280,
                           cameraRollPixelHeight: 720),
            face: rotatedFaceFromPolylines(context: rolledTogetherContext,
                                           cameraRollDegrees: 8),
            context: rolledTogetherContext
        )
        expect(abs(rolledTogether.headTiltDegrees ?? 99) < 1.0 &&
               abs(rolledTogether.shoulderSlopeDegrees ?? 99) > 7 &&
               rolledTogether.shoulderSlopeState == .partial,
               "un roulis commun 1280x720 doit s'annuler après conversion pixel des yeux")
        let noHipHead = PostureRichGeometryEvaluator.make(
            result: result(includeHips: false), face: neutralFace, context: context
        )
        expect(noHipHead.headTiltState == .available && noHipHead.headTiltDegrees != nil,
               "l'inclinaison tête-épaules ne doit pas exiger les hanches")
        let staleFaceGeometry = PostureRichGeometryEvaluator.make(
            result: result(timestamp: 0),
            face: face(timestamp: 1.0, contextKey: context.key),
            context: context
        )
        expect(staleFaceGeometry.shoulderOpeningRatio == nil &&
               staleFaceGeometry.headTiltState != .available,
               "un visage trop éloigné temporellement ne doit pas devenir une référence corps")
        let otherGenerationFaceGeometry = PostureRichGeometryEvaluator.make(
            result: result(generation: 1, timestamp: 0),
            face: face(generation: 2, timestamp: 0, contextKey: context.key),
            context: context
        )
        expect(otherGenerationFaceGeometry.shoulderOpeningRatio == nil &&
               otherGenerationFaceGeometry.headTiltState != .available,
               "un visage d'une autre génération ne doit pas être fusionné au corps")
        let jitterSamples = (0..<12).map { index in
            let jitterContext = index.isMultiple(of: 2) ? roiJitterA : roiJitterB
            return PostureRichGeometryEvaluator.make(
                result: result(sampleID: UInt64(40 + index), timestamp: Double(index) * 0.1),
                face: face(sampleID: UInt64(40 + index), timestamp: Double(index) * 0.1,
                           contextKey: jitterContext.stableContextKey),
                context: jitterContext
            )
        }
        expect(PostureRichBaselineBuilder.make(
            samples: jitterSamples, generation: 1,
            contextKey: roiJitterA.stableContextKey
        ) != nil, "un jitter ROI ne doit pas réinitialiser la baseline stable")
        expect(PostureRichBaselineBuilder.make(
            samples: jitterSamples, generation: 1,
            contextKey: formatChanged.stableContextKey
        ) == nil, "un changement de format ne doit pas réutiliser la baseline")
        let mismatchContext = PostureFramingContext(pixelWidth: 1600, pixelHeight: 900,
                                                     revision: "other-camera")!
        let mismatchMetrics = PostureRichGeometryEvaluator.make(
            result: result(),
            face: face(contextKey: mismatchContext.stableContextKey),
            context: context
        )
        expect(mismatchMetrics.shoulderOpeningRatio == nil &&
               mismatchMetrics.proximityScale == nil &&
               mismatchMetrics.leftShoulderElevation != nil &&
               mismatchMetrics.rightShoulderElevation != nil &&
               mismatchMetrics.reason?.contains("context") == true,
               "un mismatch visage/corps invalide les métriques fusionnées, sans effacer le signal corporel")
        let contextB = PostureFramingContext(pixelWidth: 1600, pixelHeight: 900,
                                              revision: "context-B")!
        var contextBGeometrySamples: [PostureRichGeometryMetrics] = []
        for index in 0..<11 {
            let timestamp = Double(index) * 0.1
            let metric = PostureRichGeometryEvaluator.make(
                result: result(generation: 2, sampleID: UInt64(700 + index),
                               timestamp: timestamp),
                face: face(generation: 2, sampleID: UInt64(700 + index),
                           timestamp: timestamp,
                           contextKey: contextB.stableContextKey),
                context: contextB
            )
            contextBGeometrySamples.append(metric)
        }
        expect(PostureRichBaselineBuilder.make(
            samples: contextBGeometrySamples, generation: 2,
            contextKey: contextB.stableContextKey
        ) == nil, "un nouveau contexte exige douze observations valides")
        let contextBFullSamples = contextBGeometrySamples + [
            PostureRichGeometryEvaluator.make(
                result: result(generation: 2, sampleID: 711, timestamp: 1.1),
                face: face(generation: 2, sampleID: 711, timestamp: 1.1,
                           contextKey: contextB.stableContextKey),
                context: contextB
            )
        ]
        expect(PostureRichBaselineBuilder.make(
            samples: contextBFullSamples, generation: 2,
            contextKey: contextB.stableContextKey
        ) != nil, "le nouveau contexte produit sa baseline après douze observations")

        let torsoRight = PostureRichGeometryEvaluator.make(
            result: result(hipOffset: 0.08), face: neutralFace, context: context
        )
        let torsoLeft = PostureRichGeometryEvaluator.make(
            result: result(hipOffset: -0.08), face: neutralFace, context: context
        )
        expect((torsoRight.torsoInclinationDegrees ?? 0) > 0 &&
               (torsoLeft.torsoInclinationDegrees ?? 0) < 0,
               "le signe torse positif indique un bassin décalé vers la droite")

        let halfDegree = PostureRichGeometryEvaluator.make(
            result: result(rightShoulderDeltaY: 0.005), face: neutralFace, context: context
        )
        let oneDegree = PostureRichGeometryEvaluator.make(
            result: result(rightShoulderDeltaY: 0.010), face: neutralFace, context: context
        )
        let twoDegrees = PostureRichGeometryEvaluator.make(
            result: result(rightShoulderDeltaY: 0.020), face: neutralFace, context: context
        )
        expect(abs(halfDegree.shoulderSlopeDegrees ?? 99) > 0.4 &&
               abs(oneDegree.shoulderSlopeDegrees ?? 0) > abs(halfDegree.shoulderSlopeDegrees ?? 0) &&
               abs(twoDegrees.shoulderSlopeDegrees ?? 0) > abs(oneDegree.shoulderSlopeDegrees ?? 0),
               "la pente signée doit rester sensible aux variations 0,5/1/2°")
        let rightHigher = PostureRichGeometryEvaluator.make(
            result: result(rightShoulderDeltaY: -0.010), face: neutralFace, context: context
        )
        expect((rightHigher.shoulderSlopeDegrees ?? 0) < 0,
               "le signe doit distinguer l'épaule droite plus haute")
        let leftHigher = PostureRichGeometryEvaluator.make(
            result: result(leftShoulderDeltaY: -0.010), face: neutralFace, context: context
        )
        expect((leftHigher.shoulderSlopeDegrees ?? 0) > 0,
               "le signe doit distinguer l'épaule gauche plus haute")

        let strongRightHigherSlope = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 95, timestamp: 0.1, rightShoulderDeltaY: -0.20),
            face: rotatedFaceFromPolylines(
                generation: 1, sampleID: 95, timestamp: 0.1,
                context: context, cameraRollDegrees: 8
            ),
            context: context
        )
        let strongLeftHigherSlope = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 96, timestamp: 0.1, leftShoulderDeltaY: -0.20),
            face: rotatedFaceFromPolylines(
                generation: 1, sampleID: 96, timestamp: 0.1,
                context: context, cameraRollDegrees: 8
            ),
            context: context
        )
        expect(strongRightHigherSlope.shouldersState == .available &&
               strongRightHigherSlope.shoulderSlopeState == .available &&
               (strongRightHigherSlope.shoulderSlopeDegrees ?? 0) < -15,
               "une forte pente avec épaule droite plus haute doit rester mesurée malgré un roulis facial distinct")
        expect(strongLeftHigherSlope.shouldersState == .available &&
               strongLeftHigherSlope.shoulderSlopeState == .available &&
               (strongLeftHigherSlope.shoulderSlopeDegrees ?? 0) > 15,
               "une forte pente avec épaule gauche plus haute doit rester mesurée malgré un roulis facial distinct")

        let noisyDeltas: [CGFloat] = [0.002, -0.002, 0.001, -0.001, 0.002, -0.001]
        let noisySlopes = noisyDeltas.map { delta in
            PostureRichGeometryEvaluator.make(
                result: result(rightShoulderDeltaY: delta), face: neutralFace, context: context
            ).shoulderSlopeDegrees ?? 99
        }
        expect(noisySlopes.allSatisfy { abs($0) < 0.25 },
               "le bruit sous-seuil doit rester une petite variation mesurable")

        let rolledContext = PostureFramingContext(pixelWidth: 1600, pixelHeight: 900,
                                                   revision: "camera-roll-8deg")!
        let rolled = PostureRichGeometryEvaluator.make(
            result: result(cameraRollDegrees: 8),
            face: face(contextKey: rolledContext.key),
            context: rolledContext
        )
        expect(rolled.contextKey != context.key &&
               abs(rolled.shoulderSlopeDegrees ?? 0) > 6.5,
               "un roulis caméra doit rester mesuré dans son contexte, sans suivre la tête")
        let headRollFace = face(contextKey: context.key)
        let headOnly = PostureRichGeometryEvaluator.make(
            result: result(), face: headRollFace, context: context
        )
        expect(abs((headOnly.shoulderSlopeDegrees ?? 99) - (neutral.shoulderSlopeDegrees ?? 0)) < 0.001,
               "un changement de tête seul ne doit pas influencer la pente des épaules")
        let headScaleOnly = PostureRichGeometryEvaluator.make(
            result: result(),
            face: face(contextKey: context.key, faceScaleMultiplier: 1.8),
            context: context
        )
        expect(abs((headScaleOnly.leftShoulderElevation ?? 99) -
                   (neutral.leftShoulderElevation ?? 0)) < 0.001 &&
               abs((headScaleOnly.rightShoulderElevation ?? 99) -
                   (neutral.rightShoulderElevation ?? 0)) < 0.001,
               "une variation de taille faciale seule ne doit pas influencer l'élévation")

        let closeCrop = PostureRichGeometryEvaluator.make(
            result: result(includeHips: false), face: neutralFace, context: context
        )
        expect(closeCrop.torsoState == .partial && closeCrop.torsoInclinationDegrees == nil,
               "les hanches hors champ rendent l'inclinaison indisponible")
        expect(closeCrop.shouldersState == .available,
               "les épaules restent indépendantes des hanches")
        let limited = PostureRichGeometryEvaluator.make(
            result: result(limitedShoulders: true), face: neutralFace, context: context
        )
        expect(limited.shouldersState == .partial && limited.openingState == .partial &&
               limited.torsoState == .partial && limited.torsoInclinationDegrees == nil &&
               limited.torsoAxisDeviation == nil,
               "les repères limited ne doivent alimenter ni épaules ni torse")

        let lowConfidence = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 90, shoulderConfidence: 0.59),
            face: face(sampleID: 90, contextKey: context.key), context: context
        )
        expect(lowConfidence.shoulderSlopeDegrees != nil &&
               lowConfidence.shouldersState == .available &&
               lowConfidence.shoulderSlopeState == .partial,
               "une pente faible confiance reste mesurable mais ne devient pas publiable")
        let confidenceBoundary = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 91, shoulderConfidence: 0.61),
            face: face(sampleID: 91, contextKey: context.key), context: context
        )
        expect(confidenceBoundary.shoulderSlopeState == .available,
               "une confiance juste au-dessus de la marge doit rester sensible")

        let incoherentPair = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 92, shoulderSpanX: 0.07),
            face: face(sampleID: 92, contextKey: context.key), context: context
        )
        expect(incoherentPair.shouldersState == .partial &&
               incoherentPair.shoulderSlopeState == .partial &&
               incoherentPair.leftShoulderElevation == nil,
               "une paire d'épaules presque confondue ne doit alimenter aucune alerte")
        let missingShoulder = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 94, includeRightShoulder: false),
            face: face(sampleID: 94, contextKey: context.key), context: context
        )
        expect(missingShoulder.shoulderSlopeDegrees == nil &&
               missingShoulder.shoulderSlopeState == .partial,
               "une seule épaule doit rester partielle sans fabriquer de pente")
        let missingPair = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 95, includeLeftShoulder: false,
                           includeRightShoulder: false),
            face: face(sampleID: 95, contextKey: context.key), context: context
        )
        expect(missingPair.shoulderSlopeDegrees == nil &&
               missingPair.shoulderSlopeState == .unavailable,
               "deux épaules absentes doivent rendre la pente indisponible")

        let poorOrientation = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 93, rightShoulderDeltaY: 0.010),
            face: face(sampleID: 93, contextKey: context.key, yawProxy: 0.5),
            context: context
        )
        expect(poorOrientation.shouldersState == .available &&
               poorOrientation.shoulderSlopeState == .partial &&
               poorOrientation.shoulderSlopeReason?.contains("orientation") == true,
               "une orientation visage hors marge doit limiter la pente sans effacer sa mesure")

        let fallbackROI = UpperBodyRegionOfInterest.fullFrameFallback(
            capturedAt: 0, sampleID: 94, generation: 1
        )!
        let fallbackFrame = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 94, rightShoulderDeltaY: 0.010,
                           regionOfInterest: fallbackROI),
            face: nil, context: context
        )
        expect(fallbackFrame.shoulderSlopeState == .available &&
               fallbackFrame.shoulderSlopeReason == nil,
               "un crop de secours ne doit pas annuler une paire d'épaules fiable")

        let samples = (0..<12).map { index in
            PostureRichGeometryMetrics(
                generation: neutral.generation, sampleID: UInt64(index + 1),
                capturedAt: Double(index) * 0.1, contextKey: neutral.contextKey,
                torsoInclinationDegrees: neutral.torsoInclinationDegrees,
                torsoAxisDeviation: neutral.torsoAxisDeviation,
                shoulderSlopeDegrees: neutral.shoulderSlopeDegrees,
                shoulderOpeningDegrees: neutral.shoulderOpeningDegrees,
                shoulderOpeningRatio: neutral.shoulderOpeningRatio,
                leftShoulderElevation: neutral.leftShoulderElevation,
                rightShoulderElevation: neutral.rightShoulderElevation,
                proximityScale: neutral.proximityScale,
                shouldersState: neutral.shouldersState,
                torsoState: neutral.torsoState,
                openingState: neutral.openingState,
                reason: neutral.reason,
                headTiltDegrees: neutral.headTiltDegrees,
                headTiltState: neutral.headTiltState
            )
        }
        let baseline = PostureRichBaselineBuilder.make(
            samples: samples, generation: 1, contextKey: context.key
        )
        expect(baseline?.sampleCount == 12 && baseline?.proximityScale != nil,
               "la baseline doit conserver les métriques scalaires et la proximité")
        expect(baseline?.headTiltDegrees != nil &&
               baseline?.familySampleCounts?.headTilt == 12 &&
               baseline?.headTiltMAD != nil,
               "l'inclinaison tête-épaules doit avoir une maturité et une dispersion propres")
        var invalidHeadTiltSamples: [PostureRichGeometryMetrics] = []
        var invalidHeadTiltFaces: [PostureFaceObservation] = []
        for index in 0..<12 {
            let sampleID = UInt64(700 + index)
            let timestamp = Double(index) * 0.1
            let invalidFace = face(sampleID: sampleID, timestamp: timestamp,
                                   contextKey: context.key, yawProxy: 0.5,
                                   facePointCount: 12)
            invalidHeadTiltFaces.append(invalidFace)
            invalidHeadTiltSamples.append(PostureRichGeometryEvaluator.make(
                result: result(sampleID: sampleID, timestamp: timestamp),
                face: invalidFace, context: context
            ))
        }
        let invalidHeadTiltBaseline = PostureRichBaselineBuilder.make(
            samples: invalidHeadTiltSamples, faceSamples: invalidHeadTiltFaces,
            generation: 1, contextKey: context.key
        )
        expect(invalidHeadTiltBaseline?.familySampleCounts?.headTilt == 0 &&
               invalidHeadTiltBaseline?.headTiltDegrees == nil,
               "yaw hors domaine ou points insuffisants ne doivent pas calibrer headTilt")
        var headTiltEvaluatorConfiguration = PostureRichSignalConfiguration()
        headTiltEvaluatorConfiguration.requiredDuration = 0
        headTiltEvaluatorConfiguration.headTiltEnterDegrees = 7.5
        var headTiltEvaluator = PostureRichSignalEvaluator(
            configuration: headTiltEvaluatorConfiguration
        )
        let headTiltEvaluation = headTiltEvaluator.consume(
            geometry: tiltedFaceGeometry,
            face: face(contextKey: context.key, eyeLineRollDegrees: 12),
            baseline: baseline,
            now: 0.1
        )
        expect(headTiltEvaluation.headTilt.quality == .good &&
               abs((headTiltEvaluation.headTilt.numericValue ?? 99) - 8) < 0.5 &&
               abs((headTiltEvaluation.headTilt.referenceDelta ?? 99) - 8) < 0.5 &&
               headTiltEvaluation.headTilt.isAttention,
               "le signal tête doit publier sa valeur brute, son écart calibré et son attention persistante")
        let noHipSamples = (0..<12).map { index in
            PostureRichGeometryEvaluator.make(
                result: result(generation: 3, sampleID: UInt64(index + 1),
                               timestamp: Double(index) * 0.1, includeHips: false),
                context: context
            )
        }
        let noHipBaseline = PostureRichBaselineBuilder.make(
            samples: noHipSamples, generation: 3, contextKey: context.key
        )
        expect(noHipBaseline?.torsoInclinationDegrees == nil &&
               noHipBaseline?.shoulderSlopeDegrees != nil &&
               noHipBaseline?.leftShoulderElevation != nil &&
               noHipBaseline?.familySampleCounts?.torso == 0 &&
               noHipBaseline?.familySampleCounts?.shoulderSlope == 12 &&
               noHipBaseline?.familySampleCounts?.shoulderElevation == 12,
               "les épaules doivent être calibrables sans hanches et le torse doit rester indisponible")
        if let noHipBaseline {
            var noHipEvaluator = PostureRichSignalEvaluator(configuration: .init())
            let noHipEvaluation = noHipEvaluator.consumeBody(
                geometry: noHipSamples[0], baseline: noHipBaseline, now: 0.01
            )
            expect(noHipEvaluation.torsoInclination.state == .unavailable &&
                   noHipEvaluation.shoulderSlope.state == .available &&
                   noHipEvaluation.shouldersRaised.state == .available,
                   "une baseline partielle ne doit pas marquer le torse complet ni bloquer les épaules")
        }
        var noHipOutlierSamples = noHipSamples
        noHipOutlierSamples[6] = PostureRichGeometryEvaluator.make(
            result: result(generation: 3, sampleID: 7, timestamp: 0.6,
                           rightShoulderDeltaY: 0.20, includeHips: false),
            context: context
        )
        let robustNoHipBaseline = PostureRichBaselineBuilder.make(
            samples: noHipOutlierSamples, generation: 3, contextKey: context.key
        )
        expect(robustNoHipBaseline?.familySampleCounts?.shoulderSlope == 12 &&
               abs(robustNoHipBaseline?.shoulderSlopeDegrees ?? 99) < 0.001,
               "un outlier isolé ne doit pas déplacer la médiane des épaules")
        var faceOnlySamples: [PostureFaceObservation] = []
        for index in 0..<13 {
            let yaw: Double = index == 6 ? 0.5 : 0
            faceOnlySamples.append(face(
                generation: 4, sampleID: UInt64(index + 1),
                timestamp: Double(index) * 0.1, contextKey: context.key,
                yawProxy: yaw
            ))
        }
        let faceOnlyBaseline = PostureRichBaselineBuilder.make(
            samples: [], faceSamples: faceOnlySamples,
            generation: 4, contextKey: context.key
        )
        expect(faceOnlyBaseline?.familySampleCounts?.proximity == 12 &&
               faceOnlyBaseline?.familySampleCounts?.blinkOpening == 12 &&
               faceOnlyBaseline?.proximityScale != nil &&
               faceOnlyBaseline?.blinkOpeningBaseline != nil,
               "la calibration visage indépendante doit ignorer le profil et conserver douze frames valides")
        var invalidFaceSamples: [PostureFaceObservation] = []
        for index in 0..<12 {
            invalidFaceSamples.append(face(
                generation: 1, sampleID: UInt64(100 + index),
                timestamp: Double(index) * 0.1, contextKey: context.key,
                yawProxy: 0.5
            ))
        }
        let bodyWithInvalidFaceBaseline = PostureRichBaselineBuilder.make(
            samples: samples, faceSamples: invalidFaceSamples,
            generation: 1, contextKey: context.key
        )
        expect(bodyWithInvalidFaceBaseline?.shoulderOpeningRatio == nil &&
               bodyWithInvalidFaceBaseline?.familySampleCounts?.shoulderOpening == 0,
               "un visage hors domaine ne doit pas devenir la référence ouverture des épaules")
        var limitedOpeningSamples: [PostureRichGeometryMetrics] = []
        for index in 0..<12 {
            let sampleID = UInt64(1100 + index)
            let timestamp = Double(index) * 0.1
            limitedOpeningSamples.append(PostureRichGeometryEvaluator.make(
                result: result(sampleID: sampleID, timestamp: timestamp,
                               limitedShoulders: true),
                face: face(sampleID: sampleID, timestamp: timestamp,
                           contextKey: context.key), context: context
            ))
        }
        let limitedOpeningBaseline = PostureRichBaselineBuilder.make(
            samples: limitedOpeningSamples, generation: 1, contextKey: context.key
        )
        expect(limitedOpeningBaseline == nil ||
               (limitedOpeningBaseline?.shoulderOpeningRatio == nil &&
                limitedOpeningBaseline?.familySampleCounts?.shoulderOpening == 0),
               "des épaules de qualité insuffisante ne doivent pas calibrer le ratio")
        let slowBodySamples = samples.enumerated().map { index, sample in
            PostureRichGeometryMetrics(
                generation: sample.generation, sampleID: sample.sampleID,
                capturedAt: Double(index) * 0.5, contextKey: sample.contextKey,
                torsoInclinationDegrees: sample.torsoInclinationDegrees,
                torsoAxisDeviation: sample.torsoAxisDeviation,
                shoulderSlopeDegrees: sample.shoulderSlopeDegrees,
                shoulderOpeningDegrees: sample.shoulderOpeningDegrees,
                shoulderOpeningRatio: sample.shoulderOpeningRatio,
                leftShoulderElevation: sample.leftShoulderElevation,
                rightShoulderElevation: sample.rightShoulderElevation,
                proximityScale: sample.proximityScale,
                shouldersState: sample.shouldersState, torsoState: sample.torsoState,
                openingState: sample.openingState, reason: sample.reason
            )
        }
        var faceWindow: [PostureFaceObservation] = []
        for index in 0...55 {
            faceWindow.append(face(
                generation: 1, sampleID: UInt64(200 + index),
                timestamp: Double(index) * 0.1, contextKey: context.key
            ))
        }
        let slowBodyBaseline = PostureRichBaselineBuilder.make(
            samples: slowBodySamples, faceSamples: faceWindow,
            generation: 1, contextKey: context.key
        )
        expect(slowBodyBaseline?.familySampleCounts?.shoulderOpening == 12,
               "les ticks visage doivent couvrir toute la fenêtre des corps à 2 Hz")
        let legacyBaselineJSON = try! JSONSerialization.data(withJSONObject: [
            "generation": 1,
            "contextKey": context.key,
            "ruleVersion": "rich-v1",
            "torsoInclinationDegrees": NSNull(),
            "torsoAxisDeviation": NSNull(),
            "shoulderSlopeDegrees": NSNull(),
            "shoulderOpeningRatio": NSNull(),
            "leftShoulderElevation": NSNull(),
            "rightShoulderElevation": NSNull(),
            "proximityScale": NSNull(),
            "sampleCount": 12,
            "torsoInclinationMAD": NSNull(),
            "torsoAxisMAD": NSNull(),
            "shoulderSlopeMAD": NSNull()
        ])
        let decodedLegacyBaseline = try? JSONDecoder().decode(
            PostureRichBaseline.self, from: legacyBaselineJSON
        )
        expect(decodedLegacyBaseline?.blinkOpeningBaseline == nil,
               "une baseline antérieure sans repère oculaire doit rester décodable")
        let partialSamples = samples.map {
            PostureRichGeometryMetrics(
                generation: $0.generation, sampleID: $0.sampleID, capturedAt: $0.capturedAt,
                contextKey: $0.contextKey, torsoInclinationDegrees: $0.torsoInclinationDegrees,
                torsoAxisDeviation: $0.torsoAxisDeviation, shoulderSlopeDegrees: $0.shoulderSlopeDegrees,
                shoulderOpeningDegrees: $0.shoulderOpeningDegrees,
                shoulderOpeningRatio: $0.shoulderOpeningRatio,
                leftShoulderElevation: $0.leftShoulderElevation,
                rightShoulderElevation: $0.rightShoulderElevation,
                proximityScale: $0.proximityScale, shouldersState: .partial,
                torsoState: .partial, openingState: .partial, reason: "fixture partial"
            )
        }
        expect(PostureRichBaselineBuilder.make(samples: partialSamples, generation: 1,
                                               contextKey: context.key) == nil,
               "douze observations partiales ne doivent pas produire de baseline")
        let duplicate = Array(samples.dropLast()) + [samples[10]]
        expect(PostureRichBaselineBuilder.make(samples: duplicate, generation: 1,
                                               contextKey: context.key) == nil,
               "un timestamp dupliqué ne doit pas faire avancer la baseline")
        var gapped = samples
        gapped[6] = PostureRichGeometryMetrics(
            generation: samples[6].generation, sampleID: samples[6].sampleID,
            capturedAt: 4.0, contextKey: samples[6].contextKey,
            torsoInclinationDegrees: samples[6].torsoInclinationDegrees,
            torsoAxisDeviation: samples[6].torsoAxisDeviation,
            shoulderSlopeDegrees: samples[6].shoulderSlopeDegrees,
            shoulderOpeningDegrees: samples[6].shoulderOpeningDegrees,
            shoulderOpeningRatio: samples[6].shoulderOpeningRatio,
            leftShoulderElevation: samples[6].leftShoulderElevation,
            rightShoulderElevation: samples[6].rightShoulderElevation,
            proximityScale: samples[6].proximityScale,
            shouldersState: samples[6].shouldersState, torsoState: samples[6].torsoState,
            openingState: samples[6].openingState, reason: samples[6].reason
        )
        expect(PostureRichBaselineBuilder.make(samples: gapped, generation: 1,
                                               contextKey: context.key) == nil,
               "un gap temporel ne doit pas fabriquer une baseline")

        var configuration = PostureRichSignalConfiguration()
        configuration.requiredDuration = 0.5
        configuration.blinkMinimumObservable = 0.1
        configuration.blinkMaximumGap = 0.4
        configuration.blinkWindow = 10

        var universalConfiguration = PostureRichSignalConfiguration()
        universalConfiguration.referenceMode = .universalGeometry
        universalConfiguration.requiredDuration = 0
        universalConfiguration.shoulderSlopeRequiredDuration = 0
        universalConfiguration.proximityDuration = 0
        var universalEvaluator = PostureRichSignalEvaluator(
            configuration: universalConfiguration
        )
        let deliberatelyWrongPersonalBaseline = PostureRichBaseline(
            generation: 1, contextKey: context.key, ruleVersion: "rich-v3",
            torsoInclinationDegrees: 40, torsoAxisDeviation: 40,
            shoulderSlopeDegrees: 40, shoulderOpeningRatio: 0.01,
            leftShoulderElevation: 40, rightShoulderElevation: 40,
            proximityScale: 0.01, sampleCount: 12,
            torsoInclinationMAD: 0, torsoAxisMAD: 0, shoulderSlopeMAD: 0,
            familySampleCounts: .init(torso: 12, shoulderSlope: 12, headTilt: 12,
                                      shoulderElevation: 12, shoulderOpening: 12,
                                      proximity: 12),
            headTiltDegrees: 40, headTiltMAD: 0
        )
        let universalNeutral = universalEvaluator.consume(
            geometry: neutral, face: neutralFace,
            baseline: deliberatelyWrongPersonalBaseline, now: 0
        )
        expect(!universalNeutral.torsoInclination.isAttention &&
               !universalNeutral.shoulderSlope.isAttention &&
               !universalNeutral.headTilt.isAttention &&
               !universalNeutral.proximity.isAttention &&
               !universalNeutral.shouldersRaised.isAttention &&
               abs((universalNeutral.shouldersRaised.value ?? 99) - 0.2625) < 0.001 &&
               abs(universalNeutral.torsoInclination.referenceDelta ?? 99) < 0.001,
               "la géométrie neutre doit rester neutre même avec une ancienne baseline personnelle opposée")

        var raisedConfiguration = universalConfiguration
        raisedConfiguration.requiredDuration = 0.5
        var universalRaisedEvaluator = PostureRichSignalEvaluator(configuration: raisedConfiguration)
        let flattenedGeometry = PostureRichGeometryEvaluator.make(
            result: result(generation: 1, sampleID: 50, timestamp: 1.0,
                           leftShoulderDeltaY: -0.04, rightShoulderDeltaY: -0.04),
            face: face(generation: 1, sampleID: 50, timestamp: 1.0,
                       contextKey: context.key), context: context
        )
        let flattenedFirst = universalRaisedEvaluator.consume(
            geometry: flattenedGeometry,
            face: face(generation: 1, sampleID: 50, timestamp: 1.0,
                       contextKey: context.key),
            baseline: deliberatelyWrongPersonalBaseline, now: 1.0
        )
        expect(abs((flattenedFirst.shouldersRaised.value ?? 99) - 0.1875) < 0.001 &&
               flattenedFirst.shouldersRaised.quality == .good &&
               !flattenedFirst.shouldersRaised.isAttention,
               "un triangle aplati doit rester en attente avant sa durée minimale")
        let flattenedSecond = universalRaisedEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(generation: 1, sampleID: 51, timestamp: 1.5,
                               leftShoulderDeltaY: -0.04, rightShoulderDeltaY: -0.04),
                face: face(generation: 1, sampleID: 51, timestamp: 1.5,
                           contextKey: context.key), context: context
            ),
            face: face(generation: 1, sampleID: 51, timestamp: 1.5,
                       contextKey: context.key),
            baseline: deliberatelyWrongPersonalBaseline, now: 1.5
        )
        expect(flattenedSecond.shouldersRaised.isAttention &&
               flattenedSecond.shouldersRaised.shoulderRaiseClassification == .bilateral,
               "un ratio sous 0,20 maintenu doit signaler les deux épaules relevées")
        let recoveredRaised = universalRaisedEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(generation: 1, sampleID: 52, timestamp: 1.6),
                face: face(generation: 1, sampleID: 52, timestamp: 1.6,
                           contextKey: context.key), context: context
            ),
            face: face(generation: 1, sampleID: 52, timestamp: 1.6,
                       contextKey: context.key),
            baseline: deliberatelyWrongPersonalBaseline, now: 1.6
        )
        expect(!recoveredRaised.shouldersRaised.isAttention,
               "le retour au ratio neutre doit fermer immédiatement l'épisode")
        let slopedShoulder = universalRaisedEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(generation: 1, sampleID: 53, timestamp: 1.7,
                               leftShoulderDeltaY: -0.08),
                face: face(generation: 1, sampleID: 53, timestamp: 1.7,
                           contextKey: context.key), context: context
            ),
            face: face(generation: 1, sampleID: 53, timestamp: 1.7,
                       contextKey: context.key),
            baseline: deliberatelyWrongPersonalBaseline, now: 1.7
        )
        expect(slopedShoulder.shoulderSlope.isAttention &&
               !slopedShoulder.shouldersRaised.isAttention,
               "une base inclinée doit rester du ressort du signal latéral, pas du triangle bilatéral")
        let universalTilted = PostureRichGeometryEvaluator.make(
            result: result(generation: 1, sampleID: 2, timestamp: 0.1,
                           hipOffset: 0.20, rightShoulderDeltaY: -0.20),
            face: face(generation: 1, sampleID: 2, timestamp: 0.1,
                       contextKey: context.key, eyeLineRollDegrees: 15),
            context: context
        )
        let universalAttention = universalEvaluator.consume(
            geometry: universalTilted,
            face: face(generation: 1, sampleID: 2, timestamp: 0.1,
                       contextKey: context.key, eyeLineRollDegrees: 15),
            baseline: deliberatelyWrongPersonalBaseline, now: 0.1
        )
        expect(universalAttention.torsoInclination.isAttention &&
               universalAttention.shoulderSlope.isAttention &&
               universalAttention.headTilt.isAttention &&
               (universalAttention.torsoInclination.numericValue ?? 0) > 10 &&
               abs(universalAttention.shoulderSlope.numericValue ?? 0) > 6 &&
               abs(universalAttention.headTilt.numericValue ?? 0) > 10,
               "les angles universels doivent utiliser zéro et leurs seuils fixes, pas la baseline personnelle")
        let strongHeadRollFace = face(
            generation: 1, sampleID: 21, timestamp: 0.15,
            contextKey: context.key, eyeLineRollDegrees: 40
        )
        let strongHeadRoll = universalEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(generation: 1, sampleID: 21, timestamp: 0.15),
                face: strongHeadRollFace, context: context
            ),
            face: strongHeadRollFace,
            baseline: deliberatelyWrongPersonalBaseline, now: 0.15
        )
        expect(strongHeadRoll.headTilt.quality == .good &&
               strongHeadRoll.headTilt.isAttention &&
               abs(strongHeadRoll.headTilt.numericValue ?? 0) > 20,
               "une forte inclinaison mesurable ne doit pas être rejetée par le seuil de roulis")
        let closeFace = face(generation: 1, sampleID: 3, timestamp: 0.2,
                             contextKey: context.key, faceScaleMultiplier: 2)
        let closeEvaluation = universalEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(generation: 1, sampleID: 3, timestamp: 0.2),
                face: closeFace, context: context
            ),
            face: closeFace,
            baseline: deliberatelyWrongPersonalBaseline, now: 0.2
        )
        expect(closeEvaluation.proximity.isAttention &&
               (closeEvaluation.proximity.numericValue ?? 0) >= 0.24,
               "la proximité universelle doit comparer la taille faciale apparente à 0,24")
        let closeRolledFace = face(
            generation: 1, sampleID: 31, timestamp: 0.25,
            contextKey: context.key, faceScaleMultiplier: 2, eyeLineRollDegrees: 32
        )
        let closeRolledEvaluation = universalEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(generation: 1, sampleID: 31, timestamp: 0.25),
                face: closeRolledFace, context: context
            ),
            face: closeRolledFace,
            baseline: deliberatelyWrongPersonalBaseline, now: 0.25
        )
        expect(closeRolledEvaluation.proximity.quality == .good &&
               closeRolledEvaluation.proximity.isAttention,
               "un visage proche et incliné doit conserver sa proximité apparente")
        let recovered = universalEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(generation: 1, sampleID: 4, timestamp: 0.3),
                face: face(generation: 1, sampleID: 4, timestamp: 0.3,
                           contextKey: context.key), context: context
            ),
            face: face(generation: 1, sampleID: 4, timestamp: 0.3,
                       contextKey: context.key),
            baseline: deliberatelyWrongPersonalBaseline, now: 0.3
        )
        expect(!recovered.proximity.isAttention,
               "la proximité doit quitter l'attention sous le seuil d'hystérésis 0,21")

        var automaticBlinkConfiguration = configuration
        automaticBlinkConfiguration.blinkTargetPerMinute = nil
        automaticBlinkConfiguration.blinkMinimumObservable = 0.1
        automaticBlinkConfiguration.blinkLowRateDuration = 0.3
        automaticBlinkConfiguration.blinkMaximumSuspension = 1.0
        var automaticBlinkEvaluator = PostureRichSignalEvaluator(
            configuration: automaticBlinkConfiguration
        )
        var automaticBlinkEvaluation: PostureRichEvaluation?
        let automaticBody = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 600, timestamp: 0), face: neutralFace, context: context
        )
        let automaticEyeSequence: [(TimeInterval, Double)] = [
            (0.0, 0.30), (0.1, 0.15), (0.2, 0.30),
            (0.3, 0.30), (0.4, 0.30), (0.5, 0.30), (0.6, 0.30)
        ]
        for (index, sample) in automaticEyeSequence.enumerated() {
            automaticBlinkEvaluation = automaticBlinkEvaluator.consume(
                geometry: automaticBody,
                face: face(sampleID: UInt64(600 + index), timestamp: sample.0,
                           contextKey: context.key, eyeOpeningRatio: sample.1),
                baseline: baseline, now: sample.0
            )
        }
        expect(automaticBlinkEvaluation?.blinkRate.state == .available &&
               automaticBlinkEvaluation?.blinkRate.value != nil &&
               automaticBlinkEvaluation?.blinkRate.normalizedValue == nil &&
               automaticBlinkEvaluation?.blinkRate.direction == .unknown &&
               automaticBlinkEvaluation?.blinkRate.isAttention == false,
               "un débit fiable sans trois fenêtres de référence ne doit pas prétendre être sous la cible")

        var pauseConfiguration = automaticBlinkConfiguration
        pauseConfiguration.blinkMinimumObservable = 30
        pauseConfiguration.blinkPauseReminderAfter = 2
        pauseConfiguration.blinkMaximumCountedInterval = 0.25
        var pauseEvaluator = PostureRichSignalEvaluator(configuration: pauseConfiguration)
        var pauseEvaluation: PostureRichEvaluation?
        for index in 0...20 {
            let timestamp = Double(index) * 0.1
            pauseEvaluation = pauseEvaluator.consume(
                geometry: automaticBody,
                face: face(sampleID: UInt64(900 + index), timestamp: timestamp,
                           contextKey: context.key),
                baseline: baseline, now: timestamp
            )
        }
        expect(pauseEvaluation?.blinkRate.state == .available &&
               pauseEvaluation?.blinkRate.value == 0 &&
               pauseEvaluation?.blinkRate.numericValue == nil &&
               pauseEvaluation?.blinkRate.normalizedValue == 0 &&
               pauseEvaluation?.blinkRate.isAttention == true &&
               pauseEvaluation?.blinkRate.reason.contains("pause") == true,
               "un rappel d'yeux ouverts peut être fiable avant la maturité du débit sans inventer une fréquence")

        var sensitivePauseConfiguration = PostureRichSignalConfiguration.sensitive
        sensitivePauseConfiguration.blinkMinimumObservable = 30
        var sensitivePauseEvaluator = PostureRichSignalEvaluator(
            configuration: sensitivePauseConfiguration
        )
        var beforeSensitivePause: PostureRichEvaluation?
        var sensitivePauseEvaluation: PostureRichEvaluation?
        for index in 0...150 {
            let timestamp = Double(index) * 0.1
            sensitivePauseEvaluation = sensitivePauseEvaluator.consume(
                geometry: automaticBody,
                face: face(sampleID: UInt64(2000 + index), timestamp: timestamp,
                           contextKey: context.key),
                baseline: baseline, now: timestamp
            )
            if index == 149 {
                beforeSensitivePause = sensitivePauseEvaluation
            }
        }
        expect(beforeSensitivePause?.blinkRate.isAttention == false &&
               sensitivePauseEvaluation?.blinkRate.isAttention == true &&
               sensitivePauseEvaluation?.blinkRate.reason.contains("15 secondes") == true,
               "le profil sensible doit rappeler après 15 secondes d'yeux ouverts observés")

        let afterPauseGap = pauseEvaluator.consume(
            geometry: automaticBody,
            face: face(sampleID: 922, timestamp: 3.0,
                       contextKey: context.key),
            baseline: baseline, now: 3.0
        )
        expect(afterPauseGap.blinkRate.isAttention == false,
               "un gap facial réinitialise le rappel de pause")
        let afterClosedEyes = pauseEvaluator.consume(
            geometry: automaticBody,
            face: face(sampleID: 923, timestamp: 3.1,
                       contextKey: context.key, eyeOpeningRatio: 0.15),
            baseline: baseline, now: 3.1
        )
        expect(afterClosedEyes.blinkRate.isAttention == false,
               "la fermeture des yeux réinitialise le rappel de pause")
        let contextBReset = automaticBlinkEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(generation: 2, sampleID: 800, timestamp: 0),
                face: face(generation: 2, sampleID: 800, timestamp: 0,
                           contextKey: contextB.stableContextKey), context: contextB
            ),
            face: face(generation: 2, sampleID: 800, timestamp: 0,
                       contextKey: contextB.stableContextKey),
            baseline: nil, now: 0
        )
        expect(contextBReset.blinkRate.normalizedValue == nil &&
               contextBReset.blinkRate.direction == .unknown &&
               (contextBReset.blinkRate.belowDuration ?? 0) == 0,
               "un changement génération/contexte ne transporte ni cible ni durée clignement")

        var evaluator = PostureRichSignalEvaluator(configuration: configuration)
        let initial = evaluator.consume(
            geometry: neutral, face: neutralFace, baseline: baseline, now: 0
        )
        expect(initial.torsoInclination.state == .available &&
               !initial.torsoInclination.isAttention,
               "une baseline neutre ne déclenche pas d'attention")
        let limitedEvaluation = evaluator.consume(
            geometry: limited, face: face(sampleID: 9, timestamp: 0.1, contextKey: context.key),
            baseline: baseline, now: 0.1
        )
        expect(limitedEvaluation.shoulderSlope.quality == .limited &&
               !limitedEvaluation.shoulderSlope.isAttention,
               "un repère limited ne doit pas déclencher une petite asymétrie")
        var qualityEvaluator = PostureRichSignalEvaluator(configuration: configuration)
        _ = qualityEvaluator.consume(geometry: neutral, face: neutralFace,
                                     baseline: baseline, now: 0)
        let limitedFrameOne = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 10, timestamp: 0.6, hipOffset: 0.20,
                           shoulderDeltaY: 0.010, limitedShoulders: true),
            face: face(sampleID: 10, timestamp: 0.6, contextKey: context.key), context: context
        )
        let limitedFrameTwo = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 11, timestamp: 1.2, hipOffset: 0.20,
                           shoulderDeltaY: 0.010, limitedShoulders: true),
            face: face(sampleID: 11, timestamp: 1.2, contextKey: context.key), context: context
        )
        _ = qualityEvaluator.consume(geometry: limitedFrameOne,
                                     face: face(sampleID: 10, timestamp: 0.6, contextKey: context.key),
                                     baseline: baseline, now: 0.6)
        let limitedPersisted = qualityEvaluator.consume(
            geometry: limitedFrameTwo,
            face: face(sampleID: 11, timestamp: 1.2, contextKey: context.key),
            baseline: baseline, now: 1.2
        )
        expect(!limitedPersisted.torsoInclination.isAttention &&
               !limitedPersisted.shoulderSlope.isAttention,
               "des repères partials persistants ne doivent jamais avancer la décision")
        let validRecoveryOne = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 12, timestamp: 1.8, hipOffset: 0.20,
                           shoulderDeltaY: 0.010),
            face: face(sampleID: 12, timestamp: 1.8, contextKey: context.key), context: context
        )
        _ = qualityEvaluator.consume(
            geometry: validRecoveryOne,
            face: face(sampleID: 12, timestamp: 1.8, contextKey: context.key),
            baseline: baseline, now: 1.8
        )
        let validRecoveryTwo = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 13, timestamp: 2.4, hipOffset: 0.20,
                           shoulderDeltaY: 0.010),
            face: face(sampleID: 13, timestamp: 2.4, contextKey: context.key), context: context
        )
        let recoveredEvaluation = qualityEvaluator.consume(
            geometry: validRecoveryTwo,
            face: face(sampleID: 13, timestamp: 2.4, contextKey: context.key),
            baseline: baseline, now: 2.4
        )
        expect(recoveredEvaluation.torsoInclination.isAttention &&
               recoveredEvaluation.shoulderSlope.isAttention,
               "après retour de points good la persistance peut reprendre")

        var tenHzEvaluatorConfiguration = configuration
        tenHzEvaluatorConfiguration.blinkTargetPerMinute = 20
        tenHzEvaluatorConfiguration.blinkLowRateFraction = 0.70
        // Fixture raccourcie : le contrat produit reste cinq minutes.
        tenHzEvaluatorConfiguration.blinkLowRateDuration = 0.3
        tenHzEvaluatorConfiguration.blinkMinimumObservable = 0
        tenHzEvaluatorConfiguration.blinkRecoveryDuration = 0.3
        tenHzEvaluatorConfiguration.blinkMaximumSuspension = 1.0
        var tenHzEvaluator = PostureRichSignalEvaluator(configuration: tenHzEvaluatorConfiguration)
        var tenHzEvaluation: PostureRichEvaluation?
        let slowBody = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 20, timestamp: 0), face: neutralFace, context: context
        )
        for index in 0...4 {
            let timestamp = Double(index) * 0.1
            let faceSample = face(sampleID: UInt64(500 + index), timestamp: timestamp,
                                  contextKey: context.key)
            tenHzEvaluation = tenHzEvaluator.consume(
                geometry: slowBody, face: faceSample, baseline: baseline, now: timestamp
            )
        }
        expect(tenHzEvaluation?.blinkRate.direction == .below &&
               tenHzEvaluation?.blinkRate.normalizedValue == 0 &&
               (tenHzEvaluation?.blinkRate.belowDuration ?? 0) >= 0.3 &&
               tenHzEvaluation?.blinkRate.isAttention == true &&
               (tenHzEvaluation?.blinkRateAssessment.belowDuration ?? 0) > 0.2,
               "les visages 10 Hz doivent fournir direction, ratio et durée sous seuil malgré un corps plus lent")
        let noFaceEvaluation = tenHzEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(sampleID: 21, timestamp: 0.5), face: nil, context: context
            ),
            face: nil, baseline: baseline, now: 0.5
        )
        expect(noFaceEvaluation.blinkRate.normalizedValue == nil &&
               noFaceEvaluation.blinkRate.direction == .unknown,
               "une absence visage doit suspendre le clignement sans republier une valeur héritée")
        let badEyeEvaluation = tenHzEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(sampleID: 22, timestamp: 0.6), face: nil, context: context
            ),
            face: face(sampleID: 22, timestamp: 0.6, contextKey: context.key,
                       eyeOpeningRatio: .nan),
            baseline: baseline, now: 0.6
        )
        expect(badEyeEvaluation.blinkRate.normalizedValue == nil &&
               badEyeEvaluation.blinkRate.quality == .limited,
               "des ratios d'yeux non finis ne sont jamais éligibles")
        let missingPoseProxyEvaluation = tenHzEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(sampleID: 23, timestamp: 0.7), face: nil, context: context
            ),
            face: face(sampleID: 23, timestamp: 0.7, contextKey: context.key,
                       yawProxy: nil, eyeLineRollDegrees: nil),
            baseline: baseline, now: 0.7
        )
        expect(missingPoseProxyEvaluation.blinkRate.state == .partial &&
               missingPoseProxyEvaluation.blinkRate.direction == .unknown &&
               !missingPoseProxyEvaluation.blinkRate.isAttention,
               "yaw/roll absents rendent le clignement partial, jamais attentif")

        let leaned = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 2, timestamp: 0.6, hipOffset: 0.20),
            face: face(sampleID: 2, timestamp: 0.6, contextKey: context.key),
            context: context
        )
        let pending = evaluator.consume(
            geometry: leaned,
            face: face(sampleID: 2, timestamp: 0.6, contextKey: context.key),
            baseline: baseline,
            now: 0.6
        )
        expect(!pending.torsoInclination.isAttention,
               "une inclinaison instantanée reste en attente")
        let sustained = evaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(sampleID: 3, timestamp: 1.2, hipOffset: 0.20),
                face: face(sampleID: 3, timestamp: 1.2, contextKey: context.key),
                context: context
            ),
            face: face(sampleID: 3, timestamp: 1.2, contextKey: context.key),
            baseline: baseline,
            now: 1.2
        )
        expect(sustained.torsoInclination.isAttention,
               "l'inclinaison persistante franchit l'hystérésis")

        // Cadences mixtes : un corps à 2 Hz doit progresser indépendamment
        // des cinq ticks visage 10 Hz intercalés. Les ticks visage peuvent
        // republier l'état corporel frais, mais ne le font jamais avancer.
        var mixedConfiguration = configuration
        mixedConfiguration.requiredDuration = 1.0
        mixedConfiguration.bodyTTL = 1.20
        var mixedEvaluator = PostureRichSignalEvaluator(configuration: mixedConfiguration)
        let mixedBodyStart = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 1, timestamp: 0, hipOffset: 0.20),
            face: neutralFace, context: context
        )
        _ = mixedEvaluator.consumeBody(geometry: mixedBodyStart, baseline: baseline, now: 0)
        var faceOnlyLast: PostureRichEvaluation?
        for index in 1...5 {
            let timestamp = Double(index) * 0.1
            faceOnlyLast = mixedEvaluator.consumeFace(
                face: face(sampleID: UInt64(1000 + index), timestamp: timestamp,
                           contextKey: context.key),
                baseline: baseline, now: timestamp
            )
            expect(faceOnlyLast?.torsoInclination.state == .available &&
                   faceOnlyLast?.torsoInclination.isAttention == false,
                   "les ticks visage seuls ne doivent pas avancer l'attention torse")
        }
        _ = mixedEvaluator.consumeBody(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(sampleID: 7, timestamp: 0.6, hipOffset: 0.20),
                face: neutralFace, context: context
            ), baseline: baseline, now: 0.6
        )
        for index in 7...11 {
            let timestamp = Double(index) * 0.1
            faceOnlyLast = mixedEvaluator.consumeFace(
                face: face(sampleID: UInt64(1000 + index), timestamp: timestamp,
                           contextKey: context.key),
                baseline: baseline, now: timestamp
            )
            expect(faceOnlyLast?.torsoInclination.isAttention == false,
                   "la cadence visage ne doit pas raccourcir la persistance corporelle")
        }
        let mixedSustained = mixedEvaluator.consumeBody(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(sampleID: 13, timestamp: 1.2, hipOffset: 0.20),
                face: neutralFace, context: context
            ), baseline: baseline, now: 1.2
        )
        expect(mixedSustained.torsoInclination.isAttention,
               "les échantillons corps 2 Hz doivent atteindre la durée requise")
        let cachedBodyOnFace = mixedEvaluator.consumeFace(
            face: face(sampleID: 1013, timestamp: 1.3, contextKey: context.key),
            baseline: baseline, now: 1.3
        )
        expect(cachedBodyOnFace.torsoInclination.isAttention,
               "un tick visage doit republier l'attention corps encore fraîche")
        let expiredBody = mixedEvaluator.consumeFace(
            face: face(sampleID: 1014, timestamp: 2.5, contextKey: context.key),
            baseline: baseline, now: 2.5
        )
        expect(expiredBody.torsoInclination.state == .unavailable &&
               !expiredBody.torsoInclination.isAttention,
               "l'expiration TTL doit effacer l'attention corporelle")

        var invalidationEvaluator = PostureRichSignalEvaluator(configuration: mixedConfiguration)
        _ = invalidationEvaluator.consumeFace(
            face: face(sampleID: 1100, timestamp: 0, contextKey: context.key),
            baseline: baseline, now: 0
        )
        _ = invalidationEvaluator.consumeBody(geometry: mixedBodyStart, baseline: baseline, now: 0)
        let invalidated = invalidationEvaluator.invalidateBody(
            generation: 1, contextKey: context.key, sampleID: 1101,
            capturedAt: 0.1, now: 0.1, reason: "noPerson"
        )
        expect(invalidated.torsoInclination.state == .unavailable &&
               invalidated.proximity.state == .available &&
               !invalidated.torsoInclination.isAttention,
               "invalidateBody efface le corps sans effacer un visage frais")

        var nilGeometryEvaluator = PostureRichSignalEvaluator(configuration: mixedConfiguration)
        _ = nilGeometryEvaluator.consumeBody(geometry: mixedBodyStart, baseline: baseline, now: 0)
        let nilGeometryFaceTick = nilGeometryEvaluator.consume(
            geometry: nil,
            face: face(sampleID: 1200, timestamp: 0.1, contextKey: context.key),
            baseline: baseline, now: 0.1
        )
        expect(nilGeometryFaceTick.torsoInclination.state == .available,
               "geometry nil sur un tick visage n'est pas un noPerson implicite")

        var staleInvalidationEvaluator = PostureRichSignalEvaluator(configuration: mixedConfiguration)
        _ = staleInvalidationEvaluator.consumeBody(geometry: mixedBodyStart, baseline: baseline, now: 0)
        let staleInvalidation = staleInvalidationEvaluator.invalidateBody(
            generation: 1, contextKey: context.key, sampleID: 1199,
            capturedAt: -0.1, now: 0.1, reason: "old noPerson"
        )
        expect(staleInvalidation.torsoInclination.reason.contains("ancienne"),
               "une invalidation corps ancienne doit être inerte")
        let retainedAfterStaleInvalidation = staleInvalidationEvaluator.consumeFace(
            face: face(sampleID: 1201, timestamp: 0.1, contextKey: context.key),
            baseline: baseline, now: 0.1
        )
        expect(retainedAfterStaleInvalidation.torsoInclination.state == .available,
               "une invalidation corps ancienne ne doit pas effacer le cache frais")

        var contextBFaceSamples: [PostureRichGeometryMetrics] = []
        for index in 0..<12 {
            let sampleID = UInt64(1300 + index)
            let timestamp = Double(index) * 0.1
            let sample = PostureRichGeometryEvaluator.make(
                result: result(sampleID: sampleID, timestamp: timestamp),
                face: face(sampleID: sampleID, timestamp: timestamp,
                           contextKey: contextB.key), context: contextB
            )
            contextBFaceSamples.append(sample)
        }
        let contextBFaceBaseline = PostureRichBaselineBuilder.make(
            samples: contextBFaceSamples, generation: 1, contextKey: contextB.key
        )
        var mismatchEvaluator = PostureRichSignalEvaluator(configuration: mixedConfiguration)
        _ = mismatchEvaluator.consumeBody(geometry: neutral, baseline: baseline, now: 0)
        let mismatchedFace = mismatchEvaluator.consumeFace(
            face: face(sampleID: 1400, timestamp: 0.1, contextKey: contextB.key),
            baseline: contextBFaceBaseline, now: 0.1
        )
        expect(mismatchedFace.shoulderOpening.state == PostureRichSignalState.unavailable &&
               mismatchedFace.shoulderOpening.reason.contains("appariés") &&
               mismatchedFace.torsoInclination.state == PostureRichSignalState.available &&
               mismatchedFace.proximity.state == PostureRichSignalState.available,
               "un contexte visage différent interdit la fusion mais conserve les sources séparées")

        var strongSlopeEvaluator = PostureRichSignalEvaluator(configuration: configuration)
        _ = strongSlopeEvaluator.consume(geometry: neutral, face: neutralFace,
                                         baseline: baseline, now: 0)
        let strongSlopeAtPointOne = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 97, timestamp: 0.6, rightShoulderDeltaY: 0.20),
            face: rotatedFaceFromPolylines(
                generation: 1, sampleID: 97, timestamp: 0.6,
                context: context, cameraRollDegrees: 8
            ),
            context: context
        )
        _ = strongSlopeEvaluator.consume(
            geometry: strongSlopeAtPointOne,
            face: rotatedFaceFromPolylines(
                generation: 1, sampleID: 97, timestamp: 0.6,
                context: context, cameraRollDegrees: 8
            ),
            baseline: baseline, now: 0.6
        )
        let strongSlopeAtPointTwo = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 98, timestamp: 1.2, rightShoulderDeltaY: 0.20),
            face: rotatedFaceFromPolylines(
                generation: 1, sampleID: 98, timestamp: 1.2,
                context: context, cameraRollDegrees: 8
            ),
            context: context
        )
        let strongSlopeEvaluation = strongSlopeEvaluator.consume(
            geometry: strongSlopeAtPointTwo,
            face: rotatedFaceFromPolylines(
                generation: 1, sampleID: 98, timestamp: 1.2,
                context: context, cameraRollDegrees: 8
            ),
            baseline: baseline, now: 1.2
        )
        expect(strongSlopeEvaluation.shoulderSlope.state == .available &&
               strongSlopeEvaluation.shoulderSlope.quality == .good &&
               (strongSlopeEvaluation.shoulderSlope.value ?? 0) > 15 &&
               strongSlopeEvaluation.shoulderSlope.isAttention,
               "une forte pente doit franchir l'évaluateur après sa durée de maintien")

        var slopeEvaluator = PostureRichSignalEvaluator(configuration: configuration)
        _ = slopeEvaluator.consume(geometry: neutral, face: neutralFace,
                                   baseline: baseline, now: 0)
        let slightSlope = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 4, timestamp: 0.6, rightShoulderDeltaY: 0.010),
            face: face(sampleID: 4, timestamp: 0.6, contextKey: context.key), context: context
        )
        let slightPending = slopeEvaluator.consume(
            geometry: slightSlope,
            face: face(sampleID: 4, timestamp: 0.6, contextKey: context.key),
            baseline: baseline, now: 0.6
        )
        expect(!slightPending.shoulderSlope.isAttention,
               "une petite asymétrie isolée reste en attente")
        let slightSustained = slopeEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(sampleID: 5, timestamp: 1.2, rightShoulderDeltaY: 0.010),
                face: face(sampleID: 5, timestamp: 1.2, contextKey: context.key), context: context
            ),
            face: face(sampleID: 5, timestamp: 1.2, contextKey: context.key),
            baseline: baseline, now: 1.2
        )
        expect(slightSustained.shoulderSlope.isAttention,
               "une asymétrie signée durable doit être détectée en profil sensible")
        var negativeSlopeEvaluator = PostureRichSignalEvaluator(configuration: configuration)
        _ = negativeSlopeEvaluator.consume(geometry: neutral, face: neutralFace,
                                           baseline: baseline, now: 0)
        let negativeSlopeOne = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 30, timestamp: 0.6, rightShoulderDeltaY: -0.010),
            face: face(sampleID: 30, timestamp: 0.6, contextKey: context.key), context: context
        )
        _ = negativeSlopeEvaluator.consume(
            geometry: negativeSlopeOne,
            face: face(sampleID: 30, timestamp: 0.6, contextKey: context.key),
            baseline: baseline, now: 0.6
        )
        let negativeSlopeTwo = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 31, timestamp: 1.2, rightShoulderDeltaY: -0.010),
            face: face(sampleID: 31, timestamp: 1.2, contextKey: context.key), context: context
        )
        let negativeSustained = negativeSlopeEvaluator.consume(
            geometry: negativeSlopeTwo,
            face: face(sampleID: 31, timestamp: 1.2, contextKey: context.key),
            baseline: baseline, now: 1.2
        )
        expect(negativeSustained.shoulderSlope.value ?? 0 < 0 &&
               negativeSustained.shoulderSlope.isAttention,
               "une asymétrie durable côté opposé conserve le signe et la détection")
        var leftOnlySlopeEvaluator = PostureRichSignalEvaluator(configuration: configuration)
        _ = leftOnlySlopeEvaluator.consume(geometry: neutral, face: neutralFace,
                                            baseline: baseline, now: 0)
        _ = leftOnlySlopeEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(sampleID: 32, timestamp: 0.6,
                               leftShoulderDeltaY: -0.010),
                face: face(sampleID: 32, timestamp: 0.6, contextKey: context.key), context: context
            ),
            face: face(sampleID: 32, timestamp: 0.6, contextKey: context.key),
            baseline: baseline, now: 0.6
        )
        let leftOnlySustained = leftOnlySlopeEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(sampleID: 33, timestamp: 1.2,
                               leftShoulderDeltaY: -0.010),
                face: face(sampleID: 33, timestamp: 1.2, contextKey: context.key), context: context
            ),
            face: face(sampleID: 33, timestamp: 1.2, contextKey: context.key),
            baseline: baseline, now: 1.2
        )
        expect(leftOnlySustained.shoulderSlope.value ?? 0 > 0 &&
               leftOnlySustained.shoulderSlope.isAttention,
               "une élévation durable de l'épaule gauche seule reste détectable")

        var alternatingSlopeEvaluator = PostureRichSignalEvaluator(configuration: configuration)
        _ = alternatingSlopeEvaluator.consume(geometry: neutral, face: neutralFace,
                                              baseline: baseline, now: 0)
        for (index, sample) in [(40, 0.010), (41, -0.010), (42, 0.010)] {
            let timestamp = Double(index - 39) * 0.6
            let frame = PostureRichGeometryEvaluator.make(
                result: result(sampleID: UInt64(index), timestamp: timestamp,
                               rightShoulderDeltaY: sample),
                face: face(sampleID: UInt64(index), timestamp: timestamp,
                           contextKey: context.key), context: context
            )
            let evaluation = alternatingSlopeEvaluator.consume(
                geometry: frame,
                face: face(sampleID: UInt64(index), timestamp: timestamp,
                           contextKey: context.key), baseline: baseline, now: timestamp
            )
            expect(!evaluation.shoulderSlope.isAttention,
                   "une oscillation de signe ne doit pas devenir une asymétrie persistante")
        }

        let sensitiveConfiguration = PostureRichSignalConfiguration.sensitive
        expect(sensitiveConfiguration.shoulderSlopeEnterDegrees == 0.65 &&
               sensitiveConfiguration.shoulderSlopeExitDegrees == 0.35 &&
               sensitiveConfiguration.shoulderSlopeRequiredDuration == 1.0 &&
               sensitiveConfiguration.requiredDuration == 0.8 &&
               sensitiveConfiguration.blinkPauseReminderAfter == 15,
               "le profil sensible doit accélérer le rappel pratique sans toucher à la CV")
        var sensitiveEvaluator = PostureRichSignalEvaluator(
            configuration: sensitiveConfiguration
        )
        _ = sensitiveEvaluator.consume(geometry: neutral, face: neutralFace,
                                       baseline: baseline, now: 0)
        for (sampleID, timestamp) in [(150, 0.5), (151, 1.0)] {
            let frame = PostureRichGeometryEvaluator.make(
                result: result(sampleID: UInt64(sampleID), timestamp: timestamp,
                               rightShoulderDeltaY: 0.010),
                face: face(sampleID: UInt64(sampleID), timestamp: timestamp,
                           contextKey: context.key), context: context
            )
            _ = sensitiveEvaluator.consume(
                geometry: frame,
                face: face(sampleID: UInt64(sampleID), timestamp: timestamp,
                           contextKey: context.key), baseline: baseline, now: timestamp
            )
        }
        let sensitiveSustained = sensitiveEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(sampleID: 152, timestamp: 1.5,
                               rightShoulderDeltaY: 0.010),
                face: face(sampleID: 152, timestamp: 1.5,
                           contextKey: context.key), context: context
            ),
            face: face(sampleID: 152, timestamp: 1.5, contextKey: context.key),
            baseline: baseline, now: 1.5
        )
        expect(sensitiveSustained.shoulderSlope.isAttention,
               "une asymétrie durable doit rester détectable après le léger filtre")
        var raisedEvaluator = PostureRichSignalEvaluator(configuration: configuration)
        _ = raisedEvaluator.consume(geometry: neutral, face: neutralFace,
                                    baseline: baseline, now: 0)
        let rightRaisedFrame = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 34, timestamp: 0.6, rightShoulderDeltaY: -0.030),
            face: face(sampleID: 34, timestamp: 0.6, contextKey: context.key), context: context
        )
        _ = raisedEvaluator.consume(
            geometry: rightRaisedFrame,
            face: face(sampleID: 34, timestamp: 0.6, contextKey: context.key),
            baseline: baseline, now: 0.6
        )
        let rightRaisedSustained = raisedEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(sampleID: 35, timestamp: 1.2, rightShoulderDeltaY: -0.030),
                face: face(sampleID: 35, timestamp: 1.2, contextKey: context.key), context: context
            ),
            face: face(sampleID: 35, timestamp: 1.2, contextKey: context.key),
            baseline: baseline, now: 1.2
        )
        expect((rightRaisedSustained.shouldersRaised.value ?? 0) > 0 &&
               rightRaisedSustained.shouldersRaised.isAttention &&
               rightRaisedSustained.shouldersRaised.shoulderRaiseClassification == .unilateralRight &&
               abs(rightRaisedSustained.shouldersRaised.leftShoulderDelta ?? 99) < 0.001 &&
               (rightRaisedSustained.shouldersRaised.rightShoulderDelta ?? 0) >
                   configuration.shoulderElevationEnterDelta,
               "une seule épaule droite relevée expose ses valeurs et reste détectable")

        var bilateralRaisedEvaluator = PostureRichSignalEvaluator(configuration: configuration)
        _ = bilateralRaisedEvaluator.consume(geometry: neutral, face: neutralFace,
                                             baseline: baseline, now: 0)
        let bilateralRaisedOne = PostureRichGeometryEvaluator.make(
            result: result(sampleID: 36, timestamp: 0.6,
                           leftShoulderDeltaY: -0.030, rightShoulderDeltaY: -0.030),
            face: face(sampleID: 36, timestamp: 0.6, contextKey: context.key), context: context
        )
        _ = bilateralRaisedEvaluator.consume(
            geometry: bilateralRaisedOne,
            face: face(sampleID: 36, timestamp: 0.6, contextKey: context.key),
            baseline: baseline, now: 0.6
        )
        let bilateralRaisedSustained = bilateralRaisedEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(sampleID: 37, timestamp: 1.2,
                               leftShoulderDeltaY: -0.030, rightShoulderDeltaY: -0.030),
                face: face(sampleID: 37, timestamp: 1.2, contextKey: context.key), context: context
            ),
            face: face(sampleID: 37, timestamp: 1.2, contextKey: context.key),
            baseline: baseline, now: 1.2
        )
        expect(bilateralRaisedSustained.shouldersRaised.isAttention &&
               bilateralRaisedSustained.shouldersRaised.shoulderRaiseClassification == .bilateral &&
               (bilateralRaisedSustained.shouldersRaised.leftShoulderDelta ?? 0) >
                   configuration.shoulderElevationEnterDelta &&
               (bilateralRaisedSustained.shouldersRaised.rightShoulderDelta ?? 0) >
                   configuration.shoulderElevationEnterDelta,
               "deux épaules relevées sont classées bilatérales")

        var jumpConfiguration = configuration
        jumpConfiguration.shoulderElevationMaximumStep = 0.15
        var jumpEvaluator = PostureRichSignalEvaluator(configuration: jumpConfiguration)
        _ = jumpEvaluator.consume(geometry: neutral, face: neutralFace,
                                  baseline: baseline, now: 0)
        let jumped = jumpEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(sampleID: 38, timestamp: 0.6, rightShoulderDeltaY: -0.20),
                face: face(sampleID: 38, timestamp: 0.6, contextKey: context.key), context: context
            ),
            face: face(sampleID: 38, timestamp: 0.6, contextKey: context.key),
            baseline: baseline, now: 0.6
        )
        expect(jumped.shouldersRaised.value == nil &&
               jumped.shouldersRaised.quality == .limited &&
               jumped.shouldersRaised.state == .error &&
               jumped.shouldersRaised.shoulderRaiseClassification == .unavailable &&
               jumped.shouldersRaised.reason.contains("saut") &&
               !jumped.shouldersRaised.isAttention,
               "un saut d'élévation est rejeté sans ouvrir une attention")
        let recoveredAfterJumpOne = jumpEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(sampleID: 39, timestamp: 1.2, rightShoulderDeltaY: -0.030),
                face: face(sampleID: 39, timestamp: 1.2, contextKey: context.key), context: context
            ),
            face: face(sampleID: 39, timestamp: 1.2, contextKey: context.key),
            baseline: baseline, now: 1.2
        )
        let recoveredAfterJumpTwo = jumpEvaluator.consume(
            geometry: PostureRichGeometryEvaluator.make(
                result: result(sampleID: 40, timestamp: 1.8, rightShoulderDeltaY: -0.030),
                face: face(sampleID: 40, timestamp: 1.8, contextKey: context.key), context: context
            ),
            face: face(sampleID: 40, timestamp: 1.8, contextKey: context.key),
            baseline: baseline, now: 1.8
        )
        expect(!recoveredAfterJumpOne.shouldersRaised.isAttention &&
               recoveredAfterJumpTwo.shouldersRaised.isAttention &&
               recoveredAfterJumpTwo.shouldersRaised.shoulderRaiseClassification == .unilateralRight,
               "le signal reprend après deux échantillons cohérents suivant le saut")
        let stale = evaluator.consume(
            geometry: leaned,
            face: face(sampleID: 6, timestamp: 0.7, contextKey: context.key),
            baseline: baseline, now: 1.3
        )
        expect(stale.torsoInclination.state == .unavailable &&
               stale.torsoInclination.reason.contains("ancien"),
               "un timestamp ancien est rejeté sans réécrire l'état")

        var blink = PostureBlinkTracker()
        expect(blink.consume(generation: 1, timestamp: 0,
                             openingRatio: 1.0, qualityGood: true,
                             configuration: configuration) == nil,
               "l'état open initial ne produit pas d'événement")
        expect(blink.consume(generation: 1, timestamp: 0.10,
                             openingRatio: 0.30, qualityGood: true,
                             configuration: configuration) == nil,
               "la fermeture ne produit pas encore l'événement")
        let event = blink.consume(generation: 1, timestamp: 0.20,
                                  openingRatio: 1.0, qualityGood: true,
                                  configuration: configuration)
        expect(event.map { abs($0.duration - 0.10) < 0.001 } == true && blink.events.count == 1,
               "un cycle open-closed-open compte un seul clignement")
        let observedBeforeGap = blink.observableSeconds
        _ = blink.consume(generation: 1, timestamp: 1.0,
                          openingRatio: 1.0, qualityGood: false,
                          configuration: configuration)
        _ = blink.consume(generation: 1, timestamp: 1.8,
                          openingRatio: 1.0, qualityGood: true,
                          configuration: configuration)
        expect(blink.observableSeconds <= observedBeforeGap + 0.01,
               "un trou de qualité ne gonfle pas le dénominateur facial")
        var blinkWithShortGap = PostureBlinkTracker()
        _ = blinkWithShortGap.consume(generation: 1, timestamp: 0,
                                      openingRatio: 1.0, qualityGood: true,
                                      configuration: configuration)
        _ = blinkWithShortGap.consume(generation: 1, timestamp: 0.1,
                                      openingRatio: 1.0, qualityGood: false,
                                      configuration: configuration)
        _ = blinkWithShortGap.consume(generation: 1, timestamp: 0.2,
                                      openingRatio: 1.0, qualityGood: true,
                                      configuration: configuration)
        expect(blinkWithShortGap.observableSeconds < 0.001,
               "la durée entre deux observations séparées par un trou reste inconnue")

        var blinkAtTenHz = PostureBlinkTracker()
        for index in 0...10 {
            let timestamp = Double(index) * 0.1
            _ = blinkAtTenHz.consume(generation: 1, timestamp: timestamp,
                                     openingRatio: 1.0, qualityGood: true,
                                     configuration: configuration)
        }
        expect(abs(blinkAtTenHz.observableSeconds - 1.0) < 0.001,
               "à 10 Hz le dénominateur suit uniquement les intervalles visage valides")
        _ = blinkAtTenHz.consume(generation: 1, timestamp: 1.1,
                                 openingRatio: 0.30, qualityGood: true,
                                 configuration: configuration)
        let tenHzBlink = blinkAtTenHz.consume(generation: 1, timestamp: 1.2,
                                              openingRatio: 1.0, qualityGood: true,
                                              configuration: configuration)
        expect(tenHzBlink.map { abs($0.duration - 0.1) < 0.001 } == true,
               "à 10 Hz un cycle fermé-ouvert conserve sa durée réelle")

        var rollingRateConfiguration = configuration
        rollingRateConfiguration.blinkWindow = 1.0
        var rollingRateBlink = PostureBlinkTracker()
        for index in 0...11 {
            _ = rollingRateBlink.consume(
                generation: 1, timestamp: Double(index) * 0.1,
                openingRatio: 1.0, qualityGood: true,
                configuration: rollingRateConfiguration
            )
        }
        let completedRollingWindow = rollingRateBlink.takeCompletedWindow()
        expect(completedRollingWindow?.observableSeconds ?? 0 > 0.9,
               "la fenêtre de référence terminée conserve sa durée observée")
        expect(rollingRateBlink.observableSeconds < 0.2 &&
               rollingRateBlink.liveObservableSeconds > 0.9 &&
               rollingRateBlink.ratePerMinute != nil,
               "le débit live reste mature après le renouvellement de la fenêtre de référence")

        var interruptedRateConfiguration = rollingRateConfiguration
        interruptedRateConfiguration.blinkMaximumGap = 0.25
        interruptedRateConfiguration.blinkMaximumSuspension = 2.0
        var interruptedRateBlink = PostureBlinkTracker()
        for index in 0...10 {
            _ = interruptedRateBlink.consume(
                generation: 1, timestamp: Double(index) * 0.1,
                openingRatio: 1.0, qualityGood: true,
                configuration: interruptedRateConfiguration
            )
        }
        _ = interruptedRateBlink.consume(
            generation: 1, timestamp: 1.1,
            openingRatio: 1.0, qualityGood: false,
            configuration: interruptedRateConfiguration
        )
        _ = interruptedRateBlink.consume(
            generation: 1, timestamp: 1.7,
            openingRatio: 1.0, qualityGood: true,
            configuration: interruptedRateConfiguration
        )
        for index in 18...27 {
            _ = interruptedRateBlink.consume(
                generation: 1, timestamp: Double(index) * 0.1,
                openingRatio: 1.0, qualityGood: true,
                configuration: interruptedRateConfiguration
            )
        }
        expect(interruptedRateBlink.liveObservableSeconds > 0.9 &&
               interruptedRateBlink.ratePerMinute != nil,
               "une interruption faciale moyenne conserve le débit valide sans compter le trou")

        var suspendedRateBlink = PostureBlinkTracker()
        _ = suspendedRateBlink.consume(
            generation: 1, timestamp: 0,
            openingRatio: 1.0, qualityGood: true,
            configuration: interruptedRateConfiguration
        )
        _ = suspendedRateBlink.consume(
            generation: 1, timestamp: 0.1,
            openingRatio: 1.0, qualityGood: true,
            configuration: interruptedRateConfiguration
        )
        _ = suspendedRateBlink.consume(
            generation: 1, timestamp: 3.0,
            openingRatio: 1.0, qualityGood: true,
            configuration: interruptedRateConfiguration
        )
        expect(suspendedRateBlink.liveObservableSeconds < 0.001 &&
               suspendedRateBlink.ratePerMinute == nil,
               "les secondes live trop anciennes doivent sortir naturellement de la fenêtre")

        var interruptedEvaluatorConfiguration = configuration
        interruptedEvaluatorConfiguration.blinkWindow = 10
        interruptedEvaluatorConfiguration.blinkMinimumObservable = 5
        interruptedEvaluatorConfiguration.blinkMaximumGap = 0.25
        interruptedEvaluatorConfiguration.blinkMaximumSuspension = 2
        var interruptedEvaluator = PostureRichSignalEvaluator(
            configuration: interruptedEvaluatorConfiguration
        )
        var interruptedEvaluation: PostureRichEvaluation?
        for index in 0...10 {
            let timestamp = Double(index) * 0.1
            interruptedEvaluation = interruptedEvaluator.consume(
                geometry: automaticBody,
                face: face(sampleID: UInt64(2000 + index), timestamp: timestamp,
                           contextKey: context.key),
                baseline: baseline, now: timestamp
            )
        }
        let interruptedQualityEvaluation = interruptedEvaluator.consume(
            geometry: automaticBody,
            face: face(sampleID: 2011, timestamp: 1.1,
                       contextKey: context.key, facePointCount: 12),
            baseline: baseline, now: 1.1
        )
        expect(interruptedQualityEvaluation.blinkRate.state == .partial &&
               interruptedQualityEvaluation.blinkRate.reason == "Suivi des yeux intermittent",
               "une qualité faciale insuffisante expose une raison courte et compréhensible")
        let interruptedResumeEvaluation = interruptedEvaluator.consume(
            geometry: automaticBody,
            face: face(sampleID: 2017, timestamp: 1.7,
                       contextKey: context.key),
            baseline: baseline, now: 1.7
        )
        expect(interruptedResumeEvaluation.blinkRate.state == .partial &&
               interruptedResumeEvaluation.blinkRate.reason.hasPrefix("Yeux observés") &&
               interruptedResumeEvaluation.blinkRate.reason.contains("/5 s"),
               "la reprise affiche les secondes valides sans compter l'interruption")
        interruptedEvaluation = interruptedResumeEvaluation
        for index in 17...60 {
            let timestamp = Double(index) * 0.1
            interruptedEvaluation = interruptedEvaluator.consume(
                geometry: automaticBody,
                face: face(sampleID: UInt64(2000 + index), timestamp: timestamp,
                           contextKey: context.key),
                baseline: baseline, now: timestamp
            )
        }
        expect(interruptedEvaluation?.blinkRate.state == .available &&
               interruptedEvaluation?.blinkRate.value != nil &&
               interruptedEvaluation?.blinkRate.reason.contains("insuffisante") == false,
               "après une interruption moyenne, le débit clignement redevient disponible avec les secondes valides cumulées")

        var strictGapConfiguration = configuration
        strictGapConfiguration.blinkMaximumSuspension = 1.0
        var longGapBlink = PostureBlinkTracker()
        _ = longGapBlink.consume(generation: 1, timestamp: 0,
                                 openingRatio: 1.0, qualityGood: true,
                                 configuration: strictGapConfiguration)
        _ = longGapBlink.consume(generation: 1, timestamp: 0.1,
                                 openingRatio: 0.30, qualityGood: true,
                                 configuration: strictGapConfiguration)
        _ = longGapBlink.consume(generation: 1, timestamp: 0.2,
                                 openingRatio: 1.0, qualityGood: true,
                                 configuration: strictGapConfiguration)
        expect(longGapBlink.events.count == 1 && longGapBlink.observableSeconds > 0,
               "la fixture de trou long commence avec un historique réel")
        _ = longGapBlink.consume(generation: 1, timestamp: 1.3,
                                 openingRatio: 1.0, qualityGood: false,
                                 configuration: strictGapConfiguration)
        expect(longGapBlink.events.count == 1 && longGapBlink.observableSeconds > 0,
               "un long trou de qualité casse le cycle sans effacer la fenêtre valide")

        var rearmedEvaluatorConfiguration = configuration
        rearmedEvaluatorConfiguration.blinkTargetPerMinute = 20
        rearmedEvaluatorConfiguration.blinkMinimumObservable = 0
        rearmedEvaluatorConfiguration.blinkWindow = 10
        var rearmedEvaluator = PostureRichSignalEvaluator(
            configuration: rearmedEvaluatorConfiguration
        )
        _ = rearmedEvaluator.consume(
            geometry: automaticBody,
            face: face(sampleID: 3000, timestamp: 0, contextKey: context.key),
            baseline: baseline, now: 0
        )
        _ = rearmedEvaluator.consume(
            geometry: automaticBody,
            face: face(sampleID: 3001, timestamp: 0.1, contextKey: context.key),
            baseline: baseline, now: 0.1
        )
        rearmedEvaluator.resetFaceTarget()
        let rearmedEvaluation = rearmedEvaluator.consume(
            geometry: automaticBody,
            face: face(sampleID: 3002, timestamp: 0.2, contextKey: context.key),
            baseline: baseline, now: 0.2
        )
        expect(rearmedEvaluation.blinkRate.state == .available &&
               rearmedEvaluation.blinkRate.normalizedValue == 0,
               "une réacquisition dans le même contexte doit conserver la cible et les secondes live")

        var learnedReferenceConfiguration = configuration
        learnedReferenceConfiguration.blinkTargetPerMinute = nil
        learnedReferenceConfiguration.blinkWindow = 1
        learnedReferenceConfiguration.blinkMinimumObservable = 0.5
        learnedReferenceConfiguration.blinkReferenceRequiredWindows = 1
        learnedReferenceConfiguration.blinkMaximumGap = 0.25
        learnedReferenceConfiguration.blinkMaximumSuspension = 2
        var learnedReferenceEvaluator = PostureRichSignalEvaluator(
            configuration: learnedReferenceConfiguration
        )
        var learnedReferenceEvaluation: PostureRichEvaluation?
        for index in 0...10 {
            let timestamp = Double(index) * 0.1
            let openingRatio = index == 1 ? 0.15 : 0.30
            learnedReferenceEvaluation = learnedReferenceEvaluator.consume(
                geometry: automaticBody,
                face: face(sampleID: UInt64(3100 + index), timestamp: timestamp,
                           contextKey: context.key, eyeOpeningRatio: openingRatio),
                baseline: baseline, now: timestamp
            )
        }
        expect(learnedReferenceEvaluation?.blinkRate.normalizedValue != nil,
               "la fenêtre de référence doit réellement produire une cible")
        learnedReferenceEvaluator.invalidateFace(
            generation: 1, sampleID: 3111, capturedAt: 1.1
        )
        learnedReferenceEvaluator.resetFaceTarget()
        let learnedReferenceResume = learnedReferenceEvaluator.consume(
            geometry: automaticBody,
            face: face(sampleID: 3112, timestamp: 1.2, contextKey: context.key),
            baseline: baseline, now: 1.2
        )
        expect(learnedReferenceResume.blinkRate.state == .available &&
               learnedReferenceResume.blinkRate.normalizedValue != nil,
               "une perte/reprise ne doit pas effacer la référence personnelle apprise")

        var rateConfiguration = configuration
        rateConfiguration.blinkTargetPerMinute = 20
        rateConfiguration.blinkLowRateFraction = 0.70
        rateConfiguration.blinkLowRateDuration = 0.5
        rateConfiguration.blinkRecoveryDuration = 0.3
        rateConfiguration.blinkMaximumSuspension = 1.0
        var lowRateTracker = PostureBlinkRateTracker()
        var lowRateAssessment = PostureBlinkRateAssessment(
            normalizedValue: nil, direction: .unknown, belowDuration: 0,
            recoveryDuration: 0, quality: .unavailable, reason: "initial"
        )
        for index in 0...5 {
            lowRateAssessment = lowRateTracker.consume(
                generation: 1, sampleID: UInt64(100 + index), timestamp: Double(index) * 0.1,
                normalizedRate: 0.69, eligible: true, configuration: rateConfiguration
            )
        }
        expect(lowRateAssessment.direction == .below &&
               lowRateAssessment.belowDuration >= 0.5,
               "une fréquence à 69% doit rester sous le seuil après la durée de fixture")
        let durationBeforeDuplicate = lowRateAssessment.belowDuration
        let duplicateRate = lowRateTracker.consume(
            generation: 1, sampleID: 105, timestamp: 0.6,
            normalizedRate: 0.69, eligible: true, configuration: rateConfiguration
        )
        expect(abs(duplicateRate.belowDuration - durationBeforeDuplicate) < 0.001,
               "un échantillon répété ne doit pas prolonger l'épisode")
        _ = lowRateTracker.consume(
            generation: 1, sampleID: 106, timestamp: 0.6,
            normalizedRate: nil, eligible: false, configuration: rateConfiguration
        )
        let suspended = lowRateTracker.consume(
            generation: 1, sampleID: 107, timestamp: 1.1,
            normalizedRate: 0.69, eligible: true, configuration: rateConfiguration
        )
        expect(abs(suspended.belowDuration - durationBeforeDuplicate) < 0.001,
               "un trou sous la suspension configurée suspend sans compter sa durée")
        _ = lowRateTracker.consume(
            generation: 1, sampleID: 108, timestamp: 11.2,
            normalizedRate: nil, eligible: false, configuration: rateConfiguration
        )
        let resetAfterGap = lowRateTracker.consume(
            generation: 1, sampleID: 109, timestamp: 11.3,
            normalizedRate: 0.69, eligible: true, configuration: rateConfiguration
        )
        expect(resetAfterGap.belowDuration < 0.001,
               "un trou supérieur à la suspension configurée réinitialise l'épisode")
        let exactThreshold = lowRateTracker.consume(
            generation: 1, sampleID: 110, timestamp: 11.4,
            normalizedRate: 0.70, eligible: true, configuration: rateConfiguration
        )
        expect(exactThreshold.direction == .neutral,
               "la valeur exactement égale au seuil n'est pas sous le seuil")
        var recoveryTracker = PostureBlinkRateTracker()
        for index in 0...5 {
            _ = recoveryTracker.consume(
                generation: 1, sampleID: UInt64(200 + index), timestamp: Double(index) * 0.1,
                normalizedRate: 0.69, eligible: true, configuration: rateConfiguration
            )
        }
        var recovery = PostureBlinkRateAssessment(
            normalizedValue: nil, direction: .unknown, belowDuration: 0,
            recoveryDuration: 0, quality: .unavailable, reason: "initial"
        )
        for index in 6...10 {
            recovery = recoveryTracker.consume(
                generation: 1, sampleID: UInt64(200 + index), timestamp: Double(index) * 0.1,
                normalizedRate: 0.80, eligible: true, configuration: rateConfiguration
            )
        }
        expect(recovery.direction == .neutral && !recoveryTracker.belowEpisodeActive &&
               recoveryTracker.belowDuration < 0.001,
               "la durée de récupération de fixture doit réarmer l'épisode")

        let wallDate = Date(timeIntervalSince1970: 1_724_000_000)
        var statistics = PostureLocalStatistics()
        statistics.record(at: wallDate, attentionEvents: 2,
                          observableSeconds: 30, blinkEvents: 1)
        expect(statistics.counters.count == 3,
               "une observation alimente exactement jour/semaine/mois")
        expect(statistics.counters.values.allSatisfy { $0.attentionEvents == 2 && $0.blinkEvents == 1 },
               "les statistiques restent des compteurs locaux scalaires")

        let confusion = PostureConfusionMatrix.make(
            expected: [false, false, true, true],
            predicted: [false, true, true, false]
        )
        expect(confusion?.trueNegative == 1 && confusion?.truePositive == 1 &&
               confusion?.falsePositive == 1 && confusion?.falseNegative == 1,
               "la matrice fixture doit distinguer TP/TN/FP/FN")

        print("PostureRichSignalHarness: OK")
    }
}
