import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The flattened picture in the other formats game engines and 3D tools take.
nonisolated enum ExportFormat: String, CaseIterable, Sendable {
    case tiff = "TIFF", tga = "TGA"
    var fileExtension: String { self == .tiff ? "tiff" : "tga" }
    var contentType: UTType { self == .tiff ? .tiff : (UTType(filenameExtension: "tga") ?? .data) }
}

/// Color spread under the transparent pixels around a cut-out, so a game engine's texture filtering blends the
/// edge with a matching color instead of black and leaves no dark halo. It exists only in exported files: inside
/// the editor color is stored multiplied by alpha, where a fully transparent pixel has no color to keep.
nonisolated enum EdgeBleed {
    /// The image as straight RGBA bytes, top row first, with color bled `distance` pixels into the transparency.
    static func straightPixels(of image: CGImage, distance: Int) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let width = image.width, height = image.height
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let source = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let line = source + y * context.bytesPerRow
            for x in 0..<width {
                let alpha = Int(line[x * 4 + 3]), at = (y * width + x) * 4
                guard alpha > 0 else { continue }
                for channel in 0..<3 { bytes[at + channel] = UInt8(min(255, (Int(line[x * 4 + channel]) * 255 + alpha / 2) / alpha)) }
                bytes[at + 3] = UInt8(alpha)
            }
        }
        if distance > 0 {
            var scratch = [UInt8](repeating: 0, count: width * height)
            texture_edge_bleed(&bytes, &scratch, width, height, width * 4, Int32(min(distance, 256)))
        }
        return (bytes, width, height)
    }

    /// A PNG whose transparent pixels keep their bled color, which needs the file written from straight alpha.
    static func pngData(_ image: CGImage, distance: Int, resolution: Double) throws -> Data {
        let pixels = try straightPixels(of: image, distance: distance)
        guard let provider = CGDataProvider(data: Data(pixels.bytes) as CFData),
              let straight = CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: pixels.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ExportError.encode }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ExportError.encode }
        CGImageDestinationAddImage(destination, straight, [kCGImagePropertyDPIWidth: resolution, kCGImagePropertyDPIHeight: resolution] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encode }
        return data as Data
    }
}

extension ImageExporter {
    /// A PNG with color bled `bleed` pixels under the transparency around its contents; see `EdgeBleed`.
    func pngData(_ snapshot: ProjectSnapshot, bleed: Int) throws -> Data {
        let raster = try render(snapshot)
        return try EdgeBleed.pngData(raster.image, distance: bleed, resolution: raster.resolution)
    }

    func data(_ snapshot: ProjectSnapshot, as format: ExportFormat, bleed: Int = 0) throws -> Data {
        let raster = try render(snapshot)
        switch format {
        case .tiff:
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil) else {
                throw ExportError.encode
            }
            CGImageDestinationAddImage(destination, raster.image, [
                kCGImagePropertyDPIWidth: raster.resolution, kCGImagePropertyDPIHeight: raster.resolution,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5], // LZW: lossless and widely read.
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ExportError.encode }
            return data as Data
        case .tga:
            return try TGAEncoder.data(raster.image, bleed: bleed)
        }
    }
}

/// Truevision TGA, which ImageIO reads but cannot write: uncompressed 32-bit, top row first, with straight
/// (not premultiplied) alpha as engines expect.
nonisolated enum TGAEncoder {
    static func data(_ image: CGImage, bleed: Int = 0) throws -> Data {
        let width = image.width, height = image.height
        guard (1...65_535).contains(width), (1...65_535).contains(height) else { throw ExportError.tooLarge }
        let pixels = try EdgeBleed.straightPixels(of: image, distance: bleed).bytes
        var header = [UInt8](repeating: 0, count: 18)
        header[2] = 2                                              // uncompressed true color
        header[12] = UInt8(width & 0xFF); header[13] = UInt8(width >> 8)
        header[14] = UInt8(height & 0xFF); header[15] = UInt8(height >> 8)
        header[16] = 32                                            // bits per pixel
        header[17] = 0x28                                          // 8 alpha bits, rows from the top
        var bytes = Data(header)
        bytes.reserveCapacity(18 + width * height * 4)
        var row = [UInt8](repeating: 0, count: width * 4)
        for y in 0..<height {
            for x in 0..<width {
                let at = (y * width + x) * 4
                row[x * 4] = pixels[at + 2]; row[x * 4 + 1] = pixels[at + 1]            // blue, green, red, alpha
                row[x * 4 + 2] = pixels[at]; row[x * 4 + 3] = pixels[at + 3]
            }
            bytes.append(contentsOf: row)
        }
        return bytes
    }
}
