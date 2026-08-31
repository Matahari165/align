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

    func deliver(candidate: PostureAlertCandidate) async -> Bool {
        guard PostureObservationSignalID.alertableCases.contains(candidate.signalID) else {
            return false
        }
        guard await authorization() == .authorized else { return false }
        let content = UNMutableNotificationContent()
        content.title = "Align"
        let body: String? = switch candidate.signalID {
        case .proximity: "Tu sembles un peu près de l’écran. Recule légèrement si c’est confortable."
        case .torsoInclination: "Ton torse reste incliné par rapport à ton repère. Recentre-toi si tu le souhaites."
        case .raisedShoulders: "Tes épaules restent plus hautes que ton repère. Relâche-les si tu le peux."
        case .estimatedBlinks: "Les clignements estimés restent sous ton repère depuis un moment. Regarde au loin quelques instants et cligne naturellement."
        case .shoulderSlope, .closedShoulders: nil
        }
        guard let body else { return false }
        content.body = body
        let request = UNNotificationRequest(
            identifier: candidate.identifier, content: content, trigger: nil
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
