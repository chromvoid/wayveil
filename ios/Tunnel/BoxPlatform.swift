import Darwin
import Foundation
import Libbox
import Network
import NetworkExtension

final class BoxPlatform: NSObject, LibboxPlatformInterfaceProtocol {
    private weak var provider: PacketTunnelProvider?
    private var monitor: NWPathMonitor?
    private var settings: NEPacketTunnelNetworkSettings?
    private var lastPath = ""
    init(provider: PacketTunnelProvider) { self.provider = provider }

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options, let ret0_, let provider else { throw unsupported("TUN options are missing.") }
        let network = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        network.mtu = NSNumber(value: options.getMTU())
        var addresses4: [String] = []; var masks: [String] = []
        if let values = options.getInet4Address() {
            while values.hasNext() { if let prefix = values.next() { addresses4.append(prefix.address()); masks.append(prefix.mask()) } }
        }
        let ipv4 = NEIPv4Settings(addresses: addresses4, subnetMasks: masks)
        ipv4.includedRoutes = [NEIPv4Route.default()]
        network.ipv4Settings = ipv4
        var addresses6: [String] = []; var prefixes: [NSNumber] = []
        if let values = options.getInet6Address() {
            while values.hasNext() { if let prefix = values.next() { addresses6.append(prefix.address()); prefixes.append(NSNumber(value: prefix.prefix())) } }
        }
        let ipv6 = NEIPv6Settings(addresses: addresses6, networkPrefixLengths: prefixes)
        ipv6.includedRoutes = [NEIPv6Route.default()]
        network.ipv6Settings = ipv6
        let servers = try options.getDNSServerAddress()
        var dns: [String] = []
        while servers.hasNext() { dns.append(servers.next()) }
        guard !dns.isEmpty else { throw unsupported("The VPN DNS server is missing.") }
        let resolver = NEDNSSettings(servers: dns)
        resolver.matchDomains = [""]; resolver.matchDomainsNoSearch = true
        network.dnsSettings = resolver
        let completion = DispatchSemaphore(value: 0)
        var networkError: Error?
        provider.setTunnelNetworkSettings(network) { error in networkError = error; completion.signal() }
        guard completion.wait(timeout: .now() + 15) == .success, networkError == nil else { throw unsupported("Could not configure the VPN interface.") }
        settings = network
        let descriptor = LibboxGetTunnelFileDescriptor()
        guard descriptor >= 0 else { throw unsupported("The VPN interface descriptor is unavailable.") }
        ret0_.pointee = descriptor
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { throw unsupported("The network listener is missing.") }
        let value = NWPathMonitor(); monitor = value
        let ready = DispatchSemaphore(value: 0)
        value.pathUpdateHandler = { [weak self] path in
            guard let self else { ready.signal(); return }
            let interface = path.availableInterfaces.first { path.usesInterfaceType($0.type) && !$0.name.hasPrefix("utun") && $0.type != .loopback }
            let available = path.status == .satisfied && interface != nil
            listener.updateDefaultInterface(available ? interface?.name ?? "" : "", interfaceIndex: available ? Int32(interface!.index) : -1,
                isExpensive: path.isExpensive, isConstrained: path.isConstrained)
            let signature = "\(available)/\(interface?.name ?? "")/\(interface?.index ?? 0)/\(path.isExpensive)/\(path.isConstrained)"
            if self.lastPath != signature { self.lastPath = signature; self.provider?.networkChanged(available: available) }
            ready.signal()
        }
        value.start(queue: DispatchQueue(label: "com.chromvoid.vpn.path"))
        guard ready.wait(timeout: .now() + 10) == .success else { throw unsupported("The network path is unavailable.") }
    }

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws { close() }
    func close() { monitor?.cancel(); monitor = nil; settings = nil }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        let interfaces = monitor?.currentPath.availableInterfaces.map { item -> LibboxNetworkInterface in
            let value = LibboxNetworkInterface()
            value.name = item.name; value.index = Int32(item.index); value.mtu = 1500
            value.flags = Int32(IFF_UP | IFF_RUNNING)
            switch item.type {
            case .wifi: value.type = LibboxInterfaceTypeWIFI
            case .cellular: value.type = LibboxInterfaceTypeCellular
            case .wiredEthernet: value.type = LibboxInterfaceTypeEthernet
            default: value.type = LibboxInterfaceTypeOther
            }
            value.addresses = StringIterator([]); value.dnsServer = StringIterator([]); value.gateway = StringIterator([])
            value.metered = monitor?.currentPath.isExpensive ?? false
            return value
        } ?? []
        return InterfaceIterator(interfaces)
    }

    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }
    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_ fd: Int32) throws { }
    func localDNSTransport() -> LibboxLocalDNSTransportProtocol? { nil }
    func readWIFIState() -> LibboxWIFIState? { nil }
    func clearDNSCache() { if let settings { provider?.setTunnelNetworkSettings(settings) { _ in } } }
    func registerMyInterface(_ name: String?) { }
    func usePlatformShell() -> Bool { false }
    func usePlatformBridge() -> Bool { false }
    func tailscaleHostname() -> String { "Wayveil" }
    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner { throw unsupported() }
    func send(_ notification: LibboxNotification?) throws { throw unsupported() }
    func cancelNotification(_ identifier: String?, typeID: Int32) throws { throw unsupported() }
    func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws { throw unsupported() }
    func closeNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws { }
    func checkPlatformShell() throws { throw unsupported() }
    func openShellSession(_ user: LibboxPlatformUser?, command: String?, environ: LibboxStringIteratorProtocol?, term: String?, rows: Int32, cols: Int32) throws -> LibboxShellSessionProtocol { throw unsupported() }
    func lookupUser(_ username: String?) throws -> LibboxPlatformUser { throw unsupported() }
    func lookupSFTPServer(_ error: NSErrorPointer) -> String { error?.pointee = unsupported(); return "" }
    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String { error?.pointee = unsupported(); return "" }
    func createBridge(_ options: LibboxBridgeOptions?) throws -> LibboxBridgeSessionProtocol { throw unsupported() }

    private func unsupported(_ message: String = "This feature is not enabled in Wayveil.") -> NSError {
        NSError(domain: "ChromVoidVPN", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class StringIterator: NSObject, LibboxStringIteratorProtocol {
    private let values: [String]
    private var index = 0
    init(_ values: [String]) { self.values = values }
    func hasNext() -> Bool { index < values.count }
    func next() -> String { defer { index += 1 }; return values[index] }
    func len() -> Int32 { Int32(values.count - index) }
}

private final class InterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private let values: [LibboxNetworkInterface]
    private var index = 0
    init(_ values: [LibboxNetworkInterface]) { self.values = values }
    func hasNext() -> Bool { index < values.count }
    func next() -> LibboxNetworkInterface? { guard hasNext() else { return nil }; defer { index += 1 }; return values[index] }
}
