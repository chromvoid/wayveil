import Combine
import Foundation
import NetworkExtension

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

@MainActor
final class VPNController: ObservableObject {
    @Published private(set) var profile: ConnectionProfile?
    @Published private(set) var routing = ProfileStore.routing
    @Published private(set) var phase: TunnelPhase = .disconnected
    @Published var error: String?
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var requestID: UUID?
    private var connectionTask: Task<Void, Never>?

    init() {
        do { profile = try ProfileStore.read() }
        catch { self.error = L("load_failed") }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self, let connection = notification.object as? NEVPNConnection,
                      connection === self.manager?.connection else { return }
                self.refreshStatus()
            }
        }
    }

    func activate() {
        timer?.invalidate()
        #if !targetEnvironment(simulator)
        Task {
            do {
                let configuration = try await loadManager()
                guard connectionTask == nil else { return }
                manager = configuration; refreshStatus()
            }
            catch { self.error = L("vpn_unavailable") }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        #endif
    }

    func deactivate() {
        timer?.invalidate(); timer = nil; requestID = nil
    }

    private func loadManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        guard let configuration = managers.first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppIdentity.tunnelIdentifier }) else { return nil }
        if let tunnel = configuration.protocolConfiguration as? NETunnelProviderProtocol,
           [.invalid, .disconnected].contains(configuration.connection.status),
           configuration.localizedDescription != "Wayveil" || tunnel.serverAddress != "Wayveil" {
            configuration.localizedDescription = "Wayveil"
            tunnel.serverAddress = "Wayveil"
            try await configuration.saveToPreferences()
            try await configuration.loadFromPreferences()
        }
        return configuration
    }

    func save(_ text: String) throws {
        guard !phase.running else { throw NSError(domain: "ChromVoidVPN", code: 1, userInfo: [NSLocalizedDescriptionKey: L("disconnect_first")]) }
        let value = try ConnectionProfile.parse(text)
        try ProfileStore.save(value)
        profile = value; error = nil
    }

    func removeProfile() {
        guard !phase.running else { return }
        do { try ProfileStore.remove(); profile = nil; error = nil }
        catch { self.error = L("save_failed") }
    }

    func setRouting(_ value: RoutingMode) {
        guard !phase.running else { return }
        routing = value; ProfileStore.routing = value
    }

    func connect() {
        guard profile != nil, !phase.running, connectionTask == nil else { return }
        error = nil
        #if targetEnvironment(simulator)
        error = L("physical_device_required")
        return
        #else
        phase = .connecting
        connectionTask = Task {
            defer { connectionTask = nil }
            do {
                let configuration = try await loadManager() ?? NETunnelProviderManager()
                try Task.checkCancellation()
                let tunnel = NETunnelProviderProtocol()
                tunnel.providerBundleIdentifier = AppIdentity.tunnelIdentifier
                tunnel.serverAddress = "Wayveil"
                tunnel.disconnectOnSleep = false
                tunnel.providerConfiguration = ["routing": routing.rawValue]
                configuration.protocolConfiguration = tunnel
                configuration.localizedDescription = "Wayveil"
                configuration.isEnabled = true
                configuration.isOnDemandEnabled = false
                try await configuration.saveToPreferences()
                try Task.checkCancellation()
                try await configuration.loadFromPreferences()
                try Task.checkCancellation()
                manager = configuration
                guard let session = configuration.connection as? NETunnelProviderSession else { throw NEVPNError(.configurationInvalid) }
                try session.startTunnel(options: nil)
            } catch {
                if !Task.isCancelled { phase = .error; self.error = L("start_failed") }
            }
        }
        #endif
    }

    func disconnect() {
        connectionTask?.cancel()
        guard let manager else { phase = .disconnected; return }
        phase = .stopping; requestID = nil
        manager.connection.stopVPNTunnel()
        if [.invalid, .disconnected].contains(manager.connection.status) { phase = .disconnected }
    }

    private func refreshStatus() {
        guard let manager else { if !phase.running { phase = .disconnected }; return }
        switch manager.connection.status {
        case .invalid, .disconnected:
            if connectionTask != nil && connectionTask?.isCancelled == false { return }
            if phase != .error { phase = .disconnected }
            requestID = nil
        case .connecting:
            phase = .connecting
        case .disconnecting:
            phase = .stopping; requestID = nil
        case .reasserting:
            phase = .reconnecting
            requestProviderStatus()
        case .connected:
            if !phase.running { phase = .connecting }
            requestProviderStatus()
        @unknown default: phase = .error
        }
    }

    private func requestProviderStatus() {
        guard requestID == nil, let session = manager?.connection as? NETunnelProviderSession else { return }
        let identifier = UUID(); requestID = identifier
        let finish: (Data?) -> Void = { [weak self] data in
            Task { @MainActor in
                guard let self, self.requestID == identifier else { return }
                self.requestID = nil
                guard let data, let raw = String(data: data, encoding: .utf8), let state = TunnelPhase(rawValue: raw), state.running else {
                    self.phase = .reconnecting; return
                }
                self.phase = state
            }
        }
        do { try session.sendProviderMessage(Data("status".utf8), responseHandler: finish) }
        catch { finish(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.requestID == identifier else { return }
            self.requestID = nil
            if self.phase.running { self.phase = .reconnecting }
        }
    }
}
