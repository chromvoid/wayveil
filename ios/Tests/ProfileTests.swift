import Foundation
import Darwin
import HevSocks5Tunnel
import WayveilCore
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

    func testCoreAcceptsBothRoutingModesWithoutChangingProfile() throws {
        let profile = try ConnectionProfile.parse(link)
        for routing in RoutingMode.allCases {
            let config = try TunnelConfiguration.make(profile: profile, routing: routing)
            let envelope = try object(config)
            let encodedProfile = try XCTUnwrap(envelope["profile"] as? [String: Any])
            let restored = try ConnectionProfile.parse(String(decoding: JSONSerialization.data(withJSONObject: encodedProfile), as: UTF8.self))
            XCTAssertEqual(restored, profile)
            var error: NSError?
            XCTAssertTrue(MobileValidate(config, &error))
            XCTAssertNil(error)
        }
    }

    func testCoreRejectsUnknownRoutingWithoutEchoingCredentials() throws {
        var config = try object(TunnelConfiguration.make(profile: ConnectionProfile.parse(link), routing: .all))
        config["routing"] = "UNKNOWN"
        let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        var error: NSError?
        XCTAssertFalse(MobileValidate(json, &error))
        let failure = try XCTUnwrap(error)
        XCTAssertFalse(failure.localizedDescription.contains("user:p+ass"))
        XCTAssertFalse(failure.localizedDescription.contains("mask+word"))
    }

    func testCoreRejectsAnInvalidPinnedCertificate() throws {
        var config = try object(TunnelConfiguration.make(profile: ConnectionProfile.parse(link), routing: .all))
        var profile = try XCTUnwrap(config["profile"] as? [String: Any])
        profile["certificate"] = "invalid-certificate"
        config["profile"] = profile
        let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        var error: NSError?
        XCTAssertFalse(MobileValidate(json, &error))
        XCTAssertNotNil(error)
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
}
