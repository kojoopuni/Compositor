import SwiftUI

/// The panel rows for the fork's color adjustments, shown inside the app's filter panel.
struct ColorAdjustmentControls: View {
    let kind: FilterKind
    @Binding var settings: ColorAdjustments

    var body: some View {
        switch kind {
        case .blackWhite:
            slider("Reds", \.grayRed, -200...300, "%"); slider("Greens", \.grayGreen, -200...300, "%"); slider("Blues", \.grayBlue, -200...300, "%")
            note("How much each color contributes to the gray. Raise one to brighten what was that color.")
        case .threshold:
            slider("Level", \.thresholdLevel, 1...255, "")
        case .posterize:
            slider("Levels", \.posterizeLevels, 2...255, "")
        case .vibrance:
            slider("Vibrance", \.vibrance, -100...100, ""); slider("Saturation", \.saturation, -100...100, "")
            note("Vibrance lifts muted colors more than vivid ones.")
        case .colorBalance:
            let tones: [(String, WritableKeyPath<ColorAdjustments, ColorAdjustments.Tone>)] =
                [("Shadows", \.shadows), ("Midtones", \.midtones), ("Highlights", \.highlights)]
            ForEach(tones, id: \.0) { title, tone in
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                slider("Cyan – Red", tone.appending(path: \.red), -100...100, "")
                slider("Magenta – Green", tone.appending(path: \.green), -100...100, "")
                slider("Yellow – Blue", tone.appending(path: \.blue), -100...100, "")
            }
            Toggle("Preserve Luminosity", isOn: $settings.preserveLuminosity)
        case .photoFilter:
            ColorPicker("Filter Color", selection: Binding(
                get: { Color(.sRGB, red: settings.filterColor.red, green: settings.filterColor.green, blue: settings.filterColor.blue) },
                set: { picked in
                    guard let rgb = NSColor(picked).usingColorSpace(.sRGB) else { return }
                    settings.filterColor = AdjustmentColor(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
                }), supportsOpacity: false)
            slider("Density", \.filterDensity, 0...100, "%")
            Toggle("Preserve Luminosity", isOn: $settings.filterPreservesLuminosity)
        default:
            EmptyView()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func slider(_ title: String, _ key: WritableKeyPath<ColorAdjustments, Double>, _ range: ClosedRange<Double>, _ unit: String) -> some View {
        HStack {
            Text(title).frame(width: 120, alignment: .leading)
            Slider(value: Binding(get: { settings[keyPath: key] }, set: { settings[keyPath: key] = $0.rounded() }), in: range)
            Text("\(Int(settings[keyPath: key]))\(unit)").monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }
}
