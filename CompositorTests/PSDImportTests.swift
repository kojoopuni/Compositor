import AppKit
import Testing
@testable import Compositor

/// A Photoshop document written by hand, so the importer is tested against the format and not against one app's files.
@MainActor
struct PSDImportTests {
    private struct PSDLayer {
        var name: String, rect: (top: Int, left: Int, bottom: Int, right: Int), color: (UInt8, UInt8, UInt8, UInt8)?
        var blend = "norm", opacity: UInt8 = 255, hidden = false, section = 0, rle = false, adjustmentKey: String?
        var mask: (rect: (Int, Int, Int, Int), value: UInt8, outside: UInt8)?
    }
    private func big<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    private func plane(_ value: UInt8, width: Int, height: Int, rle: Bool) -> Data {
        guard width > 0, height > 0 else { return Data() }
        if !rle { return big(UInt16(0)) + Data(repeating: value, count: width * height) }
        // Each row as PackBits runs of up to 128 repeats.
        var row = Data(), left = width
        while left > 0 { let run = min(128, left); row.append(UInt8(bitPattern: Int8(1 - run))); row.append(value); left -= run }
        return big(UInt16(1)) + (0..<height).reduce(Data()) { $0 + big(UInt16(row.count)) + ($1 >= 0 ? Data() : Data()) } + (0..<height).reduce(Data()) { data, _ in data + row }
    }
    private func psd(width: Int, height: Int, depth: UInt16 = 8, layers: [PSDLayer]) -> Data {
        var records = Data(), channels = Data()
        for layer in layers {
            let w = layer.rect.right - layer.rect.left, h = layer.rect.bottom - layer.rect.top
            var planes: [(Int16, Data)] = []
            if let color = layer.color {
                planes = [(-1, plane(color.3, width: w, height: h, rle: layer.rle)), (0, plane(color.0, width: w, height: h, rle: layer.rle)),
                          (1, plane(color.1, width: w, height: h, rle: layer.rle)), (2, plane(color.2, width: w, height: h, rle: layer.rle))]
            } else { planes = [(-1, big(UInt16(0))), (0, big(UInt16(0))), (1, big(UInt16(0))), (2, big(UInt16(0)))] }
            var maskData = Data()
            if let mask = layer.mask {
                let (t, l, b, r) = mask.rect
                maskData = big(Int32(t)) + big(Int32(l)) + big(Int32(b)) + big(Int32(r)) + Data([mask.outside, 0, 0, 0])
                planes.append((-2, plane(mask.value, width: r - l, height: b - t, rle: false)))
            }
            var extra = big(UInt32(maskData.count)) + maskData + big(UInt32(0))
            let ascii = Data("pascal".utf8)
            extra += Data([UInt8(ascii.count)]) + ascii + Data(repeating: 0, count: (4 - (ascii.count + 1) % 4) % 4)
            let unicode = layer.name.data(using: .utf16BigEndian)!
            extra += Data("8BIMluni".utf8) + big(UInt32(4 + unicode.count)) + big(UInt32(layer.name.utf16.count)) + unicode
            if layer.section != 0 { extra += Data("8BIMlsct".utf8) + big(UInt32(4)) + big(UInt32(layer.section)) }
            if let key = layer.adjustmentKey { extra += Data("8BIM".utf8) + Data(key.utf8) + big(UInt32(4)) + big(UInt32(0)) }
            records += big(Int32(layer.rect.top)) + big(Int32(layer.rect.left)) + big(Int32(layer.rect.bottom)) + big(Int32(layer.rect.right))
            records += big(UInt16(planes.count))
            for (id, data) in planes { records += big(id) + big(UInt32(data.count)); channels += data }
            records += Data("8BIM".utf8) + Data(layer.blend.utf8) + Data([layer.opacity, 0, layer.hidden ? 2 : 0, 0]) + big(UInt32(extra.count)) + extra
        }
        var layerInfo = big(Int16(layers.count)) + records + channels
        if layerInfo.count % 2 == 1 { layerInfo.append(0) }
        let section = big(UInt32(layerInfo.count)) + layerInfo + big(UInt32(0))
        let header = Data("8BPS".utf8) + big(UInt16(1)) + Data(repeating: 0, count: 6) + big(UInt16(4)) + big(UInt32(height)) + big(UInt32(width)) + big(depth) + big(UInt16(3))
        // Merged image: raw planes, white and opaque.
        let merged = big(UInt16(0)) + Data(repeating: 255, count: width * height * 4)
        return header + big(UInt32(0)) + big(UInt32(0)) + big(UInt32(section.count)) + section + merged
    }
    private func pixel(_ snapshot: ProjectSnapshot, _ x: Int, _ y: Int) async throws -> [Int] {
        let image = try await ImageExporter.shared.render(snapshot).image
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { Int(bytes[y * context.bytesPerRow + x * 4 + $0]) }
    }

    @Test func layersFoldersMasksAndBlendModesComeAcross() async throws {
        let file = psd(width: 40, height: 30, layers: [
            PSDLayer(name: "Background", rect: (0, 0, 30, 40), color: (0, 0, 255, 255), rle: true),
            PSDLayer(name: "</Layer group>", rect: (0, 0, 0, 0), color: nil, section: 3),
            PSDLayer(name: "Röd fyrkant", rect: (5, 10, 25, 30), color: (255, 0, 0, 255), blend: "mul ", opacity: 128,
                     mask: (rect: (5, 10, 25, 20), value: 255, outside: 0)),
            PSDLayer(name: "Hidden", rect: (0, 0, 10, 10), color: (0, 255, 0, 255), hidden: true),
            PSDLayer(name: "Group 1", rect: (0, 0, 0, 0), color: nil, section: 1),
        ])
        let result = try PSDImporter.read(file, name: "test")
        let layers = result.snapshot.manifest.layers
        #expect(layers.map(\.name) == ["Background", "Röd fyrkant", "Hidden", "Group 1"] && result.skipped.isEmpty)
        let group = try #require(layers.last)
        #expect(group.isGroup == true && layers[1].parentID == group.id && layers[2].parentID == group.id && layers[0].parentID == nil)
        let red = layers[1]
        #expect(red.transform.origin == CGPoint(x: 10, y: 5) && red.transform.size == CGSize(width: 20, height: 20))
        #expect(red.blendMode == .multiply && abs((red.opacity ?? 0) - 128.0 / 255) < 0.001 && red.maskFile != nil && layers[2].isVisible == false)
        try LayerHierarchy.validate(layers)
        // Through the mask (its left half only) red multiplies blue to black at half strength; elsewhere blue stays.
        let inside = try await pixel(result.snapshot, 12, 10), masked = try await pixel(result.snapshot, 25, 10), outside = try await pixel(result.snapshot, 35, 28)
        #expect(inside[0] == 0 && inside[1] == 0 && abs(inside[2] - 127) <= 2 && inside[3] == 255, "\(inside)")
        #expect(masked == [0, 0, 255, 255] && outside == [0, 0, 255, 255])
        // It saves and reopens as an ordinary project.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("psd-\(UUID().uuidString).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(result.snapshot, to: url)
        #expect(try await ProjectStore.shared.load(from: url).manifest.layers.count == 4)
    }

    @Test func whatPhotoshopDrawsItselfIsSkippedNamedAndCoveredByAReference() throws {
        let file = psd(width: 20, height: 20, layers: [
            PSDLayer(name: "Paint", rect: (0, 0, 20, 20), color: (10, 20, 30, 255)),
            PSDLayer(name: "Curves 1", rect: (0, 0, 0, 0), color: nil, adjustmentKey: "curv"),
        ])
        let result = try PSDImporter.read(file, name: "test")
        #expect(result.skipped == ["Curves 1"])
        #expect(result.snapshot.manifest.layers.map(\.name) == ["Paint", PSDImporter.referenceName])
    }

    @Test func otherFilesAreRefusedWithAReason() {
        #expect(throws: PSDImporter.Failure.self) { try PSDImporter.read(Data("not a psd at all".utf8), name: "x") }
        let deep = psd(width: 8, height: 8, depth: 16, layers: [])
        #expect { try PSDImporter.read(deep, name: "x") } throws: { ($0 as? LocalizedError)?.errorDescription?.contains("16 bits") == true }
        #expect(throws: (any Error).self) { try PSDImporter.read(psd(width: 8, height: 8, layers: [PSDLayer(name: "Cut", rect: (0, 0, 8, 8), color: (1, 2, 3, 255))]).prefix(60), name: "x") }
    }
}
