import AppKit
import Testing
@testable import Compositor

@MainActor
struct ColorRangeTests {

    @Test func colorRangeSelectsEveryPatchOfTheForegroundColorWhereTheLayerSits() async throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 60, emptyLayer: true)
        // Two red squares on blue, far apart: a wand would find one, Color Range finds both.
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 2, y: 2, width: 6, height: 6)); context.fill(CGRect(x: 30, y: 10, width: 6, height: 6))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Patches"), centeredAt: CGPoint(x: 50, y: 30))   // at 30, 20
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        await session.selectColorRange(tolerance: 10)
        let selection = try #require(session.selection)
        #expect(selection.path.boundingBoxOfPath == CGRect(x: 32, y: 22, width: 34, height: 14))
        #expect(selection.path.contains(CGPoint(x: 35, y: 25)) && selection.path.contains(CGPoint(x: 63, y: 33)) && !selection.path.contains(CGPoint(x: 50, y: 28)))
        #expect(session.history.undoName == "Color Range")
        session.foregroundColor = PaletteColor(red: 0, green: 1, blue: 0)
        await session.selectColorRange(tolerance: 10)
        #expect(session.brushError?.contains("foreground color") == true)
    }
}
