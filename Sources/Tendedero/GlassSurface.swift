import SwiftUI

extension View {
    /// Native glass adapts to the desktop and the system's transparency and
    /// contrast settings. Older systems retain the readable frosted capsule.
    @ViewBuilder
    func feedbackGlass() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
        }
    }
}
