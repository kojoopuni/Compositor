import AppKit
import Testing
@testable import Compositor

@MainActor
struct LayerEffectTests {
    /// A 40 px red square in the middle of a 200 px canvas.
    private func session() throws -> (EditorSession, UUID) {
        let session = EditorSession()
        session.createDocument(width: 200, height: 200, emptyLayer: true)
        let context = try BrushRaster.context(width: 40, height: 40, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Square"))
        return (session, try #require(session.activeLayerID))
    }
    private func pixel(_ session: EditorSession, _ x: Int, _ y: Int) async throws -> [Int] {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { Int(bytes[(y * image.width + x) * 4 + $0]) }
    }

    @Test func aStrokeIsItsOwnLayerBeneathTheSourceAndOneUndoStep() async throws {
        let (session, square) = try session()
        let count = session.history.undoCount
        var stroke = LayerEffect(.stroke); stroke.size = 6; stroke.red = 0; stroke.green = 0; stroke.blue = 1
        let id = try #require(await session.addLayerEffect(stroke, to: square))
        let layers = try #require(session.document?.layers)
        #expect(layers.map(\.id).firstIndex(of: id)! + 1 == layers.map(\.id).firstIndex(of: square)!)     // directly beneath
        #expect(layers.first { $0.id == id }?.name == "Square stroke" && session.history.undoCount == count + 1)
        let inside = try await pixel(session, 100, 100), edge = try await pixel(session, 77, 100), beyond = try await pixel(session, 70, 100)
        #expect(inside == [255, 0, 0, 255])                                                                // the square, untouched
        #expect(edge == [0, 0, 255, 255])                                                                  // 3 px outside its left edge: stroke
        #expect(beyond[3] == 0)                                                                            // beyond the stroke: nothing
        session.undo()
        #expect(session.document?.layers.contains { $0.id == id } == false)
    }

    @Test func aShadowFallsAwayFromTheLightAndRedrawsInPlace() async throws {
        let (session, square) = try session()
        var shadow = LayerEffect(.dropShadow); shadow.size = 2; shadow.distance = 20; shadow.angle = 180; shadow.opacity = 100
        let id = try #require(await session.addLayerEffect(shadow, to: square))
        // Lit from the left, the shadow falls to the right of the square (which spans 80–120).
        var right = try await pixel(session, 132, 100), left = try await pixel(session, 66, 100)
        #expect(right[3] > 200 && left[3] == 0)
        shadow.angle = 0
        let redrawn = await session.addLayerEffect(shadow, to: square, replacing: id)
        #expect(redrawn == id)
        right = try await pixel(session, 132, 100); left = try await pixel(session, 66, 100)
        #expect(left[3] > 200 && right[3] == 0)
        #expect(session.document?.layers.count == 3)                                                       // redrawn, not added again
        var glow = LayerEffect(.outerGlow); glow.size = 900
        let refused = await session.addLayerEffect(glow, to: square)
        #expect(refused == nil)                                                                            // out of range
    }
}
