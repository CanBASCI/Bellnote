import SwiftUI

/// The play button and the position slider, as two glass shapes in one container so they flow together.
struct PlayerBar: View {
    var isPlaying: Bool
    var current: Int
    var duration: Int
    var toggle: () -> Void
    var seek: (Int) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill", action: toggle)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                HStack(spacing: 12) {
                    Text(MediaClock.short(current))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(current) },
                            set: { seek(Int($0)) }
                        ),
                        in: 0...Double(max(duration, 1))
                    )
                    Text(MediaClock.short(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// A glass button whose icon takes the app tint, like the Process button inside a list.
/// Outside a list a glass button draws its icon in the primary colour, which looked black.
struct StudyButton: View {
    var title: Text
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                title
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}
