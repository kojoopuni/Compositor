import SwiftUI

// Menu items added by this fork, each group one view so it takes a single line (and a single slot of the ten a
// commands builder allows) where it joins the app's menus in CompositorApp.

/// File: the export formats beyond PNG and JPEG.
struct ExportFormatItems: View {
    let session: EditorSession
    let projects: ProjectController
    var body: some View {
        ForEach(ExportFormat.allCases, id: \.self) { format in
            Button("Export \(format.rawValue)…") { Task { await projects.export(as: format) } }
                .disabled(session.document == nil || !projects.canStart)
        }
        Button("Export PNG with Edge Bleed…") { Task { await projects.exportBleedPNG() } }
            .disabled(session.document == nil || !projects.canStart)
    }
}

/// Image: document operations.
struct TrimItem: View {
    let session: EditorSession
    var body: some View {
        ForEach(ColorAdjustments.kinds, id: \.self) { kind in
            Button("\(kind.rawValue)…") { session.beginFilter(kind) }
                .disabled(!session.canAdjustColors || session.hueSaturation != nil)
        }
        Divider()
        Button("Trim Transparent Pixels") { Task { await session.trimTransparentPixels() } }
            .disabled(!session.canTrim)
    }
}

/// View: ways of looking at the document.
struct TilePreviewItem: View {
    let session: EditorSession
    var body: some View {
        Button("Tile Preview") { TilePreviewController.shared.show(session) }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(session.document == nil)
    }
}

/// Compositor menu: whether an assistant on this Mac may drive the app. Off until the user turns it on.
struct AssistantControlItem: View {
    @AppStorage(ControlServer.enabledKey) private var enabled = false
    var body: some View {
        Toggle("Allow Assistant Control", isOn: Binding(get: { enabled }, set: { ControlServer.shared.setEnabled($0) }))
    }
}

/// Layer: text layers.
struct TextLayerItems: View {
    let session: EditorSession
    var body: some View {
        Button("New Text Layer…") { TextPanelController.shared.newLayer(in: session) }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!session.canEditLayers || session.document == nil)
        Button("Edit Text…") { if let id = session.activeLayerID { TextPanelController.shared.edit(id, in: session) } }
            .disabled(!session.canEditLayers || session.activeText == nil)
        Divider()
    }
}
