import AppKit
import SwiftUI

nonisolated struct WindowPresentationState: Equatable, Sendable {
    let isKey: Bool
    let isVisible: Bool
    let isMiniaturized: Bool
    let isOccluded: Bool

    static let hidden = Self(
        isKey: false,
        isVisible: false,
        isMiniaturized: true,
        isOccluded: true
    )

    // Losing key status to the menu bar does not reduce the analysis cadence.
    var usesForegroundCadence: Bool {
        isVisible && !isMiniaturized && !isOccluded
    }
}

nonisolated struct WindowPresentationLifecycle: Equatable, Sendable {
    private(set) var isClosing = false

    mutating func windowWillClose() {
        isClosing = true
    }

    mutating func windowDidBecomeKey() {
        isClosing = false
    }

    mutating func detach() {
        isClosing = false
    }
}

struct WindowPresentationReader: NSViewRepresentable {
    let onChange: (WindowPresentationState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.scheduleAttach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.scheduleAttach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach(publishingHiddenState: true)
    }

    @MainActor
    final class Coordinator {
        var onChange: (WindowPresentationState) -> Void
        private weak var window: NSWindow?
        private weak var pendingView: NSView?
        private var attachmentScheduled = false
        private var observers: [NSObjectProtocol] = []
        private var lifecycle = WindowPresentationLifecycle()
        private var lastPublishedState: WindowPresentationState?

        init(onChange: @escaping (WindowPresentationState) -> Void) {
            self.onChange = onChange
        }

        /// SwiftUI may call `updateNSView` several times before AppKit has
        /// attached the representable to a window. Coalesce those requests so
        /// the presentation reader creates at most one main-queue callback per
        /// run-loop turn.
        func scheduleAttach(to view: NSView) {
            pendingView = view
            guard !attachmentScheduled else { return }
            attachmentScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.attachmentScheduled = false
                guard let pendingView = self.pendingView else { return }
                self.pendingView = nil
                self.attach(to: pendingView.window)
            }
        }

        func attach(to window: NSWindow?) {
            guard self.window !== window else {
                publish()
                return
            }
            detach(publishingHiddenState: false)
            self.window = window
            lifecycle.detach()

            guard let window else {
                publish(.hidden)
                return
            }

            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.didChangeOcclusionStateNotification
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if name == NSWindow.didBecomeKeyNotification {
                            self?.lifecycle.windowDidBecomeKey()
                        }
                        self?.publish()
                    }
                }
            }
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.markClosing() }
                }
            )
            publish()
        }

        func detach(publishingHiddenState: Bool) {
            pendingView = nil
            attachmentScheduled = false
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            window = nil
            lifecycle.detach()
            if publishingHiddenState {
                publish(.hidden)
            }
        }

        private func markClosing() {
            lifecycle.windowWillClose()
            publish(.hidden)
        }

        private func publish(_ state: WindowPresentationState? = nil) {
            let nextState: WindowPresentationState
            if lifecycle.isClosing {
                nextState = .hidden
            } else if let state {
                nextState = state
            } else if let window {
                nextState = WindowPresentationState(
                    isKey: window.isKeyWindow,
                    isVisible: window.isVisible,
                    isMiniaturized: window.isMiniaturized,
                    isOccluded: !window.occlusionState.contains(.visible)
                )
            } else {
                nextState = .hidden
            }
            guard lastPublishedState != nextState else { return }
            lastPublishedState = nextState
            onChange(nextState)
        }
    }
}
