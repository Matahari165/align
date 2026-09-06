import Foundation

@main
private enum StatisticsPresenterHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() {
        var calendar = Calendar(identifier: .iso8601); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let loading = StatisticsPresenter.make(loadResult: .loading, database: .init(buckets: []), period: .day, date: now, calendar: calendar)
        expect(loading.state == .loading, "le chargement doit être distinct du vide")
        let empty = StatisticsPresenter.make(loadResult: .empty, database: .init(buckets: []), period: .day, date: now, calendar: calendar)
        expect(empty.state == .empty("Aucune observation fiable pour cette période."), "vide doit rester vide, sans zéros")
        expect(empty.rows.allSatisfy { !$0.primary.contains("0.0") }, "inconnu ne doit jamais devenir zéro")

        let corrupt = StatisticsPresenter.make(loadResult: .corrupt, database: .init(buckets: []), period: .day, date: now, calendar: calendar)
        if case .corrupt = corrupt.state {} else { expect(false, "corruption distincte du vide") }

        var accumulator = PostureHistoryAccumulator()
        accumulator.ingestCoverage(channel: .faceAndEyes, interval: .init(start: now, duration: 100), now: now.addingTimeInterval(300), calendar: calendar)
        accumulator.ingestCoverage(channel: .upperBody, interval: .init(start: now.addingTimeInterval(50), duration: 100), now: now.addingTimeInterval(300), calendar: calendar)
        accumulator.ingest(.init(date: now, signalID: .torsoInclination, sensitivity: .sensitive, ruleProfileID: "torso-v1", observedDuration: 100, attentionDuration: 20, beganOpportunity: true, acceptedEventCount: 0, deliveredNotification: true, recoveryDuration: 40), now: now.addingTimeInterval(300), calendar: calendar)
        accumulator.ingest(.init(date: now.addingTimeInterval(10), signalID: .torsoInclination, sensitivity: .sensitive, ruleProfileID: "torso-v1", observedDuration: 100, attentionDuration: 10, beganOpportunity: true, acceptedEventCount: 0, deliveredNotification: false, recoveryDuration: 20), now: now.addingTimeInterval(300), calendar: calendar)
        let content = StatisticsPresenter.make(loadResult: .loaded(accumulator.database), database: accumulator.database, period: .day, date: now, calendar: calendar)
        expect(content.rows.count == 8,
               "les huit observations canoniques doivent être historisées")
        expect(content.coverageAccessibilityLabel.contains("2 min"), "VoiceOver doit annoncer l’union de couverture")
        expect(content.rows.first(where: { $0.id == .torsoInclination })?.secondary.contains("30") == true, "la médiane de récupération doit être présentée")
        expect(content.insights.count <= 3, "trois insights maximum")
        expect(content.series.count == 24, "jour = timeline de 24 heures")
        let week = StatisticsPresenter.make(loadResult: .loaded(accumulator.database), database: accumulator.database, period: .week, date: now, calendar: calendar)
        expect(week.series.count == 7, "semaine = sept barres")
        let month = StatisticsPresenter.make(loadResult: .loaded(accumulator.database), database: accumulator.database, period: .month, date: now, calendar: calendar)
        expect((4...6).contains(month.series.count), "mois = semaines compactes")
        expect(content.blinkDetail.contains("Données insuffisantes"), "clignements sans couverture suffisante ne doivent pas afficher zéro")
        expect(content.rows.first(where: { $0.id == .shoulderSlope })?.experimental == false &&
               content.rows.first(where: { $0.id == .closedShoulders })?.experimental == true,
               "seul le rapport tête-épaules reste une estimation parmi ces deux métriques")
        let blinkDate = now.addingTimeInterval(500)
        accumulator.ingestCoverage(channel: .faceAndEyes, interval: .init(start: blinkDate, duration: 400), now: blinkDate.addingTimeInterval(500), calendar: calendar)
        accumulator.ingest(.init(date: blinkDate, signalID: .estimatedBlinks, sensitivity: .sensitive, ruleProfileID: "blink-v1", observedDuration: 0, attentionDuration: 0, beganOpportunity: false, acceptedEventCount: 0, deliveredNotification: false, recoveryDuration: nil, blinkEventCount: 2), now: blinkDate.addingTimeInterval(500), calendar: calendar)
        let blinkContent = StatisticsPresenter.make(loadResult: .loaded(accumulator.database), database: accumulator.database, period: .day, date: now, calendar: calendar)
        expect(blinkContent.rows.first(where: { $0.id == .estimatedBlinks })?.primary.contains("/min") == true, "la ligne clignements doit afficher le taux réel")
        func trendDatabase(previousProfile: String) -> PostureHistoryDatabase {
            var trend = PostureHistoryAccumulator()
            for (date, profile) in [(now.addingTimeInterval(-86400), previousProfile),
                                    (now, "universal-geometry-v1")] {
                trend.ingestCoverage(channel: .upperBody, interval: .init(start: date, duration: 100),
                                     now: now.addingTimeInterval(300), calendar: calendar)
                trend.ingest(.init(date: date, signalID: .shoulderSlope, sensitivity: .sensitive,
                                   ruleProfileID: profile, observedDuration: 100, attentionDuration: 20,
                                   beganOpportunity: true, acceptedEventCount: 0,
                                   deliveredNotification: false, recoveryDuration: nil),
                             now: now.addingTimeInterval(300), calendar: calendar)
            }
            return trend.database
        }
        let comparableDB = trendDatabase(previousProfile: "universal-geometry-v1")
        let comparableTrend = StatisticsPresenter.make(loadResult: .loaded(comparableDB),
            database: comparableDB, period: .day, date: now, calendar: calendar)
        expect(comparableTrend.insights.contains { $0.id == "trend-shoulders" },
               "les mêmes règles permettent une comparaison des épaules")
        let changedDB = trendDatabase(previousProfile: "runtime-v1")
        let changedTrend = StatisticsPresenter.make(loadResult: .loaded(changedDB),
            database: changedDB, period: .day, date: now, calendar: calendar)
        expect(!changedTrend.insights.contains { $0.id == "trend-shoulders" },
               "un changement de règles ne doit pas être présenté comme une évolution de posture")
        print("StatisticsPresenterHarness: OK")
    }
}
