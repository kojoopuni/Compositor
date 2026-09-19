import Foundation

/// What went wrong with a command, worded for whoever typed it.
struct CommandError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Every command takes its arguments after the command name and returns JSON for standard output.
enum Commands {
    static func run(_ arguments: [String]) async throws -> String {
        guard let name = arguments.first else { throw CommandError("usage: compositor-cli <command> [arguments]") }
        let rest = Array(arguments.dropFirst())
        switch name {
        case "info": return try await info(rest)
        case "new": return try await new(rest)
        case "add-layer": return try await addLayer(rest)
        case "set-layer": return try await setLayer(rest)
        case "delete-layer": return try await deleteLayer(rest)
        case "render": return try await render(rest)
        case "export": return try await export(rest)
        default: throw CommandError("unknown command '\(name)'")
        }
    }

    /// The document's size and its layers, top first, as the Layers panel lists them.
    static func info(_ arguments: [String]) async throws -> String {
        guard let path = arguments.first else { throw CommandError("usage: compositor-cli info <project.comp>") }
        let snapshot = try await ProjectStore.shared.load(from: URL(fileURLWithPath: path))
        let manifest = snapshot.manifest
        let layers: [[String: Any]] = manifest.layers.reversed().map { layer in
            var entry: [String: Any] = [
                "id": layer.id.uuidString, "name": layer.name, "visible": layer.isVisible,
                "opacity": layer.opacity ?? 1, "blendMode": (layer.blendMode ?? .normal).rawValue,
                "x": layer.transform.origin.x, "y": layer.transform.origin.y,
                "width": layer.transform.size.width, "height": layer.transform.size.height,
            ]
            if layer.isGroup == true { entry["kind"] = "folder" }
            else if let adjustment = layer.adjustment { entry["kind"] = "adjustment"; entry["adjustment"] = adjustment.kind.rawValue }
            else { entry["kind"] = layer.imageFile == nil ? "blank" : "pixels" }
            if let parent = layer.parentID { entry["parent"] = parent.uuidString }
            if layer.maskFile != nil { entry["mask"] = layer.maskEnabled ?? true ? "enabled" : "disabled" }
            if let source = layer.maskSourceID { entry["clippedTo"] = source.uuidString }
            return entry
        }
        return try json(["width": manifest.width, "height": manifest.height, "resolution": manifest.resolution ?? 72,
                         "layers": layers])
    }

    static func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
