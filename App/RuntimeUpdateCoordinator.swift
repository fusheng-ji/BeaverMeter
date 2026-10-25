import Foundation

/// Coordinates only runtime services. Sparkle owns app replacement and relaunch.
@MainActor
final class RuntimeUpdateCoordinator {
    typealias Run = (_ operation: String, _ targetBuild: String?) throws -> Void
    private weak var session: (any UpdateRuntimeSession)?
    private let run: Run
    private let reportError: (String) -> Void
    private(set) var isPrepared = false
    private(set) var needsRecovery = false

    init(session: any UpdateRuntimeSession, run: @escaping Run,
         reportError: @escaping (String) -> Void = { _ in }) {
        self.session = session
        self.run = run
        self.reportError = reportError
    }

    convenience init(session: any UpdateRuntimeSession, bundle: Bundle = .main,
                     reportError: @escaping (String) -> Void) {
        self.init(session: session, run: { operation, build in
            guard let script = bundle.url(forResource: "update_runtime", withExtension: "sh") else {
                throw NSError(domain: "BeaverMeterRuntime", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The bundled update runtime is missing. Reinstall BeaverMeter."])
            }
            try DirectInstallSetup.run(script: script,
                arguments: [operation, bundle.bundleURL.path] + (build.map { [$0] } ?? []),
                timeout: operation == "prepare" ? 4 : 5)
        }, reportError: reportError)
    }

    func prepare(targetBuild: String) -> Bool {
        guard !isPrepared else { return true }
        guard let session else { return false }
        if let reason = session.updateInstallationBlockReason {
            reportError(reason)
            return false
        }
        session.suspendForUpdate()
        needsRecovery = true
        do {
            try run("prepare", targetBuild)
            isPrepared = true
            return true
        } catch {
            recoverAfterAbort()
            reportError("Could not prepare the update. \(error.localizedDescription)")
            return false
        }
    }

    func recoverAfterAbort() {
        do {
            try run("recover", nil)
            isPrepared = false
            needsRecovery = false
            session?.resumeAfterUpdate()
        } catch {
            // Retain the journal and suspended state until reopening can recover it.
            reportError("Could not restore background refresh. Reopen BeaverMeter to retry. \(error.localizedDescription)")
        }
    }
}
