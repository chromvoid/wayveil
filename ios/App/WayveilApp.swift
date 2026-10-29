import SwiftUI

@main
struct WayveilApp: App {
    @StateObject private var controller = VPNController()
    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .preferredColorScheme(.dark)
                .tint(Brand.cyan)
        }
    }
}
