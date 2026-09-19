import CoreGraphics
import Foundation
import ImageIO

/// Opens a Photoshop document as a Compositor project: its layers with their names, positions, visibility, opacity,
/// blend modes, folders and layer masks. It is a way in, not a round trip. Pixels come across exactly; things
/// Photoshop draws on the fly do not — text and smart objects arrive as the pixels Photoshop last rendered for them,
/// layer styles are dropped, and adjustment layers (which have no pixels) are skipped and counted. Covers 8-bit RGB
/// and grayscale .psd files with raw or RLE channels, which is what Photoshop writes by default.
nonisolated enum PSDImporter {
    enum Failure: LocalizedError {
        case notPSD, unsupported(String), damaged
        var errorDescription: String? {
            switch self {
            case .notPSD: "This is not a Photoshop document."
            case .unsupported(let what): "This Photoshop document uses \(what), which can't be opened as layers yet. Flatten or convert it in Photoshop, or import it as a single image."
            case .damaged: "This Photoshop document is damaged or cut short."
            }
        }
    }
    /// `skipped` names the layers with no pixels to bring (adjustments and fills); `vectorMasked` those whose vector
    /// mask was left behind. When either is non-empty the project also gets Photoshop's own flattened picture as a
    /// top layer, so it looks as it did; hide that layer to work with the real ones beneath.
    struct Result { let snapshot: ProjectSnapshot; let skipped: [String]; let vectorMasked: [String] }
    static let referenceName = "Photoshop’s rendering (reference)"

    static func load(_ url: URL) throws -> Result { try read(try Data(contentsOf: url, options: .mappedIfSafe), name: url.deletingPathExtension().lastPathComponent) }

    // MARK: Reading big-endian fields

    private struct Reader {
        let data: Data
        var at: Int
        init(_ data: Data, at: Int = 0) { self.data = data; self.at = data.startIndex + at }
        var remaining: Int { data.endIndex - at }
        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, remaining >= count else { throw Failure.damaged }
            defer { at += count }
            return data.subdata(in: at..<at + count)
        }
        mutating func skip(_ count: Int) throws { guard count >= 0, remaining >= count else { throw Failure.damaged }; at += count }
        mutating func u8() throws -> Int { Int(try bytes(1)[0]) }
        mutating func u16() throws -> Int { let b = try bytes(2); return Int(b[0]) << 8 | Int(b[1]) }
        mutating func i16() throws -> Int { Int(Int16(truncatingIfNeeded: try u16())) }
        mutating func u32() throws -> Int { let b = try bytes(4); return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3]) }
        mutating func i32() throws -> Int { Int(Int32(truncatingIfNeeded: try u32())) }
        mutating func tag() throws -> String { String(decoding: try bytes(4), as: UTF8.self) }
    }

    private struct Channel { let id: Int; let length: Int }
    private struct Record {
        var rect = CGRect.zero, channels: [Channel] = [], blend = "norm", opacity = 255, hidden = false
        var name = "Layer", section = 0, maskRect: CGRect?, maskDefault = 0, maskDisabled = false, hasPixelsOnlyInPhotoshop = false
        var hasVectorMask = false
    }

    private static let blends: [String: LayerBlendMode] = [
        "norm": .normal, "mul ": .multiply, "scrn": .screen, "over": .overlay, "dark": .darken, "lite": .lighten, "diff": .difference,
        "div ": .colorDodge, "idiv": .colorBurn, "hue ": .hue, "sat ": .saturation, "colr": .color, "lum ": .luminosity,
        "sLit": .softLight, "hLit": .hardLight, "smud": .exclusion, "lddg": .linearDodge, "lbrn": .linearBurn, "vLit": .vividLight,
        "lLit": .linearLight, "pLit": .pinLight, "fdiv": .divide, "fsub": .subtract,
    ]
    /// Additional-info keys of layers that have no pixels of their own: adjustments and fills.
    private static let pixelless: Set<String> = ["levl", "curv", "hue2", "hue ", "blnc", "brit", "expA", "vibA", "blwh", "phfl", "mixr", "clrL",
                                                 "nvrt", "post", "thrs", "grdm", "selc", "SoCo", "GdFl", "PtFl"]

    static func read(_ data: Data, name: String) throws -> Result {
        var reader = Reader(data)
        guard try reader.tag() == "8BPS" else { throw Failure.notPSD }
        guard try reader.u16() == 1 else { throw Failure.unsupported("the large document format (.psb)") }
        try reader.skip(6)
        _ = try reader.u16()
        let height = try reader.u32(), width = try reader.u32(), depth = try reader.u16(), mode = try reader.u16()
        guard depth == 8 else { throw Failure.unsupported("\(depth) bits per channel") }
        guard mode == 3 || mode == 1 else { throw Failure.unsupported(mode == 4 ? "CMYK color" : mode == 9 ? "Lab color" : "a color mode other than RGB") }
        guard (1...30_000).contains(width), (1...30_000).contains(height), width * height <= 100_000_000 else { throw ProjectError.tooLarge }
        try reader.skip(try reader.u32())          // color mode data
        try reader.skip(try reader.u32())          // image resources
        let layerSectionLength = try reader.u32()
        guard layerSectionLength > 0 else { return try flattened(data, name: name, width: width, height: height, skipped: []) }
        let layerInfoLength = try reader.u32()
        guard layerInfoLength > 0 else { return try flattened(data, name: name, width: width, height: height, skipped: []) }
        let count = abs(try reader.i16())
        guard count <= 8000 else { throw Failure.damaged }

        var records: [Record] = []
        for _ in 0..<count {
            var record = Record()
            let top = try reader.i32(), left = try reader.i32(), bottom = try reader.i32(), right = try reader.i32()
            record.rect = CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
            let channelCount = try reader.u16()
            guard channelCount <= 56 else { throw Failure.damaged }
            for _ in 0..<channelCount { record.channels.append(Channel(id: try reader.i16(), length: try reader.u32())) }
            guard try reader.tag() == "8BIM" else { throw Failure.damaged }
            record.blend = try reader.tag()
            record.opacity = try reader.u8()
            _ = try reader.u8()                     // clipping
            record.hidden = try reader.u8() & 2 != 0
            _ = try reader.u8()
            var extra = Reader(try reader.bytes(try reader.u32()))
            let maskLength = try extra.u32()
            if maskLength >= 18 {
                var mask = Reader(try extra.bytes(maskLength))
                let t = try mask.i32(), l = try mask.i32(), b = try mask.i32(), r = try mask.i32()
                record.maskRect = CGRect(x: l, y: t, width: max(0, r - l), height: max(0, b - t))
                record.maskDefault = try mask.u8()
                record.maskDisabled = try mask.u8() & 2 != 0
            } else { try extra.skip(maskLength) }
            try extra.skip(try extra.u32())         // blending ranges
            let nameLength = try extra.u8()
            record.name = String(data: try extra.bytes(nameLength), encoding: .macOSRoman) ?? "Layer"
            try extra.skip((4 - (nameLength + 1) % 4) % 4)
            while extra.remaining >= 12 {
                let signature = try extra.tag()
                guard signature == "8BIM" || signature == "8B64" else { break }
                let key = try extra.tag()
                let length = try extra.u32()
                var block = Reader(try extra.bytes(min(length, extra.remaining)))
                if length % 2 == 1, extra.remaining > 0 { try extra.skip(1) }
                switch key {
                case "luni":
                    let characters = try block.u32()
                    if let text = String(data: try block.bytes(min(characters * 2, block.remaining)), encoding: .utf16BigEndian), !text.isEmpty {
                        record.name = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                    }
                case "lsct", "lsdk": record.section = try block.u32()
                case "vmsk", "vsms": record.hasVectorMask = true
                default: if pixelless.contains(key) { record.hasPixelsOnlyInPhotoshop = true }
                }
            }
            records.append(record)
        }

        // Channel data follows in the same order, and folders are rebuilt as the records go by: Photoshop lists a
        // folder's closing marker first, then what is inside it, then the folder itself.
        var layers: [ProjectLayerRecord] = [], images: [UUID: ImportedImage] = [:], masks: [UUID: ImportedImage] = [:]
        var open: [UUID] = [], skipped: [String] = [], vectorMasked: [String] = [], pixels = 0
        for record in records {
            var planes: [Int: [UInt8]] = [:]
            for channel in record.channels {
                var channelReader = Reader(try reader.bytes(channel.length))
                let box = channel.id == -2 ? (record.maskRect ?? .zero) : record.rect
                planes[channel.id] = try plane(&channelReader, width: Int(box.width), height: Int(box.height))
            }
            if record.section == 3 { open.append(UUID()); continue }
            let name = record.name.isEmpty ? "Layer" : String(record.name.prefix(200))
            if record.section == 1 || record.section == 2 {
                guard let id = open.popLast() else { continue }
                layers.append(ProjectLayerRecord(id: id, name: name, isVisible: !record.hidden,
                    transform: LayerTransform(origin: .zero, size: CGSize(width: width, height: height)), imageFile: nil, parentID: open.last, isGroup: true))
                continue
            }
            if record.hasPixelsOnlyInPhotoshop { skipped.append(name); continue }
            if record.hasVectorMask { vectorMasked.append(name) }
            let id = UUID()
            let w = Int(record.rect.width), h = Int(record.rect.height)
            var entry = ProjectLayerRecord(id: id, name: name, isVisible: !record.hidden,
                transform: LayerTransform(origin: w > 0 && h > 0 ? record.rect.origin : .zero,
                                          size: w > 0 && h > 0 ? record.rect.size : CGSize(width: width, height: height)),
                imageFile: w > 0 && h > 0 ? "\(id.uuidString).png" : nil, parentID: open.last)
            entry.opacity = Double(record.opacity) / 255
            entry.blendMode = blends[record.blend] ?? .normal
            if w > 0, h > 0 {
                pixels += w * h
                guard pixels <= 100_000_000 else { throw ProjectError.tooLarge }
                let image = try rgba(planes, width: w, height: h, gray: mode == 1)
                images[id] = ImportedImage(image: image, thumbnail: try PixelInvert.thumbnail(of: image), name: name)
                if let maskRect = record.maskRect, let values = planes[-2], maskRect.width > 0, maskRect.height > 0 {
                    // The mask covers the layer's own pixels here; outside its rectangle Photoshop uses one flat value.
                    var cover = [UInt8](repeating: UInt8(record.maskDefault), count: w * h)
                    let mw = Int(maskRect.width), mh = Int(maskRect.height)
                    for y in 0..<mh { for x in 0..<mw {
                        let lx = x + Int(maskRect.minX - record.rect.minX), ly = y + Int(maskRect.minY - record.rect.minY)
                        if (0..<w).contains(lx), (0..<h).contains(ly) { cover[ly * w + lx] = values[y * mw + x] }
                    } }
                    if let provider = CGDataProvider(data: Data(cover) as CFData),
                       let mask = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                                          shouldInterpolate: false, intent: .defaultIntent) {
                        masks[id] = try LayerMask.asset(from: mask)
                        entry.maskFile = "\(id.uuidString).mask.png"
                        entry.maskEnabled = !record.maskDisabled
                    }
                }
            }
            layers.append(entry)
        }
        guard !layers.isEmpty else { return try flattened(data, name: name, width: width, height: height, skipped: skipped) }
        if !skipped.isEmpty || !vectorMasked.isEmpty, pixels + width * height <= 100_000_000,
           let reference = try? flattened(data, name: referenceName, width: width, height: height, skipped: []).snapshot,
           let record = reference.manifest.layers.first, let image = reference.images[record.id] {
            layers.append(record)
            images[record.id] = image
        }
        let manifest = ProjectManifest(documentID: UUID(), width: width, height: height, activeLayerID: layers.last?.id, layers: layers)
        return Result(snapshot: ProjectSnapshot(manifest: manifest, images: images, masks: masks), skipped: skipped, vectorMasked: vectorMasked)
    }

    /// One channel's bytes, raw or PackBits run-length encoded.
    private static func plane(_ reader: inout Reader, width: Int, height: Int) throws -> [UInt8] {
        guard width > 0, height > 0 else { return [] }
        let compression = try reader.u16()
        var out = [UInt8](repeating: 0, count: width * height)
        switch compression {
        case 0:
            let raw = try reader.bytes(min(width * height, reader.remaining))
            raw.withUnsafeBytes { source in out.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<min(source.count, width * height)])) } }
        case 1:
            var lengths: [Int] = []
            for _ in 0..<height { lengths.append(try reader.u16()) }
            for row in 0..<height {
                let packed = try reader.bytes(lengths[row])
                var source = packed.startIndex, target = row * width
                let end = target + width
                while source < packed.endIndex, target < end {
                    let header = Int(Int8(bitPattern: packed[source])); source += 1
                    if header >= 0 {
                        let run = min(header + 1, end - target, packed.endIndex - source)
                        for offset in 0..<run { out[target + offset] = packed[source + offset] }
                        source += header + 1; target += run
                    } else if header != -128 {
                        guard source < packed.endIndex else { break }
                        let run = min(1 - header, end - target), value = packed[source]; source += 1
                        for offset in 0..<run { out[target + offset] = value }
                        target += run
                    }
                }
            }
        default: throw Failure.unsupported("ZIP-compressed layers")
        }
        return out
    }

    /// Photoshop's separate planes (straight color, with channel −1 as transparency) as the editor's premultiplied RGBA.
    private static func rgba(_ planes: [Int: [UInt8]], width: Int, height: Int, gray: Bool) throws -> CGImage {
        let count = width * height
        let red = planes[0] ?? [], green = gray ? red : (planes[1] ?? []), blue = gray ? red : (planes[2] ?? []), alpha = planes[-1]
        guard red.count == count, green.count == count, blue.count == count, alpha.map({ $0.count == count }) ?? true else { throw Failure.damaged }
        var bytes = [UInt8](repeating: 0, count: count * 4)
        for index in 0..<count {
            let a = Int(alpha?[index] ?? 255)
            bytes[index * 4] = UInt8((Int(red[index]) * a + 127) / 255)
            bytes[index * 4 + 1] = UInt8((Int(green[index]) * a + 127) / 255)
            bytes[index * 4 + 2] = UInt8((Int(blue[index]) * a + 127) / 255)
            bytes[index * 4 + 3] = UInt8(a)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ExportError.render }
        return image
    }

    /// A document with no layer records (a flattened file): its picture as one layer, read by the system.
    private static func flattened(_ data: Data, name: String, width: Int, height: Int, skipped: [String]) throws -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.damaged }
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.interpolationQuality = .none
        context.saveGState(); context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height)); context.restoreGState()
        guard let image = context.makeImage() else { throw ExportError.render }
        let id = UUID()
        let record = ProjectLayerRecord(id: id, name: name, isVisible: true, transform: LayerTransform(origin: .zero, size: CGSize(width: width, height: height)), imageFile: "\(id.uuidString).png")
        let manifest = ProjectManifest(documentID: UUID(), width: width, height: height, activeLayerID: id, layers: [record])
        return Result(snapshot: ProjectSnapshot(manifest: manifest, images: [id: ImportedImage(image: image, thumbnail: try PixelInvert.thumbnail(of: image), name: name)]), skipped: skipped, vectorMasked: [])
    }
}
