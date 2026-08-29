import Foundation

@main
private enum FaceOrientationHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func approximately(_ lhs: Double?, _ rhs: Double?, tolerance: Double = 0.000_001) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): true
        case let (.some(lhs), .some(rhs)): abs(lhs - rhs) < tolerance
        default: false
        }
    }

    static func main() {
        expect(BenchmarkPhase.guided.count == 11, "le benchmark guidé doit compter 11 phases")
        expect(BenchmarkPhase.guided.reduce(0) { $0 + $1.duration } == 60, "le benchmark guidé doit durer 60 secondes")
        expect(BenchmarkPhase.guided[7].instruction == "Sans bouger la tête, incline légèrement l’écran vers toi", "la phase d’inclinaison doit précéder l’éloignement")
        expect(BenchmarkPhase.guided[8].instruction == "Sans bouger la tête, éloigne légèrement l’écran de toi", "la phase d’éloignement doit précéder le masquage")
        var boundarySession = BenchmarkSession()
        boundarySession.start(at: 100)
        expect(boundarySession.progress(at: 140)?.phaseIndex == 7, "la frontière 40 s doit entrer dans l’inclinaison")
        expect(boundarySession.progress(at: 145)?.phaseIndex == 8, "la frontière 45 s doit entrer dans l’éloignement")
        expect(boundarySession.progress(at: 150)?.phaseIndex == 9, "la frontière 50 s doit entrer dans le masquage")

        let converted = FaceOrientationSignal(
            rollRadians: .pi / 2,
            yawRadians: -.pi / 4,
            pitchRadians: nil
        )
        expect(approximately(converted.rollDegrees, 90), "roll doit être converti en degrés")
        expect(approximately(converted.yawDegrees, -45), "yaw doit être converti en degrés")
        expect(converted.pitchDegrees == nil, "pitch nil doit rester nil")
        expect(FaceOrientationSignal.degrees(from: .infinity) == nil, "une valeur non finie doit être ignorée")

        var session = BenchmarkSession(phases: [
            BenchmarkPhase(instruction: "phase A", duration: 10, expectation: .faceVisible),
            BenchmarkPhase(instruction: "phase B", duration: 10, expectation: .faceVisible)
        ])
        session.start(at: 100)
        let first = FaceOrientationSignal(rollRadians: 0, yawRadians: .pi / 6, pitchRadians: nil)
        let second = FaceOrientationSignal(rollRadians: .pi / 6, yawRadians: .pi / 3, pitchRadians: nil)
        session.record(BenchmarkMeasurement(
            faceDuration: 0.01,
            faceSucceeded: true,
            faceHadLandmarks: true,
            faceOrientation: first,
            bodyDuration: nil,
            bodySucceeded: false,
            overlayVisible: true
        ), at: 101)
        session.record(BenchmarkMeasurement(
            faceDuration: 0.01,
            faceSucceeded: true,
            faceHadLandmarks: true,
            faceOrientation: second,
            bodyDuration: nil,
            bodySucceeded: false,
            overlayVisible: true
        ), at: 102)
        session.record(BenchmarkMeasurement(
            faceDuration: 0.01,
            faceSucceeded: true,
            faceHadLandmarks: true,
            faceOrientation: nil,
            bodyDuration: nil,
            bodySucceeded: false,
            overlayVisible: true
        ), at: 103)
        session.record(BenchmarkMeasurement(
            faceDuration: 0.01,
            faceSucceeded: true,
            faceHadLandmarks: true,
            faceOrientation: first,
            bodyDuration: nil,
            bodySucceeded: false,
            overlayVisible: true
        ), at: 111)

        let phaseA = session.phaseMetrics[0]
        expect(phaseA.roll.count == 2, "phase A doit compter les roll présents")
        expect(approximately(phaseA.roll.average, 15), "moyenne roll phase A incorrecte")
        expect(approximately(phaseA.roll.minimum, 0), "minimum roll phase A incorrect")
        expect(approximately(phaseA.roll.maximum, 30), "maximum roll phase A incorrect")
        expect(approximately(phaseA.roll.standardDeviation, 15), "dispersion roll phase A incorrecte")
        expect(phaseA.pitch.count == 0, "pitch nil ne doit pas être compté")
        expect(session.phaseMetrics[1].attempts == 1, "une mesure de phase B doit rester dans sa phase")
        expect(session.phaseMetrics[1].roll.count == 1, "phase B doit agréger son orientation")

        let report = session.finish(at: 119)
        expect(report.contains("Orientation (degrés)"), "le rapport doit exposer l’orientation")
        expect(report.contains("pitch n=0"), "le rapport doit exposer honnêtement pitch absent")
        print("FaceOrientationHarness: OK")
    }
}
