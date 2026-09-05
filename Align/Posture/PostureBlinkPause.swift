import Foundation

/// Rappel pratique après une période d'yeux ouverts continuellement observée.
/// Le délai est un réglage de rappel, pas une norme médicale de clignement.
nonisolated struct PostureBlinkPause: Equatable, Sendable {
    private var generation: UInt64 = 0
    private var lastSampleID: UInt64 = 0
    private var lastTimestamp: TimeInterval?
    private var openSince: TimeInterval?
    private(set) var needsReminder = false

    mutating func reset() { self = .init() }

    mutating func consume(
        generation: UInt64, sampleID: UInt64, timestamp: TimeInterval,
        eyesOpen: Bool, qualityGood: Bool,
        maximumGap: TimeInterval = 0.25,
        reminderAfter: TimeInterval = 20
    ) -> Bool {
        guard generation > 0, sampleID > 0, timestamp.isFinite,
              maximumGap.isFinite, maximumGap > 0,
              reminderAfter.isFinite, reminderAfter > 0 else {
            reset()
            return false
        }
        if self.generation != generation {
            reset()
            self.generation = generation
        }
        guard sampleID > lastSampleID,
              lastTimestamp.map({ timestamp > $0 }) ?? true else { return needsReminder }
        if let lastTimestamp, timestamp - lastTimestamp > maximumGap {
            openSince = nil
            needsReminder = false
        }
        lastSampleID = sampleID
        lastTimestamp = timestamp
        guard qualityGood, eyesOpen else {
            openSince = nil
            needsReminder = false
            return false
        }
        openSince = openSince ?? timestamp
        needsReminder = timestamp - (openSince ?? timestamp) >= reminderAfter
        return needsReminder
    }
}
