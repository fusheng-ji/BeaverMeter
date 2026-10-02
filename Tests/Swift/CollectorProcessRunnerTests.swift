import Foundation
import XCTest

final class CollectorProcessRunnerTests: XCTestCase {
    func testConfiguredRefreshUsesBundledHelperAndSuppliedSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("collector")
        let wrapper = directory.appendingPathComponent("refresh.sh")
        let output = directory.appendingPathComponent("local test snapshot.json")
        try """
        #!/bin/zsh
        [[ "$1" == --output ]] || exit 2
        print -r -- "$CODEX_REMOTE_SSH_HOST" > "$2"
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try """
        export CODEX_REMOTE_SSH_HOST=fixture-remote
        exec "$BEAVERMETER_COLLECTOR" "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)

        let result = CollectorProcessRunner.refresh(helper: helper, script: wrapper, output: output.path)
        XCTAssertEqual(result.status, 0, result.message)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "fixture-remote\n")
    }
}
