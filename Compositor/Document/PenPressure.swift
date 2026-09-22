import AppKit

/// How hard a pen is pressing, read from the event being handled. A mouse reports a "pressure" too (1 while its
/// button is down), and tests send synthetic events with whatever they were given, so only events that say they come
/// from a tablet count; everything else is nil and paints at full size.
@MainActor
enum PenPressure {
    /// Set by tests in place of a real tablet event.
    static var override: CGFloat?

    static var current: CGFloat? {
        if let override { return override }
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return event.subtype == .tabletPoint ? CGFloat(event.pressure) : nil
        case .tabletPoint:
            return CGFloat(event.pressure)
        default:
            return nil
        }
    }
}
