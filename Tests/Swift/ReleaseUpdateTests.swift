import Foundation
import XCTest

final class ReleaseUpdateTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/tmp/beavermeter-update-fixture/home", isDirectory: true)

    private var metadata: [String: Any] {
        ["BeaverMeterDirectInstall": "YES", "BeaverMeterUpdatesEnabled": "YES",
         "CFBundleShortVersionString": "5.4.0", "CFBundleVersion": "2026101001",
         "SUFeedURL": ReleaseUpdateConfiguration.feedURL.absoluteString,
         "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString()]
    }

    private func enabled(_ info: [String: Any], identifier: String? = ReleaseUpdateConfiguration.bundleIdentifier,
                         url: URL = URL(fileURLWithPath: "/Applications/BeaverMeter.app"),
                         demo: Bool = false) -> Bool {
        ReleaseUpdateConfiguration.isEnabled(info: info, bundleIdentifier: identifier,
                                             bundleURL: url, isDemo: demo, home: home)
    }

    func testNumericVersionsAndMalformedTags() {
        XCTAssertLessThan(ReleaseVersion("5.9.99")!, ReleaseVersion("v5.10.0")!)
        XCTAssertLessThan(ReleaseVersion("5.99.99")!, ReleaseVersion("6.0.0")!)
        XCTAssertEqual(ReleaseVersion("v0.0.0")?.description, "0.0.0")
        for invalid in ["5.4", "5.4.0-beta.1", "5.4.0+local", "05.4.0", "5.-1.0", "5.4.0.1",
                        "5.4.a", "", "VV5.4.0", " 5.4.0", "5.4.0\n", "５.4.0"] {
            XCTAssertNil(ReleaseVersion(invalid), invalid)
        }
    }

    func testOnlyCanonicalInstalledAppPathsAreEligible() {
        XCTAssertTrue(ReleaseUpdateConfiguration.isCanonicalInstallation(
            URL(fileURLWithPath: "/Applications/BeaverMeter.app"), home: home))
        XCTAssertTrue(ReleaseUpdateConfiguration.isCanonicalInstallation(
            URL(fileURLWithPath: "/Applications/BeaverMeter.app", isDirectory: true), home: home))
        XCTAssertTrue(ReleaseUpdateConfiguration.isCanonicalInstallation(
            home.appendingPathComponent("Applications/BeaverMeter.app"), home: home))
        for path in ["/Volumes/BeaverMeter/BeaverMeter.app",
                     "/private/var/AppTranslocation/XYZ/BeaverMeter.app",
                     "/Applications/BeaverMeter Copy.app",
                     "/tmp/BeaverMeter.app",
                     "/Users/another-user/Applications/BeaverMeter.app"] {
            XCTAssertFalse(ReleaseUpdateConfiguration.isCanonicalInstallation(
                URL(fileURLWithPath: path), home: home), path)
        }
        XCTAssertFalse(ReleaseUpdateConfiguration.isCanonicalInstallation(
            URL(string: "https://example.com/Applications/BeaverMeter.app")!, home: home))
    }

    func testCompleteOfficialMetadataEnablesBothInstallationLocations() {
        XCTAssertTrue(enabled(metadata))
        XCTAssertTrue(enabled(metadata, url: home.appendingPathComponent("Applications/BeaverMeter.app")))
        var booleanFlags = metadata
        booleanFlags["BeaverMeterDirectInstall"] = true
        booleanFlags["BeaverMeterUpdatesEnabled"] = true
        XCTAssertTrue(enabled(booleanFlags))
    }

    func testCanonicalAppSymlinkCannotAuthorizeAnExternalBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtureHome = root.appendingPathComponent("home")
        let applications = fixtureHome.appendingPathComponent("Applications")
        let external = root.appendingPathComponent("mounted/BeaverMeter.app")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let installed = applications.appendingPathComponent("BeaverMeter.app")
        try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: external)
        XCTAssertFalse(ReleaseUpdateConfiguration.isCanonicalInstallation(installed, home: fixtureHome))
        XCTAssertFalse(ReleaseUpdateConfiguration.isCanonicalInstallation(external, home: fixtureHome))
    }

    func testLocalDemoWrongIdentityAndUninstalledCopiesCannotStartUpdater() {
        XCTAssertFalse(enabled(metadata, demo: true))
        XCTAssertFalse(enabled(metadata, identifier: nil))
        XCTAssertFalse(enabled(metadata, identifier: "io.github.fushengji.beavermeter.local"))
        XCTAssertFalse(enabled(metadata, url: URL(fileURLWithPath: "/Volumes/BeaverMeter/BeaverMeter.app")))
        var localBuild = metadata
        localBuild["BeaverMeterUpdatesEnabled"] = "NO"
        XCTAssertFalse(enabled(localBuild), "A source build using the official identity must remain offline.")
        localBuild["BeaverMeterUpdatesEnabled"] = false
        XCTAssertFalse(enabled(localBuild))
        localBuild = metadata
        localBuild["BeaverMeterDirectInstall"] = "NO"
        XCTAssertFalse(enabled(localBuild))
    }

    func testIncompleteOrUntrustedMetadataCannotStartUpdater() {
        for key in metadata.keys {
            var incomplete = metadata
            incomplete.removeValue(forKey: key)
            XCTAssertFalse(enabled(incomplete), key)
        }
        let replacements: [(String, Any)] = [
            ("CFBundleShortVersionString", "unversioned"),
            ("CFBundleVersion", "0"),
            ("CFBundleVersion", "2026.10.10"),
            ("SUFeedURL", "https://example.com/appcast.xml"),
            ("SUPublicEDKey", ""),
            ("SUPublicEDKey", "REPLACE_WITH_PUBLIC_KEY"),
            ("SUPublicEDKey", Data(repeating: 7, count: 31).base64EncodedString())
        ]
        for (key, value) in replacements {
            var invalid = metadata
            invalid[key] = value
            XCTAssertFalse(enabled(invalid), "\(key): \(value)")
        }
    }

    func testBuildIdentityAndReleaseLinks() {
        XCTAssertTrue(ReleaseUpdateConfiguration.isValidBuild("2026101001"))
        for invalid in ["", "0", "001", "-1", "1.0", " 1", "1\n", "１２", "999999999999999999999999999999"] {
            XCTAssertFalse(ReleaseUpdateConfiguration.isValidBuild(invalid), invalid)
        }
        XCTAssertEqual(ReleaseUpdateConfiguration.releaseURL(version: "v5.4.0").absoluteString,
                       "\(ReleaseUpdateConfiguration.repositoryURL)/releases/tag/v5.4.0")
        XCTAssertEqual(ReleaseUpdateConfiguration.releaseURL(version: "invalid").absoluteString,
                       "\(ReleaseUpdateConfiguration.repositoryURL)/releases")
        let update = AvailableUpdate(version: "5.4.0", releaseURL: ReleaseUpdateConfiguration.releaseURL(version: "5.4.0"))
        XCTAssertNil(update.build, "Preview fixtures remain compatible without an internal build.")
        XCTAssertEqual(GitHubRelease.repositoryURL, ReleaseUpdateConfiguration.repositoryURL)
    }
}
