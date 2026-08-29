import Foundation

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
        BenchmarkPhase(instruction: "Masque le visage", duration: 5, expectation: .faceAbsent),
        BenchmarkPhase(instruction: "Découvre le visage et reste neutre", duration: 5, expectation: .recovery)
    ]
}

nonisolated struct BenchmarkMeasurement: Sendable {
    let faceDuration: TimeInterval
    let faceSucceeded: Bool
    let faceHadLandmarks: Bool
    let bodyDuration: TimeInterval?
    let bodySucceeded: Bool
    let overlayVisible: Bool
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

    var average: TimeInterval { count == 0 ? 0 : total / Double(count) }

    mutating func record(_ duration: TimeInterval) {
        count += 1
        total += duration
        maximum = max(maximum, duration)
    }
}

nonisolated struct BenchmarkMetrics: Sendable {
    private(set) var faceDurations = DurationAggregate()
    private(set) var bodyDurations = DurationAggregate()
    private(set) var faceAttempts = 0
    private(set) var faceSuccesses = 0
    private(set) var facesWithLandmarks = 0
    private(set) var bodyAttempts = 0
    private(set) var bodySuccesses = 0
    private(set) var overlayDropouts = 0
    private(set) var longestInterruption: TimeInterval = 0
    private(set) var recoveryDurations = DurationAggregate()
    private var interruptionStart: TimeInterval?
    private var hasSeenOverlay = false

    mutating func record(_ measurement: BenchmarkMeasurement) {
        faceAttempts += 1
        faceDurations.record(measurement.faceDuration)
        if measurement.faceSucceeded { faceSuccesses += 1 }
        if measurement.faceHadLandmarks { facesWithLandmarks += 1 }

        if let bodyDuration = measurement.bodyDuration {
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
        func milliseconds(_ value: TimeInterval) -> String {
            String(format: "%.1f ms", value * 1_000)
        }
        func rate(_ successes: Int, _ attempts: Int) -> String {
            attempts == 0 ? "—" : String(format: "%.1f %%", Double(successes) / Double(attempts) * 100)
        }

        return [
            "Benchmark Vision Align",
            "Visage : \(faceAttempts) tentatives, \(faceSuccesses) succès (\(rate(faceSuccesses, faceAttempts))), \(facesWithLandmarks) avec landmarks",
            "Durée visage : moyenne \(milliseconds(faceDurations.average)), max \(milliseconds(faceDurations.maximum))",
            "Corps : \(bodyAttempts) tentatives, \(bodySuccesses) succès (\(rate(bodySuccesses, bodyAttempts)))",
            "Durée corps : moyenne \(milliseconds(bodyDurations.average)), max \(milliseconds(bodyDurations.maximum))",
            "Overlay : \(overlayDropouts) pertes, interruption max \(String(format: "%.2f s", longestInterruption)), récupération moyenne \(String(format: "%.2f s", recoveryDurations.average))",
            "CPU/RSS : à mesurer séparément via CLI"
        ].joined(separator: "\n")
    }
}

nonisolated struct BenchmarkPhaseMetrics: Sendable {
    private(set) var attempts = 0
    private(set) var facesWithLandmarks = 0
    private(set) var visibleOverlays = 0

    mutating func record(_ measurement: BenchmarkMeasurement) {
        attempts += 1
        if measurement.faceHadLandmarks { facesWithLandmarks += 1 }
        if measurement.overlayVisible { visibleOverlays += 1 }
    }

    func report(for phase: BenchmarkPhase, index: Int) -> String {
        func rate(_ successes: Int) -> String {
            attempts == 0 ? "—" : String(format: "%.1f %%", Double(successes) / Double(attempts) * 100)
        }

        let conforming: Int
        switch phase.expectation {
        case .faceVisible, .recovery:
            conforming = facesWithLandmarks
        case .faceAbsent:
            conforming = attempts - facesWithLandmarks
        }

        return "Étape \(index + 1) · \(phase.instruction) : \(phase.expectation.reportLabel), conformité \(rate(conforming)), overlay visible \(rate(visibleOverlays))"
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
        return ([metrics.report, "", "Résultats par étape"] + phases.enumerated().map { index, phase in
            phaseMetrics[index].report(for: phase, index: index)
        }).joined(separator: "\n")
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
        let interval = (boostedUntil.map { uptime < $0 } == true) ? 0.5 : 1.0
        guard let lastAttemptUptime else { return true }
        return uptime - lastAttemptUptime >= interval
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
