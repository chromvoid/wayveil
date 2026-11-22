import AppIntents
import Foundation

let controlConnectRequestedNotification = Notification.Name("WayveilControlConnectRequested")

struct OpenWayveilToConnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Wayveil"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "control_connect_requested")
        NotificationCenter.default.post(name: controlConnectRequestedNotification, object: nil)
        return .result()
    }
}
