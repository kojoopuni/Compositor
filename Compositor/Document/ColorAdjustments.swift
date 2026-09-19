import CoreGraphics
import Foundation

/// The fork's color adjustments — Black & White, Threshold, Posterize, Vibrance, Color Balance and Photo Filter —
/// each available under Image and as an adjustment layer. Their settings travel together in this one value, so the
/// app's adjustment and filter types carry a single extra property for all six.
nonisolated struct ColorAdjustments: Codable, Equatable, Sendable {
    /// Black & White: how much each channel contributes to the gray, as percentages. 30/59/11 is how the eye weighs
    /// them; raising one brightens what was that color (red up for skin, blue down for a dark sky).
    var grayRed: Double = 30, grayGreen: Double = 59, grayBlue: Double = 11
    /// Threshold: brightness (0–255) at and above which a pixel turns white; below it, black.
    var thresholdLevel: Double = 128
    /// Posterize: levels per channel, 2–255.
    var posterizeLevels: Double = 4
    /// Vibrance lifts muted colors more than vivid ones; Saturation moves them all alike. −100–100.
    var vibrance: Double = 0, saturation: Double = 0
    /// Color Balance: cyan–red, magenta–green and yellow–blue, −100–100, for each tonal range.
    var shadows = Tone(), midtones = Tone(), highlights = Tone()
    var preserveLuminosity = true
    /// Photo Filter: the filter's color, and how strongly it tints, 0–100.
    var filterColor = AdjustmentColor(red: 0.925, green: 0.541, blue: 0)   // Photoshop's Warming Filter (85)
    var filterDensity: Double = 25
    var filterPreservesLuminosity = true

    struct Tone: Codable, Equatable, Sendable {
        var red: Double = 0, green: Double = 0, blue: Double = 0
        var isNeutral: Bool { red == 0 && green == 0 && blue == 0 }
    }

    static let kinds: [FilterKind] = [.blackWhite, .threshold, .posterize, .vibrance, .colorBalance, .photoFilter]

    var isValid: Bool { self == normalized }
    var normalized: Self {
        let clamp = ImageAdjustmentPixels.clamp
        var result = self
        result.grayRed = clamp(grayRed, -200...300, 30); result.grayGreen = clamp(grayGreen, -200...300, 59); result.grayBlue = clamp(grayBlue, -200...300, 11)
        result.thresholdLevel = clamp(thresholdLevel, 1...255, 128)
        result.posterizeLevels = clamp(posterizeLevels, 2...255, 4).rounded()
        result.vibrance = clamp(vibrance, -100...100, 0); result.saturation = clamp(saturation, -100...100, 0)
        for path in [\Self.shadows, \.midtones, \.highlights] {
            result[keyPath: path] = Tone(red: clamp(self[keyPath: path].red, -100...100, 0), green: clamp(self[keyPath: path].green, -100...100, 0),
                                         blue: clamp(self[keyPath: path].blue, -100...100, 0))
        }
        result.filterColor = filterColor.clamped
        result.filterDensity = clamp(filterDensity, 0...100, 25)
        return result
    }

    /// True when `kind` would leave every pixel as it is, so the panel can close without an undo step.
    func isIdentity(_ kind: FilterKind) -> Bool {
        switch kind {
        case .vibrance: vibrance == 0 && saturation == 0
        case .colorBalance: shadows.isNeutral && midtones.isNeutral && highlights.isNeutral
        case .photoFilter: filterDensity == 0
        default: false
        }
    }

    func apply(_ kind: FilterKind, to image: CGImage) throws -> CGImage {
        let settings = normalized
        let code: Int32, values: [Float]
        switch kind {
        case .blackWhite: code = 0; values = [settings.grayRed, settings.grayGreen, settings.grayBlue].map { Float($0 / 100) }
        case .threshold: code = 1; values = [Float(settings.thresholdLevel / 255)]
        case .posterize: code = 2; values = [Float(settings.posterizeLevels)]
        case .vibrance: code = 3; values = [Float(settings.vibrance / 100), Float(settings.saturation / 100)]
        case .colorBalance:
            code = 4
            values = [settings.shadows, settings.midtones, settings.highlights].flatMap { [$0.red, $0.green, $0.blue].map { Float($0 / 100) } }
                + [settings.preserveLuminosity ? 1 : 0]
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
