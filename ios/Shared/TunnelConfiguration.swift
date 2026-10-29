import Foundation

enum TunnelConfiguration {
    private struct Configuration: Encodable {
        let profile: ConnectionProfile
        let routing: String
        let rules: RoutingRules
    }

    static func make(profile: ConnectionProfile, routing: RoutingMode, base: RoutingDocument,
                     overrides: RoutingOverrides = .empty) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let configuration = Configuration(profile: profile, routing: routing.rawValue,
            rules: RoutingRules(routing: routing, base: base, overrides: overrides))
        return String(decoding: try encoder.encode(configuration), as: UTF8.self)
    }
}
