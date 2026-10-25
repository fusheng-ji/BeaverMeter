#!/usr/bin/env swift
// Public-key-only release verification. Never accepts or reads a private key.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    fputs("\(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("Usage: verify_sparkle_signature.swift public-key-file signed-file base64-signature")
}
do {
    let keyText = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let keyData = Data(base64Encoded: keyText), keyData.count == 32,
          let signature = Data(base64Encoded: CommandLine.arguments[3]), signature.count == 64 else {
        fail("Invalid Ed25519 public key or signature")
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: data) else {
        fail("Ed25519 release signature verification failed")
    }
} catch {
    fail("Unable to verify release signature: \(error.localizedDescription)")
}
