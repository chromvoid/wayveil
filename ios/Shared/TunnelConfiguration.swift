import Foundation

enum TunnelConfiguration {
    private struct Configuration: Encodable {
        let profile: ConnectionProfile
        let routing: String
        let rules: RoutingRules
        let endpoints: [JSONValue]?
        let preferredEndpoint: String?

        enum CodingKeys: String, CodingKey {
            case profile, routing, rules, endpoints
            case preferredEndpoint = "preferred_endpoint"
        }
    }

    static func make(profile: ConnectionProfile, base: RoutingDocument,
                     overrides: RoutingOverrides = .empty, endpoints: [JSONValue]? = nil,
                     preferredEndpoint: String? = nil) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let configuration = Configuration(profile: profile, routing: "RUSSIAN_DIRECT",
            rules: RoutingRules(base: base, overrides: overrides),
            endpoints: endpoints?.isEmpty == false ? endpoints : nil,
            preferredEndpoint: endpoints?.isEmpty == false ? preferredEndpoint : nil)
        return String(decoding: try encoder.encode(configuration), as: UTF8.self)
    }
}
