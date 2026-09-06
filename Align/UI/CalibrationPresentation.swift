import Foundation

nonisolated enum PostureCalibrationSignalOutcome: Equatable, Sendable {
    case pending
    case ready
    case unavailable(String)
}

nonisolated struct PostureCalibrationPresentation: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case idle, collecting, completed, failed(String) }
    let phase: Phase
    let progress: Double
    let outcomes: [PostureObservationSignalID: PostureCalibrationSignalOutcome]

    static let idle = Self(phase: .idle, progress: 0, outcomes: [:])

    var title: String {
        switch phase {
        case .idle: "Référence des yeux à initialiser"
        case .collecting: "Mesure de l’ouverture des yeux…"
        case .completed: "Référence des yeux prête"
        case .failed: "Référence des yeux incomplète"
        }
    }
}
