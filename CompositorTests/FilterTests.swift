import AppKit
import Testing
@testable import Compositor

@MainActor
struct FilterTests {
    @Test func gaussianBlurSoftensAHardEdgeWithoutFadingTheBordersAsOneUndoStep() async throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        // Left half opaque white, right half transparent.
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Half"))
        session.beginFilter(.gaussianBlur)
        #expect(session.filterEdit != nil && !session.canEditLayers)
        session.updateFilter(FilterSettings(radius: 3), preview: true)
        let count = session.history.undoCount
        await session.commitFilter()
        #expect(session.filterEdit == nil && session.history.undoCount == count + 1)
        #expect(session.filterSettings.radius == 3)
        let result = try #require(session.activeLayer?.asset?.image)
        let pixels = try #require(CGContext(data: nil, width: result.width, height: result.height, bitsPerComponent: 8,
            bytesPerRow: result.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        pixels.draw(result, in: CGRect(x: 0, y: 0, width: result.width, height: result.height))
        let bytes = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
        // The blur spreads past the layer's edges, so the layer grew; read pixels by where they sit in the document.
        let origin = try #require(session.activeLayer?.transform.origin)
        #expect(origin.x < 0 && result.width > 20)
        func alpha(_ x: Int) -> Int {
            let column = x - Int(origin.x), row = 10 - Int(origin.y)
            guard (0..<result.width).contains(column), (0..<result.height).contains(row) else { return 0 }
            return Int(bytes[(row * result.width + column) * 4 + 3])
        }
        #expect(alpha(10) == 255)                  // well inside stays solid
        #expect(alpha(0) > 20 && alpha(0) < 235)   // the layer's own border spreads outwards
        #expect(alpha(20) > 20 && alpha(20) < 235) // the hard edge is now soft
        #expect(alpha(38) == 0)
    }

    @Test func motionBlurStreaksAlongItsAngleCounterclockwiseFromHorizontal() throws {
        // One opaque white dot in the middle of a transparent image.
        let context = try BrushRaster.context(width: 41, height: 41, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 1, height: 1))
        let dot = try #require(context.makeImage())
        func streak(angle: Double) throws -> (Int, Int) -> Int {
            let settings = FilterSettings(angle: angle, distance: 16)
            let image = try PixelFilter.run(FilterJob(kind: .motionBlur, image: dot, settings: settings, scale: 1,
                                                      selection: nil, mapping: .identity))
            let read = try #require(CGContext(data: nil, width: 41, height: 41, bitsPerComponent: 8, bytesPerRow: 164,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            read.draw(image, in: CGRect(x: 0, y: 0, width: 41, height: 41))
            let bytes = Array(UnsafeBufferPointer(start: try #require(read.data).assumingMemoryBound(to: UInt8.self), count: 41 * 41 * 4))
            return { x, y in Int(bytes[(y * 41 + x) * 4 + 3]) } // rows top-down
        }
        let horizontal = try streak(angle: 0)
        #expect(horizontal(24, 20) > 0 && horizontal(16, 20) > 0 && horizontal(20, 24) == 0)
        let vertical = try streak(angle: 90)
        #expect(vertical(20, 24) > 0 && vertical(20, 16) > 0 && vertical(24, 20) == 0)
        // 45° runs up-right and down-left on screen, never up-left.
        let diagonal = try streak(angle: 45)
        #expect(diagonal(23, 17) > 0 && diagonal(17, 23) > 0 && diagonal(17, 17) == 0)
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

    @Test func addNoiseChangesColorButNeverAlphaAndMonochromaticKeepsGrays() throws {
        // Left half opaque mid gray, right half transparent.
        let context = try BrushRaster.context(width: 32, height: 8, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
        let gray = try #require(context.makeImage())
        func pixels(_ settings: FilterSettings) throws -> [UInt8] {
            let image = try PixelFilter.run(FilterJob(kind: .addNoise, image: gray, settings: settings, scale: 1,
                                                      selection: nil, mapping: .identity, seed: 7))
            let read = try #require(CGContext(data: nil, width: 32, height: 8, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            read.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 8))
            return Array(UnsafeBufferPointer(start: try #require(read.data).assumingMemoryBound(to: UInt8.self), count: 32 * 8 * 4))
        }
        let offsets = Array(stride(from: 0, to: 32 * 8 * 4, by: 4))
        let opaque = offsets.filter { $0 / 4 % 32 < 16 }, clear = offsets.filter { $0 / 4 % 32 >= 16 }
        let color = try pixels(FilterSettings(amount: 10))
        #expect(try pixels(FilterSettings(amount: 10)) == color) // the same seed gives the same grain
        #expect(opaque.allSatisfy { color[$0 + 3] == 255 && (112...144).contains(Int(color[$0])) })
        #expect(Set(opaque.map { color[$0] }).count > 5)
        #expect(opaque.contains { color[$0] != color[$0 + 1] }) // color noise differs per channel
        #expect(clear.allSatisfy { color[$0] == 0 && color[$0 + 3] == 0 })
        let mono = try pixels(FilterSettings(amount: 10, gaussian: true, monochromatic: true))
        #expect(opaque.allSatisfy { mono[$0] == mono[$0 + 1] && mono[$0 + 1] == mono[$0 + 2] && mono[$0 + 3] == 255 })
    }

    @Test func removeDistortionBendsAboutTheCenterAndOnlyPincushionCorrectionOpensTheCorners() throws {
        // An opaque image with a distinct color in each quadrant.
        let context = try BrushRaster.context(width: 40, height: 30, mask: false)
        for (index, rect) in [CGRect(x: 0, y: 0, width: 20, height: 15), CGRect(x: 20, y: 0, width: 20, height: 15),
                              CGRect(x: 0, y: 15, width: 20, height: 15), CGRect(x: 20, y: 15, width: 20, height: 15)].enumerated() {
            context.setFillColor(CGColor(srgbRed: CGFloat(index) / 3, green: 0.5, blue: 1 - CGFloat(index) / 3, alpha: 1))
            context.fill(rect)
        }
        let source = try #require(context.makeImage())
        func pixels(_ distortion: Double) throws -> [UInt8] {
            let image = try PixelFilter.run(FilterJob(kind: .lensCorrection, image: source, settings: FilterSettings(distortion: distortion),
                                                      scale: 1, selection: nil, mapping: .identity))
            let read = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 160,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            read.draw(image, in: CGRect(x: 0, y: 0, width: 40, height: 30))
            return Array(UnsafeBufferPointer(start: try #require(read.data).assumingMemoryBound(to: UInt8.self), count: 40 * 30 * 4))
        }
        func alpha(_ bytes: [UInt8], _ x: Int, _ y: Int) -> UInt8 { bytes[(y * 40 + x) * 4 + 3] }
        let original = try pixels(0)
        #expect(original.count == 40 * 30 * 4 && (0..<(40 * 30)).allSatisfy { original[$0 * 4 + 3] == 255 })
        // Straightening barrel distortion stretches the edges outward: nothing opens up.
        let barrel = try pixels(100)
        #expect(alpha(barrel, 0, 0) == 255 && alpha(barrel, 39, 29) == 255)
        // Straightening pincushion pulls the edges in: the corners turn transparent, the middle stays put.
        let pincushion = try pixels(-100)
        #expect(alpha(pincushion, 0, 0) == 0 && alpha(pincushion, 39, 29) == 0)
        #expect(Array(pincushion[((15 * 40 + 20) * 4)..<((15 * 40 + 20) * 4 + 4)]) == Array(original[((15 * 40 + 20) * 4)..<((15 * 40 + 20) * 4 + 4)]))
    }
}
