import Foundation
import CoreGraphics

/// Text layers and layer effects from the command line: the app's own Type tool and Layer Effects.
extension Commands {
    /// compositor-cli add-text <project> "<text>" [--font F] [--size PX] [--color r,g,b] [--align left|center|right]
    ///                         [--tracking N] [--leading PX] [--x X --y Y] [--name N] [appearance]
    static func addText(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        let session = workspace.session
        guard let document = session.document else { throw CommandError("there is no document") }
        var style = LayerTextStyle()
        style.content = try arguments.required(1, "the text").replacingOccurrences(of: "\\n", with: "\n")
        style.fontName = "Helvetica-Bold"
        style.fontSize = max(12, (CGFloat(document.height) / 10).rounded())
        style.red = 1; style.green = 1; style.blue = 1
        try read(&style, arguments)
        // Centered unless a corner is given, as the tool's own placement is wherever it was clicked.
        let size = EditorSession.textBoxSize(style)
        let origin = try arguments.number("x").flatMap { x in try arguments.number("y").map { CGPoint(x: x, y: $0) } }
            ?? CGPoint(x: ((CGFloat(document.width) - size.width) / 2).rounded(), y: ((CGFloat(document.height) - size.height) / 2).rounded())
        let before = Set(document.layers.map(\.id))
        guard session.applyText(TextDraft(documentID: document.id, layerID: nil, origin: origin, style: style)),
              let id = session.document?.layers.map(\.id).first(where: { !before.contains($0) }) else {
            throw CommandError(session.brushError ?? "the text could not be set; check the size and font")
        }
        if let name = arguments.string("name") { session.renameLayer(id, to: name) }
        try appearance(workspace, arguments)
        try await workspace.save()
        return try json(["added": id.uuidString, "text": style.content, "font": style.fontName, "size": style.fontSize])
    }

    /// compositor-cli set-text <project> <layer> [--text "<text>"] [the same options as add-text]
    static func setText(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        let layer = try workspace.activate(try arguments.required(1, "the layer's id or name"))
        guard var style = layer.liveText?.style, let document = workspace.session.document else {
            throw CommandError("'\(layer.name)' is not a text layer (or was painted on, which makes it plain pixels)")
        }
        if let text = arguments.string("text") { style.content = text.replacingOccurrences(of: "\\n", with: "\n") }
        try read(&style, arguments)
        guard workspace.session.applyText(TextDraft(documentID: document.id, layerID: layer.id, origin: layer.transform.origin, style: style)) else {
            throw CommandError(workspace.session.brushError ?? "the text could not be changed")
        }
        try await workspace.save()
        return try json(["updated": layer.id.uuidString, "text": style.content, "font": style.fontName, "size": style.fontSize])
    }

    private static func read(_ style: inout LayerTextStyle, _ arguments: Arguments) throws {
        if let font = arguments.string("font") { style.fontName = font }
        if let size = try arguments.number("size") { style.fontSize = size }
        if let tracking = try arguments.number("tracking") { style.tracking = tracking }
        if let leading = try arguments.number("leading") { style.leading = leading }
        if let text = arguments.string("align") {
            guard let alignment = TextAlignment.allCases.first(where: { $0.rawValue.lowercased() == text.lowercased() }) else {
                throw CommandError("--align is left, center or right")
            }
            style.alignment = alignment
        }
        if let text = arguments.string("color") {
            let parts = text.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 3, parts.allSatisfy({ (0...255).contains($0) }) else { throw CommandError("--color is r,g,b with each 0–255") }
            style.red = parts[0] / 255; style.green = parts[1] / 255; style.blue = parts[2] / 255
        }
        guard style.isValid else { throw CommandError("text needs a size of 1–2000, tracking −100–1000 and leading 0–5000") }
    }

    /// compositor-cli add-effect <project> <layer> stroke|shadow|glow|inner-shadow|overlay [--size PX] [--distance PX]
    ///                           [--angle DEG] [--opacity 0-100] [--color r,g,b]
    /// The app's own layer effects: kept with the layer, following every later edit, and editable in its panel.
    static func addEffect(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        let layer = try workspace.activate(try arguments.required(1, "the layer's id or name"))
        let kinds: [String: LayerEffectKind] = ["stroke": .stroke, "shadow": .shadow, "glow": .outerGlow, "inner-shadow": .innerShadow, "overlay": .colorOverlay]
        guard let kind = kinds[try arguments.required(2, "the effect").lowercased()] else {
            throw CommandError("the effect is stroke, shadow, glow, inner-shadow or overlay")
        }
        let session = workspace.session
        guard session.canEditEffects else { throw CommandError("'\(layer.name)' cannot take effects; they need a layer with pixels") }
        var color: (CGFloat, CGFloat, CGFloat)?
        if let text = arguments.string("color") {
            let parts = text.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 3, parts.allSatisfy({ (0...255).contains($0) }) else { throw CommandError("--color is r,g,b with each 0–255") }
            color = (parts[0] / 255, parts[1] / 255, parts[2] / 255)
        }
        let size = try arguments.number("size"), distance = try arguments.number("distance"), angle = try arguments.number("angle")
        let opacity = try arguments.number("opacity").map { $0 / 100 }
        var effects = layer.effects ?? LayerEffects()
        switch kind {
        case .stroke:
            var effect = effects.stroke ?? StrokeEffect()
            if let size { effect.size = size }
            if let color { effect.red = color.0; effect.green = color.1; effect.blue = color.2 }
            if let opacity { effect.opacity = opacity }
            effects.stroke = effect
        case .shadow:
            var effect = effects.shadow ?? ShadowEffect()
            if let size { effect.blur = size }
            if let distance { effect.distance = distance }
            if let angle { effect.angle = angle }
            if let color { effect.red = color.0; effect.green = color.1; effect.blue = color.2 }
            if let opacity { effect.opacity = opacity }
            effects.shadow = effect
        case .outerGlow:
            var effect = effects.outerGlow ?? OuterGlowEffect()
            if let size { effect.size = size }
            if let color { effect.red = color.0; effect.green = color.1; effect.blue = color.2 }
            if let opacity { effect.opacity = opacity }
            effects.outerGlow = effect
        case .innerShadow:
            var effect = effects.innerShadow ?? InnerShadowEffect()
            if let size { effect.blur = size }
            if let distance { effect.distance = distance }
            if let angle { effect.angle = angle }
            if let color { effect.red = color.0; effect.green = color.1; effect.blue = color.2 }
            if let opacity { effect.opacity = opacity }
            effects.innerShadow = effect
        case .colorOverlay:
            var effect = effects.colorOverlay ?? ColorOverlayEffect()
            if let color { effect.red = color.0; effect.green = color.1; effect.blue = color.2 }
            if let opacity { effect.opacity = opacity }
            effects.colorOverlay = effect
        }
        guard effects.isValid else { throw CommandError("an effect setting is out of range") }
        session.setEffects(effects, on: layer.id, name: "Add " + kind.rawValue)
        try await workspace.save()
        return try json(["effect": kind.rawValue, "layer": layer.id.uuidString, "effects": effects.kinds.map(\.rawValue)])
    }
}
