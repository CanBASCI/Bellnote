import SwiftUI

/// Shown in a recording that was never processed. Nothing else can show before it is.
struct NotProcessedView: View {
    var start: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Not processed yet")
                .appFont(.title3, weight: .semibold)
            Text("Process the recording to get the raw text, AI correction and assignments.")
                .appFont(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // Same look as Ask and Listen.
            GlassEffectContainer(spacing: 8) {
                StudyButton(title: Text("Process"), systemImage: "waveform.badge.magnifyingglass", fillsWidth: false, action: start)
                    .buttonStyle(.glass)
                    .lineLimit(1)
                    .controlSize(.large)
            }
            .padding(.top, 6)
        }
        .padding(24)
    }
}
