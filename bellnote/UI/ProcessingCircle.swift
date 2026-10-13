import SwiftUI

/// The progress of a lecture that is being processed: a system ring with Liquid Glass, the step
/// name in the middle, and what the app does under it.
struct ProcessingCircle: View {
    var step: PipelineActivity.Step

    var body: some View {
        VStack(spacing: 24) {
            GlassEffectContainer(spacing: 16) {
                ZStack {
                    Gauge(value: min(max(step.fraction, 0), 1)) { EmptyView() }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(Color.accentColor)
                        .scaleEffect(3)
                        .frame(width: 180, height: 180)
                    Text(step.title)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 44)
                }
                .frame(width: 220, height: 220)
                .glassEffect(.regular, in: .circle)
            }
            if !step.info.isEmpty {
                Text(step.info)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .padding(16)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(step.fraction, format: .percent.precision(.fractionLength(0))))
    }
}
