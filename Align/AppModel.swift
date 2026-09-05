import AppKit
import Combine
import AVFoundation

@MainActor
final class AppModel: ObservableObject {
    let camera: CameraCaptureService
    let history: PostureHistoryController
    private let notificationService: LocalPostureNotificationService
    private var alertCoordinator = PostureAlertCoordinator(
        signalConfigurations: [
            .proximity: .init(persistence: 15, recovery: 20, cooldown: 60, dailyMaximum: 720),
            .torsoInclination: .init(persistence: 15, recovery: 30, cooldown: 60, dailyMaximum: 720),
            .raisedShoulders: .init(persistence: 15, recovery: 30, cooldown: 60, dailyMaximum: 720),
            .headTilt: .init(persistence: 15, recovery: 30, cooldown: 60, dailyMaximum: 720),
            .shoulderSlope: .init(persistence: 15, recovery: 30, cooldown: 60, dailyMaximum: 720),
            .closedShoulders: .init(persistence: 15, recovery: 30, cooldown: 60, dailyMaximum: 720),
            .estimatedBlinks: .init(persistence: 1, recovery: 2 * 60, cooldown: 120, dailyMaximum: 720)
        ],
        globalConfiguration: .normal
    )
    private var alertSettings: PostureAlertSettings
    private var observationCancellables = Set<AnyCancellable>()
    private var lastHistoryState: [PostureObservationSignalID: PostureSignalSnapshot] = [:]
    private var signalDurationLastObserved: [PostureObservationSignalID: TimeInterval] = [:]
    private var signalDurationAssessment: [PostureObservationSignalID: PostureObservationAssessment?] = [:]
    private var attentionEpisodeStartedAt: [PostureObservationSignalID: TimeInterval] = [:]
    private var lastHistoryKey = Set<String>()
    private var pendingDeliveryRequests: [String: PostureAlertCandidate] = [:]
    private var lastObservationGeneration: UInt64 = 0
    private var lastObservationContextKey = ""
    private var observationContextEpoch: UInt64 = 0
    private var runtimeToken: UInt64 = 0
    private var runtimeAcceptsObservations = false
    private var coverageStarts: [PostureCoverageChannel: TimeInterval] = [:]
    private var coverageLastRecorded: [PostureCoverageChannel: TimeInterval] = [:]
    private var coverageWallOffset: TimeInterval?
    private let coverageFlushInterval: TimeInterval = 5
    private let faceCoverageMaximumGap: TimeInterval = 0.25
    private let bodyCoverageMaximumGap: TimeInterval = 1.5
    private let launchSessionID = UUID().uuidString
    private var didAttemptAutomaticCameraStart = false

    private var isTerminating = false
    private let alertDeliveryStateKey = "posture.alertDeliveryState.v1"

    var recommendationSensitivity: PostureRecommendationSensitivity { alertSettings.sensitivity }

    func sendTestNotification() async -> Bool {
        await notificationService.deliverTestNotification()
    }

    /// Démarre la caméra une seule fois à l’ouverture de la fenêtre principale.
    /// Un arrêt volontaire ne pourra donc pas être annulé par un nouveau rendu SwiftUI.
    func attemptAutomaticCameraStart() {
        guard !didAttemptAutomaticCameraStart else { return }
        didAttemptAutomaticCameraStart = true
        guard camera.state == .idle else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized, .notDetermined:
            camera.start()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func isAlertEnabled(_ id: PostureObservationSignalID) -> Bool {
        alertSettings.controls[id, default: .init()].isEnabled
    }

    func alertControl(_ id: PostureObservationSignalID) -> PostureAlertControl {
        alertSettings.controls[id, default: .init()]
    }

    init() {
        camera = CameraCaptureService()
        history = PostureHistoryController()
        notificationService = LocalPostureNotificationService()
        alertSettings = PostureAlertSettingsStore().load()
        alertCoordinator.setSensitivity(alertSettings.sensitivity)
        restoreAlertDeliveryState()
        for (id, control) in alertSettings.controls {
            alertCoordinator.setEnabled(control.isEnabled, for: id)
            if control.isSnoozedUntilReactivation {
                alertCoordinator.snooze(id, choice: .untilReactivation, now: Date())
            } else if let until = control.snoozedUntil {
                alertCoordinator.snooze(id, until: until)
            }
        }
        camera.setPostureRecommendationSensitivity(alertSettings.sensitivity)
        connectRuntime()
    }

    init(camera: CameraCaptureService) {
        self.camera = camera
        history = PostureHistoryController()
        notificationService = LocalPostureNotificationService()
        alertSettings = PostureAlertSettingsStore().load()
        alertCoordinator.setSensitivity(alertSettings.sensitivity)
        restoreAlertDeliveryState()
        for (id, control) in alertSettings.controls {
            alertCoordinator.setEnabled(control.isEnabled, for: id)
            if control.isSnoozedUntilReactivation {
                alertCoordinator.snooze(id, choice: .untilReactivation, now: Date())
            } else if let until = control.snoozedUntil {
                alertCoordinator.snooze(id, until: until)
            }
        }
        camera.setPostureRecommendationSensitivity(alertSettings.sensitivity)
        connectRuntime()
    }

    private func connectRuntime() {
        camera.$postureObservations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in self?.consume(snapshot) }
            .store(in: &observationCancellables)
        camera.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.runtimeAcceptsObservations = (state == .running)
                if state != .running {
                    // Invalidate any delivery awaiting macOS authorization or
                    // transport. A later state transition must not let that
                    // task commit into the new activation.
                    self.runtimeToken &+= 1
                    self.cancelPendingDeliveries()
                    self.alertCoordinator.resetTracking()
                    let stopUptime = ProcessInfo.processInfo.systemUptime
                    let stopWall = Date().timeIntervalSince1970
                    self.flushCoverage(at: stopUptime,
                                       wallNow: stopWall)
                    self.flushSignalDurations(at: stopUptime, wallNow: stopWall)
                    self.coverageStarts.removeAll(keepingCapacity: true)
                    self.coverageLastRecorded.removeAll(keepingCapacity: true)
                    self.signalDurationLastObserved.removeAll(keepingCapacity: true)
                    self.signalDurationAssessment.removeAll(keepingCapacity: true)
                    self.attentionEpisodeStartedAt.removeAll(keepingCapacity: true)
                    self.lastHistoryState.removeAll(keepingCapacity: true)
                    self.coverageWallOffset = nil
                }
            }
            .store(in: &observationCancellables)
        camera.$calibrationPresentation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presentation in
                guard let self else { return }
                if case .collecting = presentation.phase {
                    self.runtimeToken &+= 1
                    self.cancelPendingDeliveries()
                    self.alertCoordinator.resetTracking()
                }
            }
            .store(in: &observationCancellables)
    }

    private func consume(_ snapshot: PostureObservationsSnapshot) {
        guard runtimeAcceptsObservations else { return }
        guard !snapshot.contextKey.isEmpty else { return }
        guard snapshot.generation >= lastObservationGeneration else { return }
        let contextChanged = snapshot.contextKey != lastObservationContextKey
        if snapshot.generation != lastObservationGeneration || contextChanged {
            runtimeToken &+= 1
            flushCoverage(at: snapshot.producedAt, wallNow: Date().timeIntervalSince1970)
            flushSignalDurations(at: snapshot.producedAt,
                                 wallNow: Date().timeIntervalSince1970)
            lastHistoryState.removeAll(keepingCapacity: true)
            alertCoordinator.resetTracking()
            coverageStarts.removeAll(keepingCapacity: true)
            coverageLastRecorded.removeAll(keepingCapacity: true)
            signalDurationLastObserved.removeAll(keepingCapacity: true)
            signalDurationAssessment.removeAll(keepingCapacity: true)
            attentionEpisodeStartedAt.removeAll(keepingCapacity: true)
            coverageWallOffset = nil
            lastObservationGeneration = snapshot.generation
            lastObservationContextKey = snapshot.contextKey
            observationContextEpoch &+= 1
        }
        let now = Date().timeIntervalSince1970
        coverageWallOffset = coverageWallOffset ?? (now - snapshot.producedAt)
        if let candidate = alertCoordinator.consume(
            snapshot, now: now, freshnessNow: ProcessInfo.processInfo.systemUptime
        ) {
            let request = PostureAlertCandidate(
                identifier: "\(candidate.identifier).s\(launchSessionID)",
                signalID: candidate.signalID,
                generation: candidate.generation,
                contextKey: candidate.contextKey,
                episodeID: candidate.episodeID,
                reservationID: candidate.reservationID,
                createdAt: candidate.createdAt,
                isExperimental: candidate.isExperimental,
                sensitivity: candidate.sensitivity,
                ruleProfileID: candidate.ruleProfileID
            )
            let token = runtimeToken
            pendingDeliveryRequests[request.identifier] = candidate
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.runtimeAcceptsObservations,
                      token == self.runtimeToken,
                      candidate.generation == self.lastObservationGeneration,
                      candidate.contextKey == self.lastObservationContextKey,
                      self.pendingDeliveryRequests[request.identifier] != nil,
                      self.alertCoordinator.ownsReservation(candidate, now: Date().timeIntervalSince1970) else {
                    self.alertCoordinator.releaseDelivery(candidate, now: Date().timeIntervalSince1970)
                    self.pendingDeliveryRequests.removeValue(forKey: request.identifier)
                    return
                }
                let delivered = await self.notificationService.deliver(candidate: request)
                guard self.runtimeAcceptsObservations,
                      token == self.runtimeToken,
                      candidate.generation == self.lastObservationGeneration,
                      candidate.contextKey == self.lastObservationContextKey,
                      self.pendingDeliveryRequests[request.identifier] != nil,
                      self.alertCoordinator.ownsReservation(candidate, now: Date().timeIntervalSince1970) else {
                    await self.notificationService.retract(identifier: request.identifier)
                    self.alertCoordinator.releaseDelivery(candidate, now: Date().timeIntervalSince1970)
                    self.pendingDeliveryRequests.removeValue(forKey: request.identifier)
                    return
                }
                if delivered {
                    guard self.alertCoordinator.commitDelivery(candidate, now: Date().timeIntervalSince1970) else {
                        await self.notificationService.retract(identifier: request.identifier)
                        self.pendingDeliveryRequests.removeValue(forKey: request.identifier)
                        return
                    }
                    self.pendingDeliveryRequests.removeValue(forKey: request.identifier)
                    let historyKey = "\(self.launchSessionID):alert:source=runtime:g\(candidate.generation):c\(self.observationContextEpoch):s=\(candidate.signalID.rawValue):e\(candidate.episodeID):r\(candidate.reservationID)"
                    guard self.lastHistoryKey.insert(historyKey).inserted else { return }
                    self.persistAlertDeliveryState()
                    let observation = PostureHistoryObservation(
                        date: Date(timeIntervalSince1970: now), signalID: candidate.signalID,
                        sensitivity: candidate.sensitivity,
                        ruleProfileID: candidate.ruleProfileID, observedDuration: 0,
                        attentionDuration: 0, beganOpportunity: true,
                        acceptedEventCount: 1, deliveredNotification: true,
                        recoveryDuration: nil, eventKey: historyKey,
                        blinkEventCount: 0
                    )
                    await self.history.record(observation, now: Date(timeIntervalSince1970: now))
                } else {
                    self.alertCoordinator.releaseDelivery(
                        candidate, now: Date().timeIntervalSince1970
                    )
                    self.pendingDeliveryRequests.removeValue(forKey: request.identifier)
                }
            }
        }
        for signal in snapshot.signals {
            let previous = lastHistoryState[signal.signalID]
            let transitionAt = signal.observedAt ?? signal.producedAt
            if signal.availability == .available,
               signal.quality == .good,
               signal.assessment == .attention,
               (previous?.assessment != .attention || previous?.episodeID != signal.episodeID),
               transitionAt.isFinite {
                attentionEpisodeStartedAt[signal.signalID] = transitionAt
            }
            let changed = previous?.availability != signal.availability ||
                previous?.assessment != signal.assessment ||
                previous?.episodeID != signal.episodeID
            if changed, let previous {
                if let previousAt = signalDurationLastObserved[signal.signalID],
                   transitionAt > previousAt {
                    recordSignalDuration(previous, start: previousAt, end: transitionAt,
                                         wallNow: now,
                                         assessment: signalDurationAssessment[signal.signalID] ?? previous.assessment,
                                         generation: lastObservationGeneration)
                    signalDurationLastObserved[signal.signalID] = transitionAt
                }
                let recoveredFromAttention = previous.assessment == .attention &&
                    signal.availability == .available && signal.quality == .good &&
                    signal.assessment == .withinReference
                let recoveryDuration = recoveredFromAttention
                    ? attentionEpisodeStartedAt[signal.signalID].flatMap {
                        transitionAt >= $0 ? transitionAt - $0 : nil
                    }
                    : nil
                let transition = PostureHistoryObservation(
                    date: Date(timeIntervalSince1970: now), signalID: signal.signalID,
                    sensitivity: alertCoordinator.sensitivity, ruleProfileID: "runtime-v2",
                    observedDuration: 0, attentionDuration: 0,
                    beganOpportunity: signal.assessment == .attention &&
                        signal.episodeID != previous.episodeID,
                    acceptedEventCount: 0, deliveredNotification: false,
                    recoveryDuration: recoveryDuration,
                    eventKey: "\(launchSessionID):transition:source=runtime:g\(snapshot.generation):c\(observationContextEpoch):s=\(signal.signalID.rawValue):e\(signal.episodeID ?? 0):t\(signal.producedAt)"
                )
                history.enqueue(transition)
                if recoveredFromAttention || signal.availability != .available ||
                    signal.quality != .good {
                    attentionEpisodeStartedAt.removeValue(forKey: signal.signalID)
                }
            }
            if signal.quality == .good, let observedAt = signal.observedAt,
               observedAt.isFinite {
                let previousObservedAt = signalDurationLastObserved[signal.signalID] ?? observedAt
                if observedAt > previousObservedAt,
                   observedAt - previousObservedAt >= coverageFlushInterval {
                    recordSignalDuration(signal, start: previousObservedAt, end: observedAt,
                                         wallNow: now,
                                         assessment: signal.assessment,
                                         generation: lastObservationGeneration)
                    signalDurationLastObserved[signal.signalID] = observedAt
                } else if signalDurationLastObserved[signal.signalID] == nil {
                    signalDurationLastObserved[signal.signalID] = observedAt
                }
            } else {
                if let start = signalDurationLastObserved[signal.signalID] {
                    let end = signal.observedAt ?? signal.producedAt
                    let previousAssessment = signalDurationAssessment[signal.signalID] ?? signal.assessment
                    if end > start {
                        recordSignalDuration(signal, start: start, end: end, wallNow: now,
                                             assessment: previousAssessment,
                                             generation: lastObservationGeneration)
                    }
                }
                signalDurationLastObserved.removeValue(forKey: signal.signalID)
            }
            signalDurationAssessment[signal.signalID] = signal.assessment
            lastHistoryState[signal.signalID] = signal
        }
        if snapshot.blinkEventCount > 0 {
            let eventKey = "\(launchSessionID):blink:source=face:g\(snapshot.generation):c\(observationContextEpoch):s=\(PostureObservationSignalID.estimatedBlinks.rawValue):t\(snapshot.producedAt)"
            if lastHistoryKey.insert(eventKey).inserted {
                let observation = PostureHistoryObservation(
                    date: Date(timeIntervalSince1970: now), signalID: .estimatedBlinks,
                    sensitivity: alertCoordinator.sensitivity, ruleProfileID: "runtime-v2",
                    observedDuration: 0, attentionDuration: 0, beganOpportunity: false,
                    acceptedEventCount: 0, deliveredNotification: false,
                    recoveryDuration: nil, eventKey: eventKey,
                    blinkEventCount: snapshot.blinkEventCount
                )
                history.enqueue(observation)
            }
        }
        if let faceObservedAt = snapshot.faceAndEyesObservedAt {
            updateCoverage(
                .faceAndEyes,
                reliable: snapshot.faceAndEyesReliable,
                at: faceObservedAt,
                maximumGap: faceCoverageMaximumGap,
                now: now
            )
        }
        let bodySignals = PostureObservationEngine.bodySignalIDs.map(snapshot.signal)
        if bodySignals.contains(where: { $0.producedAt == snapshot.producedAt }) {
            let reliableTimes = bodySignals.compactMap { value -> TimeInterval? in
                value.availability == .available && value.quality == .good
                    ? value.observedAt : nil
            }
            updateCoverage(
                .upperBody,
                reliable: !reliableTimes.isEmpty,
                at: reliableTimes.max() ?? snapshot.producedAt,
                maximumGap: bodyCoverageMaximumGap,
                now: now
            )
        }
    }

    private func restoreAlertDeliveryState() {
        guard let data = UserDefaults.standard.data(forKey: alertDeliveryStateKey),
              let state = try? JSONDecoder().decode(PostureAlertDeliveryState.self, from: data)
        else { return }
        alertCoordinator.restoreDeliveryState(state)
    }

    private func cancelPendingDeliveries(for signalID: PostureObservationSignalID? = nil) {
        let matches = pendingDeliveryRequests.filter { signalID == nil || $0.value.signalID == signalID }
        for (identifier, candidate) in matches {
            pendingDeliveryRequests.removeValue(forKey: identifier)
            alertCoordinator.releaseDelivery(candidate, now: Date().timeIntervalSince1970)
            Task { @MainActor in
                await self.notificationService.retract(identifier: identifier)
            }
        }
    }

    private func persistAlertDeliveryState() {
        guard let data = try? JSONEncoder().encode(alertCoordinator.deliveryState()) else { return }
        UserDefaults.standard.set(data, forKey: alertDeliveryStateKey)
    }

    func setRecommendationSensitivity(_ value: PostureRecommendationSensitivity) {
        runtimeToken &+= 1
        cancelPendingDeliveries()
        alertSettings.sensitivity = value
        alertSettings.sensitivityWasChosenByUser = true
        PostureAlertSettingsStore().save(alertSettings)
        alertCoordinator.setSensitivity(value)
        camera.setPostureRecommendationSensitivity(value)
        objectWillChange.send()
        history.enqueueControlEvent(.init(
            date: Date(), signalID: nil, action: .sensitivityChanged,
            sensitivity: value, ruleProfileID: "runtime-v2"
        ))
    }

    func setAlertEnabled(_ enabled: Bool, for id: PostureObservationSignalID) {
        runtimeToken &+= 1
        cancelPendingDeliveries(for: id)
        alertSettings.controls[id, default: .init()].isEnabled = enabled
        if enabled {
            alertSettings.controls[id]?.isSnoozedUntilReactivation = false
            alertSettings.controls[id]?.snoozedUntil = nil
        }
        PostureAlertSettingsStore().save(alertSettings)
        alertCoordinator.setEnabled(enabled, for: id)
        objectWillChange.send()
        history.enqueueControlEvent(.init(
            date: Date(), signalID: id,
            action: enabled ? .reactivated : .disabled,
            sensitivity: alertCoordinator.sensitivity, ruleProfileID: "runtime-v2"
        ))
    }

    func snoozeAlert(_ id: PostureObservationSignalID, choice: PostureSnoozeChoice, now: Date = Date()) {
        runtimeToken &+= 1
        cancelPendingDeliveries(for: id)
        alertCoordinator.snooze(id, choice: choice, now: now)
        switch choice {
        case .untilReactivation:
            alertSettings.controls[id, default: .init()].snoozedUntil = nil
            alertSettings.controls[id, default: .init()].isSnoozedUntilReactivation = true
        case .oneHour:
            alertSettings.controls[id, default: .init()].snoozedUntil = now.addingTimeInterval(3_600).timeIntervalSince1970
            alertSettings.controls[id, default: .init()].isSnoozedUntilReactivation = false
        case .today:
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))
            alertSettings.controls[id, default: .init()].snoozedUntil = tomorrow?.timeIntervalSince1970
            alertSettings.controls[id, default: .init()].isSnoozedUntilReactivation = false
        }
        PostureAlertSettingsStore().save(alertSettings)
        objectWillChange.send()
        history.enqueueControlEvent(.init(
            date: now, signalID: id, action: .snoozed,
            sensitivity: alertCoordinator.sensitivity, ruleProfileID: "runtime-v2"
        ))
    }

    func reactivateAlert(_ id: PostureObservationSignalID) {
        runtimeToken &+= 1
        cancelPendingDeliveries(for: id)
        alertCoordinator.reactivate(id)
        alertSettings.controls[id, default: .init()].snoozedUntil = nil
        alertSettings.controls[id, default: .init()].isSnoozedUntilReactivation = false
        PostureAlertSettingsStore().save(alertSettings)
        objectWillChange.send()
        history.enqueueControlEvent(.init(
            date: Date(), signalID: id, action: .reactivated,
            sensitivity: alertCoordinator.sensitivity, ruleProfileID: "runtime-v2"
        ))
    }

    private func updateCoverage(
        _ channel: PostureCoverageChannel,
        reliable: Bool,
        at uptime: TimeInterval,
        maximumGap: TimeInterval,
        now wallNow: TimeInterval
    ) {
        guard uptime.isFinite, maximumGap.isFinite, maximumGap > 0 else { return }
        guard reliable else {
            flushCoverage(channel, wallNow: wallNow)
            return
        }
        guard let previous = coverageLastRecorded[channel] else {
            coverageStarts[channel] = uptime
            coverageLastRecorded[channel] = uptime
            return
        }
        guard uptime > previous else { return }
        if uptime - previous > maximumGap {
            flushCoverage(channel, wallNow: wallNow)
            coverageStarts[channel] = uptime
            coverageLastRecorded[channel] = uptime
            return
        }
        let start = coverageStarts[channel] ?? previous
        coverageStarts[channel] = start
        coverageLastRecorded[channel] = uptime
        if uptime - start >= coverageFlushInterval {
            recordCoverage(channel: channel, start: start, end: uptime, wallNow: wallNow)
            coverageStarts[channel] = uptime
        }
    }

    private func recordCoverage(
        channel: PostureCoverageChannel,
        start: TimeInterval,
        end: TimeInterval,
        wallNow: TimeInterval
    ) {
        guard end > start, start.isFinite, end.isFinite else { return }
        let offset = coverageWallOffset ?? (wallNow - end)
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: start + offset),
            end: Date(timeIntervalSince1970: end + offset)
        )
        history.enqueueCoverage(channel: channel, interval: interval)
    }

    private func flushCoverage(at uptime: TimeInterval, wallNow: TimeInterval) {
        _ = uptime
        for channel in Array(coverageStarts.keys) {
            flushCoverage(channel, wallNow: wallNow)
        }
    }

    private func flushCoverage(_ channel: PostureCoverageChannel, wallNow: TimeInterval) {
        guard let start = coverageStarts.removeValue(forKey: channel) else {
            coverageLastRecorded.removeValue(forKey: channel)
            return
        }
        let last = coverageLastRecorded.removeValue(forKey: channel) ?? start
        if last > start {
            recordCoverage(channel: channel, start: start, end: last, wallNow: wallNow)
        }
    }

    private func recordSignalDuration(
        _ signal: PostureSignalSnapshot,
        start: TimeInterval,
        end: TimeInterval,
        wallNow: TimeInterval,
        assessment: PostureObservationAssessment?,
        generation: UInt64
    ) {
        guard end > start, start.isFinite, end.isFinite else { return }
        let duration = end - start
        let observation = PostureHistoryObservation(
            date: Date(timeIntervalSince1970: wallNow - duration),
            signalID: signal.signalID,
            sensitivity: alertCoordinator.sensitivity,
            ruleProfileID: "runtime-v2",
            observedDuration: duration,
            attentionDuration: assessment == .attention ? duration : 0,
            beganOpportunity: false,
            acceptedEventCount: 0,
            deliveredNotification: false,
            recoveryDuration: nil,
            eventKey: "\(launchSessionID):duration:source=runtime:g\(generation):c\(observationContextEpoch):s=\(signal.signalID.rawValue):e\(signal.episodeID ?? 0):t\(start)"
        )
        history.enqueue(observation)
    }

    private func flushSignalDurations(at uptime: TimeInterval, wallNow: TimeInterval) {
        for (signalID, start) in signalDurationLastObserved {
            guard uptime > start else { continue }
            let signal = lastHistoryState[signalID] ?? .unavailable(
                signalID, generation: lastObservationGeneration, at: uptime,
                reason: "Observation terminée"
            )
            recordSignalDuration(signal, start: start, end: uptime, wallNow: wallNow,
                                 assessment: signalDurationAssessment[signalID] ?? signal.assessment,
                                 generation: lastObservationGeneration)
        }
    }

    func quit() {
        guard !isTerminating else { return }
        isTerminating = true
        camera.stop { [weak self] in
            Task { @MainActor in
                if let self { await self.history.flushPending() }
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
