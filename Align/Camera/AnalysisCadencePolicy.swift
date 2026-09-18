import CoreGraphics
import Foundation

nonisolated enum CameraCaptureRatePolicy {
    /// The analysis scheduler consumes at most 10 face samples and 1–2
    /// upper-body samples per second. Twenty capture frames per second keeps
    /// an even two-frame rhythm for the 10 Hz face cadence while avoiding the
    /// unused third of a 30 fps camera stream.
    static let targetFramesPerSecond = 20.0
    static let preferredFallbackFramesPerSecond = 15.0

    /// Chooses a rate supported by the active camera format. Twenty fps is
    /// the target; 15 fps is the explicit compatibility fallback. Unusual
    /// formats use the closest supported rate, preferring one not above the
    /// target when the camera exposes that choice.
    static func framesPerSecond(for ranges: [(minimum: Double, maximum: Double)]) -> Double? {
        func supports(_ rate: Double) -> Bool {
            ranges.contains { $0.minimum <= rate && $0.maximum >= rate }
        }
        if supports(targetFramesPerSecond) { return targetFramesPerSecond }
        if supports(preferredFallbackFramesPerSecond) { return preferredFallbackFramesPerSecond }
        return ranges.compactMap { range -> Double? in
            guard range.minimum.isFinite, range.maximum.isFinite,
                  range.minimum > 0, range.maximum >= range.minimum else { return nil }
            return min(targetFramesPerSecond, range.maximum) >= range.minimum
                ? min(targetFramesPerSecond, range.maximum)
                : range.minimum
        }.min {
            let leftDistance = abs($0 - targetFramesPerSecond)
            let rightDistance = abs($1 - targetFramesPerSecond)
            return leftDistance == rightDistance ? $0 < $1 : leftDistance < rightDistance
        }
    }
}

nonisolated enum VisionAnalysisUnit: String, Sendable {
    case upperBody
    case face
    case body
    case silhouette
    case upperBodyROISpike
}

/// Expensive Vision probes are mutually exclusive so one benchmark measures
/// one experiment instead of making two heavyweight pipelines compete.
nonisolated enum BenchmarkVisionExperiment: Sendable, Equatable {
    case upperBodyROI
    case silhouette

    func enables(_ unit: VisionAnalysisUnit) -> Bool {
        switch (self, unit) {
        case (.upperBodyROI, .upperBodyROISpike), (.silhouette, .silhouette): true
        default: false
        }
    }

    var reportName: String {
        switch self {
        case .upperBodyROI: "cou et épaules : plein cadre comparé à ROI"
        case .silhouette: "silhouette par segmentation"
        }
    }
}

nonisolated enum BenchmarkVisionCandidatePolicy {
    static func units(for experiment: BenchmarkVisionExperiment?) -> [VisionAnalysisUnit] {
        switch experiment {
        case .upperBodyROI: [.upperBodyROISpike]
        case .silhouette: [.silhouette]
        case nil: []
        }
    }

    static func allows(_ unit: VisionAnalysisUnit, in presentation: AnalysisPresentationState) -> Bool {
        units(for: presentation.benchmarkExperiment).contains { $0 == unit }
    }
}

/// Epoch independent from pose-processing generations. It invalidates a
/// synchronous segmentation result as soon as a benchmark stops.
nonisolated struct BenchmarkSegmentationEpoch: Sendable {
    private(set) var currentToken: UInt64?
    private var nextToken: UInt64 = 0

    mutating func begin() -> UInt64 {
        nextToken &+= 1
        currentToken = nextToken
        return nextToken
    }

    mutating func invalidate() {
        currentToken = nil
    }

    func accepts(_ token: UInt64, benchmarkRunning: Bool) -> Bool {
        benchmarkRunning && currentToken == token
    }
}

/// Shared cancellation state read synchronously across MainActor/sampleQueue.
/// Invalidating it does not wait behind an in-flight Vision perform.
nonisolated final class BenchmarkSegmentationCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var currentToken: UInt64?

    func activate(_ token: UInt64) {
        lock.lock()
        currentToken = token
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        currentToken = nil
        lock.unlock()
    }

    func accepts(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentToken == token
    }

    /// Commits short post-perform state changes atomically with cancellation.
    /// The closure must not call back into this box.
    @discardableResult
    func withAcceptedToken(_ token: UInt64, commit: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentToken == token else { return false }
        commit()
        return true
    }
}

nonisolated struct VisionAnalysisCandidate: Sendable {
    let unit: VisionAnalysisUnit
    let overdue: TimeInterval
    let priority: Int
}

nonisolated enum VisionAnalysisSelector {
    /// Selects one due unit. Overdue work wins; equal first-due work follows
    /// face → body → silhouette so simultaneous due units occupy distinct
    /// callbacks instead of sharing one Vision call.
    static func select(_ candidates: [VisionAnalysisCandidate]) -> VisionAnalysisUnit? {
        candidates.max {
            if $0.overdue == $1.overdue { return $0.priority < $1.priority }
            return $0.overdue < $1.overdue
        }?.unit
    }
}

/// Cooperative callback budget: one camera callback may claim exactly one
/// Vision unit. The sample queue remains the single serialization boundary.
nonisolated struct VisionCallbackBudget: Sendable {
    private(set) var claimedUnit: VisionAnalysisUnit?

    mutating func beginCallback() { claimedUnit = nil }

    mutating func claim(_ unit: VisionAnalysisUnit) -> Bool {
        guard claimedUnit == nil else { return false }
        claimedUnit = unit
        return true
    }
}

/// Allows the first capture callback of an activation to reconcile camera
/// liveness, while making all subsequent callbacks allocation-free. The gate
/// is confined to the sample queue by its owner and reset on every activation.
nonisolated struct FrameLivenessGate: Sendable {
    private(set) var didPublish = false

    mutating func claim() -> Bool {
        guard !didPublish else { return false }
        didPublish = true
        return true
    }

    mutating func reset() {
        didPublish = false
    }
}

nonisolated struct UpperBodyCadenceController: Sendable {
    private(set) var lastAttemptUptime: TimeInterval?

    func isDue(at uptime: TimeInterval, interval: TimeInterval) -> Bool {
        guard let lastAttemptUptime else { return true }
        return uptime - lastAttemptUptime >= interval
    }

    func overdue(at uptime: TimeInterval, interval: TimeInterval) -> TimeInterval {
        guard let lastAttemptUptime else { return 1 }
        return max(0, uptime - lastAttemptUptime - interval)
    }

    mutating func recordAttempt(at uptime: TimeInterval) {
        lastAttemptUptime = uptime
    }

    mutating func reset() { lastAttemptUptime = nil }
}

/// Keeps body analysis responsive after visible motion, then settles to a
/// low-cost heartbeat. Face landmarks already run for blink detection, so
/// this controller adds no second motion model.
nonisolated struct AdaptiveUpperBodyCadenceController: Sendable {
    static let activeInterval: TimeInterval = 1.0
    static let restingInterval: TimeInterval = 5.0
    static let motionBurstDuration: TimeInterval = 10.0
    static let centerMovementThreshold: CGFloat = 0.015
    static let sizeChangeThreshold = 0.06

    private(set) var lastFaceBounds: CGRect?
    private(set) var activeUntil: TimeInterval?

    mutating func observeFace(bounds: CGRect, at uptime: TimeInterval) {
        guard bounds.isFiniteAndNonEmpty, uptime.isFinite else { return }
        defer { lastFaceBounds = bounds }
        guard let previous = lastFaceBounds else {
            activeUntil = uptime + Self.motionBurstDuration
            return
        }
        let centerDelta = hypot(bounds.midX - previous.midX, bounds.midY - previous.midY)
        let previousArea = previous.width * previous.height
        let area = bounds.width * bounds.height
        let sizeDelta = previousArea > 0 ? abs(area - previousArea) / previousArea : 1
        if centerDelta >= Self.centerMovementThreshold || sizeDelta >= Self.sizeChangeThreshold {
            activeUntil = uptime + Self.motionBurstDuration
        }
    }

    func interval(at uptime: TimeInterval, isCalibrating: Bool) -> TimeInterval {
        if isCalibrating { return 0.5 }
        return activeUntil.map { uptime < $0 } == true
            ? Self.activeInterval
            : Self.restingInterval
    }

    mutating func reset() {
        lastFaceBounds = nil
        activeUntil = nil
    }
}

nonisolated private extension CGRect {
    var isFiniteAndNonEmpty: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite &&
            width > 0 && height > 0
    }
}

nonisolated enum UpperBodyROISpikeStage: Sendable, Equatable {
    case humanRectangle
    case fullFrameBody
    case regionBody(CGRect)
}

/// Benchmark-only three-step probe. Each stage consumes a distinct camera
/// callback so rectangle, full-frame body and ROI body never share a perform.
nonisolated struct UpperBodyROISpikeCadence: Sendable {
    /// One pair every two seconds: full and ROI each run at ~0.5 Hz, keeping
    /// the total body-pose benchmark budget near 1 Hz.
    static let interval: TimeInterval = 2.0
    private(set) var lastCycleUptime: TimeInterval?
    private(set) var pendingStage: UpperBodyROISpikeStage?
    private var queuedRegion: CGRect?

    func isDue(at uptime: TimeInterval, benchmarkRunning: Bool) -> Bool {
        guard benchmarkRunning else { return false }
        if pendingStage != nil { return true }
        guard let lastCycleUptime else { return true }
        return uptime - lastCycleUptime >= Self.interval
    }

    mutating func claimStage(at uptime: TimeInterval) -> UpperBodyROISpikeStage {
        if let pendingStage {
            self.pendingStage = nil
            return pendingStage
        }
        lastCycleUptime = uptime
        return .humanRectangle
    }

    mutating func continueAfterRectangle(_ region: CGRect?) {
        guard let region else {
            pendingStage = nil
            queuedRegion = nil
            return
        }
        pendingStage = .fullFrameBody
        queuedRegion = region
    }

    mutating func continueAfterFullFrame() {
        if let queuedRegion { pendingStage = .regionBody(queuedRegion) }
        queuedRegion = nil
    }

    mutating func reset() {
        lastCycleUptime = nil
        pendingStage = nil
        queuedRegion = nil
    }
}

nonisolated struct AnalysisPresentationState: Equatable, Sendable {
    var isApplicationActive: Bool
    var isWindowMiniaturized: Bool
    var benchmarkExperiment: BenchmarkVisionExperiment?

    var isBenchmarkRunning: Bool { benchmarkExperiment != nil }
    var runsSilhouetteExperiment: Bool { BenchmarkVisionCandidatePolicy.allows(.silhouette, in: self) }
    var runsUpperBodyROIExperiment: Bool { BenchmarkVisionCandidatePolicy.allows(.upperBodyROISpike, in: self) }
    /// Benchmarks own the analysis slot exclusively and pause the product engine.
    var runsNormalUpperBodyEngine: Bool { !isBenchmarkRunning }
    /// VN Body is benchmark-only. The normal path owns exactly one upper-body engine.
    var runsNormalBodyAnalysis: Bool { false }

    static let foreground = AnalysisPresentationState(
        isApplicationActive: true,
        isWindowMiniaturized: false,
        benchmarkExperiment: nil
    )

    var faceInterval: TimeInterval {
        if isBenchmarkRunning { return 0.2 }
        // Les clignements sont un signal temporel : une cadence de 2 Hz
        // saute facilement toute la phase fermée d'un œil. Le visage reste
        // donc à 10 Hz même lorsque la fenêtre est en arrière-plan. Le rendu
        // visuel, lui, reste désactivé par `publishesVisualUpdates`.
        return 0.1
    }

    var upperBodyInterval: TimeInterval {
        1.0
    }

    /// Eight seconds of calibration require at least twelve body samples.
    /// Keep the acquisition cadence independent of foreground visibility.
    func upperBodyInterval(isCalibrating: Bool) -> TimeInterval {
        isCalibrating ? 0.5 : upperBodyInterval
    }

    var publishesVisualUpdates: Bool {
        isForegroundVisible || isBenchmarkRunning
    }

    private var isForegroundVisible: Bool {
        isApplicationActive && !isWindowMiniaturized
    }
}

nonisolated struct AnalysisCadenceController: Sendable {
    private(set) var presentation = AnalysisPresentationState.foreground
    private(set) var lastAnalysisUptime: TimeInterval?

    mutating func updatePresentation(_ presentation: AnalysisPresentationState) {
        self.presentation = presentation
    }

    mutating func shouldAnalyze(at uptime: TimeInterval) -> Bool {
        guard isDue(at: uptime) else { return false }
        recordAnalysis(at: uptime)
        return true
    }

    func isDue(at uptime: TimeInterval) -> Bool {
        guard let lastAnalysisUptime else { return true }
        let clockTolerance: TimeInterval = 0.000_001
        return uptime - lastAnalysisUptime + clockTolerance >= presentation.faceInterval
    }

    func overdue(at uptime: TimeInterval) -> TimeInterval {
        guard let lastAnalysisUptime else { return 0 }
        return max(0, uptime - lastAnalysisUptime - presentation.faceInterval)
    }

    mutating func recordAnalysis(at uptime: TimeInterval) {
        lastAnalysisUptime = uptime
    }

    mutating func reset() {
        lastAnalysisUptime = nil
    }
}

/// Hand-to-face contact persists for seconds, so hand landmarks do not need
/// the 10 Hz cadence reserved for short eye blinks.
nonisolated struct HandAnalysisCadenceController: Sendable {
    static let interval: TimeInterval = 0.5
    private(set) var lastAnalysisUptime: TimeInterval?

    mutating func shouldAnalyze(at uptime: TimeInterval) -> Bool {
        guard lastAnalysisUptime.map({ uptime - $0 >= Self.interval }) ?? true else {
            return false
        }
        lastAnalysisUptime = uptime
        return true
    }

    mutating func reset() {
        lastAnalysisUptime = nil
    }
}

nonisolated struct SilhouetteCadenceController: Sendable {
    static let interval: TimeInterval = 1.0
    private(set) var lastAttemptUptime: TimeInterval?

    mutating func shouldRun(at uptime: TimeInterval, presentation: AnalysisPresentationState) -> Bool {
        guard isDue(at: uptime, presentation: presentation) else { return false }
        recordAttempt(at: uptime)
        return true
    }

    func isDue(at uptime: TimeInterval, presentation: AnalysisPresentationState) -> Bool {
        guard presentation.isBenchmarkRunning else { return false }
        guard let lastAttemptUptime else { return true }
        return uptime - lastAttemptUptime >= Self.interval
    }

    func overdue(at uptime: TimeInterval) -> TimeInterval {
        guard let lastAttemptUptime else { return 0 }
        return max(0, uptime - lastAttemptUptime - Self.interval)
    }

    mutating func recordAttempt(at uptime: TimeInterval) {
        lastAttemptUptime = uptime
    }

    mutating func reset() { lastAttemptUptime = nil }
}
