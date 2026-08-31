import Foundation

@main
private enum PostureHistoryHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() async throws {
        var accumulator = PostureHistoryAccumulator()
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_800_000_000)

        // Event identity is scoped to the process launch: two launches may
        // both restart generation/episode counters, while a duplicate within
        // one launch must still be ignored.
        var launchEvents = PostureHistoryAccumulator()
        func delivery(_ key: String) -> PostureHistoryObservation {
            .init(date: day, signalID: .proximity, sensitivity: .sensitive,
                  ruleProfileID: "runtime-v1", observedDuration: 0,
                  attentionDuration: 0, beganOpportunity: true,
                  acceptedEventCount: 1, deliveredNotification: true,
                  recoveryDuration: nil, eventKey: key)
        }
        launchEvents.ingest(delivery("launch-a:alert:g1:s=proximity:e1"), now: day)
        launchEvents.ingest(delivery("launch-a:alert:g1:s=proximity:e1"), now: day)
        launchEvents.ingest(delivery("launch-b:alert:g1:s=proximity:e1"), now: day)
        expect(launchEvents.database.buckets.reduce(0) { $0 + $1.notificationCount } == 2,
               "les lancements distincts doivent avoir des clés d’événement distinctes")

        for index in 0..<5 {
            accumulator.ingest(.init(
                date: day.addingTimeInterval(Double(index) * 60),
                signalID: .estimatedBlinks,
                sensitivity: .sensitive,
                ruleProfileID: "blink-v1",
                observedDuration: 60,
                attentionDuration: 0,
                beganOpportunity: false,
                acceptedEventCount: 10,
                deliveredNotification: false,
                recoveryDuration: nil,
                blinkEventCount: 10
            ), now: day.addingTimeInterval(600))
        }
        accumulator.ingestCoverage(
            channel: .faceAndEyes,
            interval: .init(start: day, duration: 300),
            now: day.addingTimeInterval(600),
            calendar: calendar
        )
        accumulator.ingest(.init(
            date: day.addingTimeInterval(300), signalID: .estimatedBlinks,
            sensitivity: .sensitive, ruleProfileID: "blink-v1",
            observedDuration: 0, attentionDuration: 0, beganOpportunity: true,
            acceptedEventCount: 99, deliveredNotification: false,
            recoveryDuration: nil, eventKey: "delivery-only", blinkEventCount: 0
        ), now: day.addingTimeInterval(600))
        guard let daySummary = PostureHistoryQuery.summary(
            database: accumulator.database, period: .day,
            containing: day, calendar: calendar
        ) else { fatalError("résumé jour") }
        expect(daySummary.estimatedBlinkObservedDuration == 300,
               "le dénominateur doit sommer uniquement le temps fiable")
        expect(abs((daySummary.estimatedBlinksPerMinute ?? 0) - 10) < 0.000_001,
               "le taux doit diviser les vrais clignements, pas les livraisons")

        var insufficient = PostureHistoryAccumulator()
        insufficient.ingest(.init(
            date: day, signalID: .estimatedBlinks, sensitivity: .sensitive,
            ruleProfileID: "blink-v1", observedDuration: 180,
            attentionDuration: 0, beganOpportunity: false, acceptedEventCount: 30,
            deliveredNotification: false, recoveryDuration: nil, blinkEventCount: 30
        ), now: day.addingTimeInterval(200))
        insufficient.ingestCoverage(
            channel: .faceAndEyes,
            interval: .init(start: day, duration: 180),
            now: day.addingTimeInterval(200),
            calendar: calendar
        )
        let insufficientSummary = PostureHistoryQuery.summary(
            database: insufficient.database, period: .day,
            containing: day, calendar: calendar
        )
        expect(insufficientSummary?.estimatedBlinksPerMinute == nil,
               "une couverture insuffisante ne doit jamais afficher zéro ou extrapoler")

        var coverage = PostureHistoryAccumulator()
        coverage.ingestCoverage(channel: .faceAndEyes, interval: .init(start: day, duration: 120), now: day.addingTimeInterval(300), calendar: calendar)
        coverage.ingestCoverage(channel: .upperBody, interval: .init(start: day.addingTimeInterval(60), duration: 120), now: day.addingTimeInterval(300), calendar: calendar)
        let coverageSummary = PostureHistoryQuery.summary(database: coverage.database, period: .day, containing: day, calendar: calendar)
        expect(coverageSummary?.faceAndEyesCoverage == 120 && coverageSummary?.upperBodyCoverage == 120 && coverageSummary?.totalCoverage == 180,
               "la couverture totale doit être l’union exacte, jamais le maximum approximatif")
        expect(coverageSummary?.estimatedBlinkObservedDuration == 120,
               "le dénominateur clignements doit venir de visage et deux yeux fiables")

        var boundary = PostureHistoryAccumulator()
        let midnight = calendar.startOfDay(for: day).addingTimeInterval(24 * 3600)
        boundary.ingest(.init(date: midnight.addingTimeInterval(-60), signalID: .proximity, sensitivity: .sensitive, ruleProfileID: "v1", observedDuration: 120, attentionDuration: 60, beganOpportunity: true, acceptedEventCount: 0, deliveredNotification: true, recoveryDuration: 40), now: midnight.addingTimeInterval(120), calendar: calendar)
        expect(boundary.database.buckets.count == 2 && boundary.database.buckets.allSatisfy { $0.observedDuration == 60 },
               "une observation traversant minuit doit être découpée sans perte")

        accumulator.recordControlEvent(.init(
            date: day, signalID: .raisedShoulders, action: .snoozed,
            sensitivity: .sensitive, ruleProfileID: "shoulders-sensitive-v1"
        ), now: day.addingTimeInterval(200))
        expect(accumulator.database.controlEvents.count == 1 &&
               accumulator.database.buckets.reduce(0) { $0 + $1.notificationCount } == 0,
               "un snooze doit être historisé sans compter une notification livrée")

        let file = URL(fileURLWithPath: "/private/tmp/align-posture-history-harness.json")
        try? FileManager.default.removeItem(at: file)
        let store = PostureHistoryStore(fileURL: file)
        try await store.save(accumulator.database)
        let restored = await store.load()
        expect(restored == .loaded(accumulator.database),
               "le stockage JSON atomique doit restaurer les agrégats")

        // The controller must serialize erase after an in-flight save.  The
        // queued record is started first (and reaches its persistence await),
        // then erase establishes its tombstone; a late completion cannot
        // resurrect the file.
        let controller = await MainActor.run {
            PostureHistoryController(store: store)
        }
        await controller.loadIfNeeded()
        let queuedRecord = Task { @MainActor in
            await controller.record(.init(
                date: day, signalID: .proximity, sensitivity: .sensitive,
                ruleProfileID: "queued", observedDuration: 30,
                attentionDuration: 0, beganOpportunity: true,
                acceptedEventCount: 1, deliveredNotification: false,
                recoveryDuration: nil, eventKey: "queued-before-erase"
            ), now: day.addingTimeInterval(60))
        }
        for _ in 0..<4 { await Task.yield() }
        await controller.erase()
        await queuedRecord.value
        let reloadedController = await MainActor.run {
            PostureHistoryController(store: store)
        }
        await reloadedController.loadIfNeeded()
        let reloadedIsEmpty = await MainActor.run { reloadedController.loadResult == .empty }
        expect(reloadedIsEmpty,
               "une écriture en attente ne doit pas ressusciter après erase")

        try await store.erase()
        let erased = await store.load()
        expect(erased == .empty,
               "l’effacement local doit supprimer les agrégats")
        try Data("not-json".utf8).write(to: file)
        let corrupt = await store.load()
        expect(corrupt == .corrupt,
               "une corruption doit rester distincte d’un historique vide")
        print("PostureHistoryHarness: OK")
    }
}
