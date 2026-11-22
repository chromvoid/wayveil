import Foundation

@MainActor
func activateInvitationWhenIdle(_ text: String,
                                state: () -> (access: DeviceAccess?, loading: Bool, phase: TunnelPhase),
                                activate: () async throws -> Void) async throws {
    let pending = state().access
    while true {
        let current = state()
        guard !current.phase.running else {
            throw NSError(domain: "Wayveil", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("disconnect_first", comment: "")])
        }
        if current.loading {
            try await Task.sleep(nanoseconds: 50_000_000)
            continue
        }
        if let pending, pending.device.isEmpty, pending.invitation == (try? Invitation.parse(text)),
           let access = current.access, !access.device.isEmpty,
           access.installation == pending.installation, access.token == pending.token {
            return
        }
        try await activate()
        return
    }
}

struct AccessPresentation {
    let selectedNode: CatalogNode?
    /// Whether the client chooses the node itself or uses only the node the user pinned.
    let selection: NodeSelection
    let title: String
    let subtitle: String?
    let waitingForServer: Bool
    let visibleError: String?
    let refreshInterval: TimeInterval

    init(access: DeviceAccess?, catalog: NodeCatalog?, phase: TunnelPhase, error: String?, accessError: String?,
         localize: (String) -> String = { NSLocalizedString($0, comment: "") }) {
        selectedNode = access.flatMap { catalog?.selected($0.node) }
        selection = NodeSelection(access)
        title = selectedNode?.name ?? catalog?.label ?? localize("connection_title")
        subtitle = selectedNode == nil ? nil : catalog?.label
        waitingForServer = access != nil && !phase.running &&
            (selectedNode?.ready != true || accessError.map { AccessFailure($0).terminal } == true)
        visibleError = error ?? accessError.flatMap { $0.isEmpty ? nil : localize(Self.errorKey($0)) }
        refreshInterval = catalog?.nodes.contains(where: \.ready) == true ? 60 : 5
    }

    /**
     Shows in the app's `access` and `catalog` what the tunnel extension saved once it may have moved to another node:
     the saved access, and the catalog the extension saved when the app's lacks the saved node and the saved one has it.
     Only when neither has the node does the selection fall back to the first ready node. Without a saved access
     nothing changes.
     */
    static func reload(_ access: inout DeviceAccess?, _ catalog: inout NodeCatalog?, from store: any AccessStorage) {
        guard let saved = try? store.readAccess() else { return }
        access = saved
        guard catalog?.nodes.contains(where: { $0.id == saved.node }) != true,
              let stored = (try? store.readCatalog()).flatMap({ try? NodeCatalog.parse($0) }),
              stored.device == saved.device, stored.nodes.contains(where: { $0.id == saved.node }) else { return }
        catalog = stored
    }

    static func accessErrorCode(providerError: String?, refreshError: String?, refreshCompleted: Bool) -> String? {
        refreshCompleted ? refreshError : providerError ?? refreshError
    }

    static func errorKey(_ code: String) -> String {
        switch code {
        case "invalid_invitation", "device_limit_reached", "server_not_ready", "node_unavailable", "already_activated":
            return code
        case "installation_conflict", "credential_conflict": return "activation_conflict"
        case "access_expired", "access_inactive": return "access_expired"
        case "access_revoked", "unauthorized": return "access_revoked"
        case "activating": return "access_activating"
        case "try_again_later": return "access_rate_limited"
        default: return "access_network_error"
        }
    }
}
