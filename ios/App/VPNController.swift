import Combine
import Foundation
import NetworkExtension
import WidgetKit

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

@MainActor
final class VPNController: ObservableObject {
    @Published private(set) var profile: ConnectionProfile?
    @Published private(set) var access: DeviceAccess?
    @Published private(set) var catalog: NodeCatalog?
    @Published private(set) var accessLoading = false
    @Published private(set) var accessError: String?
    @Published private(set) var phase: TunnelPhase = .disconnected {
        didSet {
            #if os(iOS)
            if phase != oldValue, #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(ofKind: "com.chromvoid.vpn.control")
            }
            #endif
            if phase != oldValue, !phase.running {
                let refresh = access != nil && !disconnectRequested && (phase == .error || oldValue.running)
                disconnectRequested = false
                if refresh { Task { await refreshCatalog(afterTunnelFailure: true) } }
            }
        }
    }
    @Published private(set) var metrics = ProfileStore.tunnelMetricsSnapshot
    @Published private(set) var liveDownloadBps: Double?
    @Published private(set) var liveUploadBps: Double?
    @Published var error: String?
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var catalogTimer: Timer?
    private let accessStore = AccessStore()
    private let accessManager = AccessManager()
    private var disconnectRequested = false
    private var refreshAfterAccessOperation = false
    private var providerAccessError: String?
    private var catalogRefreshRevision = 0
    private var requestID: UUID?
    private var connectionTask: Task<Void, Never>?
    private var active = false
    private var statsVisible = false
    private var metricsRequestID: UUID?
    private var metricsRequestedAt = Date.distantPast
    private var previousMetrics: TunnelMetricsSnapshot?

    var currentMetrics: TunnelMetricsSnapshot? { previousMetrics == nil ? nil : metrics }
    var canConnect: Bool { access != nil || profile != nil }
    var presentation: AccessPresentation {
        AccessPresentation(access: access, catalog: catalog, phase: phase, error: error, accessError: accessError)
    }
    var connectionProfile: ConnectionProfile? {
        access != nil ? presentation.selectedNode?.profile : profile
    }
    var selection: NodeSelection { NodeSelection(access) }

    init() {
        do { profile = try ProfileStore.read() }
        catch { self.error = L("load_failed") }
        do {
            access = try accessStore.readAccess()
            catalog = try accessStore.readCatalog().map { try NodeCatalog.parse($0) }
        } catch { self.error = L("load_failed") }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self, let connection = notification.object as? NEVPNConnection,
                      connection === self.manager?.connection else { return }
                self.refreshStatus()
            }
        }
    }

    func activate() {
        active = true
        scheduleRefreshTimer()
        Task { await refreshCatalog() }
        #if !targetEnvironment(simulator)
        Task {
            do {
                let configuration = try await loadManager()
                guard active, connectionTask == nil else { return }
                manager = configuration; refreshStatus()
            }
            catch { self.error = L("vpn_unavailable") }
        }
        #endif
    }

    func deactivate() {
        active = false
        timer?.invalidate(); timer = nil; requestID = nil
        catalogTimer?.invalidate(); catalogTimer = nil
        resetLiveMetrics()
    }

    func setStatsVisible(_ visible: Bool) {
        statsVisible = visible
        if active {
            scheduleRefreshTimer()
            if visible { requestMetrics() }
        }
    }

    private func scheduleRefreshTimer() {
        timer?.invalidate()
        #if !targetEnvironment(simulator)
        timer = Timer.scheduledTimer(withTimeInterval: statsVisible ? 1 : 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        #endif
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
        guard !phase.running else { throw NSError(domain: "Wayveil", code: 1, userInfo: [NSLocalizedDescriptionKey: L("disconnect_first")]) }
        guard access == nil else {
            accessError = "already_activated"
            throw AccessFailure("already_activated")
        }
        let value = try ConnectionProfile.parse(text)
        try ProfileStore.save(value)
        profile = value; error = nil
    }

    func activateInvitation(_ text: String) async throws {
        try await activateInvitationWhenIdle(text, state: { (access, accessLoading, phase) }) {
            beginAccessOperation()
            do {
                _ = try await accessManager.activate(text)
                await publishAccessState()
            } catch {
                await publishAccessState()
                accessError = (error as? AccessFailure)?.code ?? "network_error"
                throw error
            }
        }
        clearError()
    }

    func refreshCatalog(afterTunnelFailure: Bool = false) async {
        guard access != nil else { return }
        guard !accessLoading else {
            refreshAfterAccessOperation = refreshAfterAccessOperation || afterTunnelFailure
            return
        }
        beginAccessOperation()
        _ = try? await accessManager.refresh()
        await publishAccessState(catalogRefreshCompleted: true)
    }

    /// Pins the node: a connection then uses it alone.
    func selectNode(_ id: String) async throws {
        guard !phase.running, !accessLoading else { return }
        beginAccessOperation()
        do {
            try await accessManager.select(id)
            await publishAccessState()
        } catch {
            await publishAccessState()
            throw error
        }
    }

    /// Returns to the automatic choice of the node; the saved node stays the current one.
    func selectAuto() async throws {
        guard !phase.running, !accessLoading else { return }
        beginAccessOperation()
        do {
            try await accessManager.selectAuto()
            await publishAccessState()
        } catch {
            await publishAccessState()
            throw error
        }
    }

    func removeAccess() async throws {
        guard !phase.running, !accessLoading else { return }
        beginAccessOperation()
        do {
            try await accessManager.remove()
            await publishAccessState()
            clearError()
        } catch {
            await publishAccessState()
            throw error
        }
    }

    func clearError() {
        error = nil
        accessError = nil
        providerAccessError = nil
    }

    private func beginAccessOperation() {
        catalogTimer?.invalidate(); catalogTimer = nil
        accessLoading = true
    }

    private func publishAccessState(catalogRefreshCompleted: Bool = false) async {
        let state = await accessManager.state
        do { access = try accessStore.readAccess() }
        catch { self.error = L("load_failed") }
        catalog = state.catalog
        accessError = AccessPresentation.accessErrorCode(providerError: providerAccessError,
            refreshError: state.error, refreshCompleted: catalogRefreshCompleted)
        if catalogRefreshCompleted {
            providerAccessError = nil
            catalogRefreshRevision += 1
        }
        accessLoading = false
        if refreshAfterAccessOperation {
            refreshAfterAccessOperation = false
            await refreshCatalog()
        } else { scheduleCatalogRefresh() }
    }

    private func scheduleCatalogRefresh() {
        catalogTimer?.invalidate(); catalogTimer = nil
        guard active, access != nil, !accessLoading else { return }
        catalogTimer = Timer.scheduledTimer(withTimeInterval: presentation.refreshInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active else { return }
                await self.refreshCatalog()
            }
        }
    }

    func removeProfile() {
        guard !phase.running else { return }
        do { try ProfileStore.remove(); profile = nil; error = nil }
        catch { self.error = L("save_failed") }
    }

    func connect() {
        guard canConnect, !phase.running, connectionTask == nil else { return }
        clearError()
        disconnectRequested = false
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
                if [.connecting, .connected, .reasserting, .disconnecting].contains(configuration.connection.status) {
                    manager = configuration
                    refreshStatus()
                    return
                }
                let tunnel = NETunnelProviderProtocol()
                tunnel.providerBundleIdentifier = AppIdentity.tunnelIdentifier
                tunnel.serverAddress = "Wayveil"
                tunnel.disconnectOnSleep = false
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
        disconnectRequested = true
        connectionTask?.cancel()
        resetLiveMetrics()
        guard let manager else { phase = .disconnected; return }
        phase = .stopping; requestID = nil
        manager.connection.stopVPNTunnel()
        if [.invalid, .disconnected].contains(manager.connection.status) { phase = .disconnected }
    }

    private func refreshStatus() {
        defer { if phase != .connected { resetLiveMetrics() } }
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
                guard let data, let raw = String(data: data, encoding: .utf8), let state = TunnelPhase(rawValue: raw) else {
                    self.phase = .reconnecting; self.resetLiveMetrics(); return
                }
                // The extension saves the node it starts on or moves to as the current one, at any time while it runs.
                self.reloadAccess()
                self.phase = state
                if state == .error { self.requestAccessError() }
                if state == .connected { self.requestMetrics() }
                else { self.resetLiveMetrics() }
            }
        }
        do { try session.sendProviderMessage(Data("status".utf8), responseHandler: finish) }
        catch { finish(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.requestID == identifier else { return }
            self.requestID = nil
            if self.phase.running { self.phase = .reconnecting; self.resetLiveMetrics() }
        }
    }

    private func reloadAccess() {
        guard access != nil, !accessLoading else { return }
        AccessPresentation.reload(&access, &catalog, from: accessStore)
    }

    private func requestAccessError() {
        guard let access, let session = manager?.connection as? NETunnelProviderSession else { return }
        let refreshRevision = catalogRefreshRevision
        try? session.sendProviderMessage(Data("access_error".utf8)) { [weak self] data in
            Task { @MainActor in
                guard let self, self.access?.installation == access.installation, self.access?.token == access.token,
                      self.catalogRefreshRevision == refreshRevision,
                      !self.phase.running,
                      let data, let code = String(data: data, encoding: .utf8), !code.isEmpty else { return }
                self.providerAccessError = code
                self.accessError = code
            }
        }
    }

    private func requestMetrics() {
        guard active, phase == .connected, let session = manager?.connection as? NETunnelProviderSession else { return }
        let now = Date()
        guard metricsRequestID == nil || now.timeIntervalSince(metricsRequestedAt) >= 3 else { return }
        let identifier = UUID()
        metricsRequestID = identifier
        metricsRequestedAt = now
        let finish: (Data?) -> Void = { [weak self] data in
            Task { @MainActor in
                guard let self, self.active, self.phase == .connected, self.metricsRequestID == identifier else { return }
                self.metricsRequestID = nil
                guard let data, let snapshot = try? JSONDecoder().decode(TunnelMetricsSnapshot.self, from: data) else { return }
                let speed = self.previousMetrics.flatMap { snapshot.liveSpeed(since: $0) }
                self.previousMetrics = snapshot
                self.metrics = snapshot
                self.liveDownloadBps = speed?.downloadBps
                self.liveUploadBps = speed?.uploadBps
                ProfileStore.tunnelMetricsSnapshot = snapshot
            }
        }
        do { try session.sendProviderMessage(Data("metrics".utf8), responseHandler: finish) }
        catch { finish(nil) }
    }

    private func resetLiveMetrics() {
        metricsRequestID = nil
        previousMetrics = nil
        liveDownloadBps = nil
        liveUploadBps = nil
    }
}
