import Foundation

nonisolated enum PostureObservationSignalID: String, CaseIterable, Codable, Hashable, Sendable {
    case proximity
    case torsoInclination
    case raisedShoulders
    case shoulderSlope
    case estimatedBlinks
    case closedShoulders
    case headTilt
    case handOnFace

    /// Les rappels utilisent exclusivement des observations fiables. Les
    /// signaux dont aucun seuil universel défendable n'existe restent
    /// disponibles pour le diagnostic, mais ne peuvent pas notifier.
    static let alertableCases: [Self] = [
        .proximity, .torsoInclination, .estimatedBlinks,
        .shoulderSlope, .headTilt, .handOnFace
    ]
}

nonisolated enum PostureObservationQuality: String, Codable, Sendable {
    case unavailable
    case limited
    case good
}

nonisolated enum PostureCalibrationState: String, Codable, Sendable {
    case missing
    case calibrating
    case valid
    case invalidContext
}

nonisolated enum PostureObservationAvailability: String, Codable, Sendable {
    case needsCalibration
    case calibrating
    case insufficient
    case observing
    case available
}

nonisolated enum PostureObservationAssessment: String, Codable, Sendable {
    case withinReference
    case attention
}

nonisolated enum PostureRecommendationSensitivity: String, CaseIterable, Codable, Sendable {
    case discreet
    case balanced
    case sensitive

    static let defaultValue: Self = .sensitive
}

/// Scalar-only evidence crossing from CV into the posture domain. `normalizedValue`
/// is defined by each signal contract; no image, landmark or coordinate crosses here.
nonisolated struct PostureMetricEvidence: Equatable, Codable, Sendable {
    let signalID: PostureObservationSignalID
    let generation: UInt64
    let sampleID: UInt64
    let capturedAt: TimeInterval
    let producedAt: TimeInterval
    let normalizedValue: Double?
    let quality: PostureObservationQuality
    let calibration: PostureCalibrationState
    let cameraContextID: String
    let framingSignature: String
    var assessmentHint: PostureObservationAssessment? = nil
    var leftShoulderDelta: Double? = nil
    var rightShoulderDelta: Double? = nil
    var shoulderRaiseClassification: PostureShoulderRaiseClassification? = nil
    var numericValue: Double? = nil
    var referenceDelta: Double? = nil
    var observationReason: String? = nil

    var hasValidIdentity: Bool {
        generation > 0 && sampleID > 0 && capturedAt.isFinite && producedAt.isFinite &&
            producedAt >= capturedAt && !cameraContextID.isEmpty && !framingSignature.isEmpty
    }
}

nonisolated struct PostureSignalSnapshot: Equatable, Codable, Sendable {
    let signalID: PostureObservationSignalID
    let generation: UInt64
    let availability: PostureObservationAvailability
    let assessment: PostureObservationAssessment?
    let quality: PostureObservationQuality
    let observedAt: TimeInterval?
    let producedAt: TimeInterval
    let episodeID: UInt64?
    let reason: String?
    var leftShoulderDelta: Double? = nil
    var rightShoulderDelta: Double? = nil
    var shoulderRaiseClassification: PostureShoulderRaiseClassification? = nil
    var numericValue: Double? = nil
    var referenceDelta: Double? = nil

    static func unavailable(
        _ id: PostureObservationSignalID,
        generation: UInt64,
        at now: TimeInterval,
        availability: PostureObservationAvailability = .insufficient,
        reason: String
    ) -> Self {
        .init(signalID: id, generation: generation, availability: availability,
              assessment: nil, quality: .unavailable, observedAt: nil,
              producedAt: now, episodeID: nil, reason: reason)
    }
}

nonisolated struct PostureObservationsSnapshot: Equatable, Codable, Sendable {
    let generation: UInt64
    /// Identité stable caméra/format/règle. Elle reste locale et n'est jamais
    /// destinée à une copie UI ou à une notification.
    let contextKey: String
    let producedAt: TimeInterval
    let signals: [PostureSignalSnapshot]
    /// Per-publication metadata, never cumulative: the writer can count a
    /// blink event exactly once without confusing it with alert deliveries.
    let blinkEventCount: Int
    /// Face + both eyes were reliable for this sample, independently of
    /// whether the blink-rate baseline is mature enough to publish.
    let faceAndEyesReliable: Bool
    /// Timestamp de la vraie preuve visage associée à cette publication.
    /// `nil` signifie que la publication vient d'une autre source et ne doit
    /// ni ouvrir ni fermer la couverture visage dans l'historique.
    let faceAndEyesObservedAt: TimeInterval?

    init(
        generation: UInt64,
        contextKey: String = "",
        producedAt: TimeInterval,
        signals: [PostureSignalSnapshot],
        blinkEventCount: Int = 0,
        faceAndEyesReliable: Bool = false,
        faceAndEyesObservedAt: TimeInterval? = nil
    ) {
        self.generation = generation
        self.contextKey = contextKey
        self.producedAt = producedAt
        self.signals = signals
        self.blinkEventCount = blinkEventCount
        self.faceAndEyesReliable = faceAndEyesReliable
        self.faceAndEyesObservedAt = faceAndEyesObservedAt
    }

    func signal(_ id: PostureObservationSignalID) -> PostureSignalSnapshot {
        signals.first { $0.signalID == id } ?? .unavailable(
            id, generation: generation, at: producedAt, reason: "Observation absente"
        )
    }
}
