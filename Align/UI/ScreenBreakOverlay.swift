//
//  ScreenBreakOverlay.swift
//  Align
//
//  Overlay plein-écran de pause visuelle : un panneau borderless par écran,
//  affiché au niveau screenSaver avec un fondu doux. Le fond est un vrai flou
//  du bureau (NSVisualEffectView behindWindow) avec un texte blanc ombré,
//  lisible sur n'importe quel arrière-plan. Aucun son, aucun diagnostic,
//  aucune donnée sensible journalisée ou capturée.
//

import SwiftUI
import AppKit
import Combine

/// Contenu centré affiché sur chaque écran pendant une pause visuelle.
/// Style Lookaway : pas de carte, texte blanc avec ombre portée sur le
/// bureau flouté, horloge en haut, minuteur mm:ss au centre.
struct ScreenBreakOverlayContent: View {
    /// Secondes entières restantes, affichées par le minuteur.
    let remainingSeconds: Int
    /// Heure courante affichée en haut, format HH:mm.
    let timeString: String
    /// Durée nominale de la pause rappelée dans le sous-titre.
    let breakSeconds: Int
    /// Action appelée quand l'utilisateur passe la pause.
    let onSkip: () -> Void

    private var countdownText: String {
        let clamped = max(0, remainingSeconds)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    var body: some View {
        ZStack {
            // Voile léger par-dessus le flou : aide la lisibilité sans
            // masquer le bureau flouté derrière.
            Color.black.opacity(0.18)

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text(timeString)
                }
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 2)
                .accessibilityLabel("Heure actuelle \(timeString)")
                .padding(.top, 64)

                Spacer(minLength: 0)

                Text("It’s time to take a break.")
                    .font(.system(size: 44, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)

                Text("Fixez un point éloigné jusqu’à la fin du compte à rebours — \(breakSeconds) secondes.")
                    .font(.system(size: 17))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 2)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)

                Rectangle()
                    .fill(.white.opacity(0.35))
                    .frame(width: 120, height: 1)
                    .accessibilityHidden(true)
                    .padding(.top, 24)

                Text(countdownText)
                    .font(.system(size: 76, weight: .bold).monospacedDigit())
                    .foregroundStyle(AlignTheme.accentSoft)
                    .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 3)
                    .accessibilityLabel("Pause visuelle, \(remainingSeconds) secondes restantes")
                    .accessibilityAddTraits(.updatesFrequently)
                    .padding(.top, 20)

                Spacer(minLength: 0)

                VStack(spacing: 6) {
                    Button("Passer la pause", action: onSkip)
                        .buttonStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .underline()
                        .shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 1)
                    Text("Échap pour passer")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 1)
                }
                .padding(.bottom, 44)
            }
        }
        .background(Color.clear)
        .ignoresSafeArea()
    }
}

/// Présente et pilote l'overlay de pause sur tous les écrans.
///
/// Chaque `show` couvre les écrans présents à cet instant avec un panneau
/// `NSPanel` borderless non activant au niveau `.screenSaver`, sans droit
/// particulier (compatible sandbox). Le flou est un effet compositeur
/// (NSVisualEffectView behindWindow), sans capture d'écran. Le compte à
/// rebours avance par pas de 0,25 s sans jamais bloquer le thread principal.
@MainActor
final class ScreenBreakOverlayController: ObservableObject {
    /// Durée du fondu d'apparition (transition douce exigée).
    static let fadeInDuration: TimeInterval = 1.2
    /// Durée du fondu de disparition.
    static let fadeOutDuration: TimeInterval = 0.6

    @Published private(set) var isPresented = false
    @Published var remainingSeconds: Int = 0
    @Published var timeString: String = ""

    private static let tickInterval: UInt64 = 250_000_000 // 0,25 s
    private static let escapeKeyCode: UInt16 = 53
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var panels: [NSPanel] = []
    private var hostingViews: [NSHostingView<ScreenBreakOverlayContent>] = []
    private var countdownTask: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var screenChangeCancellable: AnyCancellable?

    private var breakSecondsValue: Int = 0
    private var endDate = Date()

    /// Affiche l'overlay pour `totalSeconds`. Si l'overlay est déjà visible,
    /// le minuteur est simplement relancé avec la nouvelle durée.
    func show(totalSeconds: TimeInterval) {
        guard totalSeconds > 0 else { return }
        breakSecondsValue = Int(ceil(totalSeconds))
        endDate = Date().addingTimeInterval(totalSeconds)
        remainingSeconds = breakSecondsValue
        updateClock()

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
            timeString: timeString,
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
        // Vrai flou du bureau en direct : effet compositeur derrière la
        // fenêtre, sans capture d'écran ni entitlement. `state: .active`
        // est obligatoire car un panel non activant ne devient jamais key.
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        effect.material = .fullScreenUI
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect
        let hostingView = NSHostingView(rootView: makeContent())
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
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

    private func updateClock() {
        timeString = Self.clockFormatter.string(from: Date())
    }

    private func tick() {
        let remaining = endDate.timeIntervalSince(Date())
        if remaining <= 0 {
            remainingSeconds = 0
            updateClock()
            refreshHostingViews()
            hide()
        } else {
            remainingSeconds = Int(ceil(remaining))
            updateClock()
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
