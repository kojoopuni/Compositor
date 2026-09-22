import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Commands that turn a project into a flat image, using the same compositor as the app's own export.
extension Commands {
    /// A look at the canvas: the whole of it or --region x,y,width,height, scaled down to fit --max-size pixels on
    /// its longer side. Always a PNG, so transparency shows.
    static func render(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        guard let output = arguments.url(option: "out") else { throw CommandError("render needs --out <file.png>") }
        var image = try await ImageExporter.shared.render(try workspace.snapshot()).image
        if let text = arguments.string("region") {
            let parts = text.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4 else { throw CommandError("--region is x,y,width,height in document pixels") }
            let region = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]).integral
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !region.isEmpty, let cropped = image.cropping(to: region) else {
                throw CommandError("--region falls outside the canvas")
            }
            image = cropped
        }
        if let limit = try arguments.integer("max-size"), limit > 0, max(image.width, image.height) > limit {
            image = try scaled(image, longestSide: limit)
        }
        try write(image, to: output, type: .png, properties: [:])
        return try json(["rendered": output.path, "width": image.width, "height": image.height])
    }

    /// The finished image at full size, in the format its extension names: PNG, TIFF or TGA (with transparency) or
    /// JPEG (--quality 0–100, flattened onto white or --matte r,g,b). --bleed PX spreads color under the
    /// transparency around cut-outs in PNG and TGA, so a game engine shows no dark halo.
    static func export(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        guard let output = arguments.url(option: "out") else { throw CommandError("export needs --out <file.png or .jpg>") }
        let snapshot = try workspace.snapshot()
        let bleed = try arguments.integer("bleed") ?? 0
        guard (0...256).contains(bleed) else { throw CommandError("--bleed is 0–256 pixels") }
        switch output.pathExtension.lowercased() {
        case "png" where bleed > 0:
            try await ImageExporter.shared.write(try await ImageExporter.shared.pngData(snapshot, bleed: bleed), to: output)
        case "png":
            try await ImageExporter.shared.exportPNG(snapshot, to: output)
        case "tif", "tiff":
            try await ImageExporter.shared.write(try await ImageExporter.shared.data(snapshot, as: .tiff), to: output)
        case "tga":
            try await ImageExporter.shared.write(try await ImageExporter.shared.data(snapshot, as: .tga, bleed: bleed), to: output)
        case "jpg", "jpeg":
            let quality = (try arguments.number("quality") ?? 90) / 100
            guard (0...1).contains(quality) else { throw CommandError("--quality is 0–100") }
            var matte = [1.0, 1.0, 1.0]
            if let text = arguments.string("matte") {
                matte = text.split(separator: ",").compactMap { Double($0) }.map { $0 / 255 }
                guard matte.count == 3, matte.allSatisfy({ (0...1).contains($0) }) else {
                    throw CommandError("--matte is r,g,b with each 0–255")
                }
            }
            let raster = try await ImageExporter.shared.render(snapshot)
            let result = try await ImageExporter.shared.jpeg(raster, options: JPEGOptions(quality: quality,
                red: matte[0], green: matte[1], blue: matte[2]))
            try await ImageExporter.shared.write(result.data, to: output)
        default:
            throw CommandError("export writes .png, .jpg, .tiff or .tga files")
        }
        return try json(["exported": output.path, "width": snapshot.manifest.width, "height": snapshot.manifest.height])
    }

    /// The finished picture repeated --repeat times each way (3 by default), which is how a tiling texture is
    /// judged: seams and anything that repeats too obviously show at once. --max-size limits the whole sheet.
    static func tilePreview(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        guard let output = arguments.url(option: "out") else { throw CommandError("tile-preview needs --out <file.png>") }
        let count = try arguments.integer("repeat") ?? 3
        guard (2...8).contains(count) else { throw CommandError("--repeat is 2–8") }
        let tile = try await ImageExporter.shared.render(try workspace.snapshot()).image
        let limit = max(64, try arguments.integer("max-size") ?? 2048)
        let sheet = try TileSheet.image(of: tile, count: count, limit: limit)
        let side = sheet.width / count, tall = sheet.height / count
        try write(sheet, to: output, type: .png, properties: [:])
        return try json(["rendered": output.path, "width": sheet.width, "height": sheet.height, "repeat": count,
                         "tile": ["width": side, "height": tall]])
    }

    /// The finished picture's color at --at x,y in document pixels, as the eyedropper would read it: red, green,
    /// blue and alpha, each 0–255, not premultiplied.
    static func sample(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        let parts = (arguments.string("at") ?? "").split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2 else { throw CommandError("sample needs --at x,y in document pixels") }
        let image = try await ImageExporter.shared.render(try workspace.snapshot()).image
        guard (0..<image.width).contains(parts[0]), (0..<image.height).contains(parts[1]),
              let pixel = image.cropping(to: CGRect(x: parts[0], y: parts[1], width: 1, height: 1)),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { throw CommandError("--at falls outside the canvas") }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let alpha = Double(bytes[3])
        func straight(_ value: UInt8) -> Int { alpha == 0 ? 0 : min(255, Int((Double(value) * 255 / alpha).rounded())) }
        return try json(["red": straight(bytes[0]), "green": straight(bytes[1]), "blue": straight(bytes[2]), "alpha": Int(alpha)])
    }

    private static func scaled(_ image: CGImage, longestSide: Int) throws -> CGImage {
        let factor = CGFloat(longestSide) / CGFloat(max(image.width, image.height))
        let width = max(1, Int((CGFloat(image.width) * factor).rounded())), height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CommandError("the preview could not be scaled")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw CommandError("the preview could not be scaled") }
        return result
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any]) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CommandError("\(url.path) could not be written")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CommandError("\(url.path) could not be written") }
    }
}
