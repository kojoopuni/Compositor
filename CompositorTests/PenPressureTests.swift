import AppKit
import Testing
@testable import Compositor

@MainActor
struct PenPressureTests {

    @Test func aPensPressureSetsTheTipsSizeAlongTheStrokeAndAMouseIsUnchanged() throws {
        func paint(pressures: [CGFloat]?) throws -> (width: (Int) -> Int, undo: Int) {
            let session = EditorSession()
            session.createDocument(width: 400, height: 120, emptyLayer: true)
            session.selectTool(.brush)
            session.brushSettings = BrushSettings(diameter: 40, hardness: 1, red: 1, green: 0, blue: 0, opacity: 1)
            defer { PenPressure.override = nil }
            for (index, x) in stride(from: 40, through: 360, by: 40).enumerated() {
                PenPressure.override = pressures.map { $0[min(index, $0.count - 1)] }
                if index == 0 { session.beginBrush(at: CGPoint(x: x, y: 60)) } else { session.continueBrush(at: CGPoint(x: x, y: 60)) }
            }
            session.finishBrushImmediately()
            let image = try #require(session.activeLayer?.asset?.image)
            let origin = try #require(session.activeLayer?.transform.origin)
            let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
            BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
            let (w, h, stride) = (image.width, image.height, context.bytesPerRow)
            // Copied out: the bitmap is gone by the time the measurements below are taken.
            let bytes = Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: stride * h))
            // How many pixels tall the stroke is at a document x.
            return ({ x in
                let column = x - Int(origin.x)
                guard (0..<w).contains(column) else { return 0 }
                return (0..<h).reduce(0) { $0 + (bytes[$1 * stride + column * 4 + 3] > 127 ? 1 : 0) }
            }, session.history.undoCount)
        }
        let mouse = try paint(pressures: nil)
        #expect(abs(mouse.width(80) - 40) <= 1 && abs(mouse.width(320) - 40) <= 1)          // full size from end to end
        let pen = try paint(pressures: [0.1, 0.1, 0.3, 0.6, 1, 1, 1, 1, 1])
        #expect(pen.width(60) < 14)                                                          // a light touch: a thin line
        #expect(abs(pen.width(320) - 40) <= 2)                                               // full pressure: the full tip
        #expect(pen.width(60) < pen.width(160) && pen.width(160) < pen.width(240))           // and it swells between them
        #expect(pen.undo == mouse.undo)                                                      // still one undo step
        #expect(BrushStroke.tipScale(forPressure: 0) == 0.15 && BrushStroke.tipScale(forPressure: 2) == 1)
    }
}
