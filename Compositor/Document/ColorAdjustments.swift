import CoreGraphics
import Foundation

/// The fork's color adjustments — Threshold, Posterize, Vibrance and Photo Filter — each available under Image and as
/// an adjustment layer. Their settings travel together in this one value, so the app's adjustment and filter types
/// carry a single extra property for all four. (Black & White and Color Balance are the app's own.)
nonisolated struct ColorAdjustments: Codable, Equatable, Sendable {
    /// Threshold: brightness (0–255) at and above which a pixel turns white; below it, black.
    var thresholdLevel: Double = 128
    /// Posterize: levels per channel, 2–255.
    var posterizeLevels: Double = 4
    /// Vibrance lifts muted colors more than vivid ones; Saturation moves them all alike. −100–100.
    var vibrance: Double = 0, saturation: Double = 0
    /// Photo Filter: the filter's color, and how strongly it tints, 0–100.
    var filterColor = AdjustmentColor(red: 0.925, green: 0.541, blue: 0)   // Photoshop's Warming Filter (85)
    var filterDensity: Double = 25
    var filterPreservesLuminosity = true

    static let kinds: [FilterKind] = [.threshold, .posterize, .vibrance, .photoFilter]

    var isValid: Bool { self == normalized }
    var normalized: Self {
        let clamp = ImageAdjustmentPixels.clamp
        var result = self
        result.thresholdLevel = clamp(thresholdLevel, 1...255, 128)
        result.posterizeLevels = clamp(posterizeLevels, 2...255, 4).rounded()
        result.vibrance = clamp(vibrance, -100...100, 0); result.saturation = clamp(saturation, -100...100, 0)
        result.filterColor = filterColor.clamped
        result.filterDensity = clamp(filterDensity, 0...100, 25)
        return result
    }

    /// True when `kind` would leave every pixel as it is, so the panel can close without an undo step.
    func isIdentity(_ kind: FilterKind) -> Bool {
        switch kind {
        case .vibrance: vibrance == 0 && saturation == 0
        case .photoFilter: filterDensity == 0
        default: false
        }
    }

    func apply(_ kind: FilterKind, to image: CGImage) throws -> CGImage {
        let settings = normalized
        let code: Int32, values: [Float]
        switch kind {
        case .threshold: code = 1; values = [Float(settings.thresholdLevel / 255)]
        case .posterize: code = 2; values = [Float(settings.posterizeLevels)]
        case .vibrance: code = 3; values = [Float(settings.vibrance / 100), Float(settings.saturation / 100)]
        case .photoFilter:
            code = 5
            values = [Float(settings.filterColor.red), Float(settings.filterColor.green), Float(settings.filterColor.blue),
                      Float(settings.filterDensity / 100), settings.filterPreservesLuminosity ? 1 : 0]
        default: return image
        }
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            color_adjust(pixels, width, height, stride, code, values)
        }
    }
}
