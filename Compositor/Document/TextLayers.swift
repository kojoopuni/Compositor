import AppKit
import CoreText

/// What a text layer says and how it is set. It rides in the layer's shape slot (`LayerShapeStyle.text`), so a text
/// layer is saved, duplicated, resized and undone by everything that already handles shape layers, and — like a
/// shape — its pixels are an ordinary raster that clips, masks, blends and filters like any layer. Paint on it or
/// filter it and it becomes plain pixels; until then it can be edited and re-set at any size without going soft.
nonisolated struct TextStyle: Codable, Equatable, Sendable {
    var string: String
    /// A PostScript or family name; anything the system cannot find falls back to the system font.
    var font = "Helvetica Neue Bold"
    /// Document pixels.
    var size: Double = 96
    var red: Double = 1, green: Double = 1, blue: Double = 1
    var alignment = Alignment.left
    /// Extra space between lines, as a multiple of the font's own line height; 1 is as designed.
    var lineHeight: Double = 1
    /// Extra space between letters, in thousandths of the font size, as in Photoshop.
    var tracking: Double = 0
    /// Wraps at this width in document pixels; nil lets each line run as long as it is.
    var wrapWidth: Double?

    enum Alignment: String, Codable, CaseIterable, Sendable { case left = "Left", center = "Center", right = "Right" }

    var isValid: Bool {
        !string.isEmpty && string.utf8.count <= 100_000 && [size, red, green, blue, lineHeight, tracking].allSatisfy(\.isFinite)
            && (1...4000).contains(size) && (0.5...4).contains(lineHeight) && (-200...1000).contains(tracking)
            && (wrapWidth.map { $0.isFinite && (8...30_000).contains($0) } ?? true)
    }
}

/// Text set with Core Text into a transparent image exactly as large as the text needs.
nonisolated enum TextRaster {
    /// Room around the glyphs for what reaches past the typographic bounds: italic overhang, swashes, accents.
    private static func padding(_ style: TextStyle) -> CGFloat { (CGFloat(style.size) * 0.12).rounded(.up) + 2 }

    private static func attributed(_ style: TextStyle) -> NSAttributedString {
        let font = NSFont(name: style.font, size: style.size)
            ?? NSFontManager.shared.font(withFamily: style.font, traits: [], weight: 5, size: style.size)
            ?? NSFont.systemFont(ofSize: style.size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment == .left ? .left : style.alignment == .center ? .center : .right
        paragraph.lineHeightMultiple = style.lineHeight
        return NSAttributedString(string: style.string, attributes: [
            .font: font, .paragraphStyle: paragraph, .kern: style.tracking / 1000 * style.size,
            .foregroundColor: NSColor(srgbRed: style.red, green: style.green, blue: style.blue, alpha: 1),
        ])
    }

    /// The size of the image `image(_:)` makes for this text.
    static func naturalSize(_ style: TextStyle) -> CGSize {
        let setter = CTFramesetterCreateWithAttributedString(attributed(style))
        let limit = CGSize(width: style.wrapWidth.map { CGFloat($0) } ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let text = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, limit, nil)
        let pad = padding(style)
        return CGSize(width: max(1, ceil(style.wrapWidth.map { CGFloat($0) } ?? text.width) + pad * 2), height: max(1, ceil(text.height) + pad * 2))
    }

    /// The text drawn at its natural size, or stretched to `fitting` — drawn as outlines at that size, so it is sharp
    /// however far the layer was scaled.
    static func image(_ style: TextStyle, fitting: CGSize? = nil) throws -> CGImage {
        let natural = naturalSize(style), size = fitting ?? natural
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width >= 1, height >= 1, width <= 30_000, height <= 30_000, width * height <= 100_000_000 else { throw ProjectError.tooLarge }
        // Core Text draws with y pointing up, which a plain bitmap context already has; its rows still run top to bottom.
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw ExportError.render }
        context.scaleBy(x: CGFloat(width) / natural.width, y: CGFloat(height) / natural.height)
        let pad = padding(style)
        let box = CGRect(x: pad, y: pad, width: natural.width - pad * 2, height: natural.height - pad * 2)
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed(style)), CFRange(), CGPath(rect: box, transform: nil), nil)
        CTFrameDraw(frame, context)
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }
}

extension ImageLayer {
    /// The text this layer still is: nil for other layers, and once its pixels were edited some other way.
    var liveText: TextStyle? { liveShape?.style.text }
}

extension EditorSession {
    var activeText: TextStyle? { activeLayer?.liveText }

    private func shape(for style: TextStyle, image: CGImage) -> LayerShape {
        LayerShape(style: LayerShapeStyle(kind: .rectangle, red: style.red, green: style.green, blue: style.blue, cornerRadius: 0, text: style), image: image)
    }

    /// A new text layer on top, centered on the canvas unless `origin` says where its top-left corner goes.
    @discardableResult
    func addTextLayer(_ style: TextStyle, at origin: CGPoint? = nil) -> UUID? {
        guard canEditLayers, let document, style.isValid else { return nil }
        do {
            let image = try TextRaster.image(style)
            let place = origin ?? CGPoint(x: ((CGFloat(document.width) - CGFloat(image.width)) / 2).rounded(),
                                          y: ((CGFloat(document.height) - CGFloat(image.height)) / 2).rounded())
            let before = Set(document.layers.map(\.id))
            addPixelLayer(image, at: place, name: Self.layerName(for: style), editName: "New Text Layer", dropsSelection: false,
                          shape: shape(for: style, image: image))
            return self.document?.layers.map(\.id).first { !before.contains($0) }
        } catch { brushError = error.localizedDescription; return nil }
    }

    /// New words or a new look for a text layer, as one undo step. The layer keeps its top-left corner, its rotation
    /// and everything else about it; its size follows the text.
    func updateTextLayer(_ id: UUID, to style: TextStyle, renames: Bool = true) {
        guard canEditLayers, style.isValid, let index = document?.layers.firstIndex(where: { $0.id == id }),
              let layer = document?.layers[index], let old = layer.liveText, old != style,
              let image = try? TextRaster.image(style), let thumbnail = try? PixelInvert.thumbnail(of: image) else { return }
        beginEdit("Edit Text")
        if let mask = layer.mask, mask.placement == nil { document?.layers[index].mask?.placement = layer.maskTransform }
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: layer.asset?.name ?? "Text")
        document?.layers[index].shape = shape(for: style, image: image)
        document?.layers[index].transform.size = CGSize(width: image.width, height: image.height)
        if renames, layer.name == Self.layerName(for: old) { document?.layers[index].name = Self.layerName(for: style) }
        endEdit()
    }

    /// Scaled with the Move tool, a text layer is set again at its new size instead of being stretched: its font size
    /// follows the scale. Part of the edit that changed the size (see `redrawShape`).
    func redrawText(at index: Int) -> Bool {
        guard let layer = document?.layers[index], var style = layer.liveText, let asset = layer.asset else { return false }
        let width = max(1, Int(layer.transform.size.width.rounded())), height = max(1, Int(layer.transform.size.height.rounded()))
        guard width != asset.image.width || height != asset.image.height else { return true }
        let natural = TextRaster.naturalSize(style)
        let factor = ((CGFloat(width) / natural.width) * (CGFloat(height) / natural.height)).squareRoot()
        style.size = min(4000, max(1, style.size * Double(factor)))
        if let wrap = style.wrapWidth { style.wrapWidth = min(30_000, max(8, wrap * Double(factor))) }
        guard let image = try? TextRaster.image(style, fitting: CGSize(width: width, height: height)),
              let thumbnail = try? PixelInvert.thumbnail(of: image) else { return true }
        if let mask = layer.mask, mask.placement == nil { document?.layers[index].mask?.placement = layer.maskTransform }
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].shape = shape(for: style, image: image)
        return true
    }

    static func layerName(for style: TextStyle) -> String {
        let line = style.string.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Text"
        return line.count > 32 ? String(line.prefix(32)) + "…" : line
    }
}
