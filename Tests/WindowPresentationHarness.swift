import Foundation

@main
private enum WindowPresentationHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let visibleKey = WindowPresentationState(
            isKey: true,
            isVisible: true,
            isMiniaturized: false,
            isOccluded: false
        )
        let visibleBehindMenu = WindowPresentationState(
            isKey: false,
            isVisible: true,
            isMiniaturized: false,
            isOccluded: false
        )
        let minimized = WindowPresentationState(
            isKey: false,
            isVisible: true,
            isMiniaturized: true,
            isOccluded: true
        )

        expect(visibleKey.usesForegroundCadence, "une fenêtre visible doit utiliser la cadence de premier plan")
        expect(visibleBehindMenu.usesForegroundCadence, "ouvrir le menu ne doit pas changer la cadence")
        expect(!minimized.usesForegroundCadence, "une fenêtre réduite doit quitter la cadence de premier plan")
        expect(!WindowPresentationState.hidden.usesForegroundCadence, "une fenêtre fermée ou démontée doit être cachée")
        expect(WindowPresentationState.hidden.isMiniaturized, "l’état caché doit publier le couple false/true attendu")

        var lifecycle = WindowPresentationLifecycle()
        lifecycle.windowWillClose()
        expect(lifecycle.isClosing, "la fermeture doit verrouiller l’état caché")
        lifecycle.windowDidBecomeKey()
        expect(!lifecycle.isClosing, "la réouverture de la même fenêtre doit libérer le verrou de fermeture")
        lifecycle.windowWillClose()
        lifecycle.detach()
        expect(!lifecycle.isClosing, "le démontage doit réinitialiser le cycle de vie")

        print("WindowPresentationHarness: OK")
    }
}
