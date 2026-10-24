import OSLog
import SwiftData
import SwiftUI
import UIKit

/// Ask → Source hand-off from the Assistant tab: recording plus the Raw block, or one assignment on that recording.
private struct TalkSourceJump: Identifiable, Hashable {
    var id: String
    var lecture: Lecture
    var blockToken: UUID?
    var second: Int
    /// Set when the source is an assignment of this recording. Then the Assignments picker opens on that row.
    var focusAssignmentID: PersistentIdentifier?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Timetable Source hand-off: open the program on that weekday.
private struct TalkTimetableJump: Identifiable, Hashable {
    var id: String { "\(weekday)-\(startMinutes)" }
    var term: Term
    var weekday: Int
    var startMinutes: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.term.persistentModelID == rhs.term.persistentModelID
            && lhs.weekday == rhs.weekday
            && lhs.startMinutes == rhs.startMinutes
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(term.persistentModelID)
        hasher.combine(weekday)
        hasher.combine(startMinutes)
    }
}

/// Catalogue Source hand-off: open the course on the week that owns the row.
private struct TalkCourseJump: Identifiable, Hashable {
    var id: String
    var course: Course
    var weekStart: Date?
    var focus: CoursePage.Focus?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Assistant tab: live voice assistant over every ready lecture, session memory only.
/// Stays off while any recording is processed so the pipeline keeps the model and memory.
struct AssistantPage: View {
    private static let log = Logger(subsystem: "app.bellnote", category: "talk")

    @Query(sort: \Term.createdAt) private var terms: [Term]
    @Environment(AppSession.self) private var session
    @Environment(\.modelContext) private var modelContext
    @State private var talk = TalkSession()
    @State private var sourceJump: TalkSourceJump?
    @State private var timetableJump: TalkTimetableJump?
    @State private var courseJump: TalkCourseJump?
    @State private var sourceMenu: [TalkSourceItem] = []
    @State private var showSourceMenu = false
    private var processingBusy: Bool { PipelineActivity.shared.isBusy }

    var body: some View {
        Group {
            if processingBusy {
                ContentUnavailableView {
                    Label("Assistant", systemImage: "waveform.and.mic")
                } description: {
                    Text("Assistant pauses while a recording is processed.")
                }
            } else {
                talkBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $sourceJump) { jump in
            LecturePage(
                lecture: jump.lecture,
                startSecond: jump.blockToken == nil ? nil : jump.second,
                focusRawBlockToken: jump.focusAssignmentID == nil ? jump.blockToken : nil,
                focusAssignmentID: jump.focusAssignmentID
            )
        }
        .navigationDestination(item: $timetableJump) { jump in
            ProgramPage(term: jump.term, weekday: jump.weekday, focusMinutes: jump.startMinutes)
        }
        .navigationDestination(item: $courseJump) { jump in
            CoursePage(course: jump.course, weekStart: jump.weekStart, focus: jump.focus)
        }
        .onAppear {
            Self.log.info("Assistant appear busy=\(self.processingBusy) terms=\(self.terms.count) phase=\(String(describing: self.talk.phase), privacy: .public)")
            syncTalk()
        }
        .onDisappear {
            Self.log.info("Assistant disappear phase=\(String(describing: self.talk.phase), privacy: .public)")
            talk.stop()
        }
        .onChange(of: processingBusy) { _, busy in
            Self.log.info("Assistant processingBusy=\(busy)")
            syncTalk()
        }
        .onChange(of: terms.count) { _, count in
            Self.log.info("Assistant terms count=\(count)")
            syncTalk()
        }
        // Source push stops Talk; lecture playback releases the session asynchronously.
        // Restart after the pop so the mic is not opened on a dead audio graph.
        .onChange(of: sourceJump) { previous, jump in
            guard previous != nil, jump == nil else { return }
            resumeTalkAfterSource()
        }
        .onChange(of: timetableJump) { previous, jump in
            guard previous != nil, jump == nil else { return }
            resumeTalkAfterSource()
        }
        .onChange(of: courseJump) { previous, jump in
            guard previous != nil, jump == nil else { return }
            resumeTalkAfterSource()
        }
    }

    private func resumeTalkAfterSource() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            Self.log.info("Assistant resume after Source")
            syncTalk()
        }
    }

    private var talkBody: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let maxCardWidth = max(geo.size.width - 40, 1)
            let statusHeight = UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
            let orbSide: CGFloat = 280
            let statusGap: CGFloat = 8
            let statusBlock = orbSide + statusGap + statusHeight
            let gap: CGFloat = 12
            let centeredTop = max(0, (height - statusBlock) / 2)
            let questionCap = max(centeredTop - gap, statusHeight)
            TalkStageLayout(gap: gap, statusBlock: statusBlock, questionCap: questionCap) {
                if let past = pastLine {
                    ViewThatFits(in: .vertical) {
                        Text(verbatim: past)
                            .appFont(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            Text(verbatim: past)
                                .appFont(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxHeight: questionCap)
                        .scrollBounceBehavior(.basedOnSize)
                    }
                    .frame(maxWidth: .infinity, maxHeight: questionCap, alignment: .top)
                    .padding(.horizontal, 28)
                    .padding(.top, 4)
                } else {
                    Color.clear.frame(height: 0)
                }
                VStack(spacing: statusGap) {
                    AssistantVoiceOrb(phase: talk.phase, hearing: hearingSpeech)
                        .frame(width: orbSide, height: orbSide)
                    Text(verbatim: orbStatusLine)
                        .appFont(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .animation(.easeInOut(duration: 0.2), value: orbStatusLine)
                }
                .frame(maxWidth: .infinity)
                if let card = turnCardContent {
                    talkTurnCard(card, maxWidth: maxCardWidth, maxHeight: height)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                } else {
                    Color.clear.frame(height: 0)
                }
            }
            .animation(.easeOut(duration: 0.22), value: turnCardContent?.body)
        }
    }

    /// You / Bellnote leading, Source at the card’s trailing edge, both outside the fill.
    /// The fill hugs short text; Source does not follow that width.
    /// The card grows with the text up to `maxHeight` (the orb has met the question), then the body scrolls.
    @ViewBuilder
    private func talkTurnCard(
        _ card: (title: String, body: String, showSource: Bool, followTail: Bool),
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> some View {
        let bodyMax = max(maxWidth - 28, 1)
        TalkTurnColumn(spacing: 8, maxWidth: maxWidth, maxHeight: maxHeight) {
            HStack(alignment: .center, spacing: 8) {
                Text(card.title)
                    .appFont(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if card.showSource {
                    Button("Source", systemImage: "text.quote") {
                        openSource()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .confirmationDialog("Source", isPresented: $showSourceMenu, titleVisibility: .visible) {
                        ForEach(sourceMenu) { item in
                            Button(item.title) {
                                openSourceItem(item)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            TalkBubble(
                text: card.body,
                maxTextWidth: bodyMax,
                followTail: card.followTail
            )
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .animation(.easeOut(duration: 0.12), value: card.body)
    }

    /// Orb caption always follows phase so Thinking never shows Listening (or the reverse).
    private var orbStatusLine: String {
        switch talk.phase {
        case .preparing: return String(localized: "Preparing…")
        case .listening: return String(localized: "Listening…")
        case .thinking: return String(localized: "Thinking…")
        case .speaking: return String(localized: "Speaking…")
        default: return talk.statusLine
        }
    }

    /// True while Listening and live words are already on the You card.
    private var hearingSpeech: Bool {
        guard talk.phase == .listening else { return false }
        return !talk.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The question that left the bottom bubble when Bellnote’s reply took its place.
    /// It stays only while that reply is still the bottom card. A new question clears it;
    /// the new question appears here only after Bellnote answers. Bellnote’s own text never moves up.
    private var pastLine: String? {
        if talk.phase == .speaking,
           talk.turns.last?.role == .assistant
        {
            // Reply still owns the bottom. Keep the question that produced it.
        } else {
            let live = talk.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !live.isEmpty { return nil }
            if talk.turns.last?.role == .user { return nil }
        }
        let turns = talk.turns
        guard let answerIndex = turns.lastIndex(where: { $0.role == .assistant }) else { return nil }
        return turns[..<answerIndex].last { $0.role == .user }?.text
    }

    /// Partial speech fills the same “You” card that later holds the final line.
    /// While Speaking, keep the Bellnote reply — barge ASR often echoes TTS into partialTranscript
    /// and would shrink the card to the first echoed line until playback ends.
    private var turnCardContent: (title: String, body: String, showSource: Bool, followTail: Bool)? {
        if talk.phase == .speaking,
           let latest = talk.turns.last,
           latest.role == .assistant
        {
            return (
                String(localized: "Bellnote"),
                latest.text,
                !latest.sources.isEmpty,
                false
            )
        }
        let live = talk.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty {
            // Live speech follows the newest line. The question stays on this card until the reply replaces it.
            return (String(localized: "You"), live, false, true)
        }
        guard let latest = talk.turns.last else { return nil }
        let title = latest.role == .user ? String(localized: "You") : String(localized: "Bellnote")
        let showSource = latest.role == .assistant && !latest.sources.isEmpty
        return (title, latest.text, showSource, false)
    }

    /// One source opens directly; several open a pick menu (same idea as Ask, with a list).
    private func openSource() {
        guard let latest = talk.turns.last, latest.role == .assistant else { return }
        let sources = latest.sources
        guard !sources.isEmpty else { return }
        Self.log.info("Talk source menu open count=\(sources.count)")
        for (index, item) in sources.enumerated() {
            Self.log.info(
                "Talk sourceMenuTap[\(index)] title=\(item.title, privacy: .public) target=\(String(describing: item.target), privacy: .public)"
            )
        }
        if sources.count == 1 {
            openSourceItem(sources[0])
            return
        }
        sourceMenu = sources
        showSourceMenu = true
    }

    private func openSourceItem(_ item: TalkSourceItem) {
        switch item.target {
        case .note(let blockID, let second):
            guard let host = lecture(owning: blockID) else {
                Self.log.error("Talk source lecture missing block=\(blockID.uuidString, privacy: .public)")
                return
            }
            Self.log.info("Talk source open note second=\(second) lecture=\(host.title, privacy: .public)")
            talk.stop()
            sourceJump = TalkSourceJump(
                id: blockID.uuidString,
                lecture: host,
                blockToken: blockID,
                second: second,
                focusAssignmentID: nil
            )
        case .timetable(let termID, let weekday, let startMinutes):
            guard let term = terms.first(where: { $0.persistentModelID == termID }) else {
                Self.log.error("Talk source term missing")
                return
            }
            Self.log.info("Talk source open timetable weekday=\(weekday) startMinutes=\(startMinutes)")
            talk.stop()
            timetableJump = TalkTimetableJump(term: term, weekday: weekday, startMinutes: startMinutes)
        case .assignment(let courseID, let assignmentID, let weekStart):
            guard let course = course(id: courseID),
                  let assignment = course.assignments.first(where: { $0.persistentModelID == assignmentID })
            else {
                Self.log.error("Talk source assignment missing")
                return
            }
            if let lecture = assignment.sourceLecture {
                Self.log.info("Talk source open assignment on recording second=\(assignment.sourceSecond)")
                talk.stop()
                sourceJump = TalkSourceJump(
                    id: "assignment-\(String(describing: assignmentID))",
                    lecture: lecture,
                    blockToken: assignment.sourceBlockID,
                    second: assignment.sourceSecond,
                    focusAssignmentID: assignmentID
                )
            } else {
                Self.log.info("Talk source open assignment week=\(weekStart.formatted(date: .abbreviated, time: .omitted), privacy: .public)")
                talk.stop()
                courseJump = TalkCourseJump(
                    id: "assignment-\(String(describing: assignmentID))",
                    course: course,
                    weekStart: weekStart,
                    focus: .assignment(assignmentID)
                )
            }
        case .exam(let courseID, let weekStart):
            guard let course = course(id: courseID) else {
                Self.log.error("Talk source course missing")
                return
            }
            Self.log.info("Talk source open exam")
            talk.stop()
            courseJump = TalkCourseJump(
                id: "exam-\(String(describing: courseID))-\(weekStart?.timeIntervalSince1970 ?? 0)",
                course: course,
                weekStart: weekStart,
                focus: nil
            )
        case .inventory(let courseID, let itemID):
            guard let course = course(id: courseID) else {
                Self.log.error("Talk source course missing")
                return
            }
            Self.log.info("Talk source open inventory")
            talk.stop()
            courseJump = TalkCourseJump(
                id: "inventory-\(String(describing: itemID))",
                course: course,
                weekStart: nil,
                focus: .inventory(itemID)
            )
        case .lecturer(let courseID):
            guard let course = course(id: courseID) else {
                Self.log.error("Talk source lecturer missing")
                return
            }
            Self.log.info("Talk source open lecturer")
            talk.stop()
            courseJump = TalkCourseJump(
                id: "lecturer-\(String(describing: courseID))",
                course: course,
                weekStart: nil,
                focus: .lecturer
            )
        case .recording(let lectureID):
            guard let lecture = lecture(id: lectureID) else {
                Self.log.error("Talk source recording missing")
                return
            }
            Self.log.info("Talk source open recording title=\(lecture.title, privacy: .public)")
            talk.stop()
            sourceJump = TalkSourceJump(
                id: "recording-\(String(describing: lectureID))",
                lecture: lecture,
                blockToken: nil,
                second: 0,
                focusAssignmentID: nil
            )
        }
    }

    private func lecture(id: PersistentIdentifier) -> Lecture? {
        for term in terms {
            for course in term.courses {
                if let lecture = course.lectures.first(where: { $0.persistentModelID == id }) {
                    return lecture
                }
            }
        }
        return nil
    }

    private func lecture(owning blockID: UUID) -> Lecture? {
        for term in terms {
            for course in term.courses {
                if let lecture = course.lectures.first(where: { item in
                    item.blocks.contains { $0.token == blockID }
                }) {
                    return lecture
                }
            }
        }
        return nil
    }

    private func course(id: PersistentIdentifier) -> Course? {
        modelContext.model(for: id) as? Course
    }

    private func syncTalk() {
        if processingBusy {
            Self.log.info("Assistant sync stop — pipeline busy")
            talk.stop()
            return
        }
        switch talk.phase {
        case .preparing, .thinking, .speaking:
            // Do not cut warm-up or a live reply for a term-list refresh.
            Self.log.info("Assistant sync skip phase=\(String(describing: self.talk.phase), privacy: .public)")
            return
        case .idle, .listening, .needsMicrophone, .needsModel, .needsVoice, .failed:
            Self.log.info("Assistant sync restart phase=\(String(describing: self.talk.phase), privacy: .public)")
            talk.stop()
            talk.start(terms: terms, session: session)
        }
    }
}

private struct TalkStageLayout: Layout {
    var gap: CGFloat
    var statusBlock: CGFloat
    /// The faded question may grow down to this, then it scrolls. It does not enter the orb's home.
    var questionCap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let width = bounds.width
        let height = bounds.height
        let centeredTop = max(0, (height - statusBlock) / 2)
        // Nil height is the text's own height. Proposing `questionCap` makes the flexible
        // question frame fill that cap, so the card never grows past the centered orb.
        let questionIdeal = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let questionHeight = min(max(questionIdeal.height, 0), questionCap)
        let questionLimit = questionHeight > 1 ? questionHeight + gap : 0
        let maxCard = max(height - gap - statusBlock - questionLimit, 1)
        let cardIdeal = subviews[2].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let cardHeight = min(max(cardIdeal.height, 0), maxCard)
        let aboveCardTop = height - cardHeight - gap - statusBlock
        // A short card leaves the orb centered. A taller reply lifts it until the question.
        let orbTop = max(questionLimit, min(centeredTop, aboveCardTop))
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: questionHeight)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + orbTop),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: statusBlock)
        )
        subviews[2].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + height - cardHeight),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: cardHeight)
        )
    }
}

/// Header spans the card width (title leading, Source at the trailing edge).
/// The bubble stays as wide as its text. Total height stops at `maxHeight`.
private struct TalkTurnColumn: Layout {
    var spacing: CGFloat
    var maxWidth: CGFloat
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count >= 2 else { return .zero }
        let limit = min(proposal.width ?? maxWidth, maxWidth)
        // The stage proposes the ceiling under the risen orb. A nil height keeps `maxHeight`.
        let limitH = min(maxHeight, proposal.height ?? maxHeight)
        // Nil height: the bubble reports the wrapped text. A short proposal would
        // make a scroller look like it fits and the card would never grow.
        let bubble = subviews[1].sizeThatFits(ProposedViewSize(width: limit, height: nil))
        // Full card width so Source stays at the trailing edge when the fill hugs a short line.
        let width = max(limit, 1)
        let header = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let height = min(header.height + spacing + max(bubble.height, 1), limitH)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }
        let header = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: header.height)
        )
        let bubbleCap = max(bounds.height - header.height - spacing, 1)
        let bubble = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let bubbleHeight = min(max(bubble.height, 1), bubbleCap)
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + header.height + spacing),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: min(bubble.width, bounds.width), height: bubbleHeight)
        )
    }
}

/// Reports the plain text’s height. The scroll copy is placed only when the slot
/// the stage gave the card is shorter than that text.
private struct TalkBubbleBox: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let width = proposal.width ?? text.sizeThatFits(.unspecified).width
        let measured = text.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let natural = max(measured.height, 1)
        // A nil height is the real text, so the card can rise. A shorter slot is the
        // cap under the question: report that, and the scroll copy fills it.
        let height = min(natural, proposal.height ?? natural)
        return CGSize(width: min(max(measured.width, 1), width), height: max(height, 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }
        let text = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let fits = text.height <= bounds.height + 1
        let parked = CGPoint(x: bounds.minX - 4_000, y: bounds.minY - 4_000)
        if fits {
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: nil)
            )
            subviews[1].place(
                at: parked,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: 0, height: 0)
            )
        } else {
            subviews[0].place(
                at: parked,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: 0, height: 0)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
            )
        }
    }
}

private enum TalkBubbleEnd {
    static let top = "talk-bubble-top"
    static let bottom = "talk-bubble-end"
}

/// One fill around the text. The scroll copy stays in the layout for a long reply,
/// but it has no fill of its own, so it cannot paint a second box in the corner.
private struct TalkBubble: View {
    var text: String
    var maxTextWidth: CGFloat
    var followTail: Bool

    var body: some View {
        TalkBubbleBox {
            // The unused copy is parked outside and clipped, so it cannot sit in the corner.
            words
            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 1).id(TalkBubbleEnd.top)
                    words.frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id(TalkBubbleEnd.bottom)
                }
                .id(followTail)
                .defaultScrollAnchor(followTail ? .bottom : .top)
                .defaultScrollAnchor(followTail ? .bottom : .top, for: .sizeChanges)
                .defaultScrollAnchor(.top, for: .alignment)
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.visible)
                .scrollContentBackground(.hidden)
                .onAppear {
                    proxy.scrollTo(
                        followTail ? TalkBubbleEnd.bottom : TalkBubbleEnd.top,
                        anchor: followTail ? .bottom : .top
                    )
                }
                .onChange(of: text) { _, _ in
                    guard followTail else { return }
                    proxy.scrollTo(TalkBubbleEnd.bottom, anchor: .bottom)
                }
            }
        }
        .clipped()
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: maxTextWidth + 28, alignment: .leading)
    }

    private var words: some View {
        Text(verbatim: text)
            .appFont(.callout)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: maxTextWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// VoiceOrbs-style Particles Orb — rotating 3D point cloud (sphere ↔ ring). No Pill / no text.
private struct AssistantVoiceOrb: View {
    var phase: TalkPhase
    /// Listening only: live transcript is on screen. Color and a pulse; resting shape stays.
    var hearing: Bool
    /// Kept across view rebuilds so sphere↔ring easing does not reset every frame.
    @State private var dynamics = OrbDynamics()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let blend = dynamics.tick(
                to: t,
                towardRing: ringTarget,
                towardWave: waveTarget,
                towardHelix: helixTarget,
                towardHear: hearTarget
            )
            let energy = energyAmount(at: t)
            let color = dotColor(hear: blend.hear, at: t)
            Canvas { context, size in
                drawParticles(
                    context: context,
                    size: size,
                    time: t,
                    ring: blend.ring,
                    wave: blend.wave,
                    helix: blend.helix,
                    hear: blend.hear,
                    energy: energy,
                    color: color
                )
            }
            .frame(width: 280, height: 280)
        }
        .accessibilityHidden(true)
    }

    /// Listening / thinking only — values match the first Particles Orb (do not retune).
    private var ringTarget: CGFloat {
        switch phase {
        case .thinking:
            return 1
        case .listening:
            return 0.08
        case .preparing:
            return 0
        case .needsMicrophone, .needsModel, .needsVoice, .failed:
            return 0.35
        case .speaking, .idle:
            return 0
        }
    }

    /// Speaking only — frequency ribbon. Listening/thinking never use this.
    private var waveTarget: CGFloat {
        phase == .speaking ? 1 : 0
    }

    /// Preparing only — double helix. Eases out into the sphere when listening starts.
    private var helixTarget: CGFloat {
        phase == .preparing ? 1 : 0
    }

    /// Listening only, and only while words are landing. Other phases stay on their own color.
    private var hearTarget: CGFloat {
        phase == .listening && hearing ? 1 : 0
    }

    /// Resting accent eases into violet → magenta → orange → amber while speech is live.
    private func dotColor(hear: CGFloat, at time: TimeInterval) -> Color {
        guard phase == .listening, hear > 0 else { return particleColor }
        // Hearing cycle kept as-is (restore with the phase palette below if needed).
        let stops: [(r: Double, g: Double, b: Double)] = [
            (0.68, 0.30, 1.0),
            (0.98, 0.32, 0.72),
            (1.0, 0.46, 0.16),
            (1.0, 0.84, 0.25),
        ]
        let span = time * 0.55
        let pos = span - Double(stops.count) * floor(span / Double(stops.count))
        let index = Int(pos) % stops.count
        let next = stops[(index + 1) % stops.count]
        let current = stops[index]
        let fraction = pos - Double(index)
        let live = (
            r: current.r + (next.r - current.r) * fraction,
            g: current.g + (next.g - current.g) * fraction,
            b: current.b + (next.b - current.b) * fraction
        )
        let t = Double(hear)
        let rest = Self.rgb(of: .primary)
        return Color(
            red: rest.r + (live.r - rest.r) * t,
            green: rest.g + (live.g - rest.g) * t,
            blue: rest.b + (live.b - rest.b) * t
        )
    }

    /// Phase dots use Color.primary (label). Previous palette kept to restore:
    /// listening (0.62, 0.55, 1.0), thinking (0.78, 0.58, 1.0), speaking (0.72, 0.48, 0.98),
    /// preparing (0.55, 0.62, 0.92), idle (0.7, 0.62, 1.0).
    private var particleColor: Color {
        switch phase {
        case .listening, .thinking, .speaking, .preparing, .idle:
            return .primary
        case .needsMicrophone, .needsModel, .needsVoice, .failed:
            return Color.secondary
        }
    }

    private static func rgb(of color: Color) -> (r: Double, g: Double, b: Double) {
        let ui = UIColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if ui.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (Double(r), Double(g), Double(b))
        }
        var white: CGFloat = 0
        if ui.getWhite(&white, alpha: &a) {
            return (Double(white), Double(white), Double(white))
        }
        return (0.62, 0.55, 1.0)
    }

    private var spinRate: Double {
        switch phase {
        case .listening: 0.7
        case .thinking: 1.55
        case .preparing: 0.45
        // Keep the waveform facing the student — slow yaw.
        case .speaking: 0.22
        default: 0.35
        }
    }

    private func energyAmount(at time: TimeInterval) -> CGFloat {
        switch phase {
        case .listening:
            return CGFloat((sin(time * 2.6) + 1) / 2) * 0.55 + 0.25
        case .thinking:
            return CGFloat((sin(time * 4.2) + 1) / 2) * 0.45 + 0.35
        case .speaking:
            return CGFloat((sin(time * 7.5) + 1) / 2) * 0.75 + 0.4
        case .preparing:
            return CGFloat((sin(time * 1.8) + 1) / 2) * 0.3 + 0.2
        case .needsMicrophone, .needsModel, .needsVoice, .failed:
            return 0.15
        case .idle:
            return CGFloat((sin(time * 1.4) + 1) / 2) * 0.2 + 0.12
        }
    }

    private func drawParticles(
        context: GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        ring: CGFloat,
        wave: CGFloat,
        helix: CGFloat,
        hear: CGFloat,
        energy: CGFloat,
        color: Color
    ) {
        let mid = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let baseRadius = min(size.width, size.height) * 0.32
        let r = Double(ring)
        let w = Double(wave)
        let h = Double(helix)
        // Helix breathe matches the old preparing pass (listen-like pulse).
        let helixEnergy = (sin(time * 2.6) + 1) / 2 * 0.55 + 0.25
        let shownEnergy = Double(energy) * (1 - h) + helixEnergy * h
        let breathe = 1 + 0.05 * sin(time * 1.8) + 0.1 * shownEnergy
        // Same radius for listen, think, speak, and the preparing helix.
        let radius = baseRadius * breathe
        // Each shape keeps its own yaw. Blending time * rate spins the cloud
        // because time is seconds since 2001, so a small rate change is a huge angle.
        let particleYaw = time * spinRate
        let helixYaw = time * 0.55
        let pitch = (0.35 + 0.12 * sin(time * 0.55)) * Double(1 - 0.85 * wave)
        let sphereW = max(0, 1 - r - w)
        let count = Double(Self.particleCount)
        // Thinking: ~56 evenly spaced dots (constant gap). No irregular skips.
        let ringDotCount = 56
        let baseDraw = max(
            ringDotCount,
            Int((Double(Self.particleCount) * (1 - r) + Double(ringDotCount) * r).rounded())
        )
        // Speaking is one wave. Fewer dots so the gaps stay visible.
        let speakDotCount = 96
        let withWave = max(
            1,
            Int((Double(baseDraw) * (1 - w) + Double(speakDotCount) * w).rounded())
        )
        // Preparing stays a 72-dot double helix; the count eases with the shape.
        let helixDotCount = 110
        let drawCount = max(
            1,
            Int((Double(withWave) * (1 - h) + Double(helixDotCount) * h).rounded())
        )

        var projected: [(z: Double, point: CGPoint, size: CGFloat, alpha: Double)] = []
        projected.reserveCapacity(drawCount)

        let cosY = cos(particleYaw)
        let sinY = sin(particleYaw)
        let cosH = cos(helixYaw)
        let sinH = sin(helixYaw)
        let cosP = cos(pitch)
        let sinP = sin(pitch)

        for slot in 0..<drawCount {
            let index = slot * (Self.particleCount - 1) / max(drawCount - 1, 1)
            let (sx, sy, sz) = Self.unitSphere[index]
            // Same ring shape; even angle on the ring so spacing stays equal.
            let fibAngle = atan2(sz, sx)
            let evenAngle = Double(slot) / Double(drawCount) * 2 * .pi
            let angle = fibAngle * (1 - r) + evenAngle * r
            let ringX = cos(angle)
            let ringY = sin(angle * 3 + time * 1.2) * 0.12
            let ringZ = sin(angle)

            // Speaking only: frequency ribbon.
            let u = Double(index) / count
            // Width matches the listen sphere (±1). Peaks stay inside that box.
            let waveX = (u - 0.5) * 2
            let amp = 0.5 + 0.5 * Double(energy)
            let waveY =
                (sin(u * .pi * 5 + time * 9) * 0.38
                    + sin(u * .pi * 9 + time * 14) * 0.25
                    + sin(u * .pi * 2.5 + time * 6) * 0.27)
                * amp
            let waveZ = 0.0

            var x = sx * sphereW + ringX * r + waveX * w
            var y = sy * sphereW + ringY * r + waveY * w
            var z = sz * sphereW + ringZ * r + waveZ * w
            let j = (sin(time * (2.2 + Double(index % 7) * 0.15) + Double(index)) * 0.5 + 0.5)
            // Speaking stays on one line. Jitter here reads as a second row of dots.
            // Helix has no scatter, so this fades out with the sphere.
            let jitter = 1 + Double(energy) * 0.12 * j * (1 - r * 0.5) * (1 - w) * (1 - h)
            x *= jitter
            y *= jitter
            z *= jitter

            let hu = Double(slot) / Double(max(drawCount - 1, 1))
            let strand = slot.isMultiple(of: 2) ? 0.0 : Double.pi
            let helixAngle = hu * 3.2 * Double.pi + time * 1.15 + strand
            let arm = 0.95
            let hx = cos(helixAngle) * arm
            let hy = (hu - 0.5) * 2
            let hz = sin(helixAngle) * arm

            let x1p = x * cosY - z * sinY
            let z1p = x * sinY + z * cosY
            let y1p = y * cosP - z1p * sinP
            let z2p = y * sinP + z1p * cosP

            let hx1 = hx * cosH - hz * sinH
            let hz1 = hx * sinH + hz * cosH

            var x1 = x1p * (1 - h) + hx1 * h
            var y1 = y1p * (1 - h) + hy * h
            var z2 = z2p * (1 - h) + hz1 * h

            // Hearing only. hear is 0 the rest of the time, so the resting sphere is unchanged.
            let ripple = sin(time * 8 + sy * 4) * 0.7 + sin(time * 13 + sx * 3) * 0.3
            let pulse = (ripple + 1) / 2
            let open = 1 + Double(hear) * 0.14 * pulse
            x1 *= open
            y1 *= open
            z2 *= open

            let depth = (z2 + 1) * 0.5
            let scale = radius * (0.78 + 0.42 * depth)
            let px = mid.x + CGFloat(x1) * scale
            let py = mid.y + CGFloat(y1) * scale
            // Thinking only: same ring, slightly larger dots. Listening ring weight is ~0.08.
            let thinkDots = 1 + 0.4 * r
            let dotBoost = 1 + Double(hear) * 0.75 * pulse
            let dot = CGFloat(1.4 + 2.6 * depth) * CGFloat(0.85 + 0.25 * shownEnergy) * CGFloat(dotBoost * thinkDots)
            let particleAlpha = (0.18 + 0.72 * depth) * (1 - 0.12 * r)
            let helixAlpha = 0.28 + 0.62 * depth
            let alpha = particleAlpha * (1 - h) + helixAlpha * h
            projected.append((z2, CGPoint(x: px, y: py), dot, alpha))
        }

        projected.sort { $0.z < $1.z }
        for item in projected {
            let rect = CGRect(
                x: item.point.x - item.size * 0.5,
                y: item.point.y - item.size * 0.5,
                width: item.size,
                height: item.size
            )
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(item.alpha)))
        }
    }

    private static let particleCount = 360
    /// Fibonacci sphere samples, unit radius.
    private static let unitSphere: [(Double, Double, Double)] = {
        let n = particleCount
        let golden = Double.pi * (3 - sqrt(5))
        var points: [(Double, Double, Double)] = []
        points.reserveCapacity(n)
        for i in 0..<n {
            let y = 1 - (Double(i) / Double(n - 1)) * 2
            let r = sqrt(max(0, 1 - y * y))
            let theta = golden * Double(i)
            points.append((cos(theta) * r, y, sin(theta) * r))
        }
        return points
    }()
}

/// Frame-to-frame easing so sphere ↔ ring ↔ wave ↔ helix does not pop.
private final class OrbDynamics {
    private var ring: CGFloat = 0
    private var wave: CGFloat = 0
    private var helix: CGFloat = 0
    private var hear: CGFloat = 0
    private var lastTime: TimeInterval?

    func tick(
        to time: TimeInterval,
        towardRing: CGFloat,
        towardWave: CGFloat,
        towardHelix: CGFloat,
        towardHear: CGFloat
    ) -> (ring: CGFloat, wave: CGFloat, helix: CGFloat, hear: CGFloat) {
        let dt: TimeInterval
        let isFirst = lastTime == nil
        if let lastTime {
            dt = min(0.05, max(1 / 120, time - lastTime))
        } else {
            dt = 1 / 30
        }
        lastTime = time
        let rate = CGFloat(1 - exp(-dt * 6))
        ring += (towardRing - ring) * rate
        wave += (towardWave - wave) * rate
        // First paint of Preparing is already the helix. Later phase changes ease.
        if isFirst {
            helix = towardHelix
        } else {
            helix += (towardHelix - helix) * rate
        }
        hear += (towardHear - hear) * rate
        return (ring, wave, helix, hear)
    }
}
