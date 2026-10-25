import Foundation

struct CodexWorkspaceLogin: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let label: String
    let workspaceAccountID: String
}

struct CodexWorkspaceStore: Sendable {
    let directory: URL

    var metadataURL: URL { directory.appendingPathComponent("beaver-meter-workspaces.json") }

    func home(for id: UUID) -> URL {
        directory.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("codex-workspaces", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private struct Payload: Codable {
        let version: Int
        let workspaces: [CodexWorkspaceLogin]
    }

    func load() throws -> [CodexWorkspaceLogin] {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return [] }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: metadataURL))
        guard payload.version == 1 else { throw CocoaError(.coderReadCorrupt) }
        var seen: Set<UUID> = []
        return payload.workspaces.filter { seen.insert($0.id).inserted }
    }

    /// Caller holds the registry lock when multiple collector processes can write.
    func save(_ workspace: CodexWorkspaceLogin) throws {
        var workspaces = try load()
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) { workspaces[index] = workspace }
        else { workspaces.append(workspace) }
        try AtomicFileWriter.writeJSON(Payload(version: 1, workspaces: workspaces), to: metadataURL, prettyPrinted: true)
    }
}
