import Foundation

/// Runs only in this separate QA executable, with temporary synthetic files.
enum WidgetQASelfTest {
    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("widget-qa-contract-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("current-case.json")
        let fixture = WidgetQACase(caseID: "contract-synthetic", snapshot: .unavailable, settings: .default,
                                   referenceDate: Date(timeIntervalSince1970: 1_700_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let valid = try encoder.encode(fixture)
        _ = try WidgetQAStore.apply(valid, to: current)
        guard try WidgetQAStore.load(from: current).caseID == fixture.caseID else {
            throw WidgetQAStore.Failure("Valid case failed to round-trip.")
        }
        var emptyID = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
        emptyID["caseID"] = " "
        var badSchema = emptyID
        badSchema["caseID"] = "unsupported-schema"
        var snapshot = badSchema["snapshot"] as! [String: Any]
        snapshot["schemaVersion"] = 999
        badSchema["snapshot"] = snapshot
        let invalidCases = [Data("invalid JSON".utf8), Data(#"{"caseID":"missing fields"}"#.utf8),
                            try JSONSerialization.data(withJSONObject: emptyID),
                            try JSONSerialization.data(withJSONObject: badSchema)]
        for invalid in invalidCases {
            var rejected = false
            do {
                _ = try WidgetQAStore.apply(invalid, to: current)
            } catch { rejected = true }
            guard rejected else { throw WidgetQAStore.Failure("Invalid case replaced a valid fixture.") }
            guard try WidgetQAStore.load(from: current).caseID == fixture.caseID else {
                throw WidgetQAStore.Failure("Invalid input damaged the prior case.")
            }
        }
        guard WidgetQAStore.currentURL.deletingLastPathComponent().lastPathComponent == "BeaverMeter-WidgetQA",
              UsageSnapshot.snapshotURL.deletingLastPathComponent() == WidgetQAStore.directory,
              WidgetQAStore.kind == "BeaverMeterWidgetQA" else {
            throw WidgetQAStore.Failure("QA storage or Widget identity is not isolated.")
        }
        var missingRejected = false
        do {
            _ = try WidgetQAStore.load(from: directory.appendingPathComponent("missing.json"))
        } catch { missingRejected = true }
        guard missingRejected else { throw WidgetQAStore.Failure("Missing case used a fallback.") }
    }
}
