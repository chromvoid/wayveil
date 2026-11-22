import Foundation
import XCTest

final class AppUpdateCheckTests: XCTestCase {
    func testNumericVersionComparison() {
        XCTAssertTrue(AppUpdateCheck.isNewer("0.1.1", than: "0.1.0"))
        XCTAssertTrue(AppUpdateCheck.isNewer("0.1.10", than: "0.1.9"))
        XCTAssertFalse(AppUpdateCheck.isNewer("0.2", than: "0.2.0"))
        XCTAssertFalse(AppUpdateCheck.isNewer("0.2.0", than: "0.2"))
        XCTAssertTrue(AppUpdateCheck.isNewer("1.0", than: "0.9"))
        XCTAssertFalse(AppUpdateCheck.isNewer("0.9", than: "1.0"))
    }

    func testInvalidVersionsAreNotNewer() {
        for version in ["", "latest", "1.a", "1..2", "1.0beta", "-1.0", "+1.0"] {
            XCTAssertFalse(AppUpdateCheck.isNewer(version, than: "0.1.0"), version)
            XCTAssertFalse(AppUpdateCheck.isNewer("1.0", than: version), version)
        }
    }

    func testParseLookupResponse() throws {
        let data = Data(#"{"resultCount":1,"results":[{"version":"0.1.10","minimumOsVersion":"16.0","trackId":6827036420}]}"#.utf8)
        let version = try XCTUnwrap(AppStoreVersion.parse(data))
        XCTAssertEqual(version.version, "0.1.10")
        XCTAssertEqual(version.minimumOsVersion, "16.0")
        let withoutMinimumOS = try XCTUnwrap(AppStoreVersion.parse(Data(#"{"results":[{"version":"0.2"}]}"#.utf8)))
        XCTAssertNil(withoutMinimumOS.minimumOsVersion)
    }

    func testEmptyLookupReturnsNoData() throws {
        XCTAssertNil(try AppStoreVersion.parse(Data(#"{"resultCount":0,"results":[]}"#.utf8)))
    }

    func testMissingVersionAndMalformedJSONFail() {
        XCTAssertThrowsError(try AppStoreVersion.parse(Data(#"{"results":[{"minimumOsVersion":"16.0"}]}"#.utf8)))
        XCTAssertThrowsError(try AppStoreVersion.parse(Data("invalid JSON".utf8)))
    }

    func testAvailabilityRequiresNewerCompatibleVersion() {
        let compatible = AppStoreVersion(version: "0.1.1", minimumOsVersion: "16.0")
        XCTAssertTrue(compatible.isUpdateAvailable(currentVersion: "0.1.0", systemVersion: "17.0"))
        XCTAssertTrue(compatible.isUpdateAvailable(currentVersion: "0.1.0", systemVersion: "16"))
        XCTAssertFalse(compatible.isUpdateAvailable(currentVersion: "0.1.1", systemVersion: "17.0"))
        XCTAssertFalse(compatible.isUpdateAvailable(currentVersion: "0.2", systemVersion: "17.0"))
        XCTAssertFalse(compatible.isUpdateAvailable(currentVersion: "0.1.0", systemVersion: "15.9"))
        XCTAssertTrue(AppStoreVersion(version: "0.2", minimumOsVersion: nil)
            .isUpdateAvailable(currentVersion: "0.1.0", systemVersion: "16.0"))
        XCTAssertFalse(AppStoreVersion(version: "garbage", minimumOsVersion: nil)
            .isUpdateAvailable(currentVersion: "0.1.0", systemVersion: "16.0"))
        XCTAssertFalse(AppStoreVersion(version: "0.2", minimumOsVersion: "garbage")
            .isUpdateAvailable(currentVersion: "0.1.0", systemVersion: "16.0"))
    }

    func testStorefrontCountryOrder() {
        XCTAssertEqual(AppUpdateCheck.countries(for: "RUS"), ["ru"])
        XCTAssertEqual(AppUpdateCheck.countries(for: "ARM"), ["am"])
        XCTAssertEqual(AppUpdateCheck.countries(for: "NLD"), ["nl"])
        XCTAssertEqual(AppUpdateCheck.countries(for: "USA"), ["ru", "am", "nl"])
        XCTAssertEqual(AppUpdateCheck.countries(for: nil), ["ru", "am", "nl"])
    }
}
