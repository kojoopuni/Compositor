import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// What an assistant can ask of the running app, each request acting on the project in the front tab. Everything
/// goes through the same session methods the menus and tools call, so each change is one ordinary undo step and
/// follows every rule a change made by hand does.
@MainActor
enum ControlCommands {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func handle(_ command: String, _ arguments: [String: Any], in workspace: ProjectWorkspace) async throws -> [String: Any] {
        let session = workspace.current.session
        switch command {
        case "info": return info(session)
        case "render": return try await render(session, arguments)
        case "undo":
            guard session.canUndo else { throw Failure("there is nothing to undo") }
            let name = session.history.undoName
            session.undo()
            return ["undone": name]
        default: break
        }
        // Everything below changes the document, and waits its turn behind whatever the user is in the middle of.
        guard session.document != nil else { throw Failure("no project is open in the front tab") }
        await session.waitForFileRequest()
        guard session.canEditLayers, session.filterEdit == nil, session.hueSaturation == nil else {
            throw Failure("the app is busy with another edit; finish or cancel it first")
        }
        switch command {
        case "addLayer": return try await addLayer(session, arguments)
        case "setLayer": return try setLayer(session, arguments)
        case "filter": return try await filter(session, arguments)
        case "addAdjustment": return try addAdjustment(session, arguments)
        default: throw Failure("unknown command '\(command)'")
        }
    }

    // MARK: Reading

    static func info(_ session: EditorSession) -> [String: Any] {
        guard let document = session.document else { return ["open": false] }
        let layers: [[String: Any]] = document.layers.reversed().map { layer in
            var entry: [String: Any] = ["id": layer.id.uuidString, "name": layer.name, "visible": layer.isVisible,
                "opacity": layer.opacity, "blendMode": layer.blendMode.rawValue, "x": layer.transform.origin.x, "y": layer.transform.origin.y,
                "width": layer.transform.size.width, "height": layer.transform.size.height,
                "kind": layer.isGroup ? "folder" : layer.adjustment != nil ? "adjustment" : layer.asset == nil ? "blank" : "pixels",
                "active": layer.id == session.activeLayerID]
            if let parent = layer.parentID { entry["parent"] = parent.uuidString }
            if let mask = layer.mask { entry["mask"] = mask.isEnabled ? "enabled" : "disabled" }
            return entry
        }
        var result: [String: Any] = ["open": true, "width": document.width, "height": document.height, "layers": layers,
                                     "unsavedChanges": session.isModified, "canUndo": session.canUndo]
        if let url = session.projectURL { result["project"] = url.path }
        if let selection = document.selection, !selection.isEmpty {
            let box = selection.path.boundingBoxOfPath
            result["selection"] = ["x": box.minX, "y": box.minY, "width": box.width, "height": box.height]
        }
        return result
    }

    static func render(_ session: EditorSession, _ arguments: [String: Any]) async throws -> [String: Any] {
        guard let snapshot = session.projectSnapshot() else { throw Failure("no project is open in the front tab") }
        var image = try await ImageExporter.shared.render(snapshot).image
        if let region = arguments["region"] as? [String: Any], let x = number(region["x"]), let y = number(region["y"]),
           let width = number(region["width"]), let height = number(region["height"]) {
            let box = CGRect(x: x, y: y, width: width, height: height).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !box.isEmpty, let cropped = image.cropping(to: box) else { throw Failure("the region falls outside the canvas") }
            image = cropped
        }
        let limit = Int(number(arguments["maxSize"]) ?? 1024)
        if limit > 0, max(image.width, image.height) > limit {
            image = try TileSheet.image(of: image, count: 1, limit: limit)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ExportError.encode }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encode }
        return ["png": (data as Data).base64EncodedString(), "width": image.width, "height": image.height]
    }

    // MARK: Changing

    private static func target(_ session: EditorSession, _ arguments: [String: Any]) throws -> ImageLayer {
        let layers = session.document?.layers ?? []
        guard let reference = arguments["layer"] as? String else {
            guard let active = session.activeLayer else { throw Failure("name a layer; none is active") }
            return active
        }
        if let id = UUID(uuidString: reference), let match = layers.first(where: { $0.id == id }) { return match }
        let named = layers.filter { $0.name == reference }
        guard named.count == 1 else {
            throw Failure(named.isEmpty ? "no layer has the id or name '\(reference)'" : "\(named.count) layers are named '\(reference)'; use a layer id")
        }
        return named[0]
    }

    static func addLayer(_ session: EditorSession, _ arguments: [String: Any]) async throws -> [String: Any] {
        guard let encoded = arguments["png"] as? String, let data = Data(base64Encoded: encoded) else { throw Failure("addLayer needs the image as base64 in 'png'") }
        // The importer reads files, and the app's own temporary folder is the one place a sandboxed app may always write.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("control-\(UUID().uuidString).png")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let asset = try await ImageImporter.shared.decode(file)
        session.insert(asset)
        guard let id = session.activeLayerID else { throw Failure("the layer could not be added") }
        if let name = arguments["name"] as? String { session.renameLayer(id, to: name) }
        _ = try setLayer(session, arguments.merging(["layer": id.uuidString]) { $1 })
        return ["added": id.uuidString]
    }

    static func setLayer(_ session: EditorSession, _ arguments: [String: Any]) throws -> [String: Any] {
        let layer = try target(session, arguments)
        session.selectLayers([layer.id], primary: layer.id)
        if let name = arguments["name"] as? String, name != layer.name { session.renameLayer(layer.id, to: name) }
        if let visible = arguments["visible"] as? Bool, visible != layer.isVisible { session.toggleLayerVisibility(layer.id) }
        if let opacity = number(arguments["opacity"]) { session.setLayerOpacity(opacity / 100) }
        if let blend = arguments["blend"] as? String {
            guard let mode = LayerBlendMode.allCases.first(where: { $0.rawValue.lowercased() == blend.lowercased() }) else {
                throw Failure("blend is one of: \(LayerBlendMode.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            session.setLayerBlendMode(mode)
        }
        let placement = ["x", "y", "width", "height", "rotation"].contains { arguments[$0] != nil }
        if placement {
            session.beginTransform()
            guard var draft = session.transformEdit?.draft else { throw Failure("this layer cannot be moved right now") }
            if let value = number(arguments["width"]) { draft.size.width = value }
            if let value = number(arguments["height"]) { draft.size.height = value }
            if let value = number(arguments["x"]) { draft.origin.x = value }
            if let value = number(arguments["y"]) { draft.origin.y = value }
            if let value = number(arguments["rotation"]) { draft.rotation = value }
            guard draft.isValid else { session.cancelTransform(); throw Failure("that position or size is out of range") }
            session.previewTransform(draft)
            session.commitTransform()
        }
        return ["updated": layer.id.uuidString]
    }

    static func filter(_ session: EditorSession, _ arguments: [String: Any]) async throws -> [String: Any] {
        let layer = try target(session, arguments)
        guard let name = arguments["filter"] as? String,
              let kind = FilterKind.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else {
            throw Failure("filter is one of: \(FilterKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        session.selectLayers([layer.id], primary: layer.id)
        var settings = session.filterSettings
        let values = arguments["settings"] as? [String: Any] ?? [:]
        for (key, path) in doubles { if let value = number(values[key]) { settings[keyPath: path] = value } }
        for (key, path) in flags { if let value = values[key] as? Bool { settings[keyPath: path] = value } }
        session.beginFilter(kind)
        guard session.filterEdit != nil else { throw Failure(session.brushError ?? "\(kind.rawValue) needs a single visible layer with pixels (and a selection, for Content-Aware Fill)") }
        session.updateFilter(settings, preview: true)
        await session.commitFilter()
        var waits = 0
        while let edit = session.filterEdit, edit.previewError == nil, waits < 8 {
            await edit.previewTask?.value
            await session.commitFilter()
            waits += 1
        }
        if let edit = session.filterEdit {
            let reason = edit.previewError ?? "the filter could not be applied"
            session.cancelFilter()
            throw Failure(reason)
        }
        return ["filtered": layer.id.uuidString, "filter": kind.rawValue]
    }

    static func addAdjustment(_ session: EditorSession, _ arguments: [String: Any]) throws -> [String: Any] {
        guard let name = arguments["kind"] as? String,
              let kind = AdjustmentKind.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else {
            throw Failure("kind is one of: \(AdjustmentKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        if arguments["above"] != nil {
            let below = try target(session, ["layer": arguments["above"] as Any])
            session.selectLayers([below.id], primary: below.id)
        }
        session.addAdjustment(kind)
        // Left open, the adjustment's panel is there for the user to tune what the assistant added.
        guard let id = session.activeLayerID else { throw Failure("the adjustment layer could not be added") }
        return ["added": id.uuidString, "adjustment": kind.rawValue, "note": "its panel is open in the app for the user to adjust"]
    }

    private static let doubles: [String: WritableKeyPath<FilterSettings, Double>] = [
        "radius": \.radius, "angle": \.angle, "distance": \.distance, "amount": \.amount, "distortion": \.distortion,
        "horizontal": \.offsetHorizontal, "vertical": \.offsetVertical, "band": \.tileBand, "lighting": \.tileLighting,
        "strength": \.lightingStrength, "highPassRadius": \.highPassRadius, "sharpenAmount": \.sharpenAmount,
        "sharpenRadius": \.sharpenRadius, "threshold": \.sharpenThreshold, "normalStrength": \.normalStrength, "cells": \.cloudCells,
        "refine": \.refineEdges, "contrast": \.matteContrast, "shift": \.shiftEdge,
    ]
    private static let flags: [String: WritableKeyPath<FilterSettings, Bool>] = [
        "gaussian": \.gaussian, "monochromatic": \.monochromatic, "keepEdges": \.keepEdges, "yDown": \.normalYDown, "wrap": \.normalWrap,
    ]
    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
}
