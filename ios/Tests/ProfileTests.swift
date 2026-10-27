import Foundation
import Darwin
import Libbox
import XCTest

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

    func testStrictTLSAndBothAddressFamilies() throws {
        let profile = try ConnectionProfile.parse(link)
        let config = try object(TunnelConfiguration.make(profile: profile, routing: .all))
        let inbounds = try XCTUnwrap(config["inbounds"] as? [[String: Any]])
        XCTAssertEqual(inbounds[0]["address"] as? [String], ["172.19.0.1/30", "fdfe:dcba:9876::1/126"])
        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        let tls = try XCTUnwrap(outbounds[0]["tls"] as? [String: Any])
        XCTAssertNil(tls["insecure"])
        XCTAssertEqual(tls["server_name"] as? String, "gateway.example.com")
        XCTAssertEqual(outbounds[1]["url"] as? String, "https://1.1.1.1/cdn-cgi/trace")
    }

    func testRussianDomainsUseFakeIPWithoutPublicIPBypass() throws {
        let config = try object(TunnelConfiguration.make(profile: ConnectionProfile.parse(link), routing: .russianDirect))
        let dns = try XCTUnwrap(config["dns"] as? [String: Any])
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        XCTAssertTrue(servers.contains { $0["type"] as? String == "fakeip" })
        let route = try XCTUnwrap(config["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertTrue(rules.contains { $0["domain_suffix"] as? [String] == TunnelConfiguration.russianDomains })
        XCTAssertFalse(rules.contains { $0["ip_cidr"] != nil })
    }

    func testCoreCommandSocketUnderLongContainerPath() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(String(repeating: "container", count: 16))
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousDirectory = files.currentDirectoryPath
        let previousStderr = dup(STDERR_FILENO)
        defer {
            if previousStderr >= 0 { dup2(previousStderr, STDERR_FILENO); close(previousStderr) }
            _ = files.changeCurrentDirectoryPath(previousDirectory)
            try? files.removeItem(at: directory.deletingLastPathComponent())
        }
        let options = LibboxSetupOptions()
        options.basePath = directory.path; options.workingPath = directory.path; options.tempPath = directory.path
        options.crashReportSource = "unit-test"
        var error: NSError?
        XCTAssertTrue(LibboxSetup(options, &error)); XCTAssertNil(error)
        XCTAssertTrue(LibboxCheckConfig(try TunnelConfiguration.make(profile: ConnectionProfile.parse(link), routing: .all), &error))
        XCTAssertNil(error)
        let longServer = try XCTUnwrap(LibboxNewCommandServer(nil, nil, &error))
        XCTAssertNil(error)
        XCTAssertThrowsError(try longServer.start()) { failure in
            XCTAssertTrue(failure.localizedDescription.contains("listen command server"))
        }
        longServer.close()

        XCTAssertTrue(files.changeCurrentDirectoryPath(directory.path))
        options.basePath = "."
        XCTAssertTrue(LibboxSetup(options, &error)); XCTAssertNil(error)
        let relativeServer = try XCTUnwrap(LibboxNewCommandServer(nil, nil, &error))
        defer { relativeServer.close() }
        XCTAssertNil(error)
        try relativeServer.start()
        XCTAssertTrue(files.fileExists(atPath: directory.appendingPathComponent("command.sock").path))
    }

    private func object(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }
}
