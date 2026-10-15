import SwiftUI

/// The player in the tab bar's bottom accessory. The system draws the glass and places it: above the
/// tab bar while the bar is open, and beside the small tab button on the same line once it shrinks.
struct PlayerAccessory: View {
    var audio: LectureAudio
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        HStack(spacing: 8) {
            Button(audio.isPlaying ? "Pause" : "Play", systemImage: audio.isPlaying ? "pause.fill" : "play.fill") {
                audio.toggle()
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .buttonStyle(.plain)
            .frame(width: 36, height: 36)
            if placement != .inline {
                Text(MediaClock.short(audio.currentSecond))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(audio.currentSecond) },
                    set: { audio.seek(to: Int($0), play: audio.isPlaying) }
                ),
                in: 0...Double(max(audio.duration, 1))
            )
            if placement != .inline {
                Text(MediaClock.short(audio.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
    }
}

/// A glass button whose icon takes the app tint, like the Process button inside a list.
/// Outside a list a glass button draws its icon in the primary colour, which looked black.
struct StudyButton: View {
    var title: Text
    var systemImage: String
    /// True when the button fills its share of a row. False keeps it as wide as its content.
    var fillsWidth = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            // A label, so the system sets the space between the icon and the text.
            Label {
                title
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
            }
            // The label fills the button, so a row of three splits its width evenly.
            // The minimum height keeps the button as tall as one with the body font.
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 23)
        }
        .accessibilityElement(children: .combine)
    }
}


extension View {
    /// Sets `compact` the way the tab bar shrinks: true after the page is dragged down a little,
    /// false when it is dragged back up or sits at the top. A few points of wobble do not count.
    func compactOnScroll(_ compact: Binding<Bool>) -> some View {
        modifier(CompactOnScroll(compact: compact))
    }
}

private struct CompactOnScroll: ViewModifier {
    @Binding var compact: Bool
    /// Travel in the current direction since the direction last changed.
    @State private var travel: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { old, new in
                if new <= 8 {
                    set(false)
                    travel = 0
                    return
                }
                let delta = new - old
                // A new direction starts a new count.
                if (delta > 0) != (travel > 0) { travel = 0 }
                travel += delta
                if travel > 24 {
                    set(true)
                } else if travel < -12 {
                    set(false)
                }
            }
    }

    private func set(_ value: Bool) {
        guard value != compact else { return }
        withAnimation(.smooth) { compact = value }
    }
}
