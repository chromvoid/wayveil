import Darwin
import Foundation

actor AccessManager {
    private let store: any AccessStorage
    private let client: AccessHTTPClient
    private let now: @Sendable () -> Int64
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var state: AccessState

    init(store: any AccessStorage = AccessStore(), client: AccessHTTPClient = AccessHTTPClient(),
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.store = store
        self.client = client
        self.now = now
        let access = try? store.readAccess()
        let catalog = (try? store.readCatalog()).flatMap { try? NodeCatalog.parse($0) }
        state = AccessState(catalog: access?.device.isEmpty == false && catalog?.device == access?.device ? catalog : nil)
    }

    func activate(_ text: String) async throws -> NodeCatalog {
        await lock()
        defer { unlock() }
        try Task.checkCancellation()
        let invitation = try Invitation.parse(text)
        let saved = try store.readAccess()
        if let saved, !saved.device.isEmpty || saved.invitation != invitation { throw AccessFailure("already_activated") }
        if saved == nil { try store.saveAccess(DeviceAccess.pending(invitation)) }
        return try await refreshLocked()
    }

    func refresh() async throws -> NodeCatalog {
        await lock()
        defer { unlock() }
        try Task.checkCancellation()
        return try await refreshLocked()
    }

    /// Pins a node the user chose: a managed connection then uses it alone.
    func select(_ id: String) async throws {
        await lock()
        defer { unlock() }
        try Task.checkCancellation()
        guard state.catalog?.nodes.contains(where: { $0.id == id && $0.ready }) == true,
              let access = try store.readAccess() else { throw AccessFailure("node_unavailable") }
        try store.saveAccess(access.select(id))
    }

    /// Returns to the automatic choice; the saved node stays the current one.
    func selectAuto() async throws {
        await lock()
        defer { unlock() }
        try Task.checkCancellation()
        guard let access = try store.readAccess(), access.pinned else { return }
        try store.saveAccess(access.automatic())
    }

    /// Records the node a connection moved to as the current one without pinning it; a pinned node is left alone.
    func saveCurrent(_ id: String) async throws {
        await lock()
        defer { unlock() }
        guard let access = try store.readAccess(), !access.pinned, access.node != id else { return }
        try store.saveAccess(access.current(id))
    }

    /// The candidates of a fresh catalog, none when no node is ready, or of the saved one when the controller does not
    /// answer.
    func candidates() async throws -> NodeCandidates {
        await lock()
        defer { unlock() }
        try Task.checkCancellation()
        let catalog: NodeCatalog
        do { catalog = try await refreshLocked() }
        catch let failure as AccessFailure {
            if let found = cachedCandidates(access: try store.readAccess(), catalog: state.catalog, failure: failure, now: now()) {
                return found
            }
            throw failure
        }
        // The refresh replaces a saved node that left the catalog, so the access is read after it.
        let access = try store.readAccess()
        let saved = access?.node ?? "", pinned = access?.pinned == true
        return NodeCandidates(nodes: catalog.candidates(saved: saved, pinned: pinned, validAfter: now()), saved: saved, pinned: pinned)
    }

    func remove() async throws {
        await lock()
        defer { unlock() }
        try Task.checkCancellation()
        guard let access = try store.readAccess() else { return }
        do { _ = try await client.request(method: "DELETE", path: "/v1/devices/self", token: access.token) }
        catch let failure as AccessFailure where failure.code == "unauthorized" { }
        try Task.checkCancellation()
        try store.removeAccess()
        state = AccessState()
    }

    private func refreshLocked() async throws -> NodeCatalog {
        state = AccessState(catalog: state.catalog, loading: true)
        var originalAccess: DeviceAccess?
        do {
            guard var access = try store.readAccess() else { throw AccessFailure("unauthorized") }
            originalAccess = access
            if access.device.isEmpty {
                var body = ["invite_token": access.invitation, "api_token": access.token,
                            "installation_id": access.installation, "name": Self.deviceName, "platform": Self.platform]
                if let version = client.appVersion { body["app_version"] = version }
                let response = try await client.request(method: "POST", path: "/v1/devices/enroll",
                                                        body: JSONEncoder().encode(body))
                guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                      let device = object["device_id"] as? String else { throw AccessFailure("network_error") }
                access = try currentAccess(matching: access).enrolled(device)
                try store.saveAccess(access)
            }
            let data = try await client.request(method: "GET", path: "/v1/catalog", token: access.token)
            let catalog = try NodeCatalog.parse(data)
            guard catalog.device == access.device else { throw AccessFailure("network_error") }
            try Task.checkCancellation()
            access = try currentAccess(matching: access)
            try store.saveCatalog(data)
            // Without a pin the saved node is the one a connection last worked on, and only the tunnel extension
            // changes it: a catalog an earlier request got must not undo a move. A missing one just goes unoffered.
            if access.pinned || access.node.isEmpty, let selected = catalog.selected(access.node), selected.id != access.node {
                let current = try currentAccess(matching: access)
                try store.saveAccess(current.replaced(selected.id))
            }
            state = AccessState(catalog: catalog)
            return catalog
        } catch is CancellationError {
            state = AccessState(catalog: state.catalog)
            throw CancellationError()
        } catch let failure as AccessFailure {
            state = AccessState(catalog: failure.terminal ? nil : state.catalog, error: failure.code)
            if failure.terminal, let originalAccess,
               (try? currentAccess(matching: originalAccess)) != nil { try? store.removeCatalog() }
            throw failure
        } catch {
            state = AccessState(catalog: state.catalog, error: "network_error")
            throw AccessFailure("network_error")
        }
    }

    private func currentAccess(matching access: DeviceAccess) throws -> DeviceAccess {
        guard let current = try store.readAccess(), current.installation == access.installation,
              current.token == access.token else { throw AccessFailure("unauthorized") }
        return current
    }

    // Actor methods can reenter at awaits; keep enrollment and mutations in one ordered operation.
    private func lock() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func unlock() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }

    private static var platform: String {
        #if os(macOS)
        return "macos"
        #else
        return "ios"
        #endif
    }

    private static var deviceName: String {
        #if os(macOS)
        var size = 0
        _ = sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(1, size))
        _ = sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(("Mac " + String(cString: model)).prefix(80))
        #else
        var info = utsname()
        uname(&info)
        let capacity = MemoryLayout.size(ofValue: info.machine)
        let hardware = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? hardware
        let prefix = model.hasPrefix("iPad") ? "iPad " : "iPhone "
        return String((prefix + model).prefix(80))
        #endif
    }
}
