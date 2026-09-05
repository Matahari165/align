import Foundation

@main
private enum LocalPostureNotificationServiceHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("LocalPostureNotificationServiceHarness: FAIL — \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        expect(LocalPostureNotificationCopy.authorizationOptions.contains(.alert) &&
               LocalPostureNotificationCopy.authorizationOptions.contains(.sound),
               "l’autorisation doit déclarer les alertes et le son, y compris en migration")

        let shoulder = LocalPostureNotificationCopy.body(for: .shoulderSlope)
        expect(shoulder == "Une épaule semble plus haute que l’autre. Réaligne tes épaules.",
               "la pente des épaules doit décrire une asymétrie latérale sans choisir un côté")
        expect(!(shoulder ?? "").localizedCaseInsensitiveContains("gauche") &&
               !(shoulder ?? "").localizedCaseInsensitiveContains("droite"),
               "le texte ne doit pas inventer le côté de l’épaule")

        expect(LocalPostureNotificationCopy.body(for: .headTilt) ==
               "Ta tête est penchée sur le côté. Réajuste-la.",
               "la tête doit être décrite comme penchée sur le côté")
        expect(LocalPostureNotificationCopy.body(for: .torsoInclination) ==
               "Ton buste penche sur le côté par rapport à ton repère. Recentre ton buste.",
               "le torse doit préciser le mouvement latéral et le repère calibré")

        for id in PostureObservationSignalID.alertableCases {
            let text = LocalPostureNotificationCopy.body(for: id)
            expect(text?.isEmpty == false, "\(id.rawValue) doit avoir un message")
            expect(!(text ?? "").contains("si c’est") &&
                   !(text ?? "").contains("si tu"),
                   "\(id.rawValue) ne doit pas affaiblir l’action par une condition")
        }

        expect(LocalPostureNotificationCopy.body(for: .estimatedBlinks) ==
               "Pense à cligner naturellement et regarde au loin quelques instants.",
               "le rappel clignements doit rester une suggestion non diagnostique")
        expect(LocalPostureNotificationCopy.testTitle == "Align · Test de rappel" &&
               LocalPostureNotificationCopy.testBody ==
                   "Ceci est un test. Les rappels Align sont activés.",
               "le test doit être clairement identifié et distinct d’une alerte réelle")
        expect(LocalPostureNotificationCopy.foregroundPresentationOptions.contains(.banner) &&
               LocalPostureNotificationCopy.foregroundPresentationOptions.contains(.list) &&
               LocalPostureNotificationCopy.foregroundPresentationOptions.contains(.sound),
               "le premier plan doit afficher le bandeau, la liste et le son")
        print("LocalPostureNotificationServiceHarness: OK")
    }
}
