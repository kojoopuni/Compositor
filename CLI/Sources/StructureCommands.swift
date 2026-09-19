import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// Commands for the document's size and the order and nesting of its layers.
extension Commands {
    /// Image Size: resamples every layer. --width and/or --height in pixels (one alone keeps the proportions), or
    /// --scale as a percentage; --resolution in pixels per inch; --sampling nearest, smooth or high.
    static func resize(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let url = try arguments.url(0, "the project")
        let opened = Workspace.lastWritten(url)
        let snapshot = try await ProjectStore.shared.load(from: url)
        let old = snapshot.manifest
        var width = Double(old.width), height = Double(old.height)
        if let scale = try arguments.number("scale") {
            width *= scale / 100; height *= scale / 100
        } else {
            let askedWidth = try arguments.number("width"), askedHeight = try arguments.number("height")
            guard askedWidth != nil || askedHeight != nil else { throw CommandError("resize needs --width, --height or --scale") }
            if let askedWidth, let askedHeight { width = askedWidth; height = askedHeight }
            else if let askedWidth { height *= askedWidth / width; width = askedWidth }
            else if let askedHeight { width *= askedHeight / height; height = askedHeight }
        }
        var options = ImageSizeOptions(width: max(1, Int(width.rounded())), height: max(1, Int(height.rounded())),
                                       resolution: try arguments.number("resolution") ?? old.resolution ?? 72)
        if let text = arguments.string("sampling") { options.sampling = try sampling(text) }
        let resized = try await ImageResizer.shared.resize(snapshot, to: options)
        try await Workspace.save(resized, to: url, opened: opened)
        return try json(["width": resized.manifest.width, "height": resized.manifest.height])
    }

    /// Canvas Size: grows or trims the canvas without resampling. --anchor says which part of the picture stays
    /// put: top-left, top, top-right, left, center (the default), right, bottom-left, bottom, bottom-right.
    static func canvasSize(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let url = try arguments.url(0, "the project")
        let opened = Workspace.lastWritten(url)
        let snapshot = try await ProjectStore.shared.load(from: url)
        guard let width = try arguments.integer("width") ?? Optional(snapshot.manifest.width),
              let height = try arguments.integer("height") ?? Optional(snapshot.manifest.height),
              arguments.has("width") || arguments.has("height") else {
            throw CommandError("canvas-size needs --width and/or --height")
        }
        let anchors = ["top-left", "top", "top-right", "left", "center", "right", "bottom-left", "bottom", "bottom-right"]
        var options = CanvasSizeOptions(width: width, height: height)
        if let text = arguments.string("anchor") {
            guard let index = anchors.firstIndex(of: text.lowercased()) else {
                throw CommandError("--anchor is one of: \(anchors.joined(separator: ", "))")
            }
            options.anchor = index
        }
        let resized = try await CanvasResizer.shared.resize(snapshot, to: options)
        try await Workspace.save(resized, to: url, opened: opened)
        return try json(["width": resized.manifest.width, "height": resized.manifest.height])
    }

    /// compositor-cli move-layer <project> <layer> --top | --bottom | --above <layer> | --into <folder>
    /// --top and --bottom stay within the layer's current folder; --out takes it to the top level.
    static func moveLayer(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        let layer = try workspace.layer(try arguments.required(1, "the layer's id or name"))
        let session = workspace.session
        let moved: Bool
        if let reference = arguments.string("into") {
            let folder = try workspace.layer(reference)
            guard folder.isGroup else { throw CommandError("'\(folder.name)' is not a folder") }
            moved = session.placeLayer(layer.id, in: folder.id)
        } else if let reference = arguments.string("above") {
            let target = try workspace.layer(reference)
            moved = session.placeLayer(layer.id, in: target.parentID, above: target.id)
        } else if arguments.flag("bottom") {
            moved = session.placeLayer(layer.id, in: layer.parentID, atBottom: true)
        } else if arguments.flag("top") {
            moved = session.placeLayer(layer.id, in: layer.parentID)
        } else if arguments.flag("out") {
            moved = session.placeLayer(layer.id, in: nil)
        } else {
            throw CommandError("move-layer needs --top, --bottom, --out, --above <layer> or --into <folder>")
        }
        guard moved else { throw CommandError("the layer cannot go there") }
        try await workspace.save()
        return try json(["moved": layer.id.uuidString])
    }

    /// An empty folder, or --blank for an empty pixel layer, above --above (or on top). --name names it.
    static func addEmptyLayer(_ raw: [String], folder: Bool) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        if let above = arguments.string("above") { try workspace.activate(above) }
        let session = workspace.session
        let before = Set(session.document?.layers.map(\.id) ?? [])
        if folder { session.addGroup() } else { session.addBlankLayer() }
        guard let id = session.document?.layers.map(\.id).first(where: { !before.contains($0) }) else {
            throw CommandError(folder ? "the folder could not be added" : "the layer could not be added")
        }
        if let name = arguments.string("name") { session.renameLayer(id, to: name) }
        try await workspace.save()
        return try json(["added": id.uuidString])
    }

    /// Writes the subject of a layer as a grayscale image (white over the subject) without changing the project,
    /// for use as a mask elsewhere.
    static func subjectMask(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        let layer = try workspace.layer(try arguments.required(1, "the layer's id or name"))
        guard let output = arguments.url(option: "out") else { throw CommandError("subject-mask needs --out <file.png>") }
        guard let image = layer.asset?.image else { throw CommandError("'\(layer.name)' has no pixels") }
        var settings = FilterSettings()
        if arguments.flag("advanced") { settings.backgroundQuality = .advanced }
        let mask = try await Task.detached { try SubjectRemoval.subjectMask(image, under: nil, settings: settings) }.value
        try write(mask, to: output, type: .png, properties: [:])
        return try json(["mask": output.path, "width": mask.width, "height": mask.height])
    }

    static func sampling(_ text: String) throws -> LayerSampling {
        guard let match = LayerSampling.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(text.lowercased()) }) else {
            throw CommandError("--sampling is one of: \(LayerSampling.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return match
    }
}
