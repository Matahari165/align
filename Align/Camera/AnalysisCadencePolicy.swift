import Foundation

nonisolated enum VisionAnalysisUnit: String, Sendable {
    case face
    case body
    case silhouette
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

nonisolated struct AnalysisPresentationState: Equatable, Sendable {
    var isApplicationActive: Bool
    var isWindowMiniaturized: Bool
    var isBenchmarkRunning: Bool

    static let foreground = AnalysisPresentationState(
        isApplicationActive: true,
        isWindowMiniaturized: false,
        isBenchmarkRunning: false
    )

    var faceInterval: TimeInterval {
        isForegroundVisible || isBenchmarkRunning ? 0.2 : 0.5
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
