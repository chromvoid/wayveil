import Darwin
import Foundation

/*
 * How a managed connection chooses its node and leaves one that fails, after linux/internal/nodechoice, which the
 * Linux gateway and the desktop service share: the order of the candidates, the pauses of failed nodes, the failover
 * thresholds and the comparison of latencies. The tunnel extension only calls these rules.
 */

/// The user's choice: the client chooses the node itself (`auto`), or uses only the node the user chose (`pinned`).
enum NodeSelection: String, Equatable, Sendable {
    case auto, pinned

    init(_ access: DeviceAccess?) { self = access?.pinned == true ? .pinned : .auto }
}

enum NodeChoice {
    /// A tunnel that keeps reconnecting this long moves to another node; the longer threshold applies while the
    /// controller does not answer either.
    static let failoverAfter: TimeInterval = 45
    static let failoverOfflineAfter: TimeInterval = 3 * 60
    /// A measurement takes at most this long and times a TCP connection to `latencyPort` of the node's server.
    static let latencyTimeout: TimeInterval = 2
    static let latencyPort = 443
    static let pause: TimeInterval = 10 * 60
    static let pauseMax: TimeInterval = 6 * 60 * 60
    static let healthyReset: TimeInterval = 10 * 60
    static let directMemory: TimeInterval = 30 * 60
    // A node is notably faster than another when its latency is lower by at least fasterShare percent and fasterBy ms.
    private static let fasterShare = 40
    private static let fasterBy = 50

    /// A latency in milliseconds lower than `current` by at least 40% and at least 50 ms.
    static func notablyFaster(_ latency: Int, than current: Int) -> Bool {
        let gain = current - latency
        return gain >= fasterBy && gain * 100 >= current * fasterShare
    }

    /**
     Puts first, among the nodes without a pause, the fastest one if it is notably faster than the saved node, and the
     saved node otherwise; without the saved node the first one stands for it. A node of unknown latency, or one that
     `eligible` rejects, neither wins nor loses. The nodes come ordered by `NodePauses.order`, and the rest keep their
     order. It reports whether a node won by its latency.
     */
    static func preferFaster(_ nodes: [CatalogNode], saved: String, latencies: [String: Int], pauses: NodePauses,
                             now: TimeInterval, eligible: (CatalogNode) -> Bool) -> (nodes: [CatalogNode], won: Bool) {
        let open = nodes.prefix { !pauses.paused($0.id, now: now) }
        guard !open.isEmpty else { return (nodes, false) }
        let standIn = open.firstIndex { $0.id == saved } ?? 0
        var first = standIn
        if let current = latencies[open[standIn].id] {
            var best = current
            for (index, node) in open.enumerated() {
                if let latency = latencies[node.id], latency < best, notablyFaster(latency, than: current), eligible(node) {
                    first = index
                    best = latency
                }
            }
        }
        var ordered = nodes
        ordered.insert(ordered.remove(at: first), at: 0)
        return (ordered, first != standIn)
    }

    /**
     The start of a connection: only the pinned node when there is a pin, otherwise the candidates with the paused ones
     last and, first, a node notably faster than the saved one. Both passes keep that order.
     */
    static func startPlan(_ found: NodeCandidates, pauses: NodePauses, now: TimeInterval,
                          measurement: NodeMeasurement = NodeMeasurement(), skipDirect: Bool = false) -> NodePlan {
        guard !found.pinned else { return NodePlan(nodes: found.nodes) }
        let ordered = pauses.order(found.nodes, now: now)
        guard !skipDirect, found.nodes.count > 1 else { return NodePlan(nodes: ordered) }
        let direct = { (node: CatalogNode) in directNode(node, addresses: measurement.addresses) }
        let (nodes, won) = preferFaster(ordered, saved: found.saved, latencies: measurement.latencies, pauses: pauses,
                                        now: now) { direct($0) != nil }
        return NodePlan(nodes: nodes, won: won, directSkipped: false, addresses: measurement.addresses)
    }

    /// The nodes a tunnel that keeps reconnecting on `current` moves to, in order; none when the user pinned a node.
    static func failoverPlan(_ found: NodeCandidates, current: String, pauses: NodePauses, now: TimeInterval,
                             measurement: NodeMeasurement = NodeMeasurement(), skipDirect: Bool = false) -> NodePlan {
        NodePlan(nodes: found.pinned ? [] : pauses.order(found.nodes.filter { $0.id != current }, now: now),
                 directSkipped: skipDirect, addresses: measurement.addresses)
    }

    /**
     Narrows a node to its direct transports: the endpoints whose server is the node's measured server, by name or by
     address, apart from CDN endpoints; `addresses` holds what names resolved to. A latency measured to the node's
     server says nothing about a tunnel through another host, so the direct pass runs on these alone.
     A node without endpoints runs on its profile, which is direct. Nil for a node without direct transports.
     */
    static func directNode(_ node: CatalogNode, addresses: [String: Set<String>]) -> CatalogNode? {
        guard let server = node.profile?.server else { return nil }
        guard !node.endpoints.isEmpty else { return node }
        func of(_ host: String) -> Set<String> { literalAddress(host).map { [$0] } ?? addresses[host] ?? [] }
        let own = of(server)
        var direct = node
        direct.endpoints = node.endpoints.filter { endpoint in
            guard case .object(let fields) = endpoint, case .string(let host)? = fields["server"], !host.isEmpty else { return false }
            if case .string("vless_xhttp_cdn")? = fields["kind"] { return false }
            return host == server || !of(host).isDisjoint(with: own)
        }
        return direct.endpoints.isEmpty ? nil : direct
    }

    /// `node` narrowed to the endpoints that `model` runs on, by their ID, as a node started on its direct transports compares.
    static func within(_ node: CatalogNode, _ model: CatalogNode) -> CatalogNode {
        func id(_ endpoint: JSONValue) -> String? {
            guard case .object(let fields) = endpoint, case .string(let id)? = fields["id"] else { return nil }
            return id
        }
        let ids = Set(model.endpoints.compactMap(id))
        var narrowed = node
        narrowed.endpoints = node.endpoints.filter { id($0).map(ids.contains) == true }
        return narrowed
    }

    static func onDirect(_ node: CatalogNode, endpoint: String, addresses: [String: Set<String>]) -> Bool {
        guard let direct = directNode(node, addresses: addresses) else { return false }
        return node.endpoints.isEmpty || direct.endpoints.contains { endpointValue in
            guard case .object(let fields) = endpointValue else { return false }
            return fields["id"] == .string(endpoint)
        }
    }

    /// The last check after preparation and immediately before a launch, and again before taking its core.
    static func startAllowed(_ attempt: NodeAttempt, found: NodeCandidates, pinnedTo: String?,
                             leaving: Bool, reconnecting: Bool) -> Bool {
        if leaving && !reconnecting { return false }
        guard let pinnedTo else { return true }
        // A cached catalog can offer the first ready node while an unchanged pin is still activating.
        let selected = found.pinned && pinnedTo == found.saved ? found.nodes.first?.id : pinnedTo
        return attempt.node.id == selected && !attempt.direct && attempt.full == nil
    }

    private static func names(_ nodes: [CatalogNode]) -> Set<String> {
        var names = Set<String>()
        for node in nodes {
            guard let server = node.profile?.server else { continue }
            let hosts = node.endpoints.compactMap { endpoint -> String? in
                guard case .object(let fields) = endpoint, case .string(let host)? = fields["server"] else { return nil }
                return host
            }
            for host in [server] + hosts where !host.isEmpty && literalAddress(host) == nil { names.insert(host) }
        }
        return names
    }

    /// Failover refreshes old or missing addresses with the measurement's timeout, without timing connections.
    static func resolveAddresses(_ nodes: [CatalogNode], measurement: NodeMeasurement,
                                 now: TimeInterval = Date().timeIntervalSince1970,
                                 timeout: TimeInterval = latencyTimeout,
                                 resolve: @escaping @Sendable (String) async -> [String]) async -> NodeMeasurement {
        let hosts = names(nodes)
        if now - measurement.resolvedAt < directMemory, hosts.allSatisfy({ measurement.addresses[$0]?.isEmpty == false }) {
            return measurement
        }
        let addresses = await collect(Array(hosts), timeout: timeout) { host in
            Set(await resolve(host).compactMap(literalAddress))
        }
        return NodeMeasurement(addresses: addresses, resolvedAt: now)
    }

    /// A literal IPv4 or IPv6 address in a normal form, read without a name lookup; nil for a name.
    static func literalAddress(_ server: String) -> String? {
        var text = server
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return format(AF_INET, &v4, MemoryLayout<in_addr>.size) }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, text, &v6) == 1 else { return nil }
        // An IPv4-mapped address is the IPv4 address it maps.
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return bytes[12...].map(String.init).joined(separator: ".")
        }
        return format(AF_INET6, &v6, MemoryLayout<in6_addr>.size)
    }

    private static func format<T>(_ family: Int32, _ address: inout T, _ size: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return withUnsafePointer(to: &address) { pointer in
            inet_ntop(family, pointer, &buffer, socklen_t(buffer.count)).map { _ in String(cString: buffer) }
        }
    }

    /**
     Times the nodes at once for at most two seconds and resolves the names their endpoints use within the same time;
     a node missing from the latencies is unknown. `dial` times a TCP connection to an address at port 443, the node's
     server or the first IPv4 address `resolve` gives for its name, and returns nil when it fails.
     */
    static func measure(_ nodes: [CatalogNode], timeout: TimeInterval = latencyTimeout,
                        resolve: @escaping @Sendable (String) async -> [String],
                        dial: @escaping @Sendable (String, Int) async -> TimeInterval?) async -> NodeMeasurement {
        enum Work: Hashable, Sendable { case latency(String, String), name(String) }
        enum Result: Sendable { case latency(Int), addresses(Set<String>) }
        var work: [Work] = []
        for node in nodes {
            guard let server = node.profile?.server, !server.isEmpty else { continue }
            work.append(.latency(node.id, server))
        }
        work += names(nodes).map { .name($0) }
        let results = await collect(work, timeout: timeout) { item -> Result? in
            switch item {
            case .name(let host):
                return .addresses(Set(await resolve(host).compactMap(literalAddress)))
            case .latency(_, let server):
                var address = literalAddress(server)
                if address == nil {
                    address = await resolve(server).compactMap(literalAddress).first { !$0.contains(":") }
                }
                guard let address, let elapsed = await dial(address, latencyPort), elapsed > 0 else { return nil }
                return .latency(max(1, Int((elapsed * 1000).rounded(.up))))
            }
        }
        var measurement = NodeMeasurement(resolvedAt: Date().timeIntervalSince1970)
        for (item, result) in results {
            switch (item, result) {
            case (.latency(let id, _), .latency(let milliseconds)): measurement.latencies[id] = milliseconds
            case (.name(let host), .addresses(let addresses)): measurement.addresses[host] = addresses
            default: break
            }
        }
        return measurement
    }

    /// Runs `work` for every key at once and returns the results that arrived within `timeout`. Work that ignores
    /// cancellation, as a blocking name lookup, ends after the caller stopped waiting for it.
    static func collect<K: Hashable & Sendable, V: Sendable>(_ keys: [K], timeout: TimeInterval,
                                                             work: @escaping @Sendable (K) async -> V?) async -> [K: V] {
        guard !keys.isEmpty else { return [:] }
        let box = CollectBox<K, V>(count: keys.count)
        return await withCheckedContinuation { continuation in
            box.start(continuation)
            for key in keys {
                box.add(Task.detached { box.finish(key, await work(key)) })
            }
            box.add(Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                box.end()
            })
        }
    }
}

private final class CollectBox<K: Hashable & Sendable, V: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var results: [K: V] = [:]
    private var continuation: CheckedContinuation<[K: V], Never>?
    private var tasks: [Task<Void, Never>] = []

    init(count: Int) { remaining = count }

    func start(_ continuation: CheckedContinuation<[K: V], Never>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
    }

    func add(_ task: Task<Void, Never>) {
        lock.lock()
        let ended = continuation == nil
        if !ended { tasks.append(task) }
        lock.unlock()
        if ended { task.cancel() }
    }

    func finish(_ key: K, _ value: V?) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        if let value { results[key] = value }
        remaining -= 1
        let done = remaining == 0
        lock.unlock()
        if done { end() }
    }

    func end() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        let results = self.results
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(returning: results)
    }
}

/// Latencies of measured nodes in milliseconds, and the addresses the names of their servers resolved to.
struct NodeMeasurement: Equatable, Sendable {
    var latencies: [String: Int] = [:]
    var addresses: [String: Set<String>] = [:]
    /// Wall-clock seconds, so sleep counts toward the thirty-minute lifetime.
    var resolvedAt: TimeInterval = -.infinity
}

/**
 The nodes a managed connection may use, in order, with the saved node and whether the user pinned it; `cached` marks
 nodes from the saved catalog, given while the controller did not answer.
 */
struct NodeCandidates: Equatable {
    let nodes: [CatalogNode]
    let saved: String
    let pinned: Bool
    var cached = false

    /// The candidates a connection starts on; none ready reads as a node that is still activating.
    func startable() throws -> NodeCandidates {
        guard !nodes.isEmpty else { throw AccessFailure("activating") }
        return self
    }
}

/// Both passes use the same candidates. Only a latency winner's direct failure settles that node at once.
struct NodePlan: Equatable {
    let nodes: [CatalogNode]
    var won = false
    var directSkipped = true
    var addresses: [String: Set<String>] = [:]

    var attempts: [NodeAttempt] {
        var attempts: [NodeAttempt] = []
        if !directSkipped {
            for (index, node) in nodes.enumerated() {
                guard let direct = NodeChoice.directNode(node, addresses: addresses) else { continue }
                attempts.append(NodeAttempt(node: direct, direct: true, last: won && index == 0,
                                            full: direct == node ? nil : node))
            }
        }
        let settled = Set(attempts.filter(\.last).map { $0.node.id })
        return attempts + nodes.filter { !settled.contains($0.id) }.map { NodeAttempt(node: $0) }
    }
}

struct NodeAttempt: Equatable {
    let node: CatalogNode
    var direct = false
    var last = true
    var full: CatalogNode? = nil
}

/// Process memory only, with wall-clock deadlines; shared across successive provider instances/connections.
final class NodeDirectPass: @unchecked Sendable {
    private let lock = NSLock()
    private var skipUntil: TimeInterval = -.infinity
    private var network = ""

    func onNetwork(_ signature: String) {
        lock.lock(); defer { lock.unlock() }
        if !network.isEmpty && network != signature { skipUntil = -.infinity }
        network = signature
    }

    func skipped(now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return now < skipUntil
    }

    @discardableResult
    func connected(_ attempt: NodeAttempt, in plan: NodePlan, endpoint: String,
                   addresses: [String: Set<String>], now: TimeInterval) -> Bool {
        let direct = attempt.direct || NodeChoice.onDirect(attempt.node, endpoint: endpoint, addresses: addresses)
        let exhausted = !attempt.direct && plan.attempts.contains { $0.direct }
        lock.lock(); defer { lock.unlock() }
        if direct { skipUntil = -.infinity }
        else if exhausted { skipUntil = now + NodeChoice.directMemory }
        return direct
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        skipUntil = -.infinity
    }
}

/**
 The node a managed connection runs on. A node chosen in the direct pass keeps its narrowed set until a normal core
 restart, such as a reconnect or ticket renewal, restores its full set.
 */
struct ActiveNode: Equatable {
    /// The node as it runs.
    let node: CatalogNode
    /// The catalog's node with its full set while `node` runs on its direct transports alone.
    let full: CatalogNode?

    init(_ node: CatalogNode, full: CatalogNode? = nil) {
        self.node = node
        self.full = full?.id == node.id ? full : nil
    }

    var narrowed: Bool { full != nil }

    /// The node any operation after the first start runs on: the node with its full set.
    var whole: CatalogNode { full ?? node }

    /// The fresh catalog's `offered` node as it runs without a restart: a node still on its direct transports keeps them.
    func renewed(_ offered: CatalogNode) -> ActiveNode {
        guard offered.id == node.id, full != nil else { return ActiveNode(offered) }
        return ActiveNode(NodeChoice.within(offered, node), full: offered)
    }
}

struct NodePause: Codable, Equatable {
    let until: TimeInterval
    let length: TimeInterval
}

/**
 Pauses of failed nodes in wall-clock seconds, kept through `read` and `write` so that they outlive the process.
 A pause orders the nodes; it never keeps a client from connecting.
 */
final class NodePauses: @unchecked Sendable {
    private let lock = NSLock()
    private var pauses: [String: NodePause]
    private let write: (Data) -> Void

    init(read: () -> Data?, write: @escaping (Data) -> Void) {
        pauses = read().flatMap { try? JSONDecoder().decode([String: NodePause].self, from: $0) } ?? [:]
        self.write = write
    }

    subscript(id: String) -> NodePause? {
        lock.lock(); defer { lock.unlock() }
        return pauses[id]
    }

    func paused(_ id: String, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (pauses[id]?.until ?? -.infinity) > now
    }

    /// Pauses a node for ten minutes, doubling up to six hours while it keeps failing.
    func fail(_ id: String, now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let length = pauses[id].map { min($0.length * 2, NodeChoice.pauseMax) } ?? NodeChoice.pause
        pauses[id] = NodePause(until: now + length, length: length)
        save()
    }

    func clear(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        if pauses.removeValue(forKey: id) != nil { save() }
    }

    /// Nodes without a pause first in their order, then the paused ones by the end of their pause.
    func order(_ nodes: [CatalogNode], now: TimeInterval) -> [CatalogNode] {
        lock.lock(); defer { lock.unlock() }
        let open = nodes.filter { (pauses[$0.id]?.until ?? -.infinity) <= now }
        let paused = nodes.filter { (pauses[$0.id]?.until ?? -.infinity) > now }
        return open + paused.enumerated().sorted {
            (pauses[$0.element.id]!.until, $0.offset) < (pauses[$1.element.id]!.until, $1.offset)
        }.map(\.element)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(pauses) { write(data) }
    }
}

/**
 Follows the node in use of a connection that may leave it, on a monotonic clock: how long its tunnel has kept
 reconnecting while the device had a network, whether the controller answered the last catalog request and how long
 the node has stayed healthy. Pauses go to `pauses` by wall-clock time. The owner serializes its calls.
 */
final class NodeFailover {
    private let pauses: NodePauses
    // The threshold counts from reconnectingSince; an episode lasts from a failure until the tunnel works again.
    private var reconnectingSince: TimeInterval?
    private var healthySince: TimeInterval?
    private var healthyNode = ""
    private var trackedNode = ""
    private var pausedInEpisode = Set<String>()
    /// A due failover stays due through network changes until its attempts finish or the tunnel recovers.
    private(set) var attempting = false
    /// The last catalog request went unanswered, so the nodes come from the saved catalog.
    private(set) var offline = false
    /// The candidates of the last catalog; a request without an answer keeps them.
    private(set) var found: NodeCandidates?

    init(pauses: NodePauses) { self.pauses = pauses }

    /**
     Times the tunnel on `node`: `connected` is a working tunnel, `reconnecting` one that does not work. Without a
     `network` the threshold starts again once the network is back, unless an already due failover is in progress.
     */
    func track(now: TimeInterval, node: String, connected: Bool, reconnecting: Bool, network: Bool) {
        if let healthySince, now - healthySince >= NodeChoice.healthyReset { pauses.clear(healthyNode) }
        // Another node, whatever moved the tunnel there, starts its own count and its own episode of pauses.
        if node != trackedNode {
            trackedNode = node
            reconnectingSince = nil
            attempting = false
            pausedInEpisode.removeAll()
        }
        if connected {
            reconnectingSince = nil
            attempting = false
            pausedInEpisode.removeAll()
            if healthySince == nil || healthyNode != node {
                healthySince = now
                healthyNode = node
            }
            return
        }
        healthySince = nil
        reconnectingSince = reconnecting && (network || attempting) ? reconnectingSince ?? now : nil
    }

    func beginSwitch() { attempting = true }

    /// A move to another node, or a round of failed attempts, gives the node in use the full threshold.
    /// A round interrupted by a network change resumes without another threshold.
    func switched(now: TimeInterval, retrying: Bool = false) {
        guard !retrying else { return }
        attempting = false
        if reconnectingSince != nil { reconnectingSince = now }
    }

    /**
     Keeps the candidates of a catalog request, nil for one that failed. A fresh catalog, an empty one too, replaces
     them; the controller counts as unreachable while a request fails or gives the saved catalog. When it answers again
     while the tunnel reconnects, the uplink was probably down, so the node in use gets the full threshold from then on.
     */
    func catalog(now: TimeInterval, found: NodeCandidates?) {
        let offline = found?.cached ?? true
        if self.offline, !offline, reconnectingSince != nil, !attempting { reconnectingSince = now }
        self.offline = offline
        if let found { self.found = found }
    }

    /// A node the last catalog offers; one gone from it leaves the failover queue.
    func offers(_ id: String) -> Bool { found?.nodes.contains { $0.id == id } == true }

    /// The tunnel has kept reconnecting for 45 s, or for 3 minutes while the controller does not answer.
    func due(now: TimeInterval) -> Bool {
        guard let reconnectingSince else { return false }
        return attempting || now - reconnectingSince >= (offline ? NodeChoice.failoverOfflineAfter : NodeChoice.failoverAfter)
    }

    /// Pauses a node that failed, at most once in an episode, however often it is retried there.
    func pause(_ id: String, wallNow: TimeInterval) {
        if pausedInEpisode.insert(id).inserted { pauses.fail(id, now: wallNow) }
    }
}

/**
 Starts a core for the first of the nodes that comes up and that the latest catalog still offers once its core is up:
 the one check a new core passes before it takes the tunnel, whatever starts it — the start of a connection, a failover,
 a ticket renewal or a reconnect on the full set of transports. The owner calls `run`, and `launch` calls back, on the
 queue where `failover` gets each catalog, so a catalog that comes while a core starts counts for it. A core whose node
 that catalog no longer offers is stopped and the next node is tried; a failed last attempt pauses its node when
 `pausing`, and without a network the attempts end. `end` follows when no core was taken. An owner that drops a
 launch, as when the tunnel stops, ends the attempts without `end`.
 */
final class NodeStarts<Core> {
    // launch calls ready after any wait, immediately before starting the core, on the owner's queue.
    typealias Launch = (NodeAttempt, @escaping () -> Bool, @escaping (Core?) -> Void) -> Void
    private var queue: [NodeAttempt]
    private let failover: NodeFailover
    private let pausing: Bool
    private let wallNow: () -> TimeInterval
    private let network: () -> Bool
    private let launch: Launch
    private let allowed: (NodeAttempt) -> Bool
    private let take: (NodeAttempt, Core) -> Void
    private let stop: (Core) -> Void
    private let end: () -> Void

    init(_ plan: NodePlan, failover: NodeFailover, pausing: Bool, wallNow: @escaping () -> TimeInterval,
         network: @escaping () -> Bool, allowed: @escaping (NodeAttempt) -> Bool, launch: @escaping Launch,
         take: @escaping (NodeAttempt, Core) -> Void,
         stop: @escaping (Core) -> Void, end: @escaping () -> Void) {
        queue = plan.attempts
        self.failover = failover
        self.pausing = pausing
        self.wallNow = wallNow
        self.network = network
        self.launch = launch
        self.allowed = allowed
        self.take = take
        self.stop = stop
        self.end = end
    }

    func run() {
        while !queue.isEmpty {
            let attempt = queue.removeFirst()
            // A node gone from the latest catalog leaves the queue.
            guard failover.offers(attempt.node.id) else { continue }
            launch(attempt, { [self] in
                guard allowed(attempt) else { end(); return false }
                guard failover.offers(attempt.node.id) else { run(); return false }
                return true
            }) { [self] core in finish(attempt, core) }
            return
        }
        end()
    }

    private func finish(_ attempt: NodeAttempt, _ core: Core?) {
        guard allowed(attempt) else {
            if let core { stop(core) }
            end()
            return
        }
        guard let core else {
            // Without a network no node comes up; the attempts end and the tunnel waits for the network.
            guard network() else { end(); return }
            if pausing && attempt.last { failover.pause(attempt.node.id, wallNow: wallNow()) }
            run()
            return
        }
        // A catalog that came while the core started may no longer offer its node.
        guard failover.offers(attempt.node.id) else {
            stop(core)
            run()
            return
        }
        take(attempt, core)
    }
}
