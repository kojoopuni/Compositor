import AppKit
import SwiftUI

/// View > Tile Preview: the finished picture repeated in a grid, which is how a tiling texture is judged. Seams
/// and anything that repeats too obviously show at once. It follows the document as it is edited.
@MainActor
final class TilePreviewController {
    static let shared = TilePreviewController()
    private let panel = FloatingPanelController(name: "Tile Preview")

    func show(_ session: EditorSession) {
        panel.show(title: "Tile Preview", content: TilePreviewView(session: session))
    }
}

struct TilePreviewView: View {
    let session: EditorSession
    @State private var sheet: NSImage?
    @State private var count = 3
    private let side: CGFloat = 540

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if let sheet {
                    Image(nsImage: sheet).interpolation(.high).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Text(session.document == nil ? "Open a project to preview it as tiles." : "Rendering…").foregroundStyle(.secondary)
                }
            }.frame(width: side, height: side)
            Picker("Tiles", selection: $count) {
                ForEach([2, 3, 4], id: \.self) { Text("\($0) × \($0)").tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
        }
        .padding(16)
        // Every committed edit moves one of these on, so the preview is never stale for long.
        .task(id: "\(session.history.undoCount) \(session.history.redoName) \(count) \(session.document?.id.uuidString ?? "")") { await render() }
    }

    private func render() async {
        guard let snapshot = session.projectSnapshot() else { sheet = nil; return }
        let count = count, limit = Int(side * 2)
        let made = try? await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let tile = try await ImageExporter.shared.render(snapshot).image
            return try TileSheet.image(of: tile, count: count, limit: limit)
        }.value
        guard !Task.isCancelled else { return }
        sheet = made.flatMap { $0 }.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
}
