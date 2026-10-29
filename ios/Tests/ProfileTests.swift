import Foundation
import Darwin
import HevSocks5Tunnel
import WayveilCore
import XCTest
import Security

final class ProfileTests: XCTestCase {
    private let link = "hy2://user%3Ap%2Bass@vpn.example.com:8443?sni=gateway.example.com&obfs=salamander&obfs-password=mask%2Bword#Friends"

    func testHysteriaAuthenticationAndObfuscation() throws {
        let profile = try ConnectionProfile.parse(link)
        XCTAssertEqual(profile.password, "user:p+ass")
        XCTAssertEqual(profile.obfsPassword, "mask+word")
        XCTAssertEqual(profile.port, 8443)
        XCTAssertEqual(profile.name, "Friends")
    }

    func testJSONAndLegacyLinksRoundTrip() throws {
        let expected = try ConnectionProfile.parse(link)
        let json = try JSONEncoder().encode(expected)
        XCTAssertEqual(try ConnectionProfile.parse(String(decoding: json, as: UTF8.self)), expected)
        let base64 = json.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(try ConnectionProfile.parse("wayveil://profile?data=" + base64), expected)
    }

    func testUnsafeAndUnsupportedOptionsFailWithoutEchoingSecrets() {
        for suffix in ["insecure=1", "pinSHA256=private-value", "obfs=gecko"] {
            XCTAssertThrowsError(try ConnectionProfile.parse("hy2://secret-password@vpn.example.com?" + suffix)) { error in
                XCTAssertFalse(error.localizedDescription.contains("secret-password"))
                XCTAssertFalse(error.localizedDescription.contains("private-value"))
            }
        }
    }

    func testMalformedAndOversizedProfiles() {
        XCTAssertThrowsError(try ConnectionProfile.parse(String(repeating: "x", count: 65_537)))
        XCTAssertThrowsError(try ConnectionProfile.parse("{}"))
        XCTAssertThrowsError(try ConnectionProfile.parse("{\"server\":\"vpn.example.com\",\"password\":\"pw\",\"server_port\":true}"))
        XCTAssertThrowsError(try ConnectionProfile.parse("{\"server\":\"vpn.example.com\",\"password\":\"pw\",\"version\":true}"))
    }

    func testCoreAcceptsBothRoutingModesWithoutChangingProfile() throws {
        let profile = try ConnectionProfile.parse(link)
        let base = try defaultRoutingDocument()
        let overrides = try RoutingOverrides.empty.adding("https://www.Bank.example:443/help", to: .direct)
        let defaultSuffixes: Set<String> = ["ru", "su", "xn--p1ai", "yandex.net", "yastatic.net", "vk.com", "userapi.com"]
        for routing in RoutingMode.allCases {
            for personal in [RoutingOverrides.empty, overrides] {
                let config = try TunnelConfiguration.make(profile: profile, routing: routing, base: base, overrides: personal)
                let envelope = try object(config)
                let encodedProfile = try XCTUnwrap(envelope["profile"] as? [String: Any])
                let restored = try ConnectionProfile.parse(String(decoding: JSONSerialization.data(withJSONObject: encodedProfile), as: UTF8.self))
                XCTAssertEqual(restored, profile)
                let rules = try XCTUnwrap(envelope["rules"] as? [String: Any])
                let expectedSuffixes = (routing == .russianDirect ? defaultSuffixes : []).union(personal.direct)
                XCTAssertEqual(Set(try XCTUnwrap(rules["direct_suffix"] as? [String])), expectedSuffixes)
                XCTAssertEqual(try XCTUnwrap(rules["direct_domain"] as? [String]), [])
                XCTAssertEqual(try XCTUnwrap(rules["proxy_suffix"] as? [String]), [])
                var error: NSError?
                XCTAssertTrue(MobileValidate(config, &error))
                XCTAssertNil(error)
            }
        }
    }

    func testCoreRejectsUnknownRoutingWithoutEchoingCredentials() throws {
        var config = try object(TunnelConfiguration.make(profile: ConnectionProfile.parse(link), routing: .all, base: defaultRoutingDocument()))
        config["routing"] = "UNKNOWN"
        let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        var error: NSError?
        XCTAssertFalse(MobileValidate(json, &error))
        let failure = try XCTUnwrap(error)
        XCTAssertFalse(failure.localizedDescription.contains("user:p+ass"))
        XCTAssertFalse(failure.localizedDescription.contains("mask+word"))
    }

    func testCoreRejectsAnInvalidPinnedCertificate() throws {
        var config = try object(TunnelConfiguration.make(profile: ConnectionProfile.parse(link), routing: .all, base: defaultRoutingDocument()))
        var profile = try XCTUnwrap(config["profile"] as? [String: Any])
        profile["certificate"] = "invalid-certificate"
        config["profile"] = profile
        let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        var error: NSError?
        XCTAssertFalse(MobileValidate(json, &error))
        XCTAssertNotNil(error)
    }

    func testRoutingDocumentsMatchSharedFixtures() throws {
        try validateRoutingFixtures("documents") { _ = try RoutingDocument.parse($0) }
    }

    func testRoutingOverridesMatchSharedFixtures() throws {
        try validateRoutingFixtures("overrides") { _ = try RoutingOverrides.parse($0) }
    }

    func testRoutingInputMatchesSharedFixtures() throws {
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: routingFixture("input.json")) as? [[String: Any]])
        for entry in cases {
            let name = try XCTUnwrap(entry["name"] as? String)
            let input = try XCTUnwrap(entry["input"] as? String)
            if let expected = entry["expected"] as? String {
                XCTAssertEqual(try RoutingRules.normalizeInput(input), expected, name)
            } else {
                XCTAssertThrowsError(try RoutingRules.normalizeInput(input), name)
            }
        }
        for input in ["https://user:password@www.ПРИМЕР.РФ:8443/help?next=https://example.com#section",
                      "user:password@www.ПРИМЕР.РФ:443/help",
                      "ПРИМЕР.РФ/help?next=https://example.com"] {
            XCTAssertEqual(try RoutingRules.normalizeInput(input), "xn--e1afmkfd.xn--p1ai", input)
        }
    }

    func testOverrideErrorsHaveLocalizedMessages() throws {
        let cases: [(Error, String)] = [
            (RoutingRuleError.formatUnsupported, "overrides_invalid_address"),
            (RoutingRuleError.invalidDocument, "overrides_invalid_address"),
            (RoutingRuleError.invalidVersion, "overrides_invalid_address"),
            (RoutingRuleError.invalidCategory, "overrides_invalid_address"),
            (RoutingRuleError.invalidDomain, "overrides_invalid_address"),
            (RoutingRuleError.tldNotAllowed, "overrides_invalid_address"),
            (RoutingRuleError.tooLarge, "overrides_invalid_address"),
            (RoutingRuleError.nameInOtherList, "overrides_other_list"),
            (RoutingRuleError.duplicateEntry, "overrides_duplicate"),
            (RoutingRuleError.tooManyEntries, "overrides_limit"),
            (NSError(domain: "Wayveil", code: 2), "overrides_save_failed"),
            (RoutingOverrideStoreError.damaged, "overrides_damaged")
        ]
        let appDirectory = routingDirectory.deletingLastPathComponent().appendingPathComponent("ios/App/Resources")
        for language in ["ru", "en"] {
            let data = try Data(contentsOf: appDirectory.appendingPathComponent("\(language).lproj/Localizable.strings"))
            let strings = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            for (error, key) in cases {
                XCTAssertEqual(RoutingOverrideStore.errorKey(error), key)
                XCTAssertFalse(try XCTUnwrap(strings[key], "\(language): \(key)").isEmpty)
            }
        }
    }

    func testOverrideStoreReportsDamagedItemBeforeAdding() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "com.chromvoid.vpn.routing-overrides",
                                   kSecAttrAccount as String: "overrides",
                                   kSecAttrAccessGroup as String: AppIdentity.keychainAccessGroup,
                                   kSecAttrSynchronizable as String: false]
        var request = query
        request[kSecReturnData as String] = true
        request[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            XCTFail("Could not read the original routing exceptions: \(status).")
            return
        }
        let original: [String: Any]? = status == errSecSuccess ? try XCTUnwrap(result as? [String: Any]) : nil
        defer {
            let status = SecItemDelete(query as CFDictionary)
            XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound)
            if let original {
                var restored = query
                restored[kSecValueData as String] = original[kSecValueData as String]
                restored[kSecAttrAccessible as String] = original[kSecAttrAccessible as String]
                XCTAssertEqual(SecItemAdd(restored as CFDictionary, nil), errSecSuccess)
            }
        }
        try RoutingOverrideStore.remove()
        var item = query
        item[kSecValueData as String] = Data(#"{"format":1,"direct":["a.example","a.example"],"proxy":[]}"#.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        XCTAssertThrowsError(try RoutingOverrideStore.add("new.example", to: .direct)) { error in
            XCTAssertTrue(error is RoutingOverrideStoreError)
            XCTAssertEqual(RoutingOverrideStore.errorKey(error), "overrides_damaged")
        }
        XCTAssertThrowsError(try RoutingOverrideStore.remove("a.example", from: .direct)) { error in
            XCTAssertTrue(error is RoutingOverrideStoreError)
        }
        try RoutingOverrideStore.remove()
        XCTAssertEqual(try RoutingOverrideStore.read(), .empty)
        XCTAssertEqual(try RoutingOverrideStore.add("https://www.Gosuslugi.ru/help", to: .direct).direct, ["gosuslugi.ru"])
    }

    func testRoutingMergeMatchesSharedFixtures() throws {
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: routingFixture("merge.json")) as? [[String: Any]])
        for entry in cases {
            let name = try XCTUnwrap(entry["name"] as? String)
            let routing = try XCTUnwrap(RoutingMode(rawValue: XCTUnwrap(entry["routing"] as? String)))
            let base = try RoutingDocument.parse(JSONSerialization.data(withJSONObject: XCTUnwrap(entry["base"])))
            let overrides = try RoutingOverrides.parse(JSONSerialization.data(withJSONObject: XCTUnwrap(entry["overrides"])))
            let rules = RoutingRules(routing: routing, base: base, overrides: overrides)
            let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rules)) as? [String: [String]])
            let expected = try XCTUnwrap(entry["expected"] as? [String: [String]])
            XCTAssertEqual(Set(actual.keys), Set(expected.keys), name)
            for (key, values) in expected {
                let names = try XCTUnwrap(actual[key], name)
                XCTAssertEqual(Set(names), Set(values), "\(name): \(key)")
                XCTAssertEqual(names.count, Set(names).count, "\(name): \(key)")
            }
        }
    }

    func testPersonalOverrideChangesKeepDistinctErrorsAndRoundTrip() throws {
        let overrides = try RoutingOverrides.empty.adding("https://www.Example.com/help", to: .direct)
        XCTAssertEqual(overrides.direct, ["example.com"])
        XCTAssertEqual(try RoutingOverrides.parse(JSONEncoder().encode(overrides)), overrides)
        for (input, list, code) in [("invalid_name.example", RoutingOverrides.List.direct, "invalid_domain"),
                                    ("www.Example.com", .direct, "duplicate_entry"),
                                    ("example.com", .proxy, "name_in_other_list")] {
            XCTAssertThrowsError(try overrides.adding(input, to: list)) { error in
                XCTAssertEqual((error as? RoutingRuleError)?.rawValue, code)
            }
        }
        let full = try RoutingOverrides.parse(routingFixture("overrides/valid/max-entries.json"))
        XCTAssertThrowsError(try full.adding("new.example", to: .direct)) { error in
            XCTAssertEqual((error as? RoutingRuleError)?.rawValue, "too_many_entries")
        }
        XCTAssertEqual(overrides.removing("example.com", from: .direct), .empty)
    }

    func testHEVEarlyStopAndRestartPreserveBorrowedDescriptors() throws {
        let configuration = """
        tunnel:
          mtu: 1400
          ipv4: 172.19.0.1
          ipv6: 'fdfe:dcba:9876::1'
        socks5:
          address: 127.0.0.1
          port: 1
          udp: 'udp'
        misc:
          log-file: '/dev/null'
          task-stack-size: 24576
          tcp-buffer-size: 4096
          max-session-count: 16
        """
        for _ in 0..<5 {
            var descriptors: [Int32] = [-1, -1]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors), 0)
            guard descriptors.allSatisfy({ $0 >= 0 }) else { return }
            let finished = DispatchGroup()
            let descriptor = descriptors[1]
            let bridgeDescriptor = descriptors[0]
            hev_socks5_tunnel_reset()
            finished.enter()
            DispatchQueue.global().async {
                let result = Array(configuration.utf8).withUnsafeBufferPointer {
                    hev_socks5_tunnel_main_from_str($0.baseAddress, UInt32($0.count), descriptor)
                }
                XCTAssertEqual(result, 0)
                XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0)
                Darwin.close(descriptor)
                Darwin.close(bridgeDescriptor)
                finished.leave()
            }
            hev_socks5_tunnel_quit()
            guard finished.wait(timeout: .now() + 5) == .success else {
                XCTFail("HEV did not stop after an early cancellation.")
                return
            }
        }
    }

    private func object(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    private var routingDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("routing")
    }

    private func routingFixture(_ path: String) throws -> Data {
        try Data(contentsOf: routingDirectory.appendingPathComponent("testdata").appendingPathComponent(path))
    }

    private func defaultRoutingDocument() throws -> RoutingDocument {
        try RoutingDocument.parse(Data(contentsOf: routingDirectory.appendingPathComponent("default-rules.json")))
    }

    private func validateRoutingFixtures(_ directory: String, parse: (Data) throws -> Void) throws {
        for validity in ["valid", "invalid"] {
            let location = routingDirectory.appendingPathComponent("testdata/\(directory)/\(validity)")
            let fixtures = try FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            XCTAssertFalse(fixtures.isEmpty)
            for fixture in fixtures {
                let data = try Data(contentsOf: fixture)
                if validity == "valid" {
                    XCTAssertNoThrow(try parse(data), fixture.lastPathComponent)
                } else {
                    let expected = try String(contentsOf: fixture.deletingPathExtension().appendingPathExtension("error"), encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    XCTAssertThrowsError(try parse(data), fixture.lastPathComponent) { error in
                        XCTAssertEqual((error as? RoutingRuleError)?.rawValue, expected, fixture.lastPathComponent)
                    }
                }
            }
        }
    }
}
