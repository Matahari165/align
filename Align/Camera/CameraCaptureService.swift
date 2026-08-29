@preconcurrency import AVFoundation
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
    let lastVisionError: String?

    var summary: String {
        let orientation = lockedOrientation.map { "\(candidateOrientation)→\($0)" }
            ?? candidateOrientation
        let error = lastVisionError.map { " · erreur: \($0)" } ?? ""
        let faceOrientationSummary = faceOrientation.map { " · visage \($0.summary)" } ?? ""
        let faceGeometrySummary = faceGeometry.map { " · géométrie \($0.summary)" } ?? ""
        return "Frames \(frameCallbacks) · analyses \(analyses) · orientation \(orientation) · faces \(faceResults) / landmarks \(facesWithLandmarks) / points \(facePoints) · corps \(bodyResults)\(faceOrientationSummary)\(faceGeometrySummary)\(error)"
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
    @Published private(set) var diagnostics = CameraAnalysisDiagnostics.empty
    @Published private(set) var benchmarkState: BenchmarkViewState = .idle

    private let sampleQueue = DispatchQueue(label: "com.align.camera.samples")
    private var notificationCancellables: Set<AnyCancellable> = []
    private var operationID = 0
    private var activationID = 0
    private var activePoseGeneration: PoseProcessingGeneration?
    private var benchmarkSession: BenchmarkSession?
    private var benchmarkProgressTask: Task<Void, Never>?
    private var isApplicationActive = true
    private var isWindowMiniaturized = false
    private lazy var sampleDelegate = PoseSampleBufferDelegate(
        sampleQueue: sampleQueue
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

    func stop() {
        cancelBenchmark()
        operationID += 1
        setPoseProcessingActive(false)
        recognizedPointCount = 0
        trackingMode = nil
        overlay = .empty
        state = .idle
        sessionRuntime.stop(operationID: operationID)
    }

    func startBenchmark() {
        guard state == .running,
              isApplicationActive,
              !isWindowMiniaturized else { return }
        benchmarkProgressTask?.cancel()
        var benchmark = BenchmarkSession()
        let uptime = ProcessInfo.processInfo.systemUptime
        benchmark.start(at: uptime)
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
                    let report = benchmark.finish(at: now)
                    self.benchmarkSession = nil
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
        benchmarkSession = nil
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
        benchmarkSession = nil
        benchmarkState = .invalidated(reason)
        updateAnalysisPresentation()
    }

    private func updateAnalysisPresentation() {
        let presentation = currentAnalysisPresentation
        if !presentation.publishesVisualUpdates {
            overlay = .empty
        }
        let sampleDelegate = sampleDelegate
        sampleQueue.async {
            sampleDelegate.updatePresentation(presentation)
        }
    }

    private var currentAnalysisPresentation: AnalysisPresentationState {
        AnalysisPresentationState(
            isApplicationActive: isApplicationActive,
            isWindowMiniaturized: isWindowMiniaturized,
            isBenchmarkRunning: benchmarkSession != nil
        )
    }

    private func configureAndStart(operationID currentOperationID: Int) {
        guard operationID == currentOperationID else { return }
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
        activationID += 1
        let generation = PoseProcessingGeneration(
            operationID: operationID,
            activationID: activationID
        )
        activePoseGeneration = isActive ? generation : nil
        overlay = .empty
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

    func stop(operationID: Int) {
        queue.async { [self] in
            guard operationID >= expectedOperationID else { return }
            expectedOperationID = operationID
            if session.isRunning {
                session.stopRunning()
            }
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
            if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= 15 && $0.maxFrameRate >= 15
            }) {
                let frameDuration = CMTime(value: 1, timescale: 15)
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
    private var bodyStatusAvailableUntil: TimeInterval?

    init(
        sampleQueue: DispatchQueue,
        onEvent: @escaping @Sendable (PoseProcessingEvent, PoseProcessingGeneration) -> Void
    ) {
        self.sampleQueue = sampleQueue
        self.onEvent = onEvent
    }

    func setActive(_ isActive: Bool, generation: PoseProcessingGeneration) {
        self.isActive = isActive
        self.generation = generation
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
    }

    func updatePresentation(_ presentation: AnalysisPresentationState) {
        analysisCadence.updatePresentation(presentation)
        if !presentation.publishesVisualUpdates {
            overlayExpirationWorkItem?.cancel()
            overlayExpirationWorkItem = nil
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
        guard analysisCadence.shouldAnalyze(at: uptime) else { return }
        analyses += 1

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            lastVisionError = "Buffer vidéo absent"
            publishDiagnosticsIfNeeded()
            publishStabilized(result: .inferenceError, at: uptime)
            return
        }

        let faceStart = ProcessInfo.processInfo.systemUptime
        do {
            let face = try detector.detectFace(in: pixelBuffer)
            let faceDuration = ProcessInfo.processInfo.systemUptime - faceStart

            var body: BodyDetectionOutput?
            var bodyDuration: TimeInterval?
            if bodyCadence.shouldRun(at: uptime) {
                let bodyStart = ProcessInfo.processInfo.systemUptime
                do {
                    let detectedBody = try detector.detectBody(in: pixelBuffer)
                    bodyDuration = ProcessInfo.processInfo.systemUptime - bodyStart
                    body = detectedBody
                    bodyCadence.recordAttempt(
                        at: uptime,
                        bodyAvailable: detectedBody.hasUpperBody
                    )
                    bodyStatusAvailableUntil = detectedBody.hasUpperBody
                        ? uptime + 1.2
                        : nil
                } catch {
                    bodyDuration = ProcessInfo.processInfo.systemUptime - bodyStart
                    bodyCadence.recordAttempt(at: uptime, bodyAvailable: false)
                    bodyStatusAvailableUntil = nil
                    lastVisionError = "Corps : \(error.localizedDescription)"
                }
            }

            let output = detector.combine(
                face: face,
                body: body,
                bodyStatusAvailable: bodyStatusAvailableUntil.map { uptime < $0 } == true
            )
            let currentOverlay = output.observation?.overlay ?? .empty
            let isOverlayVisible = !currentOverlay.isEmpty
            lastInferenceDiagnostics = output.diagnostics
            if bodyDuration == nil || body != nil {
                lastVisionError = nil
            }
            publishDiagnosticsIfNeeded()
            if analysisCadence.presentation.publishesVisualUpdates {
                if isOverlayVisible {
                    publishFreshOverlay(currentOverlay, at: uptime)
                } else {
                    clearOverlay()
                }
            }
            publishStabilized(
                result: output.observation.map { .detected($0.status) } ?? .noPose,
                at: uptime
            )
            if analysisCadence.presentation.isBenchmarkRunning {
                onEvent(.benchmarkMeasurement(BenchmarkMeasurement(
                    faceDuration: faceDuration,
                    faceSucceeded: face.resultCount > 0,
                    faceHadLandmarks: face.facesWithLandmarksCount > 0,
                    faceOrientation: face.primaryOrientation,
                    faceGeometry: output.diagnostics.faceGeometry,
                    bodyDuration: bodyDuration,
                    bodySucceeded: body?.hasUpperBody == true,
                    overlayVisible: isOverlayVisible
                ), uptime), generation)
            }
        } catch {
            lastVisionError = error.localizedDescription
            publishDiagnosticsIfNeeded()
            publishStabilized(result: .inferenceError, at: uptime)
            if analysisCadence.presentation.isBenchmarkRunning {
                onEvent(.benchmarkMeasurement(BenchmarkMeasurement(
                    faceDuration: ProcessInfo.processInfo.systemUptime - faceStart,
                    faceSucceeded: false,
                    faceHadLandmarks: false,
                    faceOrientation: nil,
                    faceGeometry: nil,
                    bodyDuration: nil,
                    bodySucceeded: false,
                    overlayVisible: false
                ), uptime), generation)
            }
        }
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
                self.onEvent(.overlay(.empty), scheduledGeneration)
                self.onEvent(.benchmarkOverlayVisibility(false, uptime), scheduledGeneration)
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
        onEvent(.overlay(.empty), generation)
        onEvent(.benchmarkOverlayVisibility(
            false,
            ProcessInfo.processInfo.systemUptime
        ), generation)
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
            lastVisionError: lastVisionError
        )), generation)
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
