import Foundation

@main
enum PostureIndicatorPresentationHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func result(
        _ id: PostureIndicatorID,
        state: PostureIndicatorState,
        quality: PostureSignalQuality = .good,
        observedAt: TimeInterval? = 10,
        baseline: Bool = true,
        experimental: Bool = false,
        ttl: TimeInterval = 0.75,
        classification: PostureShoulderRaiseClassification? = nil
    ) -> PostureIndicatorResult {
        .init(
            id: id, state: state, count: nil, observedAt: observedAt,
            quality: quality, hasValidBaseline: baseline,
            isExperimental: experimental, freshnessTTL: ttl,
            shoulderRaiseClassification: classification
        )
    }

    static func main() {
        let now = 10.5
        let normal = PostureIndicatorPresentation.make(
            for: result(.apparentProximity, state: .normal), producedAt: now
        )
        expect(normal.tone == .positive && normal.value == "Dans ton repère",
               "une preuve canonique fraîche doit être présentée normalement")

        let attention = PostureIndicatorPresentation.make(
            for: result(
                .raisedShoulders, state: .attention, ttl: 2,
                classification: .unilateralRight
            ),
            producedAt: now
        )
        expect(attention.tone == .negative && attention.value == "Épaule droite relevée",
               "l'attention épaules doit distinguer le côté")

        let bodyStillFresh = PostureIndicatorPresentation.make(
            for: result(.torsoInclination, state: .normal, observedAt: 9, ttl: 2),
            producedAt: now
        )
        expect(bodyStillFresh.value == "Dans ton repère",
               "le TTL corps ne doit pas être remplacé par le TTL visage")

        for unreliable in [
            result(.apparentProximity, state: .normal, quality: .limited),
            result(.apparentProximity, state: .attention, observedAt: nil),
            result(.apparentProximity, state: .normal, observedAt: 9),
            result(.raisedShoulders, state: .attention, baseline: false, ttl: 2)
        ] {
            let presentation = PostureIndicatorPresentation.make(
                for: unreliable, producedAt: now
            )
            expect(presentation.tone == .neutral && presentation.value == "—",
                   "une preuve partielle, absente ou périmée doit rester neutre")
        }

        let observing = PostureIndicatorPresentation.make(
            for: result(.torsoInclination, state: .pending, ttl: 2), producedAt: now
        )
        expect(observing.value == "Observation…",
               "une preuve fraîche en transition ne doit pas afficher Données insuffisantes")

        let slope = PostureIndicatorPresentation.make(
            for: result(.shoulderSlope, state: .attention, experimental: true, ttl: 2),
            producedAt: now
        )
        let opening = PostureIndicatorPresentation.make(
            for: result(.closedShoulders, state: .attention, experimental: true, ttl: 2),
            producedAt: now
        )
        expect(slope.tone == .neutral && slope.value == "Plus inclinées",
               "la pente expérimentale doit rester visible sans force d'alerte")
        expect(opening.tone == .neutral && opening.value == "Plus refermées",
               "l'ouverture expérimentale doit rester visible sans force d'alerte")

        let blink = PostureIndicatorPresentation.make(
            for: result(.estimatedBlinks, state: .attention, experimental: true),
            producedAt: now
        )
        expect(blink.tone == .negative && blink.value == "Sous ton repère",
               "l'alerte canonique clignements doit rester actionnable et honnête")

        expect(PostureIndicatorPresentation.orderedIDs == [
            .apparentProximity, .torsoInclination, .raisedShoulders,
            .shoulderSlope, .estimatedBlinks, .closedShoulders
        ], "l'ordre du rail doit rester stable")
        print("PostureIndicatorPresentationHarness: OK")
    }
}
