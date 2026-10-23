import SwiftData
import SwiftUI

/// Small shared pieces of the Bellnote look. Status colors are semantic, so they follow light and dark mode and
/// Increase Contrast by themselves. The course palette is a fixed set of muted colors.
enum CourseStyle {
    /// Twelve muted, modern colors for the courses, in the same style as the titles of the tiles on the course page.
    /// None is loud. Each one is dark enough for white text (the date cover) and light enough to show on dark mode.
    /// The hues are spread out, so two courses next to each other rarely look alike.
    private static let palette: [Color] = [
        rgb(79, 111, 181),   // soft blue        #4F6FB5
        rgb(63, 156, 140),   // sage teal        #3F9C8C
        rgb(194, 112, 138),  // dusty rose       #C2708A
        rgb(108, 107, 184),  // periwinkle       #6C6BB8
        rgb(196, 122, 87),   // terracotta       #C47A57
        rgb(169, 130, 47),   // ochre            #A9822F
        rgb(111, 143, 68),   // olive            #6F8F44
        rgb(142, 95, 158),   // plum             #8E5F9E
        rgb(63, 129, 153),   // steel cyan       #3F8199
        rgb(143, 109, 87),   // clay brown       #8F6D57
        rgb(194, 91, 83),    // soft coral       #C25B53
        rgb(95, 112, 136)    // slate            #5F7088
    ]

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red / 255, green: green / 255, blue: blue / 255)
    }

    static var paletteCount: Int { palette.count }

    /// The color at a place of the palette. A place past the end wraps around. A negative place (a course that has
    /// no color yet) falls back to a color from the name, so the course still has one until it gets its own.
    static func color(at index: Int, fallbackName name: String) -> Color {
        guard index >= 0 else { return color(for: name) }
        return palette[index % palette.count]
    }

    /// The same course always gets the same color. Only the fallback for a course with no stored color. `hashValue` is random per launch, so it is not used.
    static func color(for name: String) -> Color {
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }

    /// Colors of the titles of the three count tiles on the course page. Muted on purpose, not loud: a soft blue
    /// (#4F6FB5), a sage teal (#3F9C8C) and a dusty rose (#C2708A). They read on both light and dark glass.
    static let recordingsTint = rgb(79, 111, 181)
    static let assignmentsTint = rgb(63, 156, 140)
    static let examsTint = rgb(194, 112, 138)

    /// The star of a favourite course: a soft amber (#D4A34A), in the same muted range as the course colors. The
    /// system yellow is much brighter than they are.
    static let favoriteTint = rgb(212, 163, 74)

    static func initial(of name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }
}

extension Course {
    /// The color of the course, from its place in the palette.
    var color: Color {
        CourseStyle.color(at: colorIndex, fallbackName: name)
    }
}

extension Term {
    /// The place in the palette for a new course: the color the courses of this term use the least, and of those the
    /// first. So with up to twelve courses no color repeats. Past twelve, the colors start over in the same order.
    /// A new term has no courses, so its colors start from the beginning. Colors of other terms do not count.
    func nextCourseColorIndex() -> Int {
        let count = CourseStyle.paletteCount
        guard count > 0 else { return 0 }
        var uses = Array(repeating: 0, count: count)
        for course in courses where course.colorIndex >= 0 {
            uses[course.colorIndex % count] += 1
        }
        let fewest = uses.min() ?? 0
        return uses.firstIndex(of: fewest) ?? 0
    }

    /// Gives a color to the courses that have none yet (made before the color was stored), oldest first.
    func fillMissingCourseColors() {
        for course in courses.sorted(by: { $0.createdAt < $1.createdAt }) where course.colorIndex < 0 {
            course.colorIndex = nextCourseColorIndex()
        }
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
                Image(systemName: "trash")
            }
            .tint(.red)
            .accessibilityLabel(Text("Delete"))
        }
    }
}

/// A rounded square with the course initial.
struct CourseBadge: View {
    var name: String
    var color: Color
    var size: CGFloat = 40

    var body: some View {
        Text(CourseStyle.initial(of: name))
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The day of a recording as a small square, where Apple Music shows the cover of a song.
/// It is a flat rounded square in the colour of the course, with the month on top and the day number under it.
/// It has no glass. Glass is for the controls that float above the content, not for the rows of a list.
struct DateCover: View {
    var date: Date
    var color: Color
    var size: CGFloat = 48
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated).locale(locale)).localizedUppercase)
                .font(.system(size: size * 0.22, weight: .semibold, design: .rounded))
            Text(date.formatted(.dateTime.day().locale(locale)))
                .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
        }
        // White on the colour of the course, so it reads in light and dark mode.
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(color, in: .rect(cornerRadius: size * 0.2, style: .continuous))
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
            .appFont(.caption, weight: .semibold)
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
    /// The task text in `subheadline`, medium, like the time of a recording row. False keeps the body font.
    var smallTitle = false
    /// Called with the second where the lecturer gave the task. Nil makes the row plain.
    var onOpen: ((Int) -> Void)?

    /// The height of one line of the task text (`body`). Without a column width the circle is centered in
    /// a box of this height at the top of the row, so it sits in the middle of the first line. Aligning on the
    /// text baseline put it a little too high, because the circle is bigger than the text.
    @ScaledMetric(relativeTo: .body) private var bodyLineHeight: CGFloat = 22
    /// The same for the course page, where the task text is `subheadline`.
    @ScaledMetric(relativeTo: .subheadline) private var subheadlineLineHeight: CGFloat = 20

    var body: some View {
        // The circle is centered on the first line of the text, in the lecture page and in the course page.
        HStack(alignment: .top, spacing: markGap) {
            Button {
                assignment.done.toggle()
            } label: {
                // The same plain circle everywhere, no glass. With a column width the circle is centered in
                // that width, so on the course page it sits where the date covers sit.
                Image(
                    systemName: assignment.cancelled
                        ? "xmark.circle"
                        : (assignment.done ? "checkmark.circle.fill" : "circle")
                )
                .appFont(.title3)
                .foregroundStyle(assignment.done && !assignment.cancelled ? Color.green : Color.secondary)
                .frame(height: smallTitle ? subheadlineLineHeight : bodyLineHeight)
                .frame(width: markWidth)
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
                .appFont(smallTitle ? .subheadline : .body, weight: smallTitle ? .medium : nil)
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
                    .appFont(plainDetails ? .subheadline : .caption)
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
                .appFont(plainDetails ? .subheadline : .caption)
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
