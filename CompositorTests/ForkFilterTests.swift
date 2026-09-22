import AppKit
import Testing
@testable import Compositor

/// The fork's filters: Offset, the texture set, and blurs that keep their edges.
@MainActor
struct ForkFilterTests {
    /// A layer's pixels as premultiplied RGBA bytes, top row first.
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let copy = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: copy)
        return Array(UnsafeBufferPointer(start: try #require(copy.data).assumingMemoryBound(to: UInt8.self),
                                         count: image.width * image.height * 4))
    }
    private func painted(_ width: Int, _ height: Int, _ color: (Int, Int) -> (CGFloat, CGFloat, CGFloat, CGFloat)) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        for y in 0..<height { for x in 0..<width {
            let (red, green, blue, alpha) = color(x, y)
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        return try #require(context.makeImage())
    }
    private func filtered(_ kind: FilterKind, _ image: CGImage, _ settings: FilterSettings, seed: UInt32 = 0) throws -> CGImage {
        try PixelFilter.run(FilterJob(kind: kind, image: image, settings: settings, scale: 1, selection: nil, mapping: .identity, seed: seed))
    }

    @Test func offsetWrapsPixelsAroundTheEdgesAndSlidingBackRestoresThemExactly() throws {
        // Every pixel its own color, so any misplaced one shows: red counts columns, green counts rows.
        let context = try BrushRaster.context(width: 8, height: 4, mask: false)
        for y in 0..<4 { for x in 0..<8 {
            context.setFillColor(CGColor(srgbRed: CGFloat(x * 30) / 255, green: CGFloat(y * 60) / 255, blue: 0, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        let image = try #require(context.makeImage())
        func bytes(_ image: CGImage) throws -> [UInt8] {
            let copy = try BrushRaster.context(width: image.width, height: image.height, mask: false)
            BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: copy)
            return Array(UnsafeBufferPointer(start: try #require(copy.data).assumingMemoryBound(to: UInt8.self),
                                             count: image.width * image.height * 4))
        }
        func run(_ horizontal: Double, _ vertical: Double, on image: CGImage) throws -> CGImage {
            try PixelFilter.run(FilterJob(kind: .offset, image: image,
                settings: FilterSettings(offsetHorizontal: horizontal, offsetVertical: vertical),
                scale: 1, selection: nil, mapping: .identity))
        }
        let original = try bytes(image)
        // A quarter right (2 of 8 columns) and half down (2 of 4 rows): the pixel now at (x, y) came from (x − 2, y − 2).
        let slid = try bytes(try run(25, 50, on: image))
        for y in 0..<4 { for x in 0..<8 {
            let from = ((y + 2) % 4 * 8 + (x + 6) % 8) * 4, to = (y * 8 + x) * 4
            #expect(Array(slid[to..<to + 4]) == Array(original[from..<from + 4]), "pixel (\(x), \(y))")
        } }
        #expect(try bytes(try run(-25, -50, on: try run(25, 50, on: image))) == original)
        // A whole side's length is no slide at all, and the same image comes back untouched.
        #expect(try run(100, -100, on: image) === image)
        #expect(FilterSettings(offsetHorizontal: 500, offsetVertical: .nan).normalized.offsetHorizontal == 100)
        #expect(FilterSettings(offsetHorizontal: 500, offsetVertical: .nan).normalized.offsetVertical == 50)
    }

    @Test func offsetWithNothingToSlideClosesWithoutAnUndoStep() async throws {
        let session = EditorSession()
        session.createDocument(width: 8, height: 8)
        let context = try BrushRaster.context(width: 8, height: 8, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 8))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Half"))
        let count = session.history.undoCount
        session.beginFilter(.offset)
        session.updateFilter(FilterSettings(offsetHorizontal: 0, offsetVertical: 100), preview: true)
        await session.commitFilter()
        #expect(session.filterEdit == nil && session.history.undoCount == count)
        #expect(session.activeLayer?.asset?.image === image)
        session.beginFilter(.offset)
        session.updateFilter(FilterSettings(offsetHorizontal: 50, offsetVertical: 0), preview: true)
        await session.commitFilter()
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Offset")
    }

    @Test func blurThatKeepsItsEdgesStaysSolidToTheBorderAndDoesNotGrowTheLayer() async throws {
        let image = try painted(40, 40) { x, _ in x < 20 ? (0, 0, 0, 1) : (1, 1, 1, 1) }
        let faded = try rgba(try filtered(.gaussianBlur, image, FilterSettings(radius: 4)))
        let solid = try rgba(try filtered(.gaussianBlur, image, FilterSettings(radius: 4, keepEdges: true)))
        #expect(faded[(20 * 40 + 0) * 4 + 3] < 200)             // an ordinary blur fades the border
        #expect(solid[(20 * 40 + 0) * 4 + 3] == 255 && solid[(0 * 40 + 39) * 4 + 3] == 255)
        let middle = Int(solid[(20 * 40 + 20) * 4])
        #expect(middle > 60 && middle < 200)                     // and the inside is still blurred
        #expect(FilterEdit.blurMargin(.gaussianBlur, FilterSettings(radius: 4, keepEdges: true)) == 0)

        let session = EditorSession()
        session.createDocument(width: 40, height: 40)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Split"))
        session.filterSettings.keepEdges = true
        session.beginFilter(.gaussianBlur)
        session.updateFilter(FilterSettings(radius: 4, keepEdges: true), preview: true)
        await session.commitFilter()
        #expect(session.activeLayer?.transform.size == CGSize(width: 40, height: 40))
    }

    @Test func highPassKeepsDetailOnGrayAndUnsharpMaskStrengthensEdges() throws {
        let flat = try painted(24, 24) { _, _ in (0.8, 0.3, 0.1, 1) }
        let gray = try rgba(try filtered(.highPass, flat, FilterSettings(highPassRadius: 4)))
        #expect(abs(Int(gray[0]) - 128) <= 2 && abs(Int(gray[1]) - 128) <= 2 && gray[3] == 255)   // no detail: middle gray
        let step = try painted(24, 24) { x, _ in x < 12 ? (0.4, 0.4, 0.4, 1) : (0.6, 0.6, 0.6, 1) }
        let before = try rgba(step), sharp = try rgba(try filtered(.unsharpMask, step, FilterSettings(sharpenAmount: 200, sharpenRadius: 2)))
        let dark = (12 * 24 + 11) * 4, light = (12 * 24 + 12) * 4
        #expect(sharp[dark] < before[dark] && sharp[light] > before[light])                       // the edge is stronger
        #expect(sharp[(12 * 24 + 2) * 4] == before[(12 * 24 + 2) * 4])                            // flat areas are untouched
        let held = try rgba(try filtered(.unsharpMask, step, FilterSettings(sharpenAmount: 200, sharpenRadius: 2, sharpenThreshold: 200)))
        #expect(held == before)
    }

    @Test func evenLightingFlattensAGradientAndMakeTileableBringsOppositeEdgesTogether() throws {
        var random = SystemRandomNumberGenerator()
        let speckle = (0..<64 * 64).map { _ in CGFloat(Int.random(in: -14...14, using: &random)) / 255 }
        let lit = try painted(64, 64) { x, y in
            let value = 0.25 + CGFloat(x) / 64 * 0.5 + speckle[y * 64 + x]
            return (value, value, value, 1)
        }
        func sides(_ image: CGImage) throws -> (left: Int, right: Int) {
            let bytes = try rgba(image)
            let rows = stride(from: 4, to: 60, by: 4)
            return (rows.reduce(0) { $0 + Int(bytes[($1 * 64 + 1) * 4]) } / rows.underestimatedCount,
                    rows.reduce(0) { $0 + Int(bytes[($1 * 64 + 62) * 4]) } / rows.underestimatedCount)
        }
        let original = try sides(lit), evened = try sides(try filtered(.evenLighting, lit, FilterSettings(lightingStrength: 100)))
        #expect(original.right - original.left > 90 && abs(evened.right - evened.left) < 35)
        #expect(try filtered(.evenLighting, lit, FilterSettings(lightingStrength: 0)) === lit)
        let tiled = try filtered(.makeTileable, lit, FilterSettings())
        let joined = try sides(tiled)
        #expect(abs(joined.right - joined.left) < 30, "edges \(joined)")
        #expect(try rgba(tiled).enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 255 })   // still opaque
    }

    @Test func normalMapIsFlatBlueOnLevelGroundAndLeansAwayFromRisingHeight() throws {
        let level = try rgba(try filtered(.normalMap, try painted(16, 16) { _, _ in (0.5, 0.5, 0.5, 1) }, FilterSettings()))
        #expect(abs(Int(level[0]) - 128) <= 1 && abs(Int(level[1]) - 128) <= 1 && level[2] == 255 && level[3] == 255)
        // Height rising to the right: the surface faces left, so red drops below the middle and green stays level.
        let ramp = try painted(16, 16) { x, _ in (CGFloat(x) / 15, CGFloat(x) / 15, CGFloat(x) / 15, 1) }
        let slope = try rgba(try filtered(.normalMap, ramp, FilterSettings(normalStrength: 4, normalWrap: false)))
        let center = (8 * 16 + 8) * 4
        #expect(slope[center] < 110 && abs(Int(slope[center + 1]) - 128) <= 1 && slope[center + 2] > 128)
        // Height rising downward: green rises when it points up, and falls when the engine wants it pointing down.
        let fall = try painted(16, 16) { _, y in (CGFloat(y) / 15, CGFloat(y) / 15, CGFloat(y) / 15, 1) }
        let up = try rgba(try filtered(.normalMap, fall, FilterSettings(normalWrap: false)))
        let down = try rgba(try filtered(.normalMap, fall, FilterSettings(normalYDown: true, normalWrap: false)))
        #expect(up[center + 1] > 140 && down[center + 1] < 116)
    }

    @Test func cloudsAreTheSameForASeedAndTileAcrossTheirEdges() throws {
        let blank = try painted(64, 64) { _, _ in (0, 0, 0, 0) }
        let first = try rgba(try filtered(.clouds, blank, FilterSettings(cloudCells: 4), seed: 9))
        #expect(first == (try rgba(try filtered(.clouds, blank, FilterSettings(cloudCells: 4), seed: 9))))
        #expect(first != (try rgba(try filtered(.clouds, blank, FilterSettings(cloudCells: 4), seed: 10))))
        #expect(first[3] == 255 && Set(stride(from: 0, to: first.count, by: 4).map { first[$0] }).count > 20)
        // The last column continues into the first as smoothly as any two neighbors do.
        let seam = (0..<64).map { abs(Int(first[($0 * 64 + 63) * 4]) - Int(first[($0 * 64) * 4])) }.max() ?? 255
        let inside = (0..<64).map { abs(Int(first[($0 * 64 + 31) * 4]) - Int(first[($0 * 64 + 32) * 4])) }.max() ?? 0
        #expect(seam <= inside + 6, "seam \(seam), inside \(inside)")
    }
}
