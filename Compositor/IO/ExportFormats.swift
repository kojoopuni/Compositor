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

extension ImageExporter {
    func data(_ snapshot: ProjectSnapshot, as format: ExportFormat) throws -> Data {
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
            return try TGAEncoder.data(raster.image)
        }
    }
}

/// Truevision TGA, which ImageIO reads but cannot write: uncompressed 32-bit, top row first, with straight
/// (not premultiplied) alpha as engines expect.
nonisolated enum TGAEncoder {
    static func data(_ image: CGImage) throws -> Data {
        let width = image.width, height = image.height
        guard (1...65_535).contains(width), (1...65_535).contains(height) else { throw ExportError.tooLarge }
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let source = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
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
            let line = source + y * context.bytesPerRow
            for x in 0..<width {
                let alpha = Int(line[x * 4 + 3])
                func straight(_ value: UInt8) -> UInt8 { alpha == 0 ? 0 : UInt8(min(255, (Int(value) * 255 + alpha / 2) / alpha)) }
                row[x * 4] = straight(line[x * 4 + 2])             // blue, green, red, alpha
                row[x * 4 + 1] = straight(line[x * 4 + 1])
                row[x * 4 + 2] = straight(line[x * 4])
                row[x * 4 + 3] = UInt8(alpha)
            }
            bytes.append(contentsOf: row)
        }
        return bytes
    }
}
