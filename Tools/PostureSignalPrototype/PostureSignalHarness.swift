// Run:
// env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk -module-cache-path /tmp/align-posture-signal-cache Tools/PostureSignalPrototype/PostureSignalEvaluators.swift Tools/PostureSignalPrototype/PostureSignalHarness.swift -o /tmp/posture-signal-harness && /tmp/posture-signal-harness

import Foundation

@main
enum PostureSignalHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func face(time: Double, generation: UInt64 = 1, scale: Double = 1,
                     yaw: Double = 0, points: Int = 47) -> FaceMetricSnapshot {
        .init(timestamp: time, generation: generation,
              interocularDistance: 0.20 * scale, faceLength: 0.32 * scale,
              yawProxy: yaw, facePointCount: points)
    }

    static func shoulders(time: Double, generation: UInt64 = 1,
                          elevation: Double = 0, roll: Double = 0,
                          scale: Double = 1, yaw: Double = 0,
                          fresh: Bool = true) -> ShoulderMetricSnapshot {
        let sampleID = time.isFinite
            ? UInt64(max(0, Int((time * 1_000).rounded())))
            : 0
        let center = SignalPoint(x: 0.5, y: 0.35)
        func rotate(_ point: SignalPoint) -> SignalPoint {
            let dx = point.x - center.x
            let dy = point.y - center.y
            return .init(x: center.x + scale * (cos(roll) * dx - sin(roll) * dy),
                         y: center.y + scale * (sin(roll) * dx + cos(roll) * dy))
        }
        return .init(
            timestamp: time, generation: generation,
            leftShoulder: rotate(.init(x: 0.30, y: 0.70 - elevation)),
            rightShoulder: rotate(.init(x: 0.70, y: 0.70 - elevation)),
            faceReference: center, faceScale: 0.25 * scale,
            faceRollRadians: roll, yawProxy: yaw,
            bodySampleID: sampleID, faceGeneration: generation,
            faceTimestamp: time, faceSampleID: fresh ? sampleID : sampleID &+ 1
        )
    }

    static func main() {
        let faceCalibration = HeadProximityCalibration.make(
            from: (0..<7).map { face(time: Double($0) * 0.2) }
        )!
        let faceCalibration2 = HeadProximityCalibration.make(
            from: (0..<7).map { face(time: Double($0) * 0.2, generation: 2) }
        )!
        expect(HeadProximityCalibration.make(from: [
            face(time: 0), face(time: 0.2), face(time: 0.4, generation: 2),
            face(time: 0.6), face(time: 0.8)
        ]) == nil, "calibration visage mono-génération")
        expect(HeadProximityCalibration.make(from: [
            face(time: 0), face(time: 0.2), face(time: 0.2),
            face(time: 0.4), face(time: 0.6)
        ]) == nil, "calibration visage timestamp dupliqué")
        expect(HeadProximityCalibration.make(from: [
            face(time: 0), face(time: 0.2), face(time: 1.0),
            face(time: 1.2), face(time: 1.4)
        ]) == nil, "calibration visage gap")
        expect(HeadProximityCalibration.make(
            from: (0..<5).map { face(time: Double($0) * 0.2) },
            configuration: .init(maximumSampleGap: .nan)
        ) == nil, "configuration visage finie")
        var proximity = HeadProximityEvaluator(configuration: .init(
            minimumFacePointCount: 40, maximumAbsoluteYawProxy: 0.35,
            maximumScaleDisagreement: 0.18, enterRatio: 1.20,
            exitRatio: 1.12, requiredDuration: 0.9, maximumSampleGap: 0.45
        ))
        expect(proximity.consume(face(time: 2), calibration: faceCalibration).state == .neutral,
               "proximité neutre")
        expect(proximity.consume(face(time: 2.2, scale: 1.3), calibration: faceCalibration).state == .pending,
               "proximité transitoire")
        expect(proximity.consume(face(time: 2.4), calibration: faceCalibration).state == .neutral,
               "transitoire annulé")
        proximity.reset()
        for time in stride(from: 3.0, through: 4.0, by: 0.2) {
            _ = proximity.consume(face(time: time, scale: 1.3), calibration: faceCalibration)
        }
        expect(proximity.consume(face(time: 4.2, scale: 1.3), calibration: faceCalibration).state == .sustained,
               "proximité durable")
        expect(proximity.consume(face(time: 4.4, scale: 1.1), calibration: faceCalibration).state == .neutral,
               "hystérésis sortie")
        expect(proximity.consume(face(time: 4.6, scale: 1.3, yaw: 0.7), calibration: faceCalibration).state == .unavailable,
               "yaw invalide")
        expect(proximity.consume(face(time: 4.8, scale: 1.3, points: 12), calibration: faceCalibration).state == .unavailable,
               "qualité points invalide")
        expect(proximity.consume(nil, calibration: faceCalibration).state == .unavailable,
               "absence reset")
        expect(proximity.consume(face(time: 10, generation: 2), calibration: faceCalibration2).state == .neutral,
               "nouvelle génération")
        expect(proximity.consume(face(time: 10.2, generation: 1, scale: 1.4), calibration: faceCalibration2).state == .unavailable,
               "ancienne génération inerte")
        expect(proximity.consume(face(time: 9.9, generation: 2), calibration: faceCalibration2).state == .unavailable,
               "timestamp ancien")
        expect(proximity.lastTimestamp == 10, "timestamp visage rejeté ne recule pas")
        expect(proximity.consume(face(time: 10, generation: 2), calibration: faceCalibration2).state == .unavailable,
               "timestamp visage dupliqué")
        expect(proximity.lastTimestamp == 10, "timestamp visage dupliqué inerte")
        expect(proximity.consume(face(time: 12, generation: 2), calibration: faceCalibration2).state == .neutral,
               "gap visage reprend sur nouvel échantillon")
        expect(proximity.lastTimestamp == 12, "gap visage avance le watermark")
        expect(proximity.consume(face(time: 11, generation: 3), calibration: faceCalibration).state == .unavailable,
               "nouvelle génération timestamp ancien rejetée")
        expect(proximity.generation == 2 && proximity.lastTimestamp == 12,
               "nouvelle génération ancienne inerte")
        let inconsistent = FaceMetricSnapshot(timestamp: 13, generation: 3,
                                              interocularDistance: 0.30, faceLength: 0.32,
                                              yawProxy: 0, facePointCount: 47)
        expect(proximity.consume(inconsistent, calibration: faceCalibration).state == .unavailable,
               "contrôle double échelle")
        expect(proximity.consume(face(time: .nan, generation: 4), calibration: faceCalibration).state == .unavailable,
               "génération supérieure timestamp invalide")
        expect(proximity.generation == 3, "génération invalide ne reset pas")
        expect(proximity.consume(face(time: 13.2, generation: 2), calibration: faceCalibration).state == .unavailable,
               "ancienne génération reste inerte")
        expect(proximity.consume(face(time: 14, generation: 4, yaw: .infinity),
                                 calibration: faceCalibration).state == .unavailable,
               "génération supérieure payload invalide devient autoritaire")
        expect(proximity.generation == 4 && proximity.lastTimestamp == 14,
               "identité valide acceptée avant payload visage")
        expect(proximity.consume(face(time: 14.2, generation: 3), calibration: faceCalibration).state == .unavailable,
               "ancienne génération visage inerte après payload invalide")

        let shoulderCalibration = ShoulderHeightCalibration.make(
            from: (0..<7).map { shoulders(time: Double($0) * 0.2) }
        )!
        let shoulderCalibration4 = ShoulderHeightCalibration.make(
            from: (0..<7).map { shoulders(time: Double($0) * 0.2, generation: 4) }
        )!
        expect(ShoulderHeightCalibration.make(from: [
            shoulders(time: 0), shoulders(time: 0.2),
            shoulders(time: 0.4, generation: 2), shoulders(time: 0.6),
            shoulders(time: 0.8)
        ]) == nil, "calibration épaules mono-génération")
        expect(ShoulderHeightCalibration.make(from: [
            shoulders(time: 0), shoulders(time: 0.2, fresh: false),
            shoulders(time: 0.4), shoulders(time: 0.6), shoulders(time: 0.8)
        ]) == nil, "identité épaules vérifiable")
        var highShoulders = ShoulderHeightEvaluator(configuration: .init(
            enterElevation: 0.30, exitElevation: 0.18,
            requiredDuration: 1.0, maximumSampleGap: 0.65,
            maximumAbsoluteYawProxy: 0.35, maximumInterframeMovement: 0.50
        ))
        expect(highShoulders.consume(shoulders(time: 2), calibration: shoulderCalibration).state == .neutral,
               "épaules neutres")
        expect(highShoulders.consume(shoulders(time: 2.5, elevation: 0.10), calibration: shoulderCalibration).state == .pending,
               "hausse transitoire")
        expect(highShoulders.consume(shoulders(time: 3.0), calibration: shoulderCalibration).state == .neutral,
               "hausse transitoire annulée")
        highShoulders.reset()
        for time in stride(from: 4.0, through: 5.0, by: 0.5) {
            _ = highShoulders.consume(shoulders(time: time, elevation: 0.10), calibration: shoulderCalibration)
        }
        expect(highShoulders.consume(shoulders(time: 5.5, elevation: 0.10), calibration: shoulderCalibration).state == .sustained,
               "épaules hautes durables")
        expect(highShoulders.consume(shoulders(time: 6.0, elevation: 0.02), calibration: shoulderCalibration).state == .neutral,
               "hystérésis épaules")

        // Même géométrie après translation, échelle et roll : mesure identique.
        let base = ShoulderHeightEvaluator.relativeHeights(shoulders(time: 7, elevation: 0.05))!
        let transformed = ShoulderHeightEvaluator.relativeHeights(
            shoulders(time: 7, elevation: 0.05, roll: 0.45, scale: 1.8)
        )!
        expect(abs(base.left - transformed.left) < 0.000_001 &&
               abs(base.right - transformed.right) < 0.000_001,
               "invariance scale/roll/ROI")
        expect(highShoulders.consume(shoulders(time: 7, fresh: false), calibration: shoulderCalibration).state == .unavailable,
               "partial/lost indisponible")
        expect(highShoulders.consume(shoulders(time: 8, yaw: 0.8), calibration: shoulderCalibration).state == .unavailable,
               "yaw épaules invalide")
        expect(highShoulders.consume(nil, calibration: shoulderCalibration).state == .unavailable,
               "absence épaules reset")
        expect(highShoulders.consume(shoulders(time: 10, generation: 3), calibration: nil).state == .unavailable,
               "baseline absente")
        expect(highShoulders.consume(shoulders(time: 11, generation: 4), calibration: shoulderCalibration4).state == .neutral,
               "génération épaules active")
        var staleInvalid = shoulders(time: 11.2, generation: 3, fresh: false)
        expect(highShoulders.consume(staleInvalid, calibration: shoulderCalibration4).state == .unavailable,
               "ancienne génération invalide inerte")
        staleInvalid = shoulders(time: 11.4, generation: 3)
        expect(highShoulders.consume(staleInvalid, calibration: shoulderCalibration4).state == .unavailable,
               "ancienne génération valide reste inerte")
        expect(highShoulders.lastTimestamp == 11, "ancienne génération ne change pas timestamp")
        expect(highShoulders.consume(shoulders(time: 10.9, generation: 4), calibration: shoulderCalibration4).state == .unavailable,
               "timestamp épaules ancien")
        expect(highShoulders.lastTimestamp == 11, "timestamp épaules rejeté ne recule pas")
        expect(highShoulders.consume(shoulders(time: 11, generation: 4), calibration: shoulderCalibration4).state == .unavailable,
               "timestamp épaules dupliqué")
        expect(highShoulders.consume(shoulders(time: 13, generation: 4), calibration: shoulderCalibration4).state == .neutral,
               "gap épaules reprend sur nouvel échantillon")
        expect(highShoulders.lastTimestamp == 13, "gap épaules avance le watermark")
        expect(highShoulders.consume(shoulders(time: 12, generation: 5),
                                     calibration: shoulderCalibration4).state == .unavailable,
               "nouvelle génération épaules timestamp ancien")
        expect(highShoulders.generation == 4 && highShoulders.lastTimestamp == 13,
               "génération épaules ancienne inerte")
        expect(highShoulders.consume(shoulders(time: .nan, generation: 5), calibration: shoulderCalibration).state == .unavailable,
               "génération épaules supérieure invalide")
        expect(highShoulders.generation == 4, "génération épaules invalide ne reset pas")
        expect(highShoulders.consume(shoulders(time: 11.2, generation: 3), calibration: shoulderCalibration).state == .unavailable,
               "ancienne génération épaules inerte après invalide")
        expect(highShoulders.consume(shoulders(time: 14, generation: 5, yaw: .infinity),
                                     calibration: shoulderCalibration4).state == .unavailable,
               "génération supérieure payload épaules invalide")
        expect(highShoulders.generation == 5 && highShoulders.lastTimestamp == 14,
               "identité valide acceptée avant payload épaules")
        expect(highShoulders.consume(shoulders(time: 14.2, generation: 4),
                                     calibration: shoulderCalibration4).state == .unavailable,
               "ancienne génération épaules inerte après payload invalide")

        print("PostureSignalHarness: OK")
    }
}
