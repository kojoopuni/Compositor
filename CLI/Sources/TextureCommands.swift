import Foundation
import CoreGraphics

/// Commands for game textures.
extension Commands {
    /// The image with its broad light and dark areas flattened toward its average color, keeping all detail: each
    /// pixel loses the difference between a very blurred copy of the image and the image's mean. The blurred copy
    /// comes from shrinking the image to a few pixels and enlarging it again, which holds its edges steady where a
    /// true blur would fade them.
    static func evenLighting(_ image: CGImage) throws -> CGImage {
        let width = image.width, height = image.height
        let full = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: full)
        let small = try BrushRaster.context(width: 12, height: 12, mask: false)
        small.interpolationQuality = .high
        small.draw(image, in: CGRect(x: 0, y: 0, width: 12, height: 12))
        let broad = try BrushRaster.context(width: width, height: height, mask: false)
        broad.interpolationQuality = .high
        guard let tiny = small.makeImage() else { throw CommandError("the lighting could not be measured") }
        broad.draw(tiny, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = full.data?.assumingMemoryBound(to: UInt8.self),
              let light = broad.data?.assumingMemoryBound(to: UInt8.self) else { throw CommandError("the lighting could not be measured") }
        let count = width * height
        var mean = [Double](repeating: 0, count: 3)
        for index in 0..<count { for channel in 0..<3 { mean[channel] += Double(light[index * 4 + channel]) } }
        mean = mean.map { $0 / Double(count) }
        for index in 0..<count {
            let alpha = Double(pixels[index * 4 + 3])
            for channel in 0..<3 {
                let value = Double(pixels[index * 4 + channel]) - Double(light[index * 4 + channel]) + mean[channel]
                // Premultiplied: a color never exceeds its alpha.
                pixels[index * 4 + channel] = UInt8(max(0, min(alpha, value.rounded())))
            }
        }
        guard let result = full.makeImage() else { throw CommandError("the lighting could not be evened") }
        return result
    }

    /// compositor-cli make-tileable <project> <layer> [--band PERCENT] [--keep-lighting]
    /// Makes a layer repeat without visible seams. The pixels are slid half way round so the seams meet in the
    /// middle, a cross-shaped band over them is rebuilt from the texture around it (the app's Content-Aware Fill),
    /// and the pixels are slid back. --band is the width of that band as a percentage of the layer's shorter side.
    static func makeTileable(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        let layer = try workspace.activate(try arguments.required(1, "the layer's id or name"))
        let band = try arguments.number("band") ?? 12
        guard (2...40).contains(band) else { throw CommandError("--band is 2–40 (percent of the shorter side)") }
        guard layer.asset != nil, layer.transform.rotation == 0 else {
            throw CommandError("make-tileable needs an unrotated layer with pixels")
        }
        let session = workspace.session
        // Uneven lighting first: a texture that is brighter on one side cannot tile however well its seams are
        // healed, because the two sides meet at every repeat.
        if !arguments.flag("keep-lighting"), let image = layer.asset?.image {
            try session.replacePixels(of: layer.id, with: try evenLighting(image), name: "Even Lighting")
        }
        var half = FilterSettings()
        half.offsetHorizontal = 50; half.offsetVertical = 50
        try await apply(.offset, half, in: session)

        // The seams now run through the layer's center, top to bottom and side to side.
        guard let moved = session.activeLayer else { throw CommandError("the layer was lost") }
        let frame = CGRect(origin: moved.transform.origin, size: moved.transform.size)
        let thickness = min(frame.width, frame.height) * band / 100
        let cross = CGMutablePath()
        cross.addRect(CGRect(x: frame.midX - thickness / 2, y: frame.minY, width: thickness, height: frame.height))
        cross.addRect(CGRect(x: frame.minX, y: frame.midY - thickness / 2, width: frame.width, height: thickness))
        session.applySelection(cross, mode: .replace, name: "Select Seams")
        guard session.canContentAwareFill else { throw CommandError("the seams could not be selected on this layer") }
        try await apply(.contentAwareFill, FilterSettings(), in: session)
        session.deselect()

        var back = FilterSettings()
        back.offsetHorizontal = -50; back.offsetVertical = -50
        try await apply(.offset, back, in: session)
        try await workspace.save()
        return try json(["tileable": layer.id.uuidString, "band": band, "lightingEvened": !arguments.flag("keep-lighting")])
    }
}

extension EditorSession {
    /// New pixels for a layer, the same size as its old ones, as one undoable step.
    func replacePixels(of id: UUID, with image: CGImage, name: String) throws {
        guard canEditLayers, let index = document?.layers.firstIndex(where: { $0.id == id }),
              let old = document?.layers[index].asset, old.image.width == image.width, old.image.height == image.height else {
            throw CommandError("this layer's pixels cannot be replaced")
        }
        let asset = ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: old.name)
        beginEdit(name)
        document?.layers[index].asset = asset
        endEdit()
    }
}
