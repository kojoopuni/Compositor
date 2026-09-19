import Foundation
import CoreGraphics

/// Commands that change a project's structure: the canvas, its layers and how each layer sits in the stack.
extension Commands {
    static func new(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let url = try arguments.url(0, "the project to create, e.g. wall.comp")
        guard let width = try arguments.integer("width"), let height = try arguments.integer("height") else {
            throw CommandError("usage: compositor-cli new <project.comp> --width <pixels> --height <pixels>")
        }
        if FileManager.default.fileExists(atPath: url.path), !arguments.flag("overwrite") {
            throw CommandError("\(url.lastPathComponent) already exists; pass --overwrite to replace it")
        }
        let workspace = try Workspace.create(url, width: width, height: height)
        try await workspace.save()
        return try await info([url.path])
    }

    /// Places an image file as a new layer on top of the stack, centered unless --x and --y say where its top-left
    /// corner goes.
    static func addLayer(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let project = try arguments.url(0, "the project"), image = try arguments.url(1, "the image file to add")
        let workspace = try await Workspace.open(project)
        let budget = 100_000_000 - (workspace.session.document?.layers.reduce(0) {
            $0 + ($1.asset.map { $0.image.width * $0.image.height } ?? 0) } ?? 0)
        let asset = try await ImageImporter.shared.decode(image, remainingPixels: max(0, budget))
        workspace.session.insert(asset)
        guard let id = workspace.session.activeLayerID else { throw CommandError("the layer could not be added") }
        if let name = arguments.string("name") { workspace.session.renameLayer(id, to: name) }
        try place(workspace, arguments)
        try appearance(workspace, arguments)
        try await workspace.save()
        return try json(["added": id.uuidString])
    }

    static func setLayer(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        let layer = try workspace.activate(try arguments.required(1, "the layer's id or name"))
        if let name = arguments.string("name") { workspace.session.renameLayer(layer.id, to: name) }
        if let visible = try arguments.boolean("visible"), visible != layer.isVisible {
            workspace.session.toggleLayerVisibility(layer.id)
        }
        try place(workspace, arguments)
        try appearance(workspace, arguments)
        try await workspace.save()
        return try json(["updated": layer.id.uuidString])
    }

    static func deleteLayer(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        let layer = try workspace.layer(try arguments.required(1, "the layer's id or name"))
        // The app asks whether layers clipped to this one keep its shape; here they are simply released.
        workspace.session.finishDeletingLayers([layer.id], baked: [:])
        guard workspace.session.document?.layers.contains(where: { $0.id == layer.id }) == false else {
            throw CommandError("the layer could not be deleted")
        }
        try await workspace.save()
        return try json(["deleted": layer.id.uuidString])
    }

    /// --x/--y (top-left corner), --width/--height or --scale (percent of the layer's own pixels), --rotation
    /// (degrees clockwise), --flip-x/--flip-y, --sampling. Goes through the session's transform so a live shape
    /// layer is redrawn at its new size.
    private static func place(_ workspace: Workspace, _ arguments: Arguments) throws {
        let names = ["x", "y", "width", "height", "scale", "rotation", "flip-x", "flip-y", "sampling"]
        guard names.contains(where: arguments.has) else { return }
        let session = workspace.session
        session.beginTransform()
        guard var draft = session.transformEdit?.draft else { throw CommandError("this layer cannot be transformed") }
        if let scale = try arguments.number("scale") {
            guard let pixels = session.activeLayer?.asset?.image else { throw CommandError("--scale needs a layer with pixels") }
            draft = draft.scaled(toPercent: scale, pixelSize: CGSize(width: pixels.width, height: pixels.height))
        }
        if let width = try arguments.number("width") { draft.size.width = width }
        if let height = try arguments.number("height") { draft.size.height = height }
        if let x = try arguments.number("x") { draft.origin.x = x }
        if let y = try arguments.number("y") { draft.origin.y = y }
        if let rotation = try arguments.number("rotation") { draft.rotation = rotation }
        if let flip = try arguments.boolean("flip-x") { draft.flipX = flip }
        if let flip = try arguments.boolean("flip-y") { draft.flipY = flip }
        if let text = arguments.string("sampling") {
            guard let sampling = LayerSampling.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(text.lowercased()) }) else {
                throw CommandError("--sampling is one of: \(LayerSampling.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            draft.sampling = sampling
        }
        guard draft.isValid else { session.cancelTransform(); throw CommandError("that position or size is out of range") }
        session.previewTransform(draft)
        session.commitTransform()
    }

    /// --opacity (0–100) and --blend (a blend mode's name, e.g. "Multiply").
    static func appearance(_ workspace: Workspace, _ arguments: Arguments) throws {
        if let opacity = try arguments.number("opacity") {
            guard (0...100).contains(opacity) else { throw CommandError("--opacity is 0–100") }
            workspace.session.setLayerOpacity(opacity / 100)
        }
        if let text = arguments.string("blend") {
            guard let mode = LayerBlendMode.allCases.first(where: { $0.rawValue.lowercased() == text.lowercased() }) else {
                throw CommandError("--blend is one of: \(LayerBlendMode.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            workspace.session.setLayerBlendMode(mode)
        }
    }
}
