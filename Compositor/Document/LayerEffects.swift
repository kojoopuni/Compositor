import CoreGraphics
import CoreImage
import Foundation

/// Drop Shadow, Outer Glow and Stroke, made as an ordinary layer directly beneath the one they belong to — what
/// Photoshop's "Create Layers" does with a layer style. The effect is drawn from the layer's outline as it stands
/// (pixels, mask, position, rotation), so it follows cut-outs and text alike; being a layer, it can then be masked,
/// faded, blurred further or painted on. It does not follow later changes to its layer: change the settings in the
/// panel again, or delete it and add it afresh.
nonisolated struct LayerEffect: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case dropShadow = "Drop Shadow", outerGlow = "Outer Glow", stroke = "Stroke" }
    var kind: Kind
    var red: Double, green: Double, blue: Double
    /// 0–100.
    var opacity: Double
    /// Blur for a shadow or glow, thickness for a stroke; document pixels.
    var size: Double
    /// Drop Shadow only: how far it falls, in document pixels, and the angle the light comes from (degrees,
    /// counterclockwise from the right, as in Photoshop; 120 is upper left).
    var distance: Double = 0, angle: Double = 120

    init(_ kind: Kind) {
        self.kind = kind
        switch kind {
        case .dropShadow: red = 0; green = 0; blue = 0; opacity = 60; size = 12; distance = 10
        case .outerGlow: red = 1; green = 0.95; blue = 0.7; opacity = 75; size = 18
        case .stroke: red = 0; green = 0; blue = 0; opacity = 100; size = 4
        }
    }

    var isValid: Bool {
        [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } && (0...100).contains(opacity) && (0...500).contains(size)
            && (0...2000).contains(distance) && angle.isFinite
    }
    var blendMode: LayerBlendMode { kind == .outerGlow ? .screen : kind == .dropShadow ? .multiply : .normal }

    /// The effect for a layer whose outline is `coverage`'s alpha (document-sized): the image, and where in the
    /// document its top-left corner sits. Nil when there is nothing to show.
    func render(from coverage: CGImage) throws -> (image: CGImage, origin: CGPoint)? {
        let width = coverage.width, height = coverage.height
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        // Room around the canvas for what spreads or falls past it; trimmed again below.
        let reach = CGFloat(size * 3 + distance + 4).rounded(.up)
        let outline = CIImage(cgImage: coverage).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: CGFloat(red), y: CGFloat(green), z: CGFloat(blue), w: 0),
        ]).premultiplyingAlpha()
        var effect: CIImage
        switch kind {
        case .dropShadow:
            // Core Image's y points up; the light's angle is where it comes from, so the shadow falls the other way.
            let radians = angle * .pi / 180
            effect = outline.transformed(by: CGAffineTransform(translationX: CGFloat(-cos(radians) * distance), y: CGFloat(-sin(radians) * distance)))
                .applyingGaussianBlur(sigma: max(0.01, size / 2))
        case .outerGlow:
            effect = outline.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(0, size / 4)])
                .applyingGaussianBlur(sigma: max(0.01, size / 2))
        case .stroke:
            effect = outline.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(0, size)])
        }
        let frame = extent.insetBy(dx: -reach, dy: -reach)
        let drawn = try PixelAdjust.render(effect.transformed(by: CGAffineTransform(translationX: reach, y: reach)),
                                           width: Int(frame.width), height: Int(frame.height), isMask: false)
        guard let content = try Trim.contentBounds(of: drawn, threshold: 1), let image = drawn.cropping(to: content) else { return nil }
        return (image, CGPoint(x: content.minX - reach, y: content.minY - reach))
    }
}

extension EditorSession {
    /// The layers an effect may be added to: a single one with something to outline.
    var canAddLayerEffect: Bool {
        canEditLayers && selectedLayerIDs.count <= 1 && activeLayer.map { !$0.isGroup && $0.adjustment == nil && $0.asset != nil } == true
    }

    /// The layer's outline in the document — its pixels through its mask, placed, scaled and rotated — on its own.
    private func outline(of layer: ImageLayer, in snapshot: ProjectSnapshot) async throws -> CGImage {
        guard let record = snapshot.manifest.layers.first(where: { $0.id == layer.id }) else { throw ProjectError.invalid }
        var alone = record
        alone.parentID = nil; alone.maskSourceID = nil; alone.isVisible = true; alone.opacity = 1; alone.blendMode = nil
        let manifest = ProjectManifest(resolution: snapshot.manifest.resolution, documentID: snapshot.manifest.documentID,
            width: snapshot.manifest.width, height: snapshot.manifest.height, activeLayerID: layer.id, layers: [alone])
        let only = ProjectSnapshot(manifest: manifest, images: snapshot.images.filter { $0.key == layer.id }, masks: snapshot.masks.filter { $0.key == layer.id })
        return try await ImageExporter.shared.render(only).image
    }

    /// Adds `effect` beneath the active layer as one undo step, and returns the new layer's id. With `replacing`,
    /// that earlier effect layer is redrawn instead, which is how the panel's sliders work.
    @discardableResult
    func addLayerEffect(_ effect: LayerEffect, to sourceID: UUID? = nil, replacing: UUID? = nil) async -> UUID? {
        guard effect.isValid, canEditLayers, let snapshot = projectSnapshot(),
              let source = document?.layers.first(where: { $0.id == (sourceID ?? activeLayerID) }), source.asset != nil, !source.isGroup else { return nil }
        do {
            let coverage = try await outline(of: source, in: snapshot)
            guard canEditLayers, let made = try effect.render(from: coverage), let thumbnail = try? PixelInvert.thumbnail(of: made.image) else { return nil }
            let asset = ImportedImage(image: made.image, thumbnail: thumbnail, name: effect.kind.rawValue)
            if let replacing, let index = document?.layers.firstIndex(where: { $0.id == replacing }) {
                beginEdit("Edit \(effect.kind.rawValue)")
                document?.layers[index].asset = asset
                document?.layers[index].transform = LayerTransform(origin: made.origin, size: CGSize(width: made.image.width, height: made.image.height))
                document?.layers[index].opacity = effect.opacity / 100
                endEdit()
                return replacing
            }
            var layer = ImageLayer(asset: asset, origin: made.origin)
            layer.name = "\(source.name) \(effect.kind.rawValue.lowercased())"
            layer.parentID = source.parentID
            layer.opacity = effect.opacity / 100
            layer.blendMode = effect.blendMode
            guard let index = document?.layers.firstIndex(where: { $0.id == source.id }) else { return nil }
            beginEdit("Add \(effect.kind.rawValue)")
            // Layers are stored bottom to top, so taking the source's place puts the effect directly beneath it.
            document?.layers.insert(layer, at: index)
            endEdit()
            return layer.id
        } catch { brushError = error.localizedDescription; return nil }
    }
}
