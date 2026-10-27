import Darwin
import Foundation
import Network
import NetworkExtension
import HevSocks5Tunnel
import WayveilCore

final class TunnelPlatform: NSObject, MobilePlatformProtocol {
    private weak var provider: PacketTunnelProvider?
    private let pathLock = NSLock()
    private let monitor = NWPathMonitor()
    private var interfaceIndex: UInt32 = 0
    private var lastPath = ""
    private var closed = false
    private var bridge: PacketFlowBridge?

    init(provider: PacketTunnelProvider) { self.provider = provider }

    func startMonitoring() throws {
        let ready = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { ready.signal(); return }
            let interface = path.availableInterfaces.first {
                path.usesInterfaceType($0.type) && !$0.name.hasPrefix("utun") && $0.type != .loopback
            }
            let available = path.status == .satisfied && interface != nil
            let signature = "\(available)/\(interface?.index ?? 0)/\(path.isExpensive)/\(path.isConstrained)"
            self.pathLock.lock()
            self.interfaceIndex = available ? UInt32(interface!.index) : 0
            let changed = !self.lastPath.isEmpty && self.lastPath != signature && !self.closed
            self.lastPath = signature
            self.pathLock.unlock()
            ready.signal()
            if changed { self.provider?.networkChanged(available: available) }
        }
        monitor.start(queue: DispatchQueue(label: "com.chromvoid.vpn.path"))
        guard ready.wait(timeout: .now() + 10) == .success else {
            throw failure("The network path is unavailable.")
        }
    }

    func protectSocket(_ fd: Int64) throws {
        pathLock.lock()
        var index = interfaceIndex
        let available = !closed && index > 0
        pathLock.unlock()
        guard available, fd >= 0, fd <= Int64(Int32.max) else {
            throw failure("The physical network interface is unavailable.")
        }
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(Int32(fd), $0, &length) }
        }
        guard result == 0 else { throw failure("Could not inspect the transport socket.") }
        let level: Int32
        let option: Int32
        switch Int32(address.ss_family) {
        case AF_INET: level = IPPROTO_IP; option = IP_BOUND_IF
        case AF_INET6: level = IPPROTO_IPV6; option = IPV6_BOUND_IF
        default: throw failure("The transport socket address family is unsupported.")
        }
        guard setsockopt(Int32(fd), level, option, &index, socklen_t(MemoryLayout.size(ofValue: index))) == 0 else {
            throw failure("Could not bind the transport socket to the physical interface.")
        }
    }

    func configureTunnel() throws {
        guard let provider else { throw failure("The VPN provider is unavailable.") }
        let network = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        network.mtu = 1400
        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [.default()]
        network.ipv4Settings = ipv4
        let ipv6 = NEIPv6Settings(addresses: ["fdfe:dcba:9876::1"], networkPrefixLengths: [126])
        ipv6.includedRoutes = [.default()]
        network.ipv6Settings = ipv6
        let resolver = NEDNSSettings(servers: ["172.19.0.2"])
        resolver.matchDomains = [""]
        resolver.matchDomainsNoSearch = true
        network.dnsSettings = resolver
        let done = DispatchSemaphore(value: 0)
        var networkError: Error?
        provider.setTunnelNetworkSettings(network) { error in networkError = error; done.signal() }
        guard done.wait(timeout: .now() + 15) == .success, networkError == nil else {
            throw failure("Could not configure the VPN interface.")
        }
    }

    func startForwarding(configuration: String) throws {
        guard let provider else { throw failure("The VPN provider is unavailable.") }
        let bridge = try PacketFlowBridge(provider: provider)
        self.bridge = bridge
        bridge.start(configuration: configuration)
    }

    func stopForwarding() {
        bridge?.stop()
        bridge = nil
    }

    func traffic() -> (txPackets: UInt, txBytes: UInt, rxPackets: UInt, rxBytes: UInt) {
        guard bridge != nil else { return (0, 0, 0, 0) }
        var txPackets = 0, txBytes = 0, rxPackets = 0, rxBytes = 0
        hev_socks5_tunnel_stats(&txPackets, &txBytes, &rxPackets, &rxBytes)
        return (UInt(txPackets), UInt(txBytes), UInt(rxPackets), UInt(rxBytes))
    }

    func close() {
        stopForwarding()
        pathLock.lock(); closed = true; interfaceIndex = 0; pathLock.unlock()
        monitor.cancel()
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "ChromVoidVPN", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class PacketFlowBridge {
    private weak var provider: PacketTunnelProvider?
    private let queue = DispatchQueue(label: "com.chromvoid.vpn.packets")
    private let worker = DispatchQueue(label: "com.chromvoid.vpn.hev")
    private let completion = DispatchGroup()
    private let sourceCancellation = DispatchGroup()
    private let workerLock = NSLock()
    private var workerFinished = false
    private var readSource: DispatchSourceRead?
    private var pair: [Int32] = [-1, -1]
    private var active = false
    private var buffer = [UInt8](repeating: 0, count: 65_539)

    init(provider: PacketTunnelProvider) throws {
        self.provider = provider
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0 else {
            throw NSError(domain: "ChromVoidVPN", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create the VPN packet bridge."])
        }
        for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        guard fcntl(pair[0], F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(pair[0]); Darwin.close(pair[1])
            throw NSError(domain: "ChromVoidVPN", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not configure the VPN packet bridge."])
        }
    }

    func start(configuration: String) {
        active = true
        let source = DispatchSource.makeReadSource(fileDescriptor: pair[0], queue: queue)
        source.setEventHandler { [weak self] in self?.receivePackets() }
        sourceCancellation.enter()
        source.setCancelHandler { [sourceCancellation] in sourceCancellation.leave() }
        readSource = source
        source.resume()
        readPackets()
        hev_socks5_tunnel_reset()
        let descriptor = pair[1]
        completion.enter()
        worker.async { [self] in
            let result = Array(configuration.utf8).withUnsafeBufferPointer {
                hev_socks5_tunnel_main_from_str($0.baseAddress, UInt32($0.count), descriptor)
            }
            workerLock.lock(); workerFinished = true; workerLock.unlock()
            completion.leave()
            provider?.forwardingStopped(result: result)
        }
    }

    func stop() {
        queue.sync { active = false; readSource?.cancel(); readSource = nil }
        workerLock.lock()
        let finished = workerFinished
        workerLock.unlock()
        if !finished { hev_socks5_tunnel_quit() }
        completion.wait()
        sourceCancellation.wait()
        queue.sync {
            for fd in pair where fd >= 0 { Darwin.close(fd) }
            pair = [-1, -1]
        }
    }

    private func readPackets() {
        provider?.packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.queue.async {
                guard self.active else { return }
                for (packet, family) in zip(packets, protocols) {
                    var header = family.uint32Value.bigEndian
                    var framed = Data(bytes: &header, count: 4)
                    framed.append(packet)
                    framed.withUnsafeBytes { bytes in
                        _ = send(self.pair[0], bytes.baseAddress, bytes.count, MSG_DONTWAIT)
                    }
                }
                self.readPackets()
            }
        }
    }

    private func receivePackets() {
        guard active else { return }
        var packets: [Data] = []
        var protocols: [NSNumber] = []
        while packets.count < 32 {
            let length = buffer.withUnsafeMutableBytes { recv(pair[0], $0.baseAddress, $0.count, MSG_DONTWAIT) }
            if length <= 0 { break }
            guard length > 4 else { continue }
            let family = UInt32(buffer[0]) << 24 | UInt32(buffer[1]) << 16 | UInt32(buffer[2]) << 8 | UInt32(buffer[3])
            guard family == UInt32(AF_INET) || family == UInt32(AF_INET6) else { continue }
            packets.append(Data(buffer[4..<length]))
            protocols.append(NSNumber(value: family))
        }
        if !packets.isEmpty { _ = provider?.packetFlow.writePackets(packets, withProtocols: protocols) }
    }
}
