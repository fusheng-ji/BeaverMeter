import Foundation

struct ReleaseVersion: Comparable, Codable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && ($0.count == 1 || $0.first != "0")
                  && $0.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String { "\(major).\(minor).\(patch)" }
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct AvailableUpdate: Equatable, Sendable {
    let version: String
    let releaseURL: URL
    let build: String?

    init(version: String, releaseURL: URL, build: String? = nil) {
        self.version = version
        self.releaseURL = releaseURL
        self.build = build
    }
}

enum ReleaseUpdateConfiguration {
    static let repositoryURL = "https://github.com/fusheng-ji/BeaverMeter"
    static let bundleIdentifier = "io.github.fushengji.beavermeter"
    static let feedURL = URL(string: "\(repositoryURL)/releases/latest/download/appcast.xml")!

    static func isCanonicalInstallation(_ url: URL,
                                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard url.isFileURL else { return false }
        let installed = url.standardizedFileURL.resolvingSymlinksInPath()
        return [URL(fileURLWithPath: "/Applications", isDirectory: true),
                home.appendingPathComponent("Applications", isDirectory: true)].contains {
            // Resolve the installation directory, but do not trust an .app
            // symlink whose destination is on a mounted image or elsewhere.
            installed.path == $0.standardizedFileURL.resolvingSymlinksInPath()
                .appendingPathComponent("BeaverMeter.app").path
        }
    }

    /// Only a complete official installed build can create an updater.
    static func isEnabled(info: [String: Any], bundleIdentifier identifier: String?,
                          bundleURL: URL, isDemo: Bool,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let directInstall = info["BeaverMeterDirectInstall"]
        let updatesEnabled = info["BeaverMeterUpdatesEnabled"]
        guard !isDemo, identifier == bundleIdentifier,
              directInstall as? Bool == true || directInstall as? String == "YES",
              updatesEnabled as? Bool == true || updatesEnabled as? String == "YES",
              isCanonicalInstallation(bundleURL, home: home),
              let version = info["CFBundleShortVersionString"] as? String,
              ReleaseVersion(version) != nil,
              let build = info["CFBundleVersion"] as? String, isValidBuild(build),
              let feed = info["SUFeedURL"] as? String, feed == feedURL.absoluteString,
              let key = info["SUPublicEDKey"] as? String,
              let decodedKey = Data(base64Encoded: key), decodedKey.count == 32 else { return false }
        return true
    }

    static func isValidBuild(_ build: String) -> Bool {
        !build.isEmpty && build.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
            && build.first != "0" && Int(build) != nil
    }

    static func releaseURL(version: String) -> URL {
        guard let parsed = ReleaseVersion(version) else {
            return URL(string: "\(repositoryURL)/releases")!
        }
        return URL(string: "\(repositoryURL)/releases/tag/v\(parsed.description)")!
    }
}

// Retained for preview renderers and links to the project's official releases.
enum GitHubRelease {
    static let repositoryURL = ReleaseUpdateConfiguration.repositoryURL
}
