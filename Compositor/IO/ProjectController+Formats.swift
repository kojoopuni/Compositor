import AppKit
import UniformTypeIdentifiers

extension ProjectController {
    /// File > Export PNG with Edge Bleed…: for cut-outs going into a game engine, where color under the
    /// transparency around them stops dark halos. 16 pixels covers the mip levels an engine will sample.
    func exportBleedPNG() async {
        await export(title: "Export PNG with Edge Bleed", type: .png, fileExtension: "png") { snapshot in
            try await ImageExporter.shared.pngData(snapshot, bleed: 16)
        }
    }

    /// File > Export TIFF… and Export TGA…, following Export PNG.
    func export(as format: ExportFormat) async {
        await export(title: "Export \(format.rawValue)", type: format.contentType, fileExtension: format.fileExtension) { snapshot in
            try await ImageExporter.shared.data(snapshot, as: format)
        }
    }

    private func export(title: String, type: UTType, fileExtension: String,
                        make: @escaping (ProjectSnapshot) async throws -> Data) async {
        guard session.document != nil, canStart else { return }
        session.cancelCrop()
        session.commitTransform()
        session.isProjectBusy = true
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = title
        panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + "." + fileExtension
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) }
        else { response = await panel.begin() }
        guard response == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try await ImageExporter.shared.write(try await make(snapshot), to: url)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t \(title.prefix(1).lowercased() + title.dropFirst())"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            if let window { _ = await alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }

    /// File > Open Photoshop Document…: the document's layers in a new tab, never touching the .psd itself.
    func openPhotoshopDocument() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "psd") ?? .data]
        panel.allowsMultipleSelection = false
        panel.title = "Open Photoshop Document"
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) } else { response = await panel.begin() }
        guard response == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let alert = NSAlert()
        do {
            let result = try await Task.detached(priority: .userInitiated) { try PSDImporter.load(url) }.value
            guard let tab = workspace?.addTab() else { return }
            // Installed as a new, unsaved project: saving writes a .comp and leaves the Photoshop file alone.
            tab.session.installProject(result.snapshot, from: url.deletingPathExtension().appendingPathExtension("comp"))
            tab.session.projectURL = nil
            guard !result.skipped.isEmpty || !result.vectorMasked.isEmpty else { return }
            alert.alertStyle = .informational
            alert.messageText = "Some of this document is drawn by Photoshop itself"
            alert.informativeText = [
                result.skipped.isEmpty ? nil : "Adjustment and fill layers have no pixels to bring: \(result.skipped.joined(separator: ", ")).",
                result.vectorMasked.isEmpty ? nil : "Vector masks were left behind on: \(result.vectorMasked.joined(separator: ", ")).",
                "Photoshop’s own flattened picture was added as the top layer so the project looks as it did. Hide it to work with the layers beneath.",
            ].compactMap { $0 }.joined(separator: "\n\n")
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t open the Photoshop document"
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: "OK")
        if let window { _ = await alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
