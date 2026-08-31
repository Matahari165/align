import Foundation

// Commande depuis Align/Align :
// env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk -module-cache-path /tmp/align-module-cache -o /tmp/pose-render-selection-harness Align/Pose/PoseDetector.swift Align/Pose/FaceOrientation.swift Align/Pose/FaceGeometrySignal.swift Align/Pose/PersonSegmentationDetector.swift Align/Pose/HumanRectangleDetector.swift Align/Camera/AnalysisCadencePolicy.swift Align/Pose/PoseResultStabilizer.swift Align/Benchmark/BenchmarkSession.swift Align/UI/PoseOverlayRenderSelection.swift Tests/PoseOverlayRenderSelectionHarness.swift && /tmp/pose-render-selection-harness

@main
private enum PoseOverlayRenderSelectionHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() {
        func point(_ name: String, _ source: PosePointSource) -> PosePoint {
            PosePoint(name: name, location: CGPoint(x: 0.3, y: 0.4),
                      confidence: 0.9, source: source)
        }
        func line(_ name: String, _ source: PosePointSource) -> PosePolyline {
            PosePolyline(name: name,
                         locations: [CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.7, y: 0.5)],
                         source: source, isClosed: false)
        }
        let complete = PoseOverlay(
            points: [
                point("Épaule gauche", .upperBodyShoulders),
                point("Épaule droite", .upperBodyShoulders),
                point("CENTRE ESTIMÉ", .blazePose), point("Cou", .body)
            ],
            polylines: [
                line("ligne-épaules", .upperBodyShoulders), line("visage", .face),
                line("silhouette estimée", .silhouette)
            ]
        )
        let normal = PoseOverlayRenderSelection.select(complete, diagnosticsEnabled: false)
        expect(normal.points.map(\.name) == ["Épaule gauche", "Épaule droite"],
               "le mode normal doit conserver uniquement les deux épaules")
        expect(normal.polylines.map(\.name) == ["ligne-épaules"],
               "le mode normal doit conserver uniquement la ligne d'épaules")
        let development = PoseOverlayRenderSelection.select(complete, diagnosticsEnabled: true)
        expect(development.points.map(\.name) == ["Épaule gauche", "Épaule droite"],
               "le mode développement ne doit conserver que les sources upper-body")
        expect(development.polylines.map(\.name) == ["ligne-épaules"],
               "le mode développement ne doit pas réafficher visage ou silhouette legacy")
        print("PoseOverlayRenderSelectionHarness: OK")
    }
}
