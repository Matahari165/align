import Foundation

@main
private enum BlazePoseBridgeHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func point(_ x: Float, _ y: Float, _ confidence: Float = 0.9,
                      valid: Bool = true) -> AlignBlazePosePoint {
        AlignBlazePosePoint(x: x, y: y, confidence: confidence, valid: valid ? 1 : 0)
    }

    static func main() {
        let native = AlignBlazePoseResult(
            status: AlignBlazePoseDetected,
            nose: point(0.50, 0.12),
            left_ear: point(0.40, 0.15), right_ear: point(0.60, 0.15),
            left_shoulder: point(0.28, 0.38), right_shoulder: point(0.72, 0.44),
            left_elbow: point(0.18, 0.62), right_elbow: point(0.82, 0.64),
            left_hip: point(0.36, 0.88), right_hip: point(0.64, 0.90)
        )
        let complete = BlazePoseLiveEngine.liveResult(from: native)
        expect(complete?.state == .detected, "deux épaules valides doivent être détectées")
        expect(complete?.overlay.points.count == 8,
               "l’overlay proche doit privilégier sept repères hauts et le centre estimé")
        expect(complete?.overlay.polylines.count == 8,
               "le contour haut et l’axe estimé doivent être publiés sans les hanches")
        expect(abs((complete?.nose?.location.x ?? 0) - 0.50) < 0.000_001 &&
               abs((complete?.leftHip?.location.y ?? 0) - 0.88) < 0.000_001,
               "les neuf champs ABI, dont les hanches non dessinées, restent disponibles")
        expect(complete?.overlay.points.contains { $0.name.contains("Hanche") } == false,
               "les hanches ne doivent pas dominer le cadrage proche")

        var partialNative = native
        partialNative.right_shoulder.valid = 0
        let partial = BlazePoseLiveEngine.liveResult(from: partialNative)
        expect(partial?.state == .partial, "une épaule valide doit rester partielle")
        expect(partial?.rightShoulder == nil, "valid=0 doit supprimer le point")
        expect(partial?.overlay.polylines.contains { $0.name == "ligne-épaules" } == false,
               "partial ne doit jamais inventer la ligne des épaules")

        var rightOnlyNative = native
        rightOnlyNative.left_shoulder.valid = 0
        let rightOnly = BlazePoseLiveEngine.liveResult(from: rightOnlyNative)
        expect(rightOnly?.state == .partial && rightOnly?.leftShoulder == nil,
               "la droite seule doit produire partial sans inversion")

        var noShoulders = native
        noShoulders.left_shoulder.valid = 0
        noShoulders.right_shoulder.valid = 0
        expect(BlazePoseLiveEngine.liveResult(from: noShoulders)?.state == .lost,
               "aucune épaule valide doit produire lost")

        var invalid = native
        invalid.nose.x = .nan
        expect(BlazePoseLiveEngine.liveResult(from: invalid)?.nose == nil,
               "un point non fini doit être rejeté même si valid=1")
        expect(BlazePoseLiveEngine.liveResult(from: .init(status: AlignBlazePoseStale,
                                                         nose: point(0, 0),
                                                         left_ear: point(0, 0), right_ear: point(0, 0),
                                                         left_shoulder: point(0, 0), right_shoulder: point(0, 0),
                                                         left_elbow: point(0, 0), right_elbow: point(0, 0),
                                                         left_hip: point(0, 0), right_hip: point(0, 0))) == nil,
               "stale doit rester silencieux")
        var technical = noShoulders
        technical.status = AlignBlazePoseTechnicalError
        expect(BlazePoseLiveEngine.liveResult(from: technical)?.state == .technicalError,
               "l’erreur technique doit rester distincte de lost")
        print("BlazePoseBridgeHarness: OK")
    }
}
