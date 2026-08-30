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
        let bodyConfidence = " · repères cou/épaules \(upperBodyLandmarks.recognizedCount)/3 · confiance \(upperBodyLandmarks.neckConfidence.map { String(format: "%.0f", $0 * 100) } ?? "—")/\(upperBodyLandmarks.leftShoulderConfidence.map { String(format: "%.0f", $0 * 100) } ?? "—")/\(upperBodyLandmarks.rightShoulderConfidence.map { String(format: "%.0f", $0 * 100) } ?? "—")"
        let segmentation = " · silhouette \(segmentationState.displayName) · cadence/performs/valid \(segmentationAttempts)/\(segmentationVisionPerforms)/\(segmentationContoursValid), \(segmentationDurationP95.map { String(format: "p95 %.0f ms", $0 * 1_000) } ?? "p95 —")"
        let roiSpike = upperBodyROISpike.rectangleAttempts > 0 ? " · spike ROI \(upperBodyROISpike.summary)" : ""
        return "Frames \(frameCallbacks) · analyses \(analyses) · orientation \(orientation) · faces \(faceResults) / landmarks \(facesWithLandmarks) / points \(facePoints) · corps \(bodyResults)\(bodyConfidence)\(segmentation)\(roiSpike)\(faceOrientationSummary)\(faceGeometrySummary)\(error)"
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
    @Published private(set) var blazePoseState: BlazePoseLiveState?
    @Published private(set) var postureIndicators = PostureIndicatorsSnapshot.initial
    @Published private(set) var proximityAlertBanner: String?
    @Published private(set) var proximityNotificationAuthorization: LocalPostureNotificationService.Authorization = .unknown
    @Published private(set) var diagnostics = CameraAnalysisDiagnostics.empty
    @Published private(set) var benchmarkState: BenchmarkViewState = .idle

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
    private let proximityNotificationService = LocalPostureNotificationService()
    private let proximityAlertHistoryStore = PostureProximityAlertHistoryStore()
    private var proximityAlertPolicy = PostureProximityAlertPolicy()
    private var proximityBannerWorkItem: DispatchWorkItem?
    private lazy var sampleDelegate = PoseSampleBufferDelegate(
        sampleQueue: sampleQueue,
        segmentationCancellation: benchmarkSegmentationCancellation
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
            case .blazePoseState(let state):
                self.blazePoseState = state
            case .postureIndicators(let snapshot):
                self.postureIndicators = snapshot
                self.evaluateProximityAlert(snapshot)
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
        proximityAlertPolicy = PostureProximityAlertPolicy(
            restoredDeliveries: PostureProximityAlertHistoryStore().load()
        )
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
                self?.setPoseProcessingActive(false)
                self?.state = .interrupted
                self?.recognizedPointCount = 0
                self?.trackingMode = nil
                self?.overlay = .empty
            }
            .store(in: &notificationCancellables)

        NotificationCenter.default.publisher(for: AVCaptureSession.interruptionEndedNotification, object: session)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.state == .interrupted, self?.session.isRunning == true else { return }
                self?.setPoseProcessingActive(true)
                self?.state = .running
            }
            .store(in: &notificationCancellables)

        NotificationCenter.default.publisher(for: AVCaptureSession.runtimeErrorNotification, object: session)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, self.state != .idle else { return }
                self.invalidateBenchmark(reason: "Benchmark annulé : une erreur caméra est survenue.")
                self.setPoseProcessingActive(false)
                self.recognizedPointCount = 0
                self.trackingMode = nil
                self.overlay = .empty

                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self.state = .failed(
                    error.map { "L’analyse caméra s’est interrompue : \($0.localizedDescription)" }
                        ?? "L’analyse caméra s’est interrompue à cause d’une erreur système."
                )
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

    private func evaluateProximityAlert(_ snapshot: PostureIndicatorsSnapshot) {
        let distance = snapshot.result(for: .headDistance)
        let isForeground = isSystemApplicationActive && isApplicationActive && !isWindowMiniaturized
        let deliveryTime = Date().timeIntervalSince1970
        let delivery = proximityAlertPolicy.consume(
            isProbablyTooClose: distance.state == .attention,
            isEligible: !snapshot.isCalibrating && distance.observedAt != nil &&
                (isForeground || proximityNotificationAuthorization == .authorized),
            isForeground: isForeground,
            now: deliveryTime
        )
        guard delivery != .none else { return }
        switch delivery {
        case .foregroundBanner:
            proximityAlertHistoryStore.save(proximityAlertPolicy.deliveries)
            proximityAlertBanner = "Vous êtes probablement trop proche de votre repère confortable."
            proximityBannerWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.proximityAlertBanner = nil }
            proximityBannerWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        case .backgroundNotification:
            Task { @MainActor [weak self] in
                guard let self else { return }
                if await self.proximityNotificationService.deliverProbablyTooClose() {
                    self.proximityAlertHistoryStore.save(self.proximityAlertPolicy.deliveries)
                } else {
                    self.proximityAlertPolicy.rollbackDelivery(at: deliveryTime)
                }
            }
        case .none: break
        }
    }

    func start() {
        guard state != .running, state != .configuring, state != .requestingPermission else {
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
                    state = .denied
                    return
                }
                configureAndStart(operationID: currentOperationID)
            }
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .failed("L’état de l’autorisation caméra est inconnu.")
        }
    }

    func stop(completion: (@MainActor @Sendable () -> Void)? = nil) {
        cancelBenchmark()
        operationID += 1
        setPoseProcessingActive(false)
        recognizedPointCount = 0
        trackingMode = nil
        overlay = .empty
        blazePoseState = nil
        postureIndicators = .initial
        proximityAlertPolicy.resetTracking()
        proximityBannerWorkItem?.cancel()
        proximityBannerWorkItem = nil
        proximityAlertBanner = nil
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
        let delegate = sampleDelegate
        sampleQueue.async {
            delegate.beginPostureCalibration(generation: generation)
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
        guard operationID == currentOperationID else { return }
        proximityAlertPolicy.resetTracking()
        setPoseProcessingActive(false)
        state = .configuring

        sessionRuntime.start(operationID: currentOperationID) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == currentOperationID else { return }

                switch result {
                case .running:
                    self.setPoseProcessingActive(true)
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

    private func setPoseProcessingActive(
        _ isActive: Bool,
        resetDiagnostics: Bool = true
    ) {
        if !isActive {
            proximityAlertPolicy.resetTracking()
            proximityBannerWorkItem?.cancel()
            proximityBannerWorkItem = nil
            proximityAlertBanner = nil
        }
        activationID += 1
        let generation = PoseProcessingGeneration(
            operationID: operationID,
            activationID: activationID
        )
        activePoseGeneration = isActive ? generation : nil
        overlay = .empty
        blazePoseState = nil
        postureIndicators = .initial
        if resetDiagnostics {
            diagnostics = .empty
        }
        let sampleDelegate = sampleDelegate
        sampleQueue.async {
            sampleDelegate.setActive(isActive, generation: generation)
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
    case blazePoseState(BlazePoseLiveState)
    case postureIndicators(PostureIndicatorsSnapshot)
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
    private let blazePoseEngine = BlazePoseLiveEngine()
    private let humanRectangleDetector = HumanRectangleDetector()
    private let segmentationDetector = PersonSegmentationDetector()
    private let segmentationCancellation: BenchmarkSegmentationCancellationBox
    private let onEvent: @Sendable (PoseProcessingEvent, PoseProcessingGeneration) -> Void
    private let sampleQueue: DispatchQueue
    private var analysisCadence = AnalysisCadenceController()
    private var isActive = false
    private var generation = PoseProcessingGeneration(operationID: 0, activationID: 0)
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
    private var latestBodyDetection: BodyDetectionOutput?
    private var faceInvisibleSince: TimeInterval?
    private var latestSilhouetteOverlay = PoseOverlay.empty
    private var latestBlazePoseOverlay = PoseOverlay.empty
    private var blazePoseCadence = BlazePoseCadenceController()
    private var blazePoseFreshness = BlazePoseOverlayFreshness()
    private var blazePoseExpirationWorkItem: DispatchWorkItem?
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
    private var posturePipeline = PostureSignalPipeline()
    private var postureSampleID: UInt64 = 0
    private var postureBodySourceID: UInt64 = 0
    private var postureFusion = PostureAsyncFusion(maximumSkew: 0.30)!
    private var postureExpirationWorkItem: DispatchWorkItem?
    private var postureCalibrationWorkItem: DispatchWorkItem?

    init(
        sampleQueue: DispatchQueue,
        segmentationCancellation: BenchmarkSegmentationCancellationBox,
        onEvent: @escaping @Sendable (PoseProcessingEvent, PoseProcessingGeneration) -> Void
    ) {
        self.sampleQueue = sampleQueue
        self.segmentationCancellation = segmentationCancellation
        self.onEvent = onEvent
    }

    func setActive(_ isActive: Bool, generation: PoseProcessingGeneration) {
        self.isActive = isActive
        self.generation = generation
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
        latestBodyDetection = nil
        faceInvisibleSince = nil
        latestSilhouetteOverlay = .empty
        latestBlazePoseOverlay = .empty
        blazePoseCadence.reset()
        blazePoseFreshness.clear()
        blazePoseExpirationWorkItem?.cancel()
        blazePoseExpirationWorkItem = nil
        blazePoseEngine.reset()
        postureSampleID = 0
        postureBodySourceID = 0
        postureFusion.reset()
        postureExpirationWorkItem?.cancel()
        postureExpirationWorkItem = nil
        postureCalibrationWorkItem?.cancel()
        postureCalibrationWorkItem = nil
        let postureSnapshot = posturePipeline.reset(generation: UInt64(generation.activationID))
        if isActive { onEvent(.postureIndicators(postureSnapshot), generation) }
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

    func beginPostureCalibration(generation requestedGeneration: PoseProcessingGeneration) {
        guard isActive, generation == requestedGeneration else { return }
        let snapshot = posturePipeline.beginCalibration(
            at: ProcessInfo.processInfo.systemUptime,
            generation: UInt64(generation.activationID)
        )
        onEvent(.postureIndicators(snapshot), generation)
        schedulePostureCalibrationFinish(after: PostureSignalPipeline.calibrationDuration,
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
            let result = self.posturePipeline.expire(
                at: now, generation: UInt64(scheduledGeneration.activationID)
            )
            self.onEvent(.postureIndicators(result), scheduledGeneration)
            if result.isCalibrating {
                self.schedulePostureCalibrationFinish(after: 2, generation: scheduledGeneration)
            }
        }
        postureCalibrationWorkItem = work
        sampleQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func publishPosture(face: FaceDetectionOutput, at uptime: TimeInterval) {
        postureSampleID &+= 1
        let geometry = FaceGeometrySignal.from(polylines: face.polylines)
        let center = geometry?.faceCenter.map { PostureMetricPoint(x: Double($0.x), y: Double($0.y)) }
        let faceOnly = PostureSnapshot(
            faceGeneration: UInt64(generation.activationID), faceTimestamp: uptime,
            faceSampleID: postureSampleID,
            facePointCount: face.polylines.reduce(0) { $0 + $1.locations.count },
            interocularDistance: geometry?.interocularDistance, faceLength: geometry?.faceLength,
            pitchProxy: geometry?.pitchProxy, yawProxy: geometry?.yawProxy,
            eyeLineRollDegrees: geometry?.eyeLineRollDegrees,
            leftEyeOpeningRatio: geometry?.leftEyeOpeningRatio,
            rightEyeOpeningRatio: geometry?.rightEyeOpeningRatio,
            innerBrowDistanceRatio: geometry?.innerBrowDistanceRatio, faceCenter: center,
            leftShoulder: nil, rightShoulder: nil, bodyGeneration: nil,
            bodyTimestamp: nil, bodySampleID: nil
        )
        guard let fused = postureFusion.ingestFace(faceOnly) else { return }
        publishPosture(fused, at: uptime)
    }

    private func publishPosture(shoulders result: BlazePoseLiveResult, at uptime: TimeInterval) {
        postureBodySourceID &+= 1
        guard let left = result.leftShoulder, let right = result.rightShoulder else {
            if let faceOnly = postureFusion.discardBody(
                generation: UInt64(generation.activationID), timestamp: uptime,
                sampleID: postureBodySourceID
            ) { publishPosture(faceOnly, at: uptime) }
            return
        }
        let body = PostureShoulderSnapshot(
            generation: UInt64(generation.activationID), timestamp: uptime,
            sampleID: postureBodySourceID,
            leftShoulder: .init(x: Double(left.location.x), y: Double(left.location.y)),
            rightShoulder: .init(x: Double(right.location.x), y: Double(right.location.y))
        )
        guard let fused = postureFusion.ingestBody(body) else { return }
        publishPosture(fused, at: uptime)
    }

    private func publishPosture(_ input: PostureSnapshot, at uptime: TimeInterval) {
        let result = posturePipeline.ingest(input, now: uptime)
        onEvent(.postureIndicators(result), generation)
        postureExpirationWorkItem?.cancel()
        let scheduledGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, self.generation == scheduledGeneration else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let expired = self.posturePipeline.expire(
                at: now, generation: UInt64(scheduledGeneration.activationID)
            )
            self.onEvent(.postureIndicators(expired), scheduledGeneration)
        }
        postureExpirationWorkItem = work
        sampleQueue.asyncAfter(deadline: .now() + PostureSignalPipeline.ttl, execute: work)
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
            onEvent(.overlay(combinedOverlay()), generation)
        } else if !segmentationDetector.isActive {
            segmentationDetector.activate()
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isActive else { return }
        frameCallbacks += 1

        let uptime = ProcessInfo.processInfo.systemUptime
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
        case .blazePose:
            blazePoseCadence.recordAttempt(at: uptime)
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                clearBlazePose(state: .technicalError)
                break
            }
            guard let result = blazePoseEngine.analyze(
                pixelBuffer,
                at: uptime,
                generation: UInt64(generation.activationID)
            ) else { break }
            publishPosture(shoulders: result, at: uptime)
            if result.state == .detected || result.state == .partial {
                latestBlazePoseOverlay = result.overlay
                blazePoseFreshness.record(at: uptime, generation: generation.activationID)
                scheduleBlazePoseExpiration(at: uptime)
                onEvent(.blazePoseState(result.state), generation)
            } else if result.state == .technicalError {
                clearBlazePose(state: .technicalError)
            } else if blazePoseFreshness.observedAt == nil {
                clearBlazePose(state: .lost)
            }
            if analysisCadence.presentation.publishesVisualUpdates {
                onEvent(.overlay(combinedOverlay()), generation)
            }

        case .face:
            analysisCadence.recordAnalysis(at: uptime)
            faceAttempted = true
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                latestFaceDetection = .empty
                faceDuration = 0
                lastVisionError = "Visage : buffer vidéo absent"
                clearFaceOverlay()
                break
            }
            let start = ProcessInfo.processInfo.systemUptime
            do {
                let face = try detector.detectFace(in: pixelBuffer)
                faceDuration = ProcessInfo.processInfo.systemUptime - start
                latestFaceDetection = face
                faceSucceeded = face.resultCount > 0
                faceHadLandmarks = face.facesWithLandmarksCount > 0
                faceOrientation = face.primaryOrientation
                lastVisionError = nil
                publishPosture(face: face, at: uptime)
                handleFaceVisibility(face.polylines.isEmpty ? nil : uptime)
                if face.polylines.isEmpty { clearFaceOverlay() }
            } catch {
                faceDuration = ProcessInfo.processInfo.systemUptime - start
                latestFaceDetection = .empty
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
            case .blazePose:
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

    private func combinedOverlay() -> PoseOverlay {
        let bodyPoints = bodyOverlayAvailableUntil.map { ProcessInfo.processInfo.systemUptime < $0 } == true
            ? (latestBodyDetection?.points ?? [])
            : []
        return PoseOverlay(
            points: bodyPoints + latestBlazePoseOverlay.points,
            polylines: latestFaceDetection.polylines
                + latestSilhouetteOverlay.polylines
                + latestBlazePoseOverlay.polylines
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
            blazePoseCadence.isDue(at: uptime)
                ? VisionAnalysisCandidate(unit: .blazePose, overdue: blazePoseCadence.overdue(at: uptime), priority: 4)
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

    private func scheduleBlazePoseExpiration(at uptime: TimeInterval) {
        blazePoseExpirationWorkItem?.cancel()
        let scheduledGeneration = generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isActive,
                  self.generation == scheduledGeneration else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard self.blazePoseFreshness.shouldExpire(
                at: now,
                generation: scheduledGeneration.activationID
            ) else { return }
            self.clearBlazePose(state: .lost)
        }
        blazePoseExpirationWorkItem = workItem
        sampleQueue.asyncAfter(
            deadline: .now() + BlazePoseOverlayFreshness.maxAge,
            execute: workItem
        )
    }

    private func clearBlazePose(
        state: BlazePoseLiveState,
        publishesState: Bool = true
    ) {
        blazePoseExpirationWorkItem?.cancel()
        blazePoseExpirationWorkItem = nil
        blazePoseFreshness.clear()
        latestBlazePoseOverlay = .empty
        blazePoseEngine.resetTracking()
        if publishesState { onEvent(.blazePoseState(state), generation) }
        if analysisCadence.presentation.publishesVisualUpdates {
            onEvent(.overlay(combinedOverlay()), generation)
        }
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
