import Foundation

@main
private enum PostureAlertCoordinatorHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func signal(
        _ id: PostureObservationSignalID,
        assessment: PostureObservationAssessment,
        episode: UInt64?,
        at time: TimeInterval
    ) -> PostureSignalSnapshot {
        .init(signalID: id, generation: 1, availability: .available,
              assessment: assessment, quality: .good, observedAt: time,
              producedAt: time, episodeID: episode, reason: nil)
    }

    static func snapshot(_ values: [PostureSignalSnapshot], at time: TimeInterval) ->
        PostureObservationsSnapshot {
        .init(generation: 1, producedAt: time, signals: values)
    }

    static func main() {
        let config = PostureSignalAlertConfiguration(
            persistence: 2, recovery: 3, cooldown: 5, dailyMaximum: 2
        )
        var coordinator = PostureAlertCoordinator(
            signalConfigurations: Dictionary(uniqueKeysWithValues:
                PostureObservationSignalID.allCases.map { ($0, config) }),
            globalConfiguration: .init(mode: .validation,
                                       minimumIntervalBetweenSignals: 4,
                                       dailyMaximum: 3, dailyWindow: 100)
        )
        let both = snapshot([
            signal(.torsoInclination, assessment: .attention, episode: 1, at: 0),
            signal(.proximity, assessment: .attention, episode: 1, at: 0)
        ], at: 0)
        expect(coordinator.consume(both, now: 0) == nil, "la persistance doit précéder l’alerte")
        let first = coordinator.consume(both, now: 2)
        expect(first?.signalID == .proximity,
               "l’arbitre doit sélectionner une seule alerte selon la priorité")
        expect(first?.identifier == "posture.proximity.g1.e1",
               "l’identifiant doit être stable par signal/génération/épisode")
        if let first { expect(coordinator.commitDelivery(first, now: 2), "la livraison doit confirmer la réservation") }
        expect(coordinator.consume(both, now: 3) == nil,
               "le même épisode et l’intervalle global doivent être dédupliqués")

        let recovered = snapshot([
            signal(.proximity, assessment: .withinReference, episode: nil, at: 4)
        ], at: 4)
        _ = coordinator.consume(recovered, now: 4)
        _ = coordinator.consume(recovered, now: 7)
        let secondEpisode = snapshot([
            signal(.proximity, assessment: .attention, episode: 2, at: 8)
        ], at: 8)
        expect(coordinator.consume(secondEpisode, now: 8) == nil,
               "un nouvel épisode doit satisfaire sa propre persistance")
        let second = coordinator.consume(secondEpisode, now: 10)
        expect(second?.episodeID == 2,
               "récupération, cooldown et persistance permettent un nouvel épisode")
        if let second { expect(coordinator.commitDelivery(second, now: 10), "le second épisode doit être confirmé") }

        coordinator.snooze(.torsoInclination, until: 20)
        let torso = snapshot([
            signal(.torsoInclination, assessment: .attention, episode: 3, at: 11)
        ], at: 11)
        _ = coordinator.consume(torso, now: 11)
        expect(coordinator.consume(torso, now: 14) == nil,
               "le snooze doit supprimer uniquement le signal concerné")
        coordinator.setEnabled(false, for: .estimatedBlinks)
        let blink = snapshot([
            signal(.estimatedBlinks, assessment: .attention, episode: 4, at: 20)
        ], at: 20)
        _ = coordinator.consume(blink, now: 20)
        expect(coordinator.consume(blink, now: 23) == nil,
               "la désactivation d’un rappel ne doit pas émettre")
        coordinator.reactivate(.estimatedBlinks)
        _ = coordinator.consume(blink, now: 24)
        let blinkCandidate = coordinator.consume(blink, now: 26)
        expect(blinkCandidate?.signalID == .estimatedBlinks,
               "la réactivation doit restaurer uniquement le signal choisi")
        if let blinkCandidate { expect(coordinator.commitDelivery(blinkCandidate, now: 26), "le rappel clignements doit être confirmable") }

        coordinator.snooze(.raisedShoulders, choice: .untilReactivation,
                           now: Date(timeIntervalSince1970: 30))
        expect(coordinator.controls[.raisedShoulders]?.isSnoozedUntilReactivation == true,
               "Jusqu’à réactivation doit être distinct d’une échéance absente")

        var retryCoordinator = PostureAlertCoordinator(
            signalConfigurations: [.proximity: config],
            globalConfiguration: .init(mode: .validation,
                                       minimumIntervalBetweenSignals: 1,
                                       dailyMaximum: 3, dailyWindow: 100)
        )
        let retrySnapshot = snapshot([
            signal(.proximity, assessment: .attention, episode: 9, at: 0)
        ], at: 0)
        _ = retryCoordinator.consume(retrySnapshot, now: 0)
        guard let reserved = retryCoordinator.consume(retrySnapshot, now: 2) else {
            fatalError("la réservation de test doit exister")
        }
        retryCoordinator.releaseDelivery(reserved, now: 2)
        expect(retryCoordinator.consume(retrySnapshot, now: 3) == nil,
               "un échec de livraison doit appliquer un bref backoff")
        expect(retryCoordinator.consume(retrySnapshot, now: 8) != nil,
               "un échec ne doit ni livrer ni consommer le quota")

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
        print("PostureAlertCoordinatorHarness: OK")
    }
}
