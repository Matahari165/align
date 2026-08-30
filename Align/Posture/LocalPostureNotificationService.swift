import Foundation
import UserNotifications

@MainActor
final class LocalPostureNotificationService {
    enum Authorization: Equatable { case unknown, denied, authorized }
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func authorization() async -> Authorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    func requestAuthorization() async -> Authorization {
        do {
            return try await center.requestAuthorization(options: [.alert])
                ? .authorized : .denied
        } catch { return .denied }
    }

    func deliverProbablyTooClose() async -> Bool {
        guard await authorization() == .authorized else { return false }
        let content = UNMutableNotificationContent()
        content.title = "Align"
        content.body = "Vous êtes probablement trop proche de votre repère confortable."
        let request = UNNotificationRequest(
            identifier: "posture.proximity.\(UUID().uuidString)", content: content, trigger: nil
        )
        do { try await center.add(request); return true }
        catch { return false }
    }
}
