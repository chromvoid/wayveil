import Foundation
import Security

enum RoutingMode: String, CaseIterable {
    case all = "ALL"
    case russianDirect = "RUSSIAN_DIRECT"
}

enum ProfileError: Error, LocalizedError {
    case invalid, tooLarge, unsupported, tlsRequired, certificate, unsupportedOptions
    var errorDescription: String? {
        switch self {
        case .invalid: return "Invalid profile. Check the server, credentials, and TLS settings."
        case .tooLarge: return "The profile is too large."
        case .unsupported: return "Import a Wayveil profile, not a complete sing-box configuration."
        case .tlsRequired: return "TLS verification is required. Import a profile with the server certificate."
        case .certificate: return "The PEM certificate is invalid."
        case .unsupportedOptions: return "This Hysteria2 link uses unsupported options."
        }
    }
}

struct ConnectionProfile: Codable, Equatable {
    static let maximumLength = 65_536
    var version: Int = 1
    let name: String
    let server: String
    let port: Int
    let password: String
    let obfsPassword: String
    let serverName: String
    let certificate: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, name, server, password, certificate
        case port = "server_port"
        case obfsPassword = "obfs_password"
        case serverName = "server_name"
    }

    static func parse(_ text: String) throws -> ConnectionProfile {
        guard text.count <= maximumLength else { throw ProfileError.tooLarge }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile: ConnectionProfile
        do {
            if input.hasPrefix("{") {
                profile = try parseJSON(Data(input.utf8))
            } else if let uri = URLComponents(string: input), uri.scheme == "wayveil" {
                guard uri.host == "profile", let encoded = uri.queryItems?.first(where: { $0.name == "data" })?.value else { throw ProfileError.invalid }
                var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
                guard let data = Data(base64Encoded: base64) else { throw ProfileError.invalid }
                profile = try parseJSON(data)
            } else if let uri = URLComponents(string: input), ["hy2", "hysteria2"].contains(uri.scheme ?? "") {
                profile = try parseURI(uri)
            } else { throw ProfileError.invalid }
        } catch let error as ProfileError { throw error }
        catch { throw ProfileError.invalid }
        try profile.validate()
        return profile
    }

    private static func parseJSON(_ data: Data) throws -> ConnectionProfile {
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProfileError.invalid }
        guard Set(fields.keys).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else { throw ProfileError.unsupported }
        func isBoolean(_ value: Any?) -> Bool {
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }
        guard fields["version"] == nil || (fields["version"] as? Int == 1 && !isBoolean(fields["version"])) else { throw ProfileError.invalid }
        guard let server = fields["server"] as? String, let password = fields["password"] as? String else { throw ProfileError.invalid }
        let port = fields["server_port"] as? Int ?? 443
        if fields["server_port"] != nil && (isBoolean(fields["server_port"]) || fields["server_port"] as? Int == nil) { throw ProfileError.invalid }
        for key in ["name", "obfs_password", "server_name", "certificate"] where fields[key] != nil && !(fields[key] is String) { throw ProfileError.invalid }
        return ConnectionProfile(name: fields["name"] as? String ?? server, server: server, port: port,
            password: password, obfsPassword: fields["obfs_password"] as? String ?? "",
            serverName: fields["server_name"] as? String ?? server, certificate: fields["certificate"] as? String ?? "")
    }

    private static func parseURI(_ uri: URLComponents) throws -> ConnectionProfile {
        var parameters: [String: String] = [:]
        for item in uri.queryItems ?? [] { parameters[item.name] = item.value ?? "" }
        if let insecure = parameters["insecure"], !["0", "false"].contains(insecure) { throw ProfileError.tlsRequired }
        guard Set(parameters.keys).isSubset(of: ["sni", "obfs", "obfs-password", "insecure"]) else { throw ProfileError.unsupportedOptions }
        guard parameters["obfs"] == nil || parameters["obfs"] == "salamander" else { throw ProfileError.unsupportedOptions }
        if parameters["obfs"] == "salamander" && (parameters["obfs-password"] ?? "").isEmpty { throw ProfileError.invalid }
        if parameters["obfs"] == nil && !(parameters["obfs-password"] ?? "").isEmpty { throw ProfileError.invalid }
        guard let host = uri.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty, let user = uri.user else { throw ProfileError.invalid }
        let password = user + (uri.password.map { ":" + $0 } ?? "")
        return ConnectionProfile(name: uri.fragment.flatMap { $0.isEmpty ? nil : $0 } ?? host, server: host,
            port: uri.port ?? 443, password: password, obfsPassword: parameters["obfs-password"] ?? "",
            serverName: parameters["sni"] ?? host, certificate: "")
    }

    private func validate() throws {
        func validHost(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 253 && !value.contains(where: { $0.isWhitespace || "/@?#".contains($0) })
        }
        guard version == 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              validHost(server), validHost(serverName), (1...65535).contains(port),
              !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProfileError.invalid }
        if !certificate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expression = try NSRegularExpression(pattern: "-----BEGIN CERTIFICATE-----([\\s\\S]*?)-----END CERTIFICATE-----")
            let range = NSRange(certificate.startIndex..., in: certificate)
            let matches = expression.matches(in: certificate, range: range)
            guard !matches.isEmpty, expression.stringByReplacingMatches(in: certificate, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProfileError.certificate }
            for match in matches {
                guard let inner = Range(match.range(at: 1), in: certificate),
                      let data = Data(base64Encoded: String(certificate[inner]).filter { !$0.isWhitespace }),
                      SecCertificateCreateWithData(nil, data as CFData) != nil else { throw ProfileError.certificate }
            }
        }
    }
}
