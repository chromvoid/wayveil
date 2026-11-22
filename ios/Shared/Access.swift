import Foundation
import Security

enum Invitation {
    static let origin = "https://link.chromvoid.com"

    static func parse(_ text: String) throws -> String {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf16.count <= 2048,
              let url = URLComponents(string: input), let authorityStart = input.range(of: "://")?.upperBound,
              url.user == nil, url.password == nil, url.port == nil, url.percentEncodedQuery == nil else {
            throw AccessFailure("invalid_invitation")
        }
        let authority = input[authorityStart...].prefix { !"/?#".contains($0) }
        let https = url.scheme == "https" && authority == "link.chromvoid.com" && ["", "/"].contains(url.path)
        let app = url.scheme == "wayveil" && authority == "invite" && url.path.isEmpty
        guard https || app, let token = url.percentEncodedFragment,
              token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              decodeBase64URL(token)?.count == 32 else { throw AccessFailure("invalid_invitation") }
        return token
    }

    static func isLink(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("https://") || text.hasPrefix("wayveil://invite")
    }
}

struct AccessFailure: Error, Equatable, Sendable {
    let code: String
    init(_ code: String) { self.code = code }
    var terminal: Bool { ["unauthorized", "access_expired", "access_revoked", "access_inactive"].contains(code) }
}

// `pinned` marks `node` as the user's choice; otherwise it is the last node that worked, and the client chooses itself.
struct DeviceAccess: Codable, Equatable, Sendable {
    let installation: String
    let token: String
    var invitation = ""
    var device = ""
    var node = ""
    var pinned = false

    static func pending(_ invitation: String) throws -> DeviceAccess {
        func secret() throws -> String {
            var bytes = Data(count: 32)
            let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
            guard status == errSecSuccess else { throw AccessFailure("network_error") }
            return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return try DeviceAccess(installation: secret(), token: secret(), invitation: invitation)
    }

    func enrolled(_ id: String) -> DeviceAccess {
        DeviceAccess(installation: installation, token: token, device: id, node: node, pinned: pinned)
    }

    /// Pins a node the user chose.
    func select(_ id: String) -> DeviceAccess { with(node: id, pinned: true) }
    /// Returns the choice to the client and keeps the saved node as the current one.
    func automatic() -> DeviceAccess { with(node: node, pinned: false) }
    /// Records the node in use without pinning it.
    func current(_ id: String) -> DeviceAccess { with(node: id, pinned: false) }
    /// Replaces a saved node that left the catalog and keeps the mode.
    func replaced(_ id: String) -> DeviceAccess { with(node: id, pinned: pinned) }

    private func with(node: String, pinned: Bool) -> DeviceAccess {
        DeviceAccess(installation: installation, token: token, invitation: invitation, device: device, node: node, pinned: pinned)
    }
}

extension DeviceAccess {
    enum CodingKeys: String, CodingKey { case installation, token, invitation, device, node, pinned }

    // Access saved before the pin existed has no "pinned": its node is the last one that worked.
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(installation: try fields.decode(String.self, forKey: .installation),
                  token: try fields.decode(String.self, forKey: .token),
                  invitation: try fields.decode(String.self, forKey: .invitation),
                  device: try fields.decode(String.self, forKey: .device),
                  node: try fields.decode(String.self, forKey: .node),
                  pinned: try fields.decodeIfPresent(Bool.self, forKey: .pinned) ?? false)
    }
}

// Endpoint fields belong to the core; preserve their JSON values without interpreting them.
enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Decimal), bool(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Decimal.self) { self = .number(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct CatalogNode: Equatable {
    let id: String
    let name: String
    let profile: ConnectionProfile?
    let expiresAt: Int64
    var location = ""
    var portMbps = 0
    var endpoints: [JSONValue] = []
    var ready: Bool { profile != nil }
}

struct NodeCatalog: Equatable {
    let label: String
    let expiresAt: Int64
    let nodes: [CatalogNode]
    let device: String

    func selected(_ id: String) -> CatalogNode? {
        nodes.first(where: { $0.id == id }) ?? nodes.first(where: \.ready)
    }

    /**
     The nodes to connect to, with tickets valid after `validAfter`: the pinned node alone, or the first ready one while
     it is missing from the catalog, as before the pin; otherwise the ready nodes, the saved one first, then in order.
     */
    func candidates(saved: String, pinned: Bool, validAfter: Int64) -> [CatalogNode] {
        func valid(_ node: CatalogNode) -> Bool { node.ready && node.expiresAt > validAfter }
        if pinned { return selected(saved).flatMap { valid($0) ? [$0] : nil } ?? [] }
        let ready = nodes.filter(valid)
        return ready.filter { $0.id == saved } + ready.filter { $0.id != saved }
    }

    static func parse(_ data: Data) throws -> NodeCatalog {
        struct Document: Decodable {
            struct Grant: Decodable { let label: String; let expires_at: Int64 }
            struct Node: Decodable {
                let id: String?
                let name: String?
                let ready: Bool
                let server: String?
                let server_port: Int?
                let ticket: String?
                let obfs_password: String?
                let server_name: String?
                let certificate: String?
                let location: String?
                let port_mbps: Int?
                let endpoints: [JSONValue]?

                enum CodingKeys: String, CodingKey {
                    case id, name, ready, server, server_port, ticket, obfs_password, server_name, certificate
                    case location, port_mbps, endpoints
                }

                init(from decoder: Decoder) throws {
                    let fields = try decoder.container(keyedBy: CodingKeys.self)
                    id = try fields.decodeIfPresent(String.self, forKey: .id)
                    name = try fields.decodeIfPresent(String.self, forKey: .name)
                    ready = try fields.decode(Bool.self, forKey: .ready)
                    location = try fields.decodeIfPresent(String.self, forKey: .location)
                    port_mbps = try fields.decodeIfPresent(Int.self, forKey: .port_mbps)
                    server = ready ? try fields.decodeIfPresent(String.self, forKey: .server) : nil
                    server_port = ready ? try fields.decodeIfPresent(Int.self, forKey: .server_port) : nil
                    ticket = ready ? try fields.decodeIfPresent(String.self, forKey: .ticket) : nil
                    obfs_password = ready ? try fields.decodeIfPresent(String.self, forKey: .obfs_password) : nil
                    server_name = ready ? try fields.decodeIfPresent(String.self, forKey: .server_name) : nil
                    certificate = ready ? try fields.decodeIfPresent(String.self, forKey: .certificate) : nil
                    endpoints = ready ? try fields.decodeIfPresent([JSONValue].self, forKey: .endpoints) : nil
                }
            }
            let grant: Grant
            let nodes: [Node]
            let device_id: String
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        let nodes = try document.nodes.map { node -> CatalogNode in
            var profile: ConnectionProfile?
            var expiry: Int64 = 0
            if node.ready {
                guard let port = node.server_port else { throw AccessFailure("network_error") }
                let ticket = node.ticket ?? ""
                let candidate = ConnectionProfile(name: node.name ?? "", server: node.server ?? "", port: port,
                    password: ticket, obfsPassword: node.obfs_password ?? "", serverName: node.server_name ?? "",
                    certificate: node.certificate ?? "")
                profile = try ConnectionProfile.parse(String(decoding: JSONEncoder().encode(candidate), as: UTF8.self))
                let parts = ticket.split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count > 1, let payload = decodeBase64URL(String(parts[1])) else { throw AccessFailure("network_error") }
                struct Claims: Decodable { let exp: Int64 }
                expiry = try JSONDecoder().decode(Claims.self, from: payload).exp
            }
            return CatalogNode(id: node.id ?? "", name: node.name ?? "", profile: profile, expiresAt: expiry,
                location: node.location ?? "", portMbps: node.port_mbps ?? 0, endpoints: node.ready ? node.endpoints ?? [] : [])
        }
        guard Set(nodes.map(\.id)).count == nodes.count else { throw AccessFailure("network_error") }
        return NodeCatalog(label: document.grant.label, expiresAt: document.grant.expires_at, nodes: nodes, device: document.device_id)
    }
}

struct AccessState: Equatable {
    var catalog: NodeCatalog? = nil
    var loading = false
    var error: String? = nil
}

/// The saved catalog a transient failure may fall back to: for the same device and with a valid grant.
private func cachedCatalog(access: DeviceAccess?, catalog: NodeCatalog?, failure: AccessFailure, now: Int64) -> NodeCatalog? {
    guard ["network_error", "try_again_later"].contains(failure.code), let access, let catalog,
          !access.device.isEmpty, catalog.device == access.device,
          catalog.expiresAt == 0 || catalog.expiresAt > now else { return nil }
    return catalog
}

func cachedConnection(access: DeviceAccess?, catalog: NodeCatalog?, failure: AccessFailure, now: Int64) -> CatalogNode? {
    guard let access, let catalog = cachedCatalog(access: access, catalog: catalog, failure: failure, now: now) else { return nil }
    let selected = catalog.selected(access.node)
    let node = selected?.ready == true ? selected : catalog.nodes.first(where: \.ready)
    return node.flatMap { $0.expiresAt > now + 60 ? $0 : nil }
}

/// The candidates of the saved catalog: a pinned node as `cachedConnection` gives it, or every ready node with a
/// ticket valid for a minute.
func cachedCandidates(access: DeviceAccess?, catalog: NodeCatalog?, failure: AccessFailure, now: Int64) -> NodeCandidates? {
    guard let access, let catalog = cachedCatalog(access: access, catalog: catalog, failure: failure, now: now) else { return nil }
    let nodes = access.pinned
        ? cachedConnection(access: access, catalog: catalog, failure: failure, now: now).map { [$0] } ?? []
        : catalog.candidates(saved: access.node, pinned: false, validAfter: now + 60)
    return nodes.isEmpty ? nil : NodeCandidates(nodes: nodes, saved: access.node, pinned: access.pinned, cached: true)
}

func shouldRenewTicket(ticketExpiresAt: Int64, expiresAt: Int64, now: Int64) -> Bool {
    ticketExpiresAt - now <= 300 && expiresAt > ticketExpiresAt
}

private actor ManagedConnectionFailure {
    var last = AccessFailure("activating")
    func record(_ failure: AccessFailure) { last = failure }
    func timeout() -> AccessFailure { last.code == "activating" ? AccessFailure("server_not_ready") : last }
}

func awaitManagedConnection<T: Sendable>(
    connection: @escaping () async throws -> T,
    wait: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
) async throws -> T {
    let deadline = now() + 90
    let failure = ManagedConnectionFailure()
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            while now() < deadline {
                try Task.checkCancellation()
                do {
                    let node = try await connection()
                    try Task.checkCancellation()
                    if now() >= deadline { break }
                    return node
                } catch let error as AccessFailure {
                    guard ["activating", "network_error"].contains(error.code) else { throw error }
                    await failure.record(error)
                }
                let remaining = deadline - now()
                if remaining <= 0 { break }
                try await wait(min(3, remaining))
            }
            throw await failure.timeout()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: 90_000_000_000)
            throw await failure.timeout()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

private func decodeBase64URL(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64)
}
