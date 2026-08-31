import Foundation

nonisolated enum PostureIndicatorTone: Equatable, Sendable {
    case neutral
    case positive
    case negative
}

nonisolated struct PostureIndicatorPresentation: Equatable, Sendable {
    static let orderedIDs: [PostureIndicatorID] = [
        .apparentProximity,
        .torsoInclination,
        .raisedShoulders,
        .shoulderSlope,
        .estimatedBlinks,
        .closedShoulders
    ]

    let title: String
    let value: String
    let accessibilityValue: String
    let symbolName: String
    let tone: PostureIndicatorTone
    let isExperimental: Bool

    static func make(
        for result: PostureIndicatorResult,
        producedAt: TimeInterval,
        freshnessTTL: TimeInterval? = nil
    ) -> Self {
        let experimental = result.isExperimental
        let title = result.id.title

        switch result.state {
        case .needsCalibration:
            return presentation(title: title, value: "À calibrer", symbol: "scope",
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
            return Self(title: title, value: "Sous ton repère",
                        accessibilityValue: "Estimation expérimentale fiable, sous ton repère personnel",
                        symbolName: "exclamationmark.circle.fill", tone: .negative,
                        isExperimental: true)
        case .attention where result.id == .closedShoulders:
            return presentation(title: title, value: "Plus refermées",
                                symbol: "arrow.left.and.right", experimental: true,
                                reliableObservation: true)
        case .attention where result.id == .shoulderSlope:
            return presentation(title: title, value: "Plus inclinées",
                                symbol: "line.diagonal", experimental: true,
                                reliableObservation: true)
        case .normal:
            return Self(title: title, value: "Dans ton repère",
                        accessibilityValue: "Mesure fiable, dans ton repère",
                        symbolName: "checkmark.circle.fill", tone: .positive,
                        isExperimental: false)
        case .attention:
            let value: String = switch result.id {
            case .apparentProximity: "Un peu près"
            case .torsoInclination: "Torse incliné"
            case .raisedShoulders: "Épaules relevées"
            case .shoulderSlope: "Épaules inclinées"
            case .estimatedBlinks: "Sous ton repère"
            case .closedShoulders: "Plus refermées"
            }
            let evidence = result.id == .apparentProximity
                ? "Proxy fiable relatif à ton repère, " : "Mesure fiable, "
            return Self(title: title, value: value,
                        accessibilityValue: "\(evidence)correction suggérée : \(value)",
                        symbolName: "exclamationmark.circle.fill", tone: .negative,
                        isExperimental: false)
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
        let accessibility = experimental
            ? "Expérimental, Aucune information fiable"
            : "Aucune information fiable"
        return Self(title: title, value: "—", accessibilityValue: accessibility,
             symbolName: "minus.circle", tone: .neutral, isExperimental: experimental)
    }

    private static func presentation(
        title: String,
        value: String,
        symbol: String,
        experimental: Bool,
        reliableObservation: Bool = false
    ) -> Self {
        let maturity = experimental ? "Expérimental, " : ""
        let quality = reliableObservation ? "Observation fiable, " : ""
        let accessibility = maturity + quality + value
        return Self(title: title, value: value, accessibilityValue: accessibility,
                    symbolName: symbol, tone: .neutral, isExperimental: experimental)
    }

}
