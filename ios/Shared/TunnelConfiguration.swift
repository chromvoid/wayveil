import Foundation

enum TunnelConfiguration {
    static let russianDomains = ["ru", "su", "xn--p1ai", "yandex.net", "yastatic.net", "vk.com", "userapi.com"]

    static func make(profile: ConnectionProfile, routing: RoutingMode) throws -> String {
        func dns(_ tag: String, _ detour: String) -> [String: Any] {
            ["type": "https", "tag": tag, "server": "1.1.1.1", "detour": detour,
             "tls": ["enabled": true, "server_name": "cloudflare-dns.com"]]
        }
        var servers = [dns("remote-dns", "proxy"), dns("direct-dns", "direct")]
        var dnsRules: [[String: Any]] = []
        var rules: [[String: Any]] = [["action": "sniff"], ["protocol": "dns", "action": "hijack-dns"], ["ip_is_private": true, "outbound": "direct"]]
        if routing == .russianDirect {
            servers.append(["type": "fakeip", "tag": "ru-fakeip", "inet4_range": "198.18.0.0/15", "inet6_range": "fc00::/18"])
            dnsRules.append(["domain_suffix": russianDomains, "server": "ru-fakeip"])
            rules.append(["domain_suffix": russianDomains, "outbound": "direct"])
        }
        var tls: [String: Any] = ["enabled": true, "server_name": profile.serverName, "alpn": ["h3"]]
        if !profile.certificate.isEmpty { tls["certificate"] = [profile.certificate] }
        var proxy: [String: Any] = ["type": "hysteria2", "tag": "tunnel", "server": profile.server,
            "server_port": profile.port, "password": profile.password, "tls": tls]
        if !profile.obfsPassword.isEmpty { proxy["obfs"] = ["type": "salamander", "password": profile.obfsPassword] }
        let config: [String: Any] = [
            "log": ["disabled": true],
            "dns": ["servers": servers, "rules": dnsRules, "final": "remote-dns", "strategy": "ipv4_only"],
            "inbounds": [["type": "tun", "tag": "vpn", "mtu": 1400,
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"], "auto_route": true, "strict_route": true, "stack": "mixed"]],
            "outbounds": [proxy,
                ["type": "urltest", "tag": "proxy", "outbounds": ["tunnel"], "url": "https://1.1.1.1/cdn-cgi/trace", "interval": "30s"],
                ["type": "direct", "tag": "direct", "domain_resolver": "direct-dns"]],
            "route": ["auto_detect_interface": true, "default_domain_resolver": "direct-dns", "final": "proxy", "rules": rules]
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]), as: UTF8.self)
    }
}
