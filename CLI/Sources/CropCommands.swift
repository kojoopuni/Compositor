import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// Cropping, and the one-step cut-out built on it. A crop here is the app's own (Image > Trim Transparent Pixels and the Crop tool): layers shift and keep all their
/// pixels, so growing the canvas again brings back what was cropped away.
extension Commands {
    /// compositor-cli crop <project> --box x,y,width,height | --to-content [--padding PX]
    /// --to-content crops to everything that is not transparent in the finished picture, which after
    /// remove-background means the subject.
    static func crop(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let url = try arguments.url(0, "the project")
        let opened = Workspace.lastWritten(url)
        let snapshot = try await ProjectStore.shared.load(from: url)
        var box: CGRect?
        if let text = arguments.string("box") {
            let parts = text.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4 else { throw CommandError("--box is x,y,width,height in document pixels") }
            box = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        } else if !arguments.flag("to-content") {
            throw CommandError("crop needs --box x,y,width,height or --to-content")
        }
        let padding = CGFloat(max(0, try arguments.number("padding") ?? 0))
        guard let result = try await Trim.cropped(snapshot, to: box, padding: padding) else {
            throw CommandError("the picture is entirely transparent")
        }
        let cropped = result.snapshot, kept = result.box
        try await Workspace.save(cropped, to: url, opened: opened)
        return try json(["x": Int(kept.minX), "y": Int(kept.minY), "width": Int(kept.width), "height": Int(kept.height)])
    }

    /// compositor-cli cutout <image> --out subject.png [--padding PX] [--edge clean|soft] [--project keep.comp]
    /// One step from a photo to its subject on transparency, cropped to the subject. --project also keeps the
    /// layered project, with the background still there behind a mask.
    static func cutout(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let source = try arguments.url(0, "the image file")
        guard let output = arguments.url(option: "out"), output.pathExtension.lowercased() == "png" else {
            throw CommandError("cutout needs --out <file.png>")
        }
        let asset = try await ImageImporter.shared.decode(source)
        let session = EditorSession()
        // With no document yet, inserting an image makes a canvas of exactly its size.
        session.insert(asset)
        guard let layer = session.activeLayer else { throw CommandError("the image could not be opened") }
        session.renameLayer(layer.id, to: "Photo")

        let edge = arguments.string("edge")?.lowercased() ?? "clean"
        guard ["clean", "soft"].contains(edge) else { throw CommandError("--edge is clean or soft") }
        var settings = edge == "clean" ? cleanEdge(for: layer) : FilterSettings()
        if let value = try arguments.number("refine") { settings.refineEdges = value }
        if let value = try arguments.number("contrast") { settings.matteContrast = value }
        if let value = try arguments.number("shift") { settings.shiftEdge = value }
        try await apply(.removeBackground, settings, in: session)

        guard var snapshot = session.projectSnapshot() else { throw CommandError("there is no document") }
        let full = (width: snapshot.manifest.width, height: snapshot.manifest.height)
        let padding = CGFloat(max(0, try arguments.number("padding") ?? 0))
        guard let trimmed = try await Trim.cropped(snapshot, to: nil, padding: padding) else {
            throw CommandError("nothing was left after removing the background")
        }
        snapshot = trimmed.snapshot
        let box = trimmed.box
        try await ImageExporter.shared.exportPNG(snapshot, to: output)

        var result: [String: Any] = ["cutout": output.path, "width": Int(box.width), "height": Int(box.height),
                                     "from": ["width": full.width, "height": full.height], "edge": edge]
        if let project = arguments.url(option: "project") {
            if FileManager.default.fileExists(atPath: project.path), !arguments.flag("overwrite") {
                throw CommandError("\(project.lastPathComponent) already exists; pass --overwrite to replace it")
            }
            try await ProjectStore.shared.save(snapshot, to: project)
            result["project"] = project.path
        }
        return try json(result)
    }
}
