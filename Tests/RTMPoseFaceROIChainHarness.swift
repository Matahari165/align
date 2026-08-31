import CoreVideo
import Foundation

@main
private enum RTMPoseFaceROIChainHarness {
    final class CountingEngine: UpperBodyPoseEngine, @unchecked Sendable {
        let descriptor = UpperBodyEngineDescriptor(
            id: "counting.rtmpose-admission",
            displayName: "Admission RTMPose",
            version: "1",
            runtime: "test"
        )
        var generation: UInt64?
        var invocationCount = 0

        func activate(generation: UInt64) { self.generation = generation }

        func analyze(_ frame: UpperBodyFrame) -> UpperBodyEngineOutput {
            invocationCount += 1
            guard generation == frame.generation else {
                return .init(state: .stale, points: [], contours: [])
            }
            return .init(
                state: .detected,
                points: [UpperBodyPoint(
                    id: .leftShoulder,
                    location: CGPoint(x: 0.35, y: 0.55),
                    confidence: 0.8,
                    quality: .good,
                    provenance: .observed
                )],
                contours: [],
                regionOfInterest: frame.regionOfInterest
            )
        }

        func deactivate() { generation = nil }
    }

    final class TestClock: @unchecked Sendable {
        var now: TimeInterval
        init(_ now: TimeInterval) { self.now = now }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("RTMPoseFaceROIChainHarness: FAIL — \(message)\n", stderr)
            exit(1)
        }
    }

    static func frame(
        _ buffer: CVPixelBuffer,
        capturedAt: TimeInterval,
        sampleID: UInt64,
        generation: UInt64,
        roi: UpperBodyRegionOfInterest?
    ) -> UpperBodyFrame {
        UpperBodyFrame(
            pixelBuffer: buffer,
            capturedAt: capturedAt,
            sampleID: sampleID,
            generation: generation,
            regionOfInterest: roi
        )
    }

    static func main() {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let pixelBuffer else { fatalError("pixel buffer") }

        let contour = [
            CGPoint(x: 0.42, y: 0.18), CGPoint(x: 0.58, y: 0.18),
            CGPoint(x: 0.61, y: 0.36), CGPoint(x: 0.39, y: 0.36)
        ]
        guard let faceROI = RTMPoseUpperBodyCropPolicy.faceAnchored(
            faceContour: contour,
            imageSize: CGSize(width: 1280, height: 720),
            capturedAt: 10.0,
            sampleID: 1,
            generation: 7
        ) else { fatalError("face ROI") }
        expect(faceROI.isAdmissible(forFrameCapturedAt: 10.0, generation: 7),
               "faceContour doit produire une ROI same-frame admissible")
        let epsilonROI = UpperBodyRegionOfInterest(
            rect: faceROI.rect,
            capturedAt: 10.0005,
            anchorCapturedAt: 10.0,
            anchorSampleID: 1,
            generation: 7,
            source: .recentFace
        )
        expect(epsilonROI.isAdmissible(
            forFrameCapturedAt: 10.0005, generation: 7
        ), "tout timestamp strictement ultérieur, même de 0,5 ms, doit être recentFace")
        let falselySameFrameROI = UpperBodyRegionOfInterest(
            rect: faceROI.rect,
            capturedAt: 10.0005,
            anchorCapturedAt: 10.0,
            anchorSampleID: 1,
            generation: 7,
            source: .sameFrameFace
        )
        expect(!falselySameFrameROI.isAdmissible(
            forFrameCapturedAt: 10.0005, generation: 7
        ), "sameFrameFace exige une égalité temporelle exacte")
        let pixelRatio = faceROI.rect.width * 1280 / (faceROI.rect.height * 720)
        expect(abs(pixelRatio - 192.0 / 256.0) < 0.000_01,
               "la ROI doit conserver le ratio pixel 192:256")

        let reorderedContour = [contour[2], contour[0], contour[3], contour[1]]
        let reorderedROI = RTMPoseUpperBodyCropPolicy.faceAnchored(
            faceContour: reorderedContour,
            imageSize: CGSize(width: 1280, height: 720),
            capturedAt: 10.0,
            sampleID: 1,
            generation: 7
        )
        expect(reorderedROI?.rect == faceROI.rect,
               "l’ordre/roll apparent du contour ne doit pas tourner la ROI")

        expect(RTMPoseUpperBodyCropPolicy.faceAnchored(
            faceContour: [CGPoint(x: .nan, y: 0.2)],
            imageSize: CGSize(width: 1280, height: 720),
            capturedAt: 10.0,
            sampleID: 2,
            generation: 7
        ) == nil, "un contour invalide doit être refusé")

        let clock = TestClock(10.0)
        let engine = CountingEngine()
        var session = UpperBodyEngineSession(
            engine: engine,
            clock: { clock.now }
        )
        session.activate(generation: 7)
        let accepted = session.analyze(frame(
            pixelBuffer, capturedAt: 10.0, sampleID: 1,
            generation: 7, roi: faceROI
        ))
        expect(accepted?.state == .detected && engine.invocationCount == 1,
               "la chaîne faceContour→ROI→frame doit atteindre le moteur une fois")

        clock.now = 10.1
        let missing = session.analyze(frame(
            pixelBuffer, capturedAt: 10.1, sampleID: 2,
            generation: 7, roi: nil
        ))
        expect(missing?.state == .partial && engine.invocationCount == 1,
               "sans contour/ROI, le moteur ne doit pas être invoqué")

        clock.now = 10.80
        let staleROI = UpperBodyRegionOfInterest(
            rect: faceROI.rect,
            capturedAt: 10.80,
            anchorCapturedAt: 10.0,
            anchorSampleID: 1,
            generation: 7,
            source: .recentFace
        )
        let stale = session.analyze(frame(
            pixelBuffer, capturedAt: 10.80, sampleID: 3,
            generation: 7, roi: staleROI
        ))
        expect(stale?.state == .partial && engine.invocationCount == 1,
               "un skew supérieur à 0,75 s doit produire zéro invocation")

        clock.now = 10.90
        let wrongGenerationROI = UpperBodyRegionOfInterest(
            rect: faceROI.rect,
            capturedAt: 10.90,
            anchorCapturedAt: 10.85,
            anchorSampleID: 3,
            generation: 6,
            source: .recentFace
        )
        let mismatched = session.analyze(frame(
            pixelBuffer, capturedAt: 10.90, sampleID: 4,
            generation: 7, roi: wrongGenerationROI
        ))
        expect(mismatched?.state == .partial && engine.invocationCount == 1,
               "une ROI d’ancienne génération doit produire zéro invocation")

        print("RTMPoseFaceROIChainHarness: OK")
    }
}
