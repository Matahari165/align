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

        func polyline(_ name: String, _ points: [(Double, Double)]) -> PosePolyline {
            PosePolyline(
                name: name,
                locations: points.map { CGPoint(x: $0.0, y: $0.1) },
                source: .face,
                isClosed: false
            )
        }

        let basePolylines = [
            polyline("leftEye", [(0.20, 0.40), (0.20, 0.42), (0.22, 0.41)]),
            polyline("rightEye", [(0.60, 0.60), (0.60, 0.62), (0.62, 0.61)]),
            polyline("nose", [(0.46, 0.70), (0.48, 0.72), (0.47, 0.71)]),
            polyline("medianLine", [(0.40, 0.10), (0.40, 0.90)])
        ]
        let geometry = FaceGeometrySignal.from(polylines: basePolylines)
        expect(geometry != nil, "des landmarks valides doivent produire une géométrie")
        expect(approximately(geometry?.eyeLineRollDegrees, 26.565051177), "roll géométrique incorrect")
        expect(approximately(geometry?.yawProxy, 0.156524758, tolerance: 0.000_001), "le yaw proxy doit être positif et normalisé")
        expect(approximately(geometry?.pitchProxy, 0.25, tolerance: 0.000_001), "le pitch proxy doit suivre y capture")
        expect(geometry?.faceCenter != nil, "le centre facial dérivé doit être disponible")

        let invertedEyes = [
            polyline("leftEye", [(0.60, 0.60), (0.60, 0.62), (0.62, 0.61)]),
            polyline("rightEye", [(0.20, 0.40), (0.20, 0.42), (0.22, 0.41)]),
            polyline("nose", [(0.46, 0.70), (0.48, 0.72), (0.47, 0.71)]),
            polyline("medianLine", [(0.40, 0.10), (0.40, 0.90)])
        ]
        let invertedGeometry = FaceGeometrySignal.from(polylines: invertedEyes)
        expect(approximately(invertedGeometry?.eyeLineRollDegrees, geometry?.eyeLineRollDegrees), "le roll axial doit ignorer l’ordre des yeux")

        let contourFallback = FaceGeometrySignal.from(polylines: basePolylines
            .filter { $0.name != "medianLine" }
            + [polyline("faceContour", [(0.40, 0.10), (0.40, 0.90)])])
        expect(approximately(contourFallback?.pitchProxy, geometry?.pitchProxy), "le contour doit être le fallback de la longueur faciale")

        let translatedAndScaled = basePolylines.map { line in
            PosePolyline(
                name: line.name,
                locations: line.locations.map {
                    CGPoint(x: $0.x * 2 + 7, y: $0.y * 2 - 3)
                },
                source: line.source,
                isClosed: line.isClosed
            )
        }
        let transformedGeometry = FaceGeometrySignal.from(polylines: translatedAndScaled)
        expect(approximately(transformedGeometry?.eyeLineRollDegrees, geometry?.eyeLineRollDegrees), "roll doit être invariant par translation/échelle")
        expect(approximately(transformedGeometry?.yawProxy, geometry?.yawProxy), "yaw doit être invariant par translation/échelle")
        expect(approximately(transformedGeometry?.pitchProxy, geometry?.pitchProxy), "pitch doit être invariant par translation/échelle")
        expect(approximately(transformedGeometry?.interocularDistance, geometry?.interocularDistance.map { $0 * 2 }), "distance interoculaire doit suivre l'échelle")
        expect(approximately(transformedGeometry?.faceLength, geometry?.faceLength.map { $0 * 2 }),
               "longueur faciale doit suivre la même échelle morphologique")
        expect(approximately(transformedGeometry?.faceCenter.map { Double($0.x) },
                             geometry?.faceCenter.map { Double($0.x) * 2 + 7 }),
               "centre facial doit suivre translation et échelle")

        let expressionGeometry = FaceGeometrySignal.from(polylines: [
            polyline("leftEye", [(0.20, 0.40), (0.30, 0.38), (0.40, 0.40), (0.30, 0.44)]),
            polyline("rightEye", [(0.60, 0.40), (0.70, 0.38), (0.80, 0.40), (0.70, 0.44)]),
            polyline("leftEyebrow", [(0.25, 0.30), (0.42, 0.32)]),
            polyline("rightEyebrow", [(0.58, 0.32), (0.75, 0.30)]),
            polyline("medianLine", [(0.50, 0.20), (0.50, 0.80)])
        ])
        expect(approximately(expressionGeometry?.leftEyeOpeningRatio, 0.30),
               "ouverture œil gauche normalisée")
        expect(approximately(expressionGeometry?.rightEyeOpeningRatio, 0.30),
               "ouverture œil droit normalisée")
        expect(approximately(expressionGeometry?.innerBrowDistanceRatio, 0.40),
               "écart inter-sourcils normalisé")
        let angle = Double.pi / 4
        let rotatedExpression = expressionGeometry == nil ? [] : [
            polyline("leftEye", [(0.20, 0.40), (0.30, 0.38), (0.40, 0.40), (0.30, 0.44)]),
            polyline("rightEye", [(0.60, 0.40), (0.70, 0.38), (0.80, 0.40), (0.70, 0.44)]),
            polyline("medianLine", [(0.50, 0.20), (0.50, 0.80)])
        ].map { line in
            PosePolyline(name: line.name, locations: line.locations.map { point in
                let dx = Double(point.x) - 0.5
                let dy = Double(point.y) - 0.5
                return CGPoint(x: 0.5 + dx * cos(angle) - dy * sin(angle),
                               y: 0.5 + dx * sin(angle) + dy * cos(angle))
            }, source: line.source, isClosed: line.isClosed)
        }
        let rolledGeometry = FaceGeometrySignal.from(polylines: rotatedExpression)
        expect(approximately(rolledGeometry?.leftEyeOpeningRatio,
                             expressionGeometry?.leftEyeOpeningRatio),
               "ouverture œil invariante au roll")

        let oppositeNose = basePolylines.map { line in
            guard line.name == "nose" else { return line }
            return polyline("nose", [(0.30, 0.70), (0.32, 0.72)])
        }
        expect((FaceGeometrySignal.from(polylines: oppositeNose)?.yawProxy ?? 0) < 0, "un nez à gauche doit donner un yaw négatif")

        let missing = FaceGeometrySignal.from(polylines: [polyline("nose", [(0.4, 0.6), (0.4, 0.7)])])
        expect(missing == nil, "sans yeux ni longueur faciale, la géométrie doit être absente")
        let degenerate = FaceGeometrySignal.from(polylines: [
            polyline("leftEye", [(0.4, 0.4), (0.4, 0.4)]),
            polyline("rightEye", [(0.4, 0.4), (0.4, 0.4)]),
            polyline("nose", [(0.4, 0.6), (0.4, 0.6)]),
            polyline("medianLine", [(0.4, 0.4), (0.4, 0.4)])
        ])
        expect(degenerate == nil, "des distances dégénérées doivent être ignorées")
        let nonFinite = FaceGeometrySignal.from(polylines: [
            polyline("leftEye", [(Double.nan, 0.4), (Double.nan, 0.4)]),
            polyline("rightEye", [(0.6, 0.4), (0.6, 0.4)]),
            polyline("nose", [(0.5, 0.6), (0.5, 0.6)]),
            polyline("medianLine", [(0.4, 0.1), (0.4, 0.9)])
        ])
        expect(nonFinite?.yawProxy == nil && nonFinite?.interocularDistance == nil, "les coordonnées non finies doivent être ignorées")

        var geometrySession = BenchmarkSession(phases: [
            BenchmarkPhase(instruction: "phase géométrie", duration: 10, expectation: .faceVisible)
        ])
        geometrySession.start(at: 300)
        let geometryMeasurement = BenchmarkMeasurement(
            faceDuration: 0.01,
            faceSucceeded: true,
            faceHadLandmarks: true,
            faceOrientation: nil,
            faceGeometry: geometry,
            bodyDuration: nil,
            bodySucceeded: false,
            overlayVisible: true
        )
        geometrySession.record(geometryMeasurement, at: 301)
        geometrySession.record(geometryMeasurement, at: 302)
        expect(geometrySession.phaseMetrics[0].yawProxy.count == 2, "le yaw proxy doit être agrégé par phase")
        expect(approximately(geometrySession.phaseMetrics[0].pitchProxy.average, geometry?.pitchProxy), "la moyenne géométrique de phase est incorrecte")
        expect(geometrySession.phaseMetrics[0].pitchProxy.minimum == geometrySession.phaseMetrics[0].pitchProxy.maximum, "min/max géométriques doivent être conservés")

        var comparisonSession = BenchmarkSession()
        comparisonSession.start(at: 400)
        for uptime in [421.0, 426.0, 431.0, 436.0, 441.0, 446.0] {
            comparisonSession.record(geometryMeasurement, at: uptime)
        }
        let comparisonReport = comparisonSession.finish(at: 459)
        expect(comparisonReport.contains("Tête haut/bas"), "le rapport doit comparer haut et bas")
        expect(comparisonReport.contains("Tête gauche/droite"), "le rapport doit comparer gauche et droite")
        expect(comparisonReport.contains("Écran vers/loin"), "le rapport doit comparer l’écran vers et loin")
        expect(comparisonReport.contains("Visage près/loin"), "le rapport doit comparer près et loin")
        expect(comparisonReport.contains("interoculaire"), "le rapport doit exposer l’échelle interoculaire")
        expect(comparisonReport.contains("longueur faciale"), "le rapport doit exposer la longueur faciale")

        print("FaceOrientationHarness: OK")
    }
}
