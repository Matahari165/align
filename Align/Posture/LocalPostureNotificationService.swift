import Foundation
import UserNotifications

nonisolated enum LocalPostureNotificationCopy {
    static let authorizationOptions: UNAuthorizationOptions = [.alert, .sound]
    static let testTitle = "Align · Test de rappel"
    static let testBody = "Ceci est un test. Les rappels Align sont activés."
    static let screenBreakTitle = "Pause visuelle"

    static func screenBreakBody(breakSeconds: Int = 20) -> String {
        "Regarde au loin pendant \(breakSeconds) secondes. Align validera la pause lorsque ton visage quittera l’écran."
    }
    static let foregroundPresentationOptions: UNNotificationPresentationOptions = [
        .banner, .list, .sound
    ]

    static func title(for signalID: PostureObservationSignalID) -> String {
        switch signalID {
        case .proximity:
            "Distance à l’écran"
        case .torsoInclination:
            "Buste incliné"
        case .raisedShoulders:
            "Épaules relevées"
        case .shoulderSlope:
            "Pente des épaules"
        case .closedShoulders:
            "Tête–épaules"
        case .headTilt:
            "Tête inclinée"
        case .estimatedBlinks:
            "Clignements"
        case .handOnFace:
            "Main au visage"
        }
    }

    static func body(for signalID: PostureObservationSignalID) -> String? {
        switch signalID {
        case .proximity:
            "Ton visage occupe beaucoup d’espace dans le cadre. Éloigne-toi légèrement."
        case .torsoInclination:
            "Ton buste penche sur le côté par rapport à l’axe de l’image. Recentre ton buste."
        case .raisedShoulders:
            "Le triangle entre la base de ton cou et tes épaules semble aplati. Relâche tes épaules."
        case .headTilt:
            "Ta tête est penchée sur le côté. Réajuste-la."
        case .closedShoulders:
            "Réajuste la tête et relâche les épaules."
        case .shoulderSlope:
            "Une épaule semble plus haute que l’autre. Réaligne tes épaules."
        case .estimatedBlinks:
            "Pense à cligner naturellement et regarde au loin quelques instants."
        case .handOnFace:
            "Ta main semble rester sur ton visage. Éloigne-la doucement."
        }
    }
}

@MainActor
final class LocalPostureNotificationService: NSObject {
    enum Authorization: Equatable { case unknown, denied, authorized }
    private let center: UNUserNotificationCenter
    private var didRegisterSoundOption = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func authorization() async -> Authorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            // An older installation may already be authorized for alerts
            // without having registered the sound option. Re-register once
            // so the migration does not depend on the user finding Settings.
            if !didRegisterSoundOption {
                _ = try? await center.requestAuthorization(
                    options: LocalPostureNotificationCopy.authorizationOptions
                )
                didRegisterSoundOption = true
            }
            return .authorized
        case .denied: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    func requestAuthorization() async -> Authorization {
        do {
            let granted = try await center.requestAuthorization(
                options: LocalPostureNotificationCopy.authorizationOptions
            )
            didRegisterSoundOption = true
            return granted
                ? .authorized : .denied
        } catch { return .denied }
    }

    func deliver(candidate: PostureAlertCandidate) async -> Bool {
        guard PostureObservationSignalID.alertableCases.contains(candidate.signalID) else {
            return false
        }
        guard await authorization() == .authorized else { return false }
        let content = UNMutableNotificationContent()
        content.title = LocalPostureNotificationCopy.title(for: candidate.signalID)
        let body = LocalPostureNotificationCopy.body(for: candidate.signalID)
        guard let body else { return false }
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: candidate.identifier, content: content, trigger: nil
        )
        do { try await center.add(request); return true }
        catch { return false }
    }

    /// Sends an explicit diagnostic notification without creating a posture
    /// candidate or a history entry. It is used only from Settings to verify
    /// that macOS can display Align reminders.
    func deliverTestNotification() async -> Bool {
        guard await authorization() == .authorized else { return false }
        let content = UNMutableNotificationContent()
        content.title = LocalPostureNotificationCopy.testTitle
        content.body = LocalPostureNotificationCopy.testBody
        content.sound = .default
        let identifier = "align.notification.test.\(UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            scheduleTransientRetraction(for: identifier)
            return true
        }
        catch { return false }
    }

    func deliverScreenBreakReminder(identifier: String, breakSeconds: Int = 20) async -> Bool {
        guard await authorization() == .authorized else { return false }
        let content = UNMutableNotificationContent()
        content.title = LocalPostureNotificationCopy.screenBreakTitle
        content.body = LocalPostureNotificationCopy.screenBreakBody(breakSeconds: breakSeconds)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil
        )
        do { try await center.add(request); return true }
        catch { return false }
    }

    private func scheduleTransientRetraction(for identifier: String) {
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 8_000_000_000)
            } catch {
                return
            }
            guard let self else { return }
            await self.retract(identifier: identifier)
        }
    }

    /// Removes a request if its activation became obsolete while delivery was
    /// awaiting macOS. This keeps a late notification from surviving a reset.
    func retract(identifier: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

extension LocalPostureNotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Quand Align est visible, macOS doit afficher le rappel immédiatement
        // au premier plan. Hors premier plan, macOS garde sa présentation
        // système habituelle sans passer par ce callback.
        completionHandler(LocalPostureNotificationCopy.foregroundPresentationOptions)
    }
}
