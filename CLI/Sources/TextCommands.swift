import Foundation
import CoreGraphics

/// Text layers from the command line: the app's Layer > New Text Layer… and Edit Text….
extension Commands {
    /// compositor-cli add-text <project> "<text>" [--font F] [--size PX] [--color r,g,b] [--align left|center|right]
    ///                         [--tracking N] [--leading N] [--wrap PX] [--x X --y Y] [--name N] [appearance]
    static func addText(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        var style = TextStyle(string: try arguments.required(1, "the text").replacingOccurrences(of: "\\n", with: "\n"))
        if let height = workspace.session.document?.height { style.size = max(12, (Double(height) / 10).rounded()) }
        try read(&style, arguments)
        var origin: CGPoint?
        if let x = try arguments.number("x"), let y = try arguments.number("y") { origin = CGPoint(x: x, y: y) }
        guard let id = workspace.session.addTextLayer(style, at: origin) else {
            throw CommandError(workspace.session.brushError ?? "the text could not be set; check the size and font")
        }
        if let name = arguments.string("name") { workspace.session.renameLayer(id, to: name) }
        try appearance(workspace, arguments)
        try await workspace.save()
        return try json(["added": id.uuidString, "text": style.string, "font": style.font, "size": style.size])
    }

    /// compositor-cli set-text <project> <layer> [--text "<text>"] [the same options as add-text]
    static func setText(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        let layer = try workspace.activate(try arguments.required(1, "the layer's id or name"))
        guard var style = layer.liveText else { throw CommandError("'\(layer.name)' is not a text layer (or was painted on, which makes it plain pixels)") }
        if let text = arguments.string("text") { style.string = text.replacingOccurrences(of: "\\n", with: "\n") }
        try read(&style, arguments)
        workspace.session.updateTextLayer(layer.id, to: style)
        try await workspace.save()
        return try json(["updated": layer.id.uuidString, "text": style.string, "font": style.font, "size": style.size])
    }

    private static func read(_ style: inout TextStyle, _ arguments: Arguments) throws {
        if let font = arguments.string("font") { style.font = font }
        if let size = try arguments.number("size") { style.size = size }
        if let tracking = try arguments.number("tracking") { style.tracking = tracking }
        if let leading = try arguments.number("leading") { style.lineHeight = leading }
        if let wrap = try arguments.number("wrap") { style.wrapWidth = wrap }
        if let text = arguments.string("align") {
            guard let alignment = TextStyle.Alignment.allCases.first(where: { $0.rawValue.lowercased() == text.lowercased() }) else {
                throw CommandError("--align is left, center or right")
            }
            style.alignment = alignment
        }
        if let text = arguments.string("color") {
            let parts = text.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 3, parts.allSatisfy({ (0...255).contains($0) }) else { throw CommandError("--color is r,g,b with each 0–255") }
            style.red = parts[0] / 255; style.green = parts[1] / 255; style.blue = parts[2] / 255
        }
        guard style.isValid else { throw CommandError("text needs some characters, a size of 1–4000, tracking −200–1000 and leading 0.5–4") }
    }
}
