import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Must match `RecordingAttributes` in the app target (same fields, same Codable shape).
struct RecordingAttributes: ActivityAttributes {
    var courseName: String

    struct ContentState: Codable, Hashable {
        var isPaused: Bool
        var elapsedSeconds: Int
        var timingAnchor: Date
        var flagCount: Int
    }
}

struct liveactivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { context in
            lockScreen(context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedLabel(context.state, width: 56, font: .body.monospacedDigit().weight(.semibold))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.courseName)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(statusLine(context.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 160)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    controlRow(
                        isPaused: context.state.isPaused,
                        flagCount: context.state.flagCount,
                        flexible: false
                    )
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
            } compactTrailing: {
                // Narrow timer so the compact Island stays snug to the sensor.
                elapsedLabel(context.state, width: 40, font: .caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
            }
            .keylineTint(.red)
        }
    }

    @ViewBuilder
    private func lockScreen(_ context: ActivityViewContext<RecordingAttributes>) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
                    .font(.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.courseName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(statusLine(context.state))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                elapsedLabel(context.state, width: 72, font: .title2.monospacedDigit().weight(.semibold))
            }
            controlRow(
                isPaused: context.state.isPaused,
                flagCount: context.state.flagCount,
                flexible: true
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .activityBackgroundTint(Color.black.opacity(0.35))
    }

    private func statusLine(_ state: RecordingAttributes.ContentState) -> String {
        state.isPaused ? String(localized: "Paused") : String(localized: "Recording")
    }

    private func flagCountLabel(_ count: Int) -> String {
        String(localized: "\(count) flags")
    }

    /// Plain `Label` controls. Lock Screen spreads them; Island keeps intrinsic width with wider gaps.
    @ViewBuilder
    private func controlRow(isPaused: Bool, flagCount: Int, flexible: Bool) -> some View {
        HStack(spacing: flexible ? 12 : 44) {
            if isPaused {
                Button(intent: ResumeRecordingIntent()) {
                    Label("Resume", systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: flexible ? .infinity : nil)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            } else {
                Button(intent: PauseRecordingIntent()) {
                    Label("Pause", systemImage: "pause.fill")
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: flexible ? .infinity : nil)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            Button(intent: FlagRecordingIntent()) {
                HStack(spacing: 6) {
                    Label("I didn't get this", systemImage: "flag.fill")
                        .labelStyle(.iconOnly)
                    if flagCount > 0 {
                        Text(flagCountLabel(flagCount))
                            .font(.subheadline.monospacedDigit())
                    }
                }
                .frame(maxWidth: flexible ? .infinity : nil)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            Button(intent: StopRecordingIntent()) {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
                    .frame(maxWidth: flexible ? .infinity : nil)
                    .padding(.vertical, 8)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }

    /// One timer view for run and pause; fixed width so digits do not shove the Island.
    @ViewBuilder
    private func elapsedLabel(_ state: RecordingAttributes.ContentState, width: CGFloat, font: Font) -> some View {
        let pauseTime = state.isPaused
            ? state.timingAnchor.addingTimeInterval(TimeInterval(state.elapsedSeconds))
            : nil
        Text(
            timerInterval: state.timingAnchor...Date.distantFuture,
            pauseTime: pauseTime,
            countsDown: false,
            showsHours: false
        )
        .font(font)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .frame(width: width, alignment: .trailing)
    }
}

#Preview("Lock screen", as: .content, using: RecordingAttributes(courseName: "Felsefe")) {
    liveactivityLiveActivity()
} contentStates: {
    RecordingAttributes.ContentState(isPaused: false, elapsedSeconds: 125, timingAnchor: Date().addingTimeInterval(-125), flagCount: 0)
    RecordingAttributes.ContentState(isPaused: true, elapsedSeconds: 125, timingAnchor: Date().addingTimeInterval(-125), flagCount: 2)
}
