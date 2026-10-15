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

    var symbol: String {
        switch self {
        case .recording: "circle.fill"
        case .paused: "pause"
        case .processing: "circle.dotted"
        case .ready: "checkmark"
        case .failed: "exclamationmark"
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

    var statusSymbol: String {
        if isRecordedOnly { return "waveform" }
        return LectureState(rawValue: state)?.symbol ?? "questionmark.circle"
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

/// The day of a recording as a small square, where Apple Music shows the cover of a song.
/// It is Liquid Glass in the colour of the course, with the month on top and the day number under it.
struct DateCover: View {
    var date: Date
    var courseName: String
    var size: CGFloat = 48
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated).locale(locale)).localizedUppercase)
                .font(.system(size: size * 0.22, weight: .semibold, design: .rounded))
            Text(date.formatted(.dateTime.day().locale(locale)))
                .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.primary)
        .frame(width: size, height: size)
        // Liquid Glass tinted with the colour of the course, with the same tint strength as the tiles on the course page.
        .glassEffect(
            .regular.tint(CourseStyle.color(for: courseName).opacity(colorScheme == .dark ? 0.5 : 0.28)),
            in: .rect(cornerRadius: size * 0.2)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: date.formatted(.dateTime.day().month(.wide).locale(locale))))
    }
}

/// A small Liquid Glass circle with a symbol, tinted with a status colour like the date cover.
/// Without a symbol it is an empty circle. Without a tint it is plain glass.
struct GlassBadge: View {
    var systemName: String?
    var tint: Color?
    /// The width and height of the circle. Nil takes a size that follows the text size.
    var side: CGFloat?
    @ScaledMetric(relativeTo: .subheadline) private var defaultSide: CGFloat = 24
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let diameter = side ?? defaultSide
        Group {
            if let systemName {
                // The symbol follows the circle, so a smaller circle keeps the same look.
                Image(systemName: systemName)
                    .font(.system(size: diameter * 0.5, weight: .bold))
            } else {
                Color.clear
            }
        }
        .foregroundStyle(.primary)
        .frame(width: diameter, height: diameter)
        .glassEffect(glass, in: .circle)
    }

    private var glass: Glass {
        guard let tint else { return .regular }
        return .regular.tint(tint.opacity(colorScheme == .dark ? 0.5 : 0.28))
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

/// One homework row. Tapping the circle marks it done.
struct AssignmentRow: View {
    @Bindable var assignment: Assignment
    /// The width the circle is centered in. Nil keeps the width of the circle itself.
    /// The course page gives it the width of a date cover, so the circle sits where the cover sits.
    var markWidth: CGFloat?
    /// The space between the circle and the text.
    var markGap: CGFloat = 12
    /// The lines under the task in the font of the summary line of a recording row, not in the caption font.
    /// The date and "Cancelled" stay a chip.
    var plainDetails = false
    /// Called with the second where the lecturer gave the task. Nil makes the row plain.
    var onOpen: ((Int) -> Void)?

    var body: some View {
        // With a column width the circle is like a cover, so it is centered on the height of the row.
        // Without it the circle sits on the first line of the text.
        HStack(alignment: markWidth == nil ? .firstTextBaseline : .center, spacing: markGap) {
            Button {
                assignment.done.toggle()
            } label: {
                if markWidth == nil {
                    Image(
                        systemName: assignment.cancelled
                            ? "xmark.circle"
                            : (assignment.done ? "checkmark.circle.fill" : "circle")
                    )
                    .font(.title3)
                    .foregroundStyle(assignment.done && !assignment.cancelled ? Color.green : Color.secondary)
                } else {
                    // In the course page the circle is a glass circle like the date covers: an empty one, a green
                    // one with a check when done, a plain one with a cross when cancelled.
                    GlassBadge(
                        systemName: assignment.cancelled ? "xmark" : (assignment.done ? "checkmark" : nil),
                        tint: assignment.done && !assignment.cancelled ? .green : nil
                    )
                    .frame(width: markWidth)
                }
            }
            .buttonStyle(.plain)
            .disabled(assignment.cancelled)
            .accessibilityLabel(Text("Done"))
            .accessibilityAddTraits(assignment.done ? .isSelected : [])
            // The separator of the row starts at the task text, not under the circle. The list would pick the
            // first text it finds, which is a different place in a row with the play line.
            if let onOpen {
                Button { onOpen(assignment.sourceSecond) } label: { details }
                    .buttonStyle(.plain)
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            } else {
                details
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
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
            // The lines under the task. On the course page they have the size of the summary and the length of a
            // recording row: `subheadline` at the medium Dynamic Type size.
            Group {
            if assignment.cancelled {
                StatusChip(title: String(localized: "Cancelled"), tint: .orange)
            } else if let due = assignment.due {
                StatusChip(title: AssignmentRow.dueTitle(due), tint: .accentColor)
            } else {
                Text("No date was spoken.")
                    .font(plainDetails ? .subheadline : .caption)
                    .foregroundStyle(.secondary)
            }
            if let lecture = assignment.sourceLecture {
                let source = "\(lecture.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(MediaClock.short(assignment.sourceSecond))"
                Group {
                    if plainDetails {
                        // A label puts a wide space of its own between the icon and the text. The dot is the same
                        // one that stands between the date and the time in the text.
                        HStack(spacing: 0) {
                            Image(systemName: "play.circle")
                            Text(verbatim: " · ")
                            Text(verbatim: source)
                        }
                    } else {
                        Label {
                            Text(verbatim: source)
                        } icon: {
                            Image(systemName: "play.circle")
                        }
                    }
                }
                .font(plainDetails ? .subheadline : .caption)
                .foregroundStyle(.secondary)
            }
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
