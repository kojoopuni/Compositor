import CoreGraphics
import CoreImage

/// Color Burn and Color Dodge, blended the way the PDF spec (and Photoshop) define them, and the modes Core Graphics
/// does not have at all: Linear Dodge, Linear Burn, Vivid Light, Linear Light, Pin Light, Divide and Subtract.
///
/// Core Graphics gets these two wrong: its `.colorBurn` and `.colorDodge` ignore how transparent the source is, so
/// a soft brush comes out with a hard edge. Every other mode it has is right. Core Image's versions are correct, so
/// a layer in one of these modes is drawn into a copy of the canvas, blended there, and the result put back.
nonisolated enum SeparableBlend {
    static func isCoreGraphicsWrong(_ mode: LayerBlendMode) -> Bool { mode.coreImageFilter != nil }
    /// Unmanaged, like `PixelAdjust`: left to itself Core Image blends in linear light, where these modes give
    /// different (darker) results than the sRGB values every other mode, and Photoshop, blend.
    private static let ciContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Draws one layer into `context` in `mode`. `body` draws it as it would be drawn normally, into a context laid
    /// out exactly like `context`. Only a bitmap-backed context can be read back, so anywhere else this reports
    /// false and the caller draws with Core Graphics as before.
    static func draw(_ mode: LayerBlendMode, in context: CGContext, body: (CGContext) -> Void) -> Bool {
        guard isCoreGraphicsWrong(mode), context.data != nil, context.width > 0, context.height > 0,
              let name = mode.coreImageFilter, let filter = CIFilter(name: name),
              let backdrop = context.makeImage(),
              let surface = CGContext(data: nil, width: context.width, height: context.height, bitsPerComponent: 8,
                                      bytesPerRow: context.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return false }
        // The same placement as the canvas it will be blended into.
        surface.concatenate(context.ctm)
        body(surface)
        guard let source = surface.makeImage() else { return false }
        filter.setValue(CIImage(cgImage: source), forKey: kCIInputImageKey)
        filter.setValue(CIImage(cgImage: backdrop), forKey: kCIInputBackgroundImageKey)
        let frame = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        guard let output = filter.outputImage,
              let blended = ciContext.createCGImage(output, from: frame, format: .RGBA8, colorSpace: space) else { return false }
        context.saveGState()
        context.concatenate(context.ctm.inverted())
        context.setBlendMode(.copy)
        context.setAlpha(1)
        context.draw(blended, in: frame)
        context.restoreGState()
        return true
    }
}
