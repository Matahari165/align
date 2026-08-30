import Foundation

struct SignalPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

enum SustainedSignalState: Equatable, Sendable {
    case unavailable
    case neutral
    case pending
    case sustained
}

struct FaceMetricSnapshot: Equatable, Sendable {
    let timestamp: TimeInterval
    let generation: UInt64
    let interocularDistance: Double
    let faceLength: Double
    let yawProxy: Double
    let facePointCount: Int
}

struct HeadProximityCalibration: Equatable, Sendable {
    let generation: UInt64
    let medianInterocularDistance: Double
    let medianFaceLength: Double

    static func make(from snapshots: [FaceMetricSnapshot], minimumSamples: Int = 5,
                     configuration: HeadProximityConfiguration = .init()) -> Self? {
        guard minimumSamples > 0, configuration.isValid,
              coherentFaceSequence(snapshots, maximumGap: configuration.maximumSampleGap),
              let generation = snapshots.first?.generation else {
            return nil
        }
        let accepted = snapshots.filter {
            $0.facePointCount >= configuration.minimumFacePointCount &&
                abs($0.yawProxy) <= configuration.maximumAbsoluteYawProxy &&
                $0.interocularDistance.isFinite && $0.interocularDistance > 0 &&
                $0.faceLength.isFinite && $0.faceLength > 0
        }
        guard accepted.count >= minimumSamples,
              let interocular = median(accepted.map(\.interocularDistance)),
              let faceLength = median(accepted.map(\.faceLength)),
              interocular.isFinite, faceLength.isFinite,
              interocular > 0, faceLength > 0 else { return nil }
        return Self(generation: generation, medianInterocularDistance: interocular,
                    medianFaceLength: faceLength)
    }
}

struct HeadProximityConfiguration: Equatable, Sendable {
    var minimumFacePointCount = 40
    var maximumAbsoluteYawProxy = 0.35
    var maximumScaleDisagreement = 0.18
    var enterRatio = 1.20
    var exitRatio = 1.12
    var requiredDuration: TimeInterval = 1.5
    var maximumSampleGap: TimeInterval = 0.45

    var isValid: Bool {
        minimumFacePointCount > 0 && maximumAbsoluteYawProxy.isFinite &&
            maximumAbsoluteYawProxy >= 0 && maximumScaleDisagreement.isFinite &&
            maximumScaleDisagreement >= 0 && enterRatio.isFinite && exitRatio.isFinite &&
            enterRatio > exitRatio && exitRatio > 0 && requiredDuration.isFinite &&
            requiredDuration >= 0 && maximumSampleGap.isFinite && maximumSampleGap > 0
    }
}

struct HeadProximityEvaluation: Equatable, Sendable {
    let state: SustainedSignalState
    let ratio: Double?
}

struct HeadProximityEvaluator: Sendable {
    let configuration: HeadProximityConfiguration
    private(set) var generation: UInt64?
    private(set) var lastTimestamp: TimeInterval?
    private(set) var pendingSince: TimeInterval?
    private(set) var isSustained = false

    init(configuration: HeadProximityConfiguration = .init()) {
        self.configuration = configuration
    }

    mutating func reset() {
        generation = nil
        lastTimestamp = nil
        pendingSince = nil
        isSustained = false
    }

    mutating func consume(
        _ snapshot: FaceMetricSnapshot?,
        calibration: HeadProximityCalibration?
    ) -> HeadProximityEvaluation {
        guard let snapshot else {
            resetTransientState()
            return .init(state: .unavailable, ratio: nil)
        }
        guard acceptGenerationAndTimestamp(snapshot) else {
            return .init(state: .unavailable, ratio: nil)
        }
        guard configuration.isValid, let calibration,
              calibration.generation == snapshot.generation,
              calibration.medianInterocularDistance.isFinite,
              calibration.medianInterocularDistance > 0,
              calibration.medianFaceLength.isFinite,
              calibration.medianFaceLength > 0 else {
            resetTransientState(keepingIdentity: true)
            return .init(state: .unavailable, ratio: nil)
        }
        guard snapshot.facePointCount >= configuration.minimumFacePointCount,
              snapshot.yawProxy.isFinite,
              abs(snapshot.yawProxy) <= configuration.maximumAbsoluteYawProxy,
              snapshot.interocularDistance.isFinite, snapshot.interocularDistance > 0,
              snapshot.faceLength.isFinite, snapshot.faceLength > 0 else {
            resetTransientState(keepingIdentity: true)
            return .init(state: .unavailable, ratio: nil)
        }

        let interocularRatio = snapshot.interocularDistance / calibration.medianInterocularDistance
        let faceLengthRatio = snapshot.faceLength / calibration.medianFaceLength
        guard interocularRatio.isFinite, faceLengthRatio.isFinite,
              abs(interocularRatio - faceLengthRatio) <= configuration.maximumScaleDisagreement else {
            resetTransientState(keepingIdentity: true)
            return .init(state: .unavailable, ratio: nil)
        }
        let ratio = sqrt(interocularRatio) * sqrt(faceLengthRatio)
        guard ratio.isFinite else {
            resetTransientState(keepingIdentity: true)
            return .init(state: .unavailable, ratio: nil)
        }
        if isSustained {
            if ratio <= configuration.exitRatio {
                pendingSince = nil
                isSustained = false
                return .init(state: .neutral, ratio: ratio)
            }
            return .init(state: .sustained, ratio: ratio)
        }
        guard ratio >= configuration.enterRatio else {
            pendingSince = nil
            return .init(state: .neutral, ratio: ratio)
        }
        if pendingSince == nil { pendingSince = snapshot.timestamp }
        guard snapshot.timestamp - (pendingSince ?? snapshot.timestamp) >= configuration.requiredDuration else {
            return .init(state: .pending, ratio: ratio)
        }
        isSustained = true
        return .init(state: .sustained, ratio: ratio)
    }

    private mutating func acceptGenerationAndTimestamp(_ snapshot: FaceMetricSnapshot) -> Bool {
        // Un timestamp invalide ne permet pas d'ordonner la génération : le
        // snapshot entier est donc inerte.
        guard snapshot.timestamp.isFinite else { return false }
        if let generation, snapshot.generation < generation { return false }
        if generation != snapshot.generation {
            if let lastTimestamp, snapshot.timestamp <= lastTimestamp { return false }
            reset()
            generation = snapshot.generation
        }
        if let lastTimestamp {
            guard snapshot.timestamp > lastTimestamp else {
                resetTransientState(keepingIdentity: true)
                return false
            }
            guard snapshot.timestamp - lastTimestamp <= configuration.maximumSampleGap else {
                resetTransientState(keepingIdentity: true)
                self.lastTimestamp = snapshot.timestamp
                return true
            }
        }
        lastTimestamp = snapshot.timestamp
        return true
    }

    private mutating func resetTransientState(keepingIdentity: Bool = false) {
        pendingSince = nil
        isSustained = false
        if !keepingIdentity {
            generation = nil
            lastTimestamp = nil
        }
    }
}

struct ShoulderMetricSnapshot: Equatable, Sendable {
    let timestamp: TimeInterval
    let generation: UInt64
    let leftShoulder: SignalPoint
    let rightShoulder: SignalPoint
    let faceReference: SignalPoint
    let faceScale: Double
    let faceRollRadians: Double
    let yawProxy: Double
    let bodySampleID: UInt64
    let faceGeneration: UInt64
    let faceTimestamp: TimeInterval
    let faceSampleID: UInt64

    func hasVerifiedIdentity(maximumTimestampSkew: TimeInterval) -> Bool {
        timestamp.isFinite && faceTimestamp.isFinite && maximumTimestampSkew.isFinite &&
            maximumTimestampSkew >= 0 && generation == faceGeneration &&
            bodySampleID == faceSampleID &&
            abs(timestamp - faceTimestamp) <= maximumTimestampSkew
    }
}

struct ShoulderHeightCalibration: Equatable, Sendable {
    let generation: UInt64
    let medianLeftHeight: Double
    let medianRightHeight: Double

    static func make(from snapshots: [ShoulderMetricSnapshot], minimumSamples: Int = 5,
                     configuration: ShoulderHeightConfiguration = .init()) -> Self? {
        guard minimumSamples > 0, configuration.isValid,
              coherentShoulderSequence(snapshots, maximumGap: configuration.maximumSampleGap),
              let generation = snapshots.first?.generation else {
            return nil
        }
        let metrics = snapshots.filter {
            $0.hasVerifiedIdentity(maximumTimestampSkew: configuration.maximumIdentityTimestampSkew) &&
                $0.yawProxy.isFinite &&
                abs($0.yawProxy) <= configuration.maximumAbsoluteYawProxy
        }.compactMap(ShoulderHeightEvaluator.relativeHeights)
        guard metrics.count >= minimumSamples,
              let left = median(metrics.map(\.left)),
              let right = median(metrics.map(\.right)),
              left.isFinite, right.isFinite else { return nil }
        return Self(generation: generation, medianLeftHeight: left,
                    medianRightHeight: right)
    }
}

struct ShoulderHeightConfiguration: Equatable, Sendable {
    /// Seuil expérimental normalisé par la taille du visage, jamais anatomique.
    var enterElevation = 0.10
    var exitElevation = 0.06
    var requiredDuration: TimeInterval = 2.0
    var maximumSampleGap: TimeInterval = 0.65
    var maximumAbsoluteYawProxy = 0.35
    var maximumInterframeMovement = 0.08
    var maximumIdentityTimestampSkew: TimeInterval = 0.001

    var isValid: Bool {
        enterElevation.isFinite && exitElevation.isFinite &&
            enterElevation > exitElevation && exitElevation >= 0 &&
            requiredDuration.isFinite && requiredDuration >= 0 &&
            maximumSampleGap.isFinite && maximumSampleGap > 0 &&
            maximumAbsoluteYawProxy.isFinite && maximumAbsoluteYawProxy >= 0 &&
            maximumInterframeMovement.isFinite && maximumInterframeMovement >= 0 &&
            maximumIdentityTimestampSkew.isFinite && maximumIdentityTimestampSkew >= 0
    }
}

struct ShoulderHeightEvaluation: Equatable, Sendable {
    let state: SustainedSignalState
    let minimumBilateralElevation: Double?
}

struct ShoulderHeightEvaluator: Sendable {
    let configuration: ShoulderHeightConfiguration
    private(set) var generation: UInt64?
    private(set) var lastTimestamp: TimeInterval?
    private(set) var previousHeights: (left: Double, right: Double)?
    private(set) var pendingSince: TimeInterval?
    private(set) var isSustained = false

    init(configuration: ShoulderHeightConfiguration = .init()) {
        self.configuration = configuration
    }

    mutating func reset() {
        generation = nil
        lastTimestamp = nil
        previousHeights = nil
        pendingSince = nil
        isSustained = false
    }

    mutating func consume(
        _ snapshot: ShoulderMetricSnapshot?,
        calibration: ShoulderHeightCalibration?
    ) -> ShoulderHeightEvaluation {
        guard let snapshot else {
            resetTransientState()
            return .init(state: .unavailable, minimumBilateralElevation: nil)
        }
        guard acceptGenerationAndTimestamp(snapshot) else {
            return .init(state: .unavailable, minimumBilateralElevation: nil)
        }
        guard configuration.isValid, let calibration,
              calibration.generation == snapshot.generation,
              calibration.medianLeftHeight.isFinite,
              calibration.medianRightHeight.isFinite,
              snapshot.hasVerifiedIdentity(
                maximumTimestampSkew: configuration.maximumIdentityTimestampSkew),
              snapshot.yawProxy.isFinite,
              abs(snapshot.yawProxy) <= configuration.maximumAbsoluteYawProxy,
              let heights = Self.relativeHeights(snapshot) else {
            resetTransientState(keepingIdentity: true)
            return .init(state: .unavailable, minimumBilateralElevation: nil)
        }
        if let previousHeights {
            let movement = max(abs(heights.left - previousHeights.left),
                               abs(heights.right - previousHeights.right))
            guard movement <= configuration.maximumInterframeMovement else {
                self.previousHeights = heights
                pendingSince = nil
                isSustained = false
                return .init(state: .unavailable, minimumBilateralElevation: nil)
            }
        }
        previousHeights = heights
        let leftElevation = calibration.medianLeftHeight - heights.left
        let rightElevation = calibration.medianRightHeight - heights.right
        let bilateralElevation = min(leftElevation, rightElevation)
        guard leftElevation.isFinite, rightElevation.isFinite,
              bilateralElevation.isFinite else {
            resetTransientState(keepingIdentity: true)
            return .init(state: .unavailable, minimumBilateralElevation: nil)
        }

        if isSustained {
            if bilateralElevation <= configuration.exitElevation {
                pendingSince = nil
                isSustained = false
                return .init(state: .neutral, minimumBilateralElevation: bilateralElevation)
            }
            return .init(state: .sustained, minimumBilateralElevation: bilateralElevation)
        }
        guard bilateralElevation >= configuration.enterElevation else {
            pendingSince = nil
            return .init(state: .neutral, minimumBilateralElevation: bilateralElevation)
        }
        if pendingSince == nil { pendingSince = snapshot.timestamp }
        guard snapshot.timestamp - (pendingSince ?? snapshot.timestamp) >= configuration.requiredDuration else {
            return .init(state: .pending, minimumBilateralElevation: bilateralElevation)
        }
        isSustained = true
        return .init(state: .sustained, minimumBilateralElevation: bilateralElevation)
    }

    static func relativeHeights(_ snapshot: ShoulderMetricSnapshot) -> (left: Double, right: Double)? {
        guard snapshot.faceScale.isFinite, snapshot.faceScale > 0,
              snapshot.faceRollRadians.isFinite,
              snapshot.leftShoulder.x.isFinite, snapshot.leftShoulder.y.isFinite,
              snapshot.rightShoulder.x.isFinite, snapshot.rightShoulder.y.isFinite,
              snapshot.faceReference.x.isFinite, snapshot.faceReference.y.isFinite else { return nil }
        let sine = sin(-snapshot.faceRollRadians)
        let cosine = cos(-snapshot.faceRollRadians)
        func height(_ point: SignalPoint) -> Double {
            let dx = point.x - snapshot.faceReference.x
            let dy = point.y - snapshot.faceReference.y
            return (sine * dx + cosine * dy) / snapshot.faceScale
        }
        let left = height(snapshot.leftShoulder)
        let right = height(snapshot.rightShoulder)
        guard left.isFinite, right.isFinite else { return nil }
        return (left, right)
    }

    private mutating func acceptGenerationAndTimestamp(_ snapshot: ShoulderMetricSnapshot) -> Bool {
        guard snapshot.timestamp.isFinite else { return false }
        if let generation, snapshot.generation < generation { return false }
        if generation != snapshot.generation {
            if let lastTimestamp, snapshot.timestamp <= lastTimestamp { return false }
            reset()
            generation = snapshot.generation
        }
        if let lastTimestamp {
            guard snapshot.timestamp > lastTimestamp else {
                resetTransientState(keepingIdentity: true)
                return false
            }
            guard snapshot.timestamp - lastTimestamp <= configuration.maximumSampleGap else {
                resetTransientState(keepingIdentity: true)
                self.lastTimestamp = snapshot.timestamp
                return true
            }
        }
        lastTimestamp = snapshot.timestamp
        return true
    }

    private mutating func resetTransientState(keepingIdentity: Bool = false) {
        previousHeights = nil
        pendingSince = nil
        isSustained = false
        if !keepingIdentity {
            generation = nil
            lastTimestamp = nil
        }
    }
}

private func median(_ values: [Double]) -> Double? {
    let sorted = values.filter(\.isFinite).sorted()
    guard !sorted.isEmpty else { return nil }
    let middle = sorted.count / 2
    let result = sorted.count.isMultiple(of: 2)
        ? sorted[middle - 1] / 2 + sorted[middle] / 2
        : sorted[middle]
    return result.isFinite ? result : nil
}

private func coherentFaceSequence(
    _ snapshots: [FaceMetricSnapshot], maximumGap: TimeInterval
) -> Bool {
    guard let first = snapshots.first, first.timestamp.isFinite else { return false }
    var previous = first.timestamp
    for snapshot in snapshots.dropFirst() {
        guard snapshot.generation == first.generation, snapshot.timestamp.isFinite,
              snapshot.timestamp > previous,
              snapshot.timestamp - previous <= maximumGap else { return false }
        previous = snapshot.timestamp
    }
    return true
}

private func coherentShoulderSequence(
    _ snapshots: [ShoulderMetricSnapshot], maximumGap: TimeInterval
) -> Bool {
    guard let first = snapshots.first, first.timestamp.isFinite else { return false }
    var previous = first.timestamp
    for snapshot in snapshots.dropFirst() {
        guard snapshot.generation == first.generation, snapshot.timestamp.isFinite,
              snapshot.timestamp > previous,
              snapshot.timestamp - previous <= maximumGap else { return false }
        previous = snapshot.timestamp
    }
    return true
}
