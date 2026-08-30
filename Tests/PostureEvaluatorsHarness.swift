import Foundation

@main
enum PostureEvaluatorsHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func snapshot(
        time: Double,
        generation: UInt64 = 1,
        scale: Double = 1,
        pitch: Double = 0,
        eye: Double = 0.30,
        brow: Double = 0.40,
        shoulderY: Double = 0.70,
        includeBody: Bool = true,
        includeLeftEye: Bool = true,
        includeLeftShoulder: Bool = true,
        faceSampleID: UInt64? = nil,
        bodyGeneration: UInt64? = nil,
        bodyTime: Double? = nil,
        bodySampleID: UInt64? = nil
    ) -> PostureSnapshot {
        let id = faceSampleID ?? (time.isFinite && time >= 0
            ? UInt64((time * 100).rounded()) : 0)
        let resolvedBodyTime = bodyTime ?? time
        return PostureSnapshot(
            faceGeneration: generation,
            faceTimestamp: time,
            faceSampleID: id,
            facePointCount: 50,
            interocularDistance: 0.20 * scale,
            faceLength: 0.32 * scale,
            pitchProxy: pitch,
            yawProxy: 0,
            leftEyeOpeningRatio: includeLeftEye ? eye : nil,
            rightEyeOpeningRatio: eye,
            innerBrowDistanceRatio: brow,
            faceCenter: .init(x: 0.5, y: 0.3),
            leftShoulder: includeBody && includeLeftShoulder ? .init(x: 0.3, y: shoulderY) : nil,
            rightShoulder: includeBody ? .init(x: 0.7, y: shoulderY) : nil,
            bodyGeneration: includeBody ? (bodyGeneration ?? generation) : nil,
            bodyTimestamp: includeBody ? resolvedBodyTime : nil,
            bodySampleID: includeBody ? (bodySampleID ?? id &+ 10_000) : nil
        )
    }

    static func main() {
        var fusion = PostureAsyncFusion(maximumSkew: 0.30)!
        let bodyBeforeFace = PostureShoulderSnapshot(
            generation: 1, timestamp: 29.8, sampleID: 900,
            leftShoulder: .init(x: 0.3, y: 0.7),
            rightShoulder: .init(x: 0.7, y: 0.7)
        )
        expect(fusion.ingestBody(bodyBeforeFace) == nil,
               "un corps seul ne fabrique pas de face")
        let fused = fusion.ingestFace(snapshot(time: 30, includeBody: false,
                                               faceSampleID: 3_000))
        expect(fused?.bodySampleID == 900 && fused?.faceSampleID == 3_000,
               "fusion proche conserve deux identités sources distinctes")
        expect(fusion.ingestFace(snapshot(time: 30, includeBody: false,
                                         faceSampleID: 3_000)) == nil,
               "face dupliquée dédupliquée explicitement")
        expect(fusion.ingestFace(snapshot(time: 30, scale: 1.1, includeBody: false,
                                         faceSampleID: 3_000)) == nil,
               "payload modifié sous même identité refusé")
        let newerBody = PostureShoulderSnapshot(
            generation: 1, timestamp: 30.2, sampleID: 901,
            leftShoulder: .init(x: 0.3, y: 0.67),
            rightShoulder: .init(x: 0.7, y: 0.67)
        )
        expect(fusion.ingestBody(newerBody)?.faceSampleID == 3_000,
               "nouveau corps peut réémettre la dernière face")
        let sameTimestampBody = PostureShoulderSnapshot(
            generation: 1, timestamp: 30.2, sampleID: 902,
            leftShoulder: .init(x: 0.3, y: 0.66),
            rightShoulder: .init(x: 0.7, y: 0.66)
        )
        expect(fusion.ingestBody(sameTimestampBody)?.bodySampleID == 902,
               "timestamp égal départagé par l'identifiant source")
        let staleBody = PostureShoulderSnapshot(
            generation: 1, timestamp: 30.1, sampleID: 903,
            leftShoulder: .init(x: 0.3, y: 0.6),
            rightShoulder: .init(x: 0.7, y: 0.6)
        )
        expect(fusion.ingestBody(staleBody) == nil, "timestamp corps ancien rejeté")
        let farBody = PostureShoulderSnapshot(
            generation: 1, timestamp: 30.31, sampleID: 904,
            leftShoulder: .init(x: 0.3, y: 0.6),
            rightShoulder: .init(x: 0.7, y: 0.6)
        )
        expect(fusion.ingestBody(farBody) == nil, "fusion hors skew non émise")
        expect(fusion.ingestFace(snapshot(time: 30.4, includeBody: false,
                                         faceSampleID: 3_001))?.bodySampleID == 904,
               "dernières sources fusionnées seulement lorsqu'elles deviennent proches")
        expect(fusion.ingestFace(snapshot(time: 30.4, includeBody: false,
                                         faceSampleID: 3_002))?.faceSampleID == 3_002,
               "timestamp face égal départagé par l'identifiant source")
        expect(fusion.discardBody(generation: 1, timestamp: 30.4, sampleID: 905)?
               .bodySampleID == nil, "partial/lost purge immédiatement le corps")
        expect(fusion.ingestBody(farBody) == nil,
               "un corps antérieur ne réapparaît pas après purge")

        expect(PostureCalibrationSession(generation: 1, startedAt: 0,
                                         maximumSamples: 31) == nil,
               "calibration limitée à 30 échantillons")
        expect(PostureCalibrationSession(generation: 1, startedAt: 0,
                                         minimumDuration: 7.9) == nil,
               "calibration dure au moins 8 secondes")

        var session = PostureCalibrationSession(generation: 1, startedAt: 0)!
        var calibration: PostureCalibration?
        for index in 0 ... 27 {
            let result = session.consume(snapshot(time: Double(index) * 0.3))
            if case let .ready(value) = result { calibration = value }
        }
        guard let calibration else {
            expect(false, "calibration prête après 8,1 secondes")
            return
        }
        expect(calibration.sampleCount <= 30, "échantillons bornés")
        expect(calibration.completedAt - calibration.startedAt >= 8,
               "fenêtre de calibration explicite")

        var bounded = PostureCalibrationSession(generation: 1, startedAt: 0)!
        var maximumObservedSamples = 0
        for index in 0 ... 50 {
            switch bounded.consume(snapshot(time: Double(index) * 0.2)) {
            case let .collecting(_, count): maximumObservedSamples = max(maximumObservedSamples, count)
            case let .ready(value): maximumObservedSamples = max(maximumObservedSamples, value.sampleCount)
            case .failed: break
            }
        }
        expect(maximumObservedSamples <= 30, "plafond strict même sur dix secondes")

        var finishing = PostureCalibrationSession(generation: 1, startedAt: 0)!
        for index in 0 ... 26 {
            _ = finishing.consume(snapshot(time: Double(index) * 0.3))
        }
        guard case .ready = finishing.finish(at: 9.5) else {
            expect(false, "fin explicite sans nouvelle image")
            return
        }

        var faceOnlySession = PostureCalibrationSession(generation: 1, startedAt: 0)!
        var faceOnlyCalibration: PostureCalibration?
        for index in 0 ... 27 {
            let result = faceOnlySession.consume(snapshot(time: Double(index) * 0.3,
                                                          includeBody: false))
            if case let .ready(value) = result { faceOnlyCalibration = value }
        }
        expect(faceOnlyCalibration?.faceScale != nil &&
               faceOnlyCalibration?.shoulderElevation == nil,
               "calibration indépendante visage sans épaules")

        var unstableSession = PostureCalibrationSession(generation: 1, startedAt: 0)!
        var unstableCalibration: PostureCalibration?
        for index in 0 ... 27 {
            let result = unstableSession.consume(snapshot(
                time: Double(index) * 0.3,
                scale: index.isMultiple(of: 2) ? 1 : 1.4
            ))
            if case let .ready(value) = result { unstableCalibration = value }
        }
        expect(unstableCalibration?.faceScale == nil,
               "mouvement facial instable refusé pour la distance")

        var asynchronousCalibration = PostureCalibrationSession(generation: 1, startedAt: 0)!
        var asynchronousResult: PostureCalibration?
        for index in 0 ... 27 {
            let bodyIndex = index / 3
            let result = asynchronousCalibration.consume(snapshot(
                time: Double(index) * 0.3,
                bodyTime: Double(bodyIndex) * 0.9,
                bodySampleID: UInt64(50_000 + bodyIndex)
            ))
            if case let .ready(value) = result { asynchronousResult = value }
        }
        expect(asynchronousResult?.bodySampleCount == 10,
               "échantillons corps asynchrones dédupliqués par identité source")

        var wrongGeneration = PostureCalibrationSession(generation: 2, startedAt: 0)!
        expect(wrongGeneration.consume(snapshot(time: 0, generation: 1)) == .failed,
               "une autre génération est rejetée")

        let config = PostureEvaluatorConfiguration(
            ttl: 0.75,
            maximumSampleGap: 0.75,
            requiredDuration: 0.4,
            minimumFacePointCount: 40,
            maximumAbsoluteYawProxy: 0.35
        )
        var suite = PostureEvaluatorSuite(configuration: config)
        let absentCalibration = suite.consume(snapshot(time: 8.2), calibration: nil, now: 8.2)
        expect(absentCalibration.headProximity.state == .unavailable,
               "absence de repère distincte d'une calibration active")
        suite.reset()
        let activeCalibration = suite.consume(snapshot(time: 8.2), calibration: nil,
                                              now: 8.2, calibrationInProgress: true)
        expect(activeCalibration.headProximity.state == .calibrating,
               "calibration active explicite")
        suite.reset()
        let neutral = suite.consume(snapshot(time: 8.4), calibration: calibration, now: 8.4)
        expect(neutral.headProximity.state == .neutral, "distance neutre")
        expect(neutral.relativeHeadPosition.state == .neutral, "position neutre")
        expect(neutral.experimentalForwardHead.state == .neutral, "avant neutre")
        expect(neutral.elevatedShoulders.state == .neutral, "épaules neutres")
        expect(neutral.narrowedBrows.state == .neutral, "sourcils neutres")

        let stale = suite.consume(snapshot(time: 8.5), calibration: calibration, now: 9.5)
        expect(stale.headProximity.state == .unavailable, "TTL appliquée")
        let duplicate = suite.consume(snapshot(time: 8.5), calibration: calibration, now: 8.5)
        expect(duplicate.headProximity.state == .unavailable, "doublon inerte")
        suite.reset()
        expect(suite.consume(snapshot(time: 9), calibration: calibration, now: 8.9)
               .headProximity.state == .unavailable, "timestamp futur rejeté")

        suite.reset()
        _ = suite.consume(snapshot(time: 9.0, scale: 1.3, pitch: 0.15,
                                   brow: 0.32, shoulderY: 0.67),
                          calibration: calibration, now: 9.0)
        let pending = suite.consume(snapshot(time: 9.2, scale: 1.3, pitch: 0.15,
                                             brow: 0.32, shoulderY: 0.67),
                                    calibration: calibration, now: 9.2)
        expect(pending.headProximity.state == .pending, "hystérésis en attente")
        let attention = suite.consume(snapshot(time: 9.4, scale: 1.3, pitch: 0.15,
                                               brow: 0.32, shoulderY: 0.67),
                                      calibration: calibration, now: 9.4)
        expect(attention.headProximity.state == .attention, "tête proche")
        expect(attention.relativeHeadPosition.state == .attention, "position relative")
        expect(attention.experimentalForwardHead.state == .attention &&
               attention.experimentalForwardHead.isExperimental,
               "maturité expérimentale distincte de l'alerte")
        expect(attention.elevatedShoulders.state == .attention, "épaules élevées")
        expect(attention.narrowedBrows.state == .attention, "sourcils rapprochés")

        suite.reset()
        _ = suite.consume(snapshot(time: 10.0), calibration: calibration, now: 10.0)
        let closed = suite.consume(snapshot(time: 10.1, eye: 0.15),
                                   calibration: calibration, now: 10.1)
        expect(closed.estimatedBlinks.state == .pending, "fermeture observée")
        let reopened = suite.consume(snapshot(time: 10.2), calibration: calibration, now: 10.2)
        expect(reopened.estimatedBlinks.value == 1, "clignement estimé compté")
        expect(reopened.estimatedBlinks.quality == .good, "qualité cadence 10 Hz")

        suite.reset()
        _ = suite.consume(snapshot(time: 10.5), calibration: calibration, now: 10.5)
        let partialEye = suite.consume(snapshot(time: 10.6, includeLeftEye: false),
                                       calibration: calibration, now: 10.6)
        expect(partialEye.estimatedBlinks.state == .unavailable,
               "un seul œil ne suffit pas au comptage")
        let partialShoulder = suite.consume(snapshot(time: 10.7, includeLeftShoulder: false),
                                            calibration: calibration, now: 10.7)
        expect(partialShoulder.elevatedShoulders.state == .unavailable,
               "une seule épaule ne suffit pas")

        suite.reset()
        _ = suite.consume(snapshot(time: 11.0), calibration: calibration, now: 11.0)
        let slow = suite.consume(snapshot(time: 11.2), calibration: calibration, now: 11.2)
        expect(slow.estimatedBlinks.quality == .limited,
               "cadence lente explicitement limitée")

        suite.reset()
        let invalid = snapshot(time: .nan)
        expect(suite.consume(invalid, calibration: calibration, now: 12).headProximity.state
               == .unavailable, "timestamp non fini rejeté")
        let nextGeneration = suite.consume(snapshot(time: 12, generation: 2),
                                           calibration: calibration, now: 12)
        expect(nextGeneration.headProximity.state == .unavailable,
               "calibration bornée à sa génération")
        expect(suite.consume(snapshot(time: 12.1, generation: 1),
                             calibration: calibration, now: 12.1).headProximity.state
               == .unavailable, "ancienne génération inerte")

        suite.reset()
        _ = suite.consume(snapshot(time: 13, scale: 1.3), calibration: calibration, now: 13)
        _ = suite.consume(snapshot(time: 13.2, scale: 1.3), calibration: calibration, now: 13.2)
        expect(suite.consume(snapshot(time: 13.4, scale: 1.3),
                             calibration: calibration, now: 13.4).headProximity.state == .attention,
               "précondition attention")
        _ = suite.consume(snapshot(time: 13.5), calibration: calibration, now: 14.5)
        expect(suite.consume(snapshot(time: 14.6), calibration: calibration, now: 14.6)
               .headProximity.state == .neutral,
               "attention ne ressuscite pas après invalidation")

        // Une même face peut être réutilisée lorsque de nouvelles épaules arrivent.
        suite.reset()
        let sharedFaceID: UInt64 = 20_000
        _ = suite.consume(snapshot(time: 20, scale: 1.3, shoulderY: 0.67,
                                   faceSampleID: sharedFaceID,
                                   bodyTime: 19.79, bodySampleID: 70_000),
                          calibration: calibration, now: 20)
        let asynchronousPending = suite.consume(snapshot(
            time: 20, scale: 1.3, shoulderY: 0.67,
            faceSampleID: sharedFaceID, bodyTime: 20.0, bodySampleID: 70_001
        ), calibration: calibration, now: 20)
        expect(asynchronousPending.elevatedShoulders.state == .pending,
               "nouveau corps accepté avec face explicitement répétée")
        expect(asynchronousPending.headProximity.state == .pending,
               "face répétée ne fait pas progresser une seconde fois le canal visage")
        let asynchronousAttention = suite.consume(snapshot(
            time: 20, scale: 1.3, shoulderY: 0.67,
            faceSampleID: sharedFaceID, bodyTime: 20.21, bodySampleID: 70_002
        ), calibration: calibration, now: 20.21)
        expect(asynchronousAttention.elevatedShoulders.state == .attention,
               "persistance basée sur timestamps corps monotones")
        expect(asynchronousAttention.experimentalForwardHead.isExperimental,
               "tête avancée conserve sa maturité expérimentale")

        let excessiveSkew = suite.consume(snapshot(
            time: 20, scale: 1.3, shoulderY: 0.67,
            faceSampleID: sharedFaceID, bodyTime: 20.31, bodySampleID: 70_003
        ), calibration: calibration, now: 20.31)
        expect(excessiveSkew.elevatedShoulders.state == .unavailable,
               "skew supérieur à 0,30 seconde rejeté")
        let wrongBodyGeneration = suite.consume(snapshot(
            time: 20, scale: 1.3, shoulderY: 0.67,
            faceSampleID: sharedFaceID, bodyGeneration: 2,
            bodyTime: 20.2, bodySampleID: 70_004
        ), calibration: calibration, now: 20.2)
        expect(wrongBodyGeneration.elevatedShoulders.state == .unavailable,
               "génération corps différente rejetée")

        let alteredDuplicateFace = suite.consume(snapshot(
            time: 20, scale: 1.1, faceSampleID: sharedFaceID,
            bodyTime: 20.2, bodySampleID: 70_005
        ), calibration: calibration, now: 20.2)
        expect(alteredDuplicateFace.headProximity.state == .unavailable,
               "même identité faciale avec payload différent rejetée")

        suite.reset()
        _ = suite.consume(snapshot(time: 21, scale: 1.0,
                                   faceSampleID: 21_000,
                                   bodyTime: 21, bodySampleID: 80_000),
                          calibration: calibration, now: 21)
        let recomputedPair = suite.consume(snapshot(
            time: 21.2, scale: 1.3, faceSampleID: 21_001,
            bodyTime: 21, bodySampleID: 80_000
        ), calibration: calibration, now: 21.2)
        expect(recomputedPair.experimentalForwardHead.state == .pending,
               "nouvelle face recalcule la paire sans avancer le timestamp corps")

        suite.reset()
        _ = suite.consume(snapshot(time: 22.0, brow: 0.36),
                          calibration: calibration, now: 22.0)
        _ = suite.consume(snapshot(time: 22.2, brow: 0.36),
                          calibration: calibration, now: 22.2)
        let deliberateBrowContraction = suite.consume(
            snapshot(time: 22.4, brow: 0.36), calibration: calibration, now: 22.4
        )
        expect(deliberateBrowContraction.narrowedBrows.state == .attention,
               "rapprochement sourcils de 10 % détecté après 0,4 seconde")
        let browRelease = suite.consume(snapshot(time: 22.6, brow: 0.385),
                                        calibration: calibration, now: 22.6)
        expect(browRelease.narrowedBrows.state == .neutral,
               "hystérésis sourcils sort sous 4 %")

        suite.reset()
        _ = suite.consume(snapshot(time: 23.0, brow: 0.3684),
                          calibration: calibration, now: 23.0)
        _ = suite.consume(snapshot(time: 23.2, brow: 0.3684),
                          calibration: calibration, now: 23.2)
        expect(suite.consume(snapshot(time: 23.4, brow: 0.3684),
                             calibration: calibration, now: 23.4).narrowedBrows.state == .neutral,
               "contraction 7,9 % ne déclenche pas")
        suite.reset()
        _ = suite.consume(snapshot(time: 24.0, brow: 0.368),
                          calibration: calibration, now: 24.0)
        _ = suite.consume(snapshot(time: 24.2, brow: 0.368),
                          calibration: calibration, now: 24.2)
        expect(suite.consume(snapshot(time: 24.4, brow: 0.368),
                             calibration: calibration, now: 24.4).narrowedBrows.state == .attention,
               "frontière 8 % déclenche après trois mesures à 5 Hz")
        expect(suite.consume(snapshot(time: 24.6, brow: 0.384),
                             calibration: calibration, now: 24.6).narrowedBrows.state == .neutral,
               "frontière de sortie 4 % libère l'attention")
        suite.reset()
        _ = suite.consume(snapshot(time: 25.0, brow: 0.36),
                          calibration: calibration, now: 25.0)
        _ = suite.consume(snapshot(time: 25.2, brow: 0.40),
                          calibration: calibration, now: 25.2)
        _ = suite.consume(snapshot(time: 25.4, brow: 0.36),
                          calibration: calibration, now: 25.4)
        expect(suite.consume(snapshot(time: 25.6, brow: 0.36),
                             calibration: calibration, now: 25.6).narrowedBrows.state == .pending,
               "une interruption avant 0,4 seconde remet la durée à zéro")

        // Clignement de 100 ms : invisible aux instants 5 Hz, visible à 10 Hz.
        suite.reset()
        _ = suite.consume(snapshot(time: 30.0, eye: 0.30),
                          calibration: calibration, now: 30.0)
        let fiveHertz = suite.consume(snapshot(time: 30.2, eye: 0.30),
                                      calibration: calibration, now: 30.2)
        expect(fiveHertz.estimatedBlinks.value == 0,
               "5 Hz manque un clignement entièrement entre deux analyses")
        expect(fiveHertz.estimatedBlinks.quality == .limited,
               "5 Hz reste marqué qualité limitée")
        suite.reset()
        _ = suite.consume(snapshot(time: 31.0, eye: 0.30),
                          calibration: calibration, now: 31.0)
        _ = suite.consume(snapshot(time: 31.1, eye: 0.15),
                          calibration: calibration, now: 31.1)
        let tenHertz = suite.consume(snapshot(time: 31.2, eye: 0.30),
                                     calibration: calibration, now: 31.2)
        expect(tenHertz.estimatedBlinks.value == 1,
               "10 Hz observe le même clignement de 100 ms")
        expect(tenHertz.estimatedBlinks.quality == .good,
               "10 Hz atteint la qualité temporelle prévue")

        print("PostureEvaluatorsHarness: OK")
    }
}
