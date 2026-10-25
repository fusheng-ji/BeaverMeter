import Foundation

enum DirectInstallSetup {
    static func flag(_ key: String, in bundle: Bundle) -> Bool {
        let value = bundle.object(forInfoDictionaryKey: key)
        return value as? Bool == true || (value as? String)?.uppercased() == "YES"
    }

    static func needsInstallation(at url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        !ReleaseUpdateConfiguration.isCanonicalInstallation(url, home: home)
    }

    static func preferredInstalledApp(for bundle: Bundle, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                     isOfficial: (URL) -> Bool = { Bundle(url: $0)?.bundleIdentifier == ReleaseUpdateConfiguration.bundleIdentifier }) -> URL {
        guard bundle.bundleIdentifier == ReleaseUpdateConfiguration.bundleIdentifier,
              !needsInstallation(at: bundle.bundleURL, home: home) else { return bundle.bundleURL }
        let systemApp = URL(fileURLWithPath: "/Applications/BeaverMeter.app", isDirectory: true)
        return ReleaseUpdateConfiguration.isCanonicalInstallation(systemApp, home: home)
            && isOfficial(systemApp) ? systemApp : bundle.bundleURL
    }

    static func configure(bundle: Bundle = .main) async -> String? {
        guard !CommandLine.arguments.contains("--interaction-demo"),
              !flag("BeaverMeterInteractionDemo", in: bundle),
              flag("BeaverMeterDirectInstall", in: bundle) else { return nil }
        guard !needsInstallation(at: bundle.bundleURL) else {
            return "Drag BeaverMeter to Applications before opening it. Eject the disk image, then open the installed app. You can also use your home Applications folder."
        }
        guard let script = bundle.url(forResource: "configure_runtime", withExtension: "sh"),
              let updateScript = bundle.url(forResource: "update_runtime", withExtension: "sh") else {
            return "Runtime setup is missing. Download a complete BeaverMeter installation."
        }
        let app = bundle.bundleURL
        return await Task.detached(priority: .utility) {
            do {
                // Configure validates the replacement before restoring an old
                // build or completing the new build's recovery journal.
                try run(script: script, arguments: [app.path], timeout: 30)
                try run(script: updateScript, arguments: ["complete", app.path], timeout: 5)
                return nil
            } catch {
                return "Could not configure background refresh. Reopen BeaverMeter to retry. See Library/Logs/BeaverMeter/runtime-setup.log. \(error.localizedDescription)"
            }
        }.value
    }

    static func run(script: URL, arguments: [String], timeout: TimeInterval) throws {
        let result = try SubprocessRunner.run(executable: URL(fileURLWithPath: "/bin/zsh"),
                                              arguments: [script.path] + arguments, timeout: timeout)
        try appendLog(result.standardOutput + result.standardError)
        guard result.status == 0, !result.timedOut else {
            throw NSError(domain: "BeaverMeterRuntime", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: result.timedOut ? "Runtime setup timed out." : "Runtime setup failed."])
        }
    }

    private static func appendLog(_ data: Data) throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BeaverMeter", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let log = directory.appendingPathComponent("runtime-setup.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        try output.seekToEnd()
        try output.write(contentsOf: data)
    }
}
