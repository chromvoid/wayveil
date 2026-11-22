import AppIntents
import NetworkExtension
import SwiftUI
import WidgetKit

@main
struct WayveilControls: WidgetBundle {
    var body: some Widget {
        WayveilVPNControl()
    }
}

struct WayveilVPNControl: ControlWidget {
    nonisolated static let kind = "com.chromvoid.vpn.control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: VPNControlProvider()) { value in
            ControlWidgetToggle("Wayveil", isOn: value.isOn, action: SetVPNStateIntent()) { isOn in
                let statusKey = isOn == value.isOn ? value.statusKey : (isOn ? "connecting" : "stopping")
                Label(LocalizedStringKey(statusKey), systemImage: isOn ? "lock.shield.fill" : "lock.shield")
            }
            .tint(Color(red: 132/255, green: 213/255, blue: 1))
        }
        .displayName("Wayveil")
        .description("control_description")
    }
}

struct VPNControlProvider: ControlValueProvider {
    var previewValue: VPNControlValue { vpnControlValue(for: nil) }

    func currentValue() async throws -> VPNControlValue {
        let manager = try? await loadControlManager()
        return vpnControlValue(for: manager?.connection.status)
    }
}

private func loadControlManager() async throws -> NETunnelProviderManager? {
    var managers = try await NETunnelProviderManager.loadAllFromPreferences()
    if managers.isEmpty {
        try await Task.sleep(nanoseconds: 300_000_000)
        managers = try await NETunnelProviderManager.loadAllFromPreferences()
    }
    return managers.first {
        ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppIdentity.tunnelIdentifier
    }
}

struct SetVPNStateIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Wayveil"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Wayveil")
    var value: Bool

    func perform() async throws -> some IntentResult & OpensIntent {
        defer { ControlCenter.shared.reloadControls(ofKind: WayveilVPNControl.kind) }
        // iOS 18.0 and 18.1 require the typed opens-intent result.
        var result: IntentResultContainer<Never, OpenWayveilToConnectIntent, Never, Never> =
            .result(opensIntent: OpenWayveilToConnectIntent())
        if !value { result.opensIntent = nil }
        do {
            guard let manager = try await loadControlManager() else {
                return result
            }
            if value {
                guard try ProfileStore.read() != nil else {
                    return result
                }
                if !manager.isEnabled {
                    manager.isEnabled = true
                    try await manager.saveToPreferences()
                    try await manager.loadFromPreferences()
                }
                guard let session = manager.connection as? NETunnelProviderSession else {
                    throw NEVPNError(.configurationInvalid)
                }
                try session.startTunnel(options: nil)
            } else {
                manager.connection.stopVPNTunnel()
            }
        } catch {
            return result
        }
        result.opensIntent = nil
        return result
    }
}
