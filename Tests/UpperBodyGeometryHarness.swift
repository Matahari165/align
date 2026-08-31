import Foundation

@main
private enum UpperBodyGeometryHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("UpperBodyGeometryHarness: FAIL — \(message)\n", stderr)
            exit(1)
        }
    }

    static func point(_ id: UpperBodyLandmarkID, _ x: CGFloat, _ y: CGFloat) -> UpperBodyPoint {
        UpperBodyPoint(
            id: id,
            location: CGPoint(x: x, y: y),
            confidence: 0.9,
            quality: .good,
            provenance: .observed
        )
    }

    static func main() {
        let expected: [(UpperBodyLandmarkID, Int)] = [
            (.nose, 0), (.leftEar, 3), (.rightEar, 4),
            (.leftShoulder, 5), (.rightShoulder, 6),
            (.leftElbow, 7), (.rightElbow, 8),
            (.leftHip, 11), (.rightHip, 12), (.neck, 18)
        ]
        for (id, index) in expected {
            expect(id.halpe26Index == index, "index Halpe26 incorrect pour \(id.rawValue)")
        }
        expect(UpperBodyLandmarkID.rtmposeMapping.count == 10,
               "le mapping RTMPose doit exposer exactement les 10 repères Align")

        let descriptor = UpperBodyEngineDescriptor(
            id: "harness", displayName: "Harness", version: "1", runtime: "test"
        )
        let result = UpperBodyResult(
            descriptor: descriptor,
            state: .detected,
            generation: 4,
            sampleID: 23,
            capturedAt: 8.5,
            producedAt: 8.6,
            points: [
                point(.nose, 0.50, 0.22), point(.leftEar, 0.43, 0.24),
                point(.rightEar, 0.57, 0.24), point(.neck, 0.50, 0.36),
                point(.leftShoulder, 0.34, 0.50), point(.rightShoulder, 0.66, 0.43),
                point(.leftElbow, 0.26, 0.68), point(.rightElbow, 0.76, 0.62)
            ],
            contours: []
        )
        let geometry = result.derivedGeometry
        expect(geometry.generation == 4 && geometry.sampleID == 23 && geometry.capturedAt == 8.5,
               "les dérivés doivent conserver l’identité de la même frame")
        expect(geometry.status(for: .shoulders).quality == .complete,
               "les épaules doivent rester complètes sans hanches")
        expect(geometry.status(for: .neckShoulders).quality == .complete,
               "la famille cou-épaules doit rester indépendante")
        expect(geometry.status(for: .arms).quality == .complete,
               "les deux segments épaules-coudes doivent être disponibles")
        expect(geometry.status(for: .hips).quality == .unavailable,
               "les hanches hors champ doivent être explicitement indisponibles")
        expect(geometry.status(for: .torso).quality == .partial,
               "le torse doit être partiel quand les hanches manquent")
        expect(geometry.status(for: .head).quality == .complete,
               "la famille tête doit être complète")

        expect(geometry.segments.count == 6,
               "six segments mêmes-frame sont attendus sans hanches")
        expect(geometry.segment(named: "ligne-épaules")?.startID == .leftShoulder,
               "la ligne doit conserver le côté gauche anatomique")
        expect(geometry.segment(named: "épaule-coude-droite")?.endID == .rightElbow,
               "le segment droit doit conserver son côté")
        expect(geometry.axis(named: "axe-torse") == nil,
               "aucun axe torse ne doit être inventé sans quatre extrémités")
        expect(geometry.axis(named: "axe-tête")?.startIDs == [.neck] &&
               geometry.axis(named: "axe-tête")?.endIDs == [.nose],
               "l’axe tête doit rester distinct et observé")

        let partial = UpperBodyResult(
            descriptor: descriptor,
            state: .partial,
            generation: 4,
            sampleID: 24,
            capturedAt: 8.7,
            producedAt: 8.8,
            points: [point(.leftShoulder, 0.34, 0.50)],
            contours: []
        ).derivedGeometry
        expect(partial.status(for: .shoulders).quality == .partial,
               "une seule épaule doit être partial, jamais complète")
        expect(partial.segments.isEmpty && partial.axes.isEmpty,
               "aucun segment ou axe ne doit utiliser un point inventé")

        let stale = UpperBodyResult(
            descriptor: descriptor,
            state: .stale,
            generation: 4,
            sampleID: 25,
            capturedAt: 8.9,
            producedAt: 9.0,
            points: [point(.leftShoulder, 0.34, 0.50), point(.rightShoulder, 0.66, 0.50)],
            contours: []
        ).derivedGeometry
        expect(stale.segments.isEmpty && stale.axes.isEmpty &&
               stale.status(for: .shoulders).quality == .unavailable,
               "un résultat stale ne doit produire aucune géométrie")

        print("UpperBodyGeometryHarness: OK")
    }
}
