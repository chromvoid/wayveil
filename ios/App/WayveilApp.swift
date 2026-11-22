import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct WayveilApp: App {
    @StateObject private var controller = VPNController()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(WayveilAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        Window("Wayveil", id: "main") {
            ContentView(controller: controller)
                .preferredColorScheme(.dark)
                .tint(Brand.cyan)
                .frame(minWidth: 380, minHeight: 640)
        }
        // The page's gradient runs up under the traffic lights instead of a grey title bar.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 440, height: 780)
        .windowResizability(.contentMinSize)
        #else
        WindowGroup {
            ContentView(controller: controller)
                .preferredColorScheme(.dark)
                .tint(Brand.cyan)
        }
        #endif
    }
}

#if os(macOS)
final class WayveilAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
