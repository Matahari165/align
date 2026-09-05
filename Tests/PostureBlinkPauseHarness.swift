import Foundation

@main
enum PostureBlinkPauseHarness {
    static func main() {
        var tracker = PostureBlinkPause()
        for index in 0...200 {
            let reminder = tracker.consume(generation: 1, sampleID: UInt64(index + 1),
                timestamp: Double(index) / 10, eyesOpen: true, qualityGood: true)
            precondition(reminder == (index == 200), "Attendre vingt secondes réellement observées")
        }
        precondition(!tracker.consume(generation: 1, sampleID: 202,
            timestamp: 20.1, eyesOpen: false, qualityGood: true), "Fermer les yeux termine le rappel")
        precondition(!tracker.consume(generation: 1, sampleID: 203,
            timestamp: 20.2, eyesOpen: true, qualityGood: true), "Une nouvelle période recommence à zéro")
        for index in 0...60 {
            precondition(!tracker.consume(generation: 2, sampleID: UInt64(index + 1),
                timestamp: Double(index) / 2, eyesOpen: true, qualityGood: true),
                "Une cadence insuffisante ne doit pas inventer une absence de clignements")
        }
        for index in 0...400 {
            precondition(!tracker.consume(generation: 3, sampleID: UInt64(index + 1),
                timestamp: Double(index) / 10, eyesOpen: true,
                qualityGood: index % 100 != 0), "Les pertes de visibilité interrompent la preuve")
        }
        print("PostureBlinkPauseHarness: OK")
    }
}
