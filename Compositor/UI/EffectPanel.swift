import AppKit
import SwiftUI

/// Layer > Layer Effects: adds the effect beneath the active layer and keeps a panel open whose sliders redraw it.
@MainActor
final class EffectPanelController {
    static let shared = EffectPanelController()
    private let panel = FloatingPanelController(name: "Layer Effect")

    func add(_ kind: LayerEffect.Kind, in session: EditorSession) {
        guard let source = session.activeLayerID else { return }
        let effect = LayerEffect(kind)
        Task {
            guard let id = await session.addLayerEffect(effect, to: source) else { return }
            panel.show(title: kind.rawValue, content: EffectPanel(session: session, sourceID: source, effectID: id, effect: effect) { [panel] in panel.close() })
        }
    }
}

struct EffectPanel: View {
    let session: EditorSession
    let sourceID: UUID, effectID: UUID
    @State var effect: LayerEffect
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(effect.kind == .stroke ? "Width" : "Size", $effect.size, 0...(effect.kind == .stroke ? 100 : 250), "px")
            if effect.kind == .dropShadow {
                row("Distance", $effect.distance, 0...300, "px")
                row("Angle", $effect.angle, -180...180, "°")
            }
            row("Opacity", $effect.opacity, 0...100, "%")
            ColorPicker("Color", selection: Binding(
                get: { Color(.sRGB, red: effect.red, green: effect.green, blue: effect.blue) },
                set: { picked in
                    guard let rgb = NSColor(picked).usingColorSpace(.sRGB) else { return }
                    effect.red = Double(rgb.redComponent); effect.green = Double(rgb.greenComponent); effect.blue = Double(rgb.blueComponent)
                }), supportsOpacity: false)
            Text("The effect is its own layer beneath this one: mask it, fade it or delete it like any other.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Done", action: done).keyboardShortcut(.defaultAction) }
        }
        .padding(16).frame(width: 340)
        .task(id: effect) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await session.addLayerEffect(effect, to: sourceID, replacing: effectID)
        }
    }

    private func row(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ unit: String) -> some View {
        HStack {
            Text(title).frame(width: 70, alignment: .leading)
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }), in: range)
            Text("\(Int(value.wrappedValue))\(unit)").monospacedDigit().frame(width: 56, alignment: .trailing)
        }
    }
}
