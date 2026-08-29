import Foundation

nonisolated struct PoseOverlayFreshnessTracker {
    static let maxAge: TimeInterval = 0.25

    private var generation = 0
    private var lastObservationUptime: TimeInterval?

    mutating func reset(generation: Int) {
        self.generation = generation
        lastObservationUptime = nil
    }

    mutating func recordObservation(at uptime: TimeInterval, generation: Int) {
        self.generation = generation
        lastObservationUptime = uptime
    }

    mutating func recordMiss() {
        lastObservationUptime = nil
    }

    func shouldExpire(at uptime: TimeInterval, generation: Int) -> Bool {
        guard self.generation == generation, let lastObservationUptime else { return false }
        return uptime - lastObservationUptime >= Self.maxAge
    }
}

nonisolated struct SilhouetteOverlayFreshnessTracker {
    /// Visual freshness is independent from the one-second segmentation cadence:
    /// a contour older than 0.30 s is no longer drawn. Cadence tolerance must
    /// never be used to keep stale geometry on screen.
    static let maxAge: TimeInterval = 0.30
    private var generation = 0
    private var lastObservationUptime: TimeInterval?

    mutating func reset(generation: Int) {
        self.generation = generation
        lastObservationUptime = nil
    }

    mutating func recordObservation(at uptime: TimeInterval, generation: Int) {
        self.generation = generation
        lastObservationUptime = uptime
    }

    func shouldExpire(at uptime: TimeInterval, generation: Int) -> Bool {
        guard self.generation == generation, let lastObservationUptime else { return false }
        return uptime - lastObservationUptime >= Self.maxAge
    }
}

nonisolated struct BodyOverlayFreshnessTracker {
    static let maxAge: TimeInterval = 1.2
    private var generation = 0
    private var lastObservationUptime: TimeInterval?

    mutating func reset(generation: Int) {
        self.generation = generation
        lastObservationUptime = nil
    }

    mutating func recordObservation(at uptime: TimeInterval, generation: Int) {
        self.generation = generation
        lastObservationUptime = uptime
    }

    mutating func recordMiss() {
        lastObservationUptime = nil
    }

    func shouldExpire(at uptime: TimeInterval, generation: Int) -> Bool {
        guard self.generation == generation, let lastObservationUptime else { return false }
        return uptime - lastObservationUptime >= Self.maxAge
    }
}

nonisolated enum PoseDetectionResult: Sendable {
    case detected(PoseTrackingStatus)
    case noPose
    case inferenceError
}

nonisolated enum PoseStabilizationUpdate: Sendable {
    case publish(PoseTrackingStatus?)
    case analysisFailed
}

nonisolated struct PoseResultStabilizer {
    static let maxPoseAge: TimeInterval = 0.8

    private let missesBeforeLoss = 3
    private let inferenceErrorsBeforeFailure = 3
    private let minimumInferenceFailureDuration: TimeInterval = 0.4
    private var lastReliableStatus: PoseTrackingStatus?
    private var lastReliableUptime: TimeInterval?
    private var consecutiveMisses = 0
    private var consecutiveInferenceErrors = 0
    private var firstInferenceErrorUptime: TimeInterval?

    mutating func update(
        with result: PoseDetectionResult,
        at uptime: TimeInterval
    ) -> PoseStabilizationUpdate? {
        switch result {
        case .detected(let status):
            resetInferenceErrors()
            lastReliableStatus = status
            lastReliableUptime = uptime
            consecutiveMisses = 0
            return .publish(status)

        case .noPose:
            resetInferenceErrors()
            guard lastReliableStatus != nil else { return nil }
            consecutiveMisses += 1
            guard consecutiveMisses >= missesBeforeLoss else { return nil }
            reset()
            return .publish(nil)

        case .inferenceError:
            consecutiveInferenceErrors += 1
            if firstInferenceErrorUptime == nil {
                firstInferenceErrorUptime = uptime
            }

            guard consecutiveInferenceErrors >= inferenceErrorsBeforeFailure,
                  let firstInferenceErrorUptime,
                  uptime - firstInferenceErrorUptime + .ulpOfOne >= minimumInferenceFailureDuration else {
                return nil
            }

            reset()
            return .analysisFailed
        }
    }

    mutating func expireIfNeeded(at uptime: TimeInterval) -> PoseStabilizationUpdate? {
        guard lastReliableStatus != nil, let lastReliableUptime else { return nil }
        guard uptime - lastReliableUptime >= Self.maxPoseAge else { return nil }
        reset()
        return .publish(nil)
    }

    mutating func reset() {
        lastReliableStatus = nil
        lastReliableUptime = nil
        consecutiveMisses = 0
        resetInferenceErrors()
    }

    private mutating func resetInferenceErrors() {
        consecutiveInferenceErrors = 0
        firstInferenceErrorUptime = nil
    }
}
