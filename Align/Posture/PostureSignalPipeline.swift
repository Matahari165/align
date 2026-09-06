import Foundation

/// Identifiants du rail produit. Ils reflètent les observations réellement
/// raccordées au snapshot canonique, pas les anciens prototypes faciaux.
nonisolated enum PostureIndicatorID: String, CaseIterable, Sendable {
    case apparentProximity
    case torsoInclination
    case raisedShoulders
    case shoulderSlope
    case estimatedBlinks
    case closedShoulders
    case headTilt
    case handOnFace

    var title: String {
        switch self {
        case .apparentProximity: "Proximité apparente"
        case .torsoInclination: "Torse incliné"
        case .raisedShoulders: "Épaules relevées"
        case .shoulderSlope: "Inclinaison des épaules"
        case .estimatedBlinks: "Clignements estimés"
        case .closedShoulders: "Tête–épaules"
        case .headTilt: "Tête penchée"
        case .handOnFace: "Main sur le visage"
        }
    }
}

nonisolated enum PostureIndicatorState: String, Sendable {
    case needsCalibration
    case calibrating
    case normal
    case pending
    case attention
    case unavailable

    var displayName: String {
        switch self {
        case .needsCalibration: "À calibrer"
        case .calibrating: "Calibration…"
        case .normal: "Dans la zone"
        case .pending: "Observation…"
        case .attention: "Attention"
        case .unavailable: "Indisponible"
        }
    }
}

nonisolated struct PostureIndicatorResult: Equatable, Sendable {
    let id: PostureIndicatorID
    let state: PostureIndicatorState
    let count: Int?
    let observedAt: TimeInterval?
    let quality: PostureSignalQuality
    let hasValidBaseline: Bool
    let isExperimental: Bool
    let freshnessTTL: TimeInterval
    var leftShoulderDelta: Double? = nil
    var rightShoulderDelta: Double? = nil
    var shoulderRaiseClassification: PostureShoulderRaiseClassification? = nil
    var numericValue: Double? = nil
    var referenceDelta: Double? = nil
    var reason: String? = nil

    static func unavailable(_ id: PostureIndicatorID) -> Self {
        .init(
            id: id,
            state: .unavailable,
            count: nil,
            observedAt: nil,
            quality: .unavailable,
            hasValidBaseline: false,
            isExperimental: id == .estimatedBlinks || id == .handOnFace,
            freshnessTTL: id == .apparentProximity || id == .estimatedBlinks
                ? PostureObservationEngine.proximityConfiguration.ttl
                : id == .handOnFace
                ? PostureObservationEngine.handFaceConfiguration.ttl
                : PostureObservationEngine.richConfiguration.ttl
        )
    }
}

nonisolated struct PostureIndicatorsSnapshot: Equatable, Sendable {
    static let initial = Self(
        generation: 0,
        producedAt: 0,
        isCalibrating: false,
        indicators: PostureIndicatorID.allCases.map(PostureIndicatorResult.unavailable)
    )

    let generation: UInt64
    let producedAt: TimeInterval
    let isCalibrating: Bool
    let indicators: [PostureIndicatorResult]

    func result(for id: PostureIndicatorID) -> PostureIndicatorResult {
        indicators.first { $0.id == id } ?? .unavailable(id)
    }
}

nonisolated enum PostureIndicatorContract {
    static let calibrationDuration: TimeInterval = 8
}
