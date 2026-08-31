import CoreGraphics
import Foundation

/// Étage sérialisé entre les sorties CV et les alertes. Il ne possède ni caméra
/// ni image : une instance est liée à une activation et à une génération.
nonisolated struct PostureRuntimeCoordinator: Sendable {
    static let ruleVersion = "rich-v1"
    private(set) var generation: UInt64 = 0
    private(set) var contextKey = ""
    private var lastFaceSampleID: UInt64 = 0
    private var lastBodySampleID: UInt64 = 0
    private var evaluator: PostureRichSignalEvaluator
    private var observationEngine = PostureObservationEngine()
    private var baselineSamples: [PostureRichGeometryMetrics] = []
    private var baseline: PostureRichBaseline?
    private var lastBaselineBodySampleID: UInt64 = 0
    private var lastBaselineBodyCapturedAt: TimeInterval?
    private var lastPublishedSample: [PostureObservationSignalID: UInt64] = [:]
    private var lastEvaluation: PostureRichEvaluation?
    private var blinkBaselineSamples: [Double] = []
    private var blinkTargetPerMinute: Double?
    private(set) var isCalibrationActive = false
    var baselineSnapshot: PostureRichBaseline? { baseline }

    private static func configuration(for sensitivity: PostureRecommendationSensitivity) -> PostureRichSignalConfiguration {
        switch sensitivity {
        case .sensitive: return .sensitive
        case .balanced: return .balancedSensitive
        case .discreet: return .discreet
        }
    }

    private(set) var sensitivity: PostureRecommendationSensitivity

    init(sensitivity: PostureRecommendationSensitivity = .sensitive) {
        self.sensitivity = sensitivity
        self.evaluator = PostureRichSignalEvaluator(configuration: Self.configuration(for: sensitivity))
    }

    mutating func setSensitivity(_ value: PostureRecommendationSensitivity) {
        guard value != sensitivity else { return }
        sensitivity = value
        var configuration = Self.configuration(for: value)
        configuration.blinkTargetPerMinute = blinkTargetPerMinute
        evaluator = PostureRichSignalEvaluator(configuration: configuration)
    }

    mutating func beginCalibration() {
        isCalibrationActive = true
        baselineSamples.removeAll(keepingCapacity: true)
        baseline = nil
        lastBaselineBodySampleID = lastBodySampleID
        lastBaselineBodyCapturedAt = nil
        blinkBaselineSamples.removeAll(keepingCapacity: true)
        blinkTargetPerMinute = nil
        evaluator = PostureRichSignalEvaluator(configuration: Self.configuration(for: sensitivity))
        evaluator.reset()
    }

    mutating func finishCalibration() -> Bool {
        isCalibrationActive = false
        return baseline != nil
    }

    mutating func restoreBaseline(_ value: PostureRichBaseline, for generation: UInt64, contextKey: String) {
        guard value.contextKey == contextKey, value.ruleVersion == Self.ruleVersion,
              value.sampleCount >= 12 else { return }
        baseline = .init(generation: generation, contextKey: contextKey,
                         ruleVersion: value.ruleVersion,
                         torsoInclinationDegrees: value.torsoInclinationDegrees,
                         torsoAxisDeviation: value.torsoAxisDeviation,
                         shoulderSlopeDegrees: value.shoulderSlopeDegrees,
                         shoulderOpeningRatio: value.shoulderOpeningRatio,
                         leftShoulderElevation: value.leftShoulderElevation,
                         rightShoulderElevation: value.rightShoulderElevation,
                         proximityScale: value.proximityScale, sampleCount: value.sampleCount,
                         torsoInclinationMAD: value.torsoInclinationMAD,
                         torsoAxisMAD: value.torsoAxisMAD,
                         shoulderSlopeMAD: value.shoulderSlopeMAD)
        lastBaselineBodySampleID = 0
        lastBaselineBodyCapturedAt = nil
    }

    mutating func reset(generation: UInt64, contextKey: String, preserveCalibration: Bool = false) {
        let requestedCalibration = preserveCalibration && isCalibrationActive
        self.generation = generation
        isCalibrationActive = requestedCalibration
        self.contextKey = contextKey
        lastFaceSampleID = 0
        lastBodySampleID = 0
        lastPublishedSample.removeAll(keepingCapacity: true)
        lastEvaluation = nil
        blinkBaselineSamples.removeAll(keepingCapacity: true)
        blinkTargetPerMinute = nil
        var configuration = Self.configuration(for: sensitivity)
        configuration.blinkTargetPerMinute = blinkTargetPerMinute
        evaluator = PostureRichSignalEvaluator(configuration: configuration)
        evaluator.reset()
        observationEngine = PostureObservationEngine()
        _ = observationEngine.reset(generation: generation, at: 0)
        baselineSamples.removeAll(keepingCapacity: true)
        baseline = nil
        lastBaselineBodySampleID = 0
        lastBaselineBodyCapturedAt = nil
    }

    mutating func consume(
        geometry: PostureRichGeometryMetrics?,
        face: PostureFaceObservation?,
        baseline externalBaseline: PostureRichBaseline?,
        now: TimeInterval
    ) -> (evaluation: PostureRichEvaluation, snapshot: PostureObservationsSnapshot)? {
        guard now.isFinite else { return nil }
        let incomingGeneration = geometry?.generation ?? face?.generation ?? 0
        let incomingContext = geometry?.contextKey ?? face?.contextKey ?? ""
        guard incomingGeneration == generation, incomingContext == contextKey else { return nil }
        // A body sample and a face sample from different stable camera
        // contexts must never be fused (nor used to advance a shared
        // baseline). The caller resets the coordinator when the new context
        // becomes authoritative.
        if let geometry, let face, geometry.contextKey != face.contextKey {
            return nil
        }
        let bodySample = geometry?.sampleID ?? 0
        let faceSample = face?.sampleID ?? 0
        guard bodySample > lastBodySampleID || faceSample > lastFaceSampleID else { return nil }
        let isNewBodySample = geometry.map { $0.sampleID > lastBodySampleID } ?? false
        let isNewFaceSample = face.map { $0.sampleID > lastFaceSampleID } ?? false
        collectCalibrationSample(geometry)
        let candidateBaseline = self.baseline ?? externalBaseline
        let usableBaseline = candidateBaseline.flatMap {
            $0.generation == generation && $0.contextKey == contextKey &&
                $0.ruleVersion == Self.ruleVersion ? $0 : nil
        }
        // Face ticks may reuse the latest body result at 10 Hz. They must not
        // advance body temporal machines a second time; only a new body sample
        // is admitted to the rich evaluator.
        let rawEvaluation = evaluator.consume(
            geometry: isNewBodySample ? geometry : nil,
            face: face,
            baseline: usableBaseline,
            now: now
        )
        if blinkTargetPerMinute == nil,
           let rate = rawEvaluation.blinkRate.value,
           rate.isFinite, rate > 0,
           rawEvaluation.blinkRate.state == .available {
            blinkBaselineSamples.append(rate)
            if blinkBaselineSamples.count >= 12 {
                let sorted = blinkBaselineSamples.sorted()
                blinkTargetPerMinute = sorted[sorted.count / 2]
                evaluator.setBlinkTarget(blinkTargetPerMinute)
            }
        }
        let evaluation: PostureRichEvaluation
        if isNewBodySample || lastEvaluation == nil {
            evaluation = rawEvaluation
        } else if let previous = lastEvaluation {
            // A 10 Hz face tick updates only face-derived scalars. Preserve
            // the latest body sample for the canonical snapshot instead of
            // replacing it with an artificial body-unavailable value.
            evaluation = PostureRichEvaluation(
                torsoInclination: previous.torsoInclination,
                shoulderSlope: previous.shoulderSlope,
                shoulderOpening: previous.shoulderOpening,
                shouldersRaised: previous.shouldersRaised,
                proximity: rawEvaluation.proximity,
                blinkRate: rawEvaluation.blinkRate,
                blinkEvent: rawEvaluation.blinkEvent,
                blinkRateAssessment: rawEvaluation.blinkRateAssessment
            )
        } else {
            evaluation = rawEvaluation
        }
        lastEvaluation = evaluation
        if let geometry, isNewBodySample { lastBodySampleID = max(lastBodySampleID, geometry.sampleID) }
        if let face { lastFaceSampleID = max(lastFaceSampleID, face.sampleID) }
        let canonical = observationEngine.ingest(
            rich: evaluation, contextKey: contextKey, now: now,
            calibration: usableBaseline == nil ? .missing : .valid,
            signalIDs: Set(
                (isNewBodySample ? Array(PostureObservationEngine.bodySignalIDs) : []) +
                (isNewFaceSample ? Array(PostureObservationEngine.faceSignalIDs) : [])
            )
        )
        return (evaluation, canonical)
    }

    /// Ingestion explicite d'un échantillon visage. Elle ne réavance jamais
    /// les machines corporelles : le moteur riche conserve son dernier corps
    /// frais jusqu'à son TTL borné.
    mutating func consumeFace(
        _ face: PostureFaceObservation,
        baseline externalBaseline: PostureRichBaseline? = nil,
        now: TimeInterval
    ) -> (evaluation: PostureRichEvaluation, snapshot: PostureObservationsSnapshot)? {
        guard now.isFinite, face.generation == generation,
              face.contextKey == contextKey,
              face.sampleID > lastFaceSampleID,
              face.capturedAt.isFinite, now >= face.capturedAt else { return nil }
        let usableBaseline = (baseline ?? self.baseline).flatMap {
            $0.generation == generation && $0.contextKey == face.contextKey &&
                $0.ruleVersion == Self.ruleVersion ? $0 : nil
        }
        let evaluation = evaluator.consumeFace(face: face, baseline: usableBaseline, now: now)
        lastFaceSampleID = face.sampleID
        let canonical = observationEngine.ingest(
            rich: evaluation, contextKey: face.contextKey, now: now,
            calibration: usableBaseline == nil ? .missing : .valid,
            signalIDs: PostureObservationEngine.faceSignalIDs
        )
        lastEvaluation = evaluation
        return (evaluation, canonical)
    }

    /// Ingestion explicite d'un échantillon corps. Les métriques visage ne
    /// progressent pas artificiellement sur ce chemin.
    mutating func consumeBody(
        _ geometry: PostureRichGeometryMetrics,
        baseline externalBaseline: PostureRichBaseline? = nil,
        now: TimeInterval
    ) -> (evaluation: PostureRichEvaluation, snapshot: PostureObservationsSnapshot)? {
        guard now.isFinite, geometry.generation == generation,
              geometry.contextKey == contextKey,
              geometry.sampleID > lastBodySampleID,
              geometry.capturedAt.isFinite, now >= geometry.capturedAt else { return nil }
        collectCalibrationSample(geometry)
        let usableBaseline = (baseline ?? self.baseline).flatMap {
            $0.generation == generation && $0.contextKey == geometry.contextKey &&
                $0.ruleVersion == Self.ruleVersion ? $0 : nil
        }
        let evaluation = evaluator.consumeBody(geometry: geometry, baseline: usableBaseline, now: now)
        lastBodySampleID = geometry.sampleID
        let canonical = observationEngine.ingest(
            rich: evaluation, contextKey: geometry.contextKey, now: now,
            calibration: usableBaseline == nil ? .missing : .valid,
            signalIDs: PostureObservationEngine.bodySignalIDs
        )
        lastEvaluation = evaluation
        return (evaluation, canonical)
    }

    private mutating func collectCalibrationSample(_ geometry: PostureRichGeometryMetrics?) {
        guard isCalibrationActive, let geometry,
              geometry.contextKey == contextKey,
              geometry.sampleID > lastBaselineBodySampleID,
              lastBaselineBodyCapturedAt.map({ geometry.capturedAt > $0 }) ?? true else { return }
        lastBaselineBodySampleID = geometry.sampleID
        lastBaselineBodyCapturedAt = geometry.capturedAt
        baselineSamples.append(geometry)
        if baselineSamples.count > 32 { baselineSamples.removeFirst() }
        if baseline == nil {
            baseline = PostureRichBaselineBuilder.make(
                samples: baselineSamples, generation: generation,
                contextKey: contextKey, ruleVersion: Self.ruleVersion,
                minimumSamples: 12
            )
        }
    }

    mutating func expire(now: TimeInterval) -> PostureObservationsSnapshot {
        observationEngine.expire(at: now, generation: generation)
    }

    /// Invalide uniquement la source corps. Les preuves visage, le compteur de
    /// clignements et leur épisode restent indépendants.
    mutating func invalidateBody(
        at now: TimeInterval,
        reason: String = "corps indisponible"
    ) -> (evaluation: PostureRichEvaluation, snapshot: PostureObservationsSnapshot)? {
        guard generation > 0, !contextKey.isEmpty, now.isFinite else { return nil }
        let sampleID = lastBodySampleID &+ 1
        let evaluation = evaluator.invalidateBody(
            generation: generation,
            contextKey: contextKey,
            sampleID: sampleID,
            capturedAt: now,
            now: now,
            reason: reason
        )
        lastBodySampleID = sampleID
        lastEvaluation = evaluation
        let canonical = observationEngine.ingest(
            rich: evaluation,
            contextKey: contextKey,
            now: now,
            calibration: baseline == nil ? .missing : .valid,
            signalIDs: PostureObservationEngine.bodySignalIDs
        )
        return (evaluation, canonical)
    }

    /// Marque un tick visage non fiable sans effacer le dernier corps frais.
    mutating func invalidateFace(
        sampleID: UInt64,
        capturedAt: TimeInterval,
        now: TimeInterval
    ) -> PostureObservationsSnapshot {
        guard generation > 0, !contextKey.isEmpty, sampleID > lastFaceSampleID,
              capturedAt.isFinite, now.isFinite, now >= capturedAt else {
            return observationEngine.snapshot
        }
        evaluator.invalidateFace(
            generation: generation,
            sampleID: sampleID,
            capturedAt: capturedAt
        )
        lastFaceSampleID = sampleID
        return observationEngine.invalidate(
            PostureObservationEngine.faceSignalIDs,
            at: now,
            generation: generation,
            faceEvidenceObservedAt: capturedAt
        )
    }

    /// Invalide immédiatement les observations visibles après une perte ou
    /// une erreur moteur, sans réutiliser une ancienne géométrie. Le repère
    /// calibré reste conservé pour la prochaine observation valide.
    mutating func invalidate(at now: TimeInterval) -> PostureObservationsSnapshot {
        evaluator.reset()
        observationEngine = PostureObservationEngine()
        lastEvaluation = nil
        lastFaceSampleID = 0
        lastBodySampleID = 0
        lastPublishedSample.removeAll(keepingCapacity: true)
        return observationEngine.reset(generation: generation, at: now)
    }
}
