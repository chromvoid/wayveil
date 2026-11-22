import Darwin
import Foundation
import Network

/// The latency measurement of NodeChoice.measure on the device: a TCP connection from the extension, made before the
/// tunnel is configured, so that it goes through the physical network like the controller client's requests.
enum NodeProbe {
    /// The addresses the system resolver gives for a name.
    @Sendable static func resolve(_ host: String) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                hints.ai_protocol = IPPROTO_TCP
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0 else {
                    continuation.resume(returning: [])
                    return
                }
                defer { freeaddrinfo(result) }
                var addresses: [String] = []
                var cursor = result
                while let info = cursor {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        addresses.append(String(cString: buffer))
                    }
                    cursor = info.pointee.ai_next
                }
                continuation.resume(returning: addresses)
            }
        }
    }

    /// The time a TCP connection to address at port takes to open, or nil when it fails within the measurement's timeout.
    @Sendable static func dial(_ address: String, _ port: Int) async -> TimeInterval? {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: .tcp)
        let queue = DispatchQueue(label: "com.chromvoid.vpn.latency")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<TimeInterval?, Never>) in
                let attempt = Attempt(connection: connection, continuation: continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: attempt.finish(attempt.elapsed)
                    case .failed, .waiting, .cancelled: attempt.finish(nil)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + NodeChoice.latencyTimeout) { attempt.finish(nil) }
            }
        } onCancel: { connection.cancel() }
    }
}

// One latency measurement; it runs on its connection's queue only, so it needs no lock.
private final class Attempt: @unchecked Sendable {
    private let connection: NWConnection
    private var continuation: CheckedContinuation<TimeInterval?, Never>?
    private let began = DispatchTime.now()

    init(connection: NWConnection, continuation: CheckedContinuation<TimeInterval?, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    var elapsed: TimeInterval { Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1e9 }

    func finish(_ value: TimeInterval?) {
        guard let continuation else { return }
        self.continuation = nil
        connection.cancel()
        continuation.resume(returning: value)
    }
}
