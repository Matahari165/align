import Foundation

@main
private enum BlazePoseModelVariantHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        expect(BlazePoseModelVariant.configured(from: nil) == .lite,
               "une configuration absente doit préserver Lite")
        expect(BlazePoseModelVariant.configured(from: "LITE") == .lite,
               "la lecture de variante doit être stable")
        expect(BlazePoseModelVariant.configured(from: "full") == .full,
               "le bundle Full doit sélectionner exclusivement Full")
        expect(BlazePoseModelVariant.configured(from: "inconnue") == nil,
               "une valeur invalide doit échouer plutôt que fausser l’A/B en lançant Lite")

        expect(BlazePoseModelVariant.lite.detectorResourceName == "pose_detector" &&
               BlazePoseModelVariant.lite.landmarksResourceName == "pose_landmarks_detector",
               "Lite doit conserver ses deux ressources canoniques")
        expect(BlazePoseModelVariant.full.detectorResourceName == "pose_detector_full" &&
               BlazePoseModelVariant.full.landmarksResourceName == "pose_landmarks_detector_full",
               "Full doit utiliser sa paire officielle sans mélange avec Lite")
        expect(BlazePoseModelVariant.full.detectorResourceName !=
               BlazePoseModelVariant.lite.detectorResourceName,
               "une activation ne doit jamais partager le détecteur d’une autre variante")

        print("BlazePoseModelVariantHarness: OK")
    }
}
