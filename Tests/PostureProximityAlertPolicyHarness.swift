import Foundation

@main private enum PostureProximityAlertPolicyHarness {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() {
        var policy = PostureProximityAlertPolicy()
        expect(policy.consume(isProbablyTooClose: true, isEligible: false,
                              isForeground: true, now: 1_000) == .none,
               "aucune alerte sans calibration et qualité")
        expect(policy.consume(isProbablyTooClose: true, isEligible: true,
                              isForeground: true, now: 2_000) == .none,
               "début de persistance")
        expect(policy.consume(isProbablyTooClose: true, isEligible: true,
                              isForeground: true, now: 2_044) == .none,
               "pas avant 45 secondes")
        expect(policy.consume(isProbablyTooClose: true, isEligible: true,
                              isForeground: true, now: 2_045) == .foregroundBanner,
               "bandeau après 45 secondes")
        expect(policy.consume(isProbablyTooClose: true, isEligible: true,
                              isForeground: false, now: 3_844) == .none,
               "cooldown de 30 minutes")
        expect(policy.consume(isProbablyTooClose: true, isEligible: true,
                              isForeground: false, now: 3_845) == .none,
               "pas de répétition sans retour dans le repère")
        _ = policy.consume(isProbablyTooClose: false, isEligible: true,
                           isForeground: false, now: 3_845)
        _ = policy.consume(isProbablyTooClose: true, isEligible: true,
                           isForeground: false, now: 3_846)
        expect(policy.consume(isProbablyTooClose: true, isEligible: true,
                              isForeground: false, now: 3_891) == .backgroundNotification,
               "notification après retour puis nouvelle persistance")
        policy.rollbackDelivery(at: 3_891)
        expect(policy.deliveries == [2_045], "échec de livraison ne consomme ni quota ni cooldown")
        expect(policy.consume(isProbablyTooClose: true, isEligible: true,
                              isForeground: false, now: 3_891) == .none,
               "échec ne déclenche pas une boucle immédiate")
        expect(policy.consume(isProbablyTooClose: true, isEligible: true,
                              isForeground: false, now: 3_951) == .backgroundNotification,
               "livraison réessayable après une minute")
        _ = policy.consume(isProbablyTooClose: false, isEligible: true,
                           isForeground: true, now: 3_952)
        expect(policy.attentionSince == nil, "retour au repère réarme la persistance")
        _ = policy.consume(isProbablyTooClose: true, isEligible: true,
                           isForeground: true, now: 5_751)
        expect(policy.consume(isProbablyTooClose: true, isEligible: true,
                              isForeground: true, now: 5_796) == .foregroundBanner,
               "troisième alerte autorisée dans la fenêtre globale")
        _ = policy.consume(isProbablyTooClose: false, isEligible: true,
                           isForeground: false, now: 7_596)
        _ = policy.consume(isProbablyTooClose: true, isEligible: true,
                           isForeground: false, now: 7_597)
        expect(policy.consume(isProbablyTooClose: true, isEligible: true,
                              isForeground: false, now: 7_642) == .none,
               "plafond global de trois alertes par 24 heures")

        let suiteName = "com.align.tests.proximity-alert"
        guard let defaults = UserDefaults(suiteName: suiteName) else { exit(1) }
        defaults.removePersistentDomain(forName: suiteName)
        let store = PostureProximityAlertHistoryStore(defaults: defaults, key: "history")
        store.save(policy.deliveries)
        expect(store.load() == policy.deliveries, "historique minimal restauré")
        defaults.removePersistentDomain(forName: suiteName)
        print("PostureProximityAlertPolicyHarness: OK")
    }
}
