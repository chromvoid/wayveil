import Foundation
import NetworkExtension
import OSLog
import WayveilCore

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let workQueue = DispatchQueue(label: "com.chromvoid.vpn.tunnel")
    private let probeQueue = DispatchQueue(label: "com.chromvoid.vpn.health")
    private let stateLock = NSLock()
    private let logger = Logger(subsystem: "com.chromvoid.vpn", category: "Tunnel")
    private var state = TunnelPhase.disconnected
    private var engine: MobileEngine?
    private var platform: TunnelPlatform?
    private var heartbeat: DispatchSourceTimer?
    private var started = Date()
    private var lastSuccess = Date.distantPast
    private var lastProbe = Date.distantPast
    private var networkGeneration = 0
    private var probeInFlight = false
    private var needsReconnect = false
    private var online = true
    private var awake = true

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        setPhase(.connecting)
        workQueue.async { [self] in
            do {
                guard let profile = try ProfileStore.read() else { throw failure("A connection profile is required.") }
                let rawMode = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["routing"] as? String
                guard let mode = rawMode.flatMap(RoutingMode.init(rawValue:)) else { throw failure("The routing mode is missing.") }
                let config = try TunnelConfiguration.make(profile: profile, routing: mode)
                var coreError: NSError?
                guard MobileValidate(config, &coreError), coreError == nil else { throw failure("The VPN configuration could not be loaded.") }
                let platform = TunnelPlatform(provider: self)
                self.platform = platform
                try platform.startMonitoring()
                guard let engine = MobileStart(config, platform, &coreError), coreError == nil else { throw failure("The VPN engine could not start.") }
                self.engine = engine
                guard phase != .stopping else { throw failure("The VPN connection was cancelled.") }
                try platform.configureTunnel()
                guard phase != .stopping else { throw failure("The VPN connection was cancelled.") }
                try platform.startForwarding(configuration: engine.hevConfig())
                started = Date(); lastSuccess = .distantPast; lastProbe = .distantPast
                online = true; awake = true; needsReconnect = false
                let timer = DispatchSource.makeTimerSource(queue: workQueue)
                timer.schedule(deadline: .now() + 5, repeating: 5)
                timer.setEventHandler { [weak self] in self?.checkFreshness() }
                heartbeat = timer; timer.resume()
                requestProbe()
                completionHandler(nil)
            } catch {
                let cancelled = phase == .stopping
                cleanup()
                if !cancelled { setPhase(.error) }
                completionHandler(failure("Could not start the VPN. Check the profile and VPN permission."))
            }
        }
    }

    func networkChanged(available: Bool) {
        workQueue.async { [weak self] in
            guard let self, self.engine != nil else { return }
            self.online = available
            self.networkGeneration += 1
            self.lastSuccess = .distantPast
            self.needsReconnect = true
            if self.phase == .connected { self.setPhase(.reconnecting) }
            if available { self.requestProbe() }
        }
    }

    func forwardingStopped(result: Int32) {
        workQueue.async { [weak self] in
            guard let self, self.engine != nil, self.phase != .stopping else { return }
            self.logger.error("HEV packet forwarding stopped with code \(result, privacy: .public)")
            self.cleanup()
            self.setPhase(.error)
            self.cancelTunnelWithError(self.failure("VPN packet forwarding stopped."))
        }
    }

    private func checkFreshness() {
        guard engine != nil, phase != .stopping else { return }
        let interval = Date().timeIntervalSince(lastProbe)
        if online && awake && interval >= (needsReconnect ? 5 : 30) { requestProbe() }
        let healthy = online && awake && Date().timeIntervalSince(lastSuccess) < 45
        if healthy { setPhase(.connected) }
        else if Date().timeIntervalSince(started) > 8 || phase == .connected { setPhase(.reconnecting) }
    }

    private func requestProbe() {
        guard let engine, online, awake, !probeInFlight, phase != .stopping else { return }
        probeInFlight = true
        lastProbe = Date()
        let generation = networkGeneration
        let reconnect = needsReconnect
        needsReconnect = false
        probeQueue.async { [weak self, engine] in
            let healthy: Bool
            do {
                if reconnect { try engine.reconnect() }
                try engine.check()
                healthy = true
            } catch { healthy = false }
            self?.workQueue.async { [weak self, engine] in
                guard let self, self.engine === engine, self.phase != .stopping else { return }
                self.probeInFlight = false
                guard generation == self.networkGeneration else {
                    self.requestProbe()
                    return
                }
                self.lastSuccess = healthy ? Date() : .distantPast
                if !healthy { self.needsReconnect = true }
                self.checkFreshness()
                self.logHealth()
            }
        }
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
        workQueue.async {
            self.awake = false
            self.lastSuccess = .distantPast
            completionHandler()
        }
    }

    override func wake() {
        workQueue.async {
            self.awake = true
            self.networkGeneration += 1
            self.lastSuccess = .distantPast
            self.needsReconnect = true
            self.requestProbe()
        }
    }

    private func logHealth() {
        let traffic = platform?.traffic() ?? (0, 0, 0, 0)
        logger.info("Hysteria/HEV phase=\(self.phase.rawValue, privacy: .public) core=\(MobileVersion(), privacy: .public) tx_packets=\(traffic.0, privacy: .public) tx_bytes=\(traffic.1, privacy: .public) rx_packets=\(traffic.2, privacy: .public) rx_bytes=\(traffic.3, privacy: .public)")
    }

    private func cleanup() {
        heartbeat?.cancel(); heartbeat = nil
        logHealth()
        platform?.stopForwarding()
        try? engine?.close(); engine = nil
        platform?.close(); platform = nil
        probeInFlight = false
        needsReconnect = false
        lastSuccess = .distantPast
        reasserting = false
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "ChromVoidVPN", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
