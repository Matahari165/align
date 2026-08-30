import Foundation
@main private enum PostureSignalPipelineHarness {
    static func expect(_ v: @autoclosure () -> Bool, _ m: String) { guard v() else { fputs("FAIL: \(m)\n", stderr); exit(1) } }
    static func input(_ t: Double, _ id: UInt64, generation: UInt64 = 4) -> PostureSnapshot {
        .init(faceGeneration: generation, faceTimestamp: t, faceSampleID: id, facePointCount: 80,
              interocularDistance: 0.20, faceLength: 0.30, pitchProxy: 0.25, yawProxy: 0,
              leftEyeOpeningRatio: 0.30, rightEyeOpeningRatio: 0.30,
              innerBrowDistanceRatio: 0.25, faceCenter: nil, leftShoulder: nil,
              rightShoulder: nil, bodyGeneration: nil, bodyTimestamp: nil, bodySampleID: nil)
    }
    static func main() {
        var p = PostureSignalPipeline(); _ = p.reset(generation: 4)
        expect(p.snapshot.indicators.count == 6, "six indicateurs")
        _ = p.beginCalibration(at: 10, generation: 4); expect(p.snapshot.isCalibrating, "calibration visible")
        for i in 0..<13 { let t = 10 + Double(i) * (8.0 / 12.0); _ = p.ingest(input(t, UInt64(i + 1)), now: t) }
        expect(!p.snapshot.isCalibrating, "calibration terminée")
        expect(p.snapshot.result(for: .headDistance).state == .normal, "distance évaluée")
        _ = p.ingest(input(18, 14), now: 18.1)
        expect(p.snapshot.producedAt == 18.1,
               "même timestamp avec identifiant supérieur accepté lexicographiquement")
        let acceptedTime = p.snapshot.result(for: .headDistance).observedAt
        _ = p.ingest(input(17, 99), now: 18)
        expect(p.snapshot.result(for: .headDistance).observedAt == acceptedTime,
               "entrée ancienne ne remplace pas latest")
        expect(p.snapshot.result(for: .raisedShoulders).state == .unavailable, "corps non apparié non inventé")
        expect(p.expire(at: 19, generation: 4).result(for: .headDistance).state == .unavailable, "TTL")
        expect(p.reset(generation: 5).indicators.allSatisfy { $0.state == .unavailable }, "reset")

        var secondChance = PostureSignalPipeline(); _ = secondChance.reset(generation: 6)
        _ = secondChance.beginCalibration(at: 20, generation: 6)
        for i in 0..<11 {
            let t = 20 + Double(i) * 0.8
            _ = secondChance.ingest(input(t, UInt64(i + 1), generation: 6), now: t)
        }
        expect(secondChance.expire(at: 28, generation: 6).isCalibrating,
               "à 8 secondes une calibration insuffisante garde sa seconde chance")
        _ = secondChance.ingest(input(29, 12, generation: 6), now: 29)
        expect(!secondChance.snapshot.isCalibrating,
               "un échantillon entre 8 et 10 secondes peut terminer la calibration")
        print("PostureSignalPipelineHarness: OK")
    }
}
