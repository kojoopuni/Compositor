import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// Cropping, and the one-step cut-out built on it. A crop here is the app's own: layers shift and keep all their
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
        let canvas = CGRect(x: 0, y: 0, width: snapshot.manifest.width, height: snapshot.manifest.height)
        var box: CGRect
        if let text = arguments.string("box") {
            let parts = text.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4 else { throw CommandError("--box is x,y,width,height in document pixels") }
            box = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]).integral
        } else if arguments.flag("to-content") {
            let image = try await ImageExporter.shared.render(snapshot).image
            guard let content = try contentBounds(of: image) else { throw CommandError("the picture is entirely transparent") }
            let padding = CGFloat(max(0, try arguments.number("padding") ?? 0))
            box = content.insetBy(dx: -padding, dy: -padding).integral.intersection(canvas)
        } else {
            throw CommandError("crop needs --box x,y,width,height or --to-content")
        }
        guard box.width >= 1, box.height >= 1, box.width <= 30_000, box.height <= 30_000 else {
            throw CommandError("that crop is empty or too large")
        }
        let cropped = try await CanvasResizer.shared.resize(snapshot, to: CanvasSizeOptions(
            width: Int(box.width), height: Int(box.height), contentOffset: CGPoint(x: -box.minX, y: -box.minY)))
        try await Workspace.save(cropped, to: url, opened: opened)
        return try json(["x": Int(box.minX), "y": Int(box.minY), "width": Int(box.width), "height": Int(box.height)])
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
        let image = try await ImageExporter.shared.render(snapshot).image
        guard let content = try contentBounds(of: image) else { throw CommandError("nothing was left after removing the background") }
        let padding = CGFloat(max(0, try arguments.number("padding") ?? 0))
        let canvas = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let box = content.insetBy(dx: -padding, dy: -padding).integral.intersection(canvas)
        snapshot = try await CanvasResizer.shared.resize(snapshot, to: CanvasSizeOptions(
            width: Int(box.width), height: Int(box.height), contentOffset: CGPoint(x: -box.minX, y: -box.minY)))
        try await ImageExporter.shared.exportPNG(snapshot, to: output)

        var result: [String: Any] = ["cutout": output.path, "width": Int(box.width), "height": Int(box.height),
                                     "from": ["width": image.width, "height": image.height], "edge": edge]
        if let project = arguments.url(option: "project") {
            if FileManager.default.fileExists(atPath: project.path), !arguments.flag("overwrite") {
                throw CommandError("\(project.lastPathComponent) already exists; pass --overwrite to replace it")
            }
            try await ProjectStore.shared.save(snapshot, to: project)
            result["project"] = project.path
        }
        return try json(result)
    }

    /// The smallest rectangle holding every pixel that is more than faintly visible, in the image's own pixels
    /// (y down); nil when nothing is.
    static func contentBounds(of image: CGImage, threshold: UInt8 = 8) throws -> CGRect? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { throw CommandError("the picture could not be read") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            var first = -1, last = -1
            for x in 0..<width where bytes[row + x * 4 + 3] > threshold {
                if first < 0 { first = x }
                last = x
            }
            guard first >= 0 else { continue }
            minX = min(minX, first); maxX = max(maxX, last)
            minY = min(minY, y); maxY = y
        }
        guard maxX >= 0 else { return nil }
        // The bitmap's first row is the top of the picture, so these are already document coordinates.
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
