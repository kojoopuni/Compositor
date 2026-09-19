import CoreGraphics
import Foundation

/// Image > Trim Transparent Pixels: crops the canvas to whatever can be seen, as Photoshop's Trim does. After
/// Remove Background that is the subject. Like Crop, layers keep all their pixels.
nonisolated enum Trim {
    /// The smallest rectangle holding every pixel that is more than faintly visible, in the image's own pixels
    /// with y running down; nil when nothing is.
    static func contentBounds(of image: CGImage, threshold: UInt8 = 8) throws -> CGRect? {
        let width = image.width, height = image.height
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * context.bytesPerRow
            var first = -1, last = -1
            for x in 0..<width where bytes[row + x * 4 + 3] > threshold {
                if first < 0 { first = x }
                last = x
            }
            guard first >= 0 else { continue }
            minX = min(minX, first); maxX = max(maxX, last)
            minY = min(minY, y); maxY = y
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The snapshot cropped to `box` (document pixels), or to its visible content grown by `padding` when `box` is nil.
    static func cropped(_ snapshot: ProjectSnapshot, to box: CGRect?, padding: CGFloat = 0) async throws -> (snapshot: ProjectSnapshot, box: CGRect)? {
        let canvas = CGRect(x: 0, y: 0, width: snapshot.manifest.width, height: snapshot.manifest.height)
        var kept: CGRect
        if let box {
            kept = box.integral
        } else {
            let image = try await ImageExporter.shared.render(snapshot).image
            guard let content = try contentBounds(of: image) else { return nil }
            kept = content.insetBy(dx: -padding, dy: -padding).integral.intersection(canvas)
        }
        guard kept.width >= 1, kept.height >= 1, kept.width <= 30_000, kept.height <= 30_000 else { throw ProjectError.tooLarge }
        let result = try await CanvasResizer.shared.resize(snapshot, to: CanvasSizeOptions(
            width: Int(kept.width), height: Int(kept.height), contentOffset: CGPoint(x: -kept.minX, y: -kept.minY)))
        return (result, kept)
    }
}

extension EditorSession {
    var canTrim: Bool { document != nil && canStartProjectOperation }

    func trimTransparentPixels() async {
        guard canTrim, let snapshot = projectSnapshot() else { return }
        cancelCrop()
        commitTransform()
        isProjectBusy = true
        defer { isProjectBusy = false }
        do {
            guard let trimmed = try await Trim.cropped(snapshot, to: nil) else {
                brushError = "There is nothing visible to trim to."
                return
            }
            applyDocumentSize(trimmed.snapshot, actionName: "Trim")
        } catch { brushError = error.localizedDescription }
    }
}
