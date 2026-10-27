import Foundation

enum TunnelConfiguration {
    private struct Configuration: Encodable {
        let profile: ConnectionProfile
        let routing: String
    }

    static func make(profile: ConnectionProfile, routing: RoutingMode) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(Configuration(profile: profile, routing: routing.rawValue)), as: UTF8.self)
    }
}
