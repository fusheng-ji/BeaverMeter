import CryptoKit
import Foundation

// Only isolated integration copies use this key. The production key is never read or replaced.
guard CommandLine.arguments.count == 3 else { fatalError("Expected private and public output paths") }
let key = Curve25519.Signing.PrivateKey()
for (path, data) in [(CommandLine.arguments[1], key.rawRepresentation),
                     (CommandLine.arguments[2], key.publicKey.rawRepresentation)] {
    guard FileManager.default.createFile(atPath: path,
        contents: Data((data.base64EncodedString() + "\n").utf8),
        attributes: [.posixPermissions: 0o600]) else {
        fatalError("Could not create isolated test key")
    }
}
