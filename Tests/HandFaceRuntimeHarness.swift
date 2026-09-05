import Foundation

@main private enum HandFaceRuntimeHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func sample(
        generation: UInt64 = 1,
        sampleID: UInt64,
        at time: TimeInterval,
        distance: Double
    ) -> HandFaceContactSample {
        .init(
            generation: generation,
            sampleID: sampleID,
            capturedAt: time,
            contextKey: "camera-a",
            observation: .init(
                observedAt: time,
                distanceRatio: distance,
                quality: .good,
                isContact: distance <= 0.20,
                zone: .mouth,
                handIndex: 0,
                landmark: .indexFinger
            )
        )
    }

    static func main() {
        var runtime = PostureRuntimeCoordinator()
        runtime.reset(generation: 1, contextKey: "camera-a")

        let first = runtime.consumeHandFace(sample(sampleID: 1, at: 0, distance: 0.10), now: 0)
        expect(first?.signal(.handOnFace).availability == .observing,
               "un premier contact doit seulement commencer l'observation")
        _ = runtime.consumeHandFace(
            sample(sampleID: 2, at: 0.3, distance: 0.10), now: 0.3
        )
        _ = runtime.consumeHandFace(
            sample(sampleID: 3, at: 0.6, distance: 0.10), now: 0.6
        )
        let oneSecond = runtime.consumeHandFace(
            sample(sampleID: 4, at: 0.9, distance: 0.10), now: 0.9
        )
        expect(oneSecond?.signal(.handOnFace).assessment == nil,
               "une seconde ne doit pas devenir une attention")
        for index in 4...8 {
            let time = Double(index) * 0.3
            _ = runtime.consumeHandFace(
                sample(sampleID: UInt64(index + 1), at: time, distance: 0.10), now: time
            )
        }
        let stillBeforeThreshold = runtime.consumeHandFace(
            sample(sampleID: 10, at: 2.49, distance: 0.10), now: 2.49
        )
        expect(stillBeforeThreshold?.signal(.handOnFace).assessment == nil,
               "2,5 secondes ne doivent pas être franchies prématurément")
        let alerted = runtime.consumeHandFace(
            sample(sampleID: 11, at: 2.5, distance: 0.10), now: 2.5
        )
        expect(alerted?.signal(.handOnFace).assessment == .attention,
               "le runtime doit publier l'attention après 2,5 secondes")

        let hysteresis = runtime.consumeHandFace(
            sample(sampleID: 12, at: 2.6, distance: 0.25), now: 2.6
        )
        expect(hysteresis?.signal(.handOnFace).assessment == .attention,
               "la sortie reste tolérante dans la zone d'hystérésis")
        let separated = runtime.consumeHandFace(
            sample(sampleID: 13, at: 2.7, distance: 0.31), now: 2.7
        )
        expect(separated?.signal(.handOnFace).assessment == .withinReference,
               "une séparation au-delà du seuil doit fermer l'épisode")

        runtime.reset(generation: 2, contextKey: "camera-a")
        var secondAlert: PostureObservationsSnapshot?
        for index in 0...8 {
            let time = 20 + Double(index) * 0.3
            secondAlert = runtime.consumeHandFace(
                sample(generation: 2, sampleID: UInt64(index + 1), at: time, distance: 0.10),
                now: time
            )
        }
        secondAlert = runtime.consumeHandFace(
            sample(generation: 2, sampleID: 10, at: 22.5, distance: 0.10), now: 22.5
        )
        expect(secondAlert?.signal(.handOnFace).assessment == .attention,
               "un nouvel épisode peut notifier après une nouvelle persistance")
        print("HandFaceRuntimeHarness: OK")
    }
}
