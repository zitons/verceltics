import XCTest
@testable import verceltics

/// Update checks without the App Store, as in UI tests. Hosted unit tests never
/// configure the App Store update checker in the app process.
@MainActor
final class StoreServicesIsolationTests: XCTestCase {
    func testDisabledUpdateCheckNeverContactsTheAppStore() async {
        let checker = AppUpdateChecker()
        checker.checksAppStore = false

        await checker.checkForUpdates(force: true)

        XCTAssertFalse(checker.hasChecked)
        XCTAssertFalse(checker.isChecking)
        XCTAssertNil(checker.latestVersion)
        XCTAssertNil(checker.errorMessage)
    }

    func testUpdateAvailabilityComparesVersionsNumerically() throws {
        let checker = AppUpdateChecker()
        checker.checksAppStore = false
        let current = checker.currentVersion
        var parts = current.split(separator: ".").compactMap { Int($0) }
        let last = try XCTUnwrap(parts.popLast(), "current version \(current) is not numeric")
        let prefix = parts.map(String.init)

        checker.latestVersion = (prefix + ["\(last + 9)"]).joined(separator: ".")
        XCTAssertTrue(checker.isUpdateAvailable, "\(checker.latestVersion ?? "") is newer than \(current)")

        checker.latestVersion = "\(current).1"
        XCTAssertTrue(checker.isUpdateAvailable)

        checker.latestVersion = current
        XCTAssertFalse(checker.isUpdateAvailable)

        checker.latestVersion = "\(current).0"
        XCTAssertFalse(checker.isUpdateAvailable, "a trailing .0 is the same version")

        checker.latestVersion = "0.1"
        XCTAssertFalse(checker.isUpdateAvailable)

        checker.latestVersion = nil
        XCTAssertFalse(checker.isUpdateAvailable)
    }
}
