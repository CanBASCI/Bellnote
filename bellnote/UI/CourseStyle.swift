import SwiftData
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

    /// Tints of the three count tiles on the course page: #3B5FDB, #2EC98A, #F0A0B5.
    static let recordingsTint = Color(red: 59 / 255, green: 95 / 255, blue: 219 / 255)
    static let assignmentsTint = Color(red: 46 / 255, green: 201 / 255, blue: 138 / 255)
    static let examsTint = Color(red: 240 / 255, green: 160 / 255, blue: 181 / 255)

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

extension View {
    /// The swipe from the right that only asks. `onDelete` takes the row out of the list the moment the
    /// student swipes, before the confirm. This button leaves the row where it is until the confirm says yes.
    func askToDeleteSwipe(_ ask: @escaping () -> Void) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(action: ask) {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
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

/// Asks before an assignment that the list's own delete swipe picked is removed.
private struct AssignmentDeleteDialog: ViewModifier {
    @Binding var pending: Assignment?
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content.alert(
            "Delete this assignment?",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let assignment = pending { modelContext.delete(assignment) }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("It is removed from the list. The recording stays. A new run of the recording can add it again.")
        }
    }
}

extension View {
    func confirmAssignmentDelete(_ pending: Binding<Assignment?>) -> some View {
        modifier(AssignmentDeleteDialog(pending: pending))
    }
}

/// A recording and the second to play from, used to open a lecture from a task.
struct AssignmentTarget: Hashable {
    var lecture: Lecture
    var second: Int
}

/// One homework row. Tapping the circle marks it done.
struct AssignmentRow: View {
    @Bindable var assignment: Assignment
    /// Called with the second where the lecturer gave the task. Nil makes the row plain.
    var onOpen: ((Int) -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                assignment.done.toggle()
            } label: {
                Image(
                    systemName: assignment.cancelled
                        ? "xmark.circle"
                        : (assignment.done ? "checkmark.circle.fill" : "circle")
                )
                .font(.title3)
                .foregroundStyle(assignment.done && !assignment.cancelled ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(assignment.cancelled)
            .accessibilityLabel(Text("Done"))
            .accessibilityAddTraits(assignment.done ? .isSelected : [])
            if let onOpen {
                Button { onOpen(assignment.sourceSecond) } label: { details }
                    .buttonStyle(.plain)
            } else {
                details
            }
        }
        .onAppear { assignment.fillDueIfMissing() }
        // Delete is the list's own swipe from the right. Cancelled is the swipe from the left.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(
                assignment.cancelled ? "Restore" : "Cancelled",
                systemImage: assignment.cancelled ? "arrow.uturn.backward" : "xmark.circle"
            ) {
                assignment.cancelled.toggle()
            }
            .tint(.orange)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(assignment.text)
                .strikethrough(assignment.done || assignment.cancelled)
                .foregroundStyle(assignment.done || assignment.cancelled ? .secondary : .primary)
                .multilineTextAlignment(.leading)
            if assignment.cancelled {
                StatusChip(title: String(localized: "Cancelled"), tint: .orange)
            } else if let due = assignment.due {
                StatusChip(title: AssignmentRow.dueTitle(due), tint: .accentColor)
            } else {
                Text("No date was spoken.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let lecture = assignment.sourceLecture {
                Label {
                    Text(verbatim: "\(lecture.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(MediaClock.short(assignment.sourceSecond))")
                } icon: {
                    Image(systemName: "play.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The time shows only when it is known, as for "next week" at the slot hour.
    static func dueTitle(_ due: Date) -> String {
        let atMidnight = Calendar.current.startOfDay(for: due) == due
        return due.formatted(date: .abbreviated, time: atMidnight ? .omitted : .shortened)
    }
}
