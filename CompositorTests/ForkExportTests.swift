import AppKit
import ImageIO
import Testing
@testable import Compositor

/// TIFF, TGA, edge bleed, Trim and the tile sheet.
@MainActor
struct ForkExportTests {

    private func snapshot(rotation: CGFloat = 0, flip: Bool = false) throws -> ProjectSnapshot {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 2))
        let image = try #require(context.makeImage())
        let id = UUID()
        let transform = LayerTransform(origin: CGPoint(x: 1, y: 1), size: CGSize(width: 4, height: 4),
                                       rotation: rotation, flipX: flip, sampling: .nearest)
        let record = ProjectLayerRecord(id: id, name: "Red", isVisible: true, transform: transform,
                                        imageFile: "\(id).png")
        return ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 6, height: 6,
            activeLayerID: id, layers: [record]), images: [id: ImportedImage(image: image, thumbnail: image, name: "Red")])
    }

    @Test func tiffAndTGACarryTheSamePixelsAsThePNG() async throws {
        let snapshot = try snapshot()
        let tiff = try await ImageExporter.shared.data(snapshot, as: .tiff)
        let read = try #require(CGImageSourceCreateWithData(tiff as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let png = try await ImageExporter.shared.render(snapshot).image
        #expect(read.width == png.width && read.height == png.height)
        let tga = try await ImageExporter.shared.data(snapshot, as: .tga)
        #expect(tga.count == 18 + png.width * png.height * 4 && tga[2] == 2 && Int(tga[12]) == png.width
                && Int(tga[14]) == png.height && tga[16] == 32 && tga[17] == 0x28)
        // ImageIO reads TGA, so the two can be compared pixel for pixel, straight alpha included.
        let back = try #require(CGImageSourceCreateWithData(tga as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        for y in 0..<png.height { for x in 0..<png.width {
            let a = try #require(NSBitmapImageRep(cgImage: back).colorAt(x: x, y: y)), b = try #require(NSBitmapImageRep(cgImage: png).colorAt(x: x, y: y))
            #expect(abs(a.alphaComponent - b.alphaComponent) < 0.02 && abs(a.redComponent - b.redComponent) < 0.03, "pixel \(x),\(y)")
        } }
    }

    @Test func trimCropsToWhatCanBeSeenAndKeepsEveryPixel() async throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 80)
        let context = try BrushRaster.context(width: 20, height: 10, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"), centeredAt: CGPoint(x: 60, y: 30))
        let count = session.history.undoCount
        await session.trimTransparentPixels()
        #expect(session.document?.size == CGSize(width: 20, height: 10) && session.history.undoName == "Trim")
        #expect(session.activeLayer?.transform.origin == .zero && session.activeLayer?.asset?.image === image)
        #expect(session.history.undoCount == count + 1)
        session.undo()
        #expect(session.document?.size == CGSize(width: 100, height: 80))
        let sheet = try TileSheet.image(of: image, count: 3, limit: 600)
        #expect(sheet.width == 60 && sheet.height == 30)
    }

    @Test func edgeBleedColorsTheTransparencyAroundAShapeWithoutChangingAnyAlpha() throws {
        // A red square in the middle of nothing.
        let context = try BrushRaster.context(width: 16, height: 16, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 6, y: 6, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let plain = try EdgeBleed.straightPixels(of: image, distance: 0).bytes
        let bled = try EdgeBleed.straightPixels(of: image, distance: 3).bytes
        func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * 16 + x) * 4..<(y * 16 + x) * 4 + 4]) }
        #expect(pixel(plain, 4, 8) == [0, 0, 0, 0] && pixel(bled, 4, 8) == [255, 0, 0, 0])   // two pixels out: red, still clear
        #expect(pixel(bled, 3, 8) == [255, 0, 0, 0] && pixel(bled, 2, 8) == [0, 0, 0, 0])     // three reaches, four does not
        #expect(pixel(bled, 7, 7) == [255, 0, 0, 255])
        #expect(stride(from: 3, to: bled.count, by: 4).allSatisfy { bled[$0] == plain[$0] })
        // The PNG keeps that color: read back without premultiplying, the clear pixel beside the square is red.
        let png = try EdgeBleed.pngData(image, distance: 3, resolution: 72)
        let read = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let raw = try #require(read.dataProvider?.data as Data?)
        let at = 8 * read.bytesPerRow + 4 * 4
        #expect(read.alphaInfo == .last && raw[at] == 255 && raw[at + 3] == 0, "\(read.alphaInfo.rawValue) \(Array(raw[at..<at + 4]))")
    }
}
