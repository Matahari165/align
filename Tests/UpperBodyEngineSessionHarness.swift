import CoreVideo
import Foundation

@main
private enum UpperBodyEngineSessionHarness {
    final class TestClock: @unchecked Sendable {
        var now: TimeInterval
        init(_ now: TimeInterval) { self.now = now }
        func read() -> TimeInterval { now }
    }

    final class FakeEngine: UpperBodyPoseEngine, @unchecked Sendable {
        let descriptor = UpperBodyEngineDescriptor(
            id: "fake.upper-body", displayName: "Fake", version: "1", runtime: "test"
        )
        var activeGeneration: UInt64?
        var activations = 0
        var deactivations = 0
        var analyses = 0
        var output = UpperBodyEngineOutput(state: .detected, points: [], contours: [])
        var onAnalyze: (() -> Void)?

        func activate(generation: UInt64) {
            activeGeneration = generation
            activations += 1
        }

        func analyze(_ frame: UpperBodyFrame) -> UpperBodyEngineOutput {
            analyses += 1
            onAnalyze?()
            return activeGeneration == frame.generation
                ? output
                : .init(state: .stale, points: [], contours: [])
        }

        func deactivate() {
            activeGeneration = nil
            deactivations += 1
        }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("UpperBodyEngineSessionHarness: FAIL — \(message)\n", stderr)
            exit(1)
        }
    }

    static func point(_ id: UpperBodyLandmarkID, _ x: CGFloat, _ y: CGFloat) -> UpperBodyPoint {
        UpperBodyPoint(
            id: id, location: CGPoint(x: x, y: y), confidence: 0.9,
            quality: .good, provenance: .observed
        )
    }

    static func frame(
        _ pixelBuffer: CVPixelBuffer,
        generation: UInt64,
        timestamp: TimeInterval,
        sampleID: UInt64,
        regionOfInterest: UpperBodyRegionOfInterest? = nil
    ) -> UpperBodyFrame {
        UpperBodyFrame(
            pixelBuffer: pixelBuffer,
            capturedAt: timestamp,
            sampleID: sampleID,
            generation: generation,
            regionOfInterest: regionOfInterest
        )
    }

    static func main() {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { fatalError("pixel buffer") }

        let fake = FakeEngine()
        let testROI = UpperBodyRegionOfInterest(
            rect: CGRect(x: 0.20, y: 0.10, width: 0.50, height: 0.80),
            capturedAt: 10.0,
            anchorCapturedAt: 10.0,
            anchorSampleID: 3,
            generation: 7,
            source: .sameFrameFace
        )
        fake.output = .init(state: .detected, points: [
            point(.nose, 0.50, 0.88), point(.neck, 0.50, 0.68),
            point(.leftEar, 0.40, 0.78), point(.rightEar, 0.60, 0.78),
            point(.leftShoulder, 0.32, 0.60), point(.rightShoulder, 0.68, 0.58),
            point(.leftElbow, 0.24, 0.43), point(.rightElbow, 0.76, 0.43),
            point(.leftHip, 0.38, 0.28), point(.rightHip, 0.62, 0.28)
        ], contours: [UpperBodyContour(
            name: "silhouette-test",
            locations: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2)],
            isClosed: false
        )], diagnostics: UpperBodyEngineDiagnostics(
            validLandmarkCount: 10,
            simCCMinimum: -0.25,
            simCCMaximum: 0.42,
            scoreMinimum: 0.06,
            scoreMaximum: 0.29,
            leftShoulderScore: 0.19,
            rightShoulderScore: 0.12
        ))

        let clock = TestClock(10.02)
        var session = UpperBodyEngineSession(
            engine: fake,
            maximumAge: 0.30,
            clock: { clock.read() }
        )
        session.activate(generation: 7)
        expect(fake.activations == 1 && fake.deactivations == 1,
               "l’activation purge toujours le moteur avant usage")

        let accepted = session.analyze(
            frame(
                buffer, generation: 7, timestamp: 10, sampleID: 1,
                regionOfInterest: testROI
            )
        )
        expect(accepted?.state == .detected && fake.analyses == 1,
               "la génération active doit produire exactement une analyse")
        expect(accepted?.diagnostics?.leftShoulderScore == 0.19 &&
                accepted?.diagnostics?.rightShoulderScore == 0.12,
               "les scores bruts sous seuil doivent traverser la session sans valider de point")
        let missingROI = session.analyze(frame(
            buffer, generation: 7, timestamp: 10.01, sampleID: 2
        ))
        expect(missingROI?.state == .partial && fake.analyses == 1 &&
                session.currentResult == nil,
               "une ROI absente doit vider la géométrie sans appeler le moteur")
        let wrongGenerationROI = UpperBodyRegionOfInterest(
            rect: testROI.rect,
            capturedAt: 10.02,
            anchorCapturedAt: 10.0,
            anchorSampleID: 4,
            generation: 6,
            source: .recentFace
        )
        let rejectedGenerationROI = session.analyze(frame(
            buffer, generation: 7, timestamp: 10.02, sampleID: 3,
            regionOfInterest: wrongGenerationROI
        ))
        expect(rejectedGenerationROI?.state == .partial && fake.analyses == 1,
               "une ROI d’ancienne génération ne doit pas atteindre le moteur")
        let staleROI = UpperBodyRegionOfInterest(
            rect: testROI.rect,
            capturedAt: 10.80,
            anchorCapturedAt: 10.0,
            anchorSampleID: 5,
            generation: 7,
            source: .recentFace
        )
        clock.now = 10.80
        let rejectedStaleROI = session.analyze(frame(
            buffer, generation: 7, timestamp: 10.80, sampleID: 4,
            regionOfInterest: staleROI
        ))
        expect(rejectedStaleROI?.state == .partial && fake.analyses == 1,
               "une ancre au-delà du skew doit être refusée avant le moteur")
        clock.now = 10.02
        expect(session.analyze(frame(
            buffer, generation: 6, timestamp: 10.03, sampleID: 5
        )) == nil && fake.analyses == 1 &&
               session.lastRejectionReason == .generationMismatch,
               "une ancienne génération doit être inerte avec une raison typée")
        clock.now = 10.80
        let duplicateResult = session.analyze(frame(
            buffer, generation: 7, timestamp: 10.80, sampleID: 4,
            regionOfInterest: staleROI
        ))
        expect(duplicateResult == nil && fake.analyses == 1 &&
               session.lastRejectionReason == .duplicateFrame,
               "un doublon ne doit pas atteindre le moteur et doit être diagnostiqué")
        clock.now = 10.51
        expect(session.analyze(frame(
            buffer, generation: 7, timestamp: 10.2, sampleID: 6,
            regionOfInterest: testROI
        )) == nil && fake.analyses == 1,
               "une frame déjà plus vieille que le TTL doit être rejetée avant inférence")

        guard let accepted else { fatalError("accepted result") }
        expect(abs((session.expirationDelay(for: accepted, at: 10.02) ?? 0) - 0.28) < 0.000_001,
               "l’expiration doit viser capturedAt + TTL, pas producedAt + TTL")
        let product = ProductUpperBodyOverlayBuilder.make(
            from: accepted, at: 10.02, maximumAge: 0.30
        )
        expect(product.points.count == 2 && product.polylines.count == 1,
               "le produit reste limité aux deux épaules et leur ligne")
        let debug = DevelopmentUpperBodyOverlayBuilder.make(
            from: accepted, at: 10.02, maximumAge: 0.30
        )
        expect(debug.points.count == 10,
               "le développement expose uniquement les repères réellement observés")
        expect(debug.points.contains { $0.name == "BASE DU COU" },
               "le landmark Halpe26 observé doit porter le libellé exact BASE DU COU")
        expect(DevelopmentUpperBodyOverlayBuilder.summary(for: accepted, at: 10.02)
            .hasPrefix("Haut du corps · prêt"),
               "deux épaules cohérentes et fraîches doivent produire l’état prêt")
        expect(debug.polylines.contains { $0.name == "Torse · axe central (dérivé)" },
               "l’axe du torse exige épaules et hanches de la même frame")
        expect(!debug.polylines.contains { $0.source == .silhouette },
               "la silhouette doit rester masquée par défaut")
        let debugWithSilhouette = DevelopmentUpperBodyOverlayBuilder.make(
            from: accepted,
            at: 10.02,
            maximumAge: 0.30,
            options: .init(showsLandmarks: false, showsConnections: false, showsAxes: false,
                           showsSilhouette: true, showsValues: false,
                           showsTrace: false, showsROI: false)
        )
        expect(debugWithSilhouette.polylines.contains { $0.source == .silhouette },
               "la silhouette réelle reste disponible derrière son option interne")
        let debugWithROI = DevelopmentUpperBodyOverlayBuilder.make(
            from: accepted,
            at: 10.02,
            maximumAge: 0.30,
            options: .init(showsLandmarks: false, showsConnections: false, showsAxes: false,
                           showsSilhouette: false, showsValues: false,
                           showsTrace: false, showsROI: true)
        )
        expect(debugWithROI.polylines.count == 1 &&
               debugWithROI.polylines.first?.name == "RTMPose ROI" &&
               debugWithROI.polylines.first?.isClosed == true,
               "le rectangle ROI ne doit apparaître qu’en diagnostic explicite")
        let noAxes = DevelopmentUpperBodyOverlayBuilder.make(
            from: accepted,
            at: 10.02,
            maximumAge: 0.30,
            options: .init(showsLandmarks: true, showsConnections: false, showsAxes: false,
                           showsSilhouette: false, showsValues: true,
                           showsTrace: false, showsROI: false)
        )
        expect(noAxes.polylines.isEmpty,
               "désactiver Connexions, Axes et Silhouette doit retirer toutes les polylignes debug")
        let connectionsOnly = DevelopmentUpperBodyOverlayBuilder.make(
            from: accepted,
            at: 10.02,
            maximumAge: 0.30,
            options: .init(showsLandmarks: false, showsConnections: true, showsAxes: false,
                           showsSilhouette: false, showsValues: false,
                           showsTrace: false, showsROI: false)
        )
        expect(connectionsOnly.polylines.contains { $0.name == "ligne-épaules" } &&
               !connectionsOnly.polylines.contains { $0.name.contains("axe-") },
               "les connexions doivent pouvoir être inspectées sans axes dérivés")
        let axesOnly = DevelopmentUpperBodyOverlayBuilder.make(
            from: accepted,
            at: 10.02,
            maximumAge: 0.30,
            options: .init(showsLandmarks: false, showsConnections: false, showsAxes: true,
                           showsSilhouette: false, showsValues: false,
                           showsTrace: false, showsROI: false)
        )
        expect(axesOnly.polylines.map(\.name).sorted() ==
               ["Torse · axe central (dérivé)", "Tête · ligne des oreilles"].sorted(),
               "les axes tête et torse doivent être séparés des connexions")

        let partialAtLeftEdge = UpperBodyResult(
            descriptor: accepted.descriptor,
            state: .partial,
            generation: accepted.generation,
            sampleID: accepted.sampleID + 1,
            capturedAt: accepted.capturedAt,
            producedAt: accepted.producedAt,
            points: [UpperBodyPoint(
                id: .leftShoulder,
                location: CGPoint(x: 0.02, y: 0.55),
                confidence: 0.45,
                quality: .limited,
                provenance: .observed
            )],
            contours: [],
            regionOfInterest: accepted.regionOfInterest
        )
        let partialSummary = DevelopmentUpperBodyOverlayBuilder.summary(
            for: partialAtLeftEdge, at: 10.02
        )
        expect(partialSummary ==
               "Haut du corps · partiel · épaule droite absente · bord gauche",
               "le résumé doit dériver le côté absent et le bord des points réellement présents")
        let partialOverlay = DevelopmentUpperBodyOverlayBuilder.make(
            from: partialAtLeftEdge, at: 10.02
        )
        expect(partialOverlay.points.count == 1 && partialOverlay.points[0].isLimited,
               "un point partiel limité doit rester visible avec une forme distincte")
        expect(ProductUpperBodyOverlayBuilder.make(
            from: accepted, at: 10.31, maximumAge: 0.30
        ).points.isEmpty,
               "un toggle retardé ne doit jamais ressusciter des coordonnées hors TTL")

        let refreshedROI = UpperBodyRegionOfInterest(
            rect: testROI.rect,
            capturedAt: 11.0,
            anchorCapturedAt: 11.0,
            anchorSampleID: 6,
            generation: 7,
            source: .sameFrameFace
        )
        clock.now = 11.02
        expect(session.analyze(frame(
            buffer, generation: 7, timestamp: 11.0, sampleID: 7,
            regionOfInterest: refreshedROI
        ))?.state == .detected && fake.analyses == 2,
               "une nouvelle ROI fraîche doit réactiver la géométrie")
        expect(session.expire(at: 11.29, generation: 7) == nil,
               "une géométrie fraîche ne doit pas expirer trop tôt")
        let expired = session.expire(at: 11.30, generation: 7)
        expect(expired?.state == .expired && expired?.points.isEmpty == true,
               "l’expiration purge immédiatement les coordonnées")

        session.activate(generation: 8)
        expect(fake.activations == 2 && fake.deactivations == 2,
               "un changement de génération détruit l’ancienne activation")
        session.deactivate()
        expect(fake.activeGeneration == nil && session.currentResult == nil,
               "stop purge moteur et résultat")

        let slowClock = TestClock(20.0)
        let slowEngine = FakeEngine()
        slowEngine.output = .init(state: .detected, points: [
            point(.leftShoulder, 0.3, 0.6), point(.rightShoulder, 0.7, 0.6)
        ], contours: [])
        // The injected clock models admission before inference and completion
        // after a 0.31 s engine call, without sleeping in the harness.
        slowEngine.onAnalyze = { slowClock.now = 20.31 }
        var slowSession = UpperBodyEngineSession(
            engine: slowEngine,
            maximumAge: 0.30,
            clock: { slowClock.read() }
        )
        slowSession.activate(generation: 9)
        let slowROI = UpperBodyRegionOfInterest(
            rect: testROI.rect,
            capturedAt: 20.0,
            anchorCapturedAt: 20.0,
            anchorSampleID: 1,
            generation: 9,
            source: .sameFrameFace
        )
        expect(slowSession.analyze(frame(
            buffer, generation: 9, timestamp: 20.0, sampleID: 1,
            regionOfInterest: slowROI
        )) == nil && slowSession.lastRejectionReason == .postInferenceExpired,
               "une inférence lente au-delà du TTL doit être rejetée après son retour")
        expect(slowSession.currentResult == nil,
               "une inférence lente ne doit conserver aucune géométrie")
        expect(slowSession.admissionDiagnostics.engineRuns == 1 &&
                abs((slowSession.admissionDiagnostics.lastEngineDuration ?? 0) - 0.31) < 0.000_001 &&
                slowSession.admissionDiagnostics.rejectionCounts[.postInferenceExpired] == 1,
               "la durée brute et le compteur post-inférence doivent rester visibles après expiration")

        // Regression guard for the live symptom (hundreds of attempts but a
        // single accepted result): with a canonical monotonic clock and
        // strictly increasing sample timestamps, every fresh frame is
        // admitted and reaches the engine. This also proves that the
        // watermark is not accidentally global across activations.
        let streamClock = TestClock(30.01)
        let streamEngine = FakeEngine()
        streamEngine.output = .init(state: .partial, points: [
            point(.leftShoulder, 0.3, 0.6)
        ], contours: [])
        var streamSession = UpperBodyEngineSession(
            engine: streamEngine,
            maximumAge: 1.2,
            clock: { streamClock.read() }
        )
        streamSession.activate(generation: 42)
        expect(streamSession.activeGeneration == 42 &&
                streamSession.admissionDiagnostics.attempts == 0 &&
                streamSession.admissionDiagnostics.engineRuns == 0,
               "une activation doit publier la génération et remettre les compteurs à zéro")
        var acceptedCount = 0
        for index in 0..<604 {
            let capturedAt = 30.0 + Double(index) * 0.01
            streamClock.now = capturedAt + 0.01
            let roi = UpperBodyRegionOfInterest(
                rect: testROI.rect,
                capturedAt: capturedAt,
                anchorCapturedAt: capturedAt,
                anchorSampleID: UInt64(index + 1),
                generation: 42,
                source: .sameFrameFace
            )
            if streamSession.analyze(frame(
                buffer, generation: 42, timestamp: capturedAt,
                sampleID: UInt64(index + 1), regionOfInterest: roi
            )) != nil {
                acceptedCount += 1
            }
        }
        expect(acceptedCount == 604 && streamEngine.analyses == 604 &&
               streamSession.lastRejectionReason == nil,
               "604 frames fraîches doivent toutes atteindre l’unique moteur")

        let slowStreamClock = TestClock(60.0)
        let slowStreamEngine = FakeEngine()
        slowStreamEngine.output = streamEngine.output
        slowStreamEngine.onAnalyze = { slowStreamClock.now += 1.31 }
        var slowStreamSession = UpperBodyEngineSession(
            engine: slowStreamEngine,
            maximumAge: 1.2,
            clock: { slowStreamClock.read() }
        )
        slowStreamSession.activate(generation: 43)
        // One initial ROI miss is a legitimate partial result; subsequent
        // calls model a slow native inference and must be visible as
        // post-inference expirations rather than an opaque "rejected" state.
        slowStreamClock.now = 60.0
        expect(slowStreamSession.analyze(frame(
            buffer, generation: 43, timestamp: 60.0, sampleID: 1
        ))?.state == .partial, "une ROI absente reste un résultat partiel")
        for index in 1...603 {
            let capturedAt = 62.0 + Double(index - 1) * 2.0
            slowStreamClock.now = capturedAt
            let roi = UpperBodyRegionOfInterest(
                rect: testROI.rect,
                capturedAt: capturedAt,
                anchorCapturedAt: capturedAt,
                anchorSampleID: UInt64(index + 1),
                generation: 43,
                source: .sameFrameFace
            )
            expect(slowStreamSession.analyze(frame(
                buffer, generation: 43, timestamp: capturedAt,
                sampleID: UInt64(index + 1), regionOfInterest: roi
            )) == nil, "une inférence lente doit être expirée après son retour")
        }
        expect(slowStreamSession.returnedResults == 1 &&
               slowStreamSession.engineRuns == 603 &&
               slowStreamSession.rejectionCounts[.postInferenceExpired] == 603 &&
               slowStreamSession.lastRejectionReason == .postInferenceExpired,
               "604 tentatives avec moteur lent doivent exposer une seule sortie partielle et 603 rejets TTL")

        print("UpperBodyEngineSessionHarness: OK")
    }
}
