import Foundation

nonisolated struct PostureCalibration: Equatable, Sendable {
    let generation: UInt64
    let startedAt: TimeInterval
    let completedAt: TimeInterval
    let sampleCount: Int
    let bodySampleCount: Int
    let interocularDistance: Double?
    let faceLength: Double?
    let faceScale: Double?
    let pitchProxy: Double?
    let eyeOpeningRatio: Double?
    let headForwardRatio: Double?
    let shoulderElevation: Double?
    let innerBrowDistanceRatio: Double?
}

nonisolated enum PostureCalibrationProgress: Equatable, Sendable {
    case collecting(elapsed: TimeInterval, sampleCount: Int)
    case ready(PostureCalibration)
    case failed
}

nonisolated struct PostureCalibrationSession: Sendable {
    let generation: UInt64
    let startedAt: TimeInterval
    let minimumDuration: TimeInterval
    let maximumDuration: TimeInterval
    let maximumSamples: Int
    let minimumSamples: Int
    let maximumSampleGap: TimeInterval

    private var samples: [PostureSnapshot] = []
    private var bodySamples: [PostureSnapshot] = []
    private var lastSeenFace: PostureSnapshot?
    private var lastSampledFaceTimestamp: TimeInterval?
    private var lastAcceptedBodyTimestamp: TimeInterval?
    private var lastAcceptedBodySampleID: UInt64?

    init?(
        generation: UInt64,
        startedAt: TimeInterval,
        minimumDuration: TimeInterval = 8,
        maximumDuration: TimeInterval = 10,
        maximumSamples: Int = 30,
        minimumSamples: Int = 12,
        maximumSampleGap: TimeInterval = 1
    ) {
        guard startedAt.isFinite, minimumDuration.isFinite, maximumDuration.isFinite,
              maximumSampleGap.isFinite, minimumDuration >= 8, minimumDuration <= 10,
              maximumDuration >= minimumDuration, maximumDuration <= 10,
              maximumSamples > 1, maximumSamples <= 30,
              minimumSamples > 0, minimumSamples <= maximumSamples,
              maximumSampleGap > 0 else { return nil }
        self.generation = generation
        self.startedAt = startedAt
        self.minimumDuration = minimumDuration
        self.maximumDuration = maximumDuration
        self.maximumSamples = maximumSamples
        self.minimumSamples = minimumSamples
        self.maximumSampleGap = maximumSampleGap
    }

    mutating func consume(_ snapshot: PostureSnapshot) -> PostureCalibrationProgress {
        guard snapshot.faceTimestamp.isFinite, snapshot.faceGeneration == generation,
              snapshot.faceTimestamp >= startedAt else { return .failed }
        let elapsed = snapshot.faceTimestamp - startedAt
        guard elapsed <= maximumDuration else { return .failed }
        let isNewFace: Bool
        if let lastSeenFace {
            if snapshot.sameFaceEvidence(as: lastSeenFace) {
                isNewFace = false
            } else if snapshot.faceTimestamp == lastSeenFace.faceTimestamp &&
                        snapshot.faceSampleID == lastSeenFace.faceSampleID {
                return .failed
            } else {
                guard isNewer(timestamp: snapshot.faceTimestamp,
                              sampleID: snapshot.faceSampleID,
                              than: lastSeenFace.faceTimestamp,
                              sampleID: lastSeenFace.faceSampleID),
                      snapshot.faceSampleID != lastSeenFace.faceSampleID else {
                    return .collecting(elapsed: elapsed, sampleCount: samples.count)
                }
                guard snapshot.faceTimestamp - lastSeenFace.faceTimestamp <= maximumSampleGap else {
                    self.lastSeenFace = snapshot
                    return .collecting(elapsed: elapsed, sampleCount: samples.count)
                }
                isNewFace = true
            }
        } else {
            isNewFace = true
        }

        if isNewFace {
            lastSeenFace = snapshot
            let spacing = minimumDuration / Double(maximumSamples - 1)
            if lastSampledFaceTimestamp.map({ snapshot.faceTimestamp - $0 >= spacing }) ?? true,
               snapshotHasFiniteFaceMetric(snapshot), samples.count < maximumSamples {
                samples.append(snapshot)
                lastSampledFaceTimestamp = snapshot.faceTimestamp
            }
        }

        acceptBodyIfNew(snapshot)

        guard elapsed >= minimumDuration else {
            return .collecting(elapsed: elapsed, sampleCount: samples.count)
        }
        guard samples.count >= minimumSamples,
              let calibration = makeCalibration(completedAt: snapshot.faceTimestamp) else {
            return elapsed < maximumDuration
                ? .collecting(elapsed: elapsed, sampleCount: samples.count)
                : .failed
        }
        return .ready(calibration)
    }

    /// Termine explicitement la fenêtre même si aucune nouvelle image n'arrive.
    mutating func finish(at now: TimeInterval) -> PostureCalibrationProgress {
        guard now.isFinite, now >= startedAt else { return .failed }
        let elapsed = now - startedAt
        guard elapsed >= minimumDuration else {
            return .collecting(elapsed: elapsed, sampleCount: samples.count)
        }
        guard elapsed <= maximumDuration else { return .failed }
        guard samples.count >= minimumSamples,
              let calibration = makeCalibration(completedAt: now) else {
            return elapsed < maximumDuration
                ? .collecting(elapsed: elapsed, sampleCount: samples.count)
                : .failed
        }
        return .ready(calibration)
    }

    private func makeCalibration(completedAt: TimeInterval) -> PostureCalibration? {
        let faceMinimum = minimumSamples
        let bodyMinimum = min(6, minimumSamples)
        let interocular = stableMedian(samples.compactMap(\.interocularDistance),
                                       minimumCount: faceMinimum, maximumRelativeRange: 0.12)
        let faceLength = stableMedian(samples.compactMap(\.faceLength),
                                      minimumCount: faceMinimum, maximumRelativeRange: 0.12)
        let faceScale: Double?
        if let interocular, let faceLength {
            let value = sqrt(interocular) * sqrt(faceLength)
            faceScale = value.isFinite ? value : nil
        } else {
            faceScale = nil
        }
        let calibration = PostureCalibration(
            generation: generation,
            startedAt: startedAt,
            completedAt: completedAt,
            sampleCount: samples.count,
            bodySampleCount: bodySamples.count,
            interocularDistance: interocular,
            faceLength: faceLength,
            faceScale: faceScale,
            pitchProxy: stableMedian(samples.compactMap(\.pitchProxy),
                                     minimumCount: faceMinimum, maximumAbsoluteRange: 0.12),
            eyeOpeningRatio: stableMedian(samples.compactMap(\.meanEyeOpeningRatio),
                                          minimumCount: faceMinimum,
                                          maximumRelativeRange: 0.35,
                                          minimumMedian: 0.08),
            headForwardRatio: stableMedian(bodySamples.compactMap {
                $0.headForwardRatio(maximumSkew: 0.30)
            },
                                           minimumCount: bodyMinimum,
                                           maximumRelativeRange: 0.15),
            shoulderElevation: stableMedian(bodySamples.compactMap {
                $0.shoulderElevation(maximumSkew: 0.30)
            },
                                            minimumCount: bodyMinimum,
                                            maximumAbsoluteRange: 0.15),
            innerBrowDistanceRatio: stableMedian(
                samples.compactMap(\.innerBrowDistanceRatio),
                minimumCount: faceMinimum,
                maximumRelativeRange: 0.20,
                minimumMedian: 0.01
            )
        )
        guard calibration.faceScale != nil || calibration.pitchProxy != nil ||
                calibration.eyeOpeningRatio != nil || calibration.headForwardRatio != nil ||
                calibration.shoulderElevation != nil ||
                calibration.innerBrowDistanceRatio != nil else { return nil }
        return calibration
    }

    private func snapshotHasFiniteFaceMetric(_ snapshot: PostureSnapshot) -> Bool {
        snapshot.faceScale != nil || finite(snapshot.pitchProxy) != nil ||
            snapshot.meanEyeOpeningRatio != nil ||
            positiveFinite(snapshot.innerBrowDistanceRatio) != nil
    }

    private mutating func acceptBodyIfNew(_ snapshot: PostureSnapshot) {
        guard snapshot.hasNearbyBody(maximumSkew: 0.30),
              let timestamp = snapshot.bodyTimestamp,
              let sampleID = snapshot.bodySampleID,
              timestamp >= startedAt else { return }
        if let lastTimestamp = lastAcceptedBodyTimestamp,
           let lastSampleID = lastAcceptedBodySampleID {
            if timestamp == lastTimestamp && sampleID == lastSampleID { return }
            guard isNewer(timestamp: timestamp, sampleID: sampleID,
                          than: lastTimestamp, sampleID: lastSampleID),
                  sampleID != lastSampleID else { return }
        }
        guard bodySamples.count < maximumSamples,
              snapshot.headForwardRatio(maximumSkew: 0.30) != nil ||
                snapshot.shoulderElevation(maximumSkew: 0.30) != nil else { return }
        bodySamples.append(snapshot)
        lastAcceptedBodyTimestamp = timestamp
        lastAcceptedBodySampleID = sampleID
    }
}

private nonisolated func isNewer(
    timestamp: TimeInterval,
    sampleID: UInt64,
    than previousTimestamp: TimeInterval,
    sampleID previousSampleID: UInt64
) -> Bool {
    timestamp > previousTimestamp ||
        (timestamp == previousTimestamp && sampleID > previousSampleID)
}

private nonisolated func median(_ values: [Double]) -> Double? {
    let sorted = values.filter(\.isFinite).sorted()
    guard !sorted.isEmpty else { return nil }
    let middle = sorted.count / 2
    let value = sorted.count.isMultiple(of: 2)
        ? sorted[middle - 1] / 2 + sorted[middle] / 2
        : sorted[middle]
    return value.isFinite ? value : nil
}

private nonisolated func stableMedian(
    _ values: [Double],
    minimumCount: Int,
    maximumRelativeRange: Double? = nil,
    maximumAbsoluteRange: Double? = nil,
    minimumMedian: Double? = nil
) -> Double? {
    let finiteValues = values.filter(\.isFinite)
    guard finiteValues.count >= minimumCount, let center = median(finiteValues),
          minimumMedian.map({ center >= $0 }) ?? true,
          let minimum = finiteValues.min(), let maximum = finiteValues.max() else { return nil }
    let range = maximum - minimum
    guard range.isFinite,
          maximumAbsoluteRange.map({ range <= $0 }) ?? true else { return nil }
    if let maximumRelativeRange {
        guard abs(center) > 0.000_001,
              range / abs(center) <= maximumRelativeRange else { return nil }
    }
    return center
}

private nonisolated func finite(_ value: Double?) -> Double? {
    guard let value, value.isFinite else { return nil }
    return value
}

private nonisolated func positiveFinite(_ value: Double?) -> Double? {
    guard let value = finite(value), value > 0 else { return nil }
    return value
}
