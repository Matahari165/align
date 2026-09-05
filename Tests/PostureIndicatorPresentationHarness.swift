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
        expect(slope.tone == .negative && slope.value == "Une épaule plus haute",
               "un déséquilibre fiable doit maintenant permettre un rappel")
        expect(opening.tone == .negative && opening.value == "À réajuster",
               "le rapport tête-épaules doit proposer une action sans affirmer sa cause")

        let blink = PostureIndicatorPresentation.make(
            for: result(.estimatedBlinks, state: .attention, experimental: true),
            producedAt: now
        )
        expect(blink.tone == .negative && blink.value == "Pense à cligner",
               "l'alerte canonique clignements doit rester actionnable et honnête")

        expect(PostureIndicatorPresentation.orderedIDs == [
            .shoulderSlope, .raisedShoulders, .headTilt, .closedShoulders,
            .apparentProximity, .torsoInclination, .estimatedBlinks, .handOnFace
        ], "l'ordre du rail doit rester stable")

        var head = result(.headTilt, state: .attention, ttl: 2)
        head.referenceDelta = 8
        let headPresentation = PostureIndicatorPresentation.make(for: head, producedAt: now)
        expect(headPresentation.value.contains("+8.0°") && headPresentation.tone == .negative,
               "l'écart angulaire personnel doit être lisible")
        let expiredHead = PostureIndicatorPresentation.make(for: head, producedAt: 13)
        expect(expiredHead.value == "—", "un angle périmé doit disparaître")

        var learning = result(.estimatedBlinks, state: .needsCalibration, baseline: false)
        learning.numericValue = 8
        let learningPresentation = PostureIndicatorPresentation.make(for: learning, producedAt: now)
        expect(learningPresentation.value.contains("8.0/min") &&
               learningPresentation.value.contains("repère en cours") &&
               learningPresentation.tone == .neutral,
               "un taux observable sans référence ne signifie pas que les clignements suffisent")
        expect(PostureIndicatorPresentation.make(for: learning, producedAt: 12).value == "Yeux non mesurables",
               "un ancien taux ne doit pas survivre pendant l'apprentissage")
        var collecting = result(.estimatedBlinks, state: .needsCalibration,
                                quality: .limited, baseline: false)
        collecting.reason = "Yeux observés : 12/45 s"
        expect(PostureIndicatorPresentation.make(for: collecting, producedAt: now).value == collecting.reason,
               "la collecte doit expliquer sa progression sans prétendre mesurer un taux")
        expect(PostureIndicatorPresentation.make(for: collecting, producedAt: 12).value == "Yeux non mesurables",
               "une progression périmée ne doit pas rester affichée")
        collecting.reason = "camera-context-internal"
        expect(PostureIndicatorPresentation.make(for: collecting, producedAt: now).value == "Yeux non mesurables",
               "une raison technique ne doit pas fuir dans le rail produit")
        print("PostureIndicatorPresentationHarness: OK")
    }
}
