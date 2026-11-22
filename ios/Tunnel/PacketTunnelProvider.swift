import Foundation
import NetworkExtension
import OSLog
import WayveilCore

// Tunnel state stays on workQueue; phase is protected by stateLock. A managed connection chooses its node by the
// rules of NodeChoice: it starts on the first candidate that comes up and moves a tunnel that keeps reconnecting to
// the next one, without a new tunnel interface; a node the user pinned is the only one it uses.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let workQueue = DispatchQueue(label: "com.chromvoid.vpn.tunnel")
    private let probeQueue = DispatchQueue(label: "com.chromvoid.vpn.health")
    private let switchQueue = DispatchQueue(label: "com.chromvoid.vpn.switch")
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
    private var metrics = TunnelMetrics(totals: ProfileStore.tunnelMetricsTotals)
    private var lastMetricsSample = Date.distantPast
    private var startupTask: Task<Void, Never>?
    private var accessTask: Task<Void, Never>?
    private var startupCompletion: ((Error?) -> Void)?
    private var sessionID = UUID()
    private var accessManager: AccessManager?
    private var accessError: String?
    private var active: ActiveNode?
    private var activeNode: CatalogNode? { active?.node }
    private var activeProfile: ConnectionProfile?
    // The pauses of failed nodes and the failover timing and candidates of a managed connection.
    private var pauses: NodePauses?
    private var failover: NodeFailover?
    private static let directPass = NodeDirectPass()
    private var measurement = NodeMeasurement()
    private var switchTask: Task<Void, Never>?
    // Set while the core starts on another node, or on its full set of transports, beside the running one.
    private var switchID: UUID?
    private var ticketExpiresAt: Int64 = 0
    private var activeRules: RoutingDocument?
    private var activeOverrides = RoutingOverrides.empty

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        setPhase(.connecting)
        workQueue.async { [self] in
            startupCompletion = completionHandler
            sessionID = UUID()
            let session = sessionID
            accessError = nil
            do {
                guard phase != .stopping else { throw CancellationError() }
                if try AccessStore().readAccess() != nil {
                    let manager = AccessManager()
                    accessManager = manager
                    let pauses = NodePauses.stored()
                    self.pauses = pauses
                    failover = NodeFailover(pauses: pauses)
                    let platform = TunnelPlatform(provider: self)
                    self.platform = platform
                    try platform.startMonitoring()
                    Self.directPass.onNetwork(platform.networkSignature)
                    startupTask = Task { [weak self] in
                        do {
                            let found = try await awaitManagedConnection(connection: { try await manager.candidates().startable() })
                            try Task.checkCancellation()
                            self?.workQueue.async { [weak self] in
                                guard let self, self.sessionID == session, self.startupCompletion != nil else { return }
                                self.prepareManagedStart(found, session: session)
                            }
                        } catch {
                            self?.workQueue.async { [weak self] in
                                guard let self, self.sessionID == session, self.startupCompletion != nil else { return }
                                self.startFailed(error)
                            }
                        }
                    }
                } else {
                    guard let profile = try ProfileStore.read() else { throw failure("A connection profile is required.") }
                    try startConnection(profile: profile)
                }
            } catch { startFailed(error) }
        }
    }

    private func prepareManagedStart(_ found: NodeCandidates, session: UUID) {
        guard phase != .stopping, let pauses else { startFailed(CancellationError()); return }
        let generation = networkGeneration
        startupTask = Task { [weak self] in
            // Measure once per physical network, before the first core configures its tunnel.
            var measurement = NodeMeasurement()
            let skipDirect = Self.directPass.skipped(now: Date().timeIntervalSince1970)
            if !found.pinned, found.nodes.count > 1, !skipDirect {
                measurement = await NodeChoice.measure(found.nodes, resolve: NodeProbe.resolve, dial: NodeProbe.dial)
            }
            guard !Task.isCancelled else { return }
            self?.workQueue.async { [weak self] in
                guard let self, self.sessionID == session, self.startupCompletion != nil else { return }
                guard self.networkGeneration == generation else {
                    self.prepareManagedStart(found, session: session)
                    return
                }
                do {
                    guard self.phase != .stopping else { throw CancellationError() }
                    let plan = NodeChoice.startPlan(found, pauses: pauses, now: Date().timeIntervalSince1970,
                                                    measurement: measurement, skipDirect: skipDirect)
                    self.measurement = measurement
                    try self.startManaged(plan, found: found)
                } catch { self.startFailed(error) }
            }
        }
    }

    private func startConnection(profile: ConnectionProfile) throws {
        let base = try RoutingDocument.bundled()
        let overrides = (try? RoutingOverrideStore.read()) ?? .empty
        let platform = TunnelPlatform(provider: self)
        self.platform = platform
        guard phase != .stopping else { throw CancellationError() }
        let config = try configuration(profile, node: nil, base: base, overrides: overrides)
        try platform.startMonitoring()
        var coreError: NSError?
        guard let engine = MobileStart(config, platform, &coreError), coreError == nil else { throw failure("The VPN engine could not start.") }
        try begin(engine, profile: profile, node: nil, base: base, overrides: overrides)
    }

    /**
     Starts the core on the first node of the plan that comes up. Without a pin a node that fails is paused and the
     next one is tried at once, so the error shows only when none came up; the direct pass pauses only the latency
     winner. A node chosen in the direct pass keeps its direct transports until the next normal core restart.
     */
    private func startManaged(_ plan: NodePlan, found: NodeCandidates) throws {
        let base = try RoutingDocument.bundled()
        let overrides = (try? RoutingOverrideStore.read()) ?? .empty
        guard let platform, let failover else { throw CancellationError() }
        failover.catalog(now: uptime, found: found)
        // The cores start one after another on this queue, which no catalog reaches before the tunnel runs.
        NodeStarts<MobileEngine>(plan, failover: failover, pausing: !found.pinned,
            wallNow: { Date().timeIntervalSince1970 }, network: { platform.networkAvailable },
            allowed: { [self] in startAllowed($0, found: found, leaving: false) },
            launch: { [self] attempt, ready, done in
                guard phase != .stopping else { startFailed(CancellationError()); return }
                let node = attempt.node
                let config = coreConfiguration(node, base: base, overrides: overrides)
                guard ready() else { return }
                done(startCore(config, node: node, platform: platform))
            },
            take: { [self] attempt, engine in
                let node = attempt.node
                do {
                    guard let profile = node.profile else { throw failure("The VPN engine could not start.") }
                    try begin(engine, profile: profile, node: node,
                              full: attempt.full, base: base, overrides: overrides)
                    connected(engine, attempt: attempt, plan: plan, found: found)
                    if !found.pinned, node.id != found.saved { saveCurrent(node.id) }
                } catch {
                    try? engine.close()
                    logPlan(plan, found: found)
                    startFailed(error)
                }
            },
            stop: { try? $0.close() },
            end: { [self] in
                logPlan(plan, found: found)
                startFailed(failure("The VPN engine could not start."))
            }).run()
    }

    // The configuration of a core for node, nil when none loads; it reads the tunnel's state, so it is built on workQueue.
    private func coreConfiguration(_ node: CatalogNode, base: RoutingDocument, overrides: RoutingOverrides) -> String? {
        node.profile.flatMap { try? configuration($0, node: node, base: base, overrides: overrides) }
    }

    // A core for node started from config, or nil when it does not come up; it may run off workQueue.
    private func startCore(_ config: String?, node: CatalogNode, platform: TunnelPlatform) -> MobileEngine? {
        guard let config else { return nil }
        var coreError: NSError?
        let started = MobileStart(config, platform, &coreError)
        guard let started, coreError == nil else {
            try? started?.close()
            logger.error("Node \(node.id, privacy: .public) did not come up")
            return nil
        }
        return started
    }

    private func configuration(_ profile: ConnectionProfile, node: CatalogNode?, base: RoutingDocument,
                               overrides: RoutingOverrides) throws -> String {
        let config = try TunnelConfiguration.make(profile: profile, base: base, overrides: overrides,
            endpoints: node?.endpoints, preferredEndpoint: preferredEndpoint(node))
        var coreError: NSError?
        guard MobileValidate(config, &coreError), coreError == nil else { throw failure("The VPN configuration could not be loaded.") }
        return config
    }

    private func begin(_ engine: MobileEngine, profile: ConnectionProfile, node: CatalogNode?, full: CatalogNode? = nil,
                       base: RoutingDocument, overrides: RoutingOverrides) throws {
        guard let platform else { try? engine.close(); throw CancellationError() }
        self.engine = engine
        rememberEndpoint(engine, node: node, networkKey: platform.networkKey())
        metrics = TunnelMetrics(totals: ProfileStore.tunnelMetricsTotals)
        lastMetricsSample = .distantPast
        guard phase != .stopping else { throw CancellationError() }
        try platform.configureTunnel()
        guard phase != .stopping else { throw CancellationError() }
        try platform.startForwarding(configuration: engine.hevConfig())
        active = node.map { ActiveNode($0, full: full) }
        activeProfile = profile
        ticketExpiresAt = node?.expiresAt ?? 0
        activeRules = base
        activeOverrides = overrides
        started = Date(); lastSuccess = .distantPast; lastProbe = .distantPast
        online = true; awake = true; needsReconnect = false
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.checkFreshness() }
        heartbeat = timer; timer.resume()
        requestProbe()
        if node != nil { monitorAccess() }
        finishStartup(nil)
    }

    private func finishStartup(_ error: Error?) {
        let completion = startupCompletion
        startupCompletion = nil
        startupTask = nil
        completion?(error)
    }

    private func startFailed(_ error: Error) {
        let cancelled = phase == .stopping || error is CancellationError
        if let failure = error as? AccessFailure { accessError = failure.code }
        cleanup()
        if !cancelled { setPhase(.error) }
        finishStartup(failure("Could not start the VPN. Check the profile and VPN permission."))
    }

    // Renews the node's ticket from the catalog every 30 s and keeps the candidates a failover moves to.
    private func monitorAccess() {
        guard let manager = accessManager else { return }
        let session = sessionID
        accessTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    let found = try await manager.candidates()
                    try Task.checkCancellation()
                    self?.workQueue.async { [weak self] in
                        guard let self, self.sessionID == session, self.engine != nil, self.phase != .stopping else { return }
                        // A fresh catalog without a ready node leaves the tunnel as it is, as a node still activating.
                        self.accessError = found.nodes.isEmpty ? "activating" : nil
                        self.updateManagedConnection(found)
                    }
                } catch is CancellationError { return }
                catch let error as AccessFailure {
                    if Task.isCancelled { return }
                    self?.workQueue.async { [weak self] in
                        guard let self, self.sessionID == session, self.engine != nil, self.phase != .stopping else { return }
                        self.accessError = error.code
                        self.failover?.catalog(now: self.uptime, found: nil)
                        if error.terminal {
                            self.cleanup()
                            self.setPhase(.error)
                            self.cancelTunnelWithError(error)
                        }
                    }
                    if error.terminal { return }
                } catch {
                    if Task.isCancelled { return }
                }
            }
        }
    }

    /**
     Applies the catalog to the tunnel. It restarts the core when the node's configuration changes or its ticket is
     due for renewal, and moves it to the pinned node, or to the first candidate once a fresh catalog no longer offers
     the node in use. The new core starts beside the running one, which keeps the tunnel until the new core takes it;
     without a pin a node that does not come up is paused and the next candidate starts at once. A node started on its
     direct transports keeps them until its core restarts on its full set.
     */
    private func updateManagedConnection(_ found: NodeCandidates) {
        failover?.catalog(now: uptime, found: found)
        // A core starting beside the running one owns the tunnel until it ends; the next catalog applies then.
        guard switchID == nil, let active, let current = activeProfile, let pauses,
              let node = target(found, current: active.node.id), let replacement = node.profile else { return }
        let renewed = active.renewed(node)
        let changed = current.server != replacement.server || current.port != replacement.port ||
            current.serverName != replacement.serverName || current.obfsPassword != replacement.obfsPassword ||
            current.certificate != replacement.certificate || active.node.id != node.id ||
            endpointsWithoutPasswords(active.node.endpoints) != endpointsWithoutPasswords(renewed.node.endpoints)
        guard changed || shouldRenewTicket(ticketExpiresAt: ticketExpiresAt, expiresAt: node.expiresAt,
                                           now: Int64(Date().timeIntervalSince1970)) else {
            self.active = renewed
            return
        }
        let next = NodeChoice.failoverPlan(found, current: node.id, pauses: pauses, now: Date().timeIntervalSince1970)
        startBeside(NodePlan(nodes: [node] + next.nodes), pausing: !found.pinned, failover: false)
    }

    // The node the tunnel belongs on: the node in use while the catalog offers it, otherwise the first candidate (the
    // pinned node, or the first ready one while the pinned node is missing, as before). A node missing from a saved
    // catalog, whose tickets may have run out, stays until a fresh catalog tells.
    private func target(_ found: NodeCandidates, current: String) -> CatalogNode? {
        if found.pinned { return found.nodes.first }
        if let node = found.nodes.first(where: { $0.id == current }) { return node }
        guard !found.cached, let pauses else { return nil }
        return pauses.order(found.nodes, now: Date().timeIntervalSince1970).first
    }

    /**
     Times the tunnel on its node and, without a pin, moves a tunnel that has kept reconnecting for 45 s, or 3 minutes
     with a saved catalog, to the next candidate. The node it leaves and nodes that fail in the full pass are paused.
     */
    private func trackFailover() {
        guard let failover, let active, let pauses else { return }
        failover.track(now: uptime, node: active.node.id, connected: phase == .connected,
                       reconnecting: phase == .reconnecting, network: online && awake)
        let now = uptime
        guard switchID == nil, online, awake, let found = failover.found, !found.pinned, failover.due(now: now) else { return }
        let wallNow = Date().timeIntervalSince1970
        failover.pause(active.node.id, wallNow: wallNow)
        let plan = NodeChoice.failoverPlan(found, current: active.node.id, pauses: pauses, now: wallNow,
            measurement: measurement, skipDirect: Self.directPass.skipped(now: wallNow))
        guard !plan.nodes.isEmpty else { failover.switched(now: now); return }
        failover.beginSwitch()
        logger.info("Node \(active.node.id, privacy: .public) kept reconnecting, trying \(plan.nodes.map(\.id).joined(separator: ","), privacy: .public)")
        startBeside(plan, pausing: true, failover: true)
    }

    /**
     Starts a core for the first attempt that comes up beside the running one, which keeps the tunnel until the new
     core takes it without a new tunnel interface; when none is taken, the tunnel stays on its core. `pausing` pauses
     the nodes that do not come up, and a failover gives the node in use the full threshold once its attempts end.
     */
    private func startBeside(_ plan: NodePlan, pausing: Bool, failover isFailover: Bool) {
        guard switchID == nil, engine != nil, phase != .stopping else { return }
        let id = UUID()
        switchID = id
        if !plan.directSkipped {
            let previous = measurement
            let generation = networkGeneration
            switchTask = Task { [weak self] in
                let resolved = await NodeChoice.resolveAddresses(plan.nodes, measurement: previous, resolve: NodeProbe.resolve)
                guard !Task.isCancelled else { return }
                self?.workQueue.async { [weak self] in
                    guard let self, self.switchID == id else { return }
                    guard self.networkGeneration == generation else {
                        if let found = self.failover?.found { self.logPlan(plan, found: found, selecting: isFailover) }
                        self.endSwitch(id, failover: isFailover, generation: generation)
                        return
                    }
                    self.measurement = resolved
                    var prepared = plan
                    prepared.addresses = resolved.addresses
                    self.launchBeside(prepared, id: id, pausing: pausing, failover: isFailover)
                }
            }
        } else { launchBeside(plan, id: id, pausing: pausing, failover: isFailover) }
    }

    private func launchBeside(_ plan: NodePlan, id: UUID, pausing: Bool, failover isFailover: Bool) {
        guard let platform, let base = activeRules, let failover, let found = failover.found else {
            endSwitch(id, failover: isFailover)
            return
        }
        let overrides = activeOverrides
        let generation = networkGeneration
        NodeStarts<MobileEngine>(plan, failover: failover, pausing: pausing,
            wallNow: { Date().timeIntervalSince1970 }, network: { platform.networkAvailable },
            allowed: { [weak self] attempt in
                guard let self, self.networkGeneration == generation else { return false }
                return self.startAllowed(attempt, found: found, leaving: isFailover)
            },
            launch: { [weak self] attempt, ready, done in
                guard let self else { return }
                let node = attempt.node
                let config = self.coreConfiguration(node, base: base, overrides: overrides)
                self.switchQueue.async { [weak self] in
                    guard let self else { return }
                    // The switch queue and the keychain read may have waited while the tunnel recovered or a pin changed.
                    guard self.workQueue.sync(execute: {
                        guard self.switchID == id, self.engine != nil else { return false }
                        return ready()
                    }) else { return }
                    let core = self.startCore(config, node: node, platform: platform)
                    self.workQueue.async { [weak self] in
                        // Attempts the tunnel stopped, or that it left for another operation, leave their core unused.
                        guard let self, self.switchID == id, self.engine != nil, self.phase != .stopping else {
                            try? core?.close()
                            return
                        }
                        done(core)
                    }
                }
            },
            take: { [weak self] attempt, core in
                guard let self else { try? core.close(); return }
                self.take(core, attempt: attempt, plan: plan, id: id, failover: isFailover)
            },
            stop: { try? $0.close() },
            end: { [weak self] in
                guard let self, self.switchID == id else { return }
                self.logPlan(plan, found: found, selecting: isFailover)
                self.endSwitch(id, failover: isFailover, generation: generation)
            }).run()
    }

    // The tunnel moves to the new core of node without a new tunnel interface.
    private func take(_ replacement: MobileEngine, attempt: NodeAttempt, plan: NodePlan, id: UUID, failover isFailover: Bool) {
        let node = attempt.node
        guard let platform, let profile = node.profile else {
            try? replacement.close()
            endSwitch(id, failover: isFailover)
            return
        }
        let previous = activeNode?.id
        setPhase(.reconnecting)
        networkGeneration += 1
        platform.stopForwarding()
        closeEngine()
        do { try use(replacement, node: node, full: attempt.full, profile: profile) }
        catch {
            cleanup()
            setPhase(.error)
            cancelTunnelWithError(failure("Could not refresh the VPN connection."))
            return
        }
        if let found = failover?.found {
            connected(replacement, attempt: attempt, plan: plan, found: found, selecting: isFailover)
        }
        endSwitch(id, failover: isFailover)
        if node.id != previous {
            logger.info("Node \(previous ?? "", privacy: .public) moved to \(node.id, privacy: .public)")
            if failover?.found?.pinned == false { saveCurrent(node.id) }
        }
    }

    // A finished round gets a new threshold; a network interruption resumes the same round immediately.
    private func endSwitch(_ id: UUID, failover: Bool, generation: Int? = nil) {
        guard switchID == id else { return }
        let retrying: Bool
        if failover, let generation, generation != networkGeneration || !online || !awake,
           (try? AccessStore().readAccess())?.pinned == false {
            retrying = phase == .reconnecting
        } else { retrying = false }
        switchID = nil
        switchTask?.cancel(); switchTask = nil
        if failover { self.failover?.switched(now: uptime, retrying: retrying) }
        if retrying {
            measurement = NodeMeasurement()
            trackFailover()
        } else if engine != nil, phase != .stopping { requestProbe() }
    }

    private func closeEngine() {
        if let engine {
            metrics.recordTraffic(downloadBytes: engine.proxyRxBytes(), uploadBytes: engine.proxyTxBytes())
            ProfileStore.tunnelMetricsTotals = metrics.totals
            try? engine.close()
        }
        engine = nil
        probeInFlight = false
        metrics.recordTraffic(downloadBytes: 0, uploadBytes: 0)
    }

    // The tunnel runs on a new core; a direct-pass core keeps its full set for the next normal restart.
    private func use(_ replacement: MobileEngine, node: CatalogNode, full: CatalogNode?, profile: ConnectionProfile) throws {
        guard let platform else { try? replacement.close(); throw CancellationError() }
        engine = replacement
        rememberEndpoint(replacement, node: node, networkKey: platform.networkKey())
        try platform.startForwarding(configuration: replacement.hevConfig())
        active = ActiveNode(node, full: full)
        activeProfile = profile
        ticketExpiresAt = node.expiresAt
        lastSuccess = .distantPast
        lastProbe = .distantPast
        needsReconnect = false
        requestProbe()
    }

    // Records the node in use as the current one without pinning it, so that the next connection starts there.
    private func saveCurrent(_ id: String) {
        guard let manager = accessManager else { return }
        Task { try? await manager.saveCurrent(id) }
    }

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func startAllowed(_ attempt: NodeAttempt, found: NodeCandidates, leaving: Bool) -> Bool {
        guard let access = try? AccessStore().readAccess(), phase != .stopping else { return false }
        return NodeChoice.startAllowed(attempt, found: found, pinnedTo: access.pinned ? access.node : nil,
            leaving: leaving, reconnecting: phase == .reconnecting && online && awake)
    }

    private func connected(_ core: MobileEngine, attempt: NodeAttempt, plan: NodePlan, found: NodeCandidates, selecting: Bool = true) {
        logPlan(plan, found: found, attempt: attempt, selecting: selecting, endpoint: core.activeEndpoint())
        let wallNow = Date().timeIntervalSince1970
        let addresses = wallNow - measurement.resolvedAt < NodeChoice.directMemory ? measurement.addresses : [:]
        let direct = Self.directPass.connected(attempt, in: plan, endpoint: core.activeEndpoint(),
                                               addresses: addresses, now: wallNow)
        // A full-set restart (including a ticket renewal) can choose a direct endpoint whose name needs resolving.
        guard !direct, Self.directPass.skipped(now: wallNow) else { return }
        let previous = measurement
        let generation = networkGeneration
        let session = sessionID
        let coreID = ObjectIdentifier(core)
        Task { [weak self] in
            let resolved = await NodeChoice.resolveAddresses([attempt.node], measurement: previous, resolve: NodeProbe.resolve)
            self?.workQueue.async { [weak self] in
                guard let self, self.sessionID == session, self.networkGeneration == generation,
                      let engine = self.engine, ObjectIdentifier(engine) == coreID else { return }
                self.measurement = resolved
                if NodeChoice.onDirect(attempt.node, endpoint: engine.activeEndpoint(), addresses: resolved.addresses) {
                    Self.directPass.reset()
                }
            }
        }
    }

    private func logPlan(_ plan: NodePlan, found: NodeCandidates, attempt: NodeAttempt? = nil, selecting: Bool = true,
                         endpoint: String = "") {
        let latencies = measurement.latencies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)ms" }.joined(separator: ",")
        let pass = attempt.map { $0.direct ? "direct" : "full" } ?? "none"
        let skipped = selecting ? " direct_skipped=\(plan.directSkipped)" : ""
        logger.info("Node plan \(found.pinned ? "pinned" : "auto", privacy: .public) saved=\(found.saved, privacy: .public) order=\(plan.nodes.map(\.id).joined(separator: ","), privacy: .public) won=\(plan.won, privacy: .public) latencies=\(latencies, privacy: .public) cached=\(found.cached, privacy: .public) pass=\(pass, privacy: .public)\(skipped, privacy: .public) selected=\(attempt?.node.id ?? "", privacy: .public) endpoint=\(endpoint, privacy: .public)")
    }

    private func endpointsWithoutPasswords(_ endpoints: [JSONValue]) -> [JSONValue] {
        endpoints.map { endpoint in
            guard case .object(var values) = endpoint else { return endpoint }
            values.removeValue(forKey: "password")
            return .object(values)
        }
    }

    private func preferredEndpoint(_ node: CatalogNode?) -> String? {
        guard let node, let platform else { return nil }
        return UserDefaults.standard.string(forKey: "\(node.id)/\(platform.networkKey())")
    }

    private func rememberEndpoint(_ engine: MobileEngine, node: CatalogNode?, networkKey: String) {
        guard let node else { return }
        let endpoint = engine.activeEndpoint()
        guard !endpoint.isEmpty else { return }
        UserDefaults.standard.set(endpoint, forKey: "\(node.id)/\(networkKey)")
        let addresses = Date().timeIntervalSince1970 - measurement.resolvedAt < NodeChoice.directMemory ? measurement.addresses : [:]
        if NodeChoice.onDirect(node, endpoint: endpoint, addresses: addresses) { Self.directPass.reset() }
    }

    func networkChanged(available: Bool) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.networkGeneration += 1
            Self.directPass.reset()
            if let platform = self.platform { Self.directPass.onNetwork(platform.networkSignature) }
            self.measurement = NodeMeasurement()
            self.online = available
            guard self.engine != nil else { return }
            self.lastSuccess = .distantPast
            self.needsReconnect = true
            if self.phase == .connected { self.setPhase(.reconnecting) }
            if self.failover?.attempting == true { self.trackFailover() }
            if available { self.requestProbe() }
            self.trackFailover()
        }
    }

    func forwardingStopped(result: Int32, generation: UUID) {
        workQueue.async { [weak self] in
            guard let self, self.engine != nil, self.phase != .stopping,
                  self.platform?.forwardingGeneration == generation else { return }
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
        trackFailover()
    }

    private func requestProbe() {
        guard let engine, let platform, online, awake, !probeInFlight, switchID == nil, phase != .stopping else { return }
        // A node started on its direct transports reconnects on its full set: its core restarts beside the running one.
        if needsReconnect, let active, active.narrowed {
            needsReconnect = false
            lastProbe = Date()
            startBeside(NodePlan(nodes: [active.whole]), pausing: false, failover: false)
            return
        }
        probeInFlight = true
        lastProbe = Date()
        let generation = networkGeneration
        let networkKey = platform.networkKey()
        let reconnect = needsReconnect
        needsReconnect = false
        probeQueue.async { [weak self, engine] in
            let healthy: Bool
            var reconnected = false
            var latency: Double?
            var downloadBytes: Int64 = 0
            var uploadBytes: Int64 = 0
            do {
                if reconnect { try engine.reconnect(); reconnected = true }
                try engine.check()
                healthy = true
                var milliseconds: Int64 = 0
                if (try? engine.ping(&milliseconds)) != nil { latency = Double(milliseconds) }
                downloadBytes = engine.proxyRxBytes()
                uploadBytes = engine.proxyTxBytes()
            } catch { healthy = false }
            let sampledAt = Date()
            self?.workQueue.async { [weak self, engine] in
                guard let self, self.engine === engine, self.phase != .stopping else { return }
                self.probeInFlight = false
                if healthy || reconnected { self.rememberEndpoint(engine, node: self.activeNode, networkKey: networkKey) }
                if healthy {
                    if let latency { self.metrics.recordLatency(latency) }
                    self.metrics.recordTraffic(downloadBytes: downloadBytes, uploadBytes: uploadBytes, at: sampledAt)
                    self.lastMetricsSample = sampledAt
                    ProfileStore.tunnelMetricsTotals = self.metrics.totals
                }
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
        if messageData == Data("status".utf8) {
            completionHandler?(Data(phase.rawValue.utf8))
        } else if messageData == Data("access_error".utf8) {
            workQueue.async { [self] in completionHandler?(Data((accessError ?? "").utf8)) }
        } else if messageData == Data("metrics".utf8) {
            workQueue.async { [self] in
                guard let engine else { completionHandler?(nil); return }
                let now = Date()
                let snapshot = metrics.snapshot(downloadMedianBps: Double(engine.downloadMedianBps()),
                    downloadPeakBps: Double(engine.downloadPeakBps()), engineDownloadBytes: engine.proxyRxBytes(),
                    engineUploadBytes: engine.proxyTxBytes(), at: now)
                completionHandler?(try? JSONEncoder().encode(snapshot))
                if now.timeIntervalSince(lastMetricsSample) > 10 && now.timeIntervalSince(lastProbe) >= 10 {
                    requestProbe()
                }
            }
        } else { completionHandler?(nil) }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        setPhase(.stopping)
        workQueue.async {
            self.cleanup()
            self.finishStartup(self.failure("The VPN connection was cancelled."))
            self.setPhase(.disconnected)
            completionHandler()
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        workQueue.async {
            self.awake = false
            self.lastSuccess = .distantPast
            self.trackFailover()
            completionHandler()
        }
    }

    override func wake() {
        workQueue.async {
            self.awake = true
            self.networkGeneration += 1
            self.lastSuccess = .distantPast
            self.needsReconnect = true
            if self.failover?.attempting == true { self.trackFailover() }
            self.requestProbe()
        }
    }

    private func logHealth() {
        let traffic = platform?.traffic() ?? (0, 0, 0, 0)
        logger.info("Hysteria/HEV phase=\(self.phase.rawValue, privacy: .public) core=\(MobileVersion(), privacy: .public) tx_packets=\(traffic.0, privacy: .public) tx_bytes=\(traffic.1, privacy: .public) rx_packets=\(traffic.2, privacy: .public) rx_bytes=\(traffic.3, privacy: .public)")
    }

    private func cleanup() {
        startupTask?.cancel(); startupTask = nil
        accessTask?.cancel(); accessTask = nil
        accessManager = nil
        active = nil
        failover = nil
        pauses = nil
        switchID = nil
        switchTask?.cancel(); switchTask = nil
        activeProfile = nil
        activeRules = nil
        heartbeat?.cancel(); heartbeat = nil
        logHealth()
        platform?.stopForwarding()
        if let engine {
            metrics.recordTraffic(downloadBytes: engine.proxyRxBytes(), uploadBytes: engine.proxyTxBytes())
            ProfileStore.tunnelMetricsTotals = metrics.totals
            try? engine.close()
        }
        engine = nil
        platform?.close(); platform = nil
        probeInFlight = false
        needsReconnect = false
        lastSuccess = .distantPast
        reasserting = false
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "Wayveil", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
