import AppKit
import Combine

@MainActor
final class AppModel: ObservableObject {
    let camera: CameraCaptureService

    private var isTerminating = false

    init() {
        camera = CameraCaptureService()
    }

    init(camera: CameraCaptureService) {
        self.camera = camera
    }

    func quit() {
        guard !isTerminating else { return }
        isTerminating = true
        camera.stop {
            NSApplication.shared.terminate(nil)
        }
    }
}
