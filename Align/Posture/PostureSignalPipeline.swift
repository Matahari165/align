import Foundation

nonisolated enum PostureIndicatorID: String, CaseIterable, Sendable {
    case headDistance, estimatedEyeHeight, estimatedBlinks, estimatedForwardHead, raisedShoulders, narrowedBrows
    var title: String { switch self {
    case .headDistance: "Distance tête"; case .estimatedEyeHeight: "Position de tête estimée"
    case .estimatedBlinks: "Clignements estimés"; case .estimatedForwardHead: "Tête avancée — estimation"
    case .raisedShoulders: "Épaules élevées"; case .narrowedBrows: "Sourcils rapprochés" } }
}
nonisolated enum PostureIndicatorState: String, Sendable {
    case needsCalibration, calibrating, normal, pending, attention, unavailable
    var displayName: String { switch self {
    case .needsCalibration: "À calibrer"; case .calibrating: "Calibration…"; case .normal: "Dans le repère"
    case .pending: "Observation…"; case .attention: "Attention"; case .unavailable: "Indisponible" } }
}
nonisolated struct PostureIndicatorResult: Equatable, Sendable {
    let id: PostureIndicatorID; let state: PostureIndicatorState; let count: Int?
    let observedAt: TimeInterval?; let isExperimental: Bool
    static func unavailable(_ id: PostureIndicatorID) -> Self {
        .init(id: id, state: .unavailable, count: nil, observedAt: nil, isExperimental: id == .estimatedForwardHead)
    }
}
nonisolated struct PostureIndicatorsSnapshot: Equatable, Sendable {
    static let initial = Self(generation: 0, producedAt: 0, isCalibrating: false,
                              indicators: PostureIndicatorID.allCases.map(PostureIndicatorResult.unavailable))
    let generation: UInt64; let producedAt: TimeInterval; let isCalibrating: Bool
    let indicators: [PostureIndicatorResult]
    func result(for id: PostureIndicatorID) -> PostureIndicatorResult {
        indicators.first { $0.id == id } ?? .unavailable(id)
    }
}

nonisolated struct PostureSignalPipeline: Sendable {
    static let calibrationDuration: TimeInterval = 8
    static let ttl: TimeInterval = 0.75
    private(set) var generation: UInt64 = 0
    private(set) var snapshot = PostureIndicatorsSnapshot.initial
    private var evaluator = PostureEvaluatorSuite()
    private var calibration: PostureCalibration?
    private var session: PostureCalibrationSession?
    private var latest: PostureSnapshot?

    mutating func reset(generation: UInt64) -> PostureIndicatorsSnapshot {
        self.generation = generation; evaluator.reset(); calibration = nil; session = nil; latest = nil
        snapshot = .init(generation: generation, producedAt: 0, isCalibrating: false,
                         indicators: PostureIndicatorID.allCases.map(PostureIndicatorResult.unavailable)); return snapshot
    }
    mutating func beginCalibration(at now: TimeInterval, generation: UInt64) -> PostureIndicatorsSnapshot {
        guard now.isFinite else { return snapshot }
        if generation != self.generation { _ = reset(generation: generation) }
        calibration = nil; evaluator.reset(); session = .init(generation: generation, startedAt: now)
        return publish(evaluator.consume(nil, calibration: nil, now: now, calibrationInProgress: true), at: now)
    }
    mutating func ingest(_ input: PostureSnapshot, now: TimeInterval) -> PostureIndicatorsSnapshot {
        guard input.faceGeneration == generation, now.isFinite, accepts(input) else { return snapshot }
        latest = input
        if var active = session { switch active.consume(input) {
        case .collecting: session = active
        case .ready(let value): calibration = value; session = nil; evaluator.reset()
        case .failed: session = nil } }
        return publish(evaluator.consume(input, calibration: calibration, now: now,
                                         calibrationInProgress: session != nil), at: now)
    }
    private func accepts(_ input: PostureSnapshot) -> Bool {
        guard let latest else { return true }
        guard input.faceGeneration >= latest.faceGeneration else { return false }
        if input.faceGeneration > latest.faceGeneration { return input.faceTimestamp > latest.faceTimestamp }
        if input.sameFaceEvidence(as: latest) {
            guard let incomingTime = input.bodyTimestamp, let incomingID = input.bodySampleID else {
                return latest.bodyTimestamp != nil
            }
            guard let oldTime = latest.bodyTimestamp, let oldID = latest.bodySampleID else { return true }
            return incomingTime > oldTime || (incomingTime == oldTime && incomingID > oldID)
        }
        return (input.faceTimestamp > latest.faceTimestamp &&
                input.faceSampleID != latest.faceSampleID) ||
            (input.faceTimestamp == latest.faceTimestamp &&
             input.faceSampleID > latest.faceSampleID)
    }
    mutating func expire(at now: TimeInterval, generation: UInt64) -> PostureIndicatorsSnapshot {
        guard generation == self.generation, now.isFinite else { return snapshot }
        if var active = session { switch active.finish(at: now) {
        case .collecting: session = active
        case .ready(let value): calibration = value; session = nil; evaluator.reset()
        case .failed: session = nil } }
        let input = latest.flatMap { $0.isFresh(at: now, ttl: Self.ttl) ? $0 : nil }
        return publish(evaluator.consume(input, calibration: calibration, now: now,
                                         calibrationInProgress: session != nil), at: now)
    }
    private mutating func publish(_ set: PostureEvaluationSet, at now: TimeInterval) -> PostureIndicatorsSnapshot {
        let values: [(PostureIndicatorID, PostureSignalEvaluation)] = [
            (.headDistance, set.headProximity), (.estimatedEyeHeight, set.relativeHeadPosition),
            (.estimatedBlinks, set.estimatedBlinks), (.estimatedForwardHead, set.experimentalForwardHead),
            (.raisedShoulders, set.elevatedShoulders), (.narrowedBrows, set.narrowedBrows)]
        snapshot = .init(generation: generation, producedAt: now, isCalibrating: session != nil,
            indicators: values.map { id, value in .init(id: id, state: uiState(value.state, for: id),
                count: id == .estimatedBlinks ? value.value.map(Int.init) : nil,
                observedAt: value.state == .unavailable ? nil : observedAt(for: id),
                isExperimental: value.isExperimental) }); return snapshot
    }
    private func observedAt(for id: PostureIndicatorID) -> TimeInterval? {
        switch id {
        case .estimatedForwardHead, .raisedShoulders: latest?.bodyTimestamp
        default: latest?.faceTimestamp
        }
    }
    private func uiState(_ state: PostureSignalState, for id: PostureIndicatorID) -> PostureIndicatorState { switch state {
    case .unavailable:
        (id == .estimatedForwardHead || id == .raisedShoulders) || calibration != nil || session != nil
            ? .unavailable : .needsCalibration
    case .calibrating: .calibrating; case .neutral: .normal; case .pending, .experimental: .pending
    case .attention: .attention } }
}
