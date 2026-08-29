import Foundation

nonisolated private func benchmarkScalarReport(_ aggregate: ScalarAggregate) -> String {
    guard let average = aggregate.average,
          let minimum = aggregate.minimum,
          let maximum = aggregate.maximum,
          let dispersion = aggregate.standardDeviation else {
        return "n=0, moy=—, min=—, max=—, écart-type=—"
    }
    return String(
        format: "n=%d, moy=%+.3f, min=%+.3f, max=%+.3f, écart-type=%.3f",
        aggregate.count,
        average,
        minimum,
        maximum,
        dispersion
    )
}

nonisolated struct BenchmarkPhase: Equatable, Sendable {
    enum Expectation: Equatable, Sendable {
        case faceVisible
        case faceAbsent
        case recovery

        var reportLabel: String {
            switch self {
            case .faceVisible: "visage attendu"
            case .faceAbsent: "visage absent attendu"
            case .recovery: "récupération attendue"
            }
        }
    }

    let instruction: String
    let duration: TimeInterval
    let expectation: Expectation

    static let guided: [BenchmarkPhase] = [
        BenchmarkPhase(instruction: "Position neutre", duration: 10, expectation: .faceVisible),
        BenchmarkPhase(instruction: "Tourne la tête à gauche", duration: 5, expectation: .faceVisible),
        BenchmarkPhase(instruction: "Tourne la tête à droite", duration: 5, expectation: .faceVisible),
        BenchmarkPhase(instruction: "Regarde vers le haut", duration: 5, expectation: .faceVisible),
        BenchmarkPhase(instruction: "Regarde vers le bas", duration: 5, expectation: .faceVisible),
        BenchmarkPhase(instruction: "Rapproche ton visage de l’écran", duration: 5, expectation: .faceVisible),
        BenchmarkPhase(instruction: "Éloigne le visage de l’écran", duration: 5, expectation: .faceVisible),
        BenchmarkPhase(instruction: "Sans bouger la tête, incline légèrement l’écran vers toi", duration: 5, expectation: .faceVisible),
        BenchmarkPhase(instruction: "Sans bouger la tête, éloigne légèrement l’écran de toi", duration: 5, expectation: .faceVisible),
        BenchmarkPhase(instruction: "Masque le visage", duration: 5, expectation: .faceAbsent),
        BenchmarkPhase(instruction: "Découvre le visage et reste neutre", duration: 5, expectation: .recovery)
    ]
}

nonisolated struct BenchmarkMeasurement: Sendable {
    let faceAttempted: Bool
    let faceDuration: TimeInterval
    let faceSucceeded: Bool
    let faceHadLandmarks: Bool
    let faceOrientation: FaceOrientationSignal?
    let faceGeometry: FaceGeometrySignal?
    let bodyDuration: TimeInterval?
    let bodyAttempted: Bool
    let bodySucceeded: Bool
    let overlayVisible: Bool
    let faceVisible: Bool
    let bodyVisible: Bool
    let silhouetteVisible: Bool
    let segmentationAttempted: Bool
    let segmentationVisionPerformed: Bool
    let segmentationResult: Bool
    let segmentationContourValid: Bool
    let segmentationInsufficient: Bool
    let segmentationError: Bool
    let segmentationDuration: TimeInterval?

    init(
        faceAttempted: Bool = true,
        faceDuration: TimeInterval,
        faceSucceeded: Bool,
        faceHadLandmarks: Bool,
        faceOrientation: FaceOrientationSignal?,
        faceGeometry: FaceGeometrySignal? = nil,
        bodyDuration: TimeInterval?,
        bodyAttempted: Bool = false,
        bodySucceeded: Bool,
        overlayVisible: Bool,
        faceVisible: Bool = false,
        bodyVisible: Bool = false,
        silhouetteVisible: Bool = false,
        segmentationAttempted: Bool = false,
        segmentationVisionPerformed: Bool = false,
        segmentationResult: Bool = false,
        segmentationContourValid: Bool = false,
        segmentationInsufficient: Bool = false,
        segmentationError: Bool = false,
        segmentationDuration: TimeInterval? = nil
    ) {
        self.faceAttempted = faceAttempted
        self.faceDuration = faceDuration
        self.faceSucceeded = faceSucceeded
        self.faceHadLandmarks = faceHadLandmarks
        self.faceOrientation = faceOrientation
        self.faceGeometry = faceGeometry
        self.bodyDuration = bodyDuration
        self.bodyAttempted = bodyAttempted
        self.bodySucceeded = bodySucceeded
        self.overlayVisible = overlayVisible
        self.faceVisible = faceVisible
        self.bodyVisible = bodyVisible
        self.silhouetteVisible = silhouetteVisible
        self.segmentationAttempted = segmentationAttempted
        self.segmentationVisionPerformed = segmentationVisionPerformed
        self.segmentationResult = segmentationResult
        self.segmentationContourValid = segmentationContourValid
        self.segmentationInsufficient = segmentationInsufficient
        self.segmentationError = segmentationError
        self.segmentationDuration = segmentationDuration
    }
}

/// Agrégat en mémoire d'une mesure géométrique sans unité imposée.
nonisolated struct ScalarAggregate: Sendable, Equatable {
    private(set) var count = 0
    private(set) var total: Double = 0
    private(set) var minimum: Double?
    private(set) var maximum: Double?
    private var sumOfSquares: Double = 0

    var average: Double? {
        guard count > 0 else { return nil }
        return total / Double(count)
    }

    var standardDeviation: Double? {
        guard count > 0, let average else { return nil }
        let variance = max(0, sumOfSquares / Double(count) - average * average)
        return variance.squareRoot()
    }

    mutating func record(_ value: Double?) {
        guard let value, value.isFinite else { return }
        count += 1
        total += value
        sumOfSquares += value * value
        minimum = minimum.map { min($0, value) } ?? value
        maximum = maximum.map { max($0, value) } ?? value
    }
}

nonisolated struct BenchmarkProgress: Sendable {
    let instruction: String
    let phaseIndex: Int
    let phaseCount: Int
    let phaseProgress: Double
    let totalProgress: Double
}

nonisolated struct DurationAggregate: Sendable {
    private(set) var count = 0
    private(set) var total: TimeInterval = 0
    private(set) var maximum: TimeInterval = 0
    private var values: [TimeInterval] = []

    var average: TimeInterval { count == 0 ? 0 : total / Double(count) }

    var p50: TimeInterval? { percentile(0.50) }
    var p95: TimeInterval? { percentile(0.95) }

    mutating func record(_ duration: TimeInterval) {
        count += 1
        total += duration
        maximum = max(maximum, duration)
        values.append(duration)
    }

    private func percentile(_ quantile: Double) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(ceil(quantile * Double(sorted.count))) - 1))
        return sorted[index]
    }
}

/// Agrégat en mémoire d'un angle facial exprimé en degrés.
nonisolated struct AngleAggregate: Sendable, Equatable {
    private(set) var count = 0
    private(set) var total: Double = 0
    private(set) var minimum: Double?
    private(set) var maximum: Double?
    private var sumOfSquares: Double = 0

    var average: Double? {
        guard count > 0 else { return nil }
        return total / Double(count)
    }

    /// Dispersion simple : écart-type de population des échantillons présents.
    var standardDeviation: Double? {
        guard count > 0, let average else { return nil }
        let variance = max(0, sumOfSquares / Double(count) - average * average)
        return variance.squareRoot()
    }

    mutating func record(_ value: Double?) {
        guard let value, value.isFinite else { return }
        count += 1
        total += value
        sumOfSquares += value * value
        minimum = minimum.map { min($0, value) } ?? value
        maximum = maximum.map { max($0, value) } ?? value
    }
}

nonisolated struct BenchmarkMetrics: Sendable {
    private(set) var faceDurations = DurationAggregate()
    private(set) var bodyDurations = DurationAggregate()
    private(set) var faceAttempts = 0
    private(set) var faceSuccesses = 0
    private(set) var facesWithLandmarks = 0
    private(set) var faceVisibleSamples = 0
    private(set) var bodyAttempts = 0
    private(set) var bodySuccesses = 0
    private(set) var bodyVisibleSamples = 0
    private(set) var silhouetteVisibleSamples = 0
    private(set) var overlayDropouts = 0
    private(set) var longestInterruption: TimeInterval = 0
    private(set) var recoveryDurations = DurationAggregate()
    private(set) var geometryEyeLineRoll = ScalarAggregate()
    private(set) var geometryYawProxy = ScalarAggregate()
    private(set) var geometryPitchProxy = ScalarAggregate()
    private(set) var geometryInterocularDistance = ScalarAggregate()
    private(set) var geometryFaceLength = ScalarAggregate()
    private(set) var segmentationAttempts = 0
    private(set) var segmentationVisionPerforms = 0
    private(set) var segmentationResults = 0
    private(set) var segmentationContoursValid = 0
    private(set) var segmentationInsufficient = 0
    private(set) var segmentationErrors = 0
    private(set) var segmentationDurations = DurationAggregate()
    private var interruptionStart: TimeInterval?
    private var hasSeenOverlay = false

    mutating func record(_ measurement: BenchmarkMeasurement) {
        if measurement.faceAttempted {
            faceAttempts += 1
            faceDurations.record(measurement.faceDuration)
            if measurement.faceSucceeded { faceSuccesses += 1 }
            if measurement.faceHadLandmarks { facesWithLandmarks += 1 }
            geometryEyeLineRoll.record(measurement.faceGeometry?.eyeLineRollDegrees)
            geometryYawProxy.record(measurement.faceGeometry?.yawProxy)
            geometryPitchProxy.record(measurement.faceGeometry?.pitchProxy)
            geometryInterocularDistance.record(measurement.faceGeometry?.interocularDistance)
            geometryFaceLength.record(measurement.faceGeometry?.faceLength)
        }
        if measurement.faceVisible { faceVisibleSamples += 1 }
        if measurement.bodyVisible { bodyVisibleSamples += 1 }
        if measurement.silhouetteVisible { silhouetteVisibleSamples += 1 }
        if measurement.segmentationAttempted { segmentationAttempts += 1 }
        if measurement.segmentationVisionPerformed { segmentationVisionPerforms += 1 }
        if measurement.segmentationResult { segmentationResults += 1 }
        if measurement.segmentationContourValid { segmentationContoursValid += 1 }
        if measurement.segmentationInsufficient { segmentationInsufficient += 1 }
        if measurement.segmentationError { segmentationErrors += 1 }
        if let duration = measurement.segmentationDuration { segmentationDurations.record(duration) }

        if measurement.bodyAttempted, let bodyDuration = measurement.bodyDuration {
            bodyAttempts += 1
            bodyDurations.record(bodyDuration)
            if measurement.bodySucceeded { bodySuccesses += 1 }
        }

    }

    mutating func recordOverlay(visible: Bool, at uptime: TimeInterval) {
        if visible {
            hasSeenOverlay = true
            if let interruptionStart {
                let duration = uptime - interruptionStart
                longestInterruption = max(longestInterruption, duration)
                recoveryDurations.record(duration)
                self.interruptionStart = nil
            }
        } else if hasSeenOverlay, interruptionStart == nil {
            overlayDropouts += 1
            interruptionStart = uptime
        }
    }

    mutating func finish(at uptime: TimeInterval) {
        if let interruptionStart {
            longestInterruption = max(longestInterruption, uptime - interruptionStart)
        }
    }

    var report: String {
        func milliseconds(_ value: TimeInterval?) -> String {
            value.map { String(format: "%.1f ms", $0 * 1_000) } ?? "—"
        }
        func rate(_ successes: Int, _ attempts: Int) -> String {
            attempts == 0 ? "—" : String(format: "%.1f %%", Double(successes) / Double(attempts) * 100)
        }

        return [
            "Benchmark Vision Align",
            "Visage : \(faceAttempts) tentatives, \(faceSuccesses) succès (\(rate(faceSuccesses, faceAttempts))), \(facesWithLandmarks) avec landmarks, visibilité fusionnée \(faceVisibleSamples)",
            "Durée visage : moyenne \(milliseconds(faceDurations.average)), max \(milliseconds(faceDurations.maximum))",
            "Corps : \(bodyAttempts) tentatives, \(bodySuccesses) succès (\(rate(bodySuccesses, bodyAttempts))), visibilité fusionnée \(bodyVisibleSamples)",
            "Durée corps : moyenne \(milliseconds(bodyDurations.average)), max \(milliseconds(bodyDurations.maximum))",
            "Overlay : \(overlayDropouts) pertes, interruption max \(String(format: "%.2f s", longestInterruption)), récupération moyenne \(String(format: "%.2f s", recoveryDurations.average))",
            "Géométrie globale : eye-roll \(benchmarkScalarReport(geometryEyeLineRoll)), yaw-proxy \(benchmarkScalarReport(geometryYawProxy)), pitch-proxy \(benchmarkScalarReport(geometryPitchProxy)), interoculaire \(benchmarkScalarReport(geometryInterocularDistance)), longueur \(benchmarkScalarReport(geometryFaceLength))",
            "Silhouette : cadence \(segmentationAttempts), performs \(segmentationVisionPerforms), résultats \(segmentationResults), contours valides \(segmentationContoursValid), insuffisant \(segmentationInsufficient), erreurs \(segmentationErrors), visibilité fusionnée \(silhouetteVisibleSamples), durée p50/p95/max \(milliseconds(segmentationDurations.p50)) / \(milliseconds(segmentationDurations.p95)) / \(milliseconds(segmentationDurations.count == 0 ? nil : segmentationDurations.maximum))",
            "CPU/RSS : à mesurer séparément via CLI"
        ].joined(separator: "\n")
    }
}

nonisolated struct BenchmarkPhaseMetrics: Sendable {
    private(set) var attempts = 0
    private(set) var samples = 0
    private(set) var facesWithLandmarks = 0
    private(set) var visibleOverlays = 0
    private(set) var faceVisibleSamples = 0
    private(set) var bodyVisibleSamples = 0
    private(set) var silhouetteVisibleSamples = 0
    private(set) var roll = AngleAggregate()
    private(set) var yaw = AngleAggregate()
    private(set) var pitch = AngleAggregate()
    private(set) var eyeLineRoll = ScalarAggregate()
    private(set) var yawProxy = ScalarAggregate()
    private(set) var pitchProxy = ScalarAggregate()
    private(set) var interocularDistance = ScalarAggregate()
    private(set) var faceLength = ScalarAggregate()

    mutating func record(_ measurement: BenchmarkMeasurement) {
        samples += 1
        if measurement.faceAttempted {
            attempts += 1
            if measurement.faceHadLandmarks { facesWithLandmarks += 1 }
        }
        if measurement.overlayVisible { visibleOverlays += 1 }
        if measurement.faceVisible { faceVisibleSamples += 1 }
        if measurement.bodyVisible { bodyVisibleSamples += 1 }
        if measurement.silhouetteVisible { silhouetteVisibleSamples += 1 }
        if measurement.faceAttempted {
            roll.record(measurement.faceOrientation?.rollDegrees)
            yaw.record(measurement.faceOrientation?.yawDegrees)
            pitch.record(measurement.faceOrientation?.pitchDegrees)
            eyeLineRoll.record(measurement.faceGeometry?.eyeLineRollDegrees)
            yawProxy.record(measurement.faceGeometry?.yawProxy)
            pitchProxy.record(measurement.faceGeometry?.pitchProxy)
            interocularDistance.record(measurement.faceGeometry?.interocularDistance)
            faceLength.record(measurement.faceGeometry?.faceLength)
        }
    }

    func report(for phase: BenchmarkPhase, index: Int) -> String {
        func rate(_ successes: Int, denominator: Int) -> String {
            denominator == 0 ? "—" : String(format: "%.1f %%", Double(successes) / Double(denominator) * 100)
        }

        let conforming: Int
        switch phase.expectation {
        case .faceVisible, .recovery:
            conforming = facesWithLandmarks
        case .faceAbsent:
            conforming = attempts - facesWithLandmarks
        }

        return [
            "Étape \(index + 1) · \(phase.instruction) : \(phase.expectation.reportLabel), conformité \(rate(conforming, denominator: attempts)), fusion visible \(rate(visibleOverlays, denominator: samples)), visage/corps/silhouette \(faceVisibleSamples)/\(bodyVisibleSamples)/\(silhouetteVisibleSamples) sur \(samples) mesures",
            "  Orientation (degrés) : roll \(angleReport(roll)), yaw \(angleReport(yaw)), pitch \(angleReport(pitch))",
            "  Géométrie (repères normalisés) : eye-roll \(benchmarkScalarReport(eyeLineRoll)), yaw-proxy \(benchmarkScalarReport(yawProxy)), pitch-proxy \(benchmarkScalarReport(pitchProxy))",
            "  Échelles : interoculaire \(benchmarkScalarReport(interocularDistance)), longueur faciale \(benchmarkScalarReport(faceLength))"
        ].joined(separator: "\n")
    }

    private func angleReport(_ aggregate: AngleAggregate) -> String {
        guard let average = aggregate.average,
              let minimum = aggregate.minimum,
              let maximum = aggregate.maximum,
              let dispersion = aggregate.standardDeviation else {
            return "n=0, moy=—, min=—, max=—, écart-type=—"
        }
        return String(
            format: "n=%d, moy=%+.1f°, min=%+.1f°, max=%+.1f°, écart-type=%.1f°",
            aggregate.count,
            average,
            minimum,
            maximum,
            dispersion
        )
    }
}

nonisolated struct BenchmarkSession: Sendable {
    let phases: [BenchmarkPhase]
    private(set) var metrics = BenchmarkMetrics()
    private(set) var phaseMetrics: [BenchmarkPhaseMetrics]
    private(set) var startUptime: TimeInterval?

    init(phases: [BenchmarkPhase] = BenchmarkPhase.guided) {
        self.phases = phases
        self.phaseMetrics = phases.map { _ in BenchmarkPhaseMetrics() }
    }

    var totalDuration: TimeInterval { phases.reduce(0) { $0 + $1.duration } }

    mutating func start(at uptime: TimeInterval) {
        startUptime = uptime
        metrics = BenchmarkMetrics()
        phaseMetrics = phases.map { _ in BenchmarkPhaseMetrics() }
    }

    mutating func record(_ measurement: BenchmarkMeasurement, at uptime: TimeInterval) {
        guard let phaseIndex = phaseIndex(at: uptime) else { return }
        metrics.record(measurement)
        phaseMetrics[phaseIndex].record(measurement)
    }

    mutating func recordOverlay(visible: Bool, at uptime: TimeInterval) {
        guard let phaseIndex = phaseIndex(at: uptime),
              phases[phaseIndex].expectation != .faceAbsent else { return }
        metrics.recordOverlay(visible: visible, at: uptime)
    }

    func progress(at uptime: TimeInterval) -> BenchmarkProgress? {
        guard let startUptime, !phases.isEmpty else { return nil }
        let elapsed = max(0, uptime - startUptime)
        var cursor: TimeInterval = 0
        for (index, phase) in phases.enumerated() {
            let end = cursor + phase.duration
            if elapsed < end || index == phases.count - 1 {
                return BenchmarkProgress(
                    instruction: phase.instruction,
                    phaseIndex: index,
                    phaseCount: phases.count,
                    phaseProgress: min(1, max(0, (elapsed - cursor) / phase.duration)),
                    totalProgress: min(1, elapsed / totalDuration)
                )
            }
            cursor = end
        }
        return nil
    }

    func isComplete(at uptime: TimeInterval) -> Bool {
        guard let startUptime else { return false }
        return uptime - startUptime >= totalDuration
    }

    mutating func finish(at uptime: TimeInterval) -> String {
        metrics.finish(at: uptime)
        let phaseReports = phases.enumerated().map { index, phase in
            phaseMetrics[index].report(for: phase, index: index)
        }
        return ([metrics.report, "", "Résultats par étape"]
            + phaseReports
            + comparisonReport())
            .joined(separator: "\n")
    }

    private func comparisonReport() -> [String] {
        let comparisons: [(String, String, String, String, String)] = [
            ("Tête gauche/droite", "tête à gauche", "tête à droite", "gauche", "droite"),
            ("Tête haut/bas", "vers le haut", "vers le bas", "haut", "bas"),
            ("Écran vers/loin", "écran vers toi", "écran de toi", "vers", "loin"),
            ("Visage près/loin", "Rapproche ton visage", "Éloigne le visage", "près", "loin")
        ]
        let lines: [String] = comparisons.compactMap { label, firstNeedle, secondNeedle, firstLabel, secondLabel in
            guard let first = phaseIndex(containing: firstNeedle),
                  let second = phaseIndex(containing: secondNeedle) else {
                return nil
            }
            return "  \(label) : \(comparisonValue(phaseMetrics[first], label: firstLabel)) · \(comparisonValue(phaseMetrics[second], label: secondLabel))"
        }
        guard !lines.isEmpty else { return [] }
        return ["", "Comparaisons géométriques par phase"] + lines
    }

    private func phaseIndex(containing text: String) -> Int? {
        phases.firstIndex {
            $0.instruction.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func comparisonValue(_ metrics: BenchmarkPhaseMetrics, label: String) -> String {
        func average(_ aggregate: ScalarAggregate) -> String {
            aggregate.average.map { String(format: "%+.3f", $0) } ?? "—"
        }
        return "\(label) eye-roll \(average(metrics.eyeLineRoll)), yaw \(average(metrics.yawProxy)), pitch \(average(metrics.pitchProxy)), interoculaire \(average(metrics.interocularDistance)), longueur \(average(metrics.faceLength))"
    }

    private func phaseIndex(at uptime: TimeInterval) -> Int? {
        guard let startUptime, !phases.isEmpty else { return nil }
        let elapsed = uptime - startUptime
        guard elapsed >= 0, elapsed < totalDuration else { return nil }
        var cursor: TimeInterval = 0
        for (index, phase) in phases.enumerated() {
            cursor += phase.duration
            if elapsed < cursor { return index }
        }
        return nil
    }
}

nonisolated struct BodyCadenceController {
    private(set) var lastAttemptUptime: TimeInterval?
    private var boostedUntil: TimeInterval?
    private let boostedDuration: TimeInterval = 5

    mutating func shouldRun(at uptime: TimeInterval) -> Bool {
        guard isDue(at: uptime) else { return false }
        recordAttempt(at: uptime, bodyAvailable: false)
        return true
    }

    func isDue(at uptime: TimeInterval) -> Bool {
        let interval = (boostedUntil.map { uptime < $0 } == true) ? 0.5 : 1.0
        guard let lastAttemptUptime else { return true }
        return uptime - lastAttemptUptime >= interval
    }

    func overdue(at uptime: TimeInterval) -> TimeInterval {
        let interval = (boostedUntil.map { uptime < $0 } == true) ? 0.5 : 1.0
        guard let lastAttemptUptime else { return 0 }
        return max(0, uptime - lastAttemptUptime - interval)
    }

    mutating func recordAttempt(at uptime: TimeInterval, bodyAvailable: Bool) {
        let wasBoosted = boostedUntil.map { uptime < $0 } == true
        lastAttemptUptime = uptime
        if bodyAvailable, !wasBoosted {
            boostedUntil = uptime + boostedDuration
        }
    }

    mutating func reset() {
        lastAttemptUptime = nil
        boostedUntil = nil
    }
}
