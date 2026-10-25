import Darwin
import Foundation
import Security

/// Preflights the *existing* permission held by Claude Code's system reader.
/// This never reads a password, edits an ACL, or grants a new application access.
/// The caller holds the legacy interaction-policy lock with UI disabled.
enum ClaudeSecurityReadAuthorization {
    private typealias TrustedApplicationValidator = @convention(c) (SecTrustedApplication, UnsafePointer<CChar>) -> OSStatus

    // This legacy verifier is exported by Security but absent from the public
    // SDK headers. It is an optional compatibility boundary, never a dependency
    // on which native reading or application launch relies. Missing symbols and
    // every non-success result disable this fallback rather than weakening ACLs.
    private static let trustedApplicationValidator: TrustedApplicationValidator? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SecTrustedApplicationValidateWithPath") else { return nil }
        return unsafeBitCast(symbol, to: TrustedApplicationValidator.self)
    }()

    struct Entry: Equatable {
        let authorizations: Set<String>
        let requiresPassphrase: Bool
        let trustsSecurityExecutable: Bool
    }

    struct Metadata: Equatable {
        let service: String
        let account: String
        let keychainUnlocked: Bool
        let keychainSettingsReadable: Bool
        let entries: [Entry]
    }

    typealias MetadataReader = (_ service: String, _ account: String) -> Metadata?

    static func permitsRead(service: String, account: String) -> Bool {
        permitsRead(service: service, account: account, metadataReader: readMetadata)
    }

    /// Keeping the decision separate lets tests exercise every denial without
    /// querying the user's Keychain or starting the system security executable.
    static func permitsRead(service: String, account: String, metadataReader: MetadataReader) -> Bool {
        guard !service.isEmpty, !account.isEmpty, !service.contains("\0"), !account.contains("\0"),
              let metadata = metadataReader(service, account),
              metadata.service == service, metadata.account == account,
              metadata.keychainUnlocked, metadata.keychainSettingsReadable else { return false }
        let readAuthorizations = Set([kSecACLAuthorizationDecrypt as String, kSecACLAuthorizationAny as String])
        return metadata.entries.contains { entry in
            !entry.authorizations.isDisjoint(with: readAuthorizations)
                && !entry.requiresPassphrase && entry.trustsSecurityExecutable
        }
    }

    private static func readMetadata(service: String, account: String) -> Metadata? {
        guard service.utf8.count <= Int(UInt32.max), account.utf8.count <= Int(UInt32.max) else { return nil }
        var item: SecKeychainItem?
        // Nil password outputs request only an item reference, never its secret.
        guard SecKeychainFindGenericPassword(nil, UInt32(service.utf8.count), service,
                                            UInt32(account.utf8.count), account, nil, nil, &item) == errSecSuccess,
              let item else { return nil }
        var keychain: SecKeychain?
        guard SecKeychainItemCopyKeychain(item, &keychain) == errSecSuccess, let keychain else { return nil }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess,
              status & UInt32(kSecUnlockStateStatus) != 0 else { return nil }
        var settings = SecKeychainSettings(version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1), lockOnSleep: false,
                                          useLockInterval: false, lockInterval: 0)
        guard SecKeychainCopySettings(keychain, &settings) == errSecSuccess else { return nil }
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access else { return nil }
        var list: CFArray?
        guard SecAccessCopyACLList(access, &list) == errSecSuccess, let entries = list as? [SecACL] else { return nil }
        var metadata: [Entry] = []
        for entry in entries {
            guard let authorizations = SecACLCopyAuthorizations(entry) as? [String] else { return nil }
            var applications: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector(rawValue: 0)
            guard SecACLCopyContents(entry, &applications, &description, &prompt) == errSecSuccess else { return nil }
            // An unrestricted (nil) application list is not explicit trust of
            // the executable. Require a concrete entry rather than guessing.
            let trusted = (applications as? [SecTrustedApplication] ?? []).contains(where: validatesSecurityExecutable)
            metadata.append(Entry(authorizations: Set(authorizations),
                                  requiresPassphrase: prompt.contains(.requirePassphase),
                                  trustsSecurityExecutable: trusted))
        }
        return Metadata(service: service, account: account, keychainUnlocked: true,
                        keychainSettingsReadable: true, entries: metadata)
    }

    private static func validatesSecurityExecutable(_ application: SecTrustedApplication) -> Bool {
        // A stored path is descriptive metadata, not proof that its code meets
        // the ACL requirement. Never substitute a path-only comparison.
        guard let validator = trustedApplicationValidator else { return false }
        return "/usr/bin/security".withCString { validator(application, $0) == errSecSuccess }
    }
}
