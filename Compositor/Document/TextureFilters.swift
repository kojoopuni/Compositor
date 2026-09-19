import CoreGraphics
import CoreImage

/// The filters for making and preparing textures. Each takes a layer's pixels and returns new ones the same size;
/// `PixelFilter.run` confines the result to the selection like any other filter.
nonisolated enum TextureFilter {
    /// A copy of the image's pixels that can be written to, and the means to turn them back into an image.
    private static func editable(_ image: CGImage) throws -> CGContext {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        return context
    }
    private static func bytes(_ context: CGContext) throws -> UnsafeMutablePointer<UInt8> {
        guard let data = context.data else { throw ExportError.render }
        return data.assumingMemoryBound(to: UInt8.self)
    }
    private static func image(_ context: CGContext) throws -> CGImage {
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }
    /// A Gaussian blur that holds the image's border steady instead of fading it: only the detail is wanted here.
    private static func blurred(_ source: CGImage, sigma: Double) throws -> CGContext {
        let soft = CIImage(cgImage: source).clampedToExtent().applyingGaussianBlur(sigma: max(0.1, sigma))
        return try editable(try PixelAdjust.render(soft, width: source.width, height: source.height, isMask: false))
    }

    static func highPass(_ source: CGImage, radius: Double) throws -> CGImage {
        let pixels = try editable(source), soft = try blurred(source, sigma: radius)
        texture_high_pass(try bytes(pixels), try bytes(soft), source.width, source.height, pixels.bytesPerRow)
        return try image(pixels)
    }

    static func unsharpMask(_ source: CGImage, amount: Double, radius: Double, threshold: Double) throws -> CGImage {
        let pixels = try editable(source), soft = try blurred(source, sigma: radius)
        texture_unsharp(try bytes(pixels), try bytes(soft), source.width, source.height, pixels.bytesPerRow,
                        Float(amount / 100), Int32(threshold.rounded()))
        return try image(pixels)
    }

    /// Broad light and shade flattened toward the image's average color. The very blurred copy it works from is the
    /// image shrunk to a few pixels and enlarged again, which keeps its borders steady where a true blur of that
    /// size would fade them.
    static func evenLighting(_ source: CGImage, strength: Double) throws -> CGImage {
        guard strength > 0 else { return source }
        let width = source.width, height = source.height
        let small = try BrushRaster.context(width: 12, height: 12, mask: false)
        small.interpolationQuality = .high
        small.draw(source, in: CGRect(x: 0, y: 0, width: 12, height: 12))
        // Drawn straight into these flipped bitmaps the picture is upside down, and drawing it again turns it back.
        let broad = try BrushRaster.context(width: width, height: height, mask: false)
        broad.interpolationQuality = .high
        broad.draw(try image(small), in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try editable(source)
        texture_even_lighting(try bytes(pixels), try bytes(broad), width, height, pixels.bytesPerRow, Float(strength / 100))
        return try image(pixels)
    }

    /// A blurred image given back the outline it had: soft inside, solid at the edges.
    static func restoreEdges(_ blurred: CGImage, original: CGImage) throws -> CGImage {
        let soft = try editable(blurred), sharp = try editable(original)
        texture_restore_edges(try bytes(soft), try bytes(sharp), original.width, original.height, soft.bytesPerRow)
        return try image(soft)
    }

    static func normalMap(_ source: CGImage, strength: Double, yDown: Bool, wrap: Bool) throws -> CGImage {
        let heights = try editable(source)
        let normals = try BrushRaster.context(width: source.width, height: source.height, mask: false)
        texture_normal_map(try bytes(heights), try bytes(normals), source.width, source.height, heights.bytesPerRow,
                           Float(strength), yDown ? 1 : 0, wrap ? 1 : 0)
        return try image(normals)
    }

    static func clouds(width: Int, height: Int, cells: Double, seed: UInt32) throws -> CGImage {
        let pixels = try BrushRaster.context(width: width, height: height, mask: false)
        texture_clouds(try bytes(pixels), width, height, pixels.bytesPerRow, Int32(cells.rounded()), seed)
        return try image(pixels)
    }

    /// Makes the image repeat without visible seams: its lighting is evened (a texture brighter on one side cannot
    /// tile), its pixels slid half way round so the seams meet in the middle, a cross-shaped band over them rebuilt
    /// from the texture around it, and the pixels slid back. `band` is the rebuilt band's width as a percentage of
    /// the shorter side.
    static func makeTileable(_ source: CGImage, band: Double, lighting: Double) throws -> CGImage {
        let width = source.width, height = source.height
        guard width >= 8, height >= 8 else { return source }
        let half = (x: width / 2, y: height / 2)
        var work = try PixelFilter.wrapped(try evenLighting(source, strength: lighting), by: half)
        let thickness = max(2, (Double(min(width, height)) * band / 100).rounded())
        let cross = CGMutablePath()
        cross.addRect(CGRect(x: Double(half.x) - thickness / 2, y: 0, width: thickness, height: Double(height)))
        cross.addRect(CGRect(x: 0, y: Double(half.y) - thickness / 2, width: Double(width), height: thickness))
        let seams = try DocumentSelection(path: cross, antialiased: false).clip(canvas: CGSize(width: width, height: height))
        work = try ContentFill.run(FilterJob(kind: .contentAwareFill, image: work, settings: FilterSettings(), scale: 1,
                                             selection: seams, mapping: .identity))
        return try PixelFilter.wrapped(work, by: (width - half.x, height - half.y))
    }
}
