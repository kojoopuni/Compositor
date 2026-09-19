import AppKit
import UniformTypeIdentifiers

extension ProjectController {
    /// File > Export TIFF… and Export TGA…, following Export PNG.
    func export(as format: ExportFormat) async {
        guard session.document != nil, canStart else { return }
        session.cancelCrop()
        session.commitTransform()
        session.isProjectBusy = true
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export \(format.rawValue)"
        panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + "." + format.fileExtension
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) }
        else { response = await panel.begin() }
        guard response == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try await ImageExporter.shared.data(snapshot, as: format)
            try await ImageExporter.shared.write(data, to: url)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t export \(format.rawValue)"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            if let window { _ = await alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }
}
