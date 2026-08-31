import Foundation

/// Modes de protocole local. Les durées décrivent le protocole, pas une promesse de précision.
public enum PostureValidationMode: String, Codable, Sendable {
    case measurement20s
    case notification60s
}

public enum PostureValidationDirection: String, Codable, Sendable {
    case left
    case right
}

public enum PostureValidationAttention: String, Codable, Sendable {
    case leftShoulderRaised
    case rightShoulderRaised
    case bothShouldersRaised
    case shouldersClosed
    case torsoLeanLeft
    case torsoLeanRight
}

/// Phase exacte du protocole. Une phase peut ne demander aucune attention.
public enum PostureValidationExpectation: String, Codable, Sendable {
    case neutral
    case leftShoulderRaised
    case rightShoulderRaised
    case bothShouldersRaised
    case shouldersClosed
    case shouldersOpen
    case torsoLeanLeft
    case torsoLeanRight
    case recovery

    public var expectedAttention: PostureValidationAttention? {
        switch self {
        case .leftShoulderRaised: return .leftShoulderRaised
        case .rightShoulderRaised: return .rightShoulderRaised
        case .bothShouldersRaised: return .bothShouldersRaised
        case .shouldersClosed: return .shouldersClosed
        case .torsoLeanLeft: return .torsoLeanLeft
        case .torsoLeanRight: return .torsoLeanRight
        case .neutral, .shouldersOpen, .recovery:
            return nil
        }
    }

    public var expectedDirection: PostureValidationDirection? {
        switch self {
        case .torsoLeanLeft: return .left
        case .torsoLeanRight: return .right
        default: return nil
        }
    }
}

public enum PostureValidationAvailability: String, Codable, Sendable {
    case unavailable
    case limited
    case reliable

    public var isReliable: Bool {
        self == .reliable
    }
}

public struct PostureValidationPhaseDefinition: Codable, Equatable, Sendable {
    public let id: String
    public let expectation: PostureValidationExpectation
    public let duration: TimeInterval
    public let instruction: String

    public init(
        id: String,
        expectation: PostureValidationExpectation,
        duration: TimeInterval,
        instruction: String
    ) {
        self.id = id
        self.expectation = expectation
        self.duration = duration
        self.instruction = instruction
    }
}

public struct PostureValidationPhase: Codable, Equatable, Sendable {
    public let id: String
    public let expectation: PostureValidationExpectation
    public let instruction: String
    public let startTime: TimeInterval
    public let duration: TimeInterval

    public var endTime: TimeInterval {
        startTime + duration
    }

    public var expectedAttention: PostureValidationAttention? {
        expectation.expectedAttention
    }

    public var expectedDirection: PostureValidationDirection? {
        expectation.expectedDirection
    }

    fileprivate init(definition: PostureValidationPhaseDefinition, startTime: TimeInterval) {
        self.id = definition.id
        self.expectation = definition.expectation
        self.instruction = definition.instruction
        self.startTime = startTime
        self.duration = definition.duration
    }
}

public struct PostureValidationPlan: Codable, Equatable, Sendable {
    public let mode: PostureValidationMode
    public let phases: [PostureValidationPhase]
    public let expectedSampleInterval: TimeInterval

    public var totalDuration: TimeInterval {
        phases.last?.endTime ?? 0
    }

    public init?(
        mode: PostureValidationMode,
        definitions: [PostureValidationPhaseDefinition],
        expectedSampleInterval: TimeInterval = 0.1
    ) {
        guard !definitions.isEmpty,
              expectedSampleInterval.isFinite,
              expectedSampleInterval > 0 else {
            return nil
        }

        var startTime: TimeInterval = 0
        var phases: [PostureValidationPhase] = []
        for definition in definitions {
            guard !definition.id.isEmpty,
                  definition.duration.isFinite,
                  definition.duration > 0 else {
                return nil
            }
            phases.append(PostureValidationPhase(definition: definition, startTime: startTime))
            startTime += definition.duration
        }

        self.mode = mode
        self.phases = phases
        self.expectedSampleInterval = expectedSampleInterval
    }

    /// Phase contenant un temps écoulé relatif au début de la session.
    /// La borne finale est volontairement exclue afin d'éviter un double comptage.
    public func phase(at elapsed: TimeInterval) -> PostureValidationPhase? {
        guard elapsed.isFinite, elapsed >= 0, elapsed < totalDuration else {
            return nil
        }
        return phases.first { elapsed >= $0.startTime && elapsed < $0.endTime }
    }

    private static func definitions(duration: TimeInterval) -> [PostureValidationPhaseDefinition] {
        [
            .init(id: "neutral-1", expectation: .neutral, duration: duration,
                  instruction: "Reste en posture naturelle."),
            .init(id: "left-shoulder-raised", expectation: .leftShoulderRaised,
                  duration: duration, instruction: "Lève l'épaule gauche."),
            .init(id: "neutral-2", expectation: .neutral, duration: duration,
                  instruction: "Reviens en posture naturelle."),
            .init(id: "right-shoulder-raised", expectation: .rightShoulderRaised,
                  duration: duration, instruction: "Lève l'épaule droite."),
            .init(id: "neutral-3", expectation: .neutral, duration: duration,
                  instruction: "Reviens en posture naturelle."),
            .init(id: "both-shoulders-raised", expectation: .bothShouldersRaised,
                  duration: duration, instruction: "Lève les deux épaules."),
            .init(id: "shoulders-closed", expectation: .shouldersClosed,
                  duration: duration, instruction: "Ferme les épaules vers l'avant."),
            .init(id: "shoulders-open", expectation: .shouldersOpen,
                  duration: duration, instruction: "Ouvre les épaules naturellement."),
            .init(id: "torso-lean-left", expectation: .torsoLeanLeft,
                  duration: duration, instruction: "Incline le torse vers la gauche."),
            .init(id: "torso-lean-right", expectation: .torsoLeanRight,
                  duration: duration, instruction: "Incline le torse vers la droite."),
            .init(id: "recovery", expectation: .recovery, duration: duration,
                  instruction: "Reviens en posture naturelle.")
        ]
    }

    public static let measurement20s: PostureValidationPlan = {
        PostureValidationPlan(
            mode: .measurement20s,
            definitions: definitions(duration: 20)
        )!
    }()

    public static let notification60s: PostureValidationPlan = {
        PostureValidationPlan(
            mode: .notification60s,
            definitions: definitions(duration: 60)
        )!
    }()
}

/// Échantillon strictement scalaire. Aucune image, coordonnée brute ou trame n'est acceptée.
public struct PostureValidationSample: Codable, Equatable, Sendable {
    public let timestamp: TimeInterval
    public let phaseID: String
    public let expected: PostureValidationExpectation
    public let expectedAttention: PostureValidationAttention?
    public let predictedAttention: PostureValidationAttention?
    public let availability: PostureValidationAvailability
    public let predictedDirection: PostureValidationDirection?
    public let latencyMilliseconds: Double?
    public let scalarValues: [String: Double]

    public init(
        timestamp: TimeInterval,
        phaseID: String,
        expected: PostureValidationExpectation,
        expectedAttention: PostureValidationAttention?,
        predictedAttention: PostureValidationAttention?,
        availability: PostureValidationAvailability,
        predictedDirection: PostureValidationDirection?,
        latencyMilliseconds: Double?,
        scalarValues: [String: Double]
    ) {
        self.timestamp = timestamp
        self.phaseID = phaseID
        self.expected = expected
        self.expectedAttention = expectedAttention
        self.predictedAttention = predictedAttention
        self.availability = availability
        self.predictedDirection = predictedDirection
        if let latencyMilliseconds,
           latencyMilliseconds.isFinite,
           latencyMilliseconds >= 0 {
            self.latencyMilliseconds = latencyMilliseconds
        } else {
            self.latencyMilliseconds = nil
        }
        self.scalarValues = scalarValues.filter { $0.value.isFinite }
    }
}

public enum PostureValidationRecordRejection: String, Codable, Equatable, Sendable {
    case finished
    case invalidTimestamp
    case outsidePlan
    case nonMonotonicTimestamp
}

public enum PostureValidationRecordResult: Codable, Equatable, Sendable {
    case accepted
    case rejected(PostureValidationRecordRejection)
}

public struct PostureValidationRatio: Codable, Equatable, Sendable {
    public let numerator: Int
    public let denominator: Int

    public var value: Double? {
        guard denominator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }

    public init(numerator: Int, denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }
}

public struct PostureValidationDistribution: Codable, Equatable, Sendable {
    public let count: Int
    public let average: Double?
    public let minimum: Double?
    public let maximum: Double?
    public let p50: Double?
    public let p95: Double?

    fileprivate init(values: [Double]) {
        let finiteValues = values.filter(\.isFinite).sorted()
        self.count = finiteValues.count
        guard !finiteValues.isEmpty else {
            self.average = nil
            self.minimum = nil
            self.maximum = nil
            self.p50 = nil
            self.p95 = nil
            return
        }

        self.average = finiteValues.reduce(0, +) / Double(finiteValues.count)
        self.minimum = finiteValues.first
        self.maximum = finiteValues.last
        self.p50 = Self.nearestRank(0.50, values: finiteValues)
        self.p95 = Self.nearestRank(0.95, values: finiteValues)
    }

    private static func nearestRank(_ quantile: Double, values: [Double]) -> Double {
        let rank = max(1, Int(ceil(quantile * Double(values.count))))
        return values[min(values.count, rank) - 1]
    }
}

public struct PostureValidationStabilityMetric: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let median: Double?
    public let medianAbsoluteDeviation: Double?
    public let relativeMedianAbsoluteDeviation: Double?

    fileprivate init(values: [Double]) {
        let finiteValues = values.filter(\.isFinite)
        self.sampleCount = finiteValues.count
        guard let median = Self.median(finiteValues) else {
            self.median = nil
            self.medianAbsoluteDeviation = nil
            self.relativeMedianAbsoluteDeviation = nil
            return
        }

        let deviation = finiteValues.map { abs($0 - median) }
        let mad = Self.median(deviation)
        self.median = median
        self.medianAbsoluteDeviation = mad
        if let mad, abs(median) > Double.ulpOfOne {
            self.relativeMedianAbsoluteDeviation = mad / abs(median)
        } else {
            self.relativeMedianAbsoluteDeviation = nil
        }
    }

    fileprivate static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

public struct PostureValidationRepeatabilityMetric: Codable, Equatable, Sendable {
    public let firstSampleCount: Int
    public let secondSampleCount: Int
    public let firstMedian: Double?
    public let secondMedian: Double?
    public let absoluteMedianDifference: Double?
    public let relativeMedianDifference: Double?

    fileprivate init(firstValues: [Double], secondValues: [Double]) {
        self.firstSampleCount = firstValues.count
        self.secondSampleCount = secondValues.count
        self.firstMedian = PostureValidationStabilityMetric.median(firstValues)
        self.secondMedian = PostureValidationStabilityMetric.median(secondValues)
        if let firstMedian, let secondMedian {
            let difference = abs(firstMedian - secondMedian)
            self.absoluteMedianDifference = difference
            let scale = max(abs(firstMedian), abs(secondMedian))
            self.relativeMedianDifference = scale > Double.ulpOfOne ? difference / scale : nil
        } else {
            self.absoluteMedianDifference = nil
            self.relativeMedianDifference = nil
        }
    }
}

public struct PostureValidationPhaseMetrics: Codable, Equatable, Sendable {
    public let phaseID: String
    public let expected: PostureValidationExpectation
    public let sampleCount: Int
    public let reliableCount: Int
    public let predictedAttentionCount: Int
    public let expectedAttentionCount: Int
    public let coverage: PostureValidationRatio
    public let recall: PostureValidationRatio?
    public let falsePositiveShare: PostureValidationRatio?
    public let directionAccuracy: PostureValidationRatio?
    public let latency: PostureValidationDistribution

    fileprivate init(phase: PostureValidationPhase, samples: [PostureValidationSample]) {
        self.phaseID = phase.id
        self.expected = phase.expectation
        self.sampleCount = samples.count
        self.reliableCount = samples.reduce(into: 0) { count, sample in
            if sample.availability.isReliable { count += 1 }
        }
        self.predictedAttentionCount = samples.reduce(into: 0) { count, sample in
            if sample.predictedAttention != nil { count += 1 }
        }
        self.expectedAttentionCount = samples.reduce(into: 0) { count, sample in
            if sample.expectedAttention != nil { count += 1 }
        }
        self.coverage = PostureValidationRatio(
            numerator: reliableCount,
            denominator: sampleCount
        )
        if phase.expectation.expectedAttention != nil {
            self.recall = PostureValidationRatio(
                numerator: samples.reduce(into: 0) { count, sample in
                    if sample.predictedAttention == sample.expectedAttention {
                        count += 1
                    }
                },
                denominator: expectedAttentionCount
            )
        } else {
            self.recall = nil
        }
        self.falsePositiveShare = phase.expectation.expectedAttention == nil
            ? PostureValidationRatio(numerator: predictedAttentionCount, denominator: sampleCount)
            : nil

        let directionalSamples = samples.filter {
            $0.expected.expectedDirection != nil &&
            $0.predictedAttention == $0.expectedAttention &&
            $0.availability.isReliable &&
            $0.predictedDirection != nil
        }
        let correct = directionalSamples.reduce(into: 0) { count, sample in
            if sample.predictedDirection == sample.expected.expectedDirection { count += 1 }
        }
        self.directionAccuracy = phase.expectation.expectedDirection == nil
            ? nil
            : PostureValidationRatio(numerator: correct, denominator: directionalSamples.count)
        self.latency = PostureValidationDistribution(
            values: samples.compactMap(\.latencyMilliseconds)
        )
    }
}

/// Rapport local agrégé. Il n'embarque aucun échantillon brut et aucun seuil de précision.
public struct PostureValidationReport: Codable, Equatable, Sendable {
    public let mode: PostureValidationMode
    public let protocolVersion: String
    public let totalDuration: TimeInterval
    public let recordedSampleCount: Int
    public let attentionAttemptCount: Int
    public let noAttentionAttemptCount: Int
    public let predictedAttentionCount: Int
    public let coverage: PostureValidationRatio
    public let recall: PostureValidationRatio
    public let falsePositiveShare: PostureValidationRatio
    public let directionAttemptCount: Int
    public let directionEligibleCount: Int
    public let directionUnknownCount: Int
    public let directionAccuracy: PostureValidationRatio
    public let latency: PostureValidationDistribution
    public let recoveryAttemptCount: Int
    public let recoverySuccessCount: Int
    public let recoveryLatency: PostureValidationDistribution
    public let stability: [String: PostureValidationStabilityMetric]
    public let repeatability: [String: PostureValidationRepeatabilityMetric]
    public let phases: [PostureValidationPhaseMetrics]

    fileprivate init(plan: PostureValidationPlan, samples: [PostureValidationSample]) {
        self.mode = plan.mode
        self.protocolVersion = "guided-validation-v1"
        self.totalDuration = plan.totalDuration
        self.recordedSampleCount = samples.count

        let attentionSamples = samples.filter { $0.expectedAttention != nil }
        let noAttentionSamples = samples.filter { $0.expectedAttention == nil }
        self.attentionAttemptCount = attentionSamples.count
        self.noAttentionAttemptCount = noAttentionSamples.count
        self.predictedAttentionCount = samples.reduce(into: 0) { count, sample in
            if sample.predictedAttention != nil { count += 1 }
        }

        let reliableCount = samples.reduce(into: 0) { count, sample in
            if sample.availability.isReliable { count += 1 }
        }
        let detectedAttentionCount = attentionSamples.reduce(into: 0) { count, sample in
            if sample.predictedAttention == sample.expectedAttention { count += 1 }
        }
        let falsePositiveCount = noAttentionSamples.reduce(into: 0) { count, sample in
            if sample.predictedAttention != nil { count += 1 }
        }
        self.coverage = PostureValidationRatio(
            numerator: reliableCount,
            denominator: samples.count
        )
        self.recall = PostureValidationRatio(
            numerator: detectedAttentionCount,
            denominator: attentionSamples.count
        )
        self.falsePositiveShare = PostureValidationRatio(
            numerator: falsePositiveCount,
            denominator: noAttentionSamples.count
        )

        let directionalSamples = samples.filter { $0.expected.expectedDirection != nil }
        let eligibleDirectionalSamples = directionalSamples.filter {
            $0.predictedAttention == $0.expectedAttention &&
            $0.availability.isReliable &&
            $0.predictedDirection != nil
        }
        let correctDirectionalSamples = eligibleDirectionalSamples.reduce(into: 0) { count, sample in
            if sample.predictedDirection == sample.expected.expectedDirection { count += 1 }
        }
        self.directionAttemptCount = directionalSamples.count
        self.directionEligibleCount = eligibleDirectionalSamples.count
        self.directionUnknownCount = directionalSamples.count - eligibleDirectionalSamples.count
        self.directionAccuracy = PostureValidationRatio(
            numerator: correctDirectionalSamples,
            denominator: eligibleDirectionalSamples.count
        )
        self.latency = PostureValidationDistribution(
            values: samples.compactMap(\.latencyMilliseconds)
        )

        let recoveryPhases = plan.phases.filter { $0.expectation == .recovery }
        self.recoveryAttemptCount = recoveryPhases.count
        var recoveryLatencies: [Double] = []
        for phase in recoveryPhases {
            let firstReliable = samples
                .filter { $0.phaseID == phase.id }
                .filter { $0.predictedAttention == nil && $0.availability.isReliable }
                .min { $0.timestamp < $1.timestamp }
            if let firstReliable {
                recoveryLatencies.append(max(0, firstReliable.timestamp - phase.startTime))
            }
        }
        self.recoverySuccessCount = recoveryLatencies.count
        self.recoveryLatency = PostureValidationDistribution(values: recoveryLatencies)

        var phaseMetrics: [PostureValidationPhaseMetrics] = []
        for phase in plan.phases {
            phaseMetrics.append(PostureValidationPhaseMetrics(
                phase: phase,
                samples: samples.filter { $0.phaseID == phase.id }
            ))
        }
        self.phases = phaseMetrics

        let neutralPhases = plan.phases.filter { $0.expectation == .neutral }
        var neutralValues: [String: [Double]] = [:]
        for phase in neutralPhases {
            for sample in samples where sample.phaseID == phase.id && sample.availability.isReliable {
                for (key, value) in sample.scalarValues {
                    neutralValues[key, default: []].append(value)
                }
            }
        }
        self.stability = neutralValues.mapValues(PostureValidationStabilityMetric.init(values:))

        let neutralSamples = samples
            .filter { $0.expected == .neutral && $0.availability.isReliable }
            .sorted { $0.timestamp < $1.timestamp }
        let midpoint = neutralSamples.count / 2
        var firstValues: [String: [Double]] = [:]
        var secondValues: [String: [Double]] = [:]
        for (index, sample) in neutralSamples.enumerated() {
            for (key, value) in sample.scalarValues {
                if index < midpoint {
                    firstValues[key, default: []].append(value)
                } else {
                    secondValues[key, default: []].append(value)
                }
            }
        }
        var repeatability: [String: PostureValidationRepeatabilityMetric] = [:]
        let keys = Set(firstValues.keys).union(secondValues.keys)
        for key in keys {
            repeatability[key] = PostureValidationRepeatabilityMetric(
                firstValues: firstValues[key] ?? [],
                secondValues: secondValues[key] ?? []
            )
        }
        self.repeatability = repeatability
    }
}

/// Moteur en mémoire : les trames et images restent dans l'appelant, seuls les scalaires sont transmis.
public struct PostureValidationSession: Sendable {
    public let plan: PostureValidationPlan
    public private(set) var samples: [PostureValidationSample] = []
    public private(set) var isFinished = false

    private var lastTimestamp: TimeInterval?

    public init(plan: PostureValidationPlan) {
        self.plan = plan
        self.lastTimestamp = nil
    }

    @discardableResult
    public mutating func record(
        timestamp: TimeInterval,
        predictedAttention: PostureValidationAttention?,
        availability: PostureValidationAvailability,
        predictedDirection: PostureValidationDirection? = nil,
        latencyMilliseconds: Double? = nil,
        scalarValues: [String: Double] = [:]
    ) -> PostureValidationRecordResult {
        guard !isFinished else { return .rejected(.finished) }
        guard timestamp.isFinite, timestamp >= 0 else {
            return .rejected(.invalidTimestamp)
        }
        guard let phase = plan.phase(at: timestamp) else {
            return .rejected(.outsidePlan)
        }
        if let lastTimestamp, timestamp <= lastTimestamp {
            return .rejected(.nonMonotonicTimestamp)
        }

        samples.append(PostureValidationSample(
            timestamp: timestamp,
            phaseID: phase.id,
            expected: phase.expectation,
            expectedAttention: phase.expectation.expectedAttention,
            predictedAttention: predictedAttention,
            availability: availability,
            predictedDirection: predictedDirection,
            latencyMilliseconds: latencyMilliseconds,
            scalarValues: scalarValues
        ))
        lastTimestamp = timestamp
        return .accepted
    }

    public mutating func finish() -> PostureValidationReport {
        isFinished = true
        return PostureValidationReport(plan: plan, samples: samples)
    }
}
