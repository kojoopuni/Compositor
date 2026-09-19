import Foundation

/// A project opened into a bare `EditorSession`, the way the app's own tests drive the engine: every edit goes
/// through the session's methods, so it follows the same rules as the same edit made by hand.
struct Workspace {
    let session: EditorSession
    let url: URL

    static func open(_ url: URL) async throws -> Workspace {
        let snapshot = try await ProjectStore.shared.load(from: url)
        let session = EditorSession()
        session.installProject(snapshot, from: url)
        return Workspace(session: session, url: url)
    }

    /// A new project with one blank layer, as File > New makes.
    static func create(_ url: URL, width: Int, height: Int) throws -> Workspace {
        guard (1...30_000).contains(width), (1...30_000).contains(height), width * height <= 100_000_000 else {
            throw CommandError("a canvas is 1–30,000 pixels a side and at most 100 megapixels")
        }
        let session = EditorSession()
        session.createNewProject(width: width, height: height)
        guard session.document != nil else { throw CommandError("the canvas could not be created") }
        return Workspace(session: session, url: url)
    }

    func save(to destination: URL? = nil) async throws {
        guard let snapshot = session.projectSnapshot() else { throw CommandError("there is no document to save") }
        try await ProjectStore.shared.save(snapshot, to: destination ?? url)
    }

    func snapshot() throws -> ProjectSnapshot {
        guard let snapshot = session.projectSnapshot() else { throw CommandError("there is no document") }
        return snapshot
    }

    /// A layer named by its UUID or, failing that, by its name. A name shared by several layers is refused rather
    /// than guessed at.
    func layer(_ reference: String) throws -> ImageLayer {
        let layers = session.document?.layers ?? []
        if let id = UUID(uuidString: reference), let match = layers.first(where: { $0.id == id }) { return match }
        let named = layers.filter { $0.name == reference }
        if named.count == 1 { return named[0] }
        if named.count > 1 { throw CommandError("\(named.count) layers are named '\(reference)'; use a layer id") }
        throw CommandError("no layer has the id or name '\(reference)'")
    }

    /// Makes `reference` the active layer, which is what the session's layer edits act on.
    @discardableResult
    func activate(_ reference: String) throws -> ImageLayer {
        let target = try layer(reference)
        session.selectLayers([target.id], primary: target.id)
        return target
    }
}
