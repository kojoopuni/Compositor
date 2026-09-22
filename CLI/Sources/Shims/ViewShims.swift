import SwiftUI

// The app's ContentView (not part of this build) gives its panels this modifier; the panels the engine refers to
// still compile against it here.
extension View {
    func roundedControls() -> some View { buttonBorderShape(.capsule) }
}
