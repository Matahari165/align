@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreMedia
import Foundation

nonisolated struct CameraAnalysisDiagnostics: Sendable {
    static let empty = CameraAnalysisDiagnostics(
        frameCallbacks: 0,
        analyses: 0,
        candidateOrientation: "—",
        lockedOrientation: nil,
        faceOrientation: nil,
        faceGeometry: nil,
        faceResults: 0,
        facesWithLandmarks: 0,
        facePoints: 0,
        bodyResults: 0,
        upperBodyEngineID: "—",
        upperBodyAttempts: 0,
        upperBodyResults: 0,
        upperBodyLastStatus: "—",
        upperBodyLastRejectionReason: nil,
        upperBodyRejected: 0,
        upperBodyEngineRuns: 0,
        upperBodyEngineDurationP95: nil,
        upperBodyEngineDurationMax: nil,
        upperBodyValidLandmarks: 0,
        upperBodyLeftShoulderScore: nil,
        upperBodyRightShoulderScore: nil,
        upperBodySimCCMinimum: nil,
        upperBodySimCCMaximum: nil,
        upperBodyScoreMinimum: nil,
        upperBodyScoreMaximum: nil,
        upperBodyLatency: nil,
        upperBodyResultAge: nil,
        upperBodyLandmarks: .empty,
        upperBodyROISpike: .empty,
        segmentationAttempts: 0,
        segmentationVisionPerforms: 0,
        segmentationResults: 0,
        segmentationContoursValid: 0,
        segmentationInsufficient: 0,
        segmentationErrors: 0,
        segmentationDurationP50: nil,
        segmentationDurationP95: nil,
        segmentationDurationMax: nil,
        segmentationState: .notRequested,
        lastVisionError: nil
    )

    let frameCallbacks: Int
    let analyses: Int
    let candidateOrientation: String
    let lockedOrientation: String?
    let faceOrientation: FaceOrientationSignal?
    let faceGeometry: FaceGeometrySignal?
    let faceResults: Int
    let facesWithLandmarks: Int
    let facePoints: Int
    let bodyResults: Int
    let upperBodyEngineID: String
    let upperBodyAttempts: Int
    let upperBodyResults: Int
    let upperBodyLastStatus: String
    let upperBodyLastRejectionReason: String?
    let upperBodyRejected: Int
    let upperBodyEngineRuns: Int
    let upperBodyEngineDurationP95: TimeInterval?
    let upperBodyEngineDurationMax: TimeInterval?
    let upperBodyValidLandmarks: Int
    let upperBodyLeftShoulderScore: Float?
    let upperBodyRightShoulderScore: Float?
    let upperBodySimCCMinimum: Float?
    let upperBodySimCCMaximum: Float?
    let upperBodyScoreMinimum: Float?
    let upperBodyScoreMaximum: Float?
    let upperBodyLatency: TimeInterval?
    let upperBodyResultAge: TimeInterval?
    let upperBodyLandmarks: UpperBodyLandmarkDiagnostics
    let upperBodyROISpike: UpperBodyROISpikeDiagnostics
    let segmentationAttempts: Int
    let segmentationVisionPerforms: Int
    let segmentationResults: Int
    let segmentationContoursValid: Int
    let segmentationInsufficient: Int
    let segmentationErrors: Int
    let segmentationDurationP50: TimeInterval?
    let segmentationDurationP95: TimeInterval?
    let segmentationDurationMax: TimeInterval?
    let segmentationState: PersonSegmentationAvailability
    let lastVisionError: String?

    var summary: String {
        let orientation = lockedOrientation.map { "\(candidateOrientation)→\($0)" }
            ?? candidateOrientation
        let error = lastVisionError.map { " · erreur: \($0)" } ?? ""
        let faceOrientationSummary = faceOrientation.map { " · visage \($0.summary)" } ?? ""
        let faceGeometrySummary = faceGeometry.map { " · géométrie \($0.summary)" } ?? ""
        let legacyVisionBody = bodyResults > 0 || upperBodyLandmarks.recognizedCount > 0
            ? " · Vision Body benchmark \(bodyResults) résultat(s), \(upperBodyLandmarks.recognizedCount)/3 repères"
            : ""
        let segmentation = " · silhouette \(segmentationState.displayName) · cadence/performs/valid \(segmentationAttempts)/\(segmentationVisionPerforms)/\(segmentationContoursValid), \(segmentationDurationP95.map { String(format: "p95 %.0f ms", $0 * 1_000) } ?? "p95 —")"
        let roiSpike = upperBodyROISpike.rectangleAttempts > 0 ? " · spike ROI \(upperBodyROISpike.summary)" : ""
        let leftShoulder = upperBodyLeftShoulderScore.map { String(format: "%.3f", $0) } ?? "—"
        let rightShoulder = upperBodyRightShoulderScore.map { String(format: "%.3f", $0) } ?? "—"
        let simCCRange = formattedRange(upperBodySimCCMinimum, upperBodySimCCMaximum)
        let scoreRange = formattedRange(upperBodyScoreMinimum, upperBodyScoreMaximum)
        let latency = upperBodyLatency.map { String(format: "%.0f ms", $0 * 1_000) } ?? "—"
        let age = upperBodyResultAge.map { String(format: "%.0f ms", $0 * 1_000) } ?? "—"
        let engine = " · upperBody \(upperBodyEngineID) attempts/results \(upperBodyAttempts)/\(upperBodyResults) · statut \(upperBodyLastStatus) · repères valides \(upperBodyValidLandmarks) · SimCC \(simCCRange) · scores \(scoreRange) · épaules G/D \(leftShoulder)/\(rightShoulder) · latence \(latency) · âge \(age)"
        let rejection = upperBodyLastRejectionReason.map { " · rejet \($0)" } ?? ""
        let engineP95 = upperBodyEngineDurationP95.map { String(format: "%.0f ms", $0 * 1_000) } ?? "—"
        let engineMax = upperBodyEngineDurationMax.map { String(format: "%.0f ms", $0 * 1_000) } ?? "—"
        let engineTiming = " · moteur \(upperBodyEngineRuns) appels, p95 \(engineP95), max \(engineMax)"
        let rejected = upperBodyRejected > 0 ? " · rejets \(upperBodyRejected)" : ""
        return "Frames \(frameCallbacks) · analyses \(analyses) · orientation \(orientation) · faces \(faceResults) / landmarks \(facesWithLandmarks) / points \(facePoints)\(engine)\(rejection)\(rejected)\(engineTiming)\(legacyVisionBody)\(segmentation)\(roiSpike)\(faceOrientationSummary)\(faceGeometrySummary)\(error)"
    }

    private func formattedRange(_ minimum: Float?, _ maximum: Float?) -> String {
        guard let minimum, let maximum else { return "—" }
        return String(format: "%.3f…%.3f", minimum, maximum)
    }
}

enum BenchmarkViewState {
    case idle
    case running(BenchmarkProgress)
    case completed(String)
    case invalidated(String)
}

@MainActor
final class CameraCaptureService: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case configuring
        case running
        case denied
        case unavailable
        case interrupted
        case failed(String)

        var message: String {
            switch self {
            case .idle:
                "La caméra est arrêtée."
            case .requestingPermission:
                "Align attend l’autorisation d’utiliser la caméra."
            case .configuring:
                "Préparation de la caméra…"
            case .running:
                "Analyse locale en cours."
            case .denied:
                "L’accès à la caméra est désactivé dans Réglages Système > Confidentialité et sécurité > Caméra."
            case .unavailable:
                "Aucune caméra compatible n’est disponible."
            case .interrupted:
                "L’analyse est interrompue parce que la caméra n’est momentanément plus disponible."
            case .failed(let message):
                message
            }
        }
    }

    let session = AVCaptureSession()

    @Published private(set) var state: State = .idle
    @Published private(set) var trackingMode: PoseTrackingMode?
    @Published private(set) var recognizedPointCount = 0
    @Published private(set) var overlay = PoseOverlay.empty
    @Published private(set) var blazePoseState: ShoulderTrackingState?
    @Published private(set) var postureIndicators = PostureIndicatorsSnapshot.initial
    @Published private(set) var postureRichEvaluation: PostureRichEvaluation?
    @Published private(set) var postureObservations: PostureObservationsSnapshot = .init(generation: 0, producedAt: 0, signals: [])
    @Published private(set) var proximityNotificationAuthorization: LocalPostureNotificationService.Authorization = .unknown
    @Published private(set) var diagnostics = CameraAnalysisDiagnostics.empty
    @Published private(set) var benchmarkState: BenchmarkViewState = .idle
    @Published private(set) var upperBodyDevelopmentVisualizationEnabled =
        UserDefaults.standard.bool(forKey: "UpperBodyDevelopmentVisualizationEnabled")
    @Published private(set) var upperBodyDevelopmentOptions = UpperBodyDevelopmentOptions.stored()
    @Published private(set) var upperBodyDevelopmentSummary = "Torse · en attente"
    @Published private(set) var calibrationPresentation = PostureCalibrationPresentation.idle

    private let sampleQueue = DispatchQueue(label: "com.align.camera.samples")
    private var notificationCancellables: Set<AnyCancellable> = []
    private var operationID = 0
    private var activationID = 0
    private var activePoseGeneration: PoseProcessingGeneration?
    private var benchmarkSession: BenchmarkSession?
    private var benchmarkExperiment: BenchmarkVisionExperiment?
    private var benchmarkSegmentationEpoch = BenchmarkSegmentationEpoch()
    private let benchmarkSegmentationCancellation = BenchmarkSegmentationCancellationBox()
    private var benchmarkProgressTask: Task<Void, Never>?
    private var isApplicationActive = true
    private var isSystemApplicationActive = NSApplication.shared.isActive
    private var isWindowMiniaturized = false
    /// Intention de cycle de vie, indépendante de la confirmation asynchrone de la session.
    /// Elle empêche une notification de démarrage tardive de ressusciter une session arrêtée.
    private var wantsCameraRunning = false
    /// Verrou explicite posé par stop(). Il est levé uniquement par un nouveau start().
    /// La session réelle reste donc la source de vérité, sauf après un arrêt demandé.
    private var sessionReconciliationSuppressed = false
    private var explicitStopRequested = false
    private var livenessEpoch: UInt64 = 0
    private var startIntentEpoch: UInt64?
    private let proximityNotificationService = LocalPostureNotificationService()
    private lazy var sampleDelegate: PoseSampleBufferDelegate = PoseSampleBufferDelegate(
        sampleQueue: sampleQueue,
        segmentationCancellation: benchmarkSegmentationCancellation,
        onFrameLiveness: { [weak self] epoch in
            Task { @MainActor [weak self] in
                self?.reconcileFrameLiveness(epoch: epoch)
            }
        }
    ) { [weak self] event, generation in
        Task { @MainActor [weak self] in
            guard let self,
                  self.operationID == generation.operationID,
                  self.activePoseGeneration == generation,
                  self.state == .running else { return }

            switch event {
            case .status(let status):
                self.recognizedPointCount = status?.recognizedPointCount ?? 0
                self.trackingMode = status?.mode
            case .analysisFailed:
                self.invalidateBenchmark(reason: "Benchmark annulé : l’analyse Vision s’est interrompue.")
                self.setPoseProcessingActive(false, resetDiagnostics: false)
                self.recognizedPointCount = 0
                self.trackingMode = nil
                self.state = .failed("L’analyse de la pose s’est interrompue. Arrêtez puis relancez la caméra.")
            case .diagnostics(let diagnostics):
                if self.currentAnalysisPresentation.publishesVisualUpdates {
                    self.diagnostics = diagnostics
                }
            case .overlay(let overlay):
                if self.currentAnalysisPresentation.publishesVisualUpdates {
                    self.overlay = overlay
                }
            case .upperBodyPresentation(let overlay, let state):
                if self.currentAnalysisPresentation.publishesVisualUpdates {
                    self.overlay = overlay
                    self.blazePoseState = state
                } else {
                    self.overlay = .empty
                    self.blazePoseState = .lost
                }
            case .upperBodyDevelopmentSummary(let summary):
                self.upperBodyDevelopmentSummary = summary
            case .postureIndicators(let snapshot):
                self.postureIndicators = snapshot
            case .postureRichEvaluation(let evaluation):
                self.postureRichEvaluation = evaluation
            case .postureObservations(let snapshot):
                self.postureObservations = snapshot
            case .calibration(let presentation):
                self.calibrationPresentation = presentation
            case .silhouetteOverlay(let overlay, let token):
                guard self.benchmarkSegmentationEpoch.accepts(
                    token,
                    benchmarkRunning: self.benchmarkSession != nil
                ) else { return }
                if self.currentAnalysisPresentation.publishesVisualUpdates {
                    self.overlay = overlay
                }
            case .benchmarkMeasurement(let measurement, let uptime):
                self.benchmarkSession?.record(measurement, at: uptime)
            case .benchmarkOverlayVisibility(let visible, let uptime):
                self.benchmarkSession?.recordOverlay(visible: visible, at: uptime)
            }
        }
    }
    private lazy var sessionRuntime = CameraSessionRuntime(
        session: session,
        sampleQueue: sampleQueue,
        sampleDelegate: sampleDelegate
    )

    init() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.proximityNotificationAuthorization = await self.proximityNotificationService.authorization()
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.isSystemApplicationActive = true
                Task { @MainActor in
                    self.proximityNotificationAuthorization = await self.proximityNotificationService.authorization()
                }
            }
            .store(in: &notificationCancellables)

        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.isSystemApplicationActive = false }
            .store(in: &notificationCancellables)

        NotificationCenter.default.publisher(for: AVCaptureSession.wasInterruptedNotification, object: session)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.invalidateBenchmark(reason: "Benchmark annulé : la caméra a été interrompue.")
                self?.sessionReconciliationSuppressed = true
                self?.setPoseProcessingActive(false)
                self?.state = .interrupted
                self?.recognizedPointCount = 0
                self?.trackingMode = nil
                self?.overlay = .empty
                self?.postureObservations = .init(
                    generation: UInt64(self?.activePoseGeneration?.activationID ?? 0),
                    producedAt: ProcessInfo.processInfo.systemUptime, signals: []
                )
                self?.calibrationPresentation = .idle
            }
            .store(in: &notificationCancellables)

        NotificationCenter.default.publisher(for: AVCaptureSession.interruptionEndedNotification, object: session)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.state == .interrupted, self.session.isRunning else { return }
                self.sessionReconciliationSuppressed = false
                self.wantsCameraRunning = true
                self.setPoseProcessingActive(true)
                self.state = .running
            }
            .store(in: &notificationCancellables)

        NotificationCenter.default.publisher(for: AVCaptureSession.runtimeErrorNotification, object: session)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, self.state != .idle else { return }
                self.invalidateBenchmark(reason: "Benchmark annulé : une erreur caméra est survenue.")
                self.sessionReconciliationSuppressed = true
                self.setPoseProcessingActive(false)
                self.recognizedPointCount = 0
                self.trackingMode = nil
                self.overlay = .empty
                self.postureObservations = .init(
                    generation: UInt64(self.activePoseGeneration?.activationID ?? 0),
                    producedAt: ProcessInfo.processInfo.systemUptime, signals: []
                )
                self.calibrationPresentation = .idle

                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self.state = .failed(
                    error.map { "L’analyse caméra s’est interrompue : \($0.localizedDescription)" }
                        ?? "L’analyse caméra s’est interrompue à cause d’une erreur système."
                )
            }
            .store(in: &notificationCancellables)

        NotificationCenter.default.publisher(for: AVCaptureSession.didStartRunningNotification, object: session)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reconcileRunningSession()
            }
            .store(in: &notificationCancellables)

        NotificationCenter.default.publisher(for: AVCaptureSession.didStopRunningNotification, object: session)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.wantsCameraRunning && !self.sessionReconciliationSuppressed {
                    self.setPoseProcessingActive(false)
                    self.state = .failed("La caméra s’est arrêtée avant la fin de l’analyse.")
                } else if self.state == .configuring {
                    self.setPoseProcessingActive(false)
                    self.state = .idle
                }
            }
            .store(in: &notificationCancellables)
    }

    func requestProximityNotificationAuthorization() {
        if proximityNotificationAuthorization == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.proximityNotificationAuthorization = await self.proximityNotificationService.requestAuthorization()
        }
    }

    func start() {
        guard state != .running, state != .configuring, state != .requestingPermission else {
            return
        }

        wantsCameraRunning = true
        sessionReconciliationSuppressed = false
        explicitStopRequested = false
        livenessEpoch &+= 1
        startIntentEpoch = livenessEpoch
        let requestedLivenessEpoch = livenessEpoch
        let livenessDelegate = sampleDelegate
        sampleQueue.sync {
            livenessDelegate.setLivenessEpoch(requestedLivenessEpoch)
        }
        if session.isRunning {
            reconcileRunningSession()
            return
        }

        operationID += 1
        let currentOperationID = operationID

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart(operationID: currentOperationID)
        case .notDetermined:
            state = .requestingPermission
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard operationID == currentOperationID else { return }
                guard granted else {
                    wantsCameraRunning = false
                    sessionReconciliationSuppressed = true
                    startIntentEpoch = nil
                    state = .denied
                    return
                }
                configureAndStart(operationID: currentOperationID)
            }
        case .denied, .restricted:
            wantsCameraRunning = false
            sessionReconciliationSuppressed = true
            startIntentEpoch = nil
            state = .denied
        @unknown default:
            wantsCameraRunning = false
            sessionReconciliationSuppressed = true
            startIntentEpoch = nil
            state = .failed("L’état de l’autorisation caméra est inconnu.")
        }
    }

    func stop(completion: (@MainActor @Sendable () -> Void)? = nil) {
        cancelBenchmark()
        wantsCameraRunning = false
        sessionReconciliationSuppressed = true
        explicitStopRequested = true
        livenessEpoch &+= 1
        startIntentEpoch = nil
        let stoppedLivenessEpoch = livenessEpoch
        let livenessDelegate = sampleDelegate
        sampleQueue.sync {
            livenessDelegate.setLivenessEpoch(stoppedLivenessEpoch)
        }
        operationID += 1
        setPoseProcessingActive(false)
        recognizedPointCount = 0
        trackingMode = nil
        overlay = .empty
        blazePoseState = nil
        postureIndicators = .initial
        postureRichEvaluation = nil
        calibrationPresentation = .idle
        postureObservations = .init(
            generation: UInt64(activePoseGeneration?.activationID ?? 0),
            producedAt: ProcessInfo.processInfo.systemUptime,
            signals: []
        )
        state = .idle
        sessionRuntime.stop(operationID: operationID) {
            guard let completion else { return }
            Task { @MainActor in
                completion()
            }
        }
    }

    func calibratePosture() {
        guard state == .running, let generation = activePoseGeneration else { return }
        calibrationPresentation = .init(
            phase: .collecting, progress: 0, outcomes: Dictionary(
                uniqueKeysWithValues: PostureObservationSignalID.allCases.map { ($0, .pending) }
            )
        )
        let delegate = sampleDelegate
        sampleQueue.async {
            delegate.beginPostureCalibration(generation: generation)
        }
    }

    func setUpperBodyDevelopmentVisualizationEnabled(_ isEnabled: Bool) {
        upperBodyDevelopmentVisualizationEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "UpperBodyDevelopmentVisualizationEnabled")
        let delegate = sampleDelegate
        sampleQueue.async {
            delegate.setUpperBodyDevelopmentVisualizationEnabled(isEnabled)
        }
    }

    /// Met à jour les règles riches sur la même file que les échantillons.
    /// Aucun second moteur n'est créé et la génération reste inchangée.
    func setPostureRecommendationSensitivity(_ sensitivity: PostureRecommendationSensitivity) {
        let delegate = sampleDelegate
        sampleQueue.async {
            delegate.setPostureRecommendationSensitivity(sensitivity)
        }
    }

    func updateUpperBodyDevelopmentOptions(
        _ update: (inout UpperBodyDevelopmentOptions) -> Void
    ) {
        update(&upperBodyDevelopmentOptions)
        upperBodyDevelopmentOptions.store()
        let options = upperBodyDevelopmentOptions
        let delegate = sampleDelegate
        sampleQueue.async {
            delegate.setUpperBodyDevelopmentOptions(options)
        }
    }

    func startBenchmark(experiment: BenchmarkVisionExperiment) {
        guard state == .running,
              isApplicationActive,
              !isWindowMiniaturized else { return }
        benchmarkProgressTask?.cancel()
        var benchmark = BenchmarkSession()
        let uptime = ProcessInfo.processInfo.systemUptime
        benchmark.start(at: uptime)
        benchmarkExperiment = experiment
        // The token guards every expensive benchmark probe. The selected
        // experiment below decides which probe is actually eligible.
        let benchmarkToken = benchmarkSegmentationEpoch.begin()
        benchmarkSegmentationCancellation.activate(benchmarkToken)
        benchmarkSession = benchmark
        updateAnalysisPresentation()
        if let progress = benchmark.progress(at: uptime) {
            benchmarkState = .running(progress)
        }

        benchmarkProgressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, var benchmark = self.benchmarkSession else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if benchmark.isComplete(at: now) {
                    let rawReport = benchmark.finish(at: now)
                    let report = "Expérience : \(self.benchmarkExperiment?.reportName ?? "inconnue")\n\(rawReport)"
                    self.benchmarkSegmentationCancellation.invalidate()
                    self.benchmarkSegmentationEpoch.invalidate()
                    self.benchmarkSession = nil
                    self.benchmarkExperiment = nil
                    self.benchmarkState = .completed(report)
                    self.updateAnalysisPresentation()
                    return
                }
                self.benchmarkSession = benchmark
                if let progress = benchmark.progress(at: now) {
                    self.benchmarkState = .running(progress)
                }
            }
        }
    }

    func cancelBenchmark() {
        benchmarkProgressTask?.cancel()
        benchmarkProgressTask = nil
        benchmarkSegmentationCancellation.invalidate()
        benchmarkSegmentationEpoch.invalidate()
        benchmarkSession = nil
        benchmarkExperiment = nil
        benchmarkState = .idle
        updateAnalysisPresentation()
    }

    func updatePresentation(
        isApplicationActive: Bool,
        isWindowMiniaturized: Bool
    ) {
        guard self.isApplicationActive != isApplicationActive
                || self.isWindowMiniaturized != isWindowMiniaturized else { return }
        self.isApplicationActive = isApplicationActive
        self.isWindowMiniaturized = isWindowMiniaturized
        if isApplicationActive {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.proximityNotificationAuthorization = await self.proximityNotificationService.authorization()
            }
        }
        if benchmarkSession != nil,
           (!isApplicationActive || isWindowMiniaturized) {
            invalidateBenchmark(
                reason: "Benchmark annulé : garde Align visible au premier plan pendant la mesure."
            )
            return
        }
        updateAnalysisPresentation()
    }

    private func invalidateBenchmark(reason: String) {
        guard benchmarkSession != nil else { return }
        benchmarkProgressTask?.cancel()
        benchmarkProgressTask = nil
        benchmarkSegmentationCancellation.invalidate()
        benchmarkSegmentationEpoch.invalidate()
        benchmarkSession = nil
        benchmarkExperiment = nil
        benchmarkState = .invalidated(reason)
        updateAnalysisPresentation()
    }

    private func updateAnalysisPresentation() {
        let presentation = currentAnalysisPresentation
        if !presentation.publishesVisualUpdates {
            overlay = .empty
            if blazePoseState != nil { blazePoseState = .lost }
        }
        let sampleDelegate = sampleDelegate
        let benchmarkToken = benchmarkSegmentationEpoch.currentToken
        sampleQueue.async {
            sampleDelegate.updatePresentation(presentation, benchmarkToken: benchmarkToken)
        }
    }

    private var currentAnalysisPresentation: AnalysisPresentationState {
        AnalysisPresentationState(
            isApplicationActive: isApplicationActive,
            isWindowMiniaturized: isWindowMiniaturized,
            benchmarkExperiment: benchmarkSession == nil ? nil : benchmarkExperiment
        )
    }

    private func configureAndStart(operationID currentOperationID: Int) {
        guard operationID == currentOperationID,
              wantsCameraRunning,
              !sessionReconciliationSuppressed else { return }
        setPoseProcessingActive(false)
        state = .configuring

        sessionRuntime.start(operationID: currentOperationID) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self,
                      self.operationID == currentOperationID,
                      self.wantsCameraRunning else { return }

                switch result {
                case .running:
                    if self.state != .running {
                        self.setPoseProcessingActive(true)
                    }
                    self.state = .running
                case .unavailable:
                    self.setPoseProcessingActive(false)
                    self.state = .unavailable
                case .failed(let message):
                    self.setPoseProcessingActive(false)
                    self.state = .failed(message)
                }
            }
        }
    }

    /// Réconcilie l’état publié avec la session réelle. Une session peut devenir
    /// active avant le retour du callback de configuration (notamment après TCC).
    private func reconcileRunningSession() {
        guard !sessionReconciliationSuppressed, session.isRunning else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        wantsCameraRunning = true
        guard state != .running else { return }
        setPoseProcessingActive(true)
        state = .running
    }

    /// Première preuve indépendante du flux vidéo. Ce chemin ne passe pas par
    /// la garde `onEvent(state == .running)`, afin de sortir d’un éventuel cercle
    /// vicieux où l’analyse ne peut démarrer qu’après la publication de `.running`.
    private func reconcileFrameLiveness(epoch: UInt64) {
        _ = epoch // conservé pour le diagnostic; la frame réelle est la preuve d’autorité.
        guard !explicitStopRequested,
              session.isRunning,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        wantsCameraRunning = true
        sessionReconciliationSuppressed = false
        guard state != .running else { return }
        setPoseProcessingActive(true)
        state = .running
    }

    private func setPoseProcessingActive(
        _ isActive: Bool,
        resetDiagnostics: Bool = true
    ) {
        if !isActive {
        }
        activationID += 1
        let generation = PoseProcessingGeneration(
            operationID: operationID,
            activationID: activationID
        )
        activePoseGeneration = isActive ? generation : nil
        overlay = .empty
        blazePoseState = nil
        upperBodyDevelopmentSummary = "Torse · en attente"
        postureIndicators = .initial
        postureRichEvaluation = nil
        if resetDiagnostics {
            diagnostics = .empty
        }
        let sampleDelegate = sampleDelegate
        let developmentVisualizationEnabled = upperBodyDevelopmentVisualizationEnabled
        let developmentOptions = upperBodyDevelopmentOptions
        sampleQueue.async {
            sampleDelegate.setActive(isActive, generation: generation)
            sampleDelegate.setUpperBodyDevelopmentVisualizationEnabled(
                developmentVisualizationEnabled
            )
            sampleDelegate.setUpperBodyDevelopmentOptions(developmentOptions)
        }
    }
}

nonisolated private struct PoseProcessingGeneration: Equatable, Sendable {
    let operationID: Int
    let activationID: Int
}

nonisolated private enum PoseProcessingEvent: Sendable {
    case status(PoseTrackingStatus?)
    case analysisFailed
    case diagnostics(CameraAnalysisDiagnostics)
    case overlay(PoseOverlay)
    case upperBodyPresentation(PoseOverlay, ShoulderTrackingState)
    case upperBodyDevelopmentSummary(String)
    case postureIndicators(PostureIndicatorsSnapshot)
    case postureRichEvaluation(PostureRichEvaluation)
    case postureObservations(PostureObservationsSnapshot)
    case calibration(PostureCalibrationPresentation)
    case silhouetteOverlay(PoseOverlay, UInt64)
    case benchmarkMeasurement(BenchmarkMeasurement, TimeInterval)
    case benchmarkOverlayVisibility(Bool, TimeInterval)
}

private enum CameraSessionStartResult: Sendable {
    case running
    case unavailable
    case failed(String)
}

nonisolated private final class CameraSessionRuntime: @unchecked Sendable {
    private let session: AVCaptureSession
    private let queue = DispatchQueue(label: "com.align.camera.session")
    private let sampleQueue: DispatchQueue
    private let sampleDelegate: AVCaptureVideoDataOutputSampleBufferDelegate
    private var expectedOperationID = 0

    init(
        session: AVCaptureSession,
        sampleQueue: DispatchQueue,
        sampleDelegate: AVCaptureVideoDataOutputSampleBufferDelegate
    ) {
        self.session = session
        self.sampleQueue = sampleQueue
        self.sampleDelegate = sampleDelegate
    }

    func start(
        operationID: Int,
        completion: @escaping @Sendable (CameraSessionStartResult) -> Void
    ) {
        queue.async { [self] in
            guard operationID >= expectedOperationID else { return }
            expectedOperationID = operationID

            do {
                if !isConfigured {
                    session.inputs.forEach(session.removeInput)
                    session.outputs.forEach(session.removeOutput)
                    try configure()
                }

                guard operationID == expectedOperationID, isConfigured else {
                    completion(.unavailable)
                    return
                }

                session.startRunning()

                guard operationID == expectedOperationID else { return }
                completion(
                    session.isRunning
                        ? .running
                        : .failed("La caméra n’a pas confirmé son démarrage.")
                )
            } catch CameraError.cameraUnavailable {
                guard operationID == expectedOperationID else { return }
                completion(.unavailable)
            } catch {
                guard operationID == expectedOperationID else { return }
                completion(.failed("Impossible de démarrer la caméra : \(error.localizedDescription)"))
            }
        }
    }

    func stop(
        operationID: Int,
        completion: (@Sendable () -> Void)? = nil
    ) {
        queue.async { [self] in
            guard operationID >= expectedOperationID else {
                completion?()
                return
            }
            expectedOperationID = operationID
            if session.isRunning {
                session.stopRunning()
            }
            completion?()
        }
    }

    private var isConfigured: Bool {
        session.inputs.count == 1 && session.outputs.contains { $0 is AVCaptureVideoDataOutput }
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        var addedInput: AVCaptureInput?
        var addedOutput: AVCaptureOutput?

        do {
            session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .medium

            guard let camera = AVCaptureDevice.default(for: .video) else {
                throw CameraError.cameraUnavailable
            }
            (sampleDelegate as? PoseSampleBufferDelegate)?.setCameraIdentifier(camera.uniqueID)

            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                throw CameraError.inputUnavailable
            }
            session.addInput(input)
            addedInput = input

            try camera.lockForConfiguration()
            let supportedRanges = camera.activeFormat.videoSupportedFrameRateRanges.map {
                (minimum: $0.minFrameRate, maximum: $0.maxFrameRate)
            }
            if let selectedRate = CameraCaptureRatePolicy.framesPerSecond(for: supportedRanges) {
                let frameDuration = CMTime(seconds: 1 / selectedRate,
                                           preferredTimescale: 60_000)
                camera.activeVideoMinFrameDuration = frameDuration
                camera.activeVideoMaxFrameDuration = frameDuration
            }
            camera.unlockForConfiguration()

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.setSampleBufferDelegate(sampleDelegate, queue: sampleQueue)

            guard session.canAddOutput(output) else {
                throw CameraError.outputUnavailable
            }
            session.addOutput(output)
            addedOutput = output
            if let connection = output.connection(with: .video) {
                connection.automaticallyAdjustsVideoMirroring = false
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = false
                }
                if connection.isVideoRotationAngleSupported(0) {
                    connection.videoRotationAngle = 0
                }
            }
        } catch {
            if let addedOutput { session.removeOutput(addedOutput) }
            if let addedInput { session.removeInput(addedInput) }
            throw error
        }
    }
}

private enum CameraError: LocalizedError {
    case cameraUnavailable
    case inputUnavailable
    case outputUnavailable

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            "Aucune caméra compatible n’est disponible."
        case .inputUnavailable:
            "La caméra ne peut pas être ajoutée à la session."
        case .outputUnavailable:
            "Le flux vidéo ne peut pas être lu."
        }
    }
}

nonisolated private final class PoseSampleBufferDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let detector = PoseDetector()
    // RTMPose is the sole product engine for this activation. There is no
    // runtime fallback: a load/inference failure is published as technicalError.
    private var upperBodySession = UpperBodyEngineSession(engine: RTMPoseUpperBodyAdapter())
    private let humanRectangleDetector = HumanRectangleDetector()
    private let segmentationDetector = PersonSegmentationDetector()
    private let segmentationCancellation: BenchmarkSegmentationCancellationBox
    private let onFrameLiveness: @Sendable (UInt64) -> Void
    private let onEvent: @Sendable (PoseProcessingEvent, PoseProcessingGeneration) -> Void
    private let sampleQueue: DispatchQueue
    private var analysisCadence = AnalysisCadenceController()
    private var isActive = false
    private var generation = PoseProcessingGeneration(operationID: 0, activationID: 0)
    private var livenessEpoch: UInt64 = 0
    private var cameraIdentifier = "default"
    private var stabilizer = PoseResultStabilizer()
    private var expirationWorkItem: DispatchWorkItem?
    private var overlayExpirationWorkItem: DispatchWorkItem?
    private var overlayFreshness = PoseOverlayFreshnessTracker()
    private var frameCallbacks = 0
    private var analyses = 0
    private var lastInferenceDiagnostics: PoseInferenceDiagnostics?
    private var lastVisionError: String?
    private var bodyCadence = BodyCadenceController()
    private var callbackBudget = VisionCallbackBudget()
    private var bodyStatusAvailableUntil: TimeInterval?
    private var bodyOverlayAvailableUntil: TimeInterval?
    private var bodyExpirationWorkItem: DispatchWorkItem?
    private var bodyFreshness = BodyOverlayFreshnessTracker()
    private var silhouetteCadence = SilhouetteCadenceController()
    private var silhouetteFreshness = SilhouetteOverlayFreshnessTracker()
    private var silhouetteExpirationWorkItem: DispatchWorkItem?
    private var latestFaceDetection = FaceDetectionOutput.empty
    private var latestUpperBodyFaceROI: UpperBodyRegionOfInterest?
    private var faceAnchorSampleID: UInt64 = 0
    private var faceObservationSampleID: UInt64 = 0
    private var latestBodyDetection: BodyDetectionOutput?
    private var faceInvisibleSince: TimeInterval?
    private var latestSilhouetteOverlay = PoseOverlay.empty
    private var latestUpperBodyOverlay = PoseOverlay.empty
    private var upperBodyCadence = UpperBodyCadenceController()
    private var upperBodyExpirationWorkItem: DispatchWorkItem?
    private var postureObservationExpirationWorkItem: DispatchWorkItem?
    private var upperBodySampleID: UInt64 = 0
    private var upperBodyDevelopmentVisualizationEnabled = false
    private var upperBodyDevelopmentOptions = UpperBodyDevelopmentOptions()
    private var upperBodyAttempts = 0
    private var upperBodyResults = 0
    private var upperBodyLastStatus = "—"
    private var upperBodyLastRejectionReason: String?
    private var upperBodyValidLandmarks = 0
    private var upperBodyLeftShoulderScore: Float?
    private var upperBodyRightShoulderScore: Float?
    private var upperBodySimCCMinimum: Float?
    private var upperBodySimCCMaximum: Float?
    private var upperBodyScoreMinimum: Float?
    private var upperBodyScoreMaximum: Float?
    private var upperBodyLatency: TimeInterval?
    private var upperBodyResultCapturedAt: TimeInterval?
    private var segmentationAttempts = 0
    private var segmentationVisionPerforms = 0
    private var segmentationResults = 0
    private var segmentationContoursValid = 0
    private var segmentationInsufficient = 0
    private var segmentationErrors = 0
    private var segmentationDurations: [TimeInterval] = []
    private var segmentationDurationP50: TimeInterval?
    private var segmentationDurationP95: TimeInterval?
    private var segmentationDurationMax: TimeInterval?
    private var segmentationState: PersonSegmentationAvailability = .notRequested
    private var lastUpperBodyLandmarks = UpperBodyLandmarkDiagnostics.empty
    private var benchmarkSegmentationToken: UInt64?
    private var upperBodyROICadence = UpperBodyROISpikeCadence()
    private var upperBodyROISpike = UpperBodyROISpikeDiagnostics.empty
    private var postureRuntimeCoordinator = PostureRuntimeCoordinator()
    private var postureRuntimeContextKey = ""
    private var captureClockOffset: TimeInterval?
    private var lastCaptureTimestamp: TimeInterval?
    private var latestFaceCapturedAt: TimeInterval?
    private var latestPostureGeometry: PostureRichGeometryMetrics?
    private var postureCalibrationWorkItem: DispatchWorkItem?
    private var postureCalibrationStartedAt: TimeInterval?
    private var persistedRichBaseline: PostureRichBaseline?

    init(
        sampleQueue: DispatchQueue,
        segmentationCancellation: BenchmarkSegmentationCancellationBox,
        onFrameLiveness: @escaping @Sendable (UInt64) -> Void,
        onEvent: @escaping @Sendable (PoseProcessingEvent, PoseProcessingGeneration) -> Void
    ) {
        self.sampleQueue = sampleQueue
        self.segmentationCancellation = segmentationCancellation
        self.onFrameLiveness = onFrameLiveness
        self.onEvent = onEvent
        if let data = UserDefaults.standard.data(forKey: "posture.richBaseline.v1") {
            persistedRichBaseline = try? JSONDecoder().decode(PostureRichBaseline.self, from: data)
        }
    }

    func setCameraIdentifier(_ identifier: String) {
        guard !identifier.isEmpty else { return }
        cameraIdentifier = identifier
    }

    func setLivenessEpoch(_ epoch: UInt64) {
        livenessEpoch = epoch
    }

    func setActive(_ isActive: Bool, generation: PoseProcessingGeneration) {
        self.isActive = isActive
        self.generation = generation
        postureRuntimeContextKey = ""
        postureRuntimeCoordinator.reset(generation: UInt64(generation.activationID), contextKey: "")
        benchmarkSegmentationToken = nil
        analysisCadence.reset()
        expirationWorkItem?.cancel()
        expirationWorkItem = nil
        overlayExpirationWorkItem?.cancel()
        overlayExpirationWorkItem = nil
        overlayFreshness.reset(generation: generation.activationID)
        stabilizer.reset()
        frameCallbacks = 0
        analyses = 0
        lastInferenceDiagnostics = nil
        lastVisionError = nil
        bodyCadence.reset()
        bodyStatusAvailableUntil = nil
        bodyOverlayAvailableUntil = nil
        bodyExpirationWorkItem?.cancel()
        bodyExpirationWorkItem = nil
        bodyFreshness.reset(generation: generation.activationID)
        upperBodyROICadence.reset()
        upperBodyROISpike = .empty
        silhouetteCadence.reset()
        silhouetteFreshness.reset(generation: generation.activationID)
        silhouetteExpirationWorkItem?.cancel()
        silhouetteExpirationWorkItem = nil
        if isActive,
           analysisCadence.presentation.runsSilhouetteExperiment,
           benchmarkSegmentationToken != nil {
            segmentationDetector.activate()
        } else {
            segmentationDetector.deactivate()
        }
        latestFaceDetection = .empty
        latestUpperBodyFaceROI = nil
        faceAnchorSampleID = 0
        faceObservationSampleID = 0
        latestBodyDetection = nil
        faceInvisibleSince = nil
        latestSilhouetteOverlay = .empty
        latestUpperBodyOverlay = .empty
        upperBodyCadence.reset()
        upperBodyExpirationWorkItem?.cancel()
        upperBodyExpirationWorkItem = nil
        postureObservationExpirationWorkItem?.cancel()
        postureObservationExpirationWorkItem = nil
        upperBodySampleID = 0
        upperBodyAttempts = 0
        upperBodyResults = 0
        upperBodyLastStatus = "—"
        upperBodyLastRejectionReason = nil
        upperBodyValidLandmarks = 0
        upperBodyLeftShoulderScore = nil
        upperBodyRightShoulderScore = nil
        upperBodySimCCMinimum = nil
        upperBodySimCCMaximum = nil
        upperBodyScoreMinimum = nil
        upperBodyScoreMaximum = nil
        upperBodyLatency = nil
        upperBodyResultCapturedAt = nil
        if isActive {
            upperBodySession.activate(generation: UInt64(generation.activationID))
        } else {
            upperBodySession.deactivate()
        }
        postureRuntimeContextKey = ""
        captureClockOffset = nil
        lastCaptureTimestamp = nil
        latestFaceCapturedAt = nil
        latestPostureGeometry = nil
        postureCalibrationWorkItem?.cancel()
        postureCalibrationWorkItem = nil
        postureCalibrationStartedAt = nil
        segmentationAttempts = 0
        segmentationVisionPerforms = 0
        segmentationResults = 0
        segmentationContoursValid = 0
        segmentationInsufficient = 0
        segmentationErrors = 0
        segmentationDurations.removeAll(keepingCapacity: true)
        segmentationDurationP50 = nil
        segmentationDurationP95 = nil
        segmentationDurationMax = nil
        segmentationState = .notRequested
        lastUpperBodyLandmarks = .empty
    }

    func setUpperBodyDevelopmentVisualizationEnabled(_ isEnabled: Bool) {
        upperBodyDevelopmentVisualizationEnabled = isEnabled
        guard isActive else { return }
        publishCurrentUpperBodyPresentation(at: ProcessInfo.processInfo.systemUptime)
    }

    func setPostureRecommendationSensitivity(_ sensitivity: PostureRecommendationSensitivity) {
        postureRuntimeCoordinator.setSensitivity(sensitivity)
        guard isActive else { return }
        let reset = postureRuntimeCoordinator.invalidate(
            at: ProcessInfo.processInfo.systemUptime
        )
        onEvent(.postureObservations(reset), generation)
        onEvent(.postureIndicators(indicators(from: reset)), generation)
    }

    func setUpperBodyDevelopmentOptions(_ options: UpperBodyDevelopmentOptions) {
        upperBodyDevelopmentOptions = options
        setUpperBodyDevelopmentVisualizationEnabled(
            upperBodyDevelopmentVisualizationEnabled
        )
    }

    func beginPostureCalibration(generation requestedGeneration: PoseProcessingGeneration) {
        guard isActive, generation == requestedGeneration else { return }
        let now = ProcessInfo.processInfo.systemUptime
        postureRuntimeCoordinator.beginCalibration()
        let reset = postureRuntimeCoordinator.invalidate(at: now)
        onEvent(.postureObservations(reset), generation)
        onEvent(.postureIndicators(indicators(from: reset)), generation)
        let startedAt = now
        postureCalibrationStartedAt = startedAt
        onEvent(.calibration(.init(
            phase: .collecting,
            progress: 0,
            outcomes: Dictionary(uniqueKeysWithValues: PostureObservationSignalID.allCases.map { ($0, .pending) })
        )), generation)
        schedulePostureCalibrationFinish(after: 0.5,
                                         generation: generation)
    }

    private func schedulePostureCalibrationFinish(
        after delay: TimeInterval,
        generation scheduledGeneration: PoseProcessingGeneration
    ) {
        postureCalibrationWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, self.generation == scheduledGeneration else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.postureRuntimeCoordinator.isCalibrationActive {
                let elapsed = now - (self.postureCalibrationStartedAt ?? now)
                if elapsed < PostureIndicatorContract.calibrationDuration {
                    self.onEvent(.calibration(.init(
                        phase: .collecting,
                        progress: min(0.99, max(0, elapsed / PostureIndicatorContract.calibrationDuration)),
                        outcomes: Dictionary(uniqueKeysWithValues: PostureObservationSignalID.allCases.map { ($0, .pending) })
                    )), scheduledGeneration)
                    self.schedulePostureCalibrationFinish(after: 0.5, generation: scheduledGeneration)
                    return
                }
                let ready = self.postureRuntimeCoordinator.finishCalibration()
                if ready, let baseline = self.postureRuntimeCoordinator.baselineSnapshot,
                   let data = try? JSONEncoder().encode(baseline) {
                    UserDefaults.standard.set(data, forKey: "posture.richBaseline.v1")
                    self.persistedRichBaseline = baseline
                }
                let outcomes = Dictionary(uniqueKeysWithValues: PostureObservationSignalID.allCases.map { id in
                    guard ready, let baseline = self.postureRuntimeCoordinator.baselineSnapshot else {
                        return (id, PostureCalibrationSignalOutcome.unavailable("Repère insuffisant"))
                    }
                    switch id {
                    case .proximity:
                        return (id, baseline.proximityScale != nil
                            ? .ready : .unavailable("Visage insuffisant"))
                    case .torsoInclination:
                        return (id, baseline.torsoInclinationDegrees != nil
                            ? .ready : .unavailable("Hanches insuffisantes"))
                    case .raisedShoulders:
                        return (id, baseline.leftShoulderElevation != nil && baseline.rightShoulderElevation != nil
                            ? .ready : .unavailable("Épaules insuffisantes"))
                    case .shoulderSlope:
                        return (id, baseline.shoulderSlopeDegrees != nil
                            ? .ready : .unavailable("Épaules insuffisantes"))
                    case .estimatedBlinks:
                        return (id, .unavailable("Repère de clignements séparé"))
                    case .closedShoulders:
                        return (id, baseline.shoulderOpeningRatio != nil
                            ? .ready : .unavailable("Ouverture des épaules insuffisante"))
                    }
                })
                self.onEvent(.calibration(.init(
                    phase: ready ? .completed : .failed("Repères insuffisants"),
                    progress: 1,
                    outcomes: outcomes
                )), scheduledGeneration)
                self.postureCalibrationStartedAt = nil
            }
        }
        postureCalibrationWorkItem = work
        sampleQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func updatePresentation(
        _ presentation: AnalysisPresentationState,
        benchmarkToken: UInt64?
    ) {
        analysisCadence.updatePresentation(presentation)
        benchmarkSegmentationToken = benchmarkToken
        if !presentation.runsUpperBodyROIExperiment {
            upperBodyROICadence.reset()
            upperBodyROISpike = .empty
        }
        if !presentation.runsSilhouetteExperiment || benchmarkToken == nil {
            silhouetteExpirationWorkItem?.cancel()
            silhouetteExpirationWorkItem = nil
            silhouetteCadence.reset()
            segmentationDetector.deactivate()
            latestSilhouetteOverlay = .empty
            segmentationState = .notRequested
            if presentation.publishesVisualUpdates, upperBodyAttempts > 0 {
                publishCurrentUpperBodyPresentation(
                    at: ProcessInfo.processInfo.systemUptime
                )
            } else {
                onEvent(.overlay(combinedOverlay()), generation)
            }
        } else if !segmentationDetector.isActive {
            segmentationDetector.activate()
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onFrameLiveness(livenessEpoch)
        guard isActive else { return }
        frameCallbacks += 1

        let uptime = ProcessInfo.processInfo.systemUptime
        let capturedAt = monotonicCaptureTime(for: sampleBuffer, fallback: uptime)
        callbackBudget.beginCallback()
        guard let unit = nextVisionUnit(at: uptime), callbackBudget.claim(unit) else { return }
        analyses += 1
        var faceDuration: TimeInterval?
        var faceAttempted = false
        var faceSucceeded = false
        var faceHadLandmarks = false
        var faceOrientation: FaceOrientationSignal?
        var bodyDuration: TimeInterval?
        var bodyAttempted = false
        var bodySucceeded = false
        var bodyObservationAvailable = false
        var bodyInferenceError = false
        var upperBodyLandmarks: UpperBodyLandmarkDiagnostics?
        var segmentationAttempted = false
        var segmentationVisionPerformed = false
        var segmentationResult = false
        var segmentationContourValid = false
        var segmentationWasInsufficient = false
        var segmentationError = false
        var segmentationDuration: TimeInterval?
        var roiSpikeMeasurement: UpperBodyROISpikeMeasurement?

        switch unit {
        case .upperBody:
            upperBodyCadence.recordAttempt(at: uptime)
            upperBodyAttempts += 1
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                upperBodyLastStatus = UpperBodyEngineState.technicalError.rawValue
                upperBodyValidLandmarks = 0
                upperBodyLeftShoulderScore = nil
                upperBodyRightShoulderScore = nil
                upperBodySimCCMinimum = nil
                upperBodySimCCMaximum = nil
                upperBodyScoreMinimum = nil
                upperBodyScoreMaximum = nil
                upperBodyLatency = nil
                upperBodyResultCapturedAt = nil
                clearUpperBody(state: .technicalError)
                break
            }
            upperBodySampleID &+= 1
            let frameROI = latestUpperBodyFaceROI.map { anchor in
                UpperBodyRegionOfInterest(
                    rect: anchor.rect,
                    capturedAt: capturedAt,
                    anchorCapturedAt: anchor.anchorCapturedAt,
                    anchorSampleID: anchor.anchorSampleID,
                    generation: anchor.generation,
                    source: capturedAt == anchor.anchorCapturedAt
                        ? .sameFrameFace : .recentFace
                )
            }
            let frame = UpperBodyFrame(
                pixelBuffer: pixelBuffer,
                capturedAt: capturedAt,
                sampleID: upperBodySampleID,
                generation: UInt64(generation.activationID),
                regionOfInterest: frameROI
            )
            guard let result = upperBodySession.analyze(frame) else {
                upperBodyLastRejectionReason = upperBodySession.lastRejectionReason?.rawValue
                upperBodyLastStatus = upperBodyLastRejectionReason.map { "rejected:\($0)" } ?? "rejected"
                upperBodyValidLandmarks = 0
                upperBodyLeftShoulderScore = nil
                upperBodyRightShoulderScore = nil
                upperBodySimCCMinimum = nil
                upperBodySimCCMaximum = nil
                upperBodyScoreMinimum = nil
                upperBodyScoreMaximum = nil
                upperBodyLatency = nil
                upperBodyResultCapturedAt = nil
                if upperBodySession.lastRejectionReason == .postInferenceExpired ||
                    upperBodySession.lastRejectionReason == .invalidProducedAt {
                    // A slow/invalid engine return invalidates the previous
                    // geometry immediately; do not leave a detected banner
                    // or overlay alive until a delayed expiry callback.
                    clearUpperBody(state: .lost)
                }
                break
            }
            upperBodyLastRejectionReason = nil
            let resultNow = result.producedAt
            if let context = PostureFramingContext(
                pixelWidth: CVPixelBufferGetWidth(pixelBuffer),
                pixelHeight: CVPixelBufferGetHeight(pixelBuffer),
                cameraID: cameraIdentifier,
                normalizedROI: frameROI?.rect ?? .init(x: 0, y: 0, width: 1, height: 1),
                revision: "rtmpose-v1"
            ) {
                let faceObservation: PostureFaceObservation? = {
                    guard let signal = FaceGeometrySignal.from(polylines: latestFaceDetection.polylines),
                          faceObservationSampleID > 0 else { return nil }
                    return .init(
                        generation: UInt64(generation.activationID),
                        sampleID: faceObservationSampleID,
                        capturedAt: latestFaceCapturedAt ?? capturedAt,
                        facePointCount: latestFaceDetection.polylines.reduce(0) { $0 + $1.locations.count },
                        contextKey: context.key,
                        signal: signal
                    )
                }()
                let geometry = PostureRichGeometryEvaluator.make(
                    result: result, face: faceObservation, context: context
                )
                latestPostureGeometry = geometry
                preparePostureRuntime(for: context)
                if let runtime = postureRuntimeCoordinator.consumeBody(
                    geometry, baseline: nil, now: resultNow
                ) {
                    onEvent(.postureRichEvaluation(runtime.evaluation), generation)
                    onEvent(.postureObservations(runtime.snapshot), generation)
                    onEvent(.postureIndicators(indicators(from: runtime.snapshot)), generation)
                }
            }
            upperBodyResults += 1
            upperBodyLastStatus = result.state.rawValue
            upperBodyValidLandmarks = result.diagnostics?.validLandmarkCount
                ?? result.points.count
            upperBodyLeftShoulderScore = result.diagnostics?.leftShoulderScore
                ?? result.point(.leftShoulder)?.confidence
            upperBodyRightShoulderScore = result.diagnostics?.rightShoulderScore
                ?? result.point(.rightShoulder)?.confidence
            upperBodySimCCMinimum = result.diagnostics?.simCCMinimum
            upperBodySimCCMaximum = result.diagnostics?.simCCMaximum
            upperBodyScoreMinimum = result.diagnostics?.scoreMinimum
            upperBodyScoreMaximum = result.diagnostics?.scoreMaximum
            upperBodyLatency = result.producedAt - result.capturedAt
            upperBodyResultCapturedAt = result.capturedAt
            switch result.state {
            case .detected, .partial:
                latestUpperBodyOverlay = upperBodyDevelopmentVisualizationEnabled
                    ? DevelopmentUpperBodyOverlayBuilder.make(
                        from: result,
                        at: resultNow,
                        options: upperBodyDevelopmentOptions
                    )
                    : ProductUpperBodyOverlayBuilder.make(from: result, at: resultNow)
                scheduleUpperBodyExpiration(for: result, at: resultNow)
                let shoulderState = shoulderState(for: result, at: resultNow)
                onEvent(.upperBodyPresentation(
                    combinedOverlay(), shoulderState
                ), generation)
                onEvent(.upperBodyDevelopmentSummary(
                    DevelopmentUpperBodyOverlayBuilder.summary(for: result, at: resultNow)
                ), generation)
            case .technicalError:
                clearUpperBody(state: .technicalError)
            case .noPerson, .expired:
                clearUpperBody(state: .lost)
            case .stale:
                clearUpperBody(state: .lost)
            }
        case .face:
            analysisCadence.recordAnalysis(at: uptime)
            faceAttempted = true
            faceObservationSampleID &+= 1
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                latestFaceDetection = .empty
                faceDuration = 0
                lastVisionError = "Visage : buffer vidéo absent"
                let invalidated = postureRuntimeCoordinator.invalidateFace(
                    sampleID: faceObservationSampleID,
                    capturedAt: capturedAt,
                    now: uptime
                )
                onEvent(.postureObservations(invalidated), generation)
                onEvent(.postureIndicators(indicators(from: invalidated)), generation)
                clearFaceOverlay()
                break
            }
            let start = ProcessInfo.processInfo.systemUptime
            do {
                let face = try detector.detectFace(in: pixelBuffer)
                faceDuration = ProcessInfo.processInfo.systemUptime - start
                let faceProducedAt = ProcessInfo.processInfo.systemUptime
                latestFaceDetection = face
                if let contour = face.polylines.first(where: { $0.name == "faceContour" }) {
                    faceAnchorSampleID &+= 1
                    latestUpperBodyFaceROI = RTMPoseUpperBodyCropPolicy.faceAnchored(
                        faceContour: contour.locations,
                        imageSize: CGSize(
                            width: CVPixelBufferGetWidth(pixelBuffer),
                            height: CVPixelBufferGetHeight(pixelBuffer)
                        ),
                        capturedAt: capturedAt,
                        sampleID: faceAnchorSampleID,
                        generation: UInt64(generation.activationID)
                    )
                } else {
                    latestUpperBodyFaceROI = nil
                }
                faceSucceeded = face.resultCount > 0
                faceHadLandmarks = face.facesWithLandmarksCount > 0
                faceOrientation = face.primaryOrientation
                lastVisionError = nil
                latestFaceCapturedAt = capturedAt
                let expiredRuntime = postureRuntimeCoordinator.expire(now: faceProducedAt)
                if expiredRuntime.generation == UInt64(generation.activationID),
                   expiredRuntime.signals.contains(where: { $0.availability == .insufficient }) {
                    onEvent(.postureObservations(expiredRuntime), generation)
                    onEvent(.postureIndicators(indicators(from: expiredRuntime)), generation)
                }
                if let faceContext = PostureFramingContext(
                    pixelWidth: CVPixelBufferGetWidth(pixelBuffer),
                    pixelHeight: CVPixelBufferGetHeight(pixelBuffer),
                    cameraID: cameraIdentifier,
                    normalizedROI: latestUpperBodyFaceROI?.rect ?? .init(x: 0, y: 0, width: 1, height: 1),
                    revision: "rtmpose-v1"
                   ),
                   faceObservationSampleID > 0 {
                    preparePostureRuntime(for: faceContext)
                    if let signal = FaceGeometrySignal.from(polylines: face.polylines) {
                        let observation = PostureFaceObservation(
                            generation: UInt64(generation.activationID),
                            sampleID: faceObservationSampleID,
                            capturedAt: capturedAt,
                            facePointCount: face.polylines.reduce(0) { $0 + $1.locations.count },
                            contextKey: faceContext.key,
                            signal: signal
                        )
                        if let runtime = postureRuntimeCoordinator.consumeFace(
                            observation, baseline: nil, now: faceProducedAt
                        ) {
                            onEvent(.postureRichEvaluation(runtime.evaluation), generation)
                            onEvent(.postureObservations(runtime.snapshot), generation)
                            onEvent(.postureIndicators(indicators(from: runtime.snapshot)), generation)
                        }
                    } else {
                        let invalidated = postureRuntimeCoordinator.invalidateFace(
                            sampleID: faceObservationSampleID,
                            capturedAt: capturedAt,
                            now: faceProducedAt
                        )
                        onEvent(.postureObservations(invalidated), generation)
                        onEvent(.postureIndicators(indicators(from: invalidated)), generation)
                    }
                }
                handleFaceVisibility(face.polylines.isEmpty ? nil : capturedAt)
                if face.polylines.isEmpty { clearFaceOverlay() }
            } catch {
                faceDuration = ProcessInfo.processInfo.systemUptime - start
                latestFaceDetection = .empty
                latestUpperBodyFaceROI = nil
                if let faceContext = PostureFramingContext(
                    pixelWidth: CVPixelBufferGetWidth(pixelBuffer),
                    pixelHeight: CVPixelBufferGetHeight(pixelBuffer),
                    cameraID: cameraIdentifier,
                    revision: "rtmpose-v1"
                ) {
                    preparePostureRuntime(for: faceContext)
                    let invalidated = postureRuntimeCoordinator.invalidateFace(
                        sampleID: faceObservationSampleID,
                        capturedAt: capturedAt,
                        now: ProcessInfo.processInfo.systemUptime
                    )
                    onEvent(.postureObservations(invalidated), generation)
                    onEvent(.postureIndicators(indicators(from: invalidated)), generation)
                }
                handleFaceVisibility(nil, at: uptime)
                lastVisionError = "Visage : \(error.localizedDescription)"
                clearFaceOverlay()
            }

        case .body:
            bodyCadence.recordAttempt(at: uptime, bodyAvailable: false)
            bodyAttempted = true
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                bodyInferenceError = true
                bodyExpirationWorkItem?.cancel()
                bodyExpirationWorkItem = nil
                latestBodyDetection = nil
                bodyStatusAvailableUntil = nil
                bodyOverlayAvailableUntil = nil
                bodyFreshness.recordMiss()
                lastUpperBodyLandmarks = .empty
                bodyDuration = 0
                lastVisionError = "Corps : buffer vidéo absent"
                break
            }
            let start = ProcessInfo.processInfo.systemUptime
            do {
                let body = try detector.detectBody(in: pixelBuffer)
                bodyDuration = ProcessInfo.processInfo.systemUptime - start
                latestBodyDetection = body
                bodySucceeded = body.hasUpperBody
                bodyObservationAvailable = body.resultCount > 0
                upperBodyLandmarks = bodyObservationAvailable ? body.upperBodyLandmarks : nil
                lastUpperBodyLandmarks = body.upperBodyLandmarks
                bodyStatusAvailableUntil = body.hasUpperBody ? uptime + 1.2 : nil
                bodyOverlayAvailableUntil = bodyObservationAvailable ? uptime + BodyOverlayFreshnessTracker.maxAge : nil
                if bodyObservationAvailable {
                    bodyFreshness.recordObservation(at: uptime, generation: generation.activationID)
                } else {
                    bodyFreshness.recordMiss()
                }
                scheduleBodyExpirationIfNeeded(at: uptime)
                bodyCadence.recordAttempt(at: uptime, bodyAvailable: body.hasUpperBody)
                lastVisionError = nil
            } catch {
                bodyDuration = ProcessInfo.processInfo.systemUptime - start
                bodyInferenceError = true
                bodyExpirationWorkItem?.cancel()
                bodyExpirationWorkItem = nil
                latestBodyDetection = nil
                bodyStatusAvailableUntil = nil
                bodyOverlayAvailableUntil = nil
                bodyFreshness.recordMiss()
                lastUpperBodyLandmarks = .empty
                lastVisionError = "Corps : \(error.localizedDescription)"
            }

        case .silhouette:
            guard let token = benchmarkSegmentationToken,
                  analysisCadence.presentation.isBenchmarkRunning,
                  segmentationCancellation.accepts(token) else { return }
            let result = segmentationDetector.detect(
                in: sampleBuffer,
                faceAnchor: faceAnchor(from: latestFaceDetection)
            )
            let preparedOverlay: PoseOverlay? = if case .contour(let contour, _) = result {
                PoseOverlay(
                    points: [],
                    polylines: contour.polylines.map { polyline in
                        PosePolyline(
                            name: "silhouette-\(polyline.side.rawValue)",
                            locations: polyline.locations.map(VisionCoordinateMapper.poseOverlayPoint(fromSegmentationTopLeftPoint:)),
                            source: .silhouette,
                            isClosed: false
                        )
                    }
                )
            } else {
                nil
            }
            guard segmentationCancellation.withAcceptedToken(token, commit: {
                guard benchmarkSegmentationToken == token,
                      analysisCadence.presentation.isBenchmarkRunning else { return }
                silhouetteCadence.recordAttempt(at: uptime)
                segmentationAttempted = true
                segmentationAttempts += 1
                segmentationDuration = result.measurement.performedVision ? result.measurement.duration : nil
                segmentationVisionPerformed = result.measurement.performedVision
                if segmentationVisionPerformed {
                    segmentationVisionPerforms += 1
                    recordSegmentationDuration(result.measurement.duration)
                }
                switch result {
                case .contour:
                    segmentationResults += 1
                    segmentationResult = true
                    segmentationContourValid = true
                    segmentationContoursValid += 1
                    segmentationState = .available
                    latestSilhouetteOverlay = preparedOverlay ?? .empty
                    publishFreshSilhouette(at: uptime, benchmarkToken: token)
                case .insufficient(let failure, _):
                    if result.measurement.performedVision { segmentationResults += 1 }
                    segmentationResult = result.measurement.performedVision
                    segmentationWasInsufficient = true
                    segmentationInsufficient += 1
                    segmentationState = .insufficient
                    clearSilhouetteOverlay(benchmarkToken: token)
                    lastVisionError = failure == .missingFaceAnchor ? nil : "Silhouette : \(failure)"
                case .error(let failure, _):
                    segmentationError = true
                    segmentationErrors += 1
                    segmentationState = .error
                    clearSilhouetteOverlay(benchmarkToken: token)
                    lastVisionError = "Silhouette : \(failure)"
                }

                let fused = detector.combine(
                    face: latestFaceDetection,
                    body: latestBodyDetection,
                    bodyStatusAvailable: bodyStatusAvailableUntil.map { uptime < $0 } == true
                )
                lastInferenceDiagnostics = fused.diagnostics
                let fusedOverlay = combinedOverlay()
                if analysisCadence.presentation.publishesVisualUpdates {
                    onEvent(.silhouetteOverlay(fusedOverlay, token), generation)
                }
                publishDiagnosticsIfNeeded()
                publishStabilized(
                    result: fused.observation.map { .detected($0.status) } ?? .noPose,
                    at: uptime
                )
                onEvent(.benchmarkMeasurement(BenchmarkMeasurement(
                    faceAttempted: false,
                    faceDuration: 0,
                    faceSucceeded: false,
                    faceHadLandmarks: false,
                    faceOrientation: nil,
                    faceGeometry: fused.diagnostics.faceGeometry,
                    bodyDuration: nil,
                    bodyAttempted: false,
                    bodySucceeded: false,
                    bodyObservationAvailable: false,
                    bodyInferenceError: false,
                    overlayVisible: !fusedOverlay.isEmpty,
                    faceVisible: !latestFaceDetection.polylines.isEmpty,
                    bodyVisible: !latestBodyDetectionPoints(at: uptime).isEmpty,
                    silhouetteVisible: !latestSilhouetteOverlay.isEmpty,
                    segmentationAttempted: segmentationAttempted,
                    segmentationVisionPerformed: segmentationVisionPerformed,
                    segmentationResult: segmentationResult,
                    segmentationContourValid: segmentationContourValid,
                    segmentationInsufficient: segmentationWasInsufficient,
                    segmentationError: segmentationError,
                    segmentationDuration: segmentationDuration
                ), uptime), generation)
            }) else { return }
            return

        case .upperBodyROISpike:
            guard let token = benchmarkSegmentationToken,
                  segmentationCancellation.accepts(token),
                  analysisCadence.presentation.runsUpperBodyROIExperiment,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let stage = upperBodyROICadence.claimStage(at: uptime)
            enum PreparedSpikeResult {
                case rectangle(Result<HumanRectangleDetection, Error>)
                case fullFrame(Result<(BodyDetectionOutput, TimeInterval), Error>)
                case region(Result<(BodyDetectionOutput, TimeInterval), Error>)
            }
            let prepared: PreparedSpikeResult
            switch stage {
            case .humanRectangle:
                do {
                    prepared = .rectangle(.success(try humanRectangleDetector.detect(in: pixelBuffer)))
                } catch {
                    prepared = .rectangle(.failure(error))
                }
            case .fullFrameBody:
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    prepared = .fullFrame(.success((try detector.detectBody(in: pixelBuffer), ProcessInfo.processInfo.systemUptime - start)))
                } catch {
                    prepared = .fullFrame(.failure(error))
                }
            case .regionBody(let region):
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    prepared = .region(.success((try detector.detectBody(in: pixelBuffer, regionOfInterest: region), ProcessInfo.processInfo.systemUptime - start)))
                } catch {
                    prepared = .region(.failure(error))
                }
            }
            guard segmentationCancellation.withAcceptedToken(token, commit: {
                guard benchmarkSegmentationToken == token,
                      analysisCadence.presentation.runsUpperBodyROIExperiment else { return }
                switch prepared {
                case .rectangle(.success(let detection)):
                    upperBodyROISpike.clearBodyComparison()
                    upperBodyROISpike.rectangleAttempts += 1
                    upperBodyROISpike.rectangleDuration = detection.duration
                    upperBodyROISpike.rectangleConfidence = detection.confidence
                    if detection.resultCount > 0 { upperBodyROISpike.rectangleResults += 1 }
                    if detection.isAccepted { upperBodyROISpike.rectangleAccepted += 1 }
                    upperBodyROICadence.continueAfterRectangle(detection.regionOfInterest)
                    roiSpikeMeasurement = .rectangle(resultCount: detection.resultCount, accepted: detection.isAccepted, confidence: detection.confidence, duration: detection.duration, error: false)
                    lastVisionError = nil
                case .rectangle(.failure(let error)):
                    upperBodyROISpike.clearBodyComparison()
                    upperBodyROISpike.rectangleAttempts += 1
                    upperBodyROISpike.rectangleErrors += 1
                    upperBodyROISpike.rectangleConfidence = nil
                    upperBodyROISpike.rectangleDuration = nil
                    upperBodyROICadence.continueAfterRectangle(nil)
                    roiSpikeMeasurement = .rectangle(resultCount: 0, accepted: false, confidence: nil, duration: 0, error: true)
                    lastVisionError = "Rectangle humain : \(error.localizedDescription)"
                case .fullFrame(.success(let (body, duration))):
                    upperBodyROISpike.fullFrameAttempts += 1
                    upperBodyROISpike.fullFrameDuration = duration
                    upperBodyROISpike.fullFrameCoverage = body.upperBodyLandmarks.recognizedCount
                    upperBodyROICadence.continueAfterFullFrame()
                    roiSpikeMeasurement = .fullFrame(coverage: body.upperBodyLandmarks.recognizedCount, duration: duration, error: false)
                    lastVisionError = nil
                case .fullFrame(.failure(let error)):
                    upperBodyROISpike.clearRegionComparison()
                    upperBodyROISpike.fullFrameAttempts += 1
                    upperBodyROISpike.fullFrameCoverage = nil
                    upperBodyROISpike.fullFrameDuration = nil
                    upperBodyROICadence.continueAfterFullFrame()
                    roiSpikeMeasurement = .fullFrame(coverage: nil, duration: 0, error: true)
                    lastVisionError = "Corps plein benchmark : \(error.localizedDescription)"
                case .region(.success(let (body, duration))):
                    upperBodyROISpike.regionAttempts += 1
                    upperBodyROISpike.regionDuration = duration
                    upperBodyROISpike.regionCoverage = body.upperBodyLandmarks.recognizedCount
                    roiSpikeMeasurement = .region(coverage: body.upperBodyLandmarks.recognizedCount, duration: duration, error: false)
                    lastVisionError = nil
                case .region(.failure(let error)):
                    upperBodyROISpike.regionAttempts += 1
                    upperBodyROISpike.regionCoverage = nil
                    upperBodyROISpike.regionDuration = nil
                    roiSpikeMeasurement = .region(coverage: nil, duration: 0, error: true)
                    lastVisionError = "Corps ROI benchmark : \(error.localizedDescription)"
                }
            }) else { return }
        }

        if bodyOverlayAvailableUntil.map({ uptime < $0 }) != true {
            latestBodyDetection = nil
            lastUpperBodyLandmarks = .empty
            bodyOverlayAvailableUntil = nil
        }
        if bodyStatusAvailableUntil.map({ uptime < $0 }) != true {
            bodyStatusAvailableUntil = nil
        }
        let fused = detector.combine(
            face: latestFaceDetection,
            body: latestBodyDetection,
            bodyStatusAvailable: bodyStatusAvailableUntil.map { uptime < $0 } == true
        )
        lastInferenceDiagnostics = fused.diagnostics
        let fusedOverlay = combinedOverlay()
        if analysisCadence.presentation.publishesVisualUpdates {
            switch unit {
            case .upperBody:
                break
            case .face:
                if !latestFaceDetection.polylines.isEmpty { publishFreshOverlay(fusedOverlay, at: uptime) }
            case .body:
                onEvent(.overlay(fusedOverlay), generation)
            case .silhouette:
                break
            case .upperBodyROISpike:
                break
            }
        }
        publishDiagnosticsIfNeeded()
        publishStabilized(
            result: fused.observation.map { .detected($0.status) } ?? .noPose,
            at: uptime
        )
        if analysisCadence.presentation.isBenchmarkRunning {
            let overlay = fusedOverlay
            onEvent(.benchmarkMeasurement(BenchmarkMeasurement(
                faceAttempted: faceAttempted,
                faceDuration: faceDuration ?? 0,
                faceSucceeded: faceSucceeded,
                faceHadLandmarks: faceHadLandmarks,
                faceOrientation: faceOrientation,
                faceGeometry: fused.diagnostics.faceGeometry,
                bodyDuration: bodyDuration,
                bodyAttempted: bodyAttempted,
                bodySucceeded: bodySucceeded,
                bodyObservationAvailable: bodyObservationAvailable,
                bodyInferenceError: bodyInferenceError,
                upperBodyLandmarks: upperBodyLandmarks,
                overlayVisible: !overlay.isEmpty,
                faceVisible: !latestFaceDetection.polylines.isEmpty,
                bodyVisible: !latestBodyDetectionPoints(at: uptime).isEmpty,
                silhouetteVisible: !latestSilhouetteOverlay.isEmpty,
                segmentationAttempted: segmentationAttempted,
                segmentationVisionPerformed: segmentationVisionPerformed,
                segmentationResult: segmentationResult,
                segmentationContourValid: segmentationContourValid,
                segmentationInsufficient: segmentationWasInsufficient,
                segmentationError: segmentationError,
                segmentationDuration: segmentationDuration,
                upperBodyROISpike: roiSpikeMeasurement
            ), uptime), generation)
        }
    }

    private func monotonicCaptureTime(
        for sampleBuffer: CMSampleBuffer,
        fallback uptime: TimeInterval
    ) -> TimeInterval {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(pts)
        let candidate: TimeInterval
        if seconds.isFinite, seconds >= 0 {
            if let captureClockOffset {
                let adjusted = seconds + captureClockOffset
                // CMSampleBuffer timestamps are not guaranteed to share the
                // ProcessInfo uptime clock. Rebase when a restart/timebase
                // jump would make the frame appear future or older than the
                // admission TTL; the callback uptime remains monotonic.
                if adjusted.isFinite,
                   adjusted >= uptime - UpperBodyEngineSession.defaultMaximumAge,
                   adjusted <= uptime + 0.05 {
                    candidate = adjusted
                } else {
                    self.captureClockOffset = uptime - seconds
                    candidate = uptime
                }
            } else {
                captureClockOffset = uptime - seconds
                candidate = uptime
            }
        } else {
            candidate = uptime
        }

        // Preserve non-decreasing capture timestamps even when a camera
        // driver emits equal or slightly regressing PTS values. Equal values
        // remain admissible because the sample ID is strictly increasing.
        let monotonic = min(uptime, max(candidate, lastCaptureTimestamp ?? candidate))
        lastCaptureTimestamp = monotonic
        return monotonic
    }

    private func combinedOverlay() -> PoseOverlay {
        let bodyPoints = bodyOverlayAvailableUntil.map { ProcessInfo.processInfo.systemUptime < $0 } == true
            ? (latestBodyDetection?.points ?? [])
            : []
        return PoseOverlay(
            points: bodyPoints + latestUpperBodyOverlay.points,
            polylines: latestFaceDetection.polylines
                + latestSilhouetteOverlay.polylines
                + latestUpperBodyOverlay.polylines
        )
    }

    private func latestBodyDetectionPoints(at uptime: TimeInterval) -> [PosePoint] {
        guard bodyOverlayAvailableUntil.map({ uptime < $0 }) == true else { return [] }
        return latestBodyDetection?.points ?? []
    }

    private func scheduleBodyExpirationIfNeeded(at uptime: TimeInterval) {
        bodyExpirationWorkItem?.cancel()
        bodyExpirationWorkItem = nil
        guard bodyOverlayAvailableUntil != nil else { return }

        let scheduledGeneration = generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isActive,
                  self.generation == scheduledGeneration else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard self.bodyFreshness.shouldExpire(
                at: now,
                generation: scheduledGeneration.activationID
            ) else { return }
            self.latestBodyDetection = nil
            self.lastUpperBodyLandmarks = .empty
            self.bodyOverlayAvailableUntil = nil
            self.bodyStatusAvailableUntil = nil
            self.bodyExpirationWorkItem = nil
            let fused = self.detector.combine(
                face: self.latestFaceDetection,
                body: nil,
                bodyStatusAvailable: false
            )
            self.lastInferenceDiagnostics = fused.diagnostics
            if self.analysisCadence.presentation.publishesVisualUpdates {
                self.onEvent(.overlay(self.combinedOverlay()), scheduledGeneration)
                self.publishDiagnosticsIfNeeded()
            }
            self.publishStabilized(
                result: fused.observation.map { .detected($0.status) } ?? .noPose,
                at: now
            )
        }
        bodyExpirationWorkItem = workItem
        let delay = max(0, (bodyOverlayAvailableUntil ?? uptime) - uptime)
        sampleQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func nextVisionUnit(at uptime: TimeInterval) -> VisionAnalysisUnit? {
        let presentation = analysisCadence.presentation
        let candidates: [VisionAnalysisCandidate] = [
            (presentation.runsNormalUpperBodyEngine && upperBodyCadence.isDue(
                at: uptime,
                interval: presentation.upperBodyInterval
            ))
                ? VisionAnalysisCandidate(
                    unit: .upperBody,
                    overdue: upperBodyCadence.overdue(
                        at: uptime,
                        interval: presentation.upperBodyInterval
                    ),
                    priority: 4
                )
                : nil,
            analysisCadence.isDue(at: uptime)
                ? VisionAnalysisCandidate(unit: .face, overdue: analysisCadence.lastAnalysisUptime == nil ? 1 : analysisCadence.overdue(at: uptime), priority: 3)
                : nil,
            (presentation.runsNormalBodyAnalysis && bodyCadence.isDue(at: uptime))
                ? VisionAnalysisCandidate(unit: .body, overdue: bodyCadence.lastAttemptUptime == nil ? 1 : bodyCadence.overdue(at: uptime), priority: 2)
                : nil,
            (presentation.runsSilhouetteExperiment && silhouetteCadence.isDue(at: uptime, presentation: presentation))
                ? VisionAnalysisCandidate(unit: .silhouette, overdue: silhouetteCadence.lastAttemptUptime == nil ? 1 : silhouetteCadence.overdue(at: uptime), priority: 1)
                : nil,
            upperBodyROICadence.isDue(at: uptime, benchmarkRunning: presentation.runsUpperBodyROIExperiment)
                ? VisionAnalysisCandidate(unit: .upperBodyROISpike, overdue: 0, priority: 1)
                : nil
        ].compactMap { $0 }
        return VisionAnalysisSelector.select(candidates)
    }

    private func scheduleUpperBodyExpiration(
        for result: UpperBodyResult,
        at uptime: TimeInterval
    ) {
        upperBodyExpirationWorkItem?.cancel()
        postureObservationExpirationWorkItem?.cancel()
        guard let delay = upperBodySession.expirationDelay(
            for: result, at: uptime
        ) else { return }
        let scheduledGeneration = generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isActive,
                  self.generation == scheduledGeneration else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let expired = self.upperBodySession.expire(
                at: now,
                generation: UInt64(scheduledGeneration.activationID)
            )
            if let expired {
                self.onEvent(.upperBodyDevelopmentSummary(
                    DevelopmentUpperBodyOverlayBuilder.summary(for: expired, at: now)
                ), scheduledGeneration)
            }
            self.upperBodyLastStatus = UpperBodyEngineState.expired.rawValue
            self.upperBodyValidLandmarks = 0
            self.upperBodyLeftShoulderScore = nil
            self.upperBodyRightShoulderScore = nil
            self.upperBodySimCCMinimum = nil
            self.upperBodySimCCMaximum = nil
            self.upperBodyScoreMinimum = nil
            self.upperBodyScoreMaximum = nil
            // L'overlay a une durée de vie plus courte que l'observation de
            // posture (1,2 s contre 2 s). Sa disparition ne doit donc pas
            // effacer une mesure encore fraîche ni casser son historique.
            self.clearUpperBody(
                state: .lost,
                publishesDevelopmentSummary: false,
                invalidatesPosture: false
            )
            self.publishDiagnosticsIfNeeded()
        }
        upperBodyExpirationWorkItem = workItem
        sampleQueue.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )

        let postureDelay = max(
            0,
            PostureObservationEngine.richConfiguration.ttl - (uptime - result.capturedAt)
        ) + 0.01
        let postureWorkItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isActive,
                  self.generation == scheduledGeneration else { return }
            let expired = self.postureRuntimeCoordinator.expire(
                now: ProcessInfo.processInfo.systemUptime
            )
            self.onEvent(.postureObservations(expired), scheduledGeneration)
            self.onEvent(.postureIndicators(
                self.indicators(from: expired)
            ), scheduledGeneration)
        }
        postureObservationExpirationWorkItem = postureWorkItem
        sampleQueue.asyncAfter(
            deadline: .now() + postureDelay,
            execute: postureWorkItem
        )
    }

    private func clearUpperBody(
        state: ShoulderTrackingState,
        publishesState: Bool = true,
        publishesDevelopmentSummary: Bool = true,
        invalidatesPosture: Bool = true
    ) {
        upperBodyExpirationWorkItem?.cancel()
        upperBodyExpirationWorkItem = nil
        if invalidatesPosture {
            postureObservationExpirationWorkItem?.cancel()
            postureObservationExpirationWorkItem = nil
        }
        latestUpperBodyOverlay = .empty
        latestPostureGeometry = nil
        let now = ProcessInfo.processInfo.systemUptime
        let runtimeInvalidation = invalidatesPosture
            ? postureRuntimeCoordinator.invalidateBody(at: now, reason: "corps indisponible")
            : nil
        let observationSnapshot = runtimeInvalidation?.snapshot ??
            postureRuntimeCoordinator.expire(now: now)
        if let evaluation = runtimeInvalidation?.evaluation {
            onEvent(.postureRichEvaluation(evaluation), generation)
        }
        onEvent(.postureObservations(observationSnapshot), generation)
        onEvent(.postureIndicators(indicators(from: observationSnapshot)), generation)
        if publishesState {
            onEvent(.upperBodyPresentation(combinedOverlay(), state), generation)
        }
        if publishesDevelopmentSummary {
            let summary = state == .technicalError ? "Erreur technique du moteur" : "Torse · perdu"
            onEvent(.upperBodyDevelopmentSummary(summary), generation)
        }
        if !publishesState && analysisCadence.presentation.publishesVisualUpdates {
            onEvent(.overlay(combinedOverlay()), generation)
        }
    }

    private func shoulderState(
        for result: UpperBodyResult,
        at uptime: TimeInterval
    ) -> ShoulderTrackingState {
        guard result.isRenderable(
            at: uptime,
            maximumAge: UpperBodyEngineSession.defaultMaximumAge
        ) else { return .lost }
        let shoulderCount = [
            result.point(.leftShoulder), result.point(.rightShoulder)
        ].compactMap { $0 }.count
        switch shoulderCount {
        case 2 where result.hasCoherentShoulders: return .detected
        case 1...: return .partial
        default: return .lost
        }
    }

    private func publishCurrentUpperBodyPresentation(at uptime: TimeInterval) {
        guard let result = upperBodySession.currentResult,
              result.isRenderable(
                at: uptime,
                maximumAge: UpperBodyEngineSession.defaultMaximumAge
              ) else {
            clearUpperBody(state: .lost)
            return
        }
        latestUpperBodyOverlay = upperBodyDevelopmentVisualizationEnabled
            ? DevelopmentUpperBodyOverlayBuilder.make(
                from: result,
                at: uptime,
                options: upperBodyDevelopmentOptions
            )
            : ProductUpperBodyOverlayBuilder.make(from: result, at: uptime)
        onEvent(.upperBodyPresentation(
            combinedOverlay(), shoulderState(for: result, at: uptime)
        ), generation)
    }

    private func faceAnchor(from face: FaceDetectionOutput) -> PersonSegmentationFaceAnchor? {
        guard let contour = face.polylines.first(where: { $0.name == "faceContour" }),
              contour.locations.count >= 3 else { return nil }
        return PersonSegmentationFaceAnchor(faceOverlayContour: contour.locations)
    }

    private func handleFaceVisibility(_ visibleAt: TimeInterval?, at uptime: TimeInterval? = nil) {
        let now = uptime ?? ProcessInfo.processInfo.systemUptime
        if visibleAt != nil {
            faceInvisibleSince = nil
            return
        }
        faceInvisibleSince = faceInvisibleSince ?? now
        guard now - (faceInvisibleSince ?? now) >= 2.0 else { return }
        segmentationDetector.reset()
        silhouetteCadence.reset()
        clearSilhouetteOverlay()
        segmentationState = .notRequested
        latestUpperBodyFaceROI = nil
        faceInvisibleSince = now
    }

    private func publishFreshOverlay(_ overlay: PoseOverlay, at uptime: TimeInterval) {
        overlayExpirationWorkItem?.cancel()
        let scheduledGeneration = generation
        overlayFreshness.recordObservation(
            at: uptime,
            generation: scheduledGeneration.activationID
        )
        onEvent(.overlay(overlay), scheduledGeneration)
        onEvent(.benchmarkOverlayVisibility(true, uptime), scheduledGeneration)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isActive,
                  self.generation == scheduledGeneration else { return }
            let uptime = ProcessInfo.processInfo.systemUptime
            if self.overlayFreshness.shouldExpire(
                at: uptime,
                generation: scheduledGeneration.activationID
            ) {
                self.latestFaceDetection = .empty
                self.latestUpperBodyFaceROI = nil
                let overlay = self.combinedOverlay()
                self.onEvent(.overlay(overlay), scheduledGeneration)
                self.onEvent(.benchmarkOverlayVisibility(!overlay.isEmpty, uptime), scheduledGeneration)
                self.overlayExpirationWorkItem = nil
            }
        }
        overlayExpirationWorkItem = workItem
        sampleQueue.asyncAfter(
            deadline: .now() + PoseOverlayFreshnessTracker.maxAge,
            execute: workItem
        )
    }

    private func clearOverlay() {
        overlayExpirationWorkItem?.cancel()
        overlayExpirationWorkItem = nil
        overlayFreshness.recordMiss()
        silhouetteFreshness.reset(generation: generation.activationID)
        silhouetteExpirationWorkItem?.cancel()
        silhouetteExpirationWorkItem = nil
        latestFaceDetection = .empty
        latestUpperBodyFaceROI = nil
        latestSilhouetteOverlay = .empty
        onEvent(.overlay(.empty), generation)
        onEvent(.benchmarkOverlayVisibility(
            false,
            ProcessInfo.processInfo.systemUptime
        ), generation)
    }

    private func clearFaceOverlay() {
        overlayExpirationWorkItem?.cancel()
        overlayExpirationWorkItem = nil
        overlayFreshness.recordMiss()
        latestFaceDetection = .empty
        latestUpperBodyFaceROI = nil
        onEvent(.overlay(combinedOverlay()), generation)
        onEvent(.benchmarkOverlayVisibility(!combinedOverlay().isEmpty, ProcessInfo.processInfo.systemUptime), generation)
    }

    private func clearSilhouetteOverlay(benchmarkToken: UInt64? = nil) {
        silhouetteFreshness.reset(generation: generation.activationID)
        silhouetteExpirationWorkItem?.cancel()
        silhouetteExpirationWorkItem = nil
        latestSilhouetteOverlay = .empty
        if analysisCadence.presentation.publishesVisualUpdates {
            let overlay = combinedOverlay()
            if let benchmarkToken {
                onEvent(.silhouetteOverlay(overlay, benchmarkToken), generation)
            } else {
                onEvent(.overlay(overlay), generation)
            }
        }
    }

    private func publishFreshSilhouette(at uptime: TimeInterval, benchmarkToken: UInt64) {
        silhouetteExpirationWorkItem?.cancel()
        silhouetteFreshness.recordObservation(at: uptime, generation: generation.activationID)
        onEvent(.silhouetteOverlay(combinedOverlay(), benchmarkToken), generation)
        let scheduledGeneration = generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isActive,
                  self.generation == scheduledGeneration,
                  self.benchmarkSegmentationToken == benchmarkToken else { return }
            self.segmentationCancellation.withAcceptedToken(benchmarkToken) {
                guard self.isActive,
                      self.generation == scheduledGeneration,
                      self.benchmarkSegmentationToken == benchmarkToken else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.silhouetteFreshness.shouldExpire(at: now, generation: scheduledGeneration.activationID) {
                    self.latestSilhouetteOverlay = .empty
                    self.segmentationState = .insufficient
                    self.onEvent(.silhouetteOverlay(self.combinedOverlay(), benchmarkToken), scheduledGeneration)
                    self.silhouetteExpirationWorkItem = nil
                }
            }
        }
        silhouetteExpirationWorkItem = workItem
        sampleQueue.asyncAfter(deadline: .now() + SilhouetteOverlayFreshnessTracker.maxAge, execute: workItem)
    }

    private func publishDiagnosticsIfNeeded() {
        guard analysisCadence.presentation.publishesVisualUpdates else { return }
        let inference = lastInferenceDiagnostics
        let now = ProcessInfo.processInfo.systemUptime
        let upperBodyResultAge: TimeInterval? = upperBodyResultCapturedAt.flatMap { capturedAt in
            guard capturedAt.isFinite, now >= capturedAt else { return nil }
            return now - capturedAt
        }
        onEvent(.diagnostics(CameraAnalysisDiagnostics(
            frameCallbacks: frameCallbacks,
            analyses: analyses,
            candidateOrientation: inference?.candidateOrientation ?? "—",
            lockedOrientation: inference?.lockedOrientation,
            faceOrientation: inference?.faceOrientation,
            faceGeometry: inference?.faceGeometry,
            faceResults: inference?.faceResultCount ?? 0,
            facesWithLandmarks: inference?.facesWithLandmarksCount ?? 0,
            facePoints: inference?.facePointCount ?? 0,
            bodyResults: inference?.bodyResultCount ?? 0,
            upperBodyEngineID: upperBodySession.descriptor.id,
            upperBodyAttempts: upperBodyAttempts,
            upperBodyResults: upperBodyResults,
            upperBodyLastStatus: upperBodyLastStatus,
            upperBodyLastRejectionReason: upperBodyLastRejectionReason,
            upperBodyRejected: Int(upperBodySession.admissionDiagnostics.rejected),
            upperBodyEngineRuns: Int(upperBodySession.admissionDiagnostics.engineRuns),
            upperBodyEngineDurationP95: upperBodySession.admissionDiagnostics.engineDurationP95,
            upperBodyEngineDurationMax: upperBodySession.admissionDiagnostics.engineDurationMax,
            upperBodyValidLandmarks: upperBodyValidLandmarks,
            upperBodyLeftShoulderScore: upperBodyLeftShoulderScore,
            upperBodyRightShoulderScore: upperBodyRightShoulderScore,
            upperBodySimCCMinimum: upperBodySimCCMinimum,
            upperBodySimCCMaximum: upperBodySimCCMaximum,
            upperBodyScoreMinimum: upperBodyScoreMinimum,
            upperBodyScoreMaximum: upperBodyScoreMaximum,
            upperBodyLatency: upperBodyLatency,
            upperBodyResultAge: upperBodyResultAge,
            upperBodyLandmarks: lastUpperBodyLandmarks,
            upperBodyROISpike: upperBodyROISpike,
            segmentationAttempts: segmentationAttempts,
            segmentationVisionPerforms: segmentationVisionPerforms,
            segmentationResults: segmentationResults,
            segmentationContoursValid: segmentationContoursValid,
            segmentationInsufficient: segmentationInsufficient,
            segmentationErrors: segmentationErrors,
            segmentationDurationP50: segmentationDurationP50,
            segmentationDurationP95: segmentationDurationP95,
            segmentationDurationMax: segmentationDurationMax,
            segmentationState: segmentationState,
            lastVisionError: lastVisionError
        )), generation)
    }

    private func indicators(from snapshot: PostureObservationsSnapshot) -> PostureIndicatorsSnapshot {
        func result(_ id: PostureIndicatorID, _ signalID: PostureObservationSignalID?) -> PostureIndicatorResult {
            guard let signalID else { return .unavailable(id) }
            let signal = snapshot.signal(signalID)
            let state: PostureIndicatorState
            if postureRuntimeCoordinator.isCalibrationActive {
                state = .calibrating
            } else {
                switch signal.availability {
            case .needsCalibration: state = .needsCalibration
            case .calibrating: state = .calibrating
            case .insufficient: state = .unavailable
            case .observing: state = .pending
            case .available: state = signal.assessment == .attention ? .attention : .normal
                }
            }
            let quality: PostureSignalQuality = switch signal.quality {
            case .good: .good
            case .limited: .limited
            case .unavailable: .unavailable
            }
            let hasValidBaseline = switch signal.availability {
            case .needsCalibration, .calibrating: false
            case .insufficient, .observing, .available: true
            }
            return .init(
                id: id,
                state: state,
                count: nil,
                observedAt: signal.observedAt,
                quality: quality,
                hasValidBaseline: hasValidBaseline,
                isExperimental: id == .estimatedBlinks || id == .shoulderSlope ||
                    id == .closedShoulders,
                freshnessTTL: PostureObservationEngine.freshnessTTL(for: signalID)
            )
        }
        let mapped: [PostureIndicatorResult] = [
            result(.apparentProximity, .proximity),
            result(.torsoInclination, .torsoInclination),
            result(.raisedShoulders, .raisedShoulders),
            result(.shoulderSlope, .shoulderSlope),
            result(.estimatedBlinks, .estimatedBlinks),
            result(.closedShoulders, .closedShoulders)
        ]
        return .init(generation: snapshot.generation, producedAt: snapshot.producedAt,
                     isCalibrating: postureRuntimeCoordinator.isCalibrationActive,
                     indicators: mapped)
    }

    private func preparePostureRuntime(for context: PostureFramingContext) {
        guard postureRuntimeContextKey != context.key ||
                postureRuntimeCoordinator.generation != UInt64(generation.activationID) else {
            return
        }
        postureRuntimeContextKey = context.key
        postureRuntimeCoordinator.reset(
            generation: UInt64(generation.activationID),
            contextKey: context.key,
            preserveCalibration: postureRuntimeCoordinator.isCalibrationActive
        )
        if !postureRuntimeCoordinator.isCalibrationActive,
           let persistedRichBaseline {
            postureRuntimeCoordinator.restoreBaseline(
                persistedRichBaseline,
                for: UInt64(generation.activationID),
                contextKey: context.key
            )
        }
    }

    private func recordSegmentationDuration(_ duration: TimeInterval) {
        segmentationDurations.append(duration)
        if segmentationDurations.count > 120 { segmentationDurations.removeFirst() }
        let sorted = segmentationDurations.sorted()
        func percentile(_ quantile: Double) -> TimeInterval {
            sorted[min(sorted.count - 1, max(0, Int(ceil(quantile * Double(sorted.count))) - 1))]
        }
        segmentationDurationP50 = percentile(0.50)
        segmentationDurationP95 = percentile(0.95)
        segmentationDurationMax = sorted.last
    }

    private func publishStabilized(result: PoseDetectionResult, at uptime: TimeInterval) {
        if let update = stabilizer.update(with: result, at: uptime) {
            switch update {
            case .publish(let observation):
                if observation == nil {
                    expirationWorkItem?.cancel()
                    expirationWorkItem = nil
                } else {
                    scheduleExpiration()
                }
                onEvent(.status(observation), generation)
            case .analysisFailed:
                expirationWorkItem?.cancel()
                expirationWorkItem = nil
                clearOverlay()
                isActive = false
                onEvent(.analysisFailed, generation)
            }
        }
    }

    private func scheduleExpiration() {
        expirationWorkItem?.cancel()
        let scheduledGeneration = generation

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isActive,
                  self.generation == scheduledGeneration else { return }
            let uptime = ProcessInfo.processInfo.systemUptime
            if case .publish(let expiredObservation) = self.stabilizer.expireIfNeeded(at: uptime) {
                self.onEvent(.status(expiredObservation), scheduledGeneration)
                self.expirationWorkItem = nil
            }
        }
        expirationWorkItem = workItem
        sampleQueue.asyncAfter(
            deadline: .now() + PoseResultStabilizer.maxPoseAge,
            execute: workItem
        )
    }
}
