import CoreGraphics
import Foundation

/// Select > Color Range: a selection found from the active layer's pixels rather than drawn. (Select Subject is the app's own.)
nonisolated enum SmartSelection {
    /// The outline of every pixel of `image` within `tolerance` (0–255, per channel) of a color, wherever it is.
    static func outline(of color: PaletteColor, in image: CGImage, tolerance: Int) throws -> CGPath? {
        let width = image.width, height = image.height
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let wanted = [Int((color.red * 255).rounded()), Int((color.green * 255).rounded()), Int((color.blue * 255).rounded())]
        var selected = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let at = y * context.bytesPerRow + x * 4, alpha = Int(bytes[at + 3])
            guard alpha >= 128 else { continue }
            // Compared as the color it is, not as that color faded toward transparent.
            let near = (0..<3).allSatisfy { abs(min(255, Int(bytes[at + $0]) * 255 / alpha) - wanted[$0]) <= tolerance }
            if near { selected[y * width + x] = 1 }
        } }
        return try MagicWand.outline(of: selected, width: width, height: height)
    }
}

extension EditorSession {
    var canSelectFromPixels: Bool { canEditSelection && selectedLayerIDs.count <= 1 && activeLayer?.asset != nil && activeLayer?.isGroup == false }

    /// Selects everything on the active layer close to the foreground color, wherever it is. `tolerance` is 0–255.
    func selectColorRange(tolerance: Int = 40) async {
        guard canSelectFromPixels, let layer = activeLayer, let image = layer.asset?.image else { return }
        isProjectBusy = true
        defer { isProjectBusy = false }
        do {
            let color = foregroundColor
            let path = try await Task.detached(priority: .userInitiated) { try SmartSelection.outline(of: color, in: image, tolerance: tolerance) }.value
            try place(path, from: layer, image: image, name: "Color Range", empty: "Nothing on this layer is close to the foreground color. Pick a color from it with the Eyedropper first.")
        } catch { brushError = error.localizedDescription }
    }

    private func place(_ path: CGPath?, from layer: ImageLayer, image: CGImage, name: String, empty: String) throws {
        guard let path, !path.isEmpty else { brushError = empty; return }
        // From the layer's own pixels to where the layer sits in the document.
        var toDocument = BrushRaster.pixelToDocument(layer.transform, width: image.width, height: image.height)
        guard let placed = path.copy(using: &toDocument) else { throw ProjectError.invalid }
        isProjectBusy = false
        applySelection(placed, mode: selectionMode(shift: false, option: false), name: name)
    }
}
