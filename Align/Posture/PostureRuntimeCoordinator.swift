import CoreGraphics
import Foundation

/// Étage sérialisé entre les sorties CV et les alertes. Il ne possède ni caméra
/// ni image : une instance est liée à une activation et à une génération.
nonisolated struct PostureRuntimeCoordinator: Sendable {
    // La pente des épaules est désormais filtrée et soumise à une qualité de
    // cadrage dédiée : une baseline v2 ne doit pas être comparée à ce nouveau
    // signal sans recalibration.
    static let ruleVersion = "rich-v3"
    private(set) var generation: UInt64 = 0
    private(set) var contextKey = ""
    private var lastFaceSampleID: UInt64 = 0
    private var lastHandFaceSampleID: UInt64 = 0
    private var lastBodySampleID: UInt64 = 0
    private var evaluator: PostureRichSignalEvaluator
    private var observationEngine = PostureObservationEngine()
    private var baselineSamples: [PostureRichGeometryMetrics] = []
    private var baselineFaceSamples: [PostureFaceObservation] = []
    private var baseline: PostureRichBaseline?
    private var lastBaselineBodySampleID: UInt64 = 0
    private var lastBaselineBodyCapturedAt: TimeInterval?
    private var lastBaselineFaceSampleID: UInt64 = 0
    private var lastBaselineFaceCapturedAt: TimeInterval?
    private var lastPublishedSample: [PostureObservationSignalID: UInt64] = [:]
    private var lastEvaluation: PostureRichEvaluation?
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

    /// Cible explicitement fournie par l'intégrateur. Une cible personnelle
    /// ne doit jamais être déduite d'un premier débit observé : en l'absence
    /// de cette valeur, l'évaluateur attend ses fenêtres indépendantes.
    mutating func setBlinkTarget(_ target: Double?) {
        guard target == nil || (target?.isFinite == true && target! > 0) else { return }
        blinkTargetPerMinute = target
        evaluator.setBlinkTarget(target)
    }

    mutating func beginCalibration() {
        isCalibrationActive = true
        baselineSamples.removeAll(keepingCapacity: true)
        baselineFaceSamples.removeAll(keepingCapacity: true)
        baseline = nil
        lastBaselineBodySampleID = lastBodySampleID
        lastBaselineBodyCapturedAt = nil
        lastBaselineFaceSampleID = lastFaceSampleID
        lastBaselineFaceCapturedAt = nil
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
                         shoulderSlopeMAD: value.shoulderSlopeMAD,
                         blinkOpeningBaseline: value.blinkOpeningBaseline,
                         familySampleCounts: value.familySampleCounts,
                         headTiltDegrees: value.headTiltDegrees,
                         headTiltMAD: value.headTiltMAD)
        lastBaselineBodySampleID = 0
        lastBaselineBodyCapturedAt = nil
    }

    mutating func reset(generation: UInt64, contextKey: String, preserveCalibration: Bool = false) {
        let requestedCalibration = preserveCalibration && isCalibrationActive
        self.generation = generation
        isCalibrationActive = requestedCalibration
        self.contextKey = contextKey
        lastFaceSampleID = 0
        lastHandFaceSampleID = 0
        lastBodySampleID = 0
        lastPublishedSample.removeAll(keepingCapacity: true)
        lastEvaluation = nil
        blinkTargetPerMinute = nil
        var configuration = Self.configuration(for: sensitivity)
        configuration.blinkTargetPerMinute = blinkTargetPerMinute
        evaluator = PostureRichSignalEvaluator(configuration: configuration)
        evaluator.reset()
        observationEngine = PostureObservationEngine()
        _ = observationEngine.reset(generation: generation, at: 0)
        baselineSamples.removeAll(keepingCapacity: true)
        baselineFaceSamples.removeAll(keepingCapacity: true)
        baseline = nil
        lastBaselineBodySampleID = 0
        lastBaselineBodyCapturedAt = nil
        lastBaselineFaceSampleID = 0
        lastBaselineFaceCapturedAt = nil
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
        collectCalibrationFaceSample(face)
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
                headTilt: previous.headTilt,
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
        collectCalibrationFaceSample(face)
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

    /// Ingestion séparée de la proximité main–visage. La géométrie arrive
    /// depuis la même frame Vision que le visage, mais sa décision temporelle
    /// reste indépendante des métriques de posture et de leur baseline.
    mutating func consumeHandFace(
        _ sample: HandFaceContactSample,
        now: TimeInterval
    ) -> PostureObservationsSnapshot? {
        let ttl = PostureObservationEngine.freshnessTTL(for: .handOnFace)
        guard now.isFinite, sample.hasValidIdentity,
              sample.generation == generation,
              sample.contextKey == contextKey,
              sample.sampleID > lastHandFaceSampleID,
              sample.capturedAt <= now,
              now - sample.capturedAt <= ttl else { return nil }

        let quality: PostureObservationQuality = switch sample.observation.quality {
        case .good: .good
        case .limited: .limited
        case .unavailable: .unavailable
        }
        let isGood = quality == .good
        let evidence = PostureMetricEvidence(
            signalID: .handOnFace,
            generation: sample.generation,
            sampleID: sample.sampleID,
            capturedAt: sample.capturedAt,
            producedAt: now,
            // Keep the measured distance so the observation engine can apply
            // its enter/exit hysteresis. A binary hint would bypass the wider
            // exit threshold and make the rail flicker near the face.
            normalizedValue: isGood ? sample.observation.distanceRatio : nil,
            quality: quality,
            calibration: .valid,
            cameraContextID: sample.contextKey,
            framingSignature: sample.contextKey,
            assessmentHint: nil,
            numericValue: sample.observation.distanceRatio,
            observationReason: isGood ? nil : "Main ou visage insuffisant"
        )
        lastHandFaceSampleID = sample.sampleID
        return observationEngine.ingest(evidence, now: now)
    }

    /// Ingestion explicite d'un échantillon corps. Les métriques visage ne
    /// progressent pas artificiellement sur ce chemin.
    mutating func consumeBody(
        _ geometry: PostureRichGeometryMetrics,
        pairedFace: PostureFaceObservation? = nil,
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
        let evaluation = evaluator.consumeBody(
            geometry: geometry, pairedFace: pairedFace,
            baseline: usableBaseline, now: now
        )
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
        rebuildCalibrationBaseline()
    }

    private mutating func collectCalibrationFaceSample(_ face: PostureFaceObservation?) {
        guard isCalibrationActive, let face,
              face.contextKey == contextKey,
              face.sampleID > lastBaselineFaceSampleID,
              face.capturedAt.isFinite,
              lastBaselineFaceCapturedAt.map({ face.capturedAt > $0 }) ?? true else { return }
        lastBaselineFaceSampleID = face.sampleID
        lastBaselineFaceCapturedAt = face.capturedAt
        baselineFaceSamples.append(face)
        // Les corps arrivent à ~2 Hz alors que le visage arrive à ~10 Hz :
        // douze corps cohérents couvrent plus de cinq secondes. Conserver
        // 128 ticks visage permet encore d'apparier toute cette fenêtre.
        if baselineFaceSamples.count > 128 { baselineFaceSamples.removeFirst() }
        rebuildCalibrationBaseline()
    }

    private mutating func rebuildCalibrationBaseline() {
        guard isCalibrationActive else { return }
        baseline = PostureRichBaselineBuilder.make(
            samples: baselineSamples,
            faceSamples: baselineFaceSamples,
            generation: generation,
            contextKey: contextKey,
            ruleVersion: Self.ruleVersion,
            minimumSamples: 12,
            minimumFacePoints: evaluator.configuration.minimumFacePoints,
            maximumProximityYaw: evaluator.configuration.maximumProximityYaw,
            maximumRollDegrees: evaluator.configuration.maximumRollDegrees,
            maximumFusionSkew: evaluator.configuration.maximumFusionSkew
        )
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
        now: TimeInterval,
        reason: String = "Visage momentanément indisponible"
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
            PostureObservationEngine.faceSignalIDs.union([.headTilt]),
            at: now,
            generation: generation,
            faceEvidenceObservedAt: capturedAt,
            reason: reason
        )
    }

    /// Réarme les états transitoires après une réacquisition confirmée. Le
    /// repère personnel de clignements et sa fenêtre glissante restent valides
    /// dans le même contexte caméra ; seule une calibration explicite ou un
    /// changement de génération/contexte les efface.
    mutating func resetFaceTarget(at now: TimeInterval) -> PostureObservationsSnapshot {
        guard generation > 0, now.isFinite else { return observationEngine.snapshot }
        evaluator.resetFaceTarget()
        lastEvaluation = nil
        return observationEngine.invalidate(
            PostureObservationEngine.faceSignalIDs.union([.headTilt]),
            at: now,
            generation: generation,
            faceEvidenceObservedAt: now,
            reason: "Visage en cours de réacquisition"
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
        lastHandFaceSampleID = 0
        lastBodySampleID = 0
        lastPublishedSample.removeAll(keepingCapacity: true)
        return observationEngine.reset(generation: generation, at: now)
    }
}
