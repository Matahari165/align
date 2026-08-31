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
    let normalizedValue: Double?
    let direction: PostureRichSignalDirection
    /// Durée continue sous le seuil, lorsqu'un évaluateur temporel la fournit.
    /// Elle permet à l'intégrateur de décider d'une alerte sans recalculer les
    /// intervalles; ce snapshot CV n'autorise aucune notification.
    let belowDuration: TimeInterval?

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
        normalizedValue: Double? = nil,
        direction: PostureRichSignalDirection = .unknown,
        belowDuration: TimeInterval? = nil
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
        self.normalizedValue = normalizedValue
        self.direction = direction
        self.belowDuration = belowDuration
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
    let shoulderOpeningDegrees: Double?
    let shoulderOpeningRatio: Double?
    let leftShoulderElevation: Double?
    let rightShoulderElevation: Double?
    let proximityScale: Double?
    let shouldersState: PostureRichSignalState
    let torsoState: PostureRichSignalState
    let openingState: PostureRichSignalState
    let reason: String?

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
             shouldersState: state, torsoState: state, openingState: state,
             reason: reason)
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
        let faceMatchesContext = face.map { $0.contextKey == context.stableContextKey } ?? true
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
            torsoInclination = axialAngleDegrees(
                dx: Double(hipMid.x - shoulderMid.x),
                dy: Double(hipMid.y - shoulderMid.y)
            )
            let dx = Double(hipMid.x - shoulderMid.x)
            let dy = Double(hipMid.y - shoulderMid.y)
            let normalized = dx / max(abs(dy), 0.000001)
            torsoAxisDeviation = normalized.isFinite ? normalized : nil
            let good = [UpperBodyLandmarkID.leftShoulder, .rightShoulder, .leftHip, .rightHip]
                .allSatisfy { qualityGood[$0] == true }
            torsoState = torsoInclination != nil ? (good ? .available : .partial) : .unavailable
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
            reason: reason
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
}

nonisolated struct PostureRichBaseline: Equatable, Codable, Sendable {
    let generation: UInt64
    let contextKey: String
    let ruleVersion: String
    let torsoInclinationDegrees: Double?
    let torsoAxisDeviation: Double?
    let shoulderSlopeDegrees: Double?
    let shoulderOpeningRatio: Double?
    let leftShoulderElevation: Double?
    let rightShoulderElevation: Double?
    let proximityScale: Double?
    let sampleCount: Int
    let torsoInclinationMAD: Double?
    let torsoAxisMAD: Double?
    let shoulderSlopeMAD: Double?
}

nonisolated enum PostureRichBaselineBuilder {
    static func make(
        samples: [PostureRichGeometryMetrics],
        generation: UInt64,
        contextKey: String,
        ruleVersion: String = "rich-v1",
        minimumSamples: Int = 12,
        maximumSampleGap: TimeInterval = 1.50
    ) -> PostureRichBaseline? {
        guard minimumSamples > 0,
              maximumSampleGap.isFinite, maximumSampleGap > 0,
              samples.allSatisfy({ $0.generation == generation && $0.contextKey == contextKey &&
                  $0.capturedAt.isFinite }) else {
            return nil
        }
        // Une baseline ne doit jamais absorber une observation partielle :
        // on filtre les frames dont toutes les familles requises ne sont pas
        // disponibles, puis on exige le minimum sur les seules frames good.
        let eligibleSamples = samples.filter {
            $0.shouldersState == .available &&
                $0.torsoState == .available &&
                $0.openingState == .available
        }
        guard eligibleSamples.count >= minimumSamples else { return nil }
        for pair in zip(eligibleSamples, eligibleSamples.dropFirst()) {
            guard pair.1.capturedAt > pair.0.capturedAt,
                  pair.1.capturedAt - pair.0.capturedAt <= maximumSampleGap else { return nil }
        }
        return PostureRichBaseline(
            generation: generation,
            contextKey: contextKey,
            ruleVersion: ruleVersion,
            torsoInclinationDegrees: median(eligibleSamples.compactMap(\.torsoInclinationDegrees)),
            torsoAxisDeviation: median(eligibleSamples.compactMap(\.torsoAxisDeviation)),
            shoulderSlopeDegrees: median(eligibleSamples.compactMap(\.shoulderSlopeDegrees)),
            shoulderOpeningRatio: median(eligibleSamples.compactMap(\.shoulderOpeningRatio)),
            leftShoulderElevation: median(eligibleSamples.compactMap(\.leftShoulderElevation)),
            rightShoulderElevation: median(eligibleSamples.compactMap(\.rightShoulderElevation)),
            proximityScale: median(eligibleSamples.compactMap(\.proximityScale)),
            sampleCount: eligibleSamples.count,
            torsoInclinationMAD: mad(eligibleSamples.compactMap(\.torsoInclinationDegrees)),
            torsoAxisMAD: mad(eligibleSamples.compactMap(\.torsoAxisDeviation)),
            shoulderSlopeMAD: mad(eligibleSamples.compactMap(\.shoulderSlopeDegrees))
        )
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
    var shoulderOpeningEnterDelta: Double = 0.08
    var shoulderOpeningExitDelta: Double = 0.04
    var shoulderElevationEnterDelta: Double = 0.04
    var shoulderElevationExitDelta: Double = 0.02
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
    var blinkWindow: TimeInterval = 60
    var blinkMinimumObservable: TimeInterval = 30
    /// Pas de fréquence universelle : la cible est fournie par calibration/produit.
    var blinkTargetPerMinute: Double?
    /// Fraction de la cible personnelle déclenchant la direction `.below`.
    /// Le contrat produit l'autorise entre 0,50 et 0,90 (défaut 0,70).
    var blinkLowRateFraction: Double = 0.70
    /// Durée d'éligibilité continue sous le seuil (cinq minutes par défaut).
    var blinkLowRateDuration: TimeInterval = 5 * 60
    /// Durée au-dessus du seuil pour considérer une récupération.
    var blinkRecoveryDuration: TimeInterval = 2 * 60
    /// Une absence visage/yeux suspend au plus cette durée avant reset.
    var blinkMaximumSuspension: TimeInterval = 10
    /// Intervalle maximal implicitement continu à 10 Hz. Au-delà, le trou
    /// n'est jamais compté, même si une frame valide réapparaît ensuite.
    var blinkMaximumCountedInterval: TimeInterval = 0.25

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

/// Détecteur open -> closed -> open. Le dénominateur est exclusivement la
/// durée entre deux visages valides et suffisamment qualitatifs.
nonisolated struct PostureBlinkTracker: Equatable, Sendable {
    private(set) var phase: PostureBlinkPhase = .open
    private(set) var observableSeconds: TimeInterval = 0
    private(set) var events: [PostureBlinkEvent] = []
    private var closedStartedAt: TimeInterval?
    private var lastValidAt: TimeInterval?
    private var lastGoodAt: TimeInterval?
    private var lastObservedAt: TimeInterval?
    private var generation: UInt64?
    private var windowStartedAt: TimeInterval?

    mutating func reset() {
        phase = .open
        observableSeconds = 0
        events.removeAll(keepingCapacity: true)
        closedStartedAt = nil
        lastValidAt = nil
        lastGoodAt = nil
        lastObservedAt = nil
        generation = nil
        windowStartedAt = nil
    }

    mutating func consume(
        generation newGeneration: UInt64,
        timestamp: TimeInterval,
        openingRatio: Double?,
        qualityGood: Bool,
        configuration: PostureRichSignalConfiguration
    ) -> PostureBlinkEvent? {
        guard timestamp.isFinite, newGeneration > 0 else { return nil }
        if generation != newGeneration {
            reset()
            generation = newGeneration
        } else if let previous = lastObservedAt, timestamp <= previous {
            return nil
        }
        lastObservedAt = timestamp
        if let previous = lastGoodAt,
           timestamp - previous > configuration.blinkMaximumSuspension {
            reset()
            generation = newGeneration
            lastObservedAt = timestamp
        }
        guard qualityGood, let openingRatio, openingRatio.isFinite, openingRatio >= 0 else {
            phase = .open
            closedStartedAt = nil
            lastValidAt = nil
            return nil
        }
        if let previous = lastGoodAt,
           timestamp - previous > configuration.blinkMaximumGap {
            phase = .open
            closedStartedAt = nil
        }
        if let windowStartedAt,
           timestamp - windowStartedAt >= configuration.blinkWindow {
            observableSeconds = 0
            events.removeAll(keepingCapacity: true)
            self.windowStartedAt = timestamp
        } else if self.windowStartedAt == nil {
            self.windowStartedAt = timestamp
        }
        if let previous = lastValidAt {
            let delta = timestamp - previous
            if delta > 0,
               delta <= min(configuration.blinkMaximumGap,
                            configuration.blinkMaximumCountedInterval) {
                observableSeconds += delta
            }
        }
        lastValidAt = timestamp
        lastGoodAt = timestamp
        if phase == .open, openingRatio <= configuration.blinkCloseRatio {
            phase = .closed
            closedStartedAt = timestamp
            return nil
        }
        guard phase == .closed, openingRatio >= configuration.blinkOpenRatio,
              let started = closedStartedAt else { return nil }
        phase = .open
        closedStartedAt = nil
        let duration = timestamp - started
        guard duration >= configuration.blinkMinimumClosed,
              duration <= configuration.blinkMaximumClosed else { return nil }
        let event = PostureBlinkEvent(generation: newGeneration, startedAt: started,
                                      endedAt: timestamp, duration: duration)
        events.append(event)
        return event
    }

    var ratePerMinute: Double? {
        guard observableSeconds > 0 else { return nil }
        let value = Double(events.count) / observableSeconds * 60
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

nonisolated struct PostureRichEvaluation: Equatable, Sendable {
    let torsoInclination: PostureRichScalarObservation
    let shoulderSlope: PostureRichScalarObservation
    let shoulderOpening: PostureRichScalarObservation
    let shouldersRaised: PostureRichScalarObservation
    let proximity: PostureRichScalarObservation
    let blinkRate: PostureRichScalarObservation
    let blinkEvent: PostureBlinkEvent?
    let blinkRateAssessment: PostureBlinkRateAssessment
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
    private var openingState = PostureRichSustainedState()
    private var raisedState = PostureRichSustainedState()
    private var proximityState = PostureRichSustainedState()
    private var blinkTracker = PostureBlinkTracker()
    private var blinkRateTracker = PostureBlinkRateTracker()
    /// Repère automatique établi une seule fois après une fenêtre visage/yeux
    /// observable suffisante. Il reste local à la génération et n'est jamais
    /// déduit d'une norme populationnelle.
    private var automaticBlinkTargetPerMinute: Double?

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
    }

    mutating func setBlinkTarget(_ target: Double?) {
        configuration.blinkTargetPerMinute = target
        automaticBlinkTargetPerMinute = target
    }

    mutating func reset() {
        generation = nil
        contextKey = nil
        lastAcceptedTimestamp = nil
        lastAcceptedSampleID = nil
        torsoState.reset(); shoulderSlopeState.reset(); openingState.reset(); raisedState.reset(); proximityState.reset()
        blinkTracker.reset()
        blinkRateTracker.reset()
        automaticBlinkTargetPerMinute = nil
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
        baseline: PostureRichBaseline? = nil,
        now: TimeInterval
    ) -> PostureRichEvaluation {
        consumeInternal(geometry: geometry, face: nil, baseline: baseline,
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
            torsoState.reset(); shoulderSlopeState.reset(); openingState.reset(); raisedState.reset(); proximityState.reset()
            blinkTracker.reset()
            // La cible automatique et l'épisode de débit sont liés au même
            // contexte stable; aucun état de l'ancien contexte ne traverse
            // une nouvelle génération ou un nouveau cadrage.
            blinkRateTracker.reset()
            automaticBlinkTargetPerMinute = nil
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
        case .body, .invalidateBody:
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
        let torso = PostureRichScalarObservation(
            kind: .torsoInclination, value: torsoValue,
            state: torsoReason == nil ? (bodyForEvaluation?.torsoState ?? .unavailable) : .unavailable,
            quality: torsoValue == nil ? .unavailable : (bodyForEvaluation?.torsoState == .available ? .good : .limited),
            generation: idGeneration, sampleID: idSample, capturedAt: idTimestamp,
            isEstimated2DProxy: true, isAttention: torsoAttention,
            reason: torsoReason ?? ""
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
        let shoulderSlope = PostureRichScalarObservation(
            kind: .shoulderSlope, value: slopeValue,
            state: slopeReason == nil ? (body?.shouldersState ?? .unavailable) : .unavailable,
            quality: slopeValue == nil ? .unavailable : (body?.shouldersState == .available ? .good : .limited),
            generation: idGeneration, sampleID: idSample, capturedAt: idTimestamp,
            isEstimated2DProxy: true, isAttention: slopeAttention,
            reason: slopeReason ?? ""
        )

        let openingValue = body?.shoulderOpeningRatio
        let openingReason: String? = bodyInvalidationReason ?? (!paired ? "visage et RTMPose non appariés" :
            baselineUsable?.shoulderOpeningRatio == nil ? "baseline ouverture absente" : nil)
        let openingAttention: Bool
        if let openingValue, body?.openingState == .available,
           let neutral = baselineUsable?.shoulderOpeningRatio,
           neutral > 0, openingReason == nil {
            if source == .face || source == .invalidateBody {
                openingAttention = openingState.active
            } else {
                openingAttention = openingState.update(
                    deviation: log(neutral / openingValue), timestamp: idTimestamp,
                    enterThreshold: configuration.shoulderOpeningEnterDelta,
                    exitThreshold: configuration.shoulderOpeningExitDelta,
                    requiredDuration: configuration.requiredDuration,
                    maximumGap: configuration.maximumSampleGap,
                    usesMagnitude: false
                )
            }
        } else {
            if source == .body || source == .combined { openingState.reset() }
            openingAttention = false
        }
        let opening = PostureRichScalarObservation(
            kind: .shoulderOpening, value: openingValue,
            state: openingReason == nil ? (body?.openingState ?? .unavailable) : .unavailable,
            quality: openingValue == nil ? .unavailable : (body?.openingState == .available ? .good : .limited),
            generation: idGeneration, sampleID: idSample, capturedAt: idTimestamp,
            isEstimated2DProxy: true, isAttention: openingAttention,
            reason: openingReason ?? ""
        )

        let leftDelta: Double? = if let value = body?.leftShoulderElevation,
                                    let neutral = baselineUsable?.leftShoulderElevation {
            value - neutral
        } else { nil }
        let rightDelta: Double? = if let value = body?.rightShoulderElevation,
                                     let neutral = baselineUsable?.rightShoulderElevation {
            value - neutral
        } else { nil }
        let raisedValue: Double? = if body?.shouldersState == .available,
                                       let leftDelta, let rightDelta {
            // Ne pas annuler une élévation unilatérale par une moyenne :
            // l'arbitre dispose toujours des deux deltas bruts ci-dessus.
            max(leftDelta, rightDelta)
        } else { nil }
        let raisedAttention: Bool
        if let raisedValue {
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
        let raised = PostureRichScalarObservation(
            kind: .shouldersRaised, value: raisedValue,
            state: raisedValue == nil ? .partial : (body?.shouldersState ?? .unavailable),
            quality: raisedValue == nil ? .limited : .good,
            generation: idGeneration, sampleID: idSample, capturedAt: idTimestamp,
            isEstimated2DProxy: true, isAttention: raisedAttention,
            reason: bodyInvalidationReason ?? (raisedValue == nil ? "deux épaules et baseline requises" : "")
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
            reason: proximityReason
        )

        let eyeOpening: Double?
        if let face = faceForEvaluation,
           let left = face.signal.leftEyeOpeningRatio,
           let right = face.signal.rightEyeOpeningRatio {
            eyeOpening = (left + right) / 2
        } else {
            eyeOpening = nil
        }
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
                leftEyeGood && rightEyeGood && yawGood && rollGood
        } ?? false
        let normalizedEyeOpening: Double?
        if let eyeOpening, configuration.blinkBaselineOpeningRatio.isFinite,
           configuration.blinkBaselineOpeningRatio > 0 {
            normalizedEyeOpening = eyeOpening / configuration.blinkBaselineOpeningRatio
        } else {
            normalizedEyeOpening = nil
        }
        let advancesFace = source == .face || source == .combined
        let event: PostureBlinkEvent?
        if advancesFace, let usableFace = faceForEvaluation {
            event = blinkTracker.consume(generation: usableFace.generation,
                                         timestamp: usableFace.capturedAt,
                                         openingRatio: normalizedEyeOpening,
                                         qualityGood: blinkGood,
                                         configuration: configuration)
        } else {
            event = nil
        }
        let blinkValue = blinkTracker.ratePerMinute
        let blinkState: PostureRichSignalState = faceForEvaluation == nil ? .unavailable
            : !blinkGood ? .partial
            : blinkValue == nil || blinkTracker.observableSeconds < configuration.blinkMinimumObservable
                ? .partial : .available
        if advancesFace, automaticBlinkTargetPerMinute == nil,
           blinkState == .available,
           let blinkValue,
           blinkValue.isFinite, blinkValue > 0 {
            automaticBlinkTargetPerMinute = blinkValue
        }
        let normalizedBlinkRate: Double? = {
            guard blinkState == .available, blinkGood, let blinkValue,
                  let target = configuration.blinkTargetPerMinute ?? automaticBlinkTargetPerMinute,
                  target.isFinite, target > 0 else { return nil }
            let value = blinkValue / target
            return value.isFinite ? value : nil
        }()
        let blinkRateAssessment: PostureBlinkRateAssessment
        if advancesFace {
            let assessment = blinkRateTracker.consume(
                generation: idGeneration,
                sampleID: idSample,
                timestamp: idTimestamp,
                normalizedRate: normalizedBlinkRate,
                eligible: blinkGood && normalizedBlinkRate != nil,
                configuration: configuration
            )
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
        let blink = PostureRichScalarObservation(
            kind: .blinkRate, value: blinkValue, state: blinkState,
            quality: blinkGood ? .good : .limited,
            generation: idGeneration, sampleID: idSample, capturedAt: idTimestamp,
            isEstimated2DProxy: false,
            // Le tracker CV a déjà calculé la durée continue; l'étage runtime
            // consomme cette preuve sans refaire la fenêtre de cinq minutes.
            isAttention: false,
            reason: blinkRateAssessment.reason.isEmpty
                ? (blinkState == .partial ? "durée visage observable insuffisante" : "")
                : blinkRateAssessment.reason,
            normalizedValue: blinkRateAssessment.normalizedValue,
            direction: blinkRateAssessment.direction,
            belowDuration: blinkRateAssessment.belowDuration
        )

        return PostureRichEvaluation(torsoInclination: torso, shoulderSlope: shoulderSlope,
                                     shoulderOpening: opening,
                                     shouldersRaised: raised, proximity: proximity,
                                     blinkRate: blink, blinkEvent: event,
                                     blinkRateAssessment: blinkRateAssessment)
    }

    private mutating func resetBodyStateOnly() {
        torsoState.reset()
        shoulderSlopeState.reset()
        openingState.reset()
        raisedState.reset()
    }

    private mutating func resetFaceStateOnly() {
        proximityState.reset()
        blinkTracker.reset()
        blinkRateTracker.reset()
        automaticBlinkTargetPerMinute = nil
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
        return PostureRichEvaluation(torsoInclination: values[0], shoulderSlope: values[1],
                                     shoulderOpening: values[2], shouldersRaised: values[3],
                                     proximity: values[4], blinkRate: values[5], blinkEvent: nil,
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
