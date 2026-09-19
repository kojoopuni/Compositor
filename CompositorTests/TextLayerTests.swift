import AppKit
import Testing
@testable import Compositor

@MainActor
struct TextLayerTests {
    private func session() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 600, height: 300, emptyLayer: true)
        return session
    }
    private func coverage(_ image: CGImage) throws -> Int {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<image.width * image.height).reduce(0) { $0 + (bytes[$1 * 4 + 3] > 127 ? 1 : 0) }
    }

    @Test func textIsSetIntoALayerThatIsCenteredNamedAndUndoable() throws {
        let session = session()
        let count = session.history.undoCount
        let id = try #require(session.addTextLayer(TextStyle(string: "Ruins\nLevel 2", size: 60)))
        let layer = try #require(session.activeLayer)
        #expect(layer.id == id && layer.name == "Ruins" && layer.liveText?.string == "Ruins\nLevel 2")
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "New Text Layer")
        let image = try #require(layer.asset?.image)
        #expect(try coverage(image) > 500)                               // letters were drawn
        #expect(abs(layer.transform.center.x - 300) <= 1 && abs(layer.transform.center.y - 150) <= 1)
        #expect(session.addTextLayer(TextStyle(string: "")) == nil)      // nothing to set
        session.undo()
        #expect(session.document?.layers.contains { $0.id == id } == false)
    }

    @Test func editingResetsTheTextAndKeepsItsCornerAndScalingResetsItSharp() throws {
        let session = session()
        let id = try #require(session.addTextLayer(TextStyle(string: "Wall", size: 40), at: CGPoint(x: 20, y: 30)))
        let before = try #require(session.activeLayer)
        var style = try #require(before.liveText)
        style.string = "Mossy stone wall"; style.size = 80; style.red = 1; style.green = 0; style.blue = 0
        session.updateTextLayer(id, to: style)
        let edited = try #require(session.activeLayer)
        #expect(edited.transform.origin == CGPoint(x: 20, y: 30) && edited.transform.size.width > before.transform.size.width * 2)
        #expect(edited.name == "Mossy stone wall" && session.history.undoName == "Edit Text")
        #expect(edited.liveShape?.style.red == 1 && edited.liveShape?.style.green == 0)

        // Doubled with the Move tool: set again at twice the font size, at exactly the new pixel size.
        session.beginTransform()
        var draft = try #require(session.transformEdit?.draft)
        draft.size = CGSize(width: draft.size.width * 2, height: draft.size.height * 2)
        session.previewTransform(draft)
        session.commitTransform()
        let scaled = try #require(session.activeLayer)
        #expect(abs((scaled.liveText?.size ?? 0) - 160) < 2)
        #expect(scaled.asset?.image.width == Int(draft.size.width.rounded()) && scaled.asset?.image.height == Int(draft.size.height.rounded()))
    }

    @Test func textSurvivesSavingAndStopsBeingTextOncePaintedOn() async throws {
        let session = session()
        let id = try #require(session.addTextLayer(TextStyle(string: "Saved", font: "Georgia", size: 50, alignment: .center, tracking: 40)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("text-\(UUID().uuidString).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        let text = try #require(reopened.document?.layers.first { $0.id == id }?.liveText)
        #expect(text.string == "Saved" && text.font == "Georgia" && text.alignment == .center && text.tracking == 40)
        // A project written before text layers existed has no such field, and still opens.
        let plain = try JSONDecoder().decode(LayerShapeStyle.self, from: Data(#"{"kind":"Ellipse","red":1,"green":0,"blue":0,"cornerRadius":0}"#.utf8))
        #expect(plain.text == nil && plain.kind == .ellipse)

        session.selectTool(.brush)
        session.beginBrush(at: CGPoint(x: 300, y: 150)); session.continueBrush(at: CGPoint(x: 320, y: 160)); session.finishBrushImmediately()
        #expect(session.activeLayer?.liveText == nil && session.activeText == nil)
    }
}
