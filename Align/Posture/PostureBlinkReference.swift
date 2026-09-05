import Foundation

/// Paramètres de construction du repère personnel de fréquence de clignement.
/// Le repère ne décrit pas une norme médicale : il sert uniquement à comparer
/// les fenêtres d'une même personne dans un contexte caméra donné.
nonisolated struct PostureBlinkReferenceConfiguration: Equatable, Sendable {
    var windowDuration: TimeInterval = 60
    var minimumObservableSeconds: TimeInterval = 45
    var requiredWindows: Int = 3

    var isValid: Bool {
        windowDuration.isFinite && windowDuration > 0 &&
            minimumObservableSeconds.isFinite &&
            minimumObservableSeconds > 0 &&
            minimumObservableSeconds <= windowDuration &&
            requiredWindows >= 1
    }

    static let `default` = Self()
}

/// Une fenêtre est produite par le tracker de clignements, après sa propre
/// gestion des gaps. `observableSeconds` ne doit donc contenir que les
/// intervalles réellement couverts par deux preuves visage/yeux valides.
nonisolated struct PostureBlinkReferenceWindow: Equatable, Sendable {
    let startedAt: TimeInterval
    let endedAt: TimeInterval
    let observableSeconds: TimeInterval
    let blinkCount: Int

    var duration: TimeInterval { endedAt - startedAt }
    var ratePerMinute: Double? {
        guard observableSeconds > 0, observableSeconds.isFinite else { return nil }
        let value = Double(blinkCount) / observableSeconds * 60
        return value.isFinite ? value : nil
    }

    var isFinite: Bool {
        startedAt.isFinite && endedAt.isFinite && observableSeconds.isFinite &&
            duration.isFinite && blinkCount >= 0
    }
}

nonisolated enum PostureBlinkReferenceRejection: String, Equatable, Sendable {
    case invalidConfiguration
    case invalidWindow
    case insufficientObservableTime
    case overlappingWindow
    case unavailableRate
}

nonisolated enum PostureBlinkReferenceIngestResult: Equatable, Sendable {
    case accepted(windowCount: Int)
    case frozen(targetPerMinute: Double)
    case rejected(PostureBlinkReferenceRejection)
}

/// Construit une fréquence personnelle à partir de fenêtres indépendantes.
///
/// Une fenêtre n'est acceptée que si elle couvre 60 secondes et contient au
/// moins 45 secondes de preuves visage/yeux observables. Après trois fenêtres,
/// la médiane des taux est gelée : des ticks supplémentaires dans la même
/// session ne peuvent plus déplacer le repère.
nonisolated struct PostureBlinkReference: Equatable, Sendable {
    let configuration: PostureBlinkReferenceConfiguration
    private(set) var acceptedWindows: [PostureBlinkReferenceWindow] = []
    private(set) var targetPerMinute: Double?
    private(set) var isFrozen = false
    private(set) var lastRejection: PostureBlinkReferenceRejection? = nil

    init(configuration: PostureBlinkReferenceConfiguration = .default) {
        self.configuration = configuration
    }

    mutating func reset() {
        acceptedWindows.removeAll(keepingCapacity: true)
        targetPerMinute = nil
        isFrozen = false
        lastRejection = nil
    }

    @discardableResult
    mutating func ingest(
        _ window: PostureBlinkReferenceWindow
    ) -> PostureBlinkReferenceIngestResult {
        guard configuration.isValid else {
            return reject(.invalidConfiguration)
        }
        if isFrozen, let targetPerMinute {
            return .frozen(targetPerMinute: targetPerMinute)
        }
        guard window.isFinite,
              window.startedAt < window.endedAt,
              abs(window.duration - configuration.windowDuration) <= 0.5,
              window.observableSeconds >= 0,
              window.observableSeconds <= window.duration else {
            return reject(.invalidWindow)
        }
        guard window.observableSeconds >= configuration.minimumObservableSeconds else {
            return reject(.insufficientObservableTime)
        }
        if let previous = acceptedWindows.last,
           window.startedAt < previous.endedAt {
            return reject(.overlappingWindow)
        }
        guard let rate = window.ratePerMinute, rate >= 0 else {
            return reject(.unavailableRate)
        }

        acceptedWindows.append(window)
        guard acceptedWindows.count >= configuration.requiredWindows else {
            lastRejection = nil
            return .accepted(windowCount: acceptedWindows.count)
        }
        let rates = acceptedWindows
            .compactMap(\.ratePerMinute)
            .sorted()
        guard let median = Self.median(rates), median.isFinite else {
            acceptedWindows.removeLast()
            return reject(.unavailableRate)
        }
        targetPerMinute = median
        isFrozen = true
        lastRejection = nil
        return .frozen(targetPerMinute: median)
    }

    private mutating func reject(
        _ reason: PostureBlinkReferenceRejection
    ) -> PostureBlinkReferenceIngestResult {
        lastRejection = reason
        return .rejected(reason)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }
}
