import CoreGraphics
import Foundation

@main
struct UpperBodyROISpikeHarness {
    static func main() {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
        }
        func approximately(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool { abs(lhs - rhs) < 0.000_1 }

        let asymmetric = CGRect(x: 0.82, y: 0.06, width: 0.16, height: 0.42)
        let roi = UpperBodyROIMapper.expandedRegion(from: asymmetric)!
        expect(roi.minX >= 0 && roi.minY >= 0 && roi.maxX <= 1 && roi.maxY <= 1, "ROI bornée dans l'image")
        expect(roi.contains(CGPoint(x: asymmetric.midX, y: asymmetric.midY)), "ROI conserve le rectangle source")
        expect(roi.width * roi.height > asymmetric.width * asymmetric.height, "ROI élargie")
        expect(approximately(roi.maxX, 1), "clamp asymétrique droit")
        expect(UpperBodyROIMapper.expandedRegion(from: .zero) == nil, "rectangle vide refusé")
        expect(UpperBodyROIMapper.expandedRegion(from: CGRect(x: .nan, y: 0, width: 0.2, height: 0.2)) == nil, "rectangle non fini refusé")
        let localPoint = CGPoint(x: 0.25, y: 0.75)
        let fullPoint = VisionCoordinateMapper.bodyOverlayPoint(fromROILocalVisionPoint: localPoint, regionOfInterest: roi)
        expect(approximately(fullPoint.x, roi.minX + 0.25 * roi.width), "mapping ROI x vers image complète")
        expect(approximately(fullPoint.y, 1 - (roi.minY + 0.75 * roi.height)), "mapping ROI y bas-gauche vers overlay haut-gauche")
        let fullFramePoint = VisionCoordinateMapper.bodyOverlayPoint(
            fromROILocalVisionPoint: CGPoint(x: 0.2, y: 0.8),
            regionOfInterest: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        expect(approximately(fullFramePoint.x, 0.2) && approximately(fullFramePoint.y, 0.2), "mapping corps plein cadre")

        var cadence = UpperBodyROISpikeCadence()
        expect(!cadence.isDue(at: 0, benchmarkRunning: false), "désactivé hors benchmark")
        expect(cadence.isDue(at: 0, benchmarkRunning: true), "premier cycle immédiat")
        expect(cadence.claimStage(at: 0) == .humanRectangle, "rectangle premier")
        cadence.continueAfterRectangle(roi)
        expect(cadence.isDue(at: 0.1, benchmarkRunning: true), "full frame en attente")
        expect(cadence.claimStage(at: 0.1) == .fullFrameBody, "full frame second")
        cadence.continueAfterFullFrame()
        guard case .regionBody(let scheduledROI) = cadence.claimStage(at: 0.2) else {
            fatalError("ROI troisième")
        }
        expect(scheduledROI == roi, "mapping ROI inchangé jusqu'à Vision")
        expect(!cadence.isDue(at: 1.99, benchmarkRunning: true), "budget total body inférieur à 1 Hz")
        expect(cadence.isDue(at: 2.0, benchmarkRunning: true), "cycle suivant à deux secondes")
        cadence.reset()
        expect(!cadence.isDue(at: 10, benchmarkRunning: false), "reset stop")
        var rejectedCadence = UpperBodyROISpikeCadence()
        _ = rejectedCadence.claimStage(at: 0)
        rejectedCadence.continueAfterRectangle(nil)
        expect(!rejectedCadence.isDue(at: 0.1, benchmarkRunning: true), "sans rectangle accepté, aucun full/ROI comparable")

        var staleDiagnostics = UpperBodyROISpikeDiagnostics.empty
        staleDiagnostics.fullFrameCoverage = 3
        staleDiagnostics.fullFrameDuration = 0.02
        staleDiagnostics.regionCoverage = 2
        staleDiagnostics.regionDuration = 0.01
        staleDiagnostics.clearBodyComparison()
        expect(staleDiagnostics.fullFrameCoverage == nil && staleDiagnostics.fullFrameDuration == nil, "un nouveau rectangle efface le plein cadre périmé")
        expect(staleDiagnostics.regionCoverage == nil && staleDiagnostics.regionDuration == nil, "un rectangle rejeté ou en erreur efface la ROI périmée")
        staleDiagnostics.regionCoverage = 3
        staleDiagnostics.regionDuration = 0.01
        staleDiagnostics.clearRegionComparison()
        expect(staleDiagnostics.regionCoverage == nil && staleDiagnostics.regionDuration == nil, "une erreur plein cadre efface la ROI précédente")

        var metrics = BenchmarkMetrics()
        func measurement(_ spike: UpperBodyROISpikeMeasurement) -> BenchmarkMeasurement {
            BenchmarkMeasurement(
                faceAttempted: false, faceDuration: 0, faceSucceeded: false,
                faceHadLandmarks: false, faceOrientation: nil,
                bodyDuration: nil, bodySucceeded: false,
                overlayVisible: false, upperBodyROISpike: spike
            )
        }
        metrics.record(measurement(.rectangle(resultCount: 1, accepted: false, confidence: 0.49, duration: 0.01, error: false)))
        metrics.record(measurement(.rectangle(resultCount: 1, accepted: true, confidence: 0.8, duration: 0.01, error: false)))
        metrics.record(measurement(.fullFrame(coverage: 1, duration: 0.02, error: false)))
        metrics.record(measurement(.fullFrame(coverage: nil, duration: 0, error: true)))
        metrics.record(measurement(.region(coverage: 3, duration: 0.015, error: false)))
        metrics.record(measurement(.region(coverage: nil, duration: 0, error: true)))
        let report = metrics.report
        expect(report.contains("Spike rectangle humain : bruts 2/2, acceptés >=50 % 1"), "séparation rectangle brut/faible/accepté")
        expect(report.contains("Comparaison corps plein : 2 tentatives, couverture 0/1/2/3 = 0/1/0/0"), "agrégat full avec dénominateur")
        expect(report.contains("Comparaison corps ROI : 2 tentatives, couverture 0/1/2/3 = 0/0/0/1"), "agrégat ROI avec dénominateur")
        expect(report.contains("couverture 0/1/2/3 = 0/1/0/0, erreurs 1, durée p95 20.0 ms"), "une erreur full ne doit pas devenir une durée nulle")
        expect(report.contains("couverture 0/1/2/3 = 0/0/0/1, erreurs 1, durée p95 15.0 ms"), "une erreur ROI ne doit pas devenir une durée nulle")

        print("UpperBodyROISpikeHarness: OK")
    }
}
