import Foundation

@main
struct UpperBodyLandmarkHarness {
    static func main() {
        testCoverageAndConfidence()
        testFreshnessAndGeneration()
        testBenchmarkAggregation()
        print("UpperBodyLandmarkHarness: OK")
    }

    private static func testFreshnessAndGeneration() {
        var tracker = BodyOverlayFreshnessTracker()
        tracker.reset(generation: 1)
        tracker.recordObservation(at: 10, generation: 1)
        expect(!tracker.shouldExpire(at: 11.19, generation: 1), "le repère doit rester frais avant 1,2 s")
        expect(tracker.shouldExpire(at: 11.21, generation: 1), "le repère doit expirer après 1,2 s")
        tracker.reset(generation: 2)
        expect(!tracker.shouldExpire(at: 20, generation: 1), "une ancienne génération ne doit jamais expirer la nouvelle")
    }

    private static func testCoverageAndConfidence() {
        expect(UpperBodyLandmark.neck.visionJointName.rawValue.rawValue == "neck_1_joint", "le cou doit utiliser le nom SDK explicite")
        expect(UpperBodyLandmark.leftShoulder.visionJointName.rawValue.rawValue == "left_shoulder_1_joint", "l’épaule gauche doit utiliser le nom SDK explicite")
        expect(UpperBodyLandmark.rightShoulder.visionJointName.rawValue.rawValue == "right_shoulder_1_joint", "l’épaule droite doit utiliser le nom SDK explicite")

        let none = UpperBodyLandmarkDiagnostics.empty
        expect(none.recognizedCount == 0, "aucun repère doit produire 0/3")

        let one = UpperBodyLandmarkDiagnostics(confidenceByLandmark: [.neck: 0.72])
        expect(one.recognizedCount == 1, "le cou seul doit produire 1/3")
        expect(one.confidence(for: .neck) == 0.72, "la confiance du cou doit être conservée")

        let weak = UpperBodyLandmarkDiagnostics(confidenceByLandmark: [.neck: 0.34])
        expect(weak.recognizedCount == 0, "une confiance sous 0,35 ne doit pas créer de repère")
        expect(weak.confidence(for: .neck) == 0.34, "la confiance brute sous le seuil doit rester mesurable")

        let two = UpperBodyLandmarkDiagnostics(confidenceByLandmark: [
            .leftShoulder: 0.61,
            .rightShoulder: 0.83
        ])
        expect(two.recognizedCount == 2, "deux épaules doivent produire 2/3")

        let three = UpperBodyLandmarkDiagnostics(confidenceByLandmark: [
            .neck: 0.91,
            .leftShoulder: 0.81,
            .rightShoulder: 0.71
        ])
        expect(three.recognizedCount == 3, "le trio complet doit produire 3/3")
        expect(three.confidence(for: .leftShoulder) == 0.81, "gauche et droite ne doivent pas être inversées")
        expect(three.confidence(for: .rightShoulder) == 0.71, "gauche et droite ne doivent pas être inversées")
    }

    private static func testBenchmarkAggregation() {
        var metrics = BenchmarkMetrics()
        for landmarks in [
            UpperBodyLandmarkDiagnostics.empty,
            UpperBodyLandmarkDiagnostics(confidenceByLandmark: [.neck: 0.60]),
            UpperBodyLandmarkDiagnostics(confidenceByLandmark: [.neck: 0.70, .leftShoulder: 0.80]),
            UpperBodyLandmarkDiagnostics(confidenceByLandmark: [.neck: 0.90, .leftShoulder: 0.85, .rightShoulder: 0.75])
        ] {
            metrics.record(BenchmarkMeasurement(
                faceAttempted: false,
                faceDuration: 0,
                faceSucceeded: false,
                faceHadLandmarks: false,
                faceOrientation: nil,
                bodyDuration: 0.01,
                bodyAttempted: true,
                bodySucceeded: landmarks.recognizedCount == 3,
                bodyObservationAvailable: true,
                upperBodyLandmarks: landmarks,
                overlayVisible: landmarks.recognizedCount > 0
            ))
        }
        metrics.record(BenchmarkMeasurement(
            faceAttempted: false, faceDuration: 0, faceSucceeded: false,
            faceHadLandmarks: false, faceOrientation: nil,
            bodyDuration: 0.01, bodyAttempted: true, bodySucceeded: false,
            bodyObservationAvailable: false, overlayVisible: false
        ))
        metrics.record(BenchmarkMeasurement(
            faceAttempted: false, faceDuration: 0, faceSucceeded: false,
            faceHadLandmarks: false, faceOrientation: nil,
            bodyDuration: 0.01, bodyAttempted: true, bodySucceeded: false,
            bodyObservationAvailable: false, bodyInferenceError: true,
            overlayVisible: false
        ))

        let report = metrics.report
        expect(report.contains("0/3, 1/3, 2/3, 3/3 : 1 / 1 / 1 / 1"), "le rapport doit séparer les quatre niveaux de couverture")
        expect(report.contains("cou 3/4 (75.0 %)"), "la présence du cou doit être agrégée séparément")
        expect(report.contains("épaule gauche 2/4 (50.0 %)"), "l’épaule gauche doit être agrégée séparément")
        expect(report.contains("épaule droite 1/4 (25.0 %)"), "l’épaule droite doit être agrégée séparément")
        expect(report.contains("Observations corps : 4, sans résultat 1, erreurs 1"), "absence et erreur ne doivent pas être comptées comme 0/3")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("UpperBodyLandmarkHarness: FAIL — \(message)\n", stderr)
            exit(1)
        }
    }
}
