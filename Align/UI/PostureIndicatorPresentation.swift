import Foundation

nonisolated enum PostureIndicatorTone: Equatable, Sendable {
    case neutral
    case positive
    case negative
}

nonisolated struct PostureIndicatorPresentation: Equatable, Sendable {
    static let orderedIDs: [PostureIndicatorID] = [
        .shoulderSlope,
        .raisedShoulders,
        .headTilt,
        .closedShoulders,
        .apparentProximity,
        .torsoInclination,
        .estimatedBlinks,
        .handOnFace
    ]

    let title: String
    let value: String
    let accessibilityValue: String
    let symbolName: String
    let tone: PostureIndicatorTone
    let isExperimental: Bool

    /// The rail uses the same semantic value for VoiceOver and for compact
    /// layouts, but gives the primary state and its optional measurement
    /// different visual weight.
    var primaryValue: String {
        guard let separator = value.range(of: " · ") else { return value }
        return String(value[..<separator.lowerBound])
    }

    var secondaryValue: String? {
        guard let separator = value.range(of: " · ") else { return nil }
        let suffix = String(value[separator.upperBound...])
        return suffix.isEmpty ? nil : suffix
    }

    static func make(
        for result: PostureIndicatorResult,
        producedAt: TimeInterval,
        freshnessTTL: TimeInterval? = nil
    ) -> Self {
        let ttl = freshnessTTL ?? result.freshnessTTL
        let fresh = ttl.isFinite && ttl > 0 && result.quality == .good && producedAt.isFinite &&
            (result.observedAt.map { $0.isFinite && producedAt >= $0 && producedAt - $0 <= ttl } ?? false)
        if result.id == .estimatedBlinks, result.state == .needsCalibration,
           fresh, let rate = result.numericValue, rate.isFinite, rate >= 0 {
            return presentation(title: result.id.title,
                                value: String(format: "%.1f/min · repère en cours", rate),
                                symbol: "eye", experimental: true)
        }
        if result.id == .estimatedBlinks,
           result.state == .needsCalibration || result.state == .unavailable {
            let recent = ttl.isFinite && ttl > 0 && producedAt.isFinite &&
                (result.observedAt.map { $0.isFinite && producedAt >= $0 && producedAt - $0 <= ttl } ?? false)
            let reason = result.reason ?? ""
            let readableReason = reason.hasPrefix("Yeux observés :") ||
                reason.hasPrefix("Suivi des yeux trop intermittent") ||
                reason.hasPrefix("Suivi des yeux intermittent")
            return presentation(title: result.id.title,
                                value: recent && readableReason ? reason : "Yeux non mesurables",
                                symbol: "eye", experimental: true)
        }
        let base = basePresentation(for: result, producedAt: producedAt, freshnessTTL: ttl)
        guard fresh, result.hasValidBaseline,
              result.state == .normal || result.state == .attention || result.state == .pending,
              let numeric = numericText(for: result) else { return base }
        return Self(title: base.title, value: "\(base.value) · \(numeric)",
                    accessibilityValue: "\(base.accessibilityValue), \(numeric)",
                    symbolName: base.symbolName, tone: base.tone,
                    isExperimental: base.isExperimental)
    }

    private static func numericText(for result: PostureIndicatorResult) -> String? {
        switch result.id {
        case .headTilt, .shoulderSlope, .torsoInclination:
            guard let delta = result.referenceDelta, delta.isFinite else { return nil }
            return String(format: "%+.1f°", delta)
        case .apparentProximity:
            guard let value = result.numericValue, value.isFinite else { return nil }
            return String(format: "×%.2f", value)
        case .estimatedBlinks:
            guard let value = result.numericValue, value.isFinite, value >= 0 else { return nil }
            return String(format: "%.1f/min", value)
        case .raisedShoulders, .closedShoulders:
            return nil
        case .handOnFace:
            return nil
        }
    }

    private static func basePresentation(
        for result: PostureIndicatorResult,
        producedAt: TimeInterval,
        freshnessTTL: TimeInterval?
    ) -> Self {
        let experimental = result.isExperimental
        let title = result.id.title

        switch result.state {
        case .needsCalibration:
            return presentation(title: title,
                                value: "À calibrer",
                                symbol: "scope",
                                experimental: experimental)
        case .calibrating:
            return presentation(title: title, value: "Calibration…", symbol: "hourglass",
                                experimental: experimental)
        case .unavailable:
            return unavailable(title: title, experimental: experimental)
        case .pending, .normal, .attention:
            guard hasReliableEvidence(
                result,
                producedAt: producedAt,
                ttl: freshnessTTL ?? result.freshnessTTL
            ) else {
                return unavailable(title: title, experimental: experimental)
            }
        }

        switch result.state {
        case .pending:
            return presentation(title: title, value: "Observation…", symbol: "ellipsis.circle",
                                experimental: experimental, reliableObservation: true)
        case .normal where experimental:
            return presentation(title: title, value: "Dans ton repère",
                                symbol: "circle.dotted", experimental: true,
                                reliableObservation: true)
        case .attention where result.id == .estimatedBlinks:
            return Self(title: title, value: "Pense à cligner",
                        accessibilityValue: "Clignements observés : rappel de cligner naturellement",
                        symbolName: "exclamationmark.circle.fill", tone: .negative,
                        isExperimental: true)
        case .normal:
            return Self(title: title, value: "Dans ton repère",
                        accessibilityValue: "Mesure fiable, dans ton repère",
                        symbolName: "checkmark.circle.fill", tone: .positive,
                        isExperimental: false)
        case .attention:
            let value: String = switch result.id {
            case .apparentProximity: "Un peu près"
            case .torsoInclination: "Buste penché sur le côté"
            case .raisedShoulders:
                switch result.shoulderRaiseClassification {
                case .some(.unilateralLeft): "Épaule gauche relevée"
                case .some(.unilateralRight): "Épaule droite relevée"
                case .some(.bilateral): "Deux épaules relevées"
                case .some(.none), .some(.unavailable), nil: "Épaules relevées"
                }
            case .shoulderSlope: "Une épaule plus haute"
            case .headTilt: "Tête penchée sur le côté"
            case .estimatedBlinks: "Sous ton repère"
            case .closedShoulders: "À réajuster"
            case .handOnFace: "Éloigne ta main"
            }
            let evidence: String = switch result.id {
            case .apparentProximity: "Proxy fiable relatif à ton repère, "
            case .handOnFace: "Proximité 2D fiable, "
            default: "Mesure fiable, "
            }
            return Self(title: title, value: value,
                        accessibilityValue: "\(evidence)correction suggérée : \(value)",
                        symbolName: "exclamationmark.circle.fill", tone: .negative,
                        isExperimental: experimental)
        case .needsCalibration, .calibrating, .unavailable:
            preconditionFailure("Ces états sont traités avant la preuve.")
        }
    }

    private static func hasReliableEvidence(
        _ result: PostureIndicatorResult,
        producedAt: TimeInterval,
        ttl: TimeInterval
    ) -> Bool {
        guard result.quality == .good, result.hasValidBaseline,
              producedAt.isFinite, ttl.isFinite, ttl > 0,
              let observedAt = result.observedAt, observedAt.isFinite,
              observedAt <= producedAt else { return false }
        return producedAt - observedAt <= ttl
    }

    private static func unavailable(title: String, experimental: Bool) -> Self {
        return Self(title: title, value: "—", accessibilityValue: "Aucune information fiable",
             symbolName: "minus.circle", tone: .neutral, isExperimental: experimental)
    }

    private static func presentation(
        title: String,
        value: String,
        symbol: String,
        experimental: Bool,
        reliableObservation: Bool = false
    ) -> Self {
        let quality = reliableObservation ? "Observation fiable, " : ""
        let accessibility = quality + value
        return Self(title: title, value: value, accessibilityValue: accessibility,
                    symbolName: symbol, tone: .neutral, isExperimental: experimental)
    }

}
