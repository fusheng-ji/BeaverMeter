import Foundation
import XCTest

final class ClaudeCredentialResolverTests: XCTestCase {
    func testCancelledSystemReadDoesNotFallThroughToAFile() {
        XCTAssertThrowsError(try ClaudeCredentialResolver.credentialsData(environment: [:],
            homeDirectory: URL(fileURLWithPath: "/synthetic-home"),
            fileReader: { _ in XCTFail("Cancelled system read must stop credential resolution"); return Data() },
            keychainReader: { _, _ in throw URLError(.cancelled) })) {
            XCTAssertEqual(($0 as? URLError)?.code, .cancelled)
        }
    }

    private let home = URL(fileURLWithPath: "/resolver-test-home", isDirectory: true)
    private let defaultService = "Claude Code-credentials"
    private let account = "test-user"
    private let now = ISO8601DateFormatter().date(from: "2026-09-23T12:00:00Z")!

    private struct KeychainRead: Equatable {
        let service: String
        let account: String
    }

    /// Every source is supplied in memory. These tests never open the real
    /// credential file, query the login Keychain, or launch Claude Code.
    private final class Readers {
        var files: [URL: Data] = [:]
        var keychainItems: [String: Data] = [:]
        var fileReads: [URL] = []
        var keychainReads: [KeychainRead] = []
        var readOrder: [String] = []

        func readFile(_ url: URL) throws -> Data? {
            fileReads.append(url)
            readOrder.append("file")
            return files[url]
        }

        func readKeychain(_ service: String, _ account: String) throws -> Data? {
            keychainReads.append(KeychainRead(service: service, account: account))
            readOrder.append("keychain")
            return keychainItems["\(service)|\(account)"]
        }
    }

    private var defaultFile: URL {
        home.appendingPathComponent(".claude/.credentials.json")
    }

    private func credentials(_ token: String, expiresAt: Double = 4_070_908_800_000) -> Data {
        Data(#"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":\#(expiresAt)}}"#.utf8)
    }

    private func readers(primary: Data? = nil, file: Data? = nil, service: String? = nil) -> Readers {
        let readers = Readers()
        readers.keychainItems["\(service ?? defaultService)|\(account)"] = primary
        readers.files[defaultFile] = file
        return readers
    }

    private func resolve(_ readers: Readers, environment: [String: String] = ["USER": "test-user"]) throws -> Data {
        try ClaudeCredentialResolver.credentialsData(
            environment: environment,
            homeDirectory: home,
            fileReader: readers.readFile,
            keychainReader: readers.readKeychain
        )
    }

    func testKeychainPrimaryDoesNotReadAnOlderEmptyOrMalformedFile() throws {
        let primary = credentials("current-keychain-login")
        for file in [credentials("old-file-login", expiresAt: 1), Data(), Data("broken-json".utf8)] {
            let sources = readers(primary: primary, file: file)

            XCTAssertEqual(try resolve(sources), primary)
            XCTAssertEqual(sources.readOrder, ["keychain"])
            XCTAssertTrue(sources.fileReads.isEmpty)
            XCTAssertEqual(sources.keychainReads, [KeychainRead(service: defaultService, account: account)])
        }
    }

    func testMissingEmptyMalformedAndNullKeychainFallBackToTheSameProfileFile() throws {
        let file = credentials("file-login")
        let primaryValues: [Data?] = [nil, Data(), Data("not-json".utf8), Data("null".utf8)]
        for primary in primaryValues {
            let sources = readers(primary: primary, file: file)

            XCTAssertEqual(try resolve(sources), file)
            XCTAssertEqual(sources.readOrder, ["keychain", "file"])
            XCTAssertEqual(sources.fileReads, [defaultFile])
            XCTAssertEqual(sources.keychainReads, [KeychainRead(service: defaultService, account: account)])
        }
    }

    func testKeychainReadFailureFallsBackToTheSameProfileFile() throws {
        let file = credentials("file-login")
        var fileReads: [URL] = []
        let result = try ClaudeCredentialResolver.credentialsData(
            environment: ["USER": account], homeDirectory: home,
            fileReader: { url in fileReads.append(url); return file },
            keychainReader: { _, _ in throw URLError(.cannotOpenFile) }
        )

        XCTAssertEqual(result, file)
        XCTAssertEqual(fileReads, [defaultFile])
    }

    func testAnyNonNullJSONPrimaryIsAuthoritativeWithoutBorrowingFileOAuth() throws {
        let primaryValues = [
            #"{}"#,
            #"{"mcpOAuth":{}}"#,
            #"{"claudeAiOauth":{"accessToken":""}}"#,
            #"{"claudeAiOauth":{"accessToken":"","refreshToken":"retained-refresh-token"}}"#,
            #"{"claudeAiOauth":{"accessToken":"   "}}"#,
            #"[]"#,
            #"false"#,
            #"0"#,
            "\"\"",
        ]
        for json in primaryValues {
            let primary = Data(json.utf8)
            let sources = readers(primary: primary, file: credentials("unrelated-file-login"))

            let result = try resolve(sources)
            XCTAssertEqual(result, primary, json)
            XCTAssertTrue(sources.fileReads.isEmpty, json)
            XCTAssertThrowsError(try ClaudeQuotaCollector.accessToken(fromCredentials: result, now: now)) {
                XCTAssertEqual($0 as? ClaudeQuotaError, .notLoggedIn, json)
            }
        }
    }

    func testExpiredPrimaryDoesNotSwitchToAFresherFileToken() throws {
        let primary = credentials("expired-keychain-login", expiresAt: (now.timeIntervalSince1970 - 60) * 1_000)
        let sources = readers(primary: primary, file: credentials("fresh-file-login"))

        let result = try resolve(sources)
        XCTAssertEqual(result, primary)
        XCTAssertTrue(sources.fileReads.isEmpty)
        XCTAssertThrowsError(try ClaudeQuotaCollector.accessToken(fromCredentials: result, now: now)) {
            XCTAssertEqual($0 as? ClaudeQuotaError, .expired)
        }
    }

    func testMissingBothSourcesRequiresLoginWithoutSearchingOtherProfiles() throws {
        let sources = readers()
        sources.files[URL(fileURLWithPath: "/profiles/other/.credentials.json")] = credentials("other-profile")
        sources.keychainItems["Claude Code-credentials-2f3662a6|\(account)"] = credentials("other-profile")

        XCTAssertThrowsError(try resolve(sources)) {
            XCTAssertEqual($0 as? ClaudeQuotaError, .notLoggedIn)
        }
        XCTAssertEqual(sources.fileReads, [defaultFile])
        XCTAssertEqual(sources.keychainReads, [KeychainRead(service: defaultService, account: account)])
    }

    func testEmptyMalformedAndNullFallbackFilesRequireLogin() {
        for file in [Data(), Data("not-json".utf8), Data("null".utf8)] {
            let sources = readers(file: file)

            XCTAssertThrowsError(try resolve(sources)) {
                XCTAssertEqual($0 as? ClaudeQuotaError, .notLoggedIn)
            }
            XCTAssertEqual(sources.readOrder, ["keychain", "file"])
            XCTAssertEqual(sources.fileReads, [defaultFile])
        }
    }

    func testCustomConfigDirectoryUsesOnlyItsOwnFileAndHashedKeychainService() throws {
        let profileFile = URL(fileURLWithPath: "/profiles/work/.credentials.json")
        let expectedService = "Claude Code-credentials-2ea9e238"
        let environment = ["USER": account, "CLAUDE_CONFIG_DIR": "/profiles/work"]
        let sources = readers(primary: credentials("default-profile"), file: credentials("default-file"))
        let expected = credentials("work-profile")
        sources.files[profileFile] = expected

        XCTAssertEqual(try resolve(sources, environment: environment), expected)
        XCTAssertEqual(sources.keychainReads, [KeychainRead(service: expectedService, account: account)])
        XCTAssertEqual(sources.fileReads, [profileFile])
        XCTAssertEqual(ClaudeCredentialResolver.configDirectory(environment: environment, homeDirectory: home),
                       URL(fileURLWithPath: "/profiles/work", isDirectory: true))
        XCTAssertEqual(ClaudeCredentialResolver.credentialFileURL(environment: environment, homeDirectory: home), profileFile)
        XCTAssertEqual(try ClaudeCredentialResolver.keychainServiceName(environment: environment, homeDirectory: home), expectedService)
    }

    func testCustomProfileKeychainWinsWithoutReadingItsFileOrDefaultSources() throws {
        let expectedService = "Claude Code-credentials-2ea9e238"
        let expected = credentials("work-keychain")
        let sources = readers(primary: credentials("default-keychain"), file: credentials("default-file"))
        sources.keychainItems["\(expectedService)|\(account)"] = expected
        sources.files[URL(fileURLWithPath: "/profiles/work/.credentials.json")] = credentials("work-file")

        XCTAssertEqual(try resolve(sources, environment: ["USER": account, "CLAUDE_CONFIG_DIR": "/profiles/work"]), expected)
        XCTAssertEqual(sources.keychainReads, [KeychainRead(service: expectedService, account: account)])
        XCTAssertTrue(sources.fileReads.isEmpty)
    }

    func testSecureStorageDirectoryOverridesConfigDirectoryForBothSources() throws {
        let environment = ["USER": account, "CLAUDE_CONFIG_DIR": "/profiles/work",
                           "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/profiles/secure"]
        let secureFile = URL(fileURLWithPath: "/profiles/secure/.credentials.json")
        let expected = credentials("secure-profile")
        let sources = readers(primary: credentials("default-keychain"), file: credentials("default-file"))
        sources.files[URL(fileURLWithPath: "/profiles/work/.credentials.json")] = credentials("work-file")
        sources.files[secureFile] = expected

        XCTAssertEqual(try resolve(sources, environment: environment), expected)
        XCTAssertEqual(sources.keychainReads, [KeychainRead(service: "Claude Code-credentials-16006495", account: account)])
        XCTAssertEqual(sources.fileReads, [secureFile])
        XCTAssertEqual(ClaudeCredentialResolver.configDirectory(environment: environment, homeDirectory: home),
                       URL(fileURLWithPath: "/profiles/work", isDirectory: true))
        XCTAssertEqual(ClaudeCredentialResolver.storageDirectory(environment: environment, homeDirectory: home),
                       URL(fileURLWithPath: "/profiles/secure", isDirectory: true))
    }

    func testPresentButEmptySecureStorageDirectorySelectsTheDefaultProfileWithoutAHash() throws {
        let environment = ["USER": account, "CLAUDE_CONFIG_DIR": "/profiles/work",
                           "CLAUDE_SECURESTORAGE_CONFIG_DIR": ""]
        let expected = credentials("default-profile")
        let sources = readers(file: expected)
        sources.files[URL(fileURLWithPath: "/profiles/work/.credentials.json")] = credentials("work-file")

        XCTAssertEqual(try resolve(sources, environment: environment), expected)
        XCTAssertEqual(sources.keychainReads, [KeychainRead(service: defaultService, account: account)])
        XCTAssertEqual(sources.fileReads, [defaultFile])
        XCTAssertEqual(try ClaudeCredentialResolver.keychainServiceName(environment: environment, homeDirectory: home), defaultService)
    }

    func testAbsentConfigDirectoryUsesDefaultProfileWithoutAHash() throws {
        XCTAssertEqual(ClaudeCredentialResolver.configDirectory(environment: [:], homeDirectory: home),
                       home.appendingPathComponent(".claude", isDirectory: true))
        XCTAssertEqual(ClaudeCredentialResolver.credentialFileURL(environment: [:], homeDirectory: home), defaultFile)
        XCTAssertEqual(try ClaudeCredentialResolver.keychainServiceName(environment: [:], homeDirectory: home), defaultService)
    }

    func testEmptyConfigDirectoryPreservesTheEmptyRootWithoutAHash() throws {
        let environment = ["USER": account, "CLAUDE_CONFIG_DIR": ""]
        let root = URL(fileURLWithPath: "", isDirectory: true)
        let file = root.appendingPathComponent(".credentials.json")
        let expected = credentials("empty-root-file")
        let sources = readers(file: credentials("default-profile"))
        sources.files[file] = expected

        XCTAssertEqual(ClaudeCredentialResolver.configDirectory(environment: environment, homeDirectory: home), root)
        XCTAssertEqual(ClaudeCredentialResolver.storageDirectory(environment: environment, homeDirectory: home), root)
        XCTAssertEqual(ClaudeCredentialResolver.credentialFileURL(environment: environment, homeDirectory: home), file)
        XCTAssertEqual(try ClaudeCredentialResolver.keychainServiceName(environment: environment, homeDirectory: home), defaultService)
        XCTAssertEqual(try resolve(sources, environment: environment), expected)
        XCTAssertEqual(sources.keychainReads, [KeychainRead(service: defaultService, account: account)])
        XCTAssertEqual(sources.fileReads, [file])
    }

    func testExplicitCredentialFileSymlinkIsReadWhenKeychainIsDisabled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beavermeter-resolver-symlink-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("fixture-credentials.json")
        let expected = credentials("synthetic-symlink-login")
        try expected.write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".credentials.json"),
                                                  withDestinationURL: target)

        XCTAssertEqual(try ClaudeCredentialResolver.credentialsData(environment: [
            "CLAUDE_CONFIG_DIR": root.path,
            "CLAUDE_KEYCHAIN_ACCESS": "0",
        ]), expected)
    }

    func testKeychainProfileHashNormalizesUnicodeToNFC() throws {
        let composed = ["CLAUDE_CONFIG_DIR": "/profiles/caf\u{00E9}"]
        let decomposed = ["CLAUDE_CONFIG_DIR": "/profiles/cafe\u{0301}"]

        XCTAssertEqual(try ClaudeCredentialResolver.keychainServiceName(environment: composed, homeDirectory: home),
                       "Claude Code-credentials-4bee4e79")
        XCTAssertEqual(try ClaudeCredentialResolver.keychainServiceName(environment: decomposed, homeDirectory: home),
                       "Claude Code-credentials-4bee4e79")
    }

    func testKeychainProfileHashUsesRawPathRatherThanStandardizingIt() throws {
        let cases = [
            ("/profiles/work", "Claude Code-credentials-2ea9e238"),
            ("/profiles/team/../work", "Claude Code-credentials-55ba036a"),
            ("/profiles/work/", "Claude Code-credentials-75564947"),
            (" ", "Claude Code-credentials-36a9e7f1"),
        ]
        for (rawPath, service) in cases {
            XCTAssertEqual(try ClaudeCredentialResolver.keychainServiceName(
                environment: ["CLAUDE_CONFIG_DIR": rawPath], homeDirectory: home
            ), service)
        }
    }

    func testKeychainAccountPrefersNonemptyUSERAndValidatesTheWholeName() {
        XCTAssertEqual(ClaudeCredentialResolver.keychainAccountName(environment: ["USER": "alice._-123"], userName: "system-user"),
                       "alice._-123")
        XCTAssertEqual(ClaudeCredentialResolver.keychainAccountName(environment: [:], userName: "system-user"), "system-user")
        XCTAssertEqual(ClaudeCredentialResolver.keychainAccountName(environment: ["USER": ""], userName: "system-user"), "system-user")
        for invalid in ["alice bob", "alice\nbob", "alice/bob", "alice@host", "用户", " "] {
            XCTAssertEqual(ClaudeCredentialResolver.keychainAccountName(environment: ["USER": invalid], userName: "system-user"),
                           "claude-code-user", invalid)
        }
        XCTAssertEqual(ClaudeCredentialResolver.keychainAccountName(environment: [:], userName: "bad system user"), "claude-code-user")
    }

    func testKeychainOptOutReadsOnlyTheSelectedProfileFile() throws {
        let expected = credentials("work-file")
        let sources = readers(primary: credentials("default-keychain"), file: credentials("default-file"))
        let profileFile = URL(fileURLWithPath: "/profiles/work/.credentials.json")
        sources.files[profileFile] = expected
        sources.keychainItems["Claude Code-credentials-2ea9e238|\(account)"] = credentials("work-keychain")

        XCTAssertEqual(try resolve(sources, environment: ["USER": account, "CLAUDE_CONFIG_DIR": "/profiles/work",
                                                       "CLAUDE_KEYCHAIN_ACCESS": "0"]), expected)
        XCTAssertTrue(sources.keychainReads.isEmpty)
        XCTAssertEqual(sources.fileReads, [profileFile])
        XCTAssertEqual(sources.readOrder, ["file"])
    }

    func testCurrentCLIProfileIgnoresLocalOAuthAndStagingFlags() throws {
        let expected = credentials("normal-login")
        let sources = readers(primary: expected, file: credentials("file-login"))
        let environment = ["USER": account, "USE_LOCAL_OAUTH": "1", "USE_STAGING_OAUTH": "1",
                           "CLAUDE_CODE_USE_LOCAL_OAUTH": "1", "CLAUDE_CODE_USE_STAGING_OAUTH": "1"]

        XCTAssertEqual(try resolve(sources, environment: environment), expected)
        XCTAssertEqual(sources.keychainReads, [KeychainRead(service: defaultService, account: account)])
        XCTAssertTrue(sources.fileReads.isEmpty)
    }

    func testCustomOAuthEndpointIsRejectedBeforeReadingEitherCredentialSource() throws {
        let sources = readers(primary: credentials("normal-login"), file: credentials("normal-file"))
        let environment = ["USER": account, "CLAUDE_CODE_CUSTOM_OAUTH_URL": "https://example.invalid/oauth"]

        XCTAssertThrowsError(try resolve(sources, environment: environment)) { error in
            guard let error = error as? ClaudeCredentialResolver.ResolutionError else {
                return XCTFail("Expected a credential resolution error")
            }
            guard case .unsupportedOAuthEndpoint = error else {
                return XCTFail("Expected unsupportedOAuthEndpoint, got \(error)")
            }
        }
        XCTAssertThrowsError(try ClaudeCredentialResolver.keychainServiceName(environment: environment, homeDirectory: home)) { error in
            guard let error = error as? ClaudeCredentialResolver.ResolutionError else {
                return XCTFail("Expected a credential resolution error")
            }
            guard case .unsupportedOAuthEndpoint = error else {
                return XCTFail("Expected unsupportedOAuthEndpoint, got \(error)")
            }
        }
        XCTAssertTrue(sources.keychainReads.isEmpty)
        XCTAssertTrue(sources.fileReads.isEmpty)
    }

    func testEmptyCustomOAuthEndpointKeepsTheNormalProfile() throws {
        let expected = credentials("normal-login")
        let sources = readers(primary: expected)

        XCTAssertEqual(try resolve(sources, environment: ["USER": account, "CLAUDE_CODE_CUSTOM_OAUTH_URL": ""]), expected)
        XCTAssertEqual(sources.keychainReads, [KeychainRead(service: defaultService, account: account)])
        XCTAssertTrue(sources.fileReads.isEmpty)
    }

    func testTemporaryKeychainFailureWithoutAFileIsAStoreErrorRatherThanALogout() {
        var fileReads: [URL] = []
        XCTAssertThrowsError(try ClaudeCredentialResolver.credentialsData(
            environment: ["USER": account], homeDirectory: home,
            fileReader: { url in fileReads.append(url); return nil },
            keychainReader: { _, _ in throw URLError(.cannotOpenFile) }
        )) { error in
            guard let error = error as? ClaudeCredentialResolver.ResolutionError else {
                return XCTFail("Expected a credential resolution error")
            }
            guard case .credentialStoreUnavailable = error else {
                return XCTFail("Expected credentialStoreUnavailable, got \(error)")
            }
        }
        XCTAssertEqual(fileReads, [defaultFile])
    }

    func testNativeKeychainAccessFailuresSurviveAnAbsentFallbackWithoutRequestingLogin() {
        for failure in [ClaudeKeychainReader.ReadError.keychainAccessRequired, .userCancelled,
                        .unavailable(status: -12345)] {
            var fileReads: [URL] = []
            XCTAssertThrowsError(try ClaudeCredentialResolver.credentialsData(
                environment: ["USER": account], homeDirectory: home,
                fileReader: { url in fileReads.append(url); return nil },
                keychainReader: { _, _ in throw failure }
            )) {
                XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, failure)
                XCTAssertNotEqual($0 as? ClaudeQuotaError, .notLoggedIn)
            }
            XCTAssertEqual(fileReads, failure == .userCancelled ? [] : [defaultFile])
        }
    }

    func testNativeAccessFailureCanUseOnlyTheSelectedProfilesExistingFallback() throws {
        let environment = ["USER": account, "CLAUDE_CONFIG_DIR": "/profiles/selected"]
        let expectedFile = URL(fileURLWithPath: "/profiles/selected/.credentials.json")
        let expected = credentials("selected-profile-file")
        var fileReads: [URL] = []
        var keychainReads: [KeychainRead] = []
        let result = try ClaudeCredentialResolver.credentialsData(
            environment: environment, homeDirectory: home,
            fileReader: { url in fileReads.append(url); return url == expectedFile ? expected : nil },
            keychainReader: { service, account in
                keychainReads.append(KeychainRead(service: service, account: account))
                throw ClaudeKeychainReader.ReadError.keychainAccessRequired
            }
        )

        XCTAssertEqual(result, expected)
        XCTAssertEqual(fileReads, [expectedFile])
        XCTAssertEqual(keychainReads, [KeychainRead(
            service: try ClaudeCredentialResolver.keychainServiceName(environment: environment, homeDirectory: home),
            account: account
        )])
    }

    func testTemporaryFileFailureWithoutAKeychainItemIsAStoreErrorRatherThanALogout() {
        var keychainReads: [KeychainRead] = []
        XCTAssertThrowsError(try ClaudeCredentialResolver.credentialsData(
            environment: ["USER": account], homeDirectory: home,
            fileReader: { _ in throw URLError(.noPermissionsToReadFile) },
            keychainReader: { service, account in
                keychainReads.append(KeychainRead(service: service, account: account))
                return nil
            }
        )) { error in
            guard let error = error as? ClaudeCredentialResolver.ResolutionError else {
                return XCTFail("Expected a credential resolution error")
            }
            guard case .credentialStoreUnavailable = error else {
                return XCTFail("Expected credentialStoreUnavailable, got \(error)")
            }
        }
        XCTAssertEqual(keychainReads, [KeychainRead(service: defaultService, account: account)])
    }

    func testCancelledAccessNeverFallsThroughToExistingFileCredentials() {
        var fileWasRead = false
        XCTAssertThrowsError(try ClaudeCredentialResolver.credentialsData(
            environment: ["USER": account], homeDirectory: home,
            fileReader: { _ in fileWasRead = true; return self.credentials("file-secret") },
            keychainReader: { _, _ in throw ClaudeKeychainReader.ReadError.userCancelled }
        )) {
            XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, .userCancelled)
        }
        XCTAssertFalse(fileWasRead)
    }
}
