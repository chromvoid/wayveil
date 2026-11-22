import Foundation
import Darwin
import HevSocks5Tunnel
import WayveilCore
import XCTest
import Security
import NetworkExtension

final class ProfileTests: XCTestCase {
    private let link = "hy2://user%3Ap%2Bass@vpn.example.com:8443?sni=gateway.example.com&obfs=salamander&obfs-password=mask%2Bword#Friends"

    func testVPNControlValueMapsEveryStatus() {
        let cases: [(NEVPNStatus?, Bool, String)] = [
            (.connecting, true, "connecting"),
            (.connected, true, "connected"),
            (.reasserting, true, "reconnecting"),
            (.disconnecting, false, "stopping"),
            (.disconnected, false, "disconnected"),
            (.invalid, false, "disconnected"),
            (nil, false, "disconnected")
        ]
        for (status, isOn, statusKey) in cases {
            let value = vpnControlValue(for: status)
            XCTAssertEqual(value.isOn, isOn, String(describing: status))
            XCTAssertEqual(value.statusKey, statusKey, String(describing: status))
        }
    }

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

    func testExportRoundTripsAllFieldsAndMatchesAndroid() throws {
        let basic = ConnectionProfile(name: "My profile", server: "vpn.example.com", port: 443,
            password: "secret", obfsPassword: "", serverName: "vpn.example.com", certificate: "")
        let androidLink = "wayveil://profile?data=eyJ2ZXJzaW9uIjoxLCJuYW1lIjoiTXkgcHJvZmlsZSIsInNlcnZlciI6InZwbi5leGFtcGxlLmNvbSIsInNlcnZlcl9wb3J0Ijo0NDMsInBhc3N3b3JkIjoic2VjcmV0Iiwib2Jmc19wYXNzd29yZCI6IiIsInNlcnZlcl9uYW1lIjoidnBuLmV4YW1wbGUuY29tIiwiY2VydGlmaWNhdGUiOiIifQ"
        XCTAssertEqual(basic.exportLink(), androidLink)
        XCTAssertEqual(try ConnectionProfile.parse(androidLink), basic)
        let certificate = """
        -----BEGIN CERTIFICATE-----
        MIIDXDCCAkSgAwIBAgIUfWyapFXz/KJyvMfPbZ11jrQHnGUwDQYJKoZIhvcNAQEL
        BQAwQDEYMBYGA1UEAwwPdnBuLmV4YW1wbGUuY29tMSQwIgYDVQQKDBtXYXl2ZWls
        IFByb2ZpbGUgRXhwb3J0IFRlc3QwHhcNMjYxMDI5MjIzNjEwWhcNMzYxMDI2MjIz
        NjEwWjBAMRgwFgYDVQQDDA92cG4uZXhhbXBsZS5jb20xJDAiBgNVBAoMG1dheXZl
        aWwgUHJvZmlsZSBFeHBvcnQgVGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCC
        AQoCggEBAMc1Ux/OX4hTevsBafx6OKAYLc78LdyXlnIuy1+tFryCVc862B8xe5O4
        9lG4ZBr1mqt9ml1YHPfGLbPF02zM+8K0mfV5PYL0dqX+l1AHpKif1fnzoYofqriV
        xJfSX0vyaEAZeQTSRcNkO4X3cTIHhJX7Am6FzwTsWIHCSFTWHFsennHWdWgldn32
        rlmNPXvXdYqKmUJXq18yno0RNPSmWueRLhcdKX4ekH5ak8/HplIVnoLNqWxevtDW
        Nz5mwK6Wv5PG5SXELTsshrSp0/+Ecixmw1v0j3LMSQVP4LOSk6F3u6ybSrwout2e
        lMB5KcEJI20j4MdK8EZrw2O0koxbnCECAwEAAaNOMEwwHQYDVR0OBBYEFOj+sUDF
        KaRcDBiVoUJWUFqE2toJMA8GA1UdEwEB/wQFMAMBAf8wGgYDVR0RBBMwEYIPdnBu
        LmV4YW1wbGUuY29tMA0GCSqGSIb3DQEBCwUAA4IBAQA96vunWm2lYQS2Q9DZk9qR
        JZ0/NgzPNJxCYSZ5ikh7AKpRJ5sDR0fLd/gkQ2wzSGvGYBJYimU0AaUnFvvDiFFP
        gz5qkCy1j95l4PXqPr0IXABODJqknlin+jzVJPq+clXFYgo+Z+bOIN6zWgW1vDwH
        lexquLnX93cz3iIKOTzS426f9lgpsyFyDUe8jouc1YeQQ9WjMOb3nCd2bjyfleB0
        f9H0KJjaDdTTK28Y0NwE8zYgYJRjc9ABexT8AlyJbEK+EV36z9JYjsVI4RxCPmRN
        9560sshhaZKGSX0HBTY0QyvQZuu2+tfDjmsIOTny7UXgUQw8qmg1qcgxdyUaPH7n
        -----END CERTIFICATE-----
        """ + "\n"
        let pinned = ConnectionProfile(name: "Мой профиль", server: "vpn.example.com", port: 8443,
            password: "user:p+ass/with=quotes\"\\", obfsPassword: "Salamander+пароль",
            serverName: "gateway.example.com", certificate: certificate)
        for profile in [basic, pinned] {
            let exported = profile.exportLink()
            XCTAssertTrue(exported.hasPrefix("wayveil://profile?data="))
            let data = exported.dropFirst("wayveil://profile?data=".count)
            XCTAssertFalse(data.contains(where: { "=+/".contains($0) }))
            XCTAssertEqual(try ConnectionProfile.parse(exported), profile)
        }
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

    func testCoreAlwaysIncludesBaseRulesWithoutChangingProfile() throws {
        let profile = try ConnectionProfile.parse(link)
        let base = try defaultRoutingDocument()
        let overrides = try RoutingOverrides.empty.adding("https://www.Bank.example:443/help", to: .direct)
            .adding("news.example.ru", to: .proxy)
        let defaultSuffixes: Set<String> = ["ru", "su", "xn--p1ai", "yandex.net", "yastatic.net", "vk.com", "userapi.com", "yandexcloud.net", "emias.info", "sypexgeo.net"]
        for personal in [RoutingOverrides.empty, overrides] {
            let config = try TunnelConfiguration.make(profile: profile, base: base, overrides: personal)
            let envelope = try object(config)
            XCTAssertEqual(envelope["routing"] as? String, "RUSSIAN_DIRECT")
            let encodedProfile = try XCTUnwrap(envelope["profile"] as? [String: Any])
            let restored = try ConnectionProfile.parse(String(decoding: JSONSerialization.data(withJSONObject: encodedProfile), as: UTF8.self))
            XCTAssertEqual(restored, profile)
            let rules = try XCTUnwrap(envelope["rules"] as? [String: Any])
            XCTAssertEqual(Set(try XCTUnwrap(rules["direct_suffix"] as? [String])), defaultSuffixes.union(personal.direct))
            XCTAssertEqual(try XCTUnwrap(rules["direct_domain"] as? [String]), [])
            XCTAssertEqual(try XCTUnwrap(rules["proxy_suffix"] as? [String]), personal.proxy)
            var error: NSError?
            XCTAssertTrue(MobileValidate(config, &error))
            XCTAssertNil(error)
        }
    }

    func testCoreRejectsUnknownRoutingWithoutEchoingCredentials() throws {
        var config = try object(TunnelConfiguration.make(profile: ConnectionProfile.parse(link), base: defaultRoutingDocument()))
        config["routing"] = "UNKNOWN"
        let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        var error: NSError?
        XCTAssertFalse(MobileValidate(json, &error))
        let failure = try XCTUnwrap(error)
        XCTAssertFalse(failure.localizedDescription.contains("user:p+ass"))
        XCTAssertFalse(failure.localizedDescription.contains("mask+word"))
    }

    func testCoreRejectsAnInvalidPinnedCertificate() throws {
        var config = try object(TunnelConfiguration.make(profile: ConnectionProfile.parse(link), base: defaultRoutingDocument()))
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
        #if os(macOS)
        throw XCTSkip("The unsigned, hostless macOS test runner cannot access the shared Data Protection Keychain group.")
        #else
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
        #endif
    }

    func testRoutingMergeMatchesSharedFixtures() throws {
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: routingFixture("merge.json")) as? [[String: Any]])
        for entry in cases {
            let name = try XCTUnwrap(entry["name"] as? String)
            let base = try RoutingDocument.parse(JSONSerialization.data(withJSONObject: XCTUnwrap(entry["base"])))
            let overrides = try RoutingOverrides.parse(JSONSerialization.data(withJSONObject: XCTUnwrap(entry["overrides"])))
            let rules = RoutingRules(base: base, overrides: overrides)
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
          task-stack-size: 86016
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

    func testTunnelLatencyWindowAndSnapshotRoundTrip() throws {
        let started = Date(timeIntervalSince1970: 1_793_347_200)
        var metrics = TunnelMetrics(at: started)
        let empty = metrics.snapshot(downloadMedianBps: 0, downloadPeakBps: 0, engineDownloadBytes: 0, engineUploadBytes: 0, at: started)
        XCTAssertNil(empty.currentLatencyMs)
        XCTAssertNil(empty.medianLatencyMs)
        metrics.recordLatency(24)
        XCTAssertEqual(metrics.snapshot(downloadMedianBps: 0, downloadPeakBps: 0,
            engineDownloadBytes: 0, engineUploadBytes: 0).medianLatencyMs, 24)
        for milliseconds in 1...21 { metrics.recordLatency(Double(milliseconds)) }
        let snapshot = metrics.snapshot(downloadMedianBps: 1_000_000, downloadPeakBps: 2_000_000,
            engineDownloadBytes: 120, engineUploadBytes: 30, at: started.addingTimeInterval(30))
        XCTAssertEqual(snapshot.currentLatencyMs, 21)
        XCTAssertEqual(snapshot.medianLatencyMs, 11.5)
        XCTAssertEqual(snapshot.sessionStartedAt, started)
        XCTAssertEqual(snapshot.downloadMedianBps, 1_000_000)
        XCTAssertEqual(snapshot.downloadPeakBps, 2_000_000)
        XCTAssertEqual(snapshot.engineDownloadBytes, 120)
        XCTAssertEqual(snapshot.engineUploadBytes, 30)
        XCTAssertEqual(try JSONDecoder().decode(TunnelMetricsSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        let later = metrics.snapshot(downloadMedianBps: 0, downloadPeakBps: 0,
            engineDownloadBytes: 2120, engineUploadBytes: 530, at: started.addingTimeInterval(32))
        let speed = try XCTUnwrap(later.liveSpeed(since: snapshot))
        XCTAssertEqual(speed.downloadBps, 1000)
        XCTAssertEqual(speed.uploadBps, 250)
        XCTAssertNil(snapshot.liveSpeed(since: snapshot))
        XCTAssertNil(snapshot.liveSpeed(since: later))
        let reset = metrics.snapshot(downloadMedianBps: 0, downloadPeakBps: 0,
            engineDownloadBytes: 10, engineUploadBytes: 5, at: started.addingTimeInterval(34))
        XCTAssertNil(reset.liveSpeed(since: later))
        let nextSession = TunnelMetrics(at: started.addingTimeInterval(33)).snapshot(downloadMedianBps: 0,
            downloadPeakBps: 0, engineDownloadBytes: 3000, engineUploadBytes: 600, at: started.addingTimeInterval(34))
        XCTAssertNil(nextSession.liveSpeed(since: later))
    }

    func testTunnelTrafficDeltasEngineReplacementAndRestoredTotals() throws {
        let started = Date(timeIntervalSince1970: 1_793_347_200)
        var metrics = TunnelMetrics(at: started)
        metrics.recordTraffic(downloadBytes: 100, uploadBytes: 10, at: started)
        let recordedTotals = metrics.totals
        let live = metrics.snapshot(downloadMedianBps: 0, downloadPeakBps: 0,
            engineDownloadBytes: 150, engineUploadBytes: 30, at: started)
        XCTAssertEqual(live.session, TunnelTraffic(downloadBytes: 150, uploadBytes: 30))
        XCTAssertEqual(live.month, live.session)
        XCTAssertEqual(live.total, live.session)
        XCTAssertEqual(metrics.totals, recordedTotals)
        metrics.recordTraffic(downloadBytes: 150, uploadBytes: 30, at: started)
        let updated = metrics.snapshot(downloadMedianBps: 0, downloadPeakBps: 0,
            engineDownloadBytes: 150, engineUploadBytes: 30, at: started)
        XCTAssertEqual(updated, live)
        XCTAssertEqual(metrics.totals.total, live.total)
        metrics.recordTraffic(downloadBytes: 160, uploadBytes: 55, at: started)
        let reset = metrics.snapshot(downloadMedianBps: 0, downloadPeakBps: 0,
            engineDownloadBytes: 30, engineUploadBytes: 5, at: started)
        XCTAssertEqual(reset.session, TunnelTraffic(downloadBytes: 190, uploadBytes: 60))
        XCTAssertEqual(reset.month, reset.session)
        XCTAssertEqual(reset.total, reset.session)
        metrics.recordTraffic(downloadBytes: 30, uploadBytes: 5, at: started)
        XCTAssertEqual(metrics.totals.total, TunnelTraffic(downloadBytes: 190, uploadBytes: 60))
        metrics.recordTraffic(downloadBytes: 30, uploadBytes: 5, at: started)
        let snapshot = metrics.snapshot(downloadMedianBps: 0, downloadPeakBps: 0, engineDownloadBytes: 30, engineUploadBytes: 5)
        XCTAssertEqual(snapshot.session, TunnelTraffic(downloadBytes: 190, uploadBytes: 60))
        XCTAssertEqual(snapshot.month, snapshot.session)
        let restored = try JSONDecoder().decode(TunnelMetricsTotals.self, from: JSONEncoder().encode(metrics.totals))
        var nextSession = TunnelMetrics(totals: restored, at: started.addingTimeInterval(60))
        nextSession.recordTraffic(downloadBytes: 50, uploadBytes: 10, at: started.addingTimeInterval(90))
        let next = nextSession.snapshot(downloadMedianBps: 0, downloadPeakBps: 0, engineDownloadBytes: 50, engineUploadBytes: 10)
        XCTAssertEqual(next.session, TunnelTraffic(downloadBytes: 50, uploadBytes: 10))
        XCTAssertEqual(next.total, TunnelTraffic(downloadBytes: 240, uploadBytes: 70))
        XCTAssertEqual(next.trackingStartedAt, started)
    }

    func testTunnelTrafficMonthUsesLocalCalendarAndKeepsTotals() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 3 * 60 * 60))
        let formatter = ISO8601DateFormatter()
        let october = try XCTUnwrap(formatter.date(from: "2026-10-31T20:59:59Z"))
        let november = try XCTUnwrap(formatter.date(from: "2026-10-31T21:00:00Z"))
        var metrics = TunnelMetrics(at: october, calendar: calendar)
        metrics.recordTraffic(downloadBytes: 100, uploadBytes: 20, at: october, calendar: calendar)
        let octoberTotals = metrics.totals
        metrics.recordTraffic(downloadBytes: 130, uploadBytes: 27, at: november, calendar: calendar)
        let snapshot = metrics.snapshot(downloadMedianBps: 0, downloadPeakBps: 0, engineDownloadBytes: 130, engineUploadBytes: 27)
        XCTAssertEqual(snapshot.month, TunnelTraffic(downloadBytes: 30, uploadBytes: 7))
        XCTAssertEqual(snapshot.total, TunnelTraffic(downloadBytes: 130, uploadBytes: 27))
        XCTAssertEqual(snapshot.session, snapshot.total)
        XCTAssertEqual(snapshot.monthComponents, calendar.dateComponents([.era, .year, .month], from: november))
        XCTAssertEqual(snapshot.trackingStartedAt, october)
        XCTAssertEqual(snapshot.monthTraffic(at: november, calendar: calendar), snapshot.month)
        let december = try XCTUnwrap(calendar.date(byAdding: .month, value: 1, to: november))
        XCTAssertEqual(snapshot.monthTraffic(at: december, calendar: calendar), TunnelTraffic())
        let restored = TunnelMetrics(totals: octoberTotals, at: november, calendar: calendar)
        XCTAssertEqual(restored.totals.month, TunnelTraffic())
        XCTAssertEqual(restored.totals.total, octoberTotals.total)
        var travelCalendar = calendar
        travelCalendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 2 * 60 * 60))
        let midNovember = try XCTUnwrap(formatter.date(from: "2026-11-15T12:00:00Z"))
        XCTAssertEqual(snapshot.monthTraffic(at: midNovember, calendar: travelCalendar), snapshot.month)
        metrics.recordTraffic(downloadBytes: 140, uploadBytes: 30, at: midNovember, calendar: travelCalendar)
        XCTAssertEqual(metrics.totals.month, TunnelTraffic(downloadBytes: 40, uploadBytes: 10))
    }

    func testTunnelMetricsFormattingUsesLocaleAndRequiredUnits() {
        let russian = Locale(identifier: "ru_RU")
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(TunnelMetricsFormat.bytes(0, locale: russian), "0 Б")
        XCTAssertEqual(TunnelMetricsFormat.bytes(1023, locale: russian), "1023 Б")
        XCTAssertEqual(TunnelMetricsFormat.bytes(1024, locale: russian), "1,0 КБ")
        XCTAssertEqual(TunnelMetricsFormat.bytes(1_048_535, locale: russian), "1,0 МБ")
        XCTAssertEqual(TunnelMetricsFormat.bytes(100 * 1024 * 1024, locale: russian), "100 МБ")
        XCTAssertEqual(TunnelMetricsFormat.bytes(1_288_490_189, locale: russian), "1,2 ГБ")
        XCTAssertEqual(TunnelMetricsFormat.bytes(1_099_511_627_776, locale: english), "1.0 TB")
        XCTAssertEqual(TunnelMetricsFormat.speed(3_925_000, locale: russian), "31,4 Мбит/с")
        XCTAssertEqual(TunnelMetricsFormat.speed(100_000, locale: russian), "800 Кбит/с")
        XCTAssertEqual(TunnelMetricsFormat.speed(124_950_000, locale: russian), "1,0 Гбит/с")
        XCTAssertEqual(TunnelMetricsFormat.speed(125_000_000, locale: english), "1.0 Gbit/s")
        XCTAssertEqual(TunnelMetricsFormat.latency(24, locale: russian), "24 мс")
        XCTAssertEqual(TunnelMetricsFormat.latency(24, locale: english), "24 ms")
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

extension ProfileTests {
    private var invitationToken: String { accessBase64(Data(repeating: 17, count: 32)) }
    private var accessProfile: ConnectionProfile {
        ConnectionProfile(name: "Ready", server: "vpn.example.com", port: 443,
            password: "ticket", obfsPassword: "mask", serverName: "tls.example.com", certificate: "")
    }
    private var accessEndpoints: [[String: Any]] {
        [["id": "hy2", "type": "hysteria2", "server": "vpn.example.com", "server_port": 443,
          "password": "ticket", "extra": ["enabled": true]],
         ["id": "tcp", "type": "vless", "server": "fallback.example.com", "server_port": 8443,
          "password": "fallback-ticket"]]
    }
    private func accessBase64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func accessNodeJSON(id: String = "ready", ready: Bool = true, expiry: Int64 = 2_000_000_600) -> [String: Any] {
        if !ready { return ["id": id, "name": "Pending", "ready": false, "endpoints": accessEndpoints] }
        let claims = accessBase64(Data("{\"exp\":\(expiry)}".utf8))
        return ["id": id, "name": "Ready", "ready": true, "server": accessProfile.server,
                "server_port": accessProfile.port, "server_name": accessProfile.serverName,
                "ticket": "header.\(claims).signature", "obfs_password": accessProfile.obfsPassword,
                "certificate": "", "location": "Amsterdam", "port_mbps": 10000, "endpoints": accessEndpoints]
    }
    private func accessCatalogJSON(device: String = "device-one", expiry: Int64 = 0,
                                   nodes: [[String: Any]]? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["device_id": device,
            "grant": ["label": "Access", "expires_at": expiry], "nodes": nodes ?? [accessNodeJSON()]])
    }

    func testInvitationAcceptsOwnedLinksAndRejectsMalformedInvitations() throws {
        for prefix in ["https://link.chromvoid.com/#", "https://link.chromvoid.com#", "wayveil://invite#"] {
            XCTAssertEqual(try Invitation.parse(" \n" + prefix + invitationToken + "\n "), invitationToken)
            let url = try XCTUnwrap(URL(string: prefix + invitationToken))
            XCTAssertEqual(try Invitation.parse(url.absoluteString), invitationToken)
        }
        let token31 = accessBase64(Data(repeating: 17, count: 31))
        let token33 = accessBase64(Data(repeating: 17, count: 33))
        let invalid = [
            "http://link.chromvoid.com/#" + invitationToken,
            "https://other.example/#" + invitationToken,
            "https://link.chromvoid.com.evil.test/#" + invitationToken,
            "https://link.chromvoid.com@evil.test/#" + invitationToken,
            "https://link.chromvoid.com:443/#" + invitationToken,
            "https://link.chromvoid.com/admin#" + invitationToken,
            "https://link.chromvoid.com/?query#" + invitationToken,
            "wayveil://invite/#" + invitationToken,
            "wayveil://invite?query#" + invitationToken,
            "https://link.chromvoid.com/#short",
            "https://link.chromvoid.com/#" + invitationToken + "A",
            "https://link.chromvoid.com/#" + token31,
            "https://link.chromvoid.com/#" + token33,
            "https://link.chromvoid.com/#" + String(repeating: "!", count: 43),
            String(repeating: " ", count: 2049) + "https://link.chromvoid.com/#" + invitationToken
        ]
        for text in invalid {
            XCTAssertThrowsError(try Invitation.parse(text)) { error in
                XCTAssertEqual((error as? AccessFailure)?.code, "invalid_invitation")
                XCTAssertFalse(error.localizedDescription.contains(self.invitationToken))
            }
        }
        XCTAssertTrue(Invitation.isLink(" https://other.example/ "))
        XCTAssertTrue(Invitation.isLink(" wayveil://invite#invalid "))
        XCTAssertFalse(Invitation.isLink("wayveil://profile?data=value"))
        for code in ["unauthorized", "access_expired", "access_revoked", "access_inactive"] {
            XCTAssertTrue(AccessFailure(code).terminal)
        }
        XCTAssertFalse(AccessFailure("network_error").terminal)
    }
}

extension ProfileTests {
    func testDeviceAccessRoundTripsAndKeepsIdentityAfterEnrollment() throws {
        let pending = try DeviceAccess.pending(invitationToken)
        let restored = try JSONDecoder().decode(DeviceAccess.self, from: JSONEncoder().encode(pending))
        XCTAssertEqual(restored, pending)
        for secret in [restored.installation, restored.token] {
            XCTAssertEqual(secret.count, 43)
            XCTAssertFalse(secret.contains(where: { "+/=".contains($0) }))
            XCTAssertEqual(Data(base64Encoded: secret.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "=")?.count, 32)
        }
        XCTAssertNotEqual(pending.installation, pending.token)
        let enrolled = restored.enrolled("device-one").select("node-one")
        let roundTripped = try JSONDecoder().decode(DeviceAccess.self, from: JSONEncoder().encode(enrolled))
        XCTAssertEqual(roundTripped.invitation, "")
        XCTAssertEqual(roundTripped.device, "device-one")
        XCTAssertEqual(roundTripped.node, "node-one")
        XCTAssertEqual(roundTripped.installation, pending.installation)
        XCTAssertEqual(roundTripped.token, pending.token)
    }

    func testAccessSavedBeforeThePinReadsAsAutoAndPausesOutliveTheirStore() throws {
        let saved = Data(#"{"installation":"installation","token":"token","invitation":"","device":"device-one","node":"nl-01"}"#.utf8)
        let access = try JSONDecoder().decode(DeviceAccess.self, from: saved)
        XCTAssertEqual(access.node, "nl-01")
        XCTAssertFalse(access.pinned)
        XCTAssertEqual(NodeSelection(access), .auto)
        XCTAssertEqual(AccessPresentation(access: access, catalog: nil, phase: .disconnected, error: nil, accessError: nil,
                                          localize: { $0 }).selection, .auto)
        let pinned = try JSONDecoder().decode(DeviceAccess.self, from: JSONEncoder().encode(access.select("us-01")))
        XCTAssertEqual(pinned.node, "us-01")
        XCTAssertEqual(NodeSelection(pinned), .pinned)
        XCTAssertEqual(NodeSelection(pinned.automatic()), .auto)
        XCTAssertEqual(pinned.automatic().node, "us-01")

        XCTAssertNil(NodePauses(read: { Data("damaged".utf8) }, write: { _ in })["nl-01"])

        #if os(macOS)
        throw XCTSkip("The unsigned, hostless macOS test runner cannot access the shared Data Protection Keychain group.")
        #else
        // The pauses go to the shared keychain and come back from it in a new store; the original item is restored.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.chromvoid.vpn.access",
                                    kSecAttrAccount as String: "node_pauses",
                                    kSecAttrAccessGroup as String: AppIdentity.keychainAccessGroup,
                                    kSecAttrSynchronizable as String: false]
        var request = query
        request[kSecReturnData as String] = true
        request[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound, "\(status)")
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
        _ = SecItemDelete(query as CFDictionary)
        let now: TimeInterval = 2_000_000_000
        let pauses = NodePauses.stored()
        XCTAssertNil(pauses["nl-01"])
        pauses.fail("nl-01", now: now)
        pauses.fail("nl-01", now: now)
        pauses.fail("us-01", now: now)
        XCTAssertNotNil(try AccessStore().readNodePauses())
        let restored = NodePauses.stored()
        XCTAssertEqual(restored["nl-01"], NodePause(until: now + 1200, length: 1200))
        XCTAssertTrue(restored.paused("us-01", now: now + 599))
        XCTAssertFalse(restored.paused("us-01", now: now + 600))
        restored.clear("us-01")
        XCTAssertNil(NodePauses.stored()["us-01"])
        XCTAssertNotNil(NodePauses.stored()["nl-01"])
        #endif
    }

    func testCatalogParsesReadyNodesTicketsMetadataAndUnreadyNodes() throws {
        let pending = accessNodeJSON(id: "pending", ready: false)
        let ready = accessNodeJSON()
        let catalog = try NodeCatalog.parse(accessCatalogJSON(nodes: [pending, ready]))
        XCTAssertEqual(catalog.label, "Access")
        XCTAssertEqual(catalog.expiresAt, 0)
        XCTAssertEqual(catalog.device, "device-one")
        XCTAssertEqual(catalog.selected("")?.id, "ready")
        XCTAssertEqual(catalog.selected("removed")?.id, "ready")
        let node = try XCTUnwrap(catalog.selected("ready"))
        XCTAssertEqual(node.expiresAt, 2_000_000_600)
        XCTAssertEqual(node.location, "Amsterdam")
        XCTAssertEqual(node.portMbps, 10000)
        XCTAssertEqual(node.profile?.server, accessProfile.server)
        XCTAssertEqual(node.profile?.password, ready["ticket"] as? String)
        let endpoints = try JSONSerialization.jsonObject(with: JSONEncoder().encode(node.endpoints))
        XCTAssertTrue(try XCTUnwrap(endpoints as? NSArray).isEqual(to: accessEndpoints))
        let unready = try XCTUnwrap(catalog.selected("pending"))
        XCTAssertFalse(unready.ready)
        XCTAssertNil(unready.profile)
        XCTAssertEqual(unready.expiresAt, 0)
        XCTAssertTrue(unready.endpoints.isEmpty)
        XCTAssertNil(try NodeCatalog.parse(accessCatalogJSON(nodes: [pending])).selected(""))
        var minimal = ready
        for key in ["location", "port_mbps", "endpoints"] { minimal.removeValue(forKey: key) }
        let defaults = try XCTUnwrap(NodeCatalog.parse(accessCatalogJSON(nodes: [minimal])).selected("ready"))
        XCTAssertEqual(defaults.location, "")
        XCTAssertEqual(defaults.portMbps, 0)
        XCTAssertTrue(defaults.endpoints.isEmpty)
        XCTAssertThrowsError(try NodeCatalog.parse(accessCatalogJSON(nodes: [ready, ready])))
    }

    func testCachedConnectionAllowsOnlyTransientFailuresForTheSameDevice() {
        let now: Int64 = 2_000_000_000
        let access = DeviceAccess(installation: "installation", token: "token", device: "device-one", node: "ready")
        let node = CatalogNode(id: "ready", name: "Ready", profile: accessProfile, expiresAt: now + 61)
        let catalog = NodeCatalog(label: "Access", expiresAt: 0, nodes: [node], device: "device-one")
        for code in ["network_error", "try_again_later"] {
            XCTAssertEqual(cachedConnection(access: access, catalog: catalog, failure: AccessFailure(code), now: now)?.id, "ready")
        }
        for code in ["unauthorized", "access_expired", "access_revoked", "access_inactive", "activating", "invalid_invitation"] {
            XCTAssertNil(cachedConnection(access: access, catalog: catalog, failure: AccessFailure(code), now: now), code)
        }
        let foreign = NodeCatalog(label: "Access", expiresAt: 0, nodes: [node], device: "another-device")
        XCTAssertNil(cachedConnection(access: access, catalog: foreign, failure: AccessFailure("network_error"), now: now))
        XCTAssertNil(cachedConnection(access: nil, catalog: catalog, failure: AccessFailure("network_error"), now: now))
        XCTAssertNil(cachedConnection(access: access, catalog: nil, failure: AccessFailure("network_error"), now: now))
        XCTAssertNil(cachedConnection(access: DeviceAccess(installation: "pending", token: "token"), catalog: catalog,
                                     failure: AccessFailure("network_error"), now: now))
    }

    func testCachedConnectionRequiresValidTicketGrantAndReadySelection() throws {
        let now: Int64 = 2_000_000_000
        let access = DeviceAccess(installation: "installation", token: "token", device: "device-one", node: "ready")
        func cached(_ ticketExpiry: Int64, grantExpiry: Int64 = 0) -> CatalogNode? {
            let node = CatalogNode(id: "ready", name: "Ready", profile: accessProfile, expiresAt: ticketExpiry)
            return cachedConnection(access: access,
                catalog: NodeCatalog(label: "Access", expiresAt: grantExpiry, nodes: [node], device: "device-one"),
                failure: AccessFailure("network_error"), now: now)
        }
        for expiry in [now - 1, now, now + 59, now + 60] { XCTAssertNil(cached(expiry)) }
        XCTAssertNotNil(cached(now + 61))
        XCTAssertNotNil(cached(now + 61, grantExpiry: now + 1))
        XCTAssertNil(cached(now + 61, grantExpiry: now - 1))
        XCTAssertNil(cached(now + 61, grantExpiry: now))
        let pending = CatalogNode(id: "pending", name: "Pending", profile: nil, expiresAt: 0)
        let first = CatalogNode(id: "first", name: "First", profile: accessProfile, expiresAt: now + 600)
        let second = CatalogNode(id: "second", name: "Second", profile: accessProfile, expiresAt: now + 600)
        let catalog = NodeCatalog(label: "Access", expiresAt: 0, nodes: [pending, first, second], device: "device-one")
        let failure = AccessFailure("network_error")
        XCTAssertEqual(cachedConnection(access: access.select("pending"), catalog: catalog, failure: failure, now: now)?.id, "first")
        XCTAssertEqual(cachedConnection(access: access.select("second"), catalog: catalog, failure: failure, now: now)?.id, "second")
        let pinned = access.select("pending")
        let found = try XCTUnwrap(cachedCandidates(access: pinned, catalog: catalog, failure: failure, now: now))
        let pauses = NodePauses(read: { nil }, write: { _ in })
        let plan = NodeChoice.startPlan(found, pauses: pauses, now: TimeInterval(now))
        XCTAssertEqual(plan.nodes.map(\.id), ["first"])
        for current in [pinned, access.select("second")] {
            let failover = NodeFailover(pauses: pauses)
            failover.catalog(now: 0, found: found)
            var launched: [String] = [], ended = 0
            NodeStarts<String>(plan, failover: failover, pausing: false, wallNow: { TimeInterval(now) },
                network: { true }, allowed: {
                    NodeChoice.startAllowed($0, found: found, pinnedTo: current.node, leaving: false, reconnecting: false)
                }, launch: { attempt, ready, done in
                    guard ready() else { return }
                    launched.append(attempt.node.id)
                    done(attempt.node.id)
                }, take: { _, _ in }, stop: { _ in XCTFail("No catalog change") }, end: { ended += 1 }).run()
            XCTAssertEqual(launched, current == pinned ? ["first"] : [])
            XCTAssertEqual(ended, current == pinned ? 0 : 1)
        }
        XCTAssertNil(cachedConnection(access: access, catalog: NodeCatalog(label: "Access", expiresAt: 0,
            nodes: [pending], device: "device-one"), failure: failure, now: now))
    }

    func testTicketRenewalRequiresANewerTicketWithinFiveMinutes() {
        let now: Int64 = 2_000_000_000
        XCTAssertFalse(shouldRenewTicket(ticketExpiresAt: now + 300, expiresAt: now + 300, now: now))
        XCTAssertFalse(shouldRenewTicket(ticketExpiresAt: now + 300, expiresAt: now + 299, now: now))
        XCTAssertTrue(shouldRenewTicket(ticketExpiresAt: now + 300, expiresAt: now + 301, now: now))
        XCTAssertTrue(shouldRenewTicket(ticketExpiresAt: now - 1, expiresAt: now + 600, now: now))
        XCTAssertFalse(shouldRenewTicket(ticketExpiresAt: now + 301, expiresAt: now + 600, now: now))
    }

    func testManagedConnectionRetriesActivatingAndNetworkErrors() async throws {
        let node = CatalogNode(id: "ready", name: "Ready", profile: accessProfile, expiresAt: 2_000_000_600)
        for code in ["activating", "network_error"] {
            var attempts = 0
            var elapsed: TimeInterval = 0
            var waits: [TimeInterval] = []
            let result = try await awaitManagedConnection(connection: {
                attempts += 1
                if attempts == 1 { throw AccessFailure(code) }
                return node
            }, wait: { duration in waits.append(duration); elapsed += duration }, now: { elapsed })
            XCTAssertEqual(result.id, "ready")
            XCTAssertEqual(attempts, 2)
            XCTAssertEqual(waits, [3])
        }
    }

    func testManagedConnectionDeadlineAndImmediateErrors() async {
        for code in ["activating", "network_error"] {
            var attempts = 0
            var elapsed: TimeInterval = 0
            do {
                _ = try await awaitManagedConnection(connection: {
                    attempts += 1
                    throw AccessFailure(code)
                }, wait: { duration in
                    XCTAssertLessThanOrEqual(duration, 3)
                    elapsed += duration
                }, now: { elapsed })
                XCTFail("The managed connection should reach its deadline.")
            } catch {
                XCTAssertEqual((error as? AccessFailure)?.code, code == "activating" ? "server_not_ready" : code)
            }
            XCTAssertEqual(attempts, 30)
            XCTAssertEqual(elapsed, 90)
        }
        for code in ["access_revoked", "node_unavailable", "try_again_later"] {
            var attempts = 0
            do {
                _ = try await awaitManagedConnection(connection: {
                    attempts += 1
                    throw AccessFailure(code)
                }, wait: { _ in XCTFail("This failure must not be retried.") }, now: { 0 })
                XCTFail("The access failure should propagate.")
            } catch { XCTAssertEqual((error as? AccessFailure)?.code, code) }
            XCTAssertEqual(attempts, 1)
        }
    }

    func testManagedConnectionCancellationInterruptsAnInFlightConnection() async {
        let entered = expectation(description: "The connection request started.")
        let task = Task {
            try await awaitManagedConnection(connection: {
                entered.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
                throw AccessFailure("network_error")
            })
        }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation should interrupt the connection request.")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTunnelConfigurationPreservesEndpoints() throws {
        let profile = accessProfile
        let base = try defaultRoutingDocument()
        let plain = try TunnelConfiguration.make(profile: profile, base: base)
        struct PlainConfiguration: Encodable {
            let profile: ConnectionProfile
            let routing: String
            let rules: RoutingRules
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(PlainConfiguration(profile: profile, routing: "RUSSIAN_DIRECT",
            rules: RoutingRules(base: base, overrides: .empty)))
        XCTAssertEqual(Data(plain.utf8), encoded)
        let empty = try TunnelConfiguration.make(profile: profile, base: base,
            endpoints: [], preferredEndpoint: "tcp")
        XCTAssertEqual(empty, plain)
        let endpoints = try JSONDecoder().decode([JSONValue].self, from: JSONSerialization.data(withJSONObject: accessEndpoints))
        let configured = try TunnelConfiguration.make(profile: profile, base: base,
            endpoints: endpoints, preferredEndpoint: "tcp")
        var expected = try object(plain)
        expected["endpoints"] = accessEndpoints
        expected["preferred_endpoint"] = "tcp"
        XCTAssertTrue(NSDictionary(dictionary: try object(configured)).isEqual(to: expected))
        let withoutPreference = try object(TunnelConfiguration.make(profile: profile, base: base,
            endpoints: endpoints))
        XCTAssertNil(withoutPreference["preferred_endpoint"])
        XCTAssertTrue(try XCTUnwrap(withoutPreference["endpoints"] as? NSArray).isEqual(to: accessEndpoints))
    }
}

private final class MemoryAccessStore: AccessStorage, @unchecked Sendable {
    var access: DeviceAccess?
    var catalog: Data?
    var catalogRemovals = 0
    init(access: DeviceAccess? = nil, catalog: Data? = nil) {
        self.access = access
        self.catalog = catalog
    }
    func readAccess() throws -> DeviceAccess? { access }
    func saveAccess(_ access: DeviceAccess) throws { self.access = access }
    func readCatalog() throws -> Data? { catalog }
    func saveCatalog(_ catalog: Data) throws { self.catalog = catalog }
    func removeCatalog() throws { catalog = nil; catalogRemovals += 1 }
    func removeAccess() throws { access = nil; catalog = nil }
}

private actor AccessTestTransport {
    enum Reply {
        case response(Int, Data)
        case heldResponse(Int, Data, XCTestExpectation)
        case failure(AccessFailure)
    }
    private var replies: [Reply]
    private var heldResponse: CheckedContinuation<Void, Never>?
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw AccessFailure("unexpected_request") }
        switch replies.removeFirst() {
        case .failure(let failure): throw failure
        case .response(let status, let data):
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        case .heldResponse(let status, let data, let started):
            await withCheckedContinuation { continuation in
                heldResponse = continuation
                started.fulfill()
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }
    func release() {
        heldResponse?.resume()
        heldResponse = nil
    }
}

extension ProfileTests {
    private func accessClient(_ transport: AccessTestTransport, version: String? = "1.2.3+test") -> AccessHTTPClient {
        AccessHTTPClient(appVersion: version, transport: { try await transport.send($0) })
    }
    private func expectAccessFailure(_ code: String, operation: () async throws -> Void,
                                     file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected access failure \(code).", file: file, line: line)
        } catch { XCTAssertEqual((error as? AccessFailure)?.code, code, file: file, line: line) }
    }

    func testAccessManagerEnrollsOnceThenRefreshesCatalogAndSelectsReadyNode() async throws {
        let transport = AccessTestTransport([
            .response(200, Data(#"{"device_id":"device-one"}"#.utf8)),
            .response(200, try accessCatalogJSON(nodes: [accessNodeJSON(id: "pending", ready: false), accessNodeJSON()])),
            .response(200, try accessCatalogJSON())
        ])
        let store = MemoryAccessStore()
        let manager = AccessManager(store: store, client: accessClient(transport), now: { 2_000_000_000 })
        let catalog = try await manager.activate("https://link.chromvoid.com/#" + invitationToken)
        XCTAssertEqual(catalog.device, "device-one")
        XCTAssertEqual(store.access?.node, "ready")
        XCTAssertEqual(store.access?.invitation, "")
        _ = try await manager.refresh()
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/devices/enroll", "/v1/catalog", "/v1/catalog"])
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "GET"])
        let enroll = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(enroll["invite_token"] as? String, invitationToken)
        XCTAssertEqual(enroll["api_token"] as? String, store.access?.token)
        XCTAssertEqual(enroll["installation_id"] as? String, store.access?.installation)
        #if os(macOS)
        XCTAssertEqual(enroll["platform"] as? String, "macos")
        XCTAssertTrue(try XCTUnwrap(enroll["name"] as? String).hasPrefix("Mac "))
        #else
        XCTAssertEqual(enroll["platform"] as? String, "ios")
        let name = try XCTUnwrap(enroll["name"] as? String)
        XCTAssertTrue(name.hasPrefix("iPhone ") || name.hasPrefix("iPad "))
        #endif
        XCTAssertLessThanOrEqual(try XCTUnwrap(enroll["name"] as? String).count, 80)
        XCTAssertEqual(enroll["app_version"] as? String, "1.2.3+test")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer " + (store.access?.token ?? ""))
        let state = await manager.state
        XCTAssertEqual(state.catalog?.device, "device-one")
        XCTAssertFalse(state.loading)
        XCTAssertNil(state.error)
    }

    func testAccessManagerLostEnrollmentResponseReusesPendingIdentity() async throws {
        let transport = AccessTestTransport([
            .failure(AccessFailure("network_error")),
            .response(200, Data(#"{"device_id":"device-one"}"#.utf8)),
            .response(200, try accessCatalogJSON())
        ])
        let store = MemoryAccessStore()
        let manager = AccessManager(store: store, client: accessClient(transport))
        let link = "wayveil://invite#" + invitationToken
        await expectAccessFailure("network_error") { _ = try await manager.activate(link) }
        let pending = try XCTUnwrap(store.access)
        XCTAssertEqual(pending.device, "")
        XCTAssertEqual(pending.invitation, invitationToken)
        _ = try await manager.activate(link)
        let requests = await transport.requests
        let first = try object(String(decoding: XCTUnwrap(requests[0].httpBody), as: UTF8.self))
        let second = try object(String(decoding: XCTUnwrap(requests[1].httpBody), as: UTF8.self))
        XCTAssertEqual(first["api_token"] as? String, pending.token)
        XCTAssertEqual(first["api_token"] as? String, second["api_token"] as? String)
        XCTAssertEqual(first["installation_id"] as? String, second["installation_id"] as? String)
        XCTAssertEqual(store.access?.token, pending.token)
        XCTAssertEqual(store.access?.installation, pending.installation)
    }

    func testAccessManagerRejectsAlreadyActivatedAndDifferentPendingInvitation() async throws {
        let otherToken = accessBase64(Data(repeating: 18, count: 32))
        for saved in [DeviceAccess(installation: "installation", token: "token", device: "device-one"),
                      DeviceAccess(installation: "installation", token: "token", invitation: otherToken)] {
            let transport = AccessTestTransport([])
            let manager = AccessManager(store: MemoryAccessStore(access: saved), client: accessClient(transport))
            await expectAccessFailure("already_activated") {
                _ = try await manager.activate("wayveil://invite#" + self.invitationToken)
            }
            let requests = await transport.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testAccessManagerTerminalFailureErasesCatalogAndRejectsForeignStoredCatalog() async throws {
        let access = DeviceAccess(installation: "installation", token: "token", device: "device-one", node: "ready")
        let store = MemoryAccessStore(access: access, catalog: try accessCatalogJSON())
        let transport = AccessTestTransport([.response(403, Data(#"{"error":"access_revoked"}"#.utf8))])
        let manager = AccessManager(store: store, client: accessClient(transport))
        let initial = await manager.state
        XCTAssertNotNil(initial.catalog)
        await expectAccessFailure("access_revoked") { _ = try await manager.refresh() }
        XCTAssertNil(store.catalog)
        XCTAssertEqual(store.catalogRemovals, 1)
        XCTAssertEqual(store.access, access)
        let state = await manager.state
        XCTAssertNil(state.catalog)
        XCTAssertEqual(state.error, "access_revoked")
        XCTAssertFalse(state.loading)
        let foreignStore = MemoryAccessStore(access: access, catalog: try accessCatalogJSON(device: "another-device"))
        let foreignManager = AccessManager(store: foreignStore, client: accessClient(AccessTestTransport([])))
        let foreignState = await foreignManager.state
        XCTAssertNil(foreignState.catalog)
    }

    func testAccessManagerConnectionUsesOnlyFreshCachedTicketsOnNetworkFailure() async throws {
        let now: Int64 = 2_000_000_000
        for expiry in [now + 61, now] {
            let store = MemoryAccessStore(access: DeviceAccess(installation: "installation", token: "token",
                device: "device-one", node: "ready"), catalog: try accessCatalogJSON(nodes: [accessNodeJSON(expiry: expiry)]))
            let manager = AccessManager(store: store,
                client: accessClient(AccessTestTransport([.failure(AccessFailure("network_error"))])), now: { now })
            if expiry > now {
                let found = try await manager.candidates()
                XCTAssertEqual(found.nodes.map(\.id), ["ready"])
                XCTAssertTrue(found.cached)
            } else {
                await expectAccessFailure("network_error") { _ = try await manager.candidates() }
            }
        }
    }

    func testPinnedNodeIsNeverReplacedAndAutoReturns() async throws {
        let now: Int64 = 2_000_000_000
        let data = try accessCatalogJSON(nodes: [accessNodeJSON(id: "slow"), accessNodeJSON(id: "fast")])
        let store = MemoryAccessStore(access: DeviceAccess(installation: "installation", token: "token",
            device: "device-one", node: "fast"), catalog: data)
        let manager = AccessManager(store: store, client: accessClient(AccessTestTransport([
            .response(200, data), .failure(AccessFailure("network_error"))])), now: { now })
        let catalog = try NodeCatalog.parse(data)
        func selection() -> NodeSelection {
            AccessPresentation(access: store.access, catalog: catalog, phase: .disconnected, error: nil,
                               accessError: nil, localize: { $0 }).selection
        }
        XCTAssertEqual(selection(), .auto)
        try await manager.select("slow")
        XCTAssertEqual(store.access?.node, "slow")
        XCTAssertEqual(selection(), .pinned)
        let pauses = NodePauses(read: { nil }, write: { _ in })
        let measurement = NodeMeasurement(latencies: ["slow": 220, "fast": 50])
        let fresh = try await manager.candidates()
        let cached = try await manager.candidates()
        XCTAssertFalse(fresh.cached)
        XCTAssertTrue(cached.cached)
        for found in [fresh, cached] {
            XCTAssertTrue(found.pinned)
            XCTAssertEqual(found.nodes.map(\.id), ["slow"])
            let plan = NodeChoice.startPlan(found, pauses: pauses, now: TimeInterval(now), measurement: measurement)
            XCTAssertEqual(plan.nodes.map(\.id), ["slow"])
            XCTAssertFalse(plan.won)
            XCTAssertTrue(NodeChoice.failoverPlan(found, current: "slow", pauses: pauses, now: TimeInterval(now)).nodes.isEmpty)
        }
        try await manager.saveCurrent("fast")
        XCTAssertEqual(store.access?.node, "slow")
        try await manager.selectAuto()
        XCTAssertEqual(store.access?.node, "slow")
        XCTAssertEqual(selection(), .auto)
        let auto = try XCTUnwrap(cachedCandidates(access: store.access, catalog: catalog,
            failure: AccessFailure("network_error"), now: now))
        XCTAssertEqual(auto.nodes.map(\.id), ["slow", "fast"])
        XCTAssertEqual(NodeChoice.startPlan(auto, pauses: pauses, now: TimeInterval(now), measurement: measurement).nodes.map(\.id),
                       ["fast", "slow"])
        try await manager.saveCurrent("fast")
        XCTAssertEqual(store.access?.node, "fast")
        XCTAssertEqual(selection(), .auto)
    }

    func testFreshCatalogWithoutReadyNodesEmptiesTheQueue() async throws {
        let now: Int64 = 2_000_000_000
        let offered = try accessCatalogJSON(nodes: [accessNodeJSON(id: "nl-01"), accessNodeJSON(id: "us-01")])
        let store = MemoryAccessStore(access: DeviceAccess(installation: "installation", token: "token",
            device: "device-one", node: "nl-01"), catalog: offered)
        let manager = AccessManager(store: store, client: accessClient(AccessTestTransport([
            .response(200, offered), .response(200, try accessCatalogJSON(nodes: []))])), now: { now })
        let failover = NodeFailover(pauses: NodePauses(read: { nil }, write: { _ in }))
        failover.catalog(now: 0, found: try await manager.candidates())
        failover.track(now: 0, node: "nl-01", connected: false, reconnecting: true, network: true)
        XCTAssertTrue(failover.offers("us-01"))
        // Every node was taken off: the controller answered, so the queue empties and the threshold stays 45 s.
        let empty = try await manager.candidates()
        XCTAssertFalse(empty.cached)
        XCTAssertTrue(empty.nodes.isEmpty)
        XCTAssertThrowsError(try empty.startable()) { XCTAssertEqual(($0 as? AccessFailure)?.code, "activating") }
        failover.catalog(now: 10, found: empty)
        XCTAssertFalse(failover.offline)
        XCTAssertFalse(failover.offers("us-01"))
        XCTAssertTrue(NodeChoice.failoverPlan(try XCTUnwrap(failover.found), current: "nl-01",
            pauses: NodePauses(read: { nil }, write: { _ in }), now: TimeInterval(now)).nodes.isEmpty)
        XCTAssertFalse(failover.due(now: 44))
        XCTAssertTrue(failover.due(now: 45))
        // A request without an answer keeps the last candidates.
        failover.catalog(now: 20, found: nil)
        XCTAssertEqual(failover.found, empty)
    }

    func testLateCatalogKeepsTheNodeAConnectionMovedTo() async throws {
        let now: Int64 = 2_000_000_000
        let before = try accessCatalogJSON(nodes: [accessNodeJSON(id: "nl-01")])
        let after = try accessCatalogJSON(nodes: [accessNodeJSON(id: "nl-01"), accessNodeJSON(id: "us-01")])
        let store = MemoryAccessStore(access: DeviceAccess(installation: "installation", token: "token",
            device: "device-one", node: "nl-01"), catalog: before)
        let requested = expectation(description: "The app requested the catalog before us-01 was added")
        let appTransport = AccessTestTransport([.heldResponse(200, before, requested), .response(200, after)])
        let app = AccessManager(store: store, client: accessClient(appTransport), now: { now })
        let tunnel = AccessManager(store: store, client: accessClient(AccessTestTransport([.response(200, after)])), now: { now })
        let refreshing = Task { try await app.refresh() }
        await fulfillment(of: [requested], timeout: 5)
        let found = try await tunnel.candidates()
        XCTAssertEqual(found.nodes.map(\.id), ["nl-01", "us-01"])
        try await tunnel.saveCurrent("us-01")
        await appTransport.release()
        _ = try await refreshing.value
        XCTAssertEqual(store.access?.node, "us-01")
        _ = try await app.refresh()
        XCTAssertEqual(store.access?.node, "us-01")
        XCTAssertEqual(store.access?.pinned, false)
    }

    func testAppShowsTheNodeTheTunnelMovedToFromTheSavedCatalog() throws {
        let app = try NodeCatalog.parse(accessCatalogJSON(nodes: [accessNodeJSON(id: "nl-01")]))
        let store = MemoryAccessStore(access: DeviceAccess(installation: "installation", token: "token",
            device: "device-one", node: "us-01"), catalog: try accessCatalogJSON(nodes: [accessNodeJSON(id: "nl-01"),
            accessNodeJSON(id: "us-01")]))
        // The app's state as VPNController keeps it, on nl-01 before the extension moved.
        var access: DeviceAccess? = store.access?.current("nl-01")
        var catalog: NodeCatalog? = app
        func shown() -> String? {
            AccessPresentation(access: access, catalog: catalog, phase: .connected, error: nil,
                               accessError: nil, localize: { $0 }).selectedNode?.id
        }
        XCTAssertEqual(shown(), "nl-01")
        // The extension moved to us-01, which the app's catalog does not have yet: the catalog it saved shows it.
        AccessPresentation.reload(&access, &catalog, from: store)
        XCTAssertEqual(access?.node, "us-01")
        XCTAssertEqual(catalog?.nodes.map(\.id), ["nl-01", "us-01"])
        XCTAssertEqual(shown(), "us-01")
        // An app catalog that has the node stays.
        let own = try NodeCatalog.parse(accessCatalogJSON(nodes: [accessNodeJSON(id: "us-01")]))
        catalog = own
        AccessPresentation.reload(&access, &catalog, from: store)
        XCTAssertEqual(catalog, own)
        // Only a node the saved catalog lacks too falls back to the first ready one.
        store.catalog = try accessCatalogJSON(nodes: [accessNodeJSON(id: "nl-01")])
        catalog = app
        AccessPresentation.reload(&access, &catalog, from: store)
        XCTAssertEqual(catalog, app)
        XCTAssertEqual(shown(), "nl-01")
    }

    func testAccessManagerRemoveAcceptsUnauthorizedAndErasesBothItems() async throws {
        let store = MemoryAccessStore(access: DeviceAccess(installation: "installation", token: "secret", device: "device-one"),
                                      catalog: try accessCatalogJSON())
        let transport = AccessTestTransport([.response(401, Data(#"{"error":"unauthorized"}"#.utf8))])
        let manager = AccessManager(store: store, client: accessClient(transport))
        try await manager.remove()
        XCTAssertNil(store.access)
        XCTAssertNil(store.catalog)
        let state = await manager.state
        XCTAssertNil(state.catalog)
        XCTAssertNil(state.error)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "DELETE")
        XCTAssertEqual(requests[0].url?.path, "/v1/devices/self")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testAccessManagerRefreshCannotRestoreAccessRemovedByAnotherManager() async throws {
        let access = DeviceAccess(installation: "installation", token: "secret", device: "device-one")
        let store = MemoryAccessStore(access: access, catalog: try accessCatalogJSON())
        let requested = expectation(description: "Catalog requested")
        let transport = AccessTestTransport([.heldResponse(200, try accessCatalogJSON(), requested)])
        let first = AccessManager(store: store, client: accessClient(transport))
        let second = AccessManager(store: store, client: accessClient(AccessTestTransport([.response(204, Data())])))
        let refreshing = Task { try await first.refresh() }
        await fulfillment(of: [requested], timeout: 5)
        try await second.remove()
        await transport.release()
        await expectAccessFailure("unauthorized") { _ = try await refreshing.value }
        XCTAssertNil(store.access)
        XCTAssertNil(store.catalog)
        let state = await first.state
        XCTAssertNil(state.catalog)
        XCTAssertEqual(state.error, "unauthorized")
    }

    func testAccessManagerStaleRefreshPreservesReplacementAccessAndCatalog() async throws {
        for replacement in [DeviceAccess(installation: "replacement", token: "secret", device: "device-two"),
                            DeviceAccess(installation: "installation", token: "new-secret", device: "device-two")] {
            let access = DeviceAccess(installation: "installation", token: "secret", device: "device-one")
            let store = MemoryAccessStore(access: access, catalog: try accessCatalogJSON())
            let requested = expectation(description: "Catalog requested before replacement")
            let transport = AccessTestTransport([.heldResponse(200, try accessCatalogJSON(), requested)])
            let manager = AccessManager(store: store, client: accessClient(transport))
            let refreshing = Task { try await manager.refresh() }
            await fulfillment(of: [requested], timeout: 5)
            let replacementCatalog = try accessCatalogJSON(device: "device-two")
            try store.saveAccess(replacement)
            try store.saveCatalog(replacementCatalog)
            await transport.release()
            await expectAccessFailure("unauthorized") { _ = try await refreshing.value }
            XCTAssertEqual(store.access, replacement)
            XCTAssertEqual(store.catalog, replacementCatalog)
            XCTAssertEqual(store.catalogRemovals, 0)
        }
    }

    func testAccessHTTPClientMapsErrorsEmptyBodiesNoContentAndOversizedResponses() async throws {
        let cases: [(Int, Data, String)] = [
            (403, Data(#"{"error":"access_expired"}"#.utf8), "access_expired"),
            (503, Data(), "network_error"),
            (500, Data(#"{"message":"unavailable"}"#.utf8), "network_error"),
            (200, Data(repeating: 32, count: 256 * 1024 + 1), "network_error")
        ]
        for (status, data, code) in cases {
            let client = accessClient(AccessTestTransport([.response(status, data)]))
            await expectAccessFailure(code) { _ = try await client.request(method: "GET", path: "/v1/catalog") }
        }
        let noContent = accessClient(AccessTestTransport([.response(204, Data())]))
        let data = try await noContent.request(method: "DELETE", path: "/v1/devices/self")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{}")
        let failure = accessClient(AccessTestTransport([.failure(AccessFailure("transport_failure"))]))
        await expectAccessFailure("network_error") { _ = try await failure.request(method: "GET", path: "/v1/catalog") }
    }

    @MainActor
    func testInvitationActivationWaitsForAccessOperationAndAcceptsCompletedEnrollment() async throws {
        for enrollmentCompleted in [false, true] {
            let pending = DeviceAccess(installation: "installation", token: "token", invitation: invitationToken)
            var access: DeviceAccess? = pending
            var loading = true
            var observedLoading = false
            var activationCalls = 0
            var finished = false
            let waiting = expectation(description: "Activation observed the current access operation")
            let activating = Task {
                defer { finished = true }
                try await activateInvitationWhenIdle("wayveil://invite#" + invitationToken, state: {
                    if loading, !observedLoading {
                        observedLoading = true
                        waiting.fulfill()
                    }
                    return (access, loading, .disconnected)
                }, activate: { activationCalls += 1 })
            }
            await fulfillment(of: [waiting], timeout: 5)
            XCTAssertFalse(finished)
            XCTAssertEqual(activationCalls, 0)
            if enrollmentCompleted { access = pending.enrolled("device-one") }
            loading = false
            try await activating.value
            XCTAssertTrue(finished)
            XCTAssertEqual(activationCalls, enrollmentCompleted ? 0 : 1)
        }
    }

    @MainActor
    func testInvitationActivationRequiresDisconnectBeforeAndAfterWaiting() async {
        for startsWhileWaiting in [false, true] {
            var phase: TunnelPhase = startsWhileWaiting ? .disconnected : .connected
            var loading = startsWhileWaiting
            var observedLoading = false
            var activationCalls = 0
            let waiting = startsWhileWaiting ? expectation(description: "Activation is waiting before the tunnel starts") : nil
            let activating = Task {
                try await activateInvitationWhenIdle("wayveil://invite#" + invitationToken, state: {
                    if loading, !observedLoading {
                        observedLoading = true
                        waiting?.fulfill()
                    }
                    return (nil, loading, phase)
                }, activate: { activationCalls += 1 })
            }
            if let waiting {
                await fulfillment(of: [waiting], timeout: 5)
                phase = .connected
                loading = false
            }
            do {
                try await activating.value
                XCTFail("Activation should require disconnecting the tunnel.")
            } catch {
                XCTAssertFalse(error is AccessFailure)
                XCTAssertEqual((error as NSError).localizedDescription, NSLocalizedString("disconnect_first", comment: ""))
            }
            XCTAssertEqual(activationCalls, 0)
        }
    }

    func testAccessPresentationUsesSavedNodeThenCatalogAndConnectionTitle() {
        let access = DeviceAccess(installation: "installation", token: "token", device: "device-one", node: "pending")
        let pending = CatalogNode(id: "pending", name: "Pending", profile: nil, expiresAt: 0)
        let ready = CatalogNode(id: "ready", name: "Amsterdam", profile: accessProfile, expiresAt: 2_000_000_600)
        let catalog = NodeCatalog(label: "Friends", expiresAt: 0, nodes: [ready, pending], device: access.device)
        let selected = AccessPresentation(access: access, catalog: catalog, phase: .disconnected,
                                          error: nil, accessError: nil, localize: { $0 })
        XCTAssertEqual(selected.selectedNode?.id, "pending")
        XCTAssertEqual(selected.title, "Pending")
        XCTAssertEqual(selected.subtitle, "Friends")

        let unselected = AccessPresentation(access: access.select(""),
            catalog: NodeCatalog(label: "Friends", expiresAt: 0, nodes: [pending], device: access.device),
            phase: .disconnected, error: nil, accessError: nil, localize: { $0 })
        XCTAssertEqual(unselected.title, "Friends")
        XCTAssertNil(unselected.subtitle)
        let empty = AccessPresentation(access: access, catalog: nil, phase: .disconnected,
                                       error: nil, accessError: nil, localize: { $0 })
        XCTAssertEqual(empty.title, "connection_title")
        XCTAssertNil(empty.subtitle)
    }

    func testAccessPresentationWaitsOnlyForStoppedManagedConnectionWithoutReadyAccess() {
        let access = DeviceAccess(installation: "installation", token: "token", device: "device-one", node: "ready")
        let ready = CatalogNode(id: "ready", name: "Ready", profile: accessProfile, expiresAt: 2_000_000_600)
        let catalog = NodeCatalog(label: "Friends", expiresAt: 0, nodes: [ready], device: access.device)
        let cases: [(DeviceAccess?, NodeCatalog?, TunnelPhase, String?, Bool)] = [
            (access, nil, .disconnected, nil, true),
            (access, catalog, .disconnected, nil, false),
            (access, catalog, .error, "unauthorized", true),
            (access, catalog, .disconnected, "network_error", false),
            (access, nil, .connecting, "unauthorized", false),
            (access, nil, .connected, nil, false),
            (nil, nil, .disconnected, nil, false)
        ]
        for (access, catalog, phase, code, waiting) in cases {
            let value = AccessPresentation(access: access, catalog: catalog, phase: phase,
                                           error: nil, accessError: code, localize: { $0 })
            XCTAssertEqual(value.waitingForServer, waiting, "\(phase): \(code ?? "none")")
        }
    }

    func testAccessPresentationShowsControllerErrorBeforeLocalizedAccessFailure() {
        let controllerError = AccessPresentation(access: nil, catalog: nil, phase: .error,
            error: "Could not start VPN.", accessError: "unauthorized", localize: { $0 })
        XCTAssertEqual(controllerError.visibleError, "Could not start VPN.")
        let accessError = AccessPresentation(access: nil, catalog: nil, phase: .disconnected,
            error: nil, accessError: "unauthorized", localize: { "localized_" + $0 })
        XCTAssertEqual(accessError.visibleError, "localized_access_revoked")
        for code in [nil, ""] as [String?] {
            XCTAssertNil(AccessPresentation(access: nil, catalog: nil, phase: .disconnected,
                error: nil, accessError: code, localize: { $0 }).visibleError)
        }
    }

    func testCompletedCatalogRefreshReplacesTunnelAccessError() {
        let access = DeviceAccess(installation: "installation", token: "token", device: "device-one", node: "ready")
        let ready = CatalogNode(id: "ready", name: "Ready", profile: accessProfile, expiresAt: 2_000_000_600)
        let catalog = NodeCatalog(label: "Friends", expiresAt: 0, nodes: [ready], device: access.device)
        let cases: [(Bool, String?, String?, String?, Bool)] = [
            (true, nil, nil, nil, false),
            (true, "network_error", "network_error", "access_network_error", false),
            (false, "network_error", "access_expired", "access_expired", true)
        ]
        for (completed, refreshError, expectedCode, visibleError, waiting) in cases {
            let code = AccessPresentation.accessErrorCode(providerError: "access_expired",
                refreshError: refreshError, refreshCompleted: completed)
            XCTAssertEqual(code, expectedCode)
            let value = AccessPresentation(access: access, catalog: catalog, phase: .disconnected,
                error: nil, accessError: code, localize: { $0 })
            XCTAssertEqual(value.visibleError, visibleError)
            XCTAssertEqual(value.waitingForServer, waiting)
        }
    }

    func testAccessPresentationRefreshesEveryMinuteIfAnyNodeIsReadyOtherwiseEveryFiveSeconds() {
        let access = DeviceAccess(installation: "installation", token: "token", device: "device-one", node: "pending")
        let pending = CatalogNode(id: "pending", name: "Pending", profile: nil, expiresAt: 0)
        let ready = CatalogNode(id: "ready", name: "Ready", profile: accessProfile, expiresAt: 2_000_000_600)
        for (nodes, interval) in [([pending], 5.0), ([pending, ready], 60.0)] {
            let catalog = NodeCatalog(label: "Friends", expiresAt: 0, nodes: nodes, device: access.device)
            let value = AccessPresentation(access: access, catalog: catalog, phase: .disconnected,
                                           error: nil, accessError: nil, localize: { $0 })
            XCTAssertEqual(value.refreshInterval, interval)
            XCTAssertTrue(value.waitingForServer)
        }
        XCTAssertEqual(AccessPresentation(access: access, catalog: nil, phase: .disconnected,
            error: nil, accessError: nil).refreshInterval, 5)
    }

    func testAccessHTTPClientSetsOnlyValidVersionAndRequestHeaders() async throws {
        for version in ["1.2.3+test", "invalid version", String(repeating: "x", count: 33), ""] {
            let transport = AccessTestTransport([.response(200, Data("{}".utf8))])
            let client = accessClient(transport, version: version)
            _ = try await client.request(method: "POST", path: "/v1/devices/enroll", token: "secret", body: Data("{}".utf8))
            let requests = await transport.requests
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.url?.absoluteString, "https://link.chromvoid.com/v1/devices/enroll")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Wayveil-App-Version"), version == "1.2.3+test" ? version : nil)
            XCTAssertEqual(request.timeoutInterval, 10)
        }
    }
}
