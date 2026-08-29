import AppKit
import SwiftUI

struct WindowPresentationReader: NSViewRepresentable {
    let onChange: (Bool, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChange = onChange
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var onChange: (Bool, Bool) -> Void
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(onChange: @escaping (Bool, Bool) -> Void) {
            self.onChange = onChange
        }

        func attach(to window: NSWindow?) {
            guard self.window !== window else {
                publish()
                return
            }
            detach()
            self.window = window

            let center = NotificationCenter.default
            let names: [(Notification.Name, Any?)] = [
                (NSApplication.didBecomeActiveNotification, NSApp),
                (NSApplication.didResignActiveNotification, NSApp),
                (NSWindow.didMiniaturizeNotification, window),
                (NSWindow.didDeminiaturizeNotification, window)
            ]
            observers = names.map { name, object in
                center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.publish() }
                }
            }
            publish()
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            window = nil
        }

        private func publish() {
            onChange(NSApp.isActive, window?.isMiniaturized ?? false)
        }
    }
}
