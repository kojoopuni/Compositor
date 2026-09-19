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
        guard let name = arguments.first, name != "help", name != "--help" else { return usage }
        let rest = Array(arguments.dropFirst())
        switch name {
        case "info": return try await info(rest)
        case "new": return try await new(rest)
        case "add-layer": return try await addLayer(rest)
        case "set-layer": return try await setLayer(rest)
        case "delete-layer": return try await deleteLayer(rest)
        case "add-folder": return try await addEmptyLayer(rest, folder: true)
        case "add-blank-layer": return try await addEmptyLayer(rest, folder: false)
        case "move-layer": return try await moveLayer(rest)
        case "resize": return try await resize(rest)
        case "canvas-size": return try await canvasSize(rest)
        case "subject-mask": return try await subjectMask(rest)
        case "filter": return try await filter(rest)
        case "remove-background": return try await removeBackground(rest)
        case "add-adjustment": return try await addAdjustment(rest)
        case "set-mask": return try await setMask(rest)
        case "render": return try await render(rest)
        case "sample": return try await sample(rest)
        case "export": return try await export(rest)
        default: throw CommandError("unknown command '\(name)'; run compositor-cli help")
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

    static let usage = """
        compositor-cli <command> <project.comp> [arguments]   Layers are named by id or by name.

          info             <project>
          new              <project> --width W --height H [--overwrite]
          add-layer        <project> <image> [--name N] [placement] [appearance]
          add-blank-layer  <project> [--name N] [--above LAYER]
          add-folder       <project> [--name N] [--above LAYER]
          set-layer        <project> <layer> [--name N] [--visible true|false] [placement] [appearance]
          move-layer       <project> <layer> --top | --bottom | --out | --above LAYER | --into FOLDER
          delete-layer     <project> <layer>
          set-mask         <project> <layer> [<grayscale image>] [--remove] [--enabled true|false]
          remove-background <project> <layer> [--edge clean|soft] [--refine PX --contrast 0-100 --shift PX]
          subject-mask     <project> <layer> --out mask.png [--edge clean|soft]
          filter           <project> <layer> "<filter name>" [--radius --angle --distance --amount --gaussian
                           --monochromatic --distortion --exposure --offset --gamma]
          add-adjustment   <project> "<kind>" [--above LAYER] [--name N] [Levels: --black --gamma --white
                           --output-black --output-white | Hue/Saturation: --hue --saturation --lightness
                           --colorize | Exposure: --exposure --offset --gamma]
          resize           <project> --width W | --height H | --scale PERCENT [--resolution PPI] [--sampling S]
          canvas-size      <project> [--width W] [--height H] [--anchor center|top-left|...]
          render           <project> --out view.png [--region x,y,w,h] [--max-size PX]
          sample           <project> --at x,y
          export           <project> --out file.png|.jpg [--quality 0-100] [--matte r,g,b]

          placement:  --x --y --width --height --scale PERCENT --rotation DEG --flip-x B --flip-y B --sampling S
          appearance: --opacity 0-100 --blend "<mode name>"
        """

    static func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
