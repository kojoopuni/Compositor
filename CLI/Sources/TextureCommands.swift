import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Commands for game textures. Make Tileable is the app's own filter (Filter > Make Tileable); the map commands
/// below work on files and have no screen in the app yet.
extension Commands {
    /// compositor-cli make-tileable <project> <layer> [--band PERCENT] [--lighting 0-100]
    static func makeTileable(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        let layer = try workspace.activate(try arguments.required(1, "the layer's id or name"))
        var settings = FilterSettings()
        if let band = try arguments.number("band") {
            guard (2...40).contains(band) else { throw CommandError("--band is 2–40 (percent of the shorter side)") }
            settings.tileBand = band
        }
        if let lighting = try arguments.number("lighting") {
            guard (0...100).contains(lighting) else { throw CommandError("--lighting is 0–100") }
            settings.tileLighting = lighting
        }
        try await apply(.makeTileable, settings, in: workspace.session)
        try await workspace.save()
        return try json(["tileable": layer.id.uuidString, "band": settings.tileBand, "lighting": settings.tileLighting])
    }

    /// compositor-cli derive-maps <project> --out-dir DIR --name NAME [--strength S] [--y-down]
    /// From the finished picture, writes the maps a material needs beside the color: NAME_albedo, _height, _normal,
    /// _roughness and _ao, all PNG. They are estimates from brightness alone (bright is high, smooth and open), a
    /// starting point to adjust rather than measured data.
    static func deriveMaps(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let workspace = try await Workspace.open(try arguments.url(0, "the project"))
        guard let folder = arguments.url(option: "out-dir"), let name = arguments.string("name"), !name.isEmpty else {
            throw CommandError("derive-maps needs --out-dir <folder> and --name <base name>")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let snapshot = try workspace.snapshot()
        let albedo = try await ImageExporter.shared.render(snapshot).image
        let width = albedo.width, height = albedo.height
        let heights = try Gray(albedo)
        // Roughness: fine detail reads as rough, so the detail's strength lifts a middling base.
        let detail = try Gray(try TextureFilter.highPass(albedo, radius: max(2, Double(min(width, height)) / 128)))
        var roughness = heights
        for index in 0..<roughness.values.count {
            roughness.values[index] = min(1, max(0, 0.75 - 0.35 * heights.values[index] + 1.5 * abs(detail.values[index] - 0.5)))
        }
        // Ambient occlusion: places lower than their surroundings are shaded.
        let around = try Gray(try TextureFilter.highPass(albedo, radius: max(4, Double(min(width, height)) / 32)))
        var occlusion = heights
        for index in 0..<occlusion.values.count {
            occlusion.values[index] = min(1, max(0, 1 - 2.2 * max(0, 0.5 - around.values[index])))
        }
        let normal = try TextureFilter.normalMap(try heights.image(), strength: try arguments.number("strength") ?? 4,
                                                 yDown: arguments.flag("y-down"), wrap: true)
        var written: [String: String] = [:]
        func save(_ image: CGImage, _ suffix: String) throws {
            let url = folder.appendingPathComponent("\(name)_\(suffix).png")
            try write(image, to: url, type: .png, properties: [:])
            written[suffix] = url.path
        }
        try save(albedo, "albedo"); try save(try heights.image(), "height"); try save(normal, "normal")
        try save(try roughness.image(), "roughness"); try save(try occlusion.image(), "ao")
        return try json(["maps": written, "width": width, "height": height])
    }

    /// compositor-cli pack-channels --out packed.png [--layout orm|unity-mask] [--ao F] [--roughness F] [--metallic F]
    ///                              [--red F] [--green F] [--blue F] [--alpha F]
    /// Puts grayscale maps into the channels of one texture. `orm` is glTF and Godot's layout (red occlusion, green
    /// roughness, blue metallic); `unity-mask` is Unity HDRP's mask map (red metallic, green occlusion, alpha
    /// smoothness, which is roughness inverted). --red/--green/--blue/--alpha place any map directly.
    static func packChannels(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        guard let output = arguments.url(option: "out") else { throw CommandError("pack-channels needs --out <file.png>") }
        var sources: [Int: (url: URL, inverted: Bool)] = [:]
        func place(_ option: String, _ channel: Int, inverted: Bool = false) {
            if let url = arguments.url(option: option) { sources[channel] = (url, inverted) }
        }
        switch arguments.string("layout")?.lowercased() {
        case "orm": place("ao", 0); place("roughness", 1); place("metallic", 2)
        case "unity-mask": place("metallic", 0); place("ao", 1); place("roughness", 3, inverted: true)
        case nil: break
        default: throw CommandError("--layout is orm or unity-mask")
        }
        place("red", 0); place("green", 1); place("blue", 2); place("alpha", 3)
        guard !sources.isEmpty else { throw CommandError("give at least one map, e.g. --layout orm --ao ao.png --roughness rough.png") }
        var maps: [Int: Gray] = [:]
        for (channel, source) in sources {
            guard let file = CGImageSourceCreateWithURL(source.url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(file, 0, nil) else {
                throw CommandError("\(source.url.lastPathComponent) could not be read as an image")
            }
            var gray = try Gray(image)
            if source.inverted { gray.values = gray.values.map { 1 - $0 } }
            maps[channel] = gray
        }
        let first = maps.values.first!
        guard maps.values.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            throw CommandError("the maps are different sizes; resize them to match first")
        }
        // Straight bytes: channels here are data, so nothing may be multiplied by the alpha channel.
        var bytes = [UInt8](repeating: 0, count: first.width * first.height * 4)
        for index in 0..<first.width * first.height {
            for channel in 0..<4 {
                let value = maps[channel]?.values[index] ?? (channel == 3 ? 1 : 0)
                bytes[index * 4 + channel] = UInt8((min(1, max(0, value)) * 255).rounded())
            }
        }
        try writeStraight(bytes, width: first.width, height: first.height, to: output)
        let names = ["red", "green", "blue", "alpha"]
        return try json(["packed": output.path, "width": first.width, "height": first.height,
                         "channels": Dictionary(uniqueKeysWithValues: sources.map { (names[$0.key], $0.value.url.lastPathComponent + ($0.value.inverted ? " (inverted)" : "")) })])
    }

    /// compositor-cli heightmap-normal <heightmap.png> --out normal.png [--strength S] [--y-down] [--no-wrap]
    /// A normal map from a 16-bit grayscale heightmap, read at its full precision. Compositor's layers are 8-bit,
    /// where a smooth slope becomes visible steps, so terrain heightmaps are handled here as files instead.
    static func heightmapNormal(_ raw: [String]) async throws -> String {
        let arguments = Arguments(raw)
        let source = try arguments.url(0, "the heightmap image")
        guard let output = arguments.url(option: "out") else { throw CommandError("heightmap-normal needs --out <file.png>") }
        guard let file = CGImageSourceCreateWithURL(source as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(file, 0, nil) else {
            throw CommandError("\(source.lastPathComponent) could not be read as an image")
        }
        let heights = try Gray(image, deep: true)
        let strength = Float(try arguments.number("strength") ?? 4), wrap = !arguments.flag("no-wrap"), yDown = arguments.flag("y-down")
        let width = heights.width, height = heights.height
        func at(_ x: Int, _ y: Int) -> Float {
            let column = wrap ? (x % width + width) % width : min(width - 1, max(0, x))
            let row = wrap ? (y % height + height) % height : min(height - 1, max(0, y))
            return Float(heights.values[row * width + column])
        }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let across = (at(x + 1, y - 1) + 2 * at(x + 1, y) + at(x + 1, y + 1)) - (at(x - 1, y - 1) + 2 * at(x - 1, y) + at(x - 1, y + 1))
            let down = (at(x - 1, y + 1) + 2 * at(x, y + 1) + at(x + 1, y + 1)) - (at(x - 1, y - 1) + 2 * at(x, y - 1) + at(x + 1, y - 1))
            let nx = -across * strength, ny = (yDown ? -down : down) * strength
            let length = (nx * nx + ny * ny + 1).squareRoot()
            let index = (y * width + x) * 4
            bytes[index] = UInt8((nx / length * 0.5 + 0.5) * 255 + 0.5)
            bytes[index + 1] = UInt8((ny / length * 0.5 + 0.5) * 255 + 0.5)
            bytes[index + 2] = UInt8((1 / length * 0.5 + 0.5) * 255 + 0.5)
        } }
        try writeStraight(bytes, width: width, height: height, to: output)
        return try json(["normal": output.path, "width": width, "height": height, "bitsRead": image.bitsPerComponent])
    }

    /// A PNG written from straight RGBA bytes exactly as given.
    static func writeStraight(_ bytes: [UInt8], width: Int, height: Int, to url: URL) throws {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CommandError("\(url.lastPathComponent) could not be written")
        }
        try write(image, to: url, type: .png, properties: [:])
    }
}

/// One channel of brightness, 0–1, top row first.
struct Gray {
    let width: Int, height: Int
    var values: [Double]

    /// An image's brightness. `deep` reads 16 bits per sample, for heightmaps; otherwise 8, as the editor works.
    /// Device gray, so a map's values arrive as they were stored: these are data, not colors to be converted.
    init(_ image: CGImage, deep: Bool = false) throws {
        width = image.width; height = image.height
        let bits = deep ? 16 : 8, bytesPerSample = bits / 8
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: width * bytesPerSample,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                                        | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0)),
              let data = context.data else { throw CommandError("the image could not be read") }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        values = [Double](repeating: 0, count: width * height)
        if deep {
            let samples = data.assumingMemoryBound(to: UInt16.self)
            for y in 0..<height { for x in 0..<width { values[y * width + x] = Double(samples[y * (context.bytesPerRow / 2) + x]) / 65_535 } }
        } else {
            let samples = data.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height { for x in 0..<width { values[y * width + x] = Double(samples[y * context.bytesPerRow + x]) / 255 } }
        }
    }

    /// As an opaque gray image the editor's filters can read.
    func image() throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<width * height {
            let value = UInt8((min(1, max(0, values[index])) * 255).rounded())
            bytes[index * 4] = value; bytes[index * 4 + 1] = value; bytes[index * 4 + 2] = value
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CommandError("the map could not be made")
        }
        return result
    }
}
