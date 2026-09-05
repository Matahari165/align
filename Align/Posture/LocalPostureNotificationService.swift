import Foundation
import UserNotifications

nonisolated enum LocalPostureNotificationCopy {
    static let authorizationOptions: UNAuthorizationOptions = [.alert, .sound]
    static let testTitle = "Align · Test de rappel"
    static let testBody = "Ceci est un test. Les rappels Align sont activés."
    static let foregroundPresentationOptions: UNNotificationPresentationOptions = [
        .banner, .list, .sound
    ]

    static func body(for signalID: PostureObservationSignalID) -> String? {
        switch signalID {
        case .proximity:
            "Tu sembles un peu près de l’écran. Recule légèrement."
        case .torsoInclination:
            "Ton buste penche sur le côté par rapport à ton repère. Recentre ton buste."
        case .raisedShoulders:
            "Tes épaules restent relevées par rapport à ton repère. Relâche-les."
        case .headTilt:
            "Ta tête est penchée sur le côté. Réajuste-la."
        case .closedShoulders:
            "Réajuste la tête et relâche les épaules."
        case .shoulderSlope:
            "Une épaule semble plus haute que l’autre. Réaligne tes épaules."
        case .estimatedBlinks:
            "Pense à cligner naturellement et regarde au loin quelques instants."
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
        content.title = "Align"
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
        let request = UNNotificationRequest(
            identifier: "align.notification.test.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do { try await center.add(request); return true }
        catch { return false }
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
