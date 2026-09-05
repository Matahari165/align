import CoreGraphics
import Foundation

/// Repère commun aux évaluateurs. Les points entrants sont normalisés, dans
/// l'image caméra non miroir et avec l'origine en haut à gauche. Le miroir de
/// l'aperçu ne change jamais l'identité anatomique gauche/droite.
nonisolated enum PostureCameraOrientation: String, Equatable, Sendable {
    case up
}

nonisolated struct PostureFramingContext: Equatable, Sendable {
    /// Identifiant local de la caméra. Il distingue deux périphériques qui
    /// partagent le même format, sans jamais exposer l'identifiant au produit.
    let cameraID: String
    let pixelWidth: Int
    let pixelHeight: Int
    let orientation: PostureCameraOrientation
    let canonicalMirror: Bool
    let normalizedROI: CGRect
    let revision: String

    init?(
        pixelWidth: Int,
        pixelHeight: Int,
        cameraID: String = "default",
        orientation: PostureCameraOrientation = .up,
        canonicalMirror: Bool = false,
        normalizedROI: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        revision: String = "v1"
    ) {
        guard pixelWidth > 0, pixelHeight > 0,
              normalizedROI.origin.x.isFinite, normalizedROI.origin.y.isFinite,
              normalizedROI.width.isFinite, normalizedROI.height.isFinite,
              normalizedROI.minX >= 0, normalizedROI.minY >= 0,
              normalizedROI.maxX <= 1, normalizedROI.maxY <= 1,
              normalizedROI.width > 0, normalizedROI.height > 0,
              !revision.isEmpty, !cameraID.isEmpty else { return nil }
        self.cameraID = cameraID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.orientation = orientation
        self.canonicalMirror = canonicalMirror
        self.normalizedROI = normalizedROI
        self.revision = revision
    }

    var aspectRatio: Double { Double(pixelWidth) / Double(pixelHeight) }

    /// Clé stable pour calibration : caméra/format/orientation/classe de
    /// framing. Le ROI dynamique n'y figure jamais.
    var stableContextKey: String {
        "\(cameraID)-\(pixelWidth)x\(pixelHeight)-\(orientation.rawValue)-\(revision)"
    }

    /// Signature dynamique utile au diagnostic/crop, mais qui ne doit pas
    /// invalider une baseline à elle seule.
    var dynamicROISignature: String {
        [normalizedROI.minX, normalizedROI.minY,
         normalizedROI.width, normalizedROI.height]
            .map { String(format: "%.4f", Double($0)) }
            .joined(separator: ",")
    }

    /// Alias de compatibilité : toute calibration utilise désormais la clé
    /// stable, jamais la signature ROI.
    var key: String { stableContextKey }

    /// Le miroir d'affichage est volontairement exclu de la calibration.
    var calibrationKey: String { stableContextKey }

    /// Les deux composantes sont disponibles séparément pour l'intégrateur.
    var contextDescriptor: String {
        "stable=\(stableContextKey);roi=\(dynamicROISignature)"
    }

    func pixelPoint(_ normalized: CGPoint) -> CGPoint? {
        guard normalized.x.isFinite, normalized.y.isFinite,
              (0...1).contains(normalized.x), (0...1).contains(normalized.y) else {
            return nil
        }
        return CGPoint(
            x: normalized.x * CGFloat(pixelWidth),
            y: normalized.y * CGFloat(pixelHeight)
        )
    }

    func pixelDistance(_ first: CGPoint, _ second: CGPoint) -> Double? {
        guard let lhs = pixelPoint(first), let rhs = pixelPoint(second) else { return nil }
        let dx = Double(rhs.x - lhs.x)
        let dy = Double(rhs.y - lhs.y)
        let value = hypot(dx, dy)
        return value.isFinite && value > 0 ? value : nil
    }
}

nonisolated enum PostureRichSignalKind: String, CaseIterable, Hashable, Sendable {
    case torsoInclination
    case shoulderSlope
    case headTilt
    case shoulderOpening
    case shouldersRaised
    case proximity
    case blinkRate
}

nonisolated enum PostureRichSignalState: String, Equatable, Sendable {
    case available
    case partial
    case unavailable
    case stale
    case error
}

/// Direction relative to a configurable personal baseline. This is a
/// descriptive CV field only; it does not authorize a notification.
nonisolated enum PostureRichSignalDirection: String, Equatable, Sendable {
    case unknown
    case neutral
    case below
    case above
}

/// Classification descriptive de l'élévation des épaules. Elle reste une
/// preuve CV locale : l'arbitrage d'une éventuelle alerte appartient à
/// l'étage produit.
nonisolated enum PostureShoulderRaiseClassification: String, Equatable, Codable, Sendable {
    case unavailable
    case none
    case unilateralLeft
    case unilateralRight
    case bilateral
}

nonisolated struct PostureRichScalarObservation: Equatable, Sendable {
    let kind: PostureRichSignalKind
    let value: Double?
    let state: PostureRichSignalState
    let quality: PostureSignalQuality
    let generation: UInt64
    let sampleID: UInt64
    let capturedAt: TimeInterval
    let isEstimated2DProxy: Bool
    let isAttention: Bool
    let reason: String
    /// Valeur brute transportable vers la couche produit. Elle reste dans
    /// l'unité naturelle du signal (degrés, ratio ou clignements/minute).
    let numericValue: Double?
    /// Écart signé au repère personnel, dans la même unité quand elle existe.
    /// Ce champ reste optionnel : l'absence de baseline n'est jamais remplacée
    /// par un zéro artificiel.
    let referenceDelta: Double?
    let normalizedValue: Double?
    let direction: PostureRichSignalDirection
    /// Durée continue sous le seuil, lorsqu'un évaluateur temporel la fournit.
    /// Elle permet à l'intégrateur de décider d'une alerte sans recalculer les
    /// intervalles; ce snapshot CV n'autorise aucune notification.
    let belowDuration: TimeInterval?
    /// Deltas normalisés par rapport au repère personnel pour le signal
    /// `shouldersRaised`. Les champs restent optionnels pour ne pas imposer
    /// une forme artificielle aux autres observations scalaires.
    let leftShoulderDelta: Double?
    let rightShoulderDelta: Double?
    let shoulderRaiseClassification: PostureShoulderRaiseClassification?

    init(
        kind: PostureRichSignalKind,
        value: Double?,
        state: PostureRichSignalState,
        quality: PostureSignalQuality,
        generation: UInt64,
        sampleID: UInt64,
        capturedAt: TimeInterval,
        isEstimated2DProxy: Bool,
        isAttention: Bool,
        reason: String,
        numericValue: Double? = nil,
        numericValueProvided: Bool = false,
        referenceDelta: Double? = nil,
        normalizedValue: Double? = nil,
        direction: PostureRichSignalDirection = .unknown,
        belowDuration: TimeInterval? = nil,
        leftShoulderDelta: Double? = nil,
        rightShoulderDelta: Double? = nil,
        shoulderRaiseClassification: PostureShoulderRaiseClassification? = nil
    ) {
        self.kind = kind
        self.value = value
        self.state = state
        self.quality = quality
        self.generation = generation
        self.sampleID = sampleID
        self.capturedAt = capturedAt
        self.isEstimated2DProxy = isEstimated2DProxy
        self.isAttention = isAttention
        self.reason = reason
        self.numericValue = numericValueProvided ? numericValue : (numericValue ?? value)
        self.referenceDelta = referenceDelta
        self.normalizedValue = normalizedValue
        self.direction = direction
        self.belowDuration = belowDuration
        self.leftShoulderDelta = leftShoulderDelta
        self.rightShoulderDelta = rightShoulderDelta
        self.shoulderRaiseClassification = shoulderRaiseClassification
    }

    static func unavailable(
        _ kind: PostureRichSignalKind,
        generation: UInt64,
        sampleID: UInt64,
        capturedAt: TimeInterval,
        reason: String,
        state: PostureRichSignalState = .unavailable,
        estimated: Bool = true
    ) -> Self {
        Self(kind: kind, value: nil, state: state, quality: .unavailable,
             generation: generation, sampleID: sampleID, capturedAt: capturedAt,
             isEstimated2DProxy: estimated, isAttention: false, reason: reason)
    }
}

/// Les métriques sont calculées dans une seule sortie RTMPose. Elles ne
/// transportent aucune image ni coordonnée brute.
nonisolated struct PostureRichGeometryMetrics: Equatable, Sendable {
    let generation: UInt64
    let sampleID: UInt64
    let capturedAt: TimeInterval
    let contextKey: String
    let torsoInclinationDegrees: Double?
    /// Ratio dx/|dy| sans unité, conservé pour diagnostic. La décision
    /// utilise exclusivement `torsoInclinationDegrees` et son MAD en degrés.
    let torsoAxisDeviation: Double?
    let shoulderSlopeDegrees: Double?
    /// Différence axiale entre la ligne des yeux et la ligne des épaules.
    /// Les hanches ne sont volontairement pas requises.
    let headTiltDegrees: Double?
    let shoulderOpeningDegrees: Double?
    let shoulderOpeningRatio: Double?
    let leftShoulderElevation: Double?
    let rightShoulderElevation: Double?
    let proximityScale: Double?
    let shouldersState: PostureRichSignalState
    let torsoState: PostureRichSignalState
    let headTiltState: PostureRichSignalState
    /// Qualité du ratio largeur-épaules/taille-visage. Elle ne requiert pas le
    /// cou, contrairement à `openingState` qui décrit l'angle anatomique.
    let openingRatioState: PostureRichSignalState
    let openingState: PostureRichSignalState
    let reason: String?
    /// Ouvertures par œil conservées pour la calibration clignement. Elles
    /// restent absentes si la preuve faciale n'est pas disponible.
    let leftEyeOpeningRatio: Double?
    let rightEyeOpeningRatio: Double?

    init(
        generation: UInt64,
        sampleID: UInt64,
        capturedAt: TimeInterval,
        contextKey: String,
        torsoInclinationDegrees: Double?,
        torsoAxisDeviation: Double?,
        shoulderSlopeDegrees: Double?,
        shoulderOpeningDegrees: Double?,
        shoulderOpeningRatio: Double?,
        leftShoulderElevation: Double?,
        rightShoulderElevation: Double?,
        proximityScale: Double?,
        shouldersState: PostureRichSignalState,
        torsoState: PostureRichSignalState,
        openingState: PostureRichSignalState,
        reason: String?,
        leftEyeOpeningRatio: Double? = nil,
        rightEyeOpeningRatio: Double? = nil,
        headTiltDegrees: Double? = nil,
        headTiltState: PostureRichSignalState = .unavailable,
        openingRatioState: PostureRichSignalState? = nil
    ) {
        self.generation = generation
        self.sampleID = sampleID
        self.capturedAt = capturedAt
        self.contextKey = contextKey
        self.torsoInclinationDegrees = torsoInclinationDegrees
        self.torsoAxisDeviation = torsoAxisDeviation
        self.shoulderSlopeDegrees = shoulderSlopeDegrees
        self.headTiltDegrees = headTiltDegrees
        self.shoulderOpeningDegrees = shoulderOpeningDegrees
        self.shoulderOpeningRatio = shoulderOpeningRatio
        self.leftShoulderElevation = leftShoulderElevation
        self.rightShoulderElevation = rightShoulderElevation
        self.proximityScale = proximityScale
        self.shouldersState = shouldersState
        self.torsoState = torsoState
        self.headTiltState = headTiltState
        self.openingRatioState = openingRatioState ??
            (shoulderOpeningRatio == nil ? .unavailable : openingState)
        self.openingState = openingState
        self.reason = reason
        self.leftEyeOpeningRatio = leftEyeOpeningRatio
        self.rightEyeOpeningRatio = rightEyeOpeningRatio
    }

    static func unavailable(
        generation: UInt64,
        sampleID: UInt64,
        capturedAt: TimeInterval,
        contextKey: String,
        state: PostureRichSignalState = .unavailable,
        reason: String
    ) -> Self {
        Self(generation: generation, sampleID: sampleID, capturedAt: capturedAt,
             contextKey: contextKey, torsoInclinationDegrees: nil,
             torsoAxisDeviation: nil, shoulderSlopeDegrees: nil,
             shoulderOpeningDegrees: nil, shoulderOpeningRatio: nil,
             leftShoulderElevation: nil, rightShoulderElevation: nil,
             proximityScale: nil,
             shouldersState: state, torsoState: state,
             openingState: state,
             reason: reason, leftEyeOpeningRatio: nil,
             rightEyeOpeningRatio: nil, headTiltDegrees: nil, headTiltState: state,
             openingRatioState: state)
    }
}

nonisolated struct PostureFaceObservation: Equatable, Sendable {
    let generation: UInt64
    let sampleID: UInt64
    let capturedAt: TimeInterval
    let facePointCount: Int
    let contextKey: String
    let signal: FaceGeometrySignal

    var faceScale: Double? {
        guard let eye = signal.interocularDistance, let length = signal.faceLength,
              eye > 0, length > 0 else { return nil }
        let value = sqrt(eye * length)
        return value.isFinite ? value : nil
    }
}

nonisolated enum PostureRichGeometryEvaluator {
    static func make(
        result: UpperBodyResult,
        face: PostureFaceObservation? = nil,
        context: PostureFramingContext
    ) -> PostureRichGeometryMetrics {
        guard result.isFreshGeometry, result.generation > 0,
              result.sampleID > 0, result.capturedAt.isFinite else {
            return .unavailable(generation: result.generation, sampleID: result.sampleID,
                                capturedAt: result.capturedAt, contextKey: context.key,
                                state: .stale, reason: "résultat RTMPose non frais")
        }
        let faceMatchesContext = face.map {
            $0.generation == result.generation &&
                $0.contextKey == context.stableContextKey &&
                $0.capturedAt.isFinite &&
                abs($0.capturedAt - result.capturedAt) <=
                    PostureRichSignalConfiguration().maximumFusionSkew
        } ?? true
        let matchedFace = faceMatchesContext ? face : nil

        var points: [UpperBodyLandmarkID: CGPoint] = [:]
        var normalizedPoints: [UpperBodyLandmarkID: CGPoint] = [:]
        var qualityGood: [UpperBodyLandmarkID: Bool] = [:]
        for point in result.points where point.isValid {
            if let pixel = context.pixelPoint(point.location) {
                points[point.id] = pixel
                normalizedPoints[point.id] = point.location
                qualityGood[point.id] = point.quality == .good
            }
        }

        let leftShoulder = points[.leftShoulder]
        let rightShoulder = points[.rightShoulder]
        let neck = points[.neck]
        let leftHip = points[.leftHip]
        let rightHip = points[.rightHip]
        let shoulderCount = [leftShoulder, rightShoulder].compactMap { $0 }.count
        let shouldersState: PostureRichSignalState
        if shoulderCount == 2 && qualityGood[.leftShoulder] == true && qualityGood[.rightShoulder] == true {
            shouldersState = .available
        } else if shoulderCount > 0 {
            shouldersState = .partial
        } else {
            shouldersState = .unavailable
        }

        var torsoInclination: Double?
        var torsoAxisDeviation: Double?
        let torsoState: PostureRichSignalState
        if let leftShoulder, let rightShoulder, let leftHip, let rightHip {
            let shoulderMid = midpoint(leftShoulder, rightShoulder)
            let hipMid = midpoint(leftHip, rightHip)
            let candidateInclination = axialAngleDegrees(
                dx: Double(hipMid.x - shoulderMid.x),
                dy: Double(hipMid.y - shoulderMid.y)
            )
            let dx = Double(hipMid.x - shoulderMid.x)
            let dy = Double(hipMid.y - shoulderMid.y)
            let normalized = dx / max(abs(dy), 0.000001)
            let good = [UpperBodyLandmarkID.leftShoulder, .rightShoulder, .leftHip, .rightHip]
                .allSatisfy { qualityGood[$0] == true }
            // Une inclinaison latérale n'est publiable que si les quatre
            // repères qui forment l'axe sont good. Les coordonnées limited
            // restent disponibles aux diagnostics, mais ne doivent jamais
            // alimenter une décision ni une baseline.
            torsoInclination = good ? candidateInclination : nil
            torsoAxisDeviation = good && normalized.isFinite ? normalized : nil
            torsoState = good && torsoInclination != nil ? .available : .partial
        } else {
            torsoInclination = nil
            torsoAxisDeviation = nil
            let count = [leftShoulder, rightShoulder, leftHip, rightHip]
                .compactMap { $0 }.count
            torsoState = count > 0 ? .partial : .unavailable
        }

        let shoulderSlopeDegrees: Double?
        if let leftShoulder, let rightShoulder {
            let dx = Double(rightShoulder.x - leftShoulder.x)
            let dy = Double(rightShoulder.y - leftShoulder.y)
            guard hypot(dx, dy) > 0 else {
                shoulderSlopeDegrees = nil
                return .unavailable(generation: result.generation, sampleID: result.sampleID,
                                    capturedAt: result.capturedAt, contextKey: context.key,
                                    state: .error, reason: "paire d'épaules dégénérée")
            }
            var angle = atan2(dy, dx) * 180 / .pi
            if angle > 90 { angle -= 180 }
            if angle < -90 { angle += 180 }
            shoulderSlopeDegrees = angle.isFinite ? angle : nil
        } else {
            shoulderSlopeDegrees = nil
        }

        // Une inclinaison relative reste valable lorsque la caméra est elle-
        // même tournée : la rotation commune des yeux et des épaules s'annule.
        // FaceGeometrySignal exprime le roll en coordonnées normalisées tandis
        // que les épaules sont déjà en pixels. La conversion avant soustraction
        // est nécessaire sur un capteur non carré (par exemple 1280x720), sinon
        // un même roulis de caméra produit artificiellement un tilt résiduel.
        let headTiltDegrees: Double?
        if faceMatchesContext,
           let eyeRoll = matchedFace?.signal.eyeLineRollDegrees,
           let eyeRollInPixels = pixelAxialAngleDegrees(eyeRoll, context: context),
           let shoulderSlopeDegrees {
            headTiltDegrees = postureRelativeAxialDifferenceDegrees(
                eyeRollInPixels, shoulderSlopeDegrees
            )
        } else {
            headTiltDegrees = nil
        }
        // Cette qualité est calculée ici car le chemin production peut
        // transporter la géométrie fusionnée sans conserver l'objet visage.
        // Les mêmes minima que l'évaluateur riche empêchent alors une frame
        // faciale pauvre ou hors domaine de devenir une référence de calibration.
        let headTiltFaceEvidence = faceMatchesContext &&
            (matchedFace?.facePointCount ?? 0) >= PostureRichSignalConfiguration().minimumFacePoints &&
            (matchedFace?.signal.yawProxy.map {
                $0.isFinite && abs($0) <= PostureRichSignalConfiguration().maximumYaw
            } ?? false) &&
            (matchedFace?.signal.eyeLineRollDegrees.map {
                $0.isFinite && abs($0) <= PostureRichSignalConfiguration().maximumRollDegrees
            } ?? false)
        let headTiltState: PostureRichSignalState = if headTiltDegrees != nil,
            shouldersState == .available, headTiltFaceEvidence {
            .available
        } else if headTiltFaceEvidence || shoulderCount > 0 {
            .partial
        } else {
            .unavailable
        }

        var openingDegrees: Double?
        if let neck, let leftShoulder, let rightShoulder {
            openingDegrees = angleAt(neck, leftShoulder, rightShoulder)
        }
        let openingState: PostureRichSignalState
        if openingDegrees != nil {
            let good = [UpperBodyLandmarkID.neck, .leftShoulder, .rightShoulder]
                .allSatisfy { qualityGood[$0] == true }
            openingState = good ? .available : .partial
        } else if neck != nil || leftShoulder != nil || rightShoulder != nil {
            openingState = .partial
        } else {
            openingState = .unavailable
        }

        let openingRatio: Double?
        if faceMatchesContext,
           let leftShoulder = normalizedPoints[.leftShoulder],
           let rightShoulder = normalizedPoints[.rightShoulder], let faceScale = matchedFace?.faceScale,
           faceScale > 0 {
            let width = hypot(Double(rightShoulder.x - leftShoulder.x),
                              Double(rightShoulder.y - leftShoulder.y))
            let ratio = width / faceScale
            openingRatio = ratio.isFinite && ratio > 0 ? ratio : nil
        } else {
            openingRatio = nil
        }
        let openingRatioFaceQuality = matchedFace.map {
            $0.facePointCount >= PostureRichSignalConfiguration().minimumFacePoints &&
                ($0.signal.yawProxy.map {
                    $0.isFinite && abs($0) <= PostureRichSignalConfiguration().maximumProximityYaw
                } ?? false) &&
                ($0.signal.eyeLineRollDegrees.map {
                    $0.isFinite && abs($0) <= PostureRichSignalConfiguration().maximumRollDegrees
                } ?? false)
        } ?? false
        let openingRatioState: PostureRichSignalState = if openingRatio != nil,
            shouldersState == .available, openingRatioFaceQuality {
            .available
        } else if openingRatio != nil || matchedFace != nil || shoulderCount > 0 {
            .partial
        } else {
            .unavailable
        }

        // L'élévation est un signal corporel : elle ne doit pas changer si
        // seule la géométrie du visage bouge. La base du cou et la largeur
        // inter-épaules proviennent du même résultat RTMPose et sont converties
        // en pixels pour corriger l'aspect du cadre.
        let shoulderSpan: Double? = {
            guard let leftShoulder, let rightShoulder else { return nil }
            let value = hypot(Double(rightShoulder.x - leftShoulder.x),
                              Double(rightShoulder.y - leftShoulder.y))
            return value.isFinite && value > 0 ? value : nil
        }()
        let leftElevation: Double?
        let rightElevation: Double?
        let elevationLandmarksGood = qualityGood[.neck] == true &&
            qualityGood[.leftShoulder] == true && qualityGood[.rightShoulder] == true
        if elevationLandmarksGood, let neck, let shoulderSpan {
            if let leftShoulder {
                let value = (Double(neck.y) - Double(leftShoulder.y)) / shoulderSpan
                leftElevation = value.isFinite ? value : nil
            } else {
                leftElevation = nil
            }
            if let rightShoulder {
                let value = (Double(neck.y) - Double(rightShoulder.y)) / shoulderSpan
                rightElevation = value.isFinite ? value : nil
            } else {
                rightElevation = nil
            }
        } else {
            leftElevation = nil
            rightElevation = nil
        }

        let reason: String? = if !faceMatchesContext {
            "context visage/corps différent : métriques fusionnées indisponibles"
        } else if result.points.isEmpty {
            "aucun repère RTMPose valide"
        } else {
            nil
        }
        return PostureRichGeometryMetrics(
            generation: result.generation,
            sampleID: result.sampleID,
            capturedAt: result.capturedAt,
            contextKey: context.key,
            torsoInclinationDegrees: torsoInclination,
            torsoAxisDeviation: torsoAxisDeviation,
            shoulderSlopeDegrees: shoulderSlopeDegrees,
            shoulderOpeningDegrees: openingDegrees,
            shoulderOpeningRatio: openingRatio,
            leftShoulderElevation: leftElevation,
            rightShoulderElevation: rightElevation,
            proximityScale: matchedFace?.faceScale,
            shouldersState: shouldersState,
            torsoState: torsoState,
            openingState: openingState,
            reason: reason,
            leftEyeOpeningRatio: matchedFace?.signal.leftEyeOpeningRatio,
            rightEyeOpeningRatio: matchedFace?.signal.rightEyeOpeningRatio,
            headTiltDegrees: headTiltDegrees,
            headTiltState: headTiltState,
            openingRatioState: openingRatioState
        )
    }

    private static func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: (lhs.x + rhs.x) * 0.5, y: (lhs.y + rhs.y) * 0.5)
    }

    private static func axialAngleDegrees(dx: Double, dy: Double) -> Double? {
        // Axe S→B, y vers le bas : 0° est vertical, positif signifie que
        // le milieu des hanches est décalé vers la droite.
        let value = atan2(dx, dy) * 180 / .pi
        guard value.isFinite else { return nil }
        var wrapped = value.truncatingRemainder(dividingBy: 180)
        if wrapped > 90 { wrapped -= 180 }
        if wrapped < -90 { wrapped += 180 }
        return wrapped
    }

    private static func angleAt(_ vertex: CGPoint, _ lhs: CGPoint, _ rhs: CGPoint) -> Double? {
        let a = CGPoint(x: lhs.x - vertex.x, y: lhs.y - vertex.y)
        let b = CGPoint(x: rhs.x - vertex.x, y: rhs.y - vertex.y)
        let normA = hypot(Double(a.x), Double(a.y))
        let normB = hypot(Double(b.x), Double(b.y))
        guard normA > 0, normB > 0 else { return nil }
        let cosine = max(-1, min(1, (Double(a.x) * Double(b.x) + Double(a.y) * Double(b.y)) / (normA * normB)))
        let value = acos(cosine) * 180 / .pi
        return value.isFinite ? value : nil
    }

    private static func finite(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }

    private static func pixelAxialAngleDegrees(
        _ normalizedAngle: Double,
        context: PostureFramingContext
    ) -> Double? {
        guard normalizedAngle.isFinite else { return nil }
        let radians = normalizedAngle * .pi / 180
        let dx = cos(radians) * Double(context.pixelWidth)
        let dy = sin(radians) * Double(context.pixelHeight)
        guard hypot(dx, dy).isFinite, hypot(dx, dy) > 0 else { return nil }
        var value = atan2(dy, dx) * 180 / .pi
        if value > 90 { value -= 180 }
        if value < -90 { value += 180 }
        return value.isFinite ? value : nil
    }
}

/// Différence entre deux orientations axiales (une droite n'a pas de sens
/// gauche/droite propre). Le résultat est toujours borné à [-90°, 90°].
private nonisolated func postureRelativeAxialDifferenceDegrees(
    _ first: Double,
    _ second: Double
) -> Double? {
    guard first.isFinite, second.isFinite else { return nil }
    var wrapped = (first - second).truncatingRemainder(dividingBy: 180)
    if wrapped > 90 { wrapped -= 180 }
    if wrapped < -90 { wrapped += 180 }
    return wrapped.isFinite ? wrapped : nil
}

/// Repère personnel d'ouverture, conservé séparément pour chaque œil. Les
/// MAD rendent la dispersion observable sans imposer une moyenne des yeux.
nonisolated struct PostureBlinkOpeningBaseline: Equatable, Codable, Sendable {
    let leftEyeOpeningRatio: Double
    let rightEyeOpeningRatio: Double
    let leftEyeOpeningMAD: Double?
    let rightEyeOpeningMAD: Double?
    let sampleCount: Int
}

/// Maturité indépendante de chaque famille de calibration.
/// Les anciennes baselines n'ont pas ce champ et restent décodables.
nonisolated struct PostureRichBaselineFamilySampleCounts: Equatable, Codable, Sendable {
    let torso: Int
    let shoulderSlope: Int
    let headTilt: Int
    let shoulderElevation: Int
    let shoulderOpening: Int
    let proximity: Int
    let blinkOpening: Int

    init(
        torso: Int = 0,
        shoulderSlope: Int = 0,
        headTilt: Int = 0,
        shoulderElevation: Int = 0,
        shoulderOpening: Int = 0,
        proximity: Int = 0,
        blinkOpening: Int = 0
    ) {
        self.torso = max(0, torso)
        self.shoulderSlope = max(0, shoulderSlope)
        self.headTilt = max(0, headTilt)
        self.shoulderElevation = max(0, shoulderElevation)
        self.shoulderOpening = max(0, shoulderOpening)
        self.proximity = max(0, proximity)
        self.blinkOpening = max(0, blinkOpening)
    }

    var maximum: Int {
        max(torso, shoulderSlope, headTilt, shoulderElevation, shoulderOpening, proximity, blinkOpening)
    }

    var hasAnyReadyFamily: Bool { maximum > 0 }
}

nonisolated struct PostureRichBaseline: Equatable, Codable, Sendable {
    let generation: UInt64
    let contextKey: String
    let ruleVersion: String
    let torsoInclinationDegrees: Double?
    let torsoAxisDeviation: Double?
    let shoulderSlopeDegrees: Double?
    let headTiltDegrees: Double?
    let shoulderOpeningRatio: Double?
    let leftShoulderElevation: Double?
    let rightShoulderElevation: Double?
    let proximityScale: Double?
    let sampleCount: Int
    let torsoInclinationMAD: Double?
    let torsoAxisMAD: Double?
    let shoulderSlopeMAD: Double?
    let headTiltMAD: Double?
    /// `nil` pour les baselines historiques.
    let familySampleCounts: PostureRichBaselineFamilySampleCounts?
    /// `nil` pour les anciennes baselines ou une calibration sans deux yeux
    /// valides; l'évaluateur conserve alors son fallback de compatibilité.
    let blinkOpeningBaseline: PostureBlinkOpeningBaseline?

    init(
        generation: UInt64,
        contextKey: String,
        ruleVersion: String,
        torsoInclinationDegrees: Double?,
        torsoAxisDeviation: Double?,
        shoulderSlopeDegrees: Double?,
        shoulderOpeningRatio: Double?,
        leftShoulderElevation: Double?,
        rightShoulderElevation: Double?,
        proximityScale: Double?,
        sampleCount: Int,
        torsoInclinationMAD: Double?,
        torsoAxisMAD: Double?,
        shoulderSlopeMAD: Double?,
        blinkOpeningBaseline: PostureBlinkOpeningBaseline? = nil,
        familySampleCounts: PostureRichBaselineFamilySampleCounts? = nil,
        headTiltDegrees: Double? = nil,
        headTiltMAD: Double? = nil
    ) {
        self.generation = generation
        self.contextKey = contextKey
        self.ruleVersion = ruleVersion
        self.torsoInclinationDegrees = torsoInclinationDegrees
        self.torsoAxisDeviation = torsoAxisDeviation
        self.shoulderSlopeDegrees = shoulderSlopeDegrees
        self.headTiltDegrees = headTiltDegrees
        self.shoulderOpeningRatio = shoulderOpeningRatio
        self.leftShoulderElevation = leftShoulderElevation
        self.rightShoulderElevation = rightShoulderElevation
        self.proximityScale = proximityScale
        self.sampleCount = sampleCount
        self.torsoInclinationMAD = torsoInclinationMAD
        self.torsoAxisMAD = torsoAxisMAD
        self.shoulderSlopeMAD = shoulderSlopeMAD
        self.headTiltMAD = headTiltMAD
        self.blinkOpeningBaseline = blinkOpeningBaseline
        self.familySampleCounts = familySampleCounts
    }
}

nonisolated enum PostureRichBaselineBuilder {
    static func make(
        samples: [PostureRichGeometryMetrics],
        faceSamples: [PostureFaceObservation] = [],
        generation: UInt64,
        contextKey: String,
        ruleVersion: String = "rich-v2",
        minimumSamples: Int = 12,
        maximumSampleGap: TimeInterval = 1.50,
        minimumFacePoints: Int = 40,
        maximumProximityYaw: Double = 0.20,
        maximumRollDegrees: Double = 20,
        maximumFusionSkew: TimeInterval = 0.30
    ) -> PostureRichBaseline? {
        guard minimumSamples > 0,
              maximumSampleGap.isFinite, maximumSampleGap > 0,
              minimumFacePoints > 0,
              maximumProximityYaw.isFinite, maximumProximityYaw >= 0,
              maximumRollDegrees.isFinite, maximumRollDegrees >= 0,
              maximumFusionSkew.isFinite, maximumFusionSkew >= 0,
              samples.allSatisfy({ $0.generation == generation && $0.contextKey == contextKey &&
                  $0.capturedAt.isFinite }),
              faceSamples.allSatisfy({ $0.generation == generation &&
                  $0.contextKey == contextKey && $0.capturedAt.isFinite }) else {
            return nil
        }
        // Chaque famille filtre ses propres observations. Une hanche hors
        // champ ne doit donc pas invalider les épaules, mais une suite
        // partielle ou trop espacée ne peut toujours pas devenir une baseline.
        let torsoSamples = coherentSamples(
            samples.filter { $0.torsoState == .available &&
                $0.torsoInclinationDegrees?.isFinite == true },
            maximumSampleGap: maximumSampleGap,
            minimumSamples: minimumSamples
        )
        let shoulderSlopeSamples = coherentSamples(
            samples.filter { $0.shouldersState == .available &&
                $0.shoulderSlopeDegrees?.isFinite == true },
            maximumSampleGap: maximumSampleGap,
            minimumSamples: minimumSamples
        )
        let shoulderElevationSamples = coherentSamples(
            samples.filter { $0.shouldersState == .available &&
                $0.leftShoulderElevation?.isFinite == true &&
                $0.rightShoulderElevation?.isFinite == true },
            maximumSampleGap: maximumSampleGap,
            minimumSamples: minimumSamples
        )
        // Les familles visage peuvent être calibrées sur des ticks visage
        // seuls. Si ces ticks existent, ils sont la source de vérité et évitent
        // de compter deux fois les observations déjà recopiées dans geometry.
        let faceScaleSamples: [(timestamp: TimeInterval, value: Double)]
        let blinkSamples: [(timestamp: TimeInterval, left: Double, right: Double)]
        let validFaceSamples: [PostureFaceObservation]
        if faceSamples.isEmpty {
            // Sans objets visage séparés, les valeurs recopiées dans geometry
            // ne sont considérées comme preuve faciale que si la frame était
            // complète. Le chemin source-specific visage passe par
            // `faceSamples` et reste donc indépendant des hanches/épaules.
            let completeSamples = samples.filter { $0.openingRatioState == .available }
            faceScaleSamples = completeSamples.compactMap { sample in
                guard let value = sample.proximityScale,
                      value.isFinite, value > 0 else { return nil }
                return (sample.capturedAt, value)
            }
            blinkSamples = completeSamples.compactMap { sample in
                guard let left = sample.leftEyeOpeningRatio,
                      let right = sample.rightEyeOpeningRatio,
                      left.isFinite, right.isFinite, left > 0, right > 0 else {
                    return nil
                }
                return (sample.capturedAt, left, right)
            }
            validFaceSamples = []
        } else {
            validFaceSamples = faceSamples.filter { sample in
                sample.faceScale?.isFinite == true && (sample.faceScale ?? 0) > 0 &&
                    sample.facePointCount >= minimumFacePoints &&
                    (sample.signal.yawProxy.map { abs($0) <= maximumProximityYaw } ?? false) &&
                    (sample.signal.eyeLineRollDegrees.map { abs($0) <= maximumRollDegrees } ?? false)
            }
            faceScaleSamples = validFaceSamples.compactMap { sample in
                guard let value = sample.faceScale,
                      value.isFinite, value > 0 else { return nil }
                return (sample.capturedAt, value)
            }
            blinkSamples = validFaceSamples.compactMap { sample in
                guard let left = sample.signal.leftEyeOpeningRatio,
                      let right = sample.signal.rightEyeOpeningRatio,
                      left.isFinite, right.isFinite, left > 0, right > 0 else {
                    return nil
                }
                return (sample.capturedAt, left, right)
            }
        }
        let headTiltCandidates = samples.filter { sample in
            guard sample.headTiltState == .available,
                  sample.headTiltDegrees?.isFinite == true else { return false }
            guard !faceSamples.isEmpty else { return true }
            return validFaceSamples.contains {
                abs($0.capturedAt - sample.capturedAt) <= maximumFusionSkew
            }
        }
        let headTiltSamples = coherentSamples(
            headTiltCandidates,
            maximumSampleGap: maximumSampleGap,
            minimumSamples: minimumSamples
        )
        let shoulderOpeningCandidates = samples.filter { sample in
            guard sample.openingRatioState == .available,
                  sample.shoulderOpeningRatio?.isFinite == true,
                  (sample.shoulderOpeningRatio ?? 0) > 0 else { return false }
            guard !faceSamples.isEmpty else { return true }
            return validFaceSamples.contains {
                abs($0.capturedAt - sample.capturedAt) <= maximumFusionSkew
            }
        }
        let shoulderOpeningSamples = coherentSamples(
            shoulderOpeningCandidates,
            maximumSampleGap: maximumSampleGap,
            minimumSamples: minimumSamples
        )
        let proximitySamples = coherentTimedSamples(
            faceScaleSamples,
            timestamp: { $0.timestamp },
            maximumSampleGap: maximumSampleGap,
            minimumSamples: minimumSamples
        )
        let blinkOpeningSamples = coherentTimedSamples(
            blinkSamples,
            timestamp: { $0.timestamp },
            maximumSampleGap: maximumSampleGap,
            minimumSamples: minimumSamples
        )
        let familySampleCounts = PostureRichBaselineFamilySampleCounts(
            torso: torsoSamples.count,
            shoulderSlope: shoulderSlopeSamples.count,
            headTilt: headTiltSamples.count,
            shoulderElevation: shoulderElevationSamples.count,
            shoulderOpening: shoulderOpeningSamples.count,
            proximity: proximitySamples.count,
            blinkOpening: blinkOpeningSamples.count
        )
        guard familySampleCounts.hasAnyReadyFamily else { return nil }

        let blinkOpeningBaseline: PostureBlinkOpeningBaseline? = {
            guard blinkOpeningSamples.count >= minimumSamples,
                  let leftMedian = median(blinkOpeningSamples.map(\.left)),
                  let rightMedian = median(blinkOpeningSamples.map(\.right)) else {
                return nil
            }
            return PostureBlinkOpeningBaseline(
                leftEyeOpeningRatio: leftMedian,
                rightEyeOpeningRatio: rightMedian,
                leftEyeOpeningMAD: mad(blinkOpeningSamples.map(\.left)),
                rightEyeOpeningMAD: mad(blinkOpeningSamples.map(\.right)),
                sampleCount: blinkOpeningSamples.count
            )
        }()
        return PostureRichBaseline(
            generation: generation,
            contextKey: contextKey,
            ruleVersion: ruleVersion,
            torsoInclinationDegrees: median(torsoSamples.compactMap(\.torsoInclinationDegrees)),
            torsoAxisDeviation: median(torsoSamples.compactMap(\.torsoAxisDeviation)),
            shoulderSlopeDegrees: median(shoulderSlopeSamples.compactMap(\.shoulderSlopeDegrees)),
            shoulderOpeningRatio: median(shoulderOpeningSamples.compactMap(\.shoulderOpeningRatio)),
            leftShoulderElevation: median(shoulderElevationSamples.compactMap(\.leftShoulderElevation)),
            rightShoulderElevation: median(shoulderElevationSamples.compactMap(\.rightShoulderElevation)),
            proximityScale: median(proximitySamples.map(\.value)),
            sampleCount: familySampleCounts.maximum,
            torsoInclinationMAD: mad(torsoSamples.compactMap(\.torsoInclinationDegrees)),
            torsoAxisMAD: mad(torsoSamples.compactMap(\.torsoAxisDeviation)),
            shoulderSlopeMAD: mad(shoulderSlopeSamples.compactMap(\.shoulderSlopeDegrees)),
            blinkOpeningBaseline: blinkOpeningBaseline,
            familySampleCounts: familySampleCounts,
            headTiltDegrees: median(headTiltSamples.compactMap(\.headTiltDegrees)),
            headTiltMAD: mad(headTiltSamples.compactMap(\.headTiltDegrees))
        )
    }

    private static func coherentSamples(
        _ samples: [PostureRichGeometryMetrics],
        maximumSampleGap: TimeInterval,
        minimumSamples: Int
    ) -> [PostureRichGeometryMetrics] {
        guard samples.count >= minimumSamples else { return [] }
        for pair in zip(samples, samples.dropFirst()) {
            guard pair.1.capturedAt > pair.0.capturedAt,
                  pair.1.capturedAt - pair.0.capturedAt <= maximumSampleGap else {
                return []
            }
        }
        return samples
    }

    private static func coherentTimedSamples<T>(
        _ samples: [T],
        timestamp: (T) -> TimeInterval,
        maximumSampleGap: TimeInterval,
        minimumSamples: Int
    ) -> [T] {
        guard samples.count >= minimumSamples else { return [] }
        for pair in zip(samples, samples.dropFirst()) {
            let previous = timestamp(pair.0)
            let current = timestamp(pair.1)
            guard current > previous,
                  current - previous <= maximumSampleGap else {
                return []
            }
        }
        return samples
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func mad(_ values: [Double]) -> Double? {
        guard let center = median(values) else { return nil }
        return median(values.map { abs($0 - center) })
    }
}

nonisolated struct PostureRichSignalConfiguration: Equatable, Sendable {
    var faceTTL: TimeInterval = 0.75
    var bodyTTL: TimeInterval = 1.20
    var maximumFusionSkew: TimeInterval = 0.30
    var maximumSampleGap: TimeInterval = 1.50
    /// Profil par défaut biaisé sensible : les seuils restent configurables
    /// et les points requis/TTL ne sont jamais abaissés.
    var torsoEnterDegrees: Double = 4
    var torsoExitDegrees: Double = 2.5
    var shoulderSlopeEnterDegrees: Double = 0.75
    var shoulderSlopeExitDegrees: Double = 0.35
    var headTiltEnterDegrees: Double = 8
    var headTiltExitDegrees: Double = 5
    /// Limite de publication du proxy 2D : au-delà, la fusion est trop
    /// ambiguë pour être présentée comme une inclinaison relative fiable.
    var maximumHeadTiltDegrees: Double = 45
    var shoulderOpeningEnterDelta: Double = 0.08
    var shoulderOpeningExitDelta: Double = 0.04
    var shoulderElevationEnterDelta: Double = 0.04
    var shoulderElevationExitDelta: Double = 0.02
    /// Variation maximale d'un delta d'élévation entre deux résultats corps
    /// rapprochés. Au-delà, le point est traité comme un saut de modèle et
    /// n'alimente ni la persistance ni l'alerte.
    var shoulderElevationMaximumStep: Double = 0.25
    var requiredDuration: TimeInterval = 1.0
    var proximityEnterRatio: Double = 1.25
    var proximityExitRatio: Double = 1.15
    var proximityDuration: TimeInterval = 2.0
    var minimumFacePoints: Int = 40
    var maximumYaw: Double = 0.35
    var maximumProximityYaw: Double = 0.20
    var maximumRollDegrees: Double = 20
    var blinkCloseRatio: Double = 0.65
    var blinkOpenRatio: Double = 0.80
    /// Rapport d'ouverture mesuré sur l'ouverture neutre personnelle.
    var blinkBaselineOpeningRatio: Double = 0.30
    var blinkMinimumClosed: TimeInterval = 0.05
    var blinkMaximumClosed: TimeInterval = 0.50
    var blinkMaximumGap: TimeInterval = 0.35
    /// Écart maximal entre les transitions des deux yeux d'un clignement.
    /// Une valeur personnalisée est préférable au fallback historique.
    var blinkMaximumEyeSkew: TimeInterval = 0.12
    var blinkWindow: TimeInterval = 60
    var blinkMinimumObservable: TimeInterval = 45
    var blinkReferenceRequiredWindows: Int = 3
    /// Pas de fréquence universelle : la cible est fournie par calibration/produit.
    var blinkTargetPerMinute: Double?
    /// Fraction de la cible personnelle déclenchant la direction `.below`.
    /// Le contrat produit l'autorise entre 0,50 et 0,90 (défaut 0,70).
    var blinkLowRateFraction: Double = 0.70
    /// Durée d'éligibilité continue sous le seuil (cinq minutes par défaut).
    var blinkLowRateDuration: TimeInterval = 5 * 60
    /// Durée au-dessus du seuil pour considérer une récupération.
    var blinkRecoveryDuration: TimeInterval = 2 * 60
    /// Une absence visage/yeux plus longue casse l'épisode de débit, sans
    /// compter le trou ni effacer la fenêtre live encore fraîche.
    var blinkMaximumSuspension: TimeInterval = 10
    /// Intervalle maximal implicitement continu à 10 Hz. Au-delà, le trou
    /// n'est jamais compté, même si une frame valide réapparaît ensuite.
    var blinkMaximumCountedInterval: TimeInterval = 0.25
    /// Délai pratique du rappel lorsque les deux yeux restent ouverts sans
    /// preuve de clignement. Ce n'est pas une cible médicale de fréquence.
    var blinkPauseReminderAfter: TimeInterval = 20

    static var balancedSensitive: Self { Self() }

    static var sensitive: Self {
        var value = Self()
        value.torsoEnterDegrees = 3
        value.torsoExitDegrees = 1.8
        value.shoulderSlopeEnterDegrees = 0.5
        value.shoulderSlopeExitDegrees = 0.25
        value.requiredDuration = 0.8
        return value
    }

    static var discreet: Self {
        var value = Self()
        value.torsoEnterDegrees = 6
        value.torsoExitDegrees = 3.5
        value.shoulderSlopeEnterDegrees = 1.0
        value.shoulderSlopeExitDegrees = 0.5
        value.shoulderElevationEnterDelta = 0.06
        value.shoulderElevationExitDelta = 0.03
        value.requiredDuration = 1.5
        return value
    }
}

nonisolated enum PostureBlinkPhase: String, Equatable, Sendable {
    case open
    case closed
}

nonisolated struct PostureBlinkEvent: Equatable, Sendable {
    let generation: UInt64
    let startedAt: TimeInterval
    let endedAt: TimeInterval
    let duration: TimeInterval
}

/// Détecteur open -> closed -> open par œil. Un événement n'est publié que si
/// les deux yeux terminent un cycle temporellement cohérent; aucune moyenne des
/// ratios gauche/droite ne franchit la frontière CV.
nonisolated struct PostureBlinkTracker: Equatable, Sendable {
    private struct LiveInterval: Equatable, Sendable {
        let startedAt: TimeInterval
        let endedAt: TimeInterval
    }

    /// Compatibilité : `.closed` signifie que les deux yeux sont actuellement
    /// fermés. Les phases détaillées sont exposées séparément ci-dessous.
    private(set) var phase: PostureBlinkPhase = .open
    private(set) var leftEyePhase: PostureBlinkPhase = .open
    private(set) var rightEyePhase: PostureBlinkPhase = .open
    private(set) var observableSeconds: TimeInterval = 0
    /// Durée observable de la fenêtre glissante utilisée par le débit live.
    /// Elle reste indépendante de la fenêtre terminée envoyée à la calibration.
    private(set) var liveObservableSeconds: TimeInterval = 0
    private(set) var events: [PostureBlinkEvent] = []
    private var liveIntervals: [LiveInterval] = []
    private var liveEvents: [PostureBlinkEvent] = []
    /// Fenêtre terminée, consommable une seule fois par le repère personnel.
    private var completedWindow: PostureBlinkReferenceWindow?
    private var leftClosedStartedAt: TimeInterval?
    private var rightClosedStartedAt: TimeInterval?
    private var leftReopenedAt: TimeInterval?
    private var rightReopenedAt: TimeInterval?
    private var awaitingBothEyesOpen = false
    private var lastValidAt: TimeInterval?
    private var lastGoodAt: TimeInterval?
    private var lastObservedAt: TimeInterval?
    private var generation: UInt64?
    private var windowStartedAt: TimeInterval?
    private var liveLastValidAt: TimeInterval?

    mutating func reset() {
        phase = .open
        leftEyePhase = .open
        rightEyePhase = .open
        observableSeconds = 0
        liveObservableSeconds = 0
        events.removeAll(keepingCapacity: true)
        liveIntervals.removeAll(keepingCapacity: true)
        liveEvents.removeAll(keepingCapacity: true)
        completedWindow = nil
        leftClosedStartedAt = nil
        rightClosedStartedAt = nil
        leftReopenedAt = nil
        rightReopenedAt = nil
        awaitingBothEyesOpen = false
        lastValidAt = nil
        lastGoodAt = nil
        lastObservedAt = nil
        generation = nil
        windowStartedAt = nil
        liveLastValidAt = nil
    }

    mutating func takeCompletedWindow() -> PostureBlinkReferenceWindow? {
        defer { completedWindow = nil }
        return completedWindow
    }

    /// API historique : il duplique explicitement la même preuve vers les
    /// deux yeux. Le chemin de production utilise l'overload typé ci-dessous.
    mutating func consume(
        generation newGeneration: UInt64,
        timestamp: TimeInterval,
        openingRatio: Double?,
        qualityGood: Bool,
        configuration: PostureRichSignalConfiguration
    ) -> PostureBlinkEvent? {
        consume(generation: newGeneration, timestamp: timestamp,
                leftEyeOpeningRatio: openingRatio,
                rightEyeOpeningRatio: openingRatio,
                qualityGood: qualityGood, configuration: configuration)
    }

    mutating func consume(
        generation newGeneration: UInt64,
        timestamp: TimeInterval,
        leftEyeOpeningRatio: Double?,
        rightEyeOpeningRatio: Double?,
        qualityGood: Bool,
        configuration: PostureRichSignalConfiguration
    ) -> PostureBlinkEvent? {
        guard newGeneration > 0, timestamp.isFinite,
              configuration.blinkCloseRatio.isFinite,
              configuration.blinkOpenRatio.isFinite,
              configuration.blinkOpenRatio > configuration.blinkCloseRatio,
              configuration.blinkMinimumClosed.isFinite,
              configuration.blinkMinimumClosed >= 0,
              configuration.blinkMaximumClosed.isFinite,
              configuration.blinkMaximumClosed >= configuration.blinkMinimumClosed,
              configuration.blinkMaximumGap.isFinite,
              configuration.blinkMaximumGap > 0,
              configuration.blinkMaximumSuspension.isFinite,
              configuration.blinkMaximumSuspension > 0,
              configuration.blinkMaximumEyeSkew.isFinite,
              configuration.blinkMaximumEyeSkew >= 0,
              configuration.blinkMaximumCountedInterval.isFinite,
              configuration.blinkMaximumCountedInterval > 0,
              configuration.blinkWindow.isFinite,
              configuration.blinkWindow > 0 else {
            reset()
            return nil
        }

        if generation != newGeneration {
            reset()
            generation = newGeneration
        } else if let previous = lastObservedAt, timestamp <= previous {
            return nil
        }

        if let previous = lastGoodAt {
            let gap = timestamp - previous
            if gap > configuration.blinkMaximumSuspension {
                // Une longue absence casse la continuité du cycle courant,
                // mais ne détruit pas la fenêtre glissante. Les anciennes
                // observations seront retirées par `trimLiveHistory` selon
                // leur âge réel, sans faire compter le trou.
                suspendAfterGap()
            } else if gap > configuration.blinkMaximumGap {
                // Un trou moyen suspend la continuité, mais ne doit pas
                // effacer les observations valides encore présentes dans la
                // fenêtre glissante. Le trou ne contribue jamais au temps
                // observable; il casse seulement le cycle courant.
                lastValidAt = nil
                liveLastValidAt = nil
                resetCycle(awaitingBothEyesOpen: true)
            }
        }
        lastObservedAt = timestamp

        let validEyes = qualityGood &&
            leftEyeOpeningRatio.map { $0.isFinite && $0 >= 0 } == true &&
            rightEyeOpeningRatio.map { $0.isFinite && $0 >= 0 } == true
        guard validEyes, let leftEyeOpeningRatio, let rightEyeOpeningRatio else {
            // Une seule preuve faciale invalide casse le cycle, sans compter
            // l'intervalle; l'historique rate reste conservé hors suspension.
            lastValidAt = nil
            liveLastValidAt = nil
            resetCycle(awaitingBothEyesOpen: true)
            return nil
        }

        if let previous = lastValidAt {
            let delta = timestamp - previous
            if delta > 0,
               delta <= min(configuration.blinkMaximumGap,
                            configuration.blinkMaximumCountedInterval) {
                observableSeconds += delta
            }
        }
        recordLiveObservation(at: timestamp, configuration: configuration)
        if let windowStartedAt,
           timestamp - windowStartedAt >= configuration.blinkWindow {
            completedWindow = PostureBlinkReferenceWindow(
                startedAt: windowStartedAt,
                endedAt: timestamp,
                observableSeconds: observableSeconds,
                blinkCount: events.count
            )
            observableSeconds = 0
            events.removeAll(keepingCapacity: true)
            self.windowStartedAt = timestamp
        } else if self.windowStartedAt == nil {
            self.windowStartedAt = timestamp
        }
        lastValidAt = timestamp
        lastGoodAt = timestamp

        if awaitingBothEyesOpen {
            guard leftEyeOpeningRatio >= configuration.blinkOpenRatio,
                  rightEyeOpeningRatio >= configuration.blinkOpenRatio else {
                return nil
            }
            resetCycle(awaitingBothEyesOpen: false)
            return nil
        }

        if leftEyePhase == .open, leftEyeOpeningRatio <= configuration.blinkCloseRatio {
            leftEyePhase = .closed
            leftClosedStartedAt = timestamp
            leftReopenedAt = nil
        } else if leftEyePhase == .closed, leftEyeOpeningRatio >= configuration.blinkOpenRatio {
            leftEyePhase = .open
            leftReopenedAt = timestamp
        }
        if rightEyePhase == .open, rightEyeOpeningRatio <= configuration.blinkCloseRatio {
            rightEyePhase = .closed
            rightClosedStartedAt = timestamp
            rightReopenedAt = nil
        } else if rightEyePhase == .closed, rightEyeOpeningRatio >= configuration.blinkOpenRatio {
            rightEyePhase = .open
            rightReopenedAt = timestamp
        }
        phase = leftEyePhase == .closed && rightEyePhase == .closed ? .closed : .open

        if let leftStart = leftClosedStartedAt,
           timestamp - leftStart > configuration.blinkMaximumClosed {
            resetCycle(awaitingBothEyesOpen: true)
            return nil
        }
        if let rightStart = rightClosedStartedAt,
           timestamp - rightStart > configuration.blinkMaximumClosed {
            resetCycle(awaitingBothEyesOpen: true)
            return nil
        }
        if let leftStart = leftClosedStartedAt, let rightStart = rightClosedStartedAt,
           abs(leftStart - rightStart) > configuration.blinkMaximumEyeSkew {
            resetCycle(awaitingBothEyesOpen: true)
            return nil
        }

        guard leftEyePhase == .open, rightEyePhase == .open else { return nil }
        guard let leftStart = leftClosedStartedAt, let rightStart = rightClosedStartedAt,
              let leftEnd = leftReopenedAt, let rightEnd = rightReopenedAt else {
            // Un clignement unilatéral ne laisse pas de cycle à apparier.
            leftClosedStartedAt = nil
            rightClosedStartedAt = nil
            leftReopenedAt = nil
            rightReopenedAt = nil
            return nil
        }
        let leftDuration = leftEnd - leftStart
        let rightDuration = rightEnd - rightStart
        guard leftDuration >= configuration.blinkMinimumClosed,
              leftDuration <= configuration.blinkMaximumClosed,
              rightDuration >= configuration.blinkMinimumClosed,
              rightDuration <= configuration.blinkMaximumClosed,
              abs(leftEnd - rightEnd) <= configuration.blinkMaximumEyeSkew else {
            resetCycle(awaitingBothEyesOpen: true)
            return nil
        }
        let startedAt = min(leftStart, rightStart)
        let endedAt = max(leftEnd, rightEnd)
        let event = PostureBlinkEvent(generation: newGeneration, startedAt: startedAt,
                                      endedAt: endedAt, duration: endedAt - startedAt)
        events.append(event)
        liveEvents.append(event)
        trimLiveHistory(at: timestamp, window: configuration.blinkWindow)
        resetCycle(awaitingBothEyesOpen: false)
        return event
    }

    private mutating func recordLiveObservation(
        at timestamp: TimeInterval,
        configuration: PostureRichSignalConfiguration
    ) {
        if let previous = liveLastValidAt {
            let delta = timestamp - previous
            if delta > 0,
               delta <= min(configuration.blinkMaximumGap,
                            configuration.blinkMaximumCountedInterval) {
                liveIntervals.append(LiveInterval(startedAt: previous, endedAt: timestamp))
            }
        }
        liveLastValidAt = timestamp
        trimLiveHistory(at: timestamp, window: configuration.blinkWindow)
    }

    private mutating func trimLiveHistory(at timestamp: TimeInterval, window: TimeInterval) {
        let start = timestamp - window
        liveIntervals.removeAll { $0.endedAt <= start }
        liveEvents.removeAll { $0.endedAt < start }
        liveObservableSeconds = liveIntervals.reduce(0) { total, interval in
            let clippedStart = max(interval.startedAt, start)
            let clippedEnd = min(interval.endedAt, timestamp)
            return total + max(0, clippedEnd - clippedStart)
        }
    }

    private mutating func resetCycle(awaitingBothEyesOpen: Bool) {
        phase = .open
        leftEyePhase = .open
        rightEyePhase = .open
        leftClosedStartedAt = nil
        rightClosedStartedAt = nil
        leftReopenedAt = nil
        rightReopenedAt = nil
        self.awaitingBothEyesOpen = awaitingBothEyesOpen
    }

    /// Coupe toute continuité de clignement après un trou, sans remettre à
    /// zéro les observations déjà valides dans la fenêtre courante.
    private mutating func suspendAfterGap() {
        lastValidAt = nil
        liveLastValidAt = nil
        lastGoodAt = nil
        resetCycle(awaitingBothEyesOpen: true)
    }

    var ratePerMinute: Double? {
        guard liveObservableSeconds > 0 else { return nil }
        let value = Double(liveEvents.count) / liveObservableSeconds * 60
        return value.isFinite ? value : nil
    }
}

/// Suit la durée d'un débit de clignement inférieur à la cible personnelle.
/// Les intervalles sans visage/yeux valides sont suspendus (non comptés) et
/// réinitialisent l'épisode après `blinkMaximumSuspension`. Cette machine ne
/// déclenche aucune alerte : elle expose uniquement une mesure normalisée et
/// des durées que l'arbitre produit pourra consommer.
nonisolated struct PostureBlinkRateAssessment: Equatable, Sendable {
    let normalizedValue: Double?
    let direction: PostureRichSignalDirection
    let belowDuration: TimeInterval
    let recoveryDuration: TimeInterval
    let quality: PostureSignalQuality
    let reason: String
}

nonisolated struct PostureBlinkRateTracker: Equatable, Sendable {
    private(set) var belowDuration: TimeInterval = 0
    private(set) var recoveryDuration: TimeInterval = 0
    private(set) var belowEpisodeActive = false
    private var generation: UInt64?
    private var lastSampleID: UInt64?
    private var lastTimestamp: TimeInterval?
    private var lastEligibleTimestamp: TimeInterval?
    private var previousEligibleWasBelow: Bool?

    mutating func reset() {
        belowDuration = 0
        recoveryDuration = 0
        belowEpisodeActive = false
        generation = nil
        lastSampleID = nil
        lastTimestamp = nil
        lastEligibleTimestamp = nil
        previousEligibleWasBelow = nil
    }

    mutating func consume(
        generation newGeneration: UInt64,
        sampleID: UInt64,
        timestamp: TimeInterval,
        normalizedRate: Double?,
        eligible: Bool,
        configuration: PostureRichSignalConfiguration
    ) -> PostureBlinkRateAssessment {
        guard newGeneration > 0, sampleID > 0, timestamp.isFinite else {
            return assessment(normalizedValue: nil, direction: .unknown,
                              quality: .unavailable, reason: "identité clignement invalide")
        }
        guard configuration.blinkLowRateFraction.isFinite,
              (0.50...0.90).contains(configuration.blinkLowRateFraction),
              configuration.blinkLowRateDuration.isFinite,
              configuration.blinkLowRateDuration > 0,
              configuration.blinkRecoveryDuration.isFinite,
              configuration.blinkRecoveryDuration > 0,
              configuration.blinkMaximumSuspension.isFinite,
              configuration.blinkMaximumSuspension > 0,
              configuration.blinkMaximumCountedInterval.isFinite,
              configuration.blinkMaximumCountedInterval > 0,
              configuration.blinkMaximumCountedInterval <= configuration.blinkMaximumSuspension else {
            return assessment(normalizedValue: nil, direction: .unknown,
                              quality: .unavailable, reason: "configuration clignement invalide")
        }

        if generation != newGeneration {
            reset()
            generation = newGeneration
        }
        if let lastTimestamp,
           timestamp <= lastTimestamp || sampleID == lastSampleID {
            return assessment(normalizedValue: normalizedRate,
                              direction: direction(for: normalizedRate, configuration: configuration),
                              quality: eligible ? .good : .limited,
                              reason: "échantillon clignement dupliqué ou ancien")
        }
        self.lastTimestamp = timestamp
        self.lastSampleID = sampleID

        guard eligible, let normalizedRate, normalizedRate.isFinite else {
            if let lastEligibleTimestamp,
               timestamp - lastEligibleTimestamp > configuration.blinkMaximumSuspension {
                resetEpisode()
            }
            previousEligibleWasBelow = nil
            return assessment(normalizedValue: normalizedRate,
                              direction: .unknown, quality: .limited,
                              reason: "visage/yeux non éligibles; durée suspendue")
        }

        if let lastEligibleTimestamp,
           timestamp - lastEligibleTimestamp > configuration.blinkMaximumSuspension {
            resetEpisode()
        }
        let isBelow = normalizedRate < configuration.blinkLowRateFraction
        let linked = if let previous = self.lastEligibleTimestamp {
            timestamp - previous > 0 &&
                timestamp - previous <= configuration.blinkMaximumCountedInterval &&
                previousEligibleWasBelow != nil
        } else {
            false
        }
        let delta = if linked, let previous = self.lastEligibleTimestamp {
            timestamp - previous
        } else {
            0.0
        }

        if isBelow {
            if !belowEpisodeActive {
                belowEpisodeActive = true
                belowDuration = 0
            } else if linked, previousEligibleWasBelow == true {
                belowDuration += delta
            }
            recoveryDuration = 0
        } else if belowEpisodeActive {
            if linked, previousEligibleWasBelow == false {
                recoveryDuration += delta
            } else if !linked {
                recoveryDuration = 0
            }
            if recoveryDuration >= configuration.blinkRecoveryDuration {
                resetEpisode()
            }
        }

        self.lastEligibleTimestamp = timestamp
        previousEligibleWasBelow = isBelow
        let direction: PostureRichSignalDirection = isBelow ? .below : .neutral
        let reason = isBelow
            ? "fréquence sous le seuil personnel"
            : "fréquence au-dessus du seuil personnel"
        return assessment(normalizedValue: normalizedRate, direction: direction,
                          quality: .good, reason: reason)
    }

    private mutating func resetEpisode() {
        belowDuration = 0
        recoveryDuration = 0
        belowEpisodeActive = false
        lastEligibleTimestamp = nil
        previousEligibleWasBelow = nil
    }

    private func direction(
        for normalizedRate: Double?,
        configuration: PostureRichSignalConfiguration
    ) -> PostureRichSignalDirection {
        guard let normalizedRate, normalizedRate.isFinite else { return .unknown }
        return normalizedRate < configuration.blinkLowRateFraction ? .below : .neutral
    }

    private func assessment(
        normalizedValue: Double?,
        direction: PostureRichSignalDirection,
        quality: PostureSignalQuality,
        reason: String
    ) -> PostureBlinkRateAssessment {
        PostureBlinkRateAssessment(normalizedValue: normalizedValue,
                                   direction: direction,
                                   belowDuration: belowDuration,
                                   recoveryDuration: recoveryDuration,
                                   quality: quality,
                                   reason: reason)
    }
}

nonisolated struct PostureRichSustainedState: Equatable, Sendable {
    private(set) var active = false
    private var pendingSince: TimeInterval?
    private var lastTimestamp: TimeInterval?

    mutating func reset() {
        active = false
        pendingSince = nil
        lastTimestamp = nil
    }

    mutating func update(
        deviation: Double?,
        timestamp: TimeInterval,
        enterThreshold: Double,
        exitThreshold: Double,
        requiredDuration: TimeInterval,
        maximumGap: TimeInterval,
        usesMagnitude: Bool = true
    ) -> Bool {
        guard timestamp.isFinite, enterThreshold.isFinite, exitThreshold.isFinite,
              requiredDuration >= 0, maximumGap > 0 else { reset(); return false }
        if let lastTimestamp {
            if timestamp <= lastTimestamp { return active }
            if timestamp - lastTimestamp > maximumGap { reset() }
        }
        lastTimestamp = timestamp
        guard let deviation, deviation.isFinite else {
            active = false; pendingSince = nil; return false
        }
        let magnitude = usesMagnitude ? abs(deviation) : deviation
        if active {
            if magnitude <= exitThreshold { active = false; pendingSince = nil }
            return active
        }
        if magnitude >= enterThreshold {
            pendingSince = pendingSince ?? timestamp
            if timestamp - (pendingSince ?? timestamp) >= requiredDuration { active = true }
        } else {
            pendingSince = nil
        }
        return active
    }
}

/// Rejette un saut soudain dans les deltas d'élévation des épaules. Le filtre
/// est volontairement séparé de `PostureRichSustainedState` : un échantillon
/// aberrant ne doit ni ouvrir une nouvelle attention, ni effacer les règles
/// temporelles des autres signaux corporels.
private nonisolated struct PostureShoulderRaiseTemporalFilter: Equatable, Sendable {
    enum Result: Equatable, Sendable {
        case accepted
        case rejectedJump
    }

    private var generation: UInt64?
    private var contextKey: String?
    private var lastSampleID: UInt64?
    private var lastCapturedAt: TimeInterval?
    private var lastLeft: Double?
    private var lastRight: Double?

    mutating func reset() {
        generation = nil
        contextKey = nil
        lastSampleID = nil
        lastCapturedAt = nil
        lastLeft = nil
        lastRight = nil
    }

    mutating func consume(
        generation: UInt64,
        contextKey: String,
        sampleID: UInt64,
        capturedAt: TimeInterval,
        left: Double?,
        right: Double?,
        maximumStep: Double,
        maximumGap: TimeInterval
    ) -> Result {
        guard generation > 0, !contextKey.isEmpty, sampleID > 0,
              capturedAt.isFinite, maximumStep.isFinite, maximumStep > 0,
              maximumGap.isFinite, maximumGap > 0,
              left.map(\.isFinite) ?? true,
              right.map(\.isFinite) ?? true else {
            return .rejectedJump
        }

        let sameStream = self.generation == generation && self.contextKey == contextKey
        let hasUsablePrevious = sameStream &&
            (lastSampleID.map { sampleID > $0 } ?? true) &&
            (lastCapturedAt.map { capturedAt > $0 } ?? true) &&
            (lastCapturedAt.map { capturedAt - $0 <= maximumGap } ?? true)
        if hasUsablePrevious {
            let leftJump = if let left, let lastLeft {
                abs(left - lastLeft) > maximumStep
            } else { false }
            let rightJump = if let right, let lastRight {
                abs(right - lastRight) > maximumStep
            } else { false }
            if leftJump || rightJump {
                // Ne mémorise pas le saut : le prochain échantillon est
                // comparé au dernier point accepté et reste donc vérifiable.
                return .rejectedJump
            }
        }

        self.generation = generation
        self.contextKey = contextKey
        self.lastSampleID = sampleID
        self.lastCapturedAt = capturedAt
        self.lastLeft = left
        self.lastRight = right
        return .accepted
    }

    var acceptedDeltas: (left: Double?, right: Double?) {
        (lastLeft, lastRight)
    }
}

nonisolated struct PostureRichEvaluation: Equatable, Sendable {
    let torsoInclination: PostureRichScalarObservation
    let shoulderSlope: PostureRichScalarObservation
    let headTilt: PostureRichScalarObservation
    let shoulderOpening: PostureRichScalarObservation
    let shouldersRaised: PostureRichScalarObservation
    let proximity: PostureRichScalarObservation
    let blinkRate: PostureRichScalarObservation
    let blinkEvent: PostureBlinkEvent?
    let blinkRateAssessment: PostureBlinkRateAssessment

    init(
        torsoInclination: PostureRichScalarObservation,
        shoulderSlope: PostureRichScalarObservation,
        headTilt: PostureRichScalarObservation? = nil,
        shoulderOpening: PostureRichScalarObservation,
        shouldersRaised: PostureRichScalarObservation,
        proximity: PostureRichScalarObservation,
        blinkRate: PostureRichScalarObservation,
        blinkEvent: PostureBlinkEvent?,
        blinkRateAssessment: PostureBlinkRateAssessment
    ) {
        self.torsoInclination = torsoInclination
        self.shoulderSlope = shoulderSlope
        self.headTilt = headTilt ??
            .unavailable(
                .headTilt,
                generation: shoulderSlope.generation,
                sampleID: shoulderSlope.sampleID,
                capturedAt: shoulderSlope.capturedAt,
                reason: "signal tête-épaules non calculé"
            )
        self.shoulderOpening = shoulderOpening
        self.shouldersRaised = shouldersRaised
        self.proximity = proximity
        self.blinkRate = blinkRate
        self.blinkEvent = blinkEvent
        self.blinkRateAssessment = blinkRateAssessment
    }
}

/// Persistance des états et des transitions, sans notification ni UI. Les
/// alertes et les statistiques peuvent consommer ce snapshot sans dépendre du
/// moteur d'inférence.
nonisolated struct PostureRichSignalEvaluator: Equatable, Sendable {
    private enum EvaluationSource: Sendable {
        case combined
        case face
        case body
        case invalidateBody
    }

    private(set) var configuration: PostureRichSignalConfiguration
    private var generation: UInt64?
    private var contextKey: String?
    private var lastAcceptedTimestamp: TimeInterval?
    private var lastAcceptedSampleID: UInt64?
    private var torsoState = PostureRichSustainedState()
    private var shoulderSlopeState = PostureRichSustainedState()
    private var headTiltState = PostureRichSustainedState()
    private var openingRatioAttentionState = PostureRichSustainedState()
    private var raisedState = PostureRichSustainedState()
    private var shoulderRaiseFilter = PostureShoulderRaiseTemporalFilter()
    private var proximityState = PostureRichSustainedState()
    private var blinkTracker = PostureBlinkTracker()
    private var blinkRateTracker = PostureBlinkRateTracker()
    private var blinkPause = PostureBlinkPause()
    /// Repère automatique construit uniquement à partir de fenêtres indépendantes
    /// et gelé après trois fenêtres fiables. Il ne se déduit jamais du premier
    /// débit disponible.
    private var blinkReference: PostureBlinkReference

    // Les deux flux ont des cadences différentes. Ces caches ne contiennent
    // que des métriques scalaires déjà dérivées (jamais d'image ni de point
    // brut), afin qu'un tick visage ne fasse pas progresser le corps.
    private var latestBody: PostureRichGeometryMetrics?
    private var bodyGeneration: UInt64?
    private var bodyContextKey: String?
    private var bodyLastTimestamp: TimeInterval?
    private var bodyLastSampleID: UInt64?
    private var bodyBaseline: PostureRichBaseline?
    private var latestFace: PostureFaceObservation?
    private var faceGeneration: UInt64?
    private var faceContextKey: String?
    private var faceLastTimestamp: TimeInterval?
    private var faceLastSampleID: UInt64?
    private var faceBaseline: PostureRichBaseline?
    private var latestBlinkRateAssessment: PostureBlinkRateAssessment?

    init(configuration: PostureRichSignalConfiguration = .init()) {
        self.configuration = configuration
        self.blinkReference = PostureBlinkReference(configuration: .init(
            windowDuration: configuration.blinkWindow,
            minimumObservableSeconds: configuration.blinkMinimumObservable,
            requiredWindows: configuration.blinkReferenceRequiredWindows
        ))
    }

    mutating func setBlinkTarget(_ target: Double?) {
        configuration.blinkTargetPerMinute = target
    }

    /// Réarme les états transitoires après une réacquisition. Le repère
    /// personnel et les observations glissantes encore fraîches restent
    /// conservés : une perte temporaire du cadre ne doit pas imposer une
    /// nouvelle collecte de 45 s.
    mutating func resetFaceTarget() {
        proximityState.reset()
        // `invalidateFace` a déjà cassé le cycle en cours. Conserver le
        // tracker permet de réutiliser les secondes réellement observées qui
        // sont encore dans la fenêtre de 60 s, sans jamais compter le trou.
        blinkRateTracker.reset()
        blinkPause.reset()
        latestBlinkRateAssessment = nil
        latestFace = nil
        faceLastTimestamp = nil
        faceLastSampleID = nil
        headTiltState.reset()
    }

    mutating func reset() {
        generation = nil
        contextKey = nil
        lastAcceptedTimestamp = nil
        lastAcceptedSampleID = nil
        torsoState.reset(); shoulderSlopeState.reset(); headTiltState.reset(); openingRatioAttentionState.reset(); raisedState.reset(); proximityState.reset()
        shoulderRaiseFilter.reset()
        blinkTracker.reset()
        blinkRateTracker.reset()
        blinkPause.reset()
        blinkReference.reset()
        resetBodyCache()
        resetFaceCache()
    }

    mutating func consume(
        geometry: PostureRichGeometryMetrics?,
        face: PostureFaceObservation?,
        baseline: PostureRichBaseline?,
        now: TimeInterval
    ) -> PostureRichEvaluation {
        if geometry == nil && face == nil {
            // L'absence d'argument est un tick vide, pas un signal noPerson.
            return unavailableEvaluation(generation: generation ?? 0,
                                          sampleID: lastAcceptedSampleID ?? 0,
                                          capturedAt: now,
                                          reason: "aucune source fournie")
        }
        // Une absence de géométrie sur un tick visage conserve désormais les
        // machines corporelles (sans l'interpréter comme noPerson). Une
        // absence de visage sur un tick corps reste une mesure corps-only,
        // sans réutiliser implicitement un visage.
        let source: EvaluationSource = if geometry == nil && face != nil {
            .face
        } else {
            .combined
        }
        return consumeInternal(geometry: geometry, face: face, baseline: baseline,
                               now: now, source: source)
    }

    /// Tick visage : seules les machines visage progressent. Le dernier corps
    /// reste consultable jusqu'à expiration de `bodyTTL`.
    mutating func consumeFace(
        face: PostureFaceObservation,
        baseline: PostureRichBaseline? = nil,
        now: TimeInterval
    ) -> PostureRichEvaluation {
        consumeInternal(geometry: nil, face: face, baseline: baseline,
                        now: now, source: .face)
    }

    /// Tick corps : seules les machines corporelles progressent. Le visage
    /// mis en cache sert uniquement aux dérivés fusionnés/face-only.
    mutating func consumeBody(
        geometry: PostureRichGeometryMetrics,
        pairedFace: PostureFaceObservation? = nil,
        baseline: PostureRichBaseline? = nil,
        now: TimeInterval
    ) -> PostureRichEvaluation {
        consumeInternal(geometry: geometry, face: nil, pairedFace: pairedFace,
                        baseline: baseline,
                        now: now, source: .body)
    }

    /// Perte/noPerson/erreur explicite du corps. Une simple absence
    /// d'argument n'appelle jamais cette méthode implicitement.
    mutating func invalidateBody(
        generation: UInt64,
        contextKey: String,
        sampleID: UInt64,
        capturedAt: TimeInterval,
        now: TimeInterval,
        reason: String = "corps invalide"
    ) -> PostureRichEvaluation {
        consumeInternal(geometry: nil, face: nil, baseline: nil, now: now,
                        source: .invalidateBody,
                        explicitIdentity: (generation, contextKey, sampleID, capturedAt),
                        explicitReason: reason)
    }

    /// Tick visage explicitement non fiable. Il casse un cycle de clignement
    /// et suspend les durées, sans effacer le repère personnel ni les machines
    /// corporelles.
    mutating func invalidateFace(
        generation newGeneration: UInt64,
        sampleID: UInt64,
        capturedAt: TimeInterval
    ) {
        guard newGeneration > 0, sampleID > 0, capturedAt.isFinite else { return }
        proximityState.reset()
        headTiltState.reset()
        blinkPause.reset()
        _ = blinkTracker.consume(
            generation: newGeneration,
            timestamp: capturedAt,
            openingRatio: nil,
            qualityGood: false,
            configuration: configuration
        )
        latestBlinkRateAssessment = blinkRateTracker.consume(
            generation: newGeneration,
            sampleID: sampleID,
            timestamp: capturedAt,
            normalizedRate: nil,
            eligible: false,
            configuration: configuration
        )
        latestFace = nil
        faceGeneration = newGeneration
        faceLastTimestamp = capturedAt
        faceLastSampleID = sampleID
    }

    private mutating func consumeInternal(
        geometry: PostureRichGeometryMetrics?,
        face: PostureFaceObservation?,
        pairedFace: PostureFaceObservation? = nil,
        baseline: PostureRichBaseline?,
        now: TimeInterval,
        source: EvaluationSource,
        explicitIdentity: (generation: UInt64, contextKey: String, sampleID: UInt64, capturedAt: TimeInterval)? = nil,
        explicitReason: String? = nil
    ) -> PostureRichEvaluation {
        let idGeneration = explicitIdentity?.generation ?? geometry?.generation ?? face?.generation ?? 0
        let idTimestamp = explicitIdentity?.capturedAt ?? max(geometry?.capturedAt ?? -.greatestFiniteMagnitude,
                                                               face?.capturedAt ?? -.greatestFiniteMagnitude)
        // Un visage à 10 Hz peut être fusionné avec un résultat corps plus
        // lent. L'identité suit alors le composant le plus récent, sinon le
        // même sampleID corps bloquerait les observations faciales suivantes.
        let idSample: UInt64 = if let explicitIdentity {
            explicitIdentity.sampleID
        } else if let face,
                                  face.capturedAt >= (geometry?.capturedAt ?? -.greatestFiniteMagnitude) {
            face.sampleID
        } else {
            geometry?.sampleID ?? 0
        }
        let key = explicitIdentity?.contextKey ?? geometry?.contextKey ?? face?.contextKey ?? contextKey ?? ""
        guard idGeneration > 0, idSample > 0, idTimestamp.isFinite else {
            return unavailableEvaluation(generation: idGeneration, sampleID: idSample,
                                          capturedAt: idTimestamp, reason: "identité invalide")
        }
        if source == .combined, generation == idGeneration, contextKey == key,
           let lastAcceptedTimestamp, let lastAcceptedSampleID {
            if idTimestamp < lastAcceptedTimestamp ||
                (idTimestamp == lastAcceptedTimestamp && idSample == lastAcceptedSampleID) {
                return unavailableEvaluation(generation: idGeneration, sampleID: idSample,
                                              capturedAt: idTimestamp, reason: "échantillon ancien ou dupliqué")
            }
        }
        if source == .combined && (generation != idGeneration || contextKey != key) {
            torsoState.reset(); shoulderSlopeState.reset(); headTiltState.reset(); openingRatioAttentionState.reset(); raisedState.reset(); proximityState.reset()
            blinkTracker.reset()
            blinkPause.reset()
            // Le repère et l'épisode de débit sont liés au même contexte
            // stable; aucun état de l'ancien contexte ne traverse une nouvelle
            // génération ou un nouveau cadrage.
            blinkRateTracker.reset()
            blinkReference.reset()
            latestBlinkRateAssessment = nil
            generation = idGeneration
            contextKey = key
            lastAcceptedTimestamp = nil
            lastAcceptedSampleID = nil
        }
        if source == .combined {
            lastAcceptedTimestamp = idTimestamp
            lastAcceptedSampleID = idSample
            if let geometry {
                latestBody = geometry
                bodyGeneration = geometry.generation
                bodyContextKey = geometry.contextKey
                bodyLastTimestamp = geometry.capturedAt
                bodyLastSampleID = geometry.sampleID
                bodyBaseline = baseline.flatMap {
                    $0.generation == geometry.generation && $0.contextKey == geometry.contextKey ? $0 : nil
                }
            }
            if let face {
                latestFace = face
                faceGeneration = face.generation
                faceContextKey = face.contextKey
                faceLastTimestamp = face.capturedAt
                faceLastSampleID = face.sampleID
                faceBaseline = baseline.flatMap {
                    $0.generation == face.generation && $0.contextKey == face.contextKey ? $0 : nil
                }
            }
        }

        if source == .body || source == .invalidateBody {
            if let geometry {
                guard geometry.generation == idGeneration,
                      geometry.contextKey == key,
                      geometry.capturedAt.isFinite,
                      geometry.sampleID > 0 else {
                    return unavailableEvaluation(generation: idGeneration, sampleID: idSample,
                                                  capturedAt: idTimestamp, reason: "identité corps invalide")
                }
                if bodyGeneration == geometry.generation,
                   bodyContextKey == geometry.contextKey,
                   let previous = bodyLastTimestamp,
                   geometry.capturedAt < previous ||
                    (geometry.capturedAt == previous && geometry.sampleID == bodyLastSampleID) {
                    return unavailableEvaluation(generation: idGeneration, sampleID: idSample,
                                                  capturedAt: idTimestamp, reason: "échantillon corps ancien ou dupliqué")
                }
                if bodyGeneration != geometry.generation || bodyContextKey != geometry.contextKey {
                    resetBodyStateOnly()
                    bodyBaseline = nil
                }
                bodyGeneration = geometry.generation
                bodyContextKey = geometry.contextKey
                bodyLastTimestamp = geometry.capturedAt
                bodyLastSampleID = geometry.sampleID
                latestBody = geometry
                if let baseline, baseline.generation == geometry.generation,
                   baseline.contextKey == geometry.contextKey {
                    bodyBaseline = baseline
                }
            } else if source == .invalidateBody {
                if let currentGeneration = bodyGeneration {
                    guard idGeneration >= currentGeneration else {
                        return unavailableEvaluation(generation: idGeneration, sampleID: idSample,
                                                      capturedAt: idTimestamp,
                                                      reason: "invalidation corps ancienne")
                    }
                    if idGeneration == currentGeneration {
                        guard bodyContextKey == key else {
                            return unavailableEvaluation(generation: idGeneration, sampleID: idSample,
                                                          capturedAt: idTimestamp,
                                                          reason: "invalidation corps contexte différent")
                        }
                        if let previous = bodyLastTimestamp,
                           idTimestamp < previous ||
                            (idTimestamp == previous && idSample < (bodyLastSampleID ?? 0)) {
                            return unavailableEvaluation(generation: idGeneration, sampleID: idSample,
                                                          capturedAt: idTimestamp,
                                                          reason: "invalidation corps ancienne")
                        }
                    }
                }
                resetBodyStateOnly()
                latestBody = nil
                bodyBaseline = nil
                bodyLastTimestamp = nil
                bodyLastSampleID = nil
                bodyGeneration = explicitIdentity?.generation
                bodyContextKey = explicitIdentity?.contextKey
            }
        }
        if source == .face, let face {
            guard face.generation == idGeneration,
                  face.contextKey == key,
                  face.capturedAt.isFinite,
                  face.sampleID > 0 else {
                return unavailableEvaluation(generation: idGeneration, sampleID: idSample,
                                              capturedAt: idTimestamp, reason: "identité visage invalide")
            }
            if faceGeneration == face.generation,
               faceContextKey == face.contextKey,
               let previous = faceLastTimestamp,
               face.capturedAt < previous ||
                (face.capturedAt == previous && face.sampleID == faceLastSampleID) {
                return unavailableEvaluation(generation: idGeneration, sampleID: idSample,
                                              capturedAt: idTimestamp, reason: "échantillon visage ancien ou dupliqué")
            }
            if faceGeneration != face.generation || faceContextKey != face.contextKey {
                resetFaceStateOnly()
                faceBaseline = nil
            }
            faceGeneration = face.generation
            faceContextKey = face.contextKey
            faceLastTimestamp = face.capturedAt
            faceLastSampleID = face.sampleID
            latestFace = face
            if let baseline, baseline.generation == face.generation,
               baseline.contextKey == face.contextKey {
                faceBaseline = baseline
            }
        }

        let body: PostureRichGeometryMetrics?
        switch source {
        case .combined, .body:
            body = geometry.flatMap { candidate in
                candidate.generation == idGeneration && now >= candidate.capturedAt &&
                    now - candidate.capturedAt <= configuration.bodyTTL ? candidate : nil
            }
        case .face:
            if let cached = latestBody,
               now >= cached.capturedAt,
               now - cached.capturedAt <= configuration.bodyTTL {
                body = cached
            } else {
                resetBodyStateOnly()
                latestBody = nil
                body = nil
            }
        case .invalidateBody:
            body = nil
        }
        let usableFace: PostureFaceObservation?
        switch source {
        case .combined, .face:
            usableFace = face.flatMap { candidate in
                candidate.generation == idGeneration && now >= candidate.capturedAt &&
                    now - candidate.capturedAt <= configuration.faceTTL ? candidate : nil
            }
        case .body:
            if let pairedFace {
                let isPaired = pairedFace.generation == idGeneration &&
                    pairedFace.contextKey == key &&
                    pairedFace.capturedAt.isFinite &&
                    now >= pairedFace.capturedAt &&
                    now - pairedFace.capturedAt <= configuration.faceTTL &&
                    geometry.map {
                        abs(pairedFace.capturedAt - $0.capturedAt) <= configuration.maximumFusionSkew
                    } == true
                if isPaired {
                    // Cette paire capturée avec le corps sert uniquement à la
                    // géométrie fusionnée. Elle ne remplace pas le visage mis
                    // en cache et n'avance donc ni clignement ni état facial.
                    usableFace = pairedFace
                } else {
                    usableFace = nil
                }
            } else if let cached = latestFace,
                      now >= cached.capturedAt,
                      now - cached.capturedAt <= configuration.faceTTL {
                usableFace = cached
            } else {
                usableFace = nil
            }
        case .invalidateBody:
            if let cached = latestFace,
               now >= cached.capturedAt,
               now - cached.capturedAt <= configuration.faceTTL {
                usableFace = cached
            } else {
                usableFace = nil
            }
        }
        let contextMismatch = body != nil && usableFace != nil &&
            body!.contextKey != usableFace!.contextKey
        let paired = body != nil && usableFace != nil && !contextMismatch &&
            body!.generation == usableFace!.generation &&
            abs(body!.capturedAt - usableFace!.capturedAt) <= configuration.maximumFusionSkew
        // Body-only measurements remain valid when a cached face anchor has a
        // different stable context; only fused face/body metrics are withheld.
        let bodyForEvaluation = body
        // Face metrics remain independently usable when a cached body sample
        // is outside the bounded fusion skew. Only cross-source derivations
        // are withheld; a stale/unpaired body must not starve the 10 Hz face
        // stream.
        let faceForEvaluation = usableFace
        let bodyBaselineUsable = (baseline.flatMap {
            $0.generation == body?.generation && $0.contextKey == body?.contextKey ? $0 : nil
        } ?? bodyBaseline)
        let faceBaselineUsable = (baseline.flatMap {
            $0.generation == usableFace?.generation && $0.contextKey == usableFace?.contextKey ? $0 : nil
        } ?? faceBaseline)
        let baselineUsable: PostureRichBaseline? = if paired {
            baseline.flatMap { $0.contextKey == body?.contextKey && $0.contextKey == usableFace?.contextKey ? $0 : nil }
                ?? (bodyBaseline?.contextKey == usableFace?.contextKey ? bodyBaseline : nil)
                ?? (faceBaseline?.contextKey == body?.contextKey ? faceBaseline : nil)
        } else {
            nil
        }

        let bodyInvalidationReason = source == .invalidateBody ? explicitReason : nil
        let torsoValue = bodyForEvaluation?.torsoInclinationDegrees
        let torsoReason = bodyInvalidationReason ??
            (bodyBaselineUsable?.torsoInclinationDegrees == nil ? "baseline torse absente" : nil)
        let torsoAttention: Bool
        if let torsoValue, bodyForEvaluation?.torsoState == .available,
           let neutral = bodyBaselineUsable?.torsoInclinationDegrees, torsoReason == nil {
            let dispersion = (bodyBaselineUsable?.torsoInclinationMAD ?? 0) * 1.4826 * 2
            if source == .face || source == .invalidateBody {
                torsoAttention = torsoState.active
            } else {
                torsoAttention = torsoState.update(
                    deviation: torsoValue - neutral, timestamp: idTimestamp,
                    enterThreshold: max(configuration.torsoEnterDegrees, dispersion),
                    exitThreshold: max(configuration.torsoExitDegrees, dispersion * 0.5),
                    requiredDuration: configuration.requiredDuration,
                    maximumGap: configuration.maximumSampleGap
                )
            }
        } else {
            // A face-only tick deliberately carries no body geometry. Keep
            // the body machine alive; explicit body loss/error calls reset()
            // through the runtime coordinator.
            if source == .body || source == .combined { torsoState.reset() }
            torsoAttention = false
        }
        let torsoReferenceDelta: Double? = if let torsoValue,
            let neutral = bodyBaselineUsable?.torsoInclinationDegrees {
            torsoValue - neutral
        } else { nil }
        let torso = PostureRichScalarObservation(
            kind: .torsoInclination, value: torsoValue,
            state: torsoReason == nil ? (bodyForEvaluation?.torsoState ?? .unavailable) : .unavailable,
            quality: torsoValue == nil ? .unavailable : (bodyForEvaluation?.torsoState == .available ? .good : .limited),
            generation: idGeneration, sampleID: idSample, capturedAt: idTimestamp,
            isEstimated2DProxy: true, isAttention: torsoAttention,
            reason: torsoReason ?? "",
            referenceDelta: torsoReferenceDelta
        )

        let slopeValue = body?.shoulderSlopeDegrees
        let slopeReason = bodyInvalidationReason ??
            (bodyBaselineUsable?.shoulderSlopeDegrees == nil ? "baseline pente absente" : nil)
        let slopeAttention: Bool
        if let slopeValue, body?.shouldersState == .available,
           let neutral = bodyBaselineUsable?.shoulderSlopeDegrees, slopeReason == nil {
            let dispersion = (bodyBaselineUsable?.shoulderSlopeMAD ?? 0) * 1.4826 * 2
            if source == .face || source == .invalidateBody {
                slopeAttention = shoulderSlopeState.active
            } else {
                slopeAttention = shoulderSlopeState.update(
                    deviation: slopeValue - neutral, timestamp: idTimestamp,
                    enterThreshold: max(configuration.shoulderSlopeEnterDegrees, dispersion),
                    exitThreshold: max(configuration.shoulderSlopeExitDegrees, dispersion * 0.5),
                    requiredDuration: configuration.requiredDuration,
                    maximumGap: configuration.maximumSampleGap
                )
            }
        } else {
            if source == .body || source == .combined { shoulderSlopeState.reset() }
            slopeAttention = false
        }
        let shoulderSlopeReferenceDelta: Double? = if let slopeValue,
            let neutral = bodyBaselineUsable?.shoulderSlopeDegrees {
            slopeValue - neutral
        } else { nil }
        let shoulderSlope = PostureRichScalarObservation(
            kind: .shoulderSlope, value: slopeValue,
            state: slopeReason == nil ? (body?.shouldersState ?? .unavailable) : .unavailable,
            quality: slopeValue == nil ? .unavailable : (body?.shouldersState == .available ? .good : .limited),
            generation: idGeneration, sampleID: idSample, capturedAt: idTimestamp,
            isEstimated2DProxy: true, isAttention: slopeAttention,
            reason: slopeReason ?? "",
            referenceDelta: shoulderSlopeReferenceDelta
        )

        // Ce signal est produit à la cadence corps, mais sa preuve nécessite
        // une paire visage/corps fraîche. Il compare deux droites dans le même
        // repère image : une rotation commune de la caméra s'annule.
        let headTiltValue: Double? = if paired { body?.headTiltDegrees } else { nil }
        let headTiltFaceQuality = faceForEvaluation.map {
            $0.facePointCount >= configuration.minimumFacePoints &&
                ($0.signal.yawProxy.map { $0.isFinite && abs($0) <= configuration.maximumYaw } ?? false) &&
                ($0.signal.eyeLineRollDegrees.map {
                    $0.isFinite && abs($0) <= configuration.maximumRollDegrees
                } ?? false)
        } ?? false
        let headTiltNeutral = bodyBaselineUsable?.headTiltDegrees
        let headTiltReason: String? = bodyInvalidationReason ?? {
            guard paired else { return "visage et épaules non appariés" }
            guard headTiltFaceQuality else { return "qualité visage insuffisante" }
            guard body?.shouldersState == .available, headTiltValue != nil else {
                return "deux épaules et orientation visage requises"
            }
            guard headTiltNeutral != nil else { return "baseline tête-épaules absente" }
            return nil
        }()
        let headTiltAttention: Bool
        if let headTiltValue,
           abs(headTiltValue) <= configuration.maximumHeadTiltDegrees,
           body?.shouldersState == .available,
           headTiltFaceQuality,
           let neutral = headTiltNeutral,
           headTiltReason == nil {
            let dispersion = (bodyBaselineUsable?.headTiltMAD ?? 0) * 1.4826 * 2
            if source == .face || source == .invalidateBody {
                headTiltAttention = headTiltState.active
            } else {
                headTiltAttention = headTiltState.update(
                    deviation: headTiltValue - neutral, timestamp: idTimestamp,
                    enterThreshold: max(configuration.headTiltEnterDegrees, dispersion),
                    exitThreshold: max(configuration.headTiltExitDegrees, dispersion * 0.5),
                    requiredDuration: configuration.requiredDuration,
                    maximumGap: configuration.maximumSampleGap
                )
            }
        } else {
            if source == .body || source == .combined { headTiltState.reset() }
            headTiltAttention = false
        }
        let headTiltReferenceDelta: Double? = if let headTiltValue, let neutral = headTiltNeutral {
            headTiltValue - neutral
        } else { nil }
        let headTilt = PostureRichScalarObservation(
            kind: .headTilt,
            value: headTiltValue,
            state: headTiltReason == nil
                ? (body?.headTiltState ?? .unavailable)
                : .unavailable,
            quality: headTiltValue == nil ? .unavailable
                : (headTiltFaceQuality && body?.shouldersState == .available ? .good : .limited),
            generation: idGeneration, sampleID: idSample, capturedAt: idTimestamp,
            isEstimated2DProxy: true, isAttention: headTiltAttention,
            reason: headTiltReason ?? "",
            referenceDelta: headTiltReferenceDelta
        )

        let openingValue = body?.shoulderOpeningRatio
        let openingReason: String? = bodyInvalidationReason ?? (!paired ? "visage et RTMPose non appariés" :
            baselineUsable?.shoulderOpeningRatio == nil ? "baseline ouverture absente" : nil)
        let openingAttention: Bool
        if let openingValue, body?.openingRatioState == .available,
           let neutral = baselineUsable?.shoulderOpeningRatio,
           neutral > 0, openingReason == nil {
            if source == .face || source == .invalidateBody {
                openingAttention = openingRatioAttentionState.active
            } else {
                openingAttention = openingRatioAttentionState.update(
                    deviation: log(neutral / openingValue), timestamp: idTimestamp,
                    enterThreshold: configuration.shoulderOpeningEnterDelta,
                    exitThreshold: configuration.shoulderOpeningExitDelta,
                    requiredDuration: configuration.requiredDuration,
                    maximumGap: configuration.maximumSampleGap,
                    usesMagnitude: false
                )
            }
        } else {
            if source == .body || source == .combined { openingRatioAttentionState.reset() }
            openingAttention = false
        }
        let openingReferenceDelta: Double? = if let openingValue,
            let neutral = baselineUsable?.shoulderOpeningRatio, neutral > 0 {
            openingValue / neutral - 1
        } else { nil }
        let opening = PostureRichScalarObservation(
            kind: .shoulderOpening, value: openingValue,
            state: openingReason == nil ? (body?.openingRatioState ?? .unavailable) : .unavailable,
            quality: openingValue == nil ? .unavailable : (body?.openingRatioState == .available ? .good : .limited),
            generation: idGeneration, sampleID: idSample, capturedAt: idTimestamp,
            isEstimated2DProxy: true, isAttention: openingAttention,
            reason: openingReason ?? "",
            referenceDelta: openingReferenceDelta
        )

        let leftDelta: Double? = if let value = body?.leftShoulderElevation,
                                    let neutral = bodyBaselineUsable?.leftShoulderElevation {
            value - neutral
        } else { nil }
        let rightDelta: Double? = if let value = body?.rightShoulderElevation,
                                     let neutral = bodyBaselineUsable?.rightShoulderElevation {
            value - neutral
        } else { nil }

        // Le filtre avance uniquement sur un nouvel échantillon corps. Un
        // tick visage republie les derniers deltas acceptés, tandis qu'un
        // saut rejette les deux côtés afin de ne pas fabriquer une élévation
        // bilatérale ou un épisode à partir d'un seul résultat aberrant.
        let filteredDeltas: (left: Double?, right: Double?, rejectedJump: Bool)
        switch source {
        case .body, .combined:
            switch shoulderRaiseFilter.consume(
                generation: idGeneration,
                contextKey: key,
                sampleID: body?.sampleID ?? idSample,
                capturedAt: body?.capturedAt ?? idTimestamp,
                left: leftDelta,
                right: rightDelta,
                maximumStep: configuration.shoulderElevationMaximumStep,
                maximumGap: configuration.maximumSampleGap
            ) {
            case .accepted:
                filteredDeltas = (leftDelta, rightDelta, false)
            case .rejectedJump:
                filteredDeltas = (nil, nil, true)
            }
        case .face:
            let accepted = shoulderRaiseFilter.acceptedDeltas
            filteredDeltas = (accepted.left, accepted.right, false)
        case .invalidateBody:
            filteredDeltas = (nil, nil, false)
        }
        let acceptedLeftDelta = filteredDeltas.left
        let acceptedRightDelta = filteredDeltas.right
        let raisedValue = [acceptedLeftDelta, acceptedRightDelta].compactMap { $0 }.max()
        let raiseClassification = classifyShoulderRaise(
            left: acceptedLeftDelta,
            right: acceptedRightDelta,
            enterThreshold: configuration.shoulderElevationEnterDelta
        )
        let raisedQuality: PostureSignalQuality = if filteredDeltas.rejectedJump {
            .limited
        } else if raisedValue == nil {
            .unavailable
        } else if body?.shouldersState == .available,
                  acceptedLeftDelta != nil, acceptedRightDelta != nil {
            .good
        } else {
            .limited
        }
        let raisedAttention: Bool
        if let raisedValue, raisedQuality == .good {
            if source == .face || source == .invalidateBody {
                raisedAttention = raisedState.active
            } else {
                raisedAttention = raisedState.update(
                    deviation: raisedValue, timestamp: idTimestamp,
                    enterThreshold: configuration.shoulderElevationEnterDelta,
                    exitThreshold: configuration.shoulderElevationExitDelta,
                    requiredDuration: configuration.requiredDuration,
                    maximumGap: configuration.maximumSampleGap
                )
            }
        } else {
            if source == .body || source == .combined { raisedState.reset() }
            raisedAttention = false
        }
        let raisedSignalState: PostureRichSignalState = if filteredDeltas.rejectedJump {
            .error
        } else if raisedValue == nil {
            body == nil ? .unavailable : .partial
        } else {
            body?.shouldersState ?? .unavailable
        }
        let raisedReason: String = if let bodyInvalidationReason {
            bodyInvalidationReason
        } else if filteredDeltas.rejectedJump {
            "saut d'élévation des épaules rejeté"
        } else if raisedValue == nil {
            "deux épaules et baseline requises"
        } else if raisedQuality != .good {
            "qualité des épaules insuffisante"
        } else {
            ""
        }
        let raised = PostureRichScalarObservation(
            kind: .shouldersRaised, value: raisedValue,
            state: raisedSignalState,
            quality: raisedQuality,
            generation: idGeneration, sampleID: idSample, capturedAt: idTimestamp,
            isEstimated2DProxy: true, isAttention: raisedAttention,
            reason: raisedReason,
            referenceDelta: raisedValue,
            leftShoulderDelta: acceptedLeftDelta,
            rightShoulderDelta: acceptedRightDelta,
            shoulderRaiseClassification: raiseClassification
        )

        let scale = faceForEvaluation?.faceScale
        let proximityRatio: Double? = if let scale, let neutral = faceBaselineUsable?.proximityScale,
            neutral > 0 { scale / neutral } else { nil }
        let faceQuality = faceForEvaluation.map {
            $0.facePointCount >= configuration.minimumFacePoints &&
                ($0.signal.yawProxy.map { abs($0) <= configuration.maximumProximityYaw } ?? false) &&
                ($0.signal.eyeLineRollDegrees.map { abs($0) <= configuration.maximumRollDegrees } ?? false)
        } ?? false
        let proximityReason = faceQuality
            ? (proximityRatio == nil ? "baseline proximité absente" : "")
            : "qualité visage insuffisante"
        let proximityAttention: Bool
        if let proximityRatio, faceQuality, proximityReason.isEmpty {
            if source == .body {
                proximityAttention = proximityState.active
            } else {
                proximityAttention = proximityState.update(
                    deviation: proximityRatio - 1, timestamp: idTimestamp,
                    enterThreshold: configuration.proximityEnterRatio - 1,
                    exitThreshold: configuration.proximityExitRatio - 1,
                    requiredDuration: configuration.proximityDuration,
                    maximumGap: configuration.maximumSampleGap
                )
            }
        } else {
            if source == .face || source == .combined { proximityState.reset() }
            proximityAttention = false
        }
        let proximity = PostureRichScalarObservation(
            kind: .proximity, value: proximityRatio,
            state: faceForEvaluation == nil ? .unavailable : faceQuality ? .available : .partial,
            quality: proximityRatio == nil ? .unavailable : faceQuality ? .good : .limited,
            generation: idGeneration, sampleID: idSample, capturedAt: idTimestamp,
            isEstimated2DProxy: true, isAttention: proximityAttention,
            reason: proximityReason,
            referenceDelta: proximityRatio.map { $0 - 1 }
        )

        let leftEyeOpening = faceForEvaluation?.signal.leftEyeOpeningRatio
        let rightEyeOpening = faceForEvaluation?.signal.rightEyeOpeningRatio
        let blinkOpeningBaseline = faceBaselineUsable?.blinkOpeningBaseline
        // Les baselines personnalisées sont le contrat attendu. Le fallback
        // historique reste par œil, jamais une moyenne gauche/droite.
        let leftOpeningReference = blinkOpeningBaseline?.leftEyeOpeningRatio
            ?? configuration.blinkBaselineOpeningRatio
        let rightOpeningReference = blinkOpeningBaseline?.rightEyeOpeningRatio
            ?? configuration.blinkBaselineOpeningRatio
        let blinkGood = faceForEvaluation.map {
            let leftEyeGood = $0.signal.leftEyeOpeningRatio.map {
                $0.isFinite && $0 >= 0
            } ?? false
            let rightEyeGood = $0.signal.rightEyeOpeningRatio.map {
                $0.isFinite && $0 >= 0
            } ?? false
            let yawGood = $0.signal.yawProxy.map {
                $0.isFinite && abs($0) <= configuration.maximumYaw
            } ?? false
            let rollGood = $0.signal.eyeLineRollDegrees.map {
                $0.isFinite && abs($0) <= configuration.maximumRollDegrees
            } ?? false
            return $0.facePointCount >= configuration.minimumFacePoints &&
                leftEyeGood && rightEyeGood && yawGood && rollGood &&
                leftOpeningReference.isFinite && leftOpeningReference > 0 &&
                rightOpeningReference.isFinite && rightOpeningReference > 0
        } ?? false
        let normalizedLeftEyeOpening: Double? = if let leftEyeOpening,
            leftOpeningReference.isFinite, leftOpeningReference > 0 {
            leftEyeOpening / leftOpeningReference
        } else { nil }
        let normalizedRightEyeOpening: Double? = if let rightEyeOpening,
            rightOpeningReference.isFinite, rightOpeningReference > 0 {
            rightEyeOpening / rightOpeningReference
        } else { nil }
        let advancesFace = source == .face || source == .combined
        let event: PostureBlinkEvent?
        if advancesFace, let usableFace = faceForEvaluation {
            event = blinkTracker.consume(generation: usableFace.generation,
                                         timestamp: usableFace.capturedAt,
                                         leftEyeOpeningRatio: normalizedLeftEyeOpening,
                                         rightEyeOpeningRatio: normalizedRightEyeOpening,
                                         qualityGood: blinkGood,
                                         configuration: configuration)
        } else {
            event = nil
        }
        let blinkValue = blinkTracker.ratePerMinute
        let blinkState: PostureRichSignalState = faceForEvaluation == nil ? .unavailable
            : !blinkGood ? .partial
            : blinkValue == nil || blinkTracker.liveObservableSeconds < configuration.blinkMinimumObservable
                ? .partial : .available
        if advancesFace, configuration.blinkTargetPerMinute == nil,
           let completedWindow = blinkTracker.takeCompletedWindow() {
            if case let .frozen(targetPerMinute) = blinkReference.ingest(completedWindow),
               targetPerMinute.isFinite, targetPerMinute > 0 {
                configuration.blinkTargetPerMinute = targetPerMinute
            }
        }
        let normalizedBlinkRate: Double? = {
            guard blinkState == .available, blinkGood, let blinkValue,
                  let target = configuration.blinkTargetPerMinute,
                  target.isFinite, target > 0 else { return nil }
            let value = blinkValue / target
            return value.isFinite ? value : nil
        }()
        let blinkPauseReminder: Bool
        if advancesFace, let usableFace = faceForEvaluation {
            let eyesOpen = normalizedLeftEyeOpening.map { $0 >= configuration.blinkOpenRatio } == true &&
                normalizedRightEyeOpening.map { $0 >= configuration.blinkOpenRatio } == true
            blinkPauseReminder = blinkPause.consume(
                generation: usableFace.generation,
                sampleID: usableFace.sampleID,
                timestamp: usableFace.capturedAt,
                eyesOpen: eyesOpen,
                qualityGood: blinkGood,
                maximumGap: configuration.blinkMaximumCountedInterval,
                reminderAfter: configuration.blinkPauseReminderAfter
            )
        } else {
            blinkPauseReminder = blinkPause.needsReminder
        }
        var blinkRateAssessment: PostureBlinkRateAssessment
        if advancesFace {
            let assessment: PostureBlinkRateAssessment
            if configuration.blinkTargetPerMinute != nil {
                assessment = blinkRateTracker.consume(
                    generation: idGeneration,
                    sampleID: idSample,
                    timestamp: idTimestamp,
                    normalizedRate: normalizedBlinkRate,
                    eligible: blinkGood && normalizedBlinkRate != nil,
                    configuration: configuration
                )
            } else {
                blinkRateTracker.reset()
                assessment = PostureBlinkRateAssessment(
                    normalizedValue: nil,
                    direction: .unknown,
                    belowDuration: 0,
                    recoveryDuration: 0,
                    quality: blinkState == .available && blinkGood ? .good : .limited,
                    reason: blinkState == .available
                        ? "débit fiable; repère personnel en cours"
                        : "fenêtre fiable insuffisante"
                )
            }
            latestBlinkRateAssessment = assessment
            blinkRateAssessment = assessment
        } else {
            blinkRateAssessment = latestBlinkRateAssessment ?? PostureBlinkRateAssessment(
                normalizedValue: normalizedBlinkRate,
                direction: normalizedBlinkRate.map {
                    $0 < configuration.blinkLowRateFraction ? .below : .neutral
                } ?? .unknown,
                belowDuration: blinkRateTracker.belowDuration,
                recoveryDuration: blinkRateTracker.recoveryDuration,
                quality: blinkState == .available ? .good : .limited,
                reason: "tick visage non avancé"
            )
        }
        if blinkPauseReminder {
            blinkRateAssessment = PostureBlinkRateAssessment(
                normalizedValue: 0,
                direction: .below,
                belowDuration: 0,
                recoveryDuration: 0,
                quality: .good,
                reason: "pause clignement prolongée : yeux ouverts depuis 20 secondes"
            )
        }
        let effectiveBlinkState: PostureRichSignalState = blinkPauseReminder ? .available : blinkState
        let blinkPublishedValue: Double? = blinkPauseReminder ? (blinkValue ?? 0) : blinkValue
        let blinkNumericValue: Double? = if blinkPauseReminder &&
            blinkTracker.liveObservableSeconds < configuration.blinkMinimumObservable {
            nil
        } else {
            blinkValue
        }
        let blinkReason: String = {
            if blinkPauseReminder {
                return blinkRateAssessment.reason
            }
            if blinkState == .partial,
               blinkTracker.liveObservableSeconds < configuration.blinkMinimumObservable {
                let observedValue = blinkTracker.liveObservableSeconds.isFinite
                    ? max(0, blinkTracker.liveObservableSeconds) : 0
                let requiredValue = configuration.blinkMinimumObservable.isFinite
                    ? max(0, configuration.blinkMinimumObservable) : 0
                let observed = String(format: "%.0f", floor(observedValue))
                let required = String(format: "%.0f", requiredValue)
                let progress = observed + "/" + required + " s"
                if faceForEvaluation == nil {
                    return "Visage indisponible"
                }
                if !blinkGood {
                    return "Suivi des yeux intermittent"
                }
                return "Yeux observés : " + progress
            }
            return blinkRateAssessment.reason.isEmpty
                ? (blinkState == .partial ? "Suivi des yeux insuffisant" : "")
                : blinkRateAssessment.reason
        }()
        let blink = PostureRichScalarObservation(
            kind: .blinkRate, value: blinkPublishedValue, state: effectiveBlinkState,
            quality: blinkGood ? .good : .limited,
            generation: idGeneration, sampleID: idSample, capturedAt: idTimestamp,
            isEstimated2DProxy: false,
            // Le tracker CV est l'autorité de l'épisode sous la cible. L'étage
            // produit n'a donc pas à refaire une fenêtre temporelle.
            isAttention: blinkPauseReminder || (blinkRateAssessment.direction == .below &&
                blinkRateAssessment.belowDuration >= configuration.blinkLowRateDuration),
            reason: blinkReason,
            numericValue: blinkNumericValue,
            numericValueProvided: blinkPauseReminder,
            normalizedValue: blinkRateAssessment.normalizedValue,
            direction: blinkRateAssessment.direction,
            belowDuration: blinkRateAssessment.belowDuration
        )

        return PostureRichEvaluation(torsoInclination: torso, shoulderSlope: shoulderSlope,
                                     headTilt: headTilt,
                                     shoulderOpening: opening,
                                     shouldersRaised: raised, proximity: proximity,
                                     blinkRate: blink, blinkEvent: event,
                                     blinkRateAssessment: blinkRateAssessment)
    }

    private func classifyShoulderRaise(
        left: Double?,
        right: Double?,
        enterThreshold: Double
    ) -> PostureShoulderRaiseClassification {
        guard let left, let right,
              enterThreshold.isFinite, enterThreshold >= 0,
              left.isFinite, right.isFinite else {
            return .unavailable
        }
        let leftRaised = left >= enterThreshold
        let rightRaised = right >= enterThreshold
        switch (leftRaised, rightRaised) {
        case (true, true): return .bilateral
        case (true, false): return .unilateralLeft
        case (false, true): return .unilateralRight
        case (false, false): return .none
        }
    }

    private mutating func resetBodyStateOnly() {
        torsoState.reset()
        shoulderSlopeState.reset()
        headTiltState.reset()
        openingRatioAttentionState.reset()
        raisedState.reset()
        shoulderRaiseFilter.reset()
    }

    private mutating func resetFaceStateOnly() {
        proximityState.reset()
        headTiltState.reset()
        blinkTracker.reset()
        blinkRateTracker.reset()
        blinkPause.reset()
        blinkReference.reset()
        latestBlinkRateAssessment = nil
    }

    private mutating func resetBodyCache() {
        latestBody = nil
        bodyGeneration = nil
        bodyContextKey = nil
        bodyLastTimestamp = nil
        bodyLastSampleID = nil
        bodyBaseline = nil
    }

    private mutating func resetFaceCache() {
        latestFace = nil
        faceGeneration = nil
        faceContextKey = nil
        faceLastTimestamp = nil
        faceLastSampleID = nil
        faceBaseline = nil
        latestBlinkRateAssessment = nil
    }

    private func unavailableEvaluation(generation: UInt64, sampleID: UInt64,
                                       capturedAt: TimeInterval, reason: String) -> PostureRichEvaluation {
        let values = PostureRichSignalKind.allCases.map {
            PostureRichScalarObservation.unavailable($0, generation: generation,
                                                     sampleID: sampleID, capturedAt: capturedAt,
                                                     reason: reason)
        }
        let blinkRateAssessment = PostureBlinkRateAssessment(
            normalizedValue: nil, direction: .unknown, belowDuration: 0,
            recoveryDuration: 0, quality: .unavailable, reason: reason
        )
        func value(_ kind: PostureRichSignalKind) -> PostureRichScalarObservation {
            values.first { $0.kind == kind } ??
                .unavailable(kind, generation: generation, sampleID: sampleID,
                             capturedAt: capturedAt, reason: reason)
        }
        return PostureRichEvaluation(
                                     torsoInclination: value(.torsoInclination),
                                     shoulderSlope: value(.shoulderSlope),
                                     headTilt: value(.headTilt),
                                     shoulderOpening: value(.shoulderOpening),
                                     shouldersRaised: value(.shouldersRaised),
                                     proximity: value(.proximity),
                                     blinkRate: value(.blinkRate), blinkEvent: nil,
                                     blinkRateAssessment: blinkRateAssessment)
    }
}

nonisolated enum PostureStatisticsGranularity: String, Hashable, Sendable {
    case day
    case week
    case month
}

nonisolated struct PostureStatisticsKey: Hashable, Sendable {
    let granularity: PostureStatisticsGranularity
    let year: Int
    let month: Int
    let weekOfYear: Int
    let day: Int

    static func keys(for date: Date, calendar: Calendar = .current) -> [Self] {
        let components = calendar.dateComponents([.year, .month, .weekOfYear, .day], from: date)
        guard let year = components.year, let month = components.month,
              let week = components.weekOfYear, let day = components.day else { return [] }
        return [
            Self(granularity: .day, year: year, month: month, weekOfYear: week, day: day),
            Self(granularity: .week, year: year, month: month, weekOfYear: week, day: 0),
            Self(granularity: .month, year: year, month: month, weekOfYear: 0, day: 0)
        ]
    }
}

nonisolated struct PostureStatisticsCounter: Equatable, Sendable {
    var attentionEvents = 0
    var observableSeconds = 0.0
    var blinkEvents = 0
}

/// Matrice simple pour les fixtures d'évaluation : le profil sensible cherche
/// d'abord à réduire les faux négatifs, sans masquer les faux positifs.
nonisolated struct PostureConfusionMatrix: Equatable, Sendable {
    let truePositive: Int
    let trueNegative: Int
    let falsePositive: Int
    let falseNegative: Int

    static func make(expected: [Bool], predicted: [Bool]) -> Self? {
        guard expected.count == predicted.count else { return nil }
        var matrix = Self(truePositive: 0, trueNegative: 0, falsePositive: 0, falseNegative: 0)
        for (truth, guess) in zip(expected, predicted) {
            if truth && guess {
                matrix = Self(truePositive: matrix.truePositive + 1,
                              trueNegative: matrix.trueNegative,
                              falsePositive: matrix.falsePositive,
                              falseNegative: matrix.falseNegative)
            } else if !truth && !guess {
                matrix = Self(truePositive: matrix.truePositive,
                              trueNegative: matrix.trueNegative + 1,
                              falsePositive: matrix.falsePositive,
                              falseNegative: matrix.falseNegative)
            } else if guess {
                matrix = Self(truePositive: matrix.truePositive,
                              trueNegative: matrix.trueNegative,
                              falsePositive: matrix.falsePositive + 1,
                              falseNegative: matrix.falseNegative)
            } else {
                matrix = Self(truePositive: matrix.truePositive,
                              trueNegative: matrix.trueNegative,
                              falsePositive: matrix.falsePositive,
                              falseNegative: matrix.falseNegative + 1)
            }
        }
        return matrix
    }
}

nonisolated struct PostureLocalStatistics: Equatable, Sendable {
    private(set) var counters: [PostureStatisticsKey: PostureStatisticsCounter] = [:]

    mutating func record(
        at wallClockDate: Date,
        calendar: Calendar = .current,
        attentionEvents: Int = 0,
        observableSeconds: TimeInterval = 0,
        blinkEvents: Int = 0
    ) {
        guard attentionEvents >= 0, blinkEvents >= 0,
              observableSeconds.isFinite, observableSeconds >= 0 else { return }
        for key in PostureStatisticsKey.keys(for: wallClockDate, calendar: calendar) {
            var counter = counters[key, default: .init()]
            counter.attentionEvents += attentionEvents
            counter.observableSeconds += observableSeconds
            counter.blinkEvents += blinkEvents
            counters[key] = counter
        }
    }
}
