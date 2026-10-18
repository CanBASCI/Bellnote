import SwiftUI

/// The player in the tab bar's bottom accessory. The system draws the glass and places it: above the
/// tab bar while the bar is open, and beside the small tab button on the same line once it shrinks.
struct PlayerAccessory: View {
    var audio: LectureAudio
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    /// The second under the thumb while the finger drags it. The player is asked once, not on every step: when the
    /// finger lifts, or when the thumb has rested for a moment. The rest is a safety net for a lift that the slider
    /// does not report; without it the thumb stayed where it was left and the sound went on from the old place.
    @State private var scrubbing: Double?

    var body: some View {
        let shown = scrubbing ?? Double(audio.currentSecond)
        return HStack(spacing: 8) {
            Button(audio.isPlaying ? "Pause" : "Play", systemImage: audio.isPlaying ? "pause.fill" : "play.fill") {
                audio.toggle()
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .buttonStyle(.plain)
            .frame(width: 36, height: 36)
            if placement != .inline {
                Text(MediaClock.short(Int(shown)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { shown },
                    set: { scrubbing = $0 }
                ),
                in: 0...Double(max(audio.duration, 1)),
                onEditingChanged: { editing in
                    guard !editing, let value = scrubbing else { return }
                    audio.seek(to: Int(value), play: audio.isPlaying)
                    scrubbing = nil
                }
            )
            // Starts again with every move of the thumb. It runs out only when the thumb rests.
            .task(id: scrubbing) {
                guard let value = scrubbing else { return }
                do {
                    try await Task.sleep(for: .milliseconds(350))
                } catch {
                    // The thumb moved again, or the lift already asked the player.
                    return
                }
                audio.seek(to: Int(value), play: audio.isPlaying)
                scrubbing = nil
            }
            if placement != .inline {
                Text(MediaClock.short(audio.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            // Right of the scrubber: same Picker-in-Menu pattern as the term menu on Home.
            // No picker title: "Playback speed" / "Oynatma hızı" was wider than "1.5×" and left empty room.
            Menu {
                Picker(selection: rateSelection) {
                    ForEach(LectureAudio.rateSteps, id: \.self) { step in
                        Text(Self.rateLabel(step)).tag(step)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
                .labelsHidden()
                // Selected row uses primary instead of the accent blue of a menu picker.
                .tint(.primary)
            } label: {
                Text(Self.rateLabel(audio.rate))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 36)
            }
            .tint(.primary)
            .accessibilityLabel(Text("Playback speed"))
            .accessibilityValue(Text(Self.rateLabel(audio.rate)))
        }
        .padding(.horizontal, 12)
    }

    /// Bridges the menu picker to `LectureAudio.setRate`.
    private var rateSelection: Binding<Float> {
        Binding(
            get: { audio.rate },
            set: { audio.setRate($0) }
        )
    }

    /// Compact label for the speed control, always with a multiply sign.
    private static func rateLabel(_ rate: Float) -> String {
        switch rate {
        case 0.5: return "0.5×"
        case 1.5: return "1.5×"
        case 2: return "2×"
        default: return "1×"
        }
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
