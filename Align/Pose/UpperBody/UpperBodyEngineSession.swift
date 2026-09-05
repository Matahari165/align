import Foundation

/// Reason why a frame was refused before it reached the active upper-body
/// engine. Kept as a scalar diagnostic so the UI can distinguish lifecycle,
/// timestamp and duplicate-watermark failures without retaining frame data.
nonisolated enum UpperBodyAdmissionRejectionReason: String, Equatable, Hashable, Sendable {
    case noActiveGeneration = "no-active-generation"
    case generationMismatch = "generation-mismatch"
    case invalidSampleID = "invalid-sample-id"
    case invalidCapturedAt = "invalid-captured-at"
    case invalidAdmissionClock = "invalid-admission-clock"
    case futureFrame = "future-frame"
    case staleFrame = "stale-frame"
    case duplicateFrame = "duplicate-frame"
    case invalidProducedAt = "invalid-produced-at"
    case postInferenceExpired = "post-inference-expired"
}

/// Scalar-only evidence for a rejected frame. No image, ROI coordinates or
/// model output are retained; the timestamps are only there to explain a
/// clock/PTS admission failure to Diagnostics.
nonisolated struct UpperBodyAdmissionRejection: Equatable, Sendable {
    let reason: UpperBodyAdmissionRejectionReason
    let activeGeneration: UInt64?
    let frameGeneration: UInt64
    let sampleID: UInt64
    let capturedAt: TimeInterval
    let admissionAt: TimeInterval
}

/// Counters are owned by the sample-queue session and reset at every
/// activation. They distinguish frames that reached the engine from results
/// that were returned as partial, including fail-closed ROI validation.
nonisolated struct UpperBodyEngineSessionDiagnostics: Equatable, Sendable {
    let attempts: UInt64
    let returnedResults: UInt64
    /// Number of frames that actually reached the pose engine.
    let inferenceResults: UInt64
    /// Partial outputs from the engine or the final fail-closed path if the
    /// bounded fallback cannot be constructed.
    let partialResults: UInt64
    let rejected: UInt64
    let roiRejected: UInt64
    /// Number of calls that used the bounded full-frame fallback crop.
    let fallbackAttempts: UInt64
    let rejectionCounts: [UpperBodyAdmissionRejectionReason: UInt64]
    let lastRejection: UpperBodyAdmissionRejection?
    let engineRuns: UInt64
    let lastEngineDuration: TimeInterval?
    let engineDurationP50: TimeInterval?
    let engineDurationP95: TimeInterval?
    let engineDurationMax: TimeInterval?
}

/// Unique owner of the active upper-body engine. It is confined to sampleQueue.
nonisolated struct UpperBodyEngineSession: @unchecked Sendable {
    static let defaultMaximumAge: TimeInterval = 1.2

    private let engine: any UpperBodyPoseEngine
    private let maximumAge: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private(set) var activeGeneration: UInt64?
    private(set) var lastRejectionReason: UpperBodyAdmissionRejectionReason?
    private(set) var lastRejection: UpperBodyAdmissionRejection?
    private(set) var analysisAttempts: UInt64
    private(set) var returnedResults: UInt64
    private(set) var inferenceResults: UInt64
    private(set) var partialResults: UInt64
    private(set) var roiRejected: UInt64
    private(set) var fallbackAttempts: UInt64
    private(set) var rejectionCounts: [UpperBodyAdmissionRejectionReason: UInt64]
    private(set) var engineRuns: UInt64
    private(set) var lastEngineDuration: TimeInterval?
    private var engineDurations: [TimeInterval]
    private var watermark: (capturedAt: TimeInterval, sampleID: UInt64)?
    private var latestResult: UpperBodyResult?

    init(
        engine: any UpperBodyPoseEngine,
        maximumAge: TimeInterval = Self.defaultMaximumAge,
        clock: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        precondition(maximumAge.isFinite && maximumAge > 0)
        self.engine = engine
        self.maximumAge = maximumAge
        self.clock = clock
        self.lastRejectionReason = nil
        self.lastRejection = nil
        self.analysisAttempts = 0
        self.returnedResults = 0
        self.inferenceResults = 0
        self.partialResults = 0
        self.roiRejected = 0
        self.fallbackAttempts = 0
        self.rejectionCounts = [:]
        self.engineRuns = 0
        self.lastEngineDuration = nil
        self.engineDurations = []
    }

    var descriptor: UpperBodyEngineDescriptor { engine.descriptor }
    var currentResult: UpperBodyResult? { latestResult }
    var admissionDiagnostics: UpperBodyEngineSessionDiagnostics {
        UpperBodyEngineSessionDiagnostics(
            attempts: analysisAttempts,
            returnedResults: returnedResults,
            inferenceResults: inferenceResults,
            partialResults: partialResults,
            rejected: rejectionCounts.values.reduce(0, +),
            roiRejected: roiRejected,
            fallbackAttempts: fallbackAttempts,
            rejectionCounts: rejectionCounts,
            lastRejection: lastRejection,
            engineRuns: engineRuns,
            lastEngineDuration: lastEngineDuration,
            engineDurationP50: percentile(0.50),
            engineDurationP95: percentile(0.95),
            engineDurationMax: engineDurations.max()
        )
    }

    mutating func activate(generation: UInt64) {
        engine.deactivate()
        activeGeneration = generation
        watermark = nil
        latestResult = nil
        lastRejectionReason = nil
        lastRejection = nil
        analysisAttempts = 0
        returnedResults = 0
        inferenceResults = 0
        partialResults = 0
        roiRejected = 0
        fallbackAttempts = 0
        rejectionCounts = [:]
        engineRuns = 0
        lastEngineDuration = nil
        engineDurations = []
        engine.activate(generation: generation)
    }

    mutating func deactivate() {
        engine.deactivate()
        activeGeneration = nil
        watermark = nil
        latestResult = nil
        lastRejectionReason = nil
        lastRejection = nil
        analysisAttempts = 0
        returnedResults = 0
        inferenceResults = 0
        partialResults = 0
        roiRejected = 0
        fallbackAttempts = 0
        rejectionCounts = [:]
        engineRuns = 0
        lastEngineDuration = nil
        engineDurations = []
    }

    mutating func analyze(_ frame: UpperBodyFrame) -> UpperBodyResult? {
        analysisAttempts &+= 1
        let admissionTime = clock()
        lastRejectionReason = nil
        guard let activeGeneration else {
            return reject(.noActiveGeneration, frame: frame, admissionAt: admissionTime)
        }
        guard frame.generation == activeGeneration else {
            return reject(.generationMismatch, frame: frame, admissionAt: admissionTime)
        }
        guard frame.sampleID > 0 else {
            return reject(.invalidSampleID, frame: frame, admissionAt: admissionTime)
        }
        guard frame.capturedAt.isFinite else {
            return reject(.invalidCapturedAt, frame: frame, admissionAt: admissionTime)
        }
        guard admissionTime.isFinite else {
            return reject(.invalidAdmissionClock, frame: frame, admissionAt: admissionTime)
        }
        guard admissionTime >= frame.capturedAt else {
            return reject(.futureFrame, frame: frame, admissionAt: admissionTime)
        }
        guard admissionTime - frame.capturedAt <= maximumAge else {
            return reject(.staleFrame, frame: frame, admissionAt: admissionTime)
        }
        if let watermark {
            guard frame.capturedAt > watermark.capturedAt ||
                    (frame.capturedAt == watermark.capturedAt && frame.sampleID > watermark.sampleID)
            else {
                return reject(
                    frame.capturedAt == watermark.capturedAt ? .duplicateFrame : .staleFrame,
                    frame: frame,
                    admissionAt: admissionTime
                )
            }
        }
        watermark = (frame.capturedAt, frame.sampleID)

        let regionOfInterest: UpperBodyRegionOfInterest
        if let providedROI = frame.regionOfInterest,
           providedROI.isAdmissible(
               forFrameCapturedAt: frame.capturedAt,
               generation: frame.generation
           ) {
            regionOfInterest = providedROI
        } else {
            // Vision may lose the face for one frame while the person remains
            // visible, or hand us an anchor that is stale/incoherent. In both
            // cases run RTMPose on a broad, bounded crop. The model still has
            // to return valid/confident points; this fallback never fabricates
            // geometry or asserts that a person is present.
            if frame.regionOfInterest != nil { roiRejected &+= 1 }
            guard let fallback = UpperBodyRegionOfInterest.fullFrameFallback(
                capturedAt: frame.capturedAt,
                sampleID: frame.sampleID,
                generation: frame.generation
            ) else {
                return partialResult(for: frame, producedAt: admissionTime)
            }
            fallbackAttempts &+= 1
            regionOfInterest = fallback
        }

        let engineStartedAt = clock()
        let engineFrame = UpperBodyFrame(
            pixelBuffer: frame.pixelBuffer,
            capturedAt: frame.capturedAt,
            sampleID: frame.sampleID,
            generation: frame.generation,
            regionOfInterest: regionOfInterest
        )
        let output = engine.analyze(engineFrame)
        inferenceResults &+= 1
        let producedAt = clock()
        recordEngineDuration(startedAt: engineStartedAt, endedAt: producedAt)
        guard producedAt.isFinite else {
            return reject(.invalidProducedAt, frame: frame, admissionAt: producedAt)
        }
        guard producedAt >= frame.capturedAt else {
            latestResult = nil
            return reject(.invalidProducedAt, frame: frame, admissionAt: producedAt)
        }
        guard producedAt - frame.capturedAt <= maximumAge else {
            // A result that completed after its TTL can no longer back the
            // overlay or posture state. Purge it now rather than waiting for
            // the expiration timer, which may be delayed behind inference.
            latestResult = nil
            return reject(.postInferenceExpired, frame: frame, admissionAt: producedAt)
        }
        let keepsGeometry = output.state == .detected || output.state == .partial
        let points = keepsGeometry ? output.points.filter(\.isValid) : []
        let contours = keepsGeometry ? output.contours.filter(\.isValid) : []
        let result = UpperBodyResult(
            descriptor: engine.descriptor,
            state: output.state,
            generation: activeGeneration,
            sampleID: frame.sampleID,
            capturedAt: frame.capturedAt,
            producedAt: producedAt,
            points: points,
            contours: contours,
            regionOfInterest: keepsGeometry
                ? (output.regionOfInterest ?? regionOfInterest)
                : nil,
            diagnostics: output.diagnostics
        )
        latestResult = keepsGeometry && !points.isEmpty ? result : nil
        returnedResults &+= 1
        if result.state == .partial { partialResults &+= 1 }
        lastRejection = nil
        return result
    }

    private mutating func partialResult(
        for frame: UpperBodyFrame,
        producedAt: TimeInterval
    ) -> UpperBodyResult {
        latestResult = nil
        returnedResults &+= 1
        partialResults &+= 1
        lastRejection = nil
        return UpperBodyResult(
            descriptor: engine.descriptor,
            state: .partial,
            generation: activeGeneration ?? frame.generation,
            sampleID: frame.sampleID,
            capturedAt: frame.capturedAt,
            producedAt: producedAt,
            points: [],
            contours: [],
            regionOfInterest: nil,
            diagnostics: nil
        )
    }

    @discardableResult
    private mutating func reject(
        _ reason: UpperBodyAdmissionRejectionReason,
        frame: UpperBodyFrame,
        admissionAt: TimeInterval
    ) -> UpperBodyResult? {
        lastRejectionReason = reason
        lastRejection = UpperBodyAdmissionRejection(
            reason: reason,
            activeGeneration: activeGeneration,
            frameGeneration: frame.generation,
            sampleID: frame.sampleID,
            capturedAt: frame.capturedAt,
            admissionAt: admissionAt
        )
        rejectionCounts[reason, default: 0] &+= 1
        return nil
    }

    private mutating func recordEngineDuration(
        startedAt: TimeInterval,
        endedAt: TimeInterval
    ) {
        engineRuns &+= 1
        guard startedAt.isFinite, endedAt.isFinite, endedAt >= startedAt else {
            lastEngineDuration = nil
            return
        }
        let duration = endedAt - startedAt
        lastEngineDuration = duration
        engineDurations.append(duration)
        // Keep diagnostics bounded even if the camera remains active for days.
        if engineDurations.count > 128 { engineDurations.removeFirst() }
    }

    private func percentile(_ fraction: Double) -> TimeInterval? {
        guard !engineDurations.isEmpty else { return nil }
        let sorted = engineDurations.sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int((Double(sorted.count - 1) * fraction).rounded()))
        )
        return sorted[index]
    }

    func expirationDelay(for result: UpperBodyResult, at uptime: TimeInterval) -> TimeInterval? {
        guard uptime.isFinite, result.capturedAt.isFinite,
              result.generation == activeGeneration else { return nil }
        return max(0, result.capturedAt + maximumAge - uptime)
    }

    mutating func expire(at uptime: TimeInterval, generation: UInt64) -> UpperBodyResult? {
        guard generation == activeGeneration,
              let latestResult,
              let age = latestResult.age(at: uptime),
              age >= maximumAge else { return nil }
        self.latestResult = nil
        return UpperBodyResult(
            descriptor: latestResult.descriptor,
            state: .expired,
            generation: latestResult.generation,
            sampleID: latestResult.sampleID,
            capturedAt: latestResult.capturedAt,
            producedAt: uptime,
            points: [],
            contours: [],
            regionOfInterest: nil,
            diagnostics: nil
        )
    }
}
