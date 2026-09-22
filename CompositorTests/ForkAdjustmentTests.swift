import AppKit
import Testing
@testable import Compositor

/// Threshold, Posterize, Vibrance and Photo Filter.
@MainActor
struct ForkAdjustmentTests {

    @Test func theForksColorAdjustmentsDoWhatTheirNamesSay() throws {
        func pixel(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) throws -> CGImage {
            let context = try BrushRaster.context(width: 1, height: 1, mask: false)
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha))
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            return try #require(context.makeImage())
        }
        func bytes(_ image: CGImage) throws -> [Int] {
            let context = try BrushRaster.context(width: 1, height: 1, mask: false)
            BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1), mask: false, context: context)
            return (0..<4).map { Int(try! #require(context.data).assumingMemoryBound(to: UInt8.self)[$0]) }
        }
        var settings = ColorAdjustments()
        let orange = try pixel(1, 0.5, 0)
        #expect(try bytes(try settings.apply(.threshold, to: try pixel(0.6, 0.6, 0.6))) == [255, 255, 255, 255])
        #expect(try bytes(try settings.apply(.threshold, to: try pixel(0.4, 0.4, 0.4))) == [0, 0, 0, 255])
        settings.posterizeLevels = 2
        #expect(try bytes(try settings.apply(.posterize, to: try pixel(0.7, 0.2, 0.55))) == [255, 0, 255, 255])
        settings.saturation = -100
        let drained = try bytes(try settings.apply(.vibrance, to: orange))
        #expect(drained[0] == drained[1] && drained[1] == drained[2])
        settings = ColorAdjustments(); settings.filterDensity = 100; settings.filterPreservesLuminosity = false
        let tinted = try bytes(try settings.apply(.photoFilter, to: try pixel(1, 1, 1)))
        #expect(abs(tinted[0] - 236) <= 1 && abs(tinted[1] - 138) <= 1 && tinted[2] == 0)   // white takes the filter's color
        // A soft edge changes like the color it is, and keeps its alpha.
        let soft = try bytes(try ColorAdjustments().apply(.threshold, to: try pixel(1, 1, 1, 0.5)))
        #expect(soft[3] == 128 && soft[0] == 128)
        #expect(ColorAdjustments().isIdentity(.vibrance) && !ColorAdjustments().isIdentity(.threshold))
        var wild = ColorAdjustments(); wild.posterizeLevels = .nan; wild.filterDensity = 900
        #expect(wild.normalized.posterizeLevels == 4 && wild.normalized.filterDensity == 100 && !wild.isValid)
    }
}
