import SwiftUI

/// Small shared pieces of the Bellnote look. Only semantic colors are used,
/// so every piece follows light and dark mode and Increase Contrast by itself.
enum CourseStyle {
    private static let palette: [Color] = [.indigo, .teal, .orange, .pink, .green, .blue, .purple, .mint]

    /// The same course always gets the same color. `hashValue` is random per launch, so it is not used.
    static func color(for name: String) -> Color {
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }

    static func initial(of name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }
}

extension LectureState {
    var tint: Color {
        switch self {
        case .recording, .failed: .red
        case .paused: .gray
        case .processing: .orange
        case .ready: .green
        }
    }
}

extension Lecture {
    /// A recording that was stopped and not processed yet is stored as `paused`.
    /// The student sees that as "Recorded", not "Paused".
    var isRecordedOnly: Bool {
        state == LectureState.paused.rawValue
            && audioRelativePath != nil
            && stage == PipelineStage.idle.rawValue
    }

    var statusTitle: String {
        if isRecordedOnly { return String(localized: "Recorded") }
        return LectureState(rawValue: state)?.title ?? state
    }

    var statusTint: Color {
        if isRecordedOnly { return .blue }
        return LectureState(rawValue: state)?.tint ?? .gray
    }
}

/// A rounded square with the course initial.
struct CourseBadge: View {
    var name: String
    var size: CGFloat = 40

    var body: some View {
        Text(CourseStyle.initial(of: name))
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(CourseStyle.color(for: name).gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A small tinted label such as "Ready" or "Friday".
struct StatusChip: View {
    var title: String
    var tint: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// One homework row. Tapping the circle marks it done.
struct AssignmentRow: View {
    @Bindable var assignment: Assignment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                assignment.done.toggle()
            } label: {
                Image(systemName: assignment.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(assignment.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Done"))
            .accessibilityAddTraits(assignment.done ? .isSelected : [])
            VStack(alignment: .leading, spacing: 4) {
                Text(assignment.text)
                    .strikethrough(assignment.done)
                    .foregroundStyle(assignment.done ? .secondary : .primary)
                if let due = assignment.due {
                    StatusChip(title: due.formatted(date: .abbreviated, time: .omitted), tint: .accentColor)
                } else {
                    Text("No date was spoken.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
