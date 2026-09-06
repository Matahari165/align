import Foundation

@main
private enum PostureAlertCoordinatorHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func signal(
        _ id: PostureObservationSignalID,
        assessment: PostureObservationAssessment? = .attention,
        episode: UInt64? = 1,
        at time: TimeInterval,
        availability: PostureObservationAvailability = .available,
        quality: PostureObservationQuality = .good,
        observedAt: TimeInterval? = nil
    ) -> PostureSignalSnapshot {
        .init(signalID: id, generation: 1, availability: availability,
              assessment: assessment, quality: quality,
              observedAt: observedAt ?? time, producedAt: time,
              episodeID: episode, reason: nil)
    }

    static func snapshot(
        _ values: [PostureSignalSnapshot],
        at time: TimeInterval,
        contextKey: String = "camera-a"
    ) -> PostureObservationsSnapshot {
        .init(generation: 1, contextKey: contextKey, producedAt: time, signals: values)
    }

    static func coordinator(
        _ ids: [PostureObservationSignalID],
        config: PostureSignalAlertConfiguration,
        minimumInterval: TimeInterval = 1,
        dailyMaximum: Int = 20
    ) -> PostureAlertCoordinator {
        PostureAlertCoordinator(
            signalConfigurations: Dictionary(uniqueKeysWithValues: ids.map { ($0, config) }),
            globalConfiguration: .init(
                mode: .validation,
                minimumIntervalBetweenSignals: minimumInterval,
                dailyMaximum: dailyMaximum,
                dailyWindow: 100
            )
        )
    }

    static func main() {
        let config = PostureSignalAlertConfiguration(
            persistence: 2, recovery: 3, cooldown: 5, dailyMaximum: 2
        )

        // Persistence, priority, global spacing, recovery, snooze and reactivation.
        var basic = coordinator(PostureObservationSignalID.allCases, config: config,
                                minimumInterval: 4, dailyMaximum: 3)
        let bothAt0 = snapshot([
            signal(.torsoInclination, at: 0),
            signal(.proximity, at: 0)
        ], at: 0)
        expect(basic.consume(bothAt0, now: 0) == nil,
               "la persistance doit précéder l’alerte")

        let bothAt2 = snapshot([
            signal(.torsoInclination, at: 2),
            signal(.proximity, at: 2)
        ], at: 2)
        let first = basic.consume(bothAt2, now: 2)
        expect(first?.signalID == .proximity,
               "l’arbitre doit sélectionner une seule alerte selon la priorité")
        expect(first?.identifier == "posture.proximity.g1.e1.r1",
               "l’identifiant doit distinguer la réservation précise")
        if let first {
            expect(basic.commitDelivery(first, now: 2),
                   "la livraison doit confirmer la réservation")
        }

        let bothAt3 = snapshot([
            signal(.torsoInclination, at: 3),
            signal(.proximity, at: 3)
        ], at: 3)
        expect(basic.consume(bothAt3, now: 3) == nil,
               "l’intervalle global doit espacer les rappels")

        let recoveredAt4 = snapshot([
            signal(.proximity, assessment: .withinReference, episode: nil, at: 4)
        ], at: 4)
        _ = basic.consume(recoveredAt4, now: 4)
        let recoveredAt7 = snapshot([
            signal(.proximity, assessment: .withinReference, episode: nil, at: 7)
        ], at: 7)
        _ = basic.consume(recoveredAt7, now: 7)
        let secondEpisodeAt8 = snapshot([
            signal(.proximity, episode: 2, at: 8)
        ], at: 8)
        expect(basic.consume(secondEpisodeAt8, now: 8) == nil,
               "un nouvel épisode doit satisfaire sa propre persistance")
        let secondEpisodeAt10 = snapshot([
            signal(.proximity, episode: 2, at: 10)
        ], at: 10)
        let second = basic.consume(secondEpisodeAt10, now: 10)
        expect(second?.episodeID == 2,
               "récupération, cooldown et persistance permettent un nouvel épisode")
        if let second {
            expect(basic.commitDelivery(second, now: 10),
                   "le second épisode doit être confirmé")
        }

        basic.snooze(.torsoInclination, until: 20)
        let torsoAt11 = snapshot([
            signal(.torsoInclination, episode: 3, at: 11)
        ], at: 11)
        _ = basic.consume(torsoAt11, now: 11)
        let torsoAt14 = snapshot([
            signal(.torsoInclination, episode: 3, at: 14)
        ], at: 14)
        expect(basic.consume(torsoAt14, now: 14) == nil,
               "le snooze doit supprimer uniquement le signal concerné")

        basic.setEnabled(false, for: .estimatedBlinks)
        let blinkAt20 = snapshot([
            signal(.estimatedBlinks, episode: 4, at: 20)
        ], at: 20)
        _ = basic.consume(blinkAt20, now: 20)
        let blinkAt23 = snapshot([
            signal(.estimatedBlinks, episode: 4, at: 23)
        ], at: 23)
        expect(basic.consume(blinkAt23, now: 23) == nil,
               "la désactivation d’un rappel ne doit pas émettre")
        basic.reactivate(.estimatedBlinks)
        let blinkAt24 = snapshot([
            signal(.estimatedBlinks, episode: 4, at: 24)
        ], at: 24)
        _ = basic.consume(blinkAt24, now: 24)
        let blinkAt26 = snapshot([
            signal(.estimatedBlinks, episode: 4, at: 26)
        ], at: 26)
        let blinkCandidate = basic.consume(blinkAt26, now: 26)
        expect(blinkCandidate?.signalID == .estimatedBlinks,
               "la réactivation doit restaurer uniquement le signal choisi")
        if let blinkCandidate {
            expect(basic.commitDelivery(blinkCandidate, now: 26),
                   "le rappel clignements doit être confirmable")
        }

        basic.snooze(.raisedShoulders, choice: .untilReactivation,
                     now: Date(timeIntervalSince1970: 30))
        expect(basic.controls[.raisedShoulders]?.isSnoozedUntilReactivation == true,
               "Jusqu’à réactivation doit être distinct d’une échéance absente")

        // Same persistent episode may repeat after its cooldown. A late async
        // completion for the first reservation must not claim the second one.
        var repeated = coordinator([.proximity], config: config)
        _ = repeated.consume(snapshot([signal(.proximity, episode: 9, at: 0)], at: 0), now: 0)
        guard let firstReservation = repeated.consume(
            snapshot([signal(.proximity, episode: 9, at: 2)], at: 2), now: 2
        ) else { fatalError("la première réservation doit exister") }
        expect(repeated.commitDelivery(firstReservation, now: 2),
               "la première livraison doit être confirmée")
        expect(repeated.consume(
            snapshot([signal(.proximity, episode: 9, at: 3)], at: 3), now: 3
        ) == nil, "le cooldown par signal doit s’appliquer")
        guard let secondReservation = repeated.consume(
            snapshot([signal(.proximity, episode: 9, at: 8)], at: 8), now: 8
        ) else { fatalError("la répétition après cooldown doit exister") }
        expect(secondReservation.episodeID == firstReservation.episodeID &&
               secondReservation.reservationID != firstReservation.reservationID,
               "un même épisode doit recevoir des réservations distinctes")
        expect(!repeated.ownsReservation(firstReservation, now: 8),
               "une livraison asynchrone ancienne ne doit plus posséder la réservation")
        expect(!repeated.commitDelivery(firstReservation, now: 8),
               "une livraison asynchrone ancienne ne doit pas consommer le quota")
        expect(repeated.commitDelivery(secondReservation, now: 8),
               "la nouvelle réservation doit rester livrable")

        // A reservation is valid only while the latest reliable proof remains
        // current. This covers a real invalid tick, silence past the TTL, and
        // a renewed proof for the same episode while delivery is in flight.
        var invalidated = coordinator([.proximity], config: config)
        _ = invalidated.consume(snapshot([signal(.proximity, at: 0)], at: 0), now: 0)
        guard let invalidatedCandidate = invalidated.consume(
            snapshot([signal(.proximity, at: 2)], at: 2), now: 2
        ) else { fatalError("la réservation à invalider doit exister") }
        _ = invalidated.consume(snapshot([
            signal(.proximity, assessment: nil, episode: nil, at: 2.1,
                   availability: .insufficient, quality: .unavailable)
        ], at: 2.1), now: 2.1)
        expect(!invalidated.ownsReservation(invalidatedCandidate, now: 2.1),
               "une preuve devenue indisponible doit invalider la réservation")
        expect(!invalidated.commitDelivery(invalidatedCandidate, now: 2.1),
               "une réservation invalidée ne doit pas être confirmée")

        var delayedDelivery = coordinator([.estimatedBlinks], config: config)
        _ = delayedDelivery.consume(snapshot([signal(.estimatedBlinks, at: 0)], at: 0), now: 0)
        guard let delayedCandidate = delayedDelivery.consume(
            snapshot([signal(.estimatedBlinks, at: 2)], at: 2), now: 2
        ) else { fatalError("la réservation blink doit exister") }
        expect(delayedDelivery.ownsReservation(delayedCandidate, now: 3.5),
               "un délai d'autorisation ou de livraison de quelques secondes doit rester livrable")
        expect(delayedDelivery.commitDelivery(delayedCandidate, now: 3.5),
               "un rappel blink valide doit être confirmable après un délai asynchrone")

        var expired = coordinator([.proximity], config: config)
        _ = expired.consume(snapshot([signal(.proximity, at: 0)], at: 0), now: 0)
        guard let expiredCandidate = expired.consume(
            snapshot([signal(.proximity, at: 2)], at: 2), now: 2
        ) else { fatalError("la réservation à expirer doit exister") }
        expect(!expired.ownsReservation(expiredCandidate, now: 7.1),
               "un silence prolongé au-delà du bail de livraison doit invalider la réservation")
        expect(!expired.commitDelivery(expiredCandidate, now: 7.1),
               "une preuve silencieuse expirée ne doit pas être confirmée")

        var renewed = coordinator([.proximity], config: config)
        _ = renewed.consume(snapshot([signal(.proximity, at: 0)], at: 0), now: 0)
        guard let renewedCandidate = renewed.consume(
            snapshot([signal(.proximity, at: 2)], at: 2), now: 2
        ) else { fatalError("la réservation à renouveler doit exister") }
        _ = renewed.consume(snapshot([
            signal(.proximity, at: 2.4)
        ], at: 2.4), now: 2.4)
        expect(renewed.ownsReservation(renewedCandidate, now: 2.9),
               "une preuve fiable renouvelée doit prolonger la réservation")
        expect(renewed.commitDelivery(renewedCandidate, now: 2.9),
               "la réservation prolongée doit rester confirmable")

        // Fair scheduling: a signal not scheduled yet gets a turn before a
        // repeatedly eligible signal, then the oldest scheduled signal wins.
        let fairConfig = PostureSignalAlertConfiguration(
            persistence: 1, recovery: 1, cooldown: 1, dailyMaximum: 20
        )
        var fair = coordinator([.proximity, .torsoInclination], config: fairConfig)
        _ = fair.consume(snapshot([
            signal(.proximity, at: 0), signal(.torsoInclination, at: 0)
        ], at: 0), now: 0)
        guard let fairFirst = fair.consume(snapshot([
            signal(.proximity, at: 1), signal(.torsoInclination, at: 1)
        ], at: 1), now: 1) else { fatalError("la première alerte équitable doit exister") }
        expect(fairFirst.signalID == .proximity, "la priorité départage le premier tour")
        expect(fair.commitDelivery(fairFirst, now: 1), "le premier tour doit être confirmé")
        guard let fairSecond = fair.consume(snapshot([
            signal(.proximity, at: 2), signal(.torsoInclination, at: 2)
        ], at: 2), now: 2) else { fatalError("le second tour équitable doit exister") }
        expect(fairSecond.signalID == .torsoInclination,
               "un signal en attente doit passer avant le signal prioritaire répété")
        expect(fair.commitDelivery(fairSecond, now: 2), "le second tour doit être confirmé")
        guard let fairThird = fair.consume(snapshot([
            signal(.proximity, at: 3), signal(.torsoInclination, at: 3)
        ], at: 3), now: 3) else { fatalError("le troisième tour équitable doit exister") }
        expect(fairThird.signalID == .proximity,
               "le signal le plus anciennement planifié doit reprendre son tour")

        // Reliability gating: limited, unavailable and stale evidence cannot
        // open an alert episode, even when its assessment says attention.
        let reliabilityConfig = PostureSignalAlertConfiguration(
            persistence: 1, recovery: 1, cooldown: 1, dailyMaximum: 5
        )
        var limited = coordinator([.proximity], config: reliabilityConfig)
        expect(limited.consume(snapshot([
            signal(.proximity, at: 0, availability: .available, quality: .limited)
        ], at: 0), now: 0) == nil,
               "une observation limitée ne doit jamais produire un rappel")

        var limitedShoulderSlope = coordinator([.shoulderSlope], config: reliabilityConfig)
        expect(limitedShoulderSlope.consume(snapshot([
            signal(.shoulderSlope, at: 0, availability: .available, quality: .limited)
        ], at: 0), now: 0) == nil,
               "une pente d'épaules limitée par le cadrage ne doit jamais produire un rappel")

        var unavailable = coordinator([.proximity], config: reliabilityConfig)
        expect(unavailable.consume(snapshot([
            signal(.proximity, at: 0, availability: .insufficient, quality: .unavailable)
        ], at: 0), now: 0) == nil,
               "une observation indisponible ne doit jamais produire un rappel")

        var stale = coordinator([.proximity], config: reliabilityConfig)
        _ = stale.consume(snapshot([signal(.proximity, at: 0)], at: 0), now: 0)
        expect(stale.consume(snapshot([
            signal(.proximity, at: 2, observedAt: 0)
        ], at: 2), now: 2) == nil,
               "une observation plus ancienne que son TTL ne doit pas produire un rappel")

        // A delivery failure releases the reservation and leaves the quota
        // available for a later retry after the short backoff.
        var retry = coordinator([.proximity], config: config)
        _ = retry.consume(snapshot([signal(.proximity, episode: 9, at: 0)], at: 0), now: 0)
        guard let failed = retry.consume(
            snapshot([signal(.proximity, episode: 9, at: 2)], at: 2), now: 2
        ) else { fatalError("la réservation de permission doit exister") }
        retry.releaseDelivery(failed, now: 2)
        expect(retry.consume(
            snapshot([signal(.proximity, episode: 9, at: 3)], at: 3), now: 3
        ) == nil, "un échec de livraison doit appliquer un bref backoff")
        expect(retry.consume(
            snapshot([signal(.proximity, episode: 9, at: 8)], at: 8), now: 8
        ) != nil, "un échec ne doit ni livrer ni consommer le quota")

        // Context changes invalidate old async work.
        var identity = coordinator([.proximity], config: config)
        _ = identity.consume(snapshot([signal(.proximity, at: 0)], at: 0), now: 0)
        guard let oldContext = identity.consume(
            snapshot([signal(.proximity, at: 2)], at: 2), now: 2
        ) else { fatalError("la réservation d'identité doit exister") }
        _ = identity.consume(
            snapshot([
                signal(.proximity, assessment: .withinReference, episode: nil, at: 2.1)
            ], at: 2.1, contextKey: "camera-b"), now: 2.1
        )
        expect(!identity.ownsReservation(oldContext, now: 2.2),
               "une réservation d’un ancien contexte doit devenir inerte")

        // Delivery state survives a restart, while runtime identity does not.
        var persisted = coordinator([.proximity], config: config)
        _ = persisted.consume(snapshot([signal(.proximity, episode: 40, at: 10)], at: 10), now: 10)
        guard let delivered = persisted.consume(
            snapshot([signal(.proximity, episode: 40, at: 12)], at: 12), now: 12
        ) else { fatalError("l'alerte persistée doit devenir éligible") }
        expect(persisted.commitDelivery(delivered, now: 12),
               "la livraison persistée doit être confirmée")
        let savedDeliveryState = persisted.deliveryState()
        expect(savedDeliveryState.requiresRecovery["proximity"] == true,
               "l’état de livraison doit rester persisté")

        var restored = coordinator([.proximity], config: config)
        restored.restoreDeliveryState(.init(
            globalDeliveries: savedDeliveryState.globalDeliveries,
            perSignal: savedDeliveryState.perSignal,
            requiresRecovery: savedDeliveryState.requiresRecovery
        ), now: 20)
        _ = restored.consume(snapshot([signal(.proximity, episode: 41, at: 20)], at: 20), now: 20)
        expect(restored.consume(
            snapshot([signal(.proximity, episode: 41, at: 23)], at: 23), now: 23
        ) != nil,
               "la récupération ne doit pas bloquer un nouvel épisode après redémarrage")

        // Every signal exposed in Settings is now an actual alertable signal.
        for id in PostureObservationSignalID.alertableCases {
            var signalCoordinator = coordinator([id], config: config)
            _ = signalCoordinator.consume(snapshot([signal(id, at: 0)], at: 0), now: 0)
            expect(signalCoordinator.consume(
                snapshot([signal(id, at: 2)], at: 2), now: 2
            )?.signalID == id, "\(id.rawValue) doit pouvoir déclencher un rappel")
        }

        let suite = "com.align.tests.alert-settings"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settingsStore = PostureAlertSettingsStore(defaults: defaults)
        var settings = PostureAlertSettings()
        expect(settings.sensitivity == .sensitive && !settings.sensitivityWasChosenByUser,
               "Sensible doit être le défaut distinct d’un choix explicite")
        settings.sensitivity = .balanced
        settings.sensitivityWasChosenByUser = true
        settings.controls[.proximity]?.snoozedUntil = 123
        settingsStore.save(settings)
        expect(settingsStore.load() == settings,
               "sensibilité, snooze et activation doivent survivre au redémarrage")
        expect(PostureObservationSignalID.alertableCases.count == 7,
               "les sept signaux affichés doivent être alertables")
        print("PostureAlertCoordinatorHarness: OK")
    }
}
