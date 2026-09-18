//
//  ScreenBreakOverlay.swift
//  Align
//
//  Overlay plein-écran de pause visuelle : un panneau borderless par écran,
//  affiché au niveau screenSaver avec un fondu doux. Aucun son, aucun
//  diagnostic, aucune donnée sensible journalisée ou capturée.
//

import SwiftUI
import AppKit
import Combine

/// Carte glass centrée affichée sur chaque écran pendant une pause visuelle.
struct ScreenBreakOverlayContent: View {
    /// Secondes entières restantes, affichées par le minuteur.
    let remainingSeconds: Int
    /// Durée totale prévue de la pause, en secondes entières.
    let totalSeconds: Int
    /// Fraction écoulée de la pause, entre 0 et 1.
    let progress: Double
    /// Durée nominale de la pause rappelée dans le sous-titre.
    let breakSeconds: Int
    /// Action appelée quand l'utilisateur passe la pause.
    let onSkip: () -> Void

    var body: some View {
        ZStack {
            // Fond plein-écran : matériau + voile sombre léger pour lisibilité.
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(Color.black.opacity(0.35))

            VStack(spacing: 16) {
                Label("Pause visuelle", systemImage: "eye")
                    .font(.headline)
                    .foregroundStyle(AlignTheme.accent)

                Text("It’s time to take a break.")
                    .font(.largeTitle)
                    .bold()
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AlignTheme.ivory)

                Text("Regarde au loin pendant \(breakSeconds) secondes.")
                    .foregroundStyle(.secondary)

                Text("\(remainingSeconds)s")
                    .monospacedDigit()
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(AlignTheme.ivory)
                    .accessibilityLabel("Pause visuelle, \(remainingSeconds) secondes restantes")
                    .accessibilityAddTraits(.updatesFrequently)

                ProgressView(value: min(1, max(0, progress)))
                    .frame(width: 280)
                    .tint(AlignTheme.accent)

                Button("Passer la pause", action: onSkip)
                    .buttonStyle(.borderedProminent)
                    .tint(AlignTheme.accent)

                Text("Échap pour passer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(AlignTheme.elevated.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(AlignTheme.hairline, lineWidth: 1)
            )
        }
        .ignoresSafeArea()
    }
}

/// Présente et pilote l'overlay de pause sur tous les écrans.
///
/// Chaque `show` couvre les écrans présents à cet instant avec un panneau
/// `NSPanel` borderless non activant au niveau `.screenSaver`, sans droit
/// particulier (compatible sandbox). Le compte à rebours avance par pas de
/// 0,25 s sans jamais bloquer le thread principal.
@MainActor
final class ScreenBreakOverlayController: ObservableObject {
    /// Durée du fondu d'apparition (transition douce exigée).
    static let fadeInDuration: TimeInterval = 1.2
    /// Durée du fondu de disparition.
    static let fadeOutDuration: TimeInterval = 0.6

    @Published private(set) var isPresented = false
    @Published var remainingSeconds: Int = 0
    @Published var progress: Double = 0

    private static let tickInterval: UInt64 = 250_000_000 // 0,25 s
    private static let escapeKeyCode: UInt16 = 53

    private var panels: [NSPanel] = []
    private var hostingViews: [NSHostingView<ScreenBreakOverlayContent>] = []
    private var countdownTask: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var screenChangeCancellable: AnyCancellable?

    private var totalSeconds: TimeInterval = 0
    private var breakSecondsValue: Int = 0
    private var endDate = Date()

    /// Affiche l'overlay pour `totalSeconds`. Si l'overlay est déjà visible,
    /// le minuteur est simplement relancé avec la nouvelle durée.
    func show(totalSeconds: TimeInterval) {
        guard totalSeconds > 0 else { return }
        self.totalSeconds = totalSeconds
        breakSecondsValue = Int(ceil(totalSeconds))
        endDate = Date().addingTimeInterval(totalSeconds)
        remainingSeconds = breakSecondsValue
        progress = 0

        if isPresented {
            refreshHostingViews()
            restartCountdown()
            return
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        panels.removeAll()
        hostingViews.removeAll()
        for screen in screens {
            let (panel, hostingView) = makePanel(on: screen)
            panels.append(panel)
            hostingViews.append(hostingView)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeInDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 1
            }
        }
        isPresented = true
        installEscapeMonitor()
        observeScreenChanges()
        restartCountdown()
    }

    /// Masque l'overlay, avec fondu sauf si `animated` vaut faux.
    func hide(animated: Bool = true) {
        countdownTask?.cancel()
        countdownTask = nil
        removeEscapeMonitor()
        guard isPresented else { return }
        isPresented = false
        let closing = panels
        panels.removeAll()
        hostingViews.removeAll()
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.fadeOutDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for panel in closing {
                    panel.animator().alphaValue = 0
                }
            }, completionHandler: {
                for panel in closing {
                    panel.orderOut(nil)
                    panel.close()
                }
            })
        } else {
            for panel in closing {
                panel.orderOut(nil)
                panel.close()
            }
        }
    }

    /// Passe la pause, comme le bouton et la touche Échap.
    func skip() {
        hide(animated: true)
    }

    // MARK: - Construction

    private func makeContent() -> ScreenBreakOverlayContent {
        ScreenBreakOverlayContent(
            remainingSeconds: remainingSeconds,
            totalSeconds: Int(ceil(totalSeconds)),
            progress: progress,
            breakSeconds: breakSecondsValue,
            onSkip: { [weak self] in
                Task { @MainActor in self?.skip() }
            }
        )
    }

    private func makePanel(on screen: NSScreen) -> (NSPanel, NSHostingView<ScreenBreakOverlayContent>) {
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.isMovable = false
        let hostingView = NSHostingView(rootView: makeContent())
        panel.contentView = hostingView
        return (panel, hostingView)
    }

    private func refreshHostingViews() {
        let content = makeContent()
        for hostingView in hostingViews {
            hostingView.rootView = content
        }
    }

    // MARK: - Compte à rebours

    private func restartCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.tickInterval)
                guard !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let remaining = endDate.timeIntervalSince(Date())
        if remaining <= 0 {
            remainingSeconds = 0
            progress = 1
            refreshHostingViews()
            hide()
        } else {
            remainingSeconds = Int(ceil(remaining))
            progress = min(1, max(0, 1 - remaining / totalSeconds))
            refreshHostingViews()
        }
    }

    // MARK: - Clavier et écrans

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode else { return event }
            Task { @MainActor in self?.skip() }
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    private func observeScreenChanges() {
        guard screenChangeCancellable == nil else { return }
        screenChangeCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.rescreen() }
            }
    }

    /// Recouvre les écrans actuels en conservant le minuteur en cours.
    private func rescreen() {
        guard isPresented else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let old = panels
        panels.removeAll()
        hostingViews.removeAll()
        for screen in screens {
            let (panel, hostingView) = makePanel(on: screen)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            panels.append(panel)
            hostingViews.append(hostingView)
        }
        for panel in old {
            panel.orderOut(nil)
            panel.close()
        }
        refreshHostingViews()
    }
}
