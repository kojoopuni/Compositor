import AppKit
import SwiftUI

/// Layer > New Text Layer… and Edit Text…: a floating panel whose every change is set into the layer at once. The
/// layer is moved, scaled and rotated with the Move tool like any other; scaling it re-sets the text at the new size.
@MainActor
final class TextPanelController {
    static let shared = TextPanelController()
    private let panel = FloatingPanelController(name: "Text")

    func newLayer(in session: EditorSession) {
        var style = TextStyle(string: "Text")
        let color = session.foregroundColor
        style.red = Double(color.red); style.green = Double(color.green); style.blue = Double(color.blue)
        // A size that reads on this canvas, whatever its resolution.
        if let height = session.document?.height { style.size = max(12, (Double(height) / 10).rounded()) }
        guard let id = session.addTextLayer(style) else { return }
        edit(id, in: session)
    }

    func edit(_ id: UUID, in session: EditorSession) {
        guard session.document?.layers.first(where: { $0.id == id })?.liveText != nil else { return }
        panel.show(title: "Text", content: TextPanel(session: session, layerID: id) { [panel] in panel.close() })
    }
}

struct TextPanel: View {
    let session: EditorSession
    let layerID: UUID
    let done: () -> Void
    @State private var style = TextStyle(string: "")
    private static let families = NSFontManager.shared.availableFontFamilies

    private var layerStyle: TextStyle? { session.document?.layers.first { $0.id == layerID }?.liveText }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $style.string).font(.body).frame(width: 340, height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Picker("Font", selection: family) { ForEach(Self.families, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 190)
                Picker("Style", selection: $style.font) { ForEach(members, id: \.self) { Text(displayName($0)).tag($0) } }.labelsHidden()
            }
            HStack {
                Text("Size").frame(width: 60, alignment: .leading)
                Slider(value: $style.size, in: 6...600)
                TextField("", value: $style.size, format: .number.precision(.fractionLength(0))).frame(width: 56).multilineTextAlignment(.trailing)
                Text("px").foregroundStyle(.secondary)
            }
            HStack {
                Text("Tracking").frame(width: 60, alignment: .leading)
                Slider(value: $style.tracking, in: -100...500)
                Text("\(Int(style.tracking))").monospacedDigit().frame(width: 56, alignment: .trailing)
            }
            HStack {
                Text("Leading").frame(width: 60, alignment: .leading)
                Slider(value: $style.lineHeight, in: 0.6...2.5)
                Text(style.lineHeight.formatted(.number.precision(.fractionLength(2)))).monospacedDigit().frame(width: 56, alignment: .trailing)
            }
            HStack {
                Picker("Alignment", selection: $style.alignment) {
                    ForEach(TextStyle.Alignment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Spacer()
                ColorPicker("Color", selection: color, supportsOpacity: false)
            }
            HStack { Spacer(); Button("Done", action: done).keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .onAppear { if let layerStyle { style = layerStyle } }
        // Set into the layer as it changes; each pause in typing is its own undo step.
        .task(id: style) {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, style.isValid, style != layerStyle else { return }
            session.updateTextLayer(layerID, to: style)
        }
    }

    private var family: Binding<String> {
        Binding(get: { NSFont(name: style.font, size: 12)?.familyName ?? Self.families.first ?? "" },
                set: { chosen in
                    let members = NSFontManager.shared.availableMembers(ofFontFamily: chosen)?.compactMap { $0.first as? String } ?? []
                    style.font = members.first { $0.hasSuffix("-Regular") || !$0.contains("-") } ?? members.first ?? chosen
                })
    }
    private var members: [String] {
        NSFontManager.shared.availableMembers(ofFontFamily: family.wrappedValue)?.compactMap { $0.first as? String } ?? [style.font]
    }
    private func displayName(_ postScript: String) -> String {
        NSFontManager.shared.availableMembers(ofFontFamily: family.wrappedValue)?
            .first { $0.first as? String == postScript }.flatMap { $0.count > 1 ? $0[1] as? String : nil } ?? postScript
    }
    private var color: Binding<Color> {
        Binding(get: { Color(.sRGB, red: style.red, green: style.green, blue: style.blue) },
                set: { picked in
                    guard let rgb = NSColor(picked).usingColorSpace(.sRGB) else { return }
                    style.red = Double(rgb.redComponent); style.green = Double(rgb.greenComponent); style.blue = Double(rgb.blueComponent)
                })
    }
}
