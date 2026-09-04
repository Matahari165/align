import CoreGraphics
import Foundation

/// Rectangle facial minimal utilisé pour suivre une cible dans l'image.
///
/// Ce contrat est volontairement non biométrique : il ne contient ni image,
/// ni landmark, ni identifiant d'observation Vision, ni descripteur du visage.
/// Le rectangle est exprimé dans l'espace normalisé Vision (origine en bas à
/// gauche) et reste borné à [0, 1].
nonisolated struct FaceBoxCandidate: Equatable, Sendable {
    let boundingBox: CGRect

    init?(boundingBox: CGRect) {
        guard Self.isValid(boundingBox) else { return nil }
        self.boundingBox = boundingBox
    }

    static func isValid(_ rectangle: CGRect) -> Bool {
        rectangle.origin.x.isFinite && rectangle.origin.y.isFinite &&
            rectangle.size.width.isFinite && rectangle.size.height.isFinite &&
            rectangle.minX >= 0 && rectangle.minY >= 0 &&
            rectangle.maxX <= 1 && rectangle.maxY <= 1 &&
            rectangle.width > 0 && rectangle.height > 0
    }

    var center: CGPoint {
        CGPoint(x: boundingBox.midX, y: boundingBox.midY)
    }

    var area: CGFloat {
        boundingBox.width * boundingBox.height
    }
}

/// Seuils de continuité spatiale. Ils ne constituent pas une vérité physique
/// ni un résultat benchmarké : le futur intégrateur peut les ajuster après des
/// séquences Release sur la caméra de référence.
nonisolated struct FaceTargetContinuityConfiguration: Equatable, Sendable {
    /// Un suivi Vision sans nouvelle détection ne doit pas traverser un trou
    /// de capture plus long que cette durée.
    var maximumGap: TimeInterval = 0.50
    /// Déplacement maximal du centre entre deux observations associées.
    var maximumCenterDistance: CGFloat = 0.25
    /// Variation multiplicative maximale de largeur et de hauteur. Une valeur
    /// de 0.60 autorise une taille comprise entre 40 % et 160 % de la cible.
    var maximumRelativeSizeChange: CGFloat = 0.60
    /// IoU minimale lorsqu'elle suffit à établir un recouvrement spatial.
    var minimumIntersectionOverUnion: CGFloat = 0.05
    /// Score composite minimal pour une association faiblement recouverte.
    var minimumAssociationScore: CGFloat = 0.45
    /// Marge minimale entre les deux meilleurs candidats ; sous cette marge,
    /// la cible devient indisponible au lieu de basculer vers un autre visage.
    var minimumWinnerMargin: CGFloat = 0.12

    var isValid: Bool {
        maximumGap.isFinite && maximumGap > 0 &&
            maximumCenterDistance.isFinite && maximumCenterDistance > 0 &&
            maximumRelativeSizeChange.isFinite &&
            (0..<1).contains(maximumRelativeSizeChange) &&
            minimumIntersectionOverUnion.isFinite &&
            (0...1).contains(minimumIntersectionOverUnion) &&
            minimumAssociationScore.isFinite &&
            (0...1).contains(minimumAssociationScore) &&
            minimumWinnerMargin.isFinite &&
            (0...1).contains(minimumWinnerMargin)
    }

    static let `default` = Self()
}

nonisolated enum FaceTargetUnavailableReason: String, Equatable, Sendable {
    case noFace
    case multipleFaces
    case targetLost
    case trackingJump
    case trackingGap
    case noTarget
    case outOfOrder
    case invalidTimestamp
    case invalidCandidate
    case invalidConfiguration
    case rearmRequired
}

nonisolated struct FaceTargetMatch: Equatable, Sendable {
    let intersectionOverUnion: CGFloat
    let centerDistance: CGFloat
    /// Proximité de taille dans [0, 1] : 1 signifie même largeur et hauteur.
    let sizeSimilarity: CGFloat
    /// Score pondéré utilisé uniquement pour départager des boîtes spatiales.
    let score: CGFloat

    var isFinite: Bool {
        intersectionOverUnion.isFinite && centerDistance.isFinite &&
            sizeSimilarity.isFinite && score.isFinite
    }
}

/// Décision de la continuité faciale.
///
/// `.ambiguous` et `.unavailable` ne portent jamais une ancienne boîte : le
/// consommateur doit donc suspendre les landmarks et les métriques faciales
/// jusqu'à une nouvelle cible explicitement sélectionnée.
nonisolated enum FaceTargetDecision: Equatable, Sendable {
    case selected(FaceBoxCandidate, match: FaceTargetMatch?)
    case ambiguous
    case unavailable(FaceTargetUnavailableReason)

    var candidate: FaceBoxCandidate? {
        guard case .selected(let candidate, _) = self else { return nil }
        return candidate
    }

    var isAvailable: Bool { candidate != nil }

    var reason: FaceTargetUnavailableReason? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}

/// Associe des rectangles faciaux par continuité spatiale, sans tenter de
/// reconnaître une personne.
///
/// Le composant ne lance aucune requête Vision. Il est conçu pour séparer la
/// politique déterministe (testable par fixtures) du futur moteur qui fournira
/// les boîtes issues de `VNDetectFaceRectanglesRequest` ou de
/// `VNTrackObjectRequest`.
nonisolated struct FaceTargetContinuity: Equatable, Sendable {
    let configuration: FaceTargetContinuityConfiguration
    private(set) var target: FaceBoxCandidate? = nil
    private(set) var lastTimestamp: TimeInterval? = nil
    private(set) var lastDecision: FaceTargetDecision = .unavailable(.noFace)
    private(set) var requiresExplicitRearm = false

    init(configuration: FaceTargetContinuityConfiguration = .default) {
        self.configuration = configuration
    }

    mutating func reset() {
        target = nil
        lastTimestamp = nil
        lastDecision = .unavailable(.noFace)
        requiresExplicitRearm = false
    }

    /// Autorise explicitement l'acquisition d'une nouvelle personne après une
    /// perte ou une ambiguïté. Aucune reconnaissance biométrique n'est tentée.
    mutating func rearm() {
        target = nil
        lastTimestamp = nil
        lastDecision = .unavailable(.noTarget)
        requiresExplicitRearm = false
    }

    /// Sélectionne une cible à partir d'une détection complète.
    ///
    /// Sans cible précédente, une seule boîte est nécessaire. Plusieurs boîtes
    /// sont toujours ambiguës : la taille seule ne doit jamais choisir un autre
    /// visage par défaut.
    mutating func ingestFullDetection(
        _ candidates: [FaceBoxCandidate],
        at timestamp: TimeInterval
    ) -> FaceTargetDecision {
        guard configuration.isValid else {
            return publish(.unavailable(.invalidConfiguration), timestamp: timestamp)
        }
        guard !requiresExplicitRearm else {
            return publish(.unavailable(.rearmRequired), timestamp: timestamp)
        }
        switch acceptTimestamp(timestamp) {
        case .rejected:
            return lastDecision
        case .accepted:
            break
        case .resetAfterGap:
            return publish(
                .unavailable(.trackingGap),
                timestamp: timestamp,
                clearTarget: true,
                requireRearm: true
            )
        }

        let validCandidates = candidates.filter { FaceBoxCandidate.isValid($0.boundingBox) }
        if target == nil {
            switch validCandidates.count {
            case 0:
                return publish(.unavailable(candidates.isEmpty ? .noFace : .invalidCandidate), timestamp: timestamp)
            case 1:
                return select(validCandidates[0], match: nil, timestamp: timestamp)
            default:
                return publish(
                    .ambiguous,
                    timestamp: timestamp,
                    clearTarget: true,
                    requireRearm: true
                )
            }
        }

        guard let previous = target else {
            return publish(.unavailable(.noTarget), timestamp: timestamp)
        }
        let matches = validCandidates.compactMap { candidate -> (FaceBoxCandidate, FaceTargetMatch)? in
            guard let match = Self.match(from: previous, to: candidate,
                                         configuration: configuration),
                  match.isFinite else { return nil }
            return (candidate, match)
        }.sorted { lhs, rhs in
            if lhs.1.score != rhs.1.score { return lhs.1.score > rhs.1.score }
            return Self.lexicographicKey(lhs.0.boundingBox)
                .lexicographicallyPrecedes(Self.lexicographicKey(rhs.0.boundingBox))
        }

        guard let winner = matches.first else {
            return publish(
                .unavailable(.targetLost),
                timestamp: timestamp,
                clearTarget: true,
                requireRearm: true
            )
        }
        if let runnerUp = matches.dropFirst().first,
           winner.1.score - runnerUp.1.score < configuration.minimumWinnerMargin {
            return publish(
                .ambiguous,
                timestamp: timestamp,
                clearTarget: true,
                requireRearm: true
            )
        }
        return select(winner.0, match: winner.1, timestamp: timestamp)
    }

    /// Accepte la boîte d'un tracker Vision déjà amorcé par la cible courante.
    /// Une boîte qui saute trop loin ne peut pas réinitialiser silencieusement
    /// la cible vers une autre personne.
    mutating func ingestTrackedBox(
        _ candidate: FaceBoxCandidate,
        at timestamp: TimeInterval
    ) -> FaceTargetDecision {
        guard configuration.isValid else {
            return publish(.unavailable(.invalidConfiguration), timestamp: timestamp)
        }
        guard !requiresExplicitRearm else {
            return publish(.unavailable(.rearmRequired), timestamp: timestamp)
        }
        switch acceptTimestamp(timestamp) {
        case .rejected:
            return lastDecision
        case .accepted:
            break
        case .resetAfterGap:
            return publish(
                .unavailable(.trackingGap),
                timestamp: timestamp,
                clearTarget: true,
                requireRearm: true
            )
        }
        guard let previous = target else {
            return publish(.unavailable(.noTarget), timestamp: timestamp)
        }
        guard let match = Self.match(from: previous, to: candidate,
                                     configuration: configuration), match.isFinite else {
            return publish(
                .unavailable(.trackingJump),
                timestamp: timestamp,
                clearTarget: true,
                requireRearm: true
            )
        }
        return select(candidate, match: match, timestamp: timestamp)
    }

    /// Rejette explicitement une frame de tracking absente ou techniquement
    /// invalide. La prochaine détection complète repartira sans ancienne cible.
    mutating func ingestTrackingMiss(at timestamp: TimeInterval) -> FaceTargetDecision {
        guard configuration.isValid else {
            return publish(.unavailable(.invalidConfiguration), timestamp: timestamp)
        }
        guard !requiresExplicitRearm else {
            return publish(.unavailable(.rearmRequired), timestamp: timestamp)
        }
        switch acceptTimestamp(timestamp) {
        case .rejected:
            return lastDecision
        case .accepted:
            break
        case .resetAfterGap:
            return publish(
                .unavailable(.trackingGap),
                timestamp: timestamp,
                clearTarget: true,
                requireRearm: true
            )
        }
        return publish(
            .unavailable(.trackingJump),
            timestamp: timestamp,
            clearTarget: true,
            requireRearm: true
        )
    }

    static func match(
        from previous: FaceBoxCandidate,
        to candidate: FaceBoxCandidate,
        configuration: FaceTargetContinuityConfiguration
    ) -> FaceTargetMatch? {
        guard configuration.isValid,
              FaceBoxCandidate.isValid(previous.boundingBox),
              FaceBoxCandidate.isValid(candidate.boundingBox) else { return nil }

        let iou = intersectionOverUnion(previous.boundingBox, candidate.boundingBox)
        let centerDistance = hypot(
            candidate.center.x - previous.center.x,
            candidate.center.y - previous.center.y
        )
        guard centerDistance.isFinite,
              centerDistance <= configuration.maximumCenterDistance else { return nil }

        let widthRatio = candidate.boundingBox.width / previous.boundingBox.width
        let heightRatio = candidate.boundingBox.height / previous.boundingBox.height
        let minimumScale = 1 - configuration.maximumRelativeSizeChange
        let maximumScale = 1 + configuration.maximumRelativeSizeChange
        guard widthRatio.isFinite, heightRatio.isFinite,
              widthRatio >= minimumScale, widthRatio <= maximumScale,
              heightRatio >= minimumScale, heightRatio <= maximumScale else { return nil }

        let widthSimilarity = 1 - abs(widthRatio - 1) / configuration.maximumRelativeSizeChange
        let heightSimilarity = 1 - abs(heightRatio - 1) / configuration.maximumRelativeSizeChange
        let sizeSimilarity = max(0, (widthSimilarity + heightSimilarity) / 2)
        let centerSimilarity = max(0, 1 - centerDistance / configuration.maximumCenterDistance)
        let score = max(0, min(1, iou * 0.50 + centerSimilarity * 0.30 + sizeSimilarity * 0.20))
        guard iou >= configuration.minimumIntersectionOverUnion ||
            score >= configuration.minimumAssociationScore else { return nil }
        return FaceTargetMatch(
            intersectionOverUnion: iou,
            centerDistance: centerDistance,
            sizeSimilarity: sizeSimilarity,
            score: score
        )
    }

    private enum TimestampAdmission {
        case accepted
        case resetAfterGap
        case rejected
    }

    private mutating func acceptTimestamp(_ timestamp: TimeInterval) -> TimestampAdmission {
        guard timestamp.isFinite else {
            _ = publish(.unavailable(.invalidTimestamp), timestamp: nil)
            return .rejected
        }
        if let previous = lastTimestamp {
            guard timestamp > previous else {
                _ = publish(.unavailable(.outOfOrder), timestamp: nil)
                return .rejected
            }
            if timestamp - previous > configuration.maximumGap {
                // Une frame trop éloignée ne prolonge jamais une cible. La
                // frame actuelle peut néanmoins servir de nouvelle sélection
                // si elle contient exactement un visage détecté.
                target = nil
                lastTimestamp = timestamp
                return .resetAfterGap
            }
        }
        lastTimestamp = timestamp
        return .accepted
    }

    private mutating func select(
        _ candidate: FaceBoxCandidate,
        match: FaceTargetMatch?,
        timestamp: TimeInterval
    ) -> FaceTargetDecision {
        target = candidate
        let decision = FaceTargetDecision.selected(candidate, match: match)
        lastDecision = decision
        lastTimestamp = timestamp
        return decision
    }

    @discardableResult
    private mutating func publish(
        _ decision: FaceTargetDecision,
        timestamp: TimeInterval?,
        clearTarget: Bool = false,
        requireRearm: Bool = false
    ) -> FaceTargetDecision {
        if clearTarget { target = nil }
        if requireRearm { requiresExplicitRearm = true }
        if let timestamp { lastTimestamp = timestamp }
        lastDecision = decision
        return decision
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        let union = rectangleArea(lhs) + rectangleArea(rhs) - rectangleArea(intersection)
        guard union > 0, union.isFinite else { return 0 }
        return max(0, min(1, rectangleArea(intersection) / union))
    }

    private static func rectangleArea(_ rectangle: CGRect) -> CGFloat {
        rectangle.width * rectangle.height
    }

    private static func lexicographicKey(_ rectangle: CGRect) -> [CGFloat] {
        [rectangle.minX, rectangle.minY, rectangle.width, rectangle.height]
    }
}
