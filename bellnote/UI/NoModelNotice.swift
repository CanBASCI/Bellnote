import SwiftUI

/// Asked before a lecture is processed while no text model is installed. The transcript still
/// gets written, but tags, AI correction and assignments need a model, so the student decides first.
private struct NoModelNotice: ViewModifier {
    @Binding var isPresented: Bool
    var proceed: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "No AI model installed",
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button("Process anyway") { proceed() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The text is written, then processing waits for a model. AI correction, tags and assignments need one. Download it in Settings, Models.")
        }
    }
}

extension View {
    func noModelNotice(isPresented: Binding<Bool>, proceed: @escaping () -> Void) -> some View {
        modifier(NoModelNotice(isPresented: isPresented, proceed: proceed))
    }
}
