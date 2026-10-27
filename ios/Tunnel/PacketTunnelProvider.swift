import Foundation
import Libbox
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider, LibboxCommandServerHandlerProtocol {
    let workQueue = DispatchQueue(label: "com.chromvoid.vpn.tunnel")
    private let stateLock = NSLock()
    private var state = TunnelPhase.disconnected
    private var server: LibboxCommandServer?
    private var platform: BoxPlatform?
    private var probe: LibboxCommandClient?
    private var probeHandler: CoreProbe?
    private var heartbeat: DispatchSourceTimer?
    private var started = Date()
    private var lastSuccess: TimeInterval = 0
    private var lastProbe = Date.distantPast
    private var requiredSuccessAfter: TimeInterval = 0
    private var online = true

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        setPhase(.connecting)
        workQueue.async { [self] in
            do {
                guard let profile = try ProfileStore.read() else { throw self.failure("A connection profile is required.") }
                let rawMode = (self.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["routing"] as? String
                guard let mode = rawMode.flatMap(RoutingMode.init(rawValue:)) else { throw self.failure("The routing mode is missing.") }
                let config = try TunnelConfiguration.make(profile: profile, routing: mode)
                let files = FileManager.default
                let base = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Core", isDirectory: true)
                let cache = files.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Core", isDirectory: true)
                try files.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                try files.createDirectory(at: cache, withIntermediateDirectories: true)
                var privateBase = base
                var protection = URLResourceValues(); protection.isExcludedFromBackup = true
                try privateBase.setResourceValues(protection)
                let snapshot = base.appendingPathComponent("configuration.json")
                if (try? files.destinationOfSymbolicLink(atPath: snapshot.path)) != "/dev/null" {
                    if files.fileExists(atPath: snapshot.path) { try files.removeItem(at: snapshot) }
                    try files.createSymbolicLink(atPath: snapshot.path, withDestinationPath: "/dev/null")
                }
                // Darwin limits Unix socket paths, so keep the core's command socket relative.
                guard files.changeCurrentDirectoryPath(base.path) else { throw self.failure("The VPN working directory is unavailable.") }
                let setup = LibboxSetupOptions()
                setup.basePath = "."; setup.workingPath = cache.path; setup.tempPath = cache.path
                setup.logMaxLines = 0; setup.debug = false; setup.oomKillerEnabled = true
                setup.crashReportSource = "packet-tunnel"; setup.appVersion = "0.1.0"
                var coreError: NSError?
                guard LibboxSetup(setup, &coreError), LibboxCheckConfig(config, &coreError), coreError == nil else { throw self.failure("The VPN configuration could not be loaded.") }
                let platform = BoxPlatform(provider: self)
                self.platform = platform
                guard let server = LibboxNewCommandServer(self, platform, &coreError), coreError == nil else { throw self.failure("The VPN engine could not start.") }
                self.server = server
                try server.start()
                try server.startOrReloadService(config, options: LibboxOverrideOptions())
                self.started = Date(); self.lastSuccess = 0
                self.requiredSuccessAfter = floor(self.started.timeIntervalSince1970)
                let handler = CoreProbe(provider: self)
                let commands = LibboxCommandClientOptions(); commands.addCommand(LibboxCommandOutbounds)
                self.probeHandler = handler
                guard let probe = LibboxNewCommandClient(handler, commands) else { throw self.failure("The VPN connection check could not start.") }
                self.probe = probe
                try probe.connect()
                let timer = DispatchSource.makeTimerSource(queue: self.workQueue)
                timer.schedule(deadline: .now() + 5, repeating: 5)
                timer.setEventHandler { [weak self] in self?.checkFreshness() }
                self.heartbeat = timer; timer.resume()
                completionHandler(nil)
            } catch {
                self.cleanup(); self.setPhase(.error)
                completionHandler(self.failure("Could not start the VPN. Check the profile and VPN permission."))
            }
        }
    }

    func recordHealth(_ timestamp: Int64) {
        workQueue.async { [weak self] in
            guard let self, self.server != nil else { return }
            self.lastSuccess = TimeInterval(timestamp)
            self.checkFreshness()
        }
    }

    func networkChanged(available: Bool) {
        workQueue.async { [weak self] in
            guard let self, let server = self.server else { return }
            self.online = available; self.lastSuccess = 0
            self.requiredSuccessAfter = floor(Date().timeIntervalSince1970)
            server.resetNetwork()
            if self.phase == .connected { self.setPhase(.reconnecting) }
            if available { server.wakeNow(); self.requestProbe() }
        }
    }

    private func checkFreshness() {
        guard server != nil else { return }
        if online && Date().timeIntervalSince(lastProbe) >= 30 { requestProbe() }
        let healthy = online && lastSuccess >= requiredSuccessAfter && lastSuccess > 0 && Date().timeIntervalSince1970 - lastSuccess < 45
        if healthy { setPhase(.connected) }
        else if Date().timeIntervalSince(started) > 8 || phase == .connected { setPhase(.reconnecting) }
    }

    private func requestProbe() {
        lastProbe = Date()
        try? probe?.urlTest("proxy")
    }

    private var phase: TunnelPhase {
        stateLock.lock(); defer { stateLock.unlock() }; return state
    }

    private func setPhase(_ value: TunnelPhase) {
        stateLock.lock(); state = value; stateLock.unlock()
        if value == .reconnecting { reasserting = true }
        else if value == .connected { reasserting = false }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard messageData == Data("status".utf8) else { completionHandler?(nil); return }
        completionHandler?(Data(phase.rawValue.utf8))
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        setPhase(.stopping)
        workQueue.async { self.cleanup(); self.setPhase(.disconnected); completionHandler() }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        workQueue.async { self.server?.pause(); completionHandler() }
    }

    override func wake() {
        workQueue.async {
            self.lastSuccess = 0
            self.requiredSuccessAfter = floor(Date().timeIntervalSince1970)
            self.server?.wakeNow(); self.server?.resetNetwork()
            self.requestProbe()
        }
    }

    private func cleanup() {
        heartbeat?.cancel(); heartbeat = nil
        try? probe?.disconnect(); probe = nil; probeHandler = nil
        try? server?.closeService(); server?.close(); server = nil
        platform?.close(); platform = nil
    }

    func serviceStop() throws { cancelTunnelWithError(nil) }
    func serviceReload() throws { throw failure("Disconnect before changing the profile.") }
    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus { LibboxSystemProxyStatus() }
    func setSystemProxyEnabled(_ enabled: Bool) throws { throw failure("System proxy mode is not enabled.") }
    func triggerNativeCrash() throws { throw failure("Native crash triggering is not enabled.") }
    func writeDebugMessage(_ message: String?) { }
    func connectSSHAgent(_ ret0_: UnsafeMutablePointer<Int32>?) throws { throw failure("SSH agent forwarding is not enabled.") }
    private func failure(_ message: String) -> NSError { NSError(domain: "ChromVoidVPN", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private final class CoreProbe: NSObject, LibboxCommandClientHandlerProtocol {
    private weak var provider: PacketTunnelProvider?
    init(provider: PacketTunnelProvider) { self.provider = provider }
    func writeOutbounds(_ message: LibboxOutboundGroupItemIteratorProtocol?) {
        guard let message else { return }
        while message.hasNext() {
            guard let item = message.next() else { continue }
            if item.tag == "tunnel" { provider?.recordHealth(item.urlTestTime) }
        }
    }
    func connected() { }
    func disconnected(_ message: String?) { provider?.recordHealth(0) }
    func clearLogs() { }
    func setDefaultLogLevel(_ level: Int32) { }
    func writeLogs(_ messageList: LibboxLogIteratorProtocol?) { }
    func writeStatus(_ message: LibboxStatusMessage?) { }
    func writeGroups(_ message: LibboxOutboundGroupIteratorProtocol?) { }
    func initializeClashMode(_ modeList: LibboxStringIteratorProtocol?, currentMode: String?) { }
    func updateClashMode(_ newMode: String?) { }
    func write(_ events: LibboxConnectionEvents?) { }
}
