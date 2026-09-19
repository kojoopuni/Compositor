import Foundation
import CoreGraphics
import ImageIO

/// Commands that change pixels or add non-destructive adjustments, all through the session's own editors so
/// selection limits, layer growth (a blur spreading past the edge) and validation behave as they do in the app.
extension Commands {
    /// compositor-cli filter <project> <layer> <filter name> [settings]
    /// Settings: --radius, --angle, --distance, --amount, --gaussian, --monochromatic, --distortion,
    /// --horizontal, --vertical (Offset, percent), --exposure, --offset, --gamma, --keep-edges (blurs),
    /// --threshold (Unsharp Mask), --strength (Even Lighting 0–100, Height to Normal Map 0.1–50), --y-down,
    /// --no-wrap (normal map), --band, --lighting (Make Tileable), --cells (Clouds).
    static func filter(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        let layer = try workspace.activate(try arguments.required(1, "the layer's id or name"))
        let name = try arguments.required(2, "the filter's name")
        let usable = FilterKind.allCases.filter { $0 != .removeBackground && $0 != .contentAwareFill }
        guard let kind = usable.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else {
            throw CommandError("filters: \(usable.map(\.rawValue).joined(separator: ", "))")
        }
        var settings = FilterSettings()
        if let value = try arguments.number("radius") { settings.radius = value; settings.highPassRadius = value; settings.sharpenRadius = value }
        if let value = try arguments.number("angle") { settings.angle = value }
        if let value = try arguments.number("distance") { settings.distance = value }
        if let value = try arguments.number("amount") { settings.amount = value; settings.sharpenAmount = value }
        if let value = try arguments.number("threshold") { settings.sharpenThreshold = value }
        if let value = try arguments.number("strength") {
            if kind == .normalMap { settings.normalStrength = value } else { settings.lightingStrength = value }
        }
        if let value = try arguments.number("band") { settings.tileBand = value }
        if let value = try arguments.number("lighting") { settings.tileLighting = value }
        if let value = try arguments.number("cells") { settings.cloudCells = value }
        settings.keepEdges = arguments.flag("keep-edges")
        settings.normalYDown = arguments.flag("y-down")
        settings.normalWrap = !arguments.flag("no-wrap")
        if let value = try arguments.number("distortion") { settings.distortion = value }
        if let value = try arguments.number("horizontal") { settings.offsetHorizontal = value }
        if let value = try arguments.number("vertical") { settings.offsetVertical = value }
        settings.gaussian = arguments.flag("gaussian")
        settings.monochromatic = arguments.flag("monochromatic")
        try read(&settings.exposure, arguments)
        try await apply(kind, settings, in: workspace.session)
        try await workspace.save()
        return try json(["filtered": layer.id.uuidString, "filter": kind.rawValue])
    }

    /// Hides the background behind a layer mask, so nothing is erased. --edge clean (the default) gives a crisp
    /// outline sized to the image; --edge soft is the subject detector's own mask. --refine (pixels), --contrast
    /// (0–100) and --shift (pixels, negative contracts) override the clean edge's values.
    static func removeBackground(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        let layer = try workspace.activate(try arguments.required(1, "the layer's id or name"))
        let edge = arguments.string("edge")?.lowercased() ?? "clean"
        guard ["clean", "soft"].contains(edge) else { throw CommandError("--edge is clean or soft") }
        var settings = FilterSettings()
        if edge == "clean" || arguments.flag("advanced") {
            settings = cleanEdge(for: layer)
        }
        if let value = try arguments.number("refine") { settings.refineEdges = value }
        if let value = try arguments.number("contrast") { settings.matteContrast = value }
        if let value = try arguments.number("shift") { settings.shiftEdge = value }
        try await apply(.removeBackground, settings, in: workspace.session)
        try await workspace.save()
        return try json(["masked": layer.id.uuidString, "edge": edge, "refine": settings.refineEdges,
                         "contrast": settings.matteContrast, "shift": settings.shiftEdge])
    }

    /// The detector's mask is made small and stretched over the layer, so its edge is a haze whose width grows with
    /// the image: about 15 px on a 3,500 px screenshot, invisible on a 500 px picture. These values clear that
    /// haze and pull the edge in just past it, in proportion to the layer's longer side.
    static func cleanEdge(for layer: ImageLayer) -> FilterSettings {
        let longest = Double(max(layer.asset?.image.width ?? 0, layer.asset?.image.height ?? 0))
        var settings = FilterSettings()
        settings.backgroundQuality = .advanced
        settings.refineEdges = min(12, max(3, (longest / 576).rounded()))
        settings.matteContrast = 65
        settings.shiftEdge = -min(3, max(0.5, (longest / 3456 * 2).rounded() / 2))
        return settings
    }

    static func apply(_ kind: FilterKind, _ settings: FilterSettings, in session: EditorSession) async throws {
        session.beginFilter(kind)
        guard session.filterEdit != nil else {
            throw CommandError("\(kind.rawValue) needs a single visible layer with pixels")
        }
        session.updateFilter(settings, preview: true)
        await session.commitFilter()
        // An automatic filter commits only once its preview has settled, and the change of settings above may have
        // queued a second one behind the first.
        var waits = 0
        while let edit = session.filterEdit, edit.previewError == nil, waits < 8 {
            await edit.previewTask?.value
            await session.commitFilter()
            waits += 1
        }
        if let edit = session.filterEdit {
            let reason = edit.previewError ?? "the filter could not be applied"
            session.cancelFilter()
            throw CommandError(reason)
        }
        // A failure while committing is shown in the app as a brush error.
        if let reason = session.brushError { throw CommandError(reason) }
    }

    /// compositor-cli add-adjustment <project> <kind> [--above <layer>] [settings]
    /// Levels: --black --gamma --white --output-black --output-white. Hue/Saturation: --hue --saturation
    /// --lightness --colorize. Exposure: --exposure --offset --gamma. Others start at their defaults.
    static func addAdjustment(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        let name = try arguments.required(1, "the adjustment's name")
        guard let kind = AdjustmentKind.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else {
            throw CommandError("adjustments: \(AdjustmentKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        if let above = arguments.string("above") { try workspace.activate(above) }
        let session = workspace.session
        session.addAdjustment(kind)
        // The app opens the adjustment's panel straight away; here the values arrive with the command.
        session.adjustmentEditingID = nil
        guard let id = session.activeLayerID, var adjustment = session.activeLayer?.adjustment else {
            throw CommandError("the adjustment layer could not be added")
        }
        switch kind {
        case .levels:
            var range = LevelRange()
            if let value = try arguments.number("black") { range.black = value }
            if let value = try arguments.number("gamma") { range.gamma = value }
            if let value = try arguments.number("white") { range.white = value }
            if let value = try arguments.number("output-black") { range.outputBlack = value }
            if let value = try arguments.number("output-white") { range.outputWhite = value }
            adjustment.levels.current = range
        case .hsv:
            adjustment.hsvSettings = HueSaturationSettings(hue: try arguments.number("hue") ?? 0,
                saturation: try arguments.number("saturation") ?? 0, lightness: try arguments.number("lightness") ?? 0,
                colorize: arguments.flag("colorize"))
        case .exposure:
            try read(&adjustment.exposure, arguments)
        case .curves, .gradientMap, .grain:
            break
        }
        guard adjustment.isValid else { throw CommandError("those settings are out of range") }
        session.updateAdjustment(id, value: adjustment)
        if let name = arguments.string("name") { session.renameLayer(id, to: name) }
        try await workspace.save()
        return try json(["added": id.uuidString, "adjustment": kind.rawValue])
    }

    private static func read(_ exposure: inout ExposureSettings, _ arguments: Arguments) throws {
        if let value = try arguments.number("exposure") { exposure.exposure = value }
        if let value = try arguments.number("offset") { exposure.offset = value }
        if let value = try arguments.number("gamma") { exposure.gamma = value }
        guard exposure.isValid else { throw CommandError("exposure is −20–20, offset −0.5–0.5, gamma 0.01–9.99") }
    }

    /// compositor-cli set-mask <project> <layer> <grayscale image> — white reveals, black hides. The image is
    /// fitted to the layer's own pixels. --remove deletes the mask; --enabled true/false switches it.
    static func setMask(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        let layer = try workspace.activate(try arguments.required(1, "the layer's id or name"))
        let session = workspace.session
        if arguments.flag("remove") {
            session.deleteLayerMask()
        } else if arguments.positionals.count > 2 {
            let width = layer.asset?.image.width ?? Int(layer.size.width.rounded())
            let height = layer.asset?.image.height ?? Int(layer.size.height.rounded())
            let mask = try grayscale(try arguments.url(2, "the mask image"), width: width, height: height)
            try session.installMask(LayerMask(asset: try LayerMask.asset(from: mask)), on: layer.id)
        }
        if let enabled = try arguments.boolean("enabled"), session.activeLayer?.mask?.isEnabled == !enabled {
            session.toggleLayerMask()
        }
        try await workspace.save()
        return try json(["masked": layer.id.uuidString, "hasMask": session.activeLayer?.mask != nil])
    }

    /// Any image file as 8-bit gray without alpha at `width` × `height`, which is what a layer mask stores.
    /// Transparent areas count as black (hidden).
    private static func grayscale(_ url: URL, width: Int, height: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CommandError("\(url.lastPathComponent) could not be read as an image")
        }
        guard width > 0, height > 0, width * height <= 100_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw CommandError("the mask could not be prepared")
        }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw CommandError("the mask could not be prepared") }
        return result
    }
}

extension EditorSession {
    /// Gives a layer a finished mask in one undoable step, replacing any it had.
    func installMask(_ mask: LayerMask, on id: UUID) throws {
        guard canEditLayers, let index = document?.layers.firstIndex(where: { $0.id == id }) else {
            throw CommandError("this layer cannot take a mask")
        }
        beginEdit("Set Layer Mask")
        document?.layers[index].mask = mask
        endEdit()
    }
}
