import SwiftUI

/// The progress of a lecture that is being processed: a system ring with Liquid Glass, the step
/// name in the middle, and what the app does under it.
struct ProcessingCircle: View {
    var step: PipelineActivity.Step
    /// The student cancelled. The step that runs has to end before the work stops.
    var isStopping = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Two empty halves of the same size, one above the ring and one below it, keep the ring in the
        // middle of the page. The explanation is drawn on top of the lower half, starting 24 pt under
        // the ring. It does not take part in the layout, so its height (it changes with every step)
        // cannot move the ring.
        VStack(spacing: 0) {
            Color.clear
            GlassEffectContainer(spacing: 16) {
                ZStack {
                    // The ring only moves when a step ends. This arc keeps turning, so a long step
                    // (the model starting) still shows that the app works. It says nothing about how far.
                    if !reduceMotion {
                        TimelineView(.animation) { context in
                            let turn = context.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: 1.8) / 1.8
                            Circle()
                                .trim(from: 0, to: 0.18)
                                .stroke(
                                    Color.accentColor.opacity(0.6),
                                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                                )
                                .rotationEffect(.degrees(turn * 360))
                        }
                        .frame(width: 200, height: 200)
                        .accessibilityHidden(true)
                    }
                    Gauge(value: min(max(step.fraction, 0), 1)) { EmptyView() }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(Color.accentColor)
                        .scaleEffect(3)
                        .frame(width: 180, height: 180)
                    Text(isStopping ? String(localized: "Cancelling…") : step.title)
                        .appFont(.subheadline, weight: .semibold)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 44)
                }
                .frame(width: 220, height: 220)
                .glassEffect(.regular, in: .circle)
            }
            Color.clear
                .overlay(alignment: .top) {
                    let info = isStopping
                        ? String(localized: "The step that is running has to end first. Then the work stops.")
                        : step.info
                    if !info.isEmpty {
                        Text(info)
                            .appFont(.footnote)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .padding(16)
                            .glassEffect(.regular, in: .rect(cornerRadius: 20))
                            .padding(.top, 24)
                    }
                }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(step.fraction, format: .percent.precision(.fractionLength(0))))
    }
}
