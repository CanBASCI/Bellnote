import AVFoundation
import OSLog
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// A text that the share sheet sends as a plain text file. The file is written only when the student picks where
/// to send it, in the temporary folder.
private struct SharedText: Transferable {
    var name: String
    var text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { item in
            // A name must not hold a slash or a colon.
            let safe = item.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe).appendingPathExtension("txt")
            try item.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

struct LecturePage: View {
    @Bindable var lecture: Lecture
    /// Plays from this second once the recording is loaded.
    var startSecond: Int?
    /// Opens the Raw tab and scrolls to this block (Ask → Source).
    var focusRawBlockToken: UUID?
    /// Opens the Assignments picker and scrolls to this task.
    var focusAssignmentID: PersistentIdentifier?

    @State private var editingTitle = false
    @State private var titleDraft = ""

    var body: some View {
        LectureNote(
            lecture: lecture,
            showsDate: false,
            startSecond: startSecond,
            onEditTitle: {
                titleDraft = lecture.title
                editingTitle = true
            },
            focusRawBlockToken: focusRawBlockToken,
            focusAssignmentID: focusAssignmentID
        )
            .navigationTitle(barTitle)
            .navigationSubtitle(subtitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The headline takes two lines in the middle of the bar.
                ToolbarItem(placement: .principal) {
                    Text(barTitle)
                        .appFont(.subheadline, weight: .semibold)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .alert("Lecture title", isPresented: $editingTitle) {
                TextField("Lecture title", text: $titleDraft)
                Button("Save") { saveTitle() }
                Button("Cancel", role: .cancel) {}
            }
    }

    /// The headline the model wrote from the AI correction, or the date while there is none.
    private var barTitle: String {
        lecture.title.isEmpty
            ? lecture.startedAt.formatted(date: .abbreviated, time: .shortened)
            : lecture.title
    }

    /// An empty title goes back to the date, and the model writes a new headline at the next run.
    private func saveTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        lecture.title = trimmed
        lecture.titleEdited = !trimmed.isEmpty
    }

    private var subtitle: String {
        guard lecture.recordedSeconds >= 60 else { return "" }
        return String(format: String(localized: "%lld min"), lecture.recordedSeconds / 60)
    }
}

private enum LectureTab: Hashable {
    case correction
    case raw
    case assignments
}

struct LectureNote: View {
    @Bindable var lecture: Lecture
    var showsDate: Bool
    var startSecond: Int?
    /// When set, the bar has a pencil to the left of the Process button that calls this.
    var onEditTitle: (() -> Void)?
    /// Opens Raw and scrolls to this block once (from Ask → Source on this page or via navigation).
    var focusRawBlockToken: UUID? = nil
    /// Opens the Assignments picker and scrolls to this task.
    var focusAssignmentID: PersistentIdentifier? = nil

    @Environment(AppSession.self) private var session
    /// Speaker name and the minute, one point under subheadline.
    @ScaledMetric(relativeTo: .subheadline) private var speakerPoint: CGFloat = 14
    /// “Missing”, one point under caption, with the lines under an assignment.
    @ScaledMetric(relativeTo: .caption) private var noteMetaSize: CGFloat = 11
    @State private var audio = LectureAudio()
    @State private var reader = SpeechReader()
    @State private var showStudy = false
    @State private var fluidGate = FluidAudioGate()
    private var workingStage: PipelineStage? { PipelineActivity.shared.stage(for: lecture) }
    private var workingStep: PipelineActivity.Step? { PipelineActivity.shared.step(for: lecture) }
    @State private var askReprocess = false
    @State private var askRewriteCorrection = false
    @State private var askRewriteAssignments = false
    @State private var askNoModel = false
    @State private var showCancel = false
    @State private var tab: LectureTab
    /// Speakers chosen in the Raw tab. Empty means everyone.
    @State private var chosenSpeakers: Set<Int> = []
    @State private var pendingAssignment: Assignment?
    @State private var pendingTurn: Block?
    @State private var editingBlock: Block?
    /// Block to emphasize and scroll to in Raw after Ask → Source.
    @State private var highlightBlockToken: UUID?
    /// Bumped so a Raw scroll runs after the list has drawn the source row.
    @State private var rawScrollTick: Int = 0
    /// Assignment row to scroll to after the Assignments picker is shown.
    @State private var highlightAssignmentID: PersistentIdentifier?
    @State private var assignmentScrollTick: Int = 0

    /// Starts on Raw when Ask → Source already knows which block to show.
    init(
        lecture: Lecture,
        showsDate: Bool,
        startSecond: Int? = nil,
        onEditTitle: (() -> Void)? = nil,
        focusRawBlockToken: UUID? = nil,
        focusAssignmentID: PersistentIdentifier? = nil
    ) {
        self.lecture = lecture
        self.showsDate = showsDate
        self.startSecond = startSecond
        self.onEditTitle = onEditTitle
        self.focusRawBlockToken = focusRawBlockToken
        self.focusAssignmentID = focusAssignmentID
        if let focusAssignmentID {
            _tab = State(initialValue: .assignments)
            _highlightAssignmentID = State(initialValue: focusAssignmentID)
            _assignmentScrollTick = State(initialValue: 1)
            _highlightBlockToken = State(initialValue: nil)
            _rawScrollTick = State(initialValue: 0)
        } else if let focusRawBlockToken {
            _tab = State(initialValue: .raw)
            _highlightBlockToken = State(initialValue: focusRawBlockToken)
            _rawScrollTick = State(initialValue: 1)
            _highlightAssignmentID = State(initialValue: nil)
            _assignmentScrollTick = State(initialValue: 0)
        } else {
            _tab = State(initialValue: .correction)
            _highlightBlockToken = State(initialValue: nil)
            _rawScrollTick = State(initialValue: 0)
            _highlightAssignmentID = State(initialValue: nil)
            _assignmentScrollTick = State(initialValue: 0)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if showsDate {
                    Section {
                        Text(lecture.startedAt.formatted(date: .abbreviated, time: .omitted))
                            .appFont(.title2, weight: .semibold)
                    }
                }
                if lecture.isRecordedOnly && workingStage == nil {
                    // Nothing to show in any tab until the recording is processed. The overlay below
                    // centres the message on the page.
                    EmptyView()
                } else {
                    switch tab {
                    case .correction:
                        correctionSections
                    case .raw:
                        rawSections
                    case .assignments:
                        assignmentSections
                    }
                }
            }
            .listStyle(.insetGrouped)
            // The list starts closer to the bar. Only the list moves; the bar and the tabs stay as they are.
            .contentMargins(.top, 0, for: .scrollContent)
            .task(id: rawScrollTick) {
                guard rawScrollTick > 0, tab == .raw, let token = highlightBlockToken else { return }
                // Let the Raw rows land before scrolling; one frame is not always enough after a push.
                try? await Task.sleep(for: .milliseconds(200))
                withAnimation {
                    proxy.scrollTo(token, anchor: .center)
                }
            }
            .task(id: assignmentScrollTick) {
                guard assignmentScrollTick > 0, tab == .assignments, let id = highlightAssignmentID else { return }
                try? await Task.sleep(for: .milliseconds(200))
                withAnimation {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        // The tabs sit under the navigation bar, in the middle, and the list scrolls under them.
        .safeAreaBar(edge: .top) {
            if !(lecture.isRecordedOnly && workingStage == nil) {
                VStack(spacing: 12) {
                    Picker("", selection: $tab) {
                        Text("AI correction").tag(LectureTab.correction)
                        Text("Raw").tag(LectureTab.raw)
                        Text("Assignments").tag(LectureTab.assignments)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .scenePadding(.horizontal)
                    // The speaker tags belong to the Raw tab. They are not a row of the list.
                    if tab == .raw, speakerTagGroups.count > 1,
                       !(lecture.blocks.isEmpty && lecture.flaggedSeconds.isEmpty) {
                        speakerTags
                    }
                }
                // Space under the tabs, so the bar reaches a little lower than the tabs.
                .padding(.bottom, 12)
            }
        }
        .overlay {
            // While the lecture is processed, the ring takes the screen. The notes come back when it ends.
            if let workingStep {
                ProcessingCircle(step: workingStep, isStopping: PipelineActivity.shared.isStopping(lecture))
            } else if lecture.isRecordedOnly {
                NotProcessedView { start() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
            }
        }
        .toolbar {
            if let onEditTitle {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit title", systemImage: "pencil", action: onEditTitle)
                        .labelStyle(.iconOnly)
                        .disabled(workingStage != nil)
                }
            }
            if workingStage != nil {
                // Only while the lecture is processed. It opens a small popover with one red button.
                ToolbarItem(placement: .primaryAction) {
                    Button("Cancel processing", systemImage: "xmark") {
                        showCancel = true
                    }
                    .labelStyle(.iconOnly)
                    // Once asked, the run ends when the step it is in lets go.
                    .disabled(PipelineActivity.shared.isStopping(lecture))
                    .popover(isPresented: $showCancel) {
                        // The red button of the recorder: prominent glass, tinted red.
                        Button {
                            showCancel = false
                            PipelineActivity.shared.stop(lecture)
                        } label: {
                            Label("Cancel processing", systemImage: "xmark")
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .tint(.red)
                        .padding()
                        .presentationCompactAdaptation(.popover)
                    }
                }
            } else if lecture.audioRelativePath != nil, !lecture.isRecordedOnly {
                // A recording that was never processed has its own Process button in the middle.
                ToolbarItem(placement: .primaryAction) {
                    let again = lecture.state == LectureState.ready.rawValue
                    Button(
                        again ? "Process again" : "Process",
                        systemImage: again ? "arrow.clockwise" : "waveform.badge.magnifyingglass"
                    ) {
                        if again {
                            askReprocess = true
                        } else {
                            start()
                        }
                    }
                    .labelStyle(.iconOnly)
                }
            }
            // Ask and Listen are one menu at the far right of the bar. Shown on every tab once a correction
            // exists and the whole run is over. The correction is written before the last stages end.
            if hasCorrection, workingStage == nil, let course = lecture.course {
                ToolbarItem(placement: .primaryAction) {
                    studyMenu(course)
                }
            }
            // A temporary share button at the far right of the bar. It shares what the open tab shows (the AI
            // correction, the raw text or the assignments) as a text file, because the text can be long.
            if let shared = textToShare {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: shared, preview: SharePreview(shared.name)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .task(id: lecture.persistentModelID) {
            await audio.load(lecture)
            if let startSecond, audio.duration > 0 {
                audio.seek(to: startSecond, play: true)
            }
        }
        .onChange(of: audio.duration) { syncPlayer() }
        // The player leaves while the lecture is processed and comes back when the whole run is over.
        .onChange(of: workingStage == nil) { syncPlayer() }
        .onDisappear {
            audio.stop()
            if session.player === audio { session.player = nil }
        }
        .task(id: audio.isPlaying) {
            while !Task.isCancelled, audio.isPlaying {
                try? await Task.sleep(for: .milliseconds(400))
                await audio.sync()
            }
        }
        .sheet(isPresented: $showStudy) {
            if let course = lecture.course {
                // Only this recording is asked about, not the other recordings of the course.
                StudySheet(course: course, lecture: lecture) { _, blockToken, _ in
                    // After the sheet finishes dismissing, so the Raw picker change is on screen.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        openRawSource(blockToken)
                    }
                }
            }
        }
        .fluidAudioGate(fluidGate)
        .noModelNotice(isPresented: $askNoModel) {
            fluidGate.request { await process() }
        }
        .confirmAssignmentDelete($pendingAssignment)
        .alert("Process again?", isPresented: $askReprocess) {
            Button("Delete and process again", role: .destructive) {
                start()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The raw text, the AI correction, the assignments and the title are deleted at once. Cancelling the processing does not bring them back. The recording stays.")
        }
        .alert("Process AI correction again?", isPresented: $askRewriteCorrection) {
            Button("Process AI correction again", role: .destructive) { rewriteCorrection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The AI correction is written again from the raw text as it is now. The raw text stays.")
        }
        .alert("Process assignments again?", isPresented: $askRewriteAssignments) {
            Button("Process assignments again", role: .destructive) { rewriteAssignments() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Assignments are taken again from the raw text as it is now. A task marked done stays done when the same words come back. The raw text stays.")
        }
        .alert("Delete this turn?", isPresented: Binding(
            get: { pendingTurn != nil },
            set: { if !$0 { pendingTurn = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let block = pendingTurn { deleteTurn(block) }
                pendingTurn = nil
            }
            Button("Cancel", role: .cancel) { pendingTurn = nil }
        } message: {
            Text("This speaker's text is removed. The recording stays.")
        }
        .sheet(item: $editingBlock) { block in
            RawTurnEditor(block: block, lecture: lecture) {
                chosenSpeakers = []
            }
        }
    }

    @ViewBuilder
    private var correctionSections: some View {
        // No correction yet: nothing to read, ask about or listen to. A running lecture shows only
        // the bar. A stopped one with no correction says so.
        if hasCorrection || workingStage == nil {
            Section {
                if hasSpokenText {
                    Button("Process AI correction again", systemImage: "arrow.clockwise") {
                        askRewriteCorrection = true
                    }
                    .labelStyle(.iconOnly)
                    .imageScale(.medium)
                }
                Text(CorrectionText.attributed(bodyText))
                    .appFont(.callout)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
        }
    }

    /// Exactly what Apple dictation returned, one block per speaker turn.
    @ViewBuilder
    private var rawSections: some View {
        let filter = activeSpeakers
        let blocks = lecture.blocks
            .filter { !$0.text.isEmpty }
            .filter { filter.isEmpty || filter.contains($0.speaker) }
            .sorted { $0.second < $1.second }
        if lecture.blocks.isEmpty && lecture.flaggedSeconds.isEmpty {
            Section {
                Text("No lectures yet.")
                    .foregroundStyle(.secondary)
            }
        } else {
            // The playing block is found once for the whole list, not once per row. `chapters` sorts every
            // block, and this list is drawn again each time the player moves.
            let playingToken = playingBlockToken(in: chapters)
            Section {
                ForEach(blocks) { block in
                    chapterLabel(
                        block,
                        isCurrent: block.token == playingToken,
                        isSource: block.token == highlightBlockToken
                    )
                    .id(block.token)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { editingBlock = block } label: {
                            Image(systemName: "pencil")
                        }
                        .tint(Color(.systemGray))
                        .accessibilityLabel(Text("Edit turn"))
                    }
                    .askToDeleteSwipe { pendingTurn = block }
                }
                ForEach(Array((filter.isEmpty ? orphanFlags : []).enumerated()), id: \.offset) { _, second in
                    Button {
                        audio.seek(to: second, play: true)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(MediaClock.short(second))
                                .appFont(size: speakerPoint, digits: true)
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .leading)
                            Text("I didn't get this")
                                .appFont(.callout)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var assignmentSections: some View {
        let own = lectureAssignments
        Section {
            if hasSpokenText {
                Button("Process assignments again", systemImage: "arrow.clockwise") {
                    askRewriteAssignments = true
                }
                .labelStyle(.iconOnly)
                .imageScale(.medium)
            }
            if own.isEmpty {
                Text("No assignments yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(own) { assignment in
                AssignmentRow(assignment: assignment, lectureReading: true) { second in
                    // Plays the sentence where the task was given and pauses there. The play button goes on.
                    audio.seek(to: second, play: true, until: endSecond(of: assignment))
                }
                .id(assignment.persistentModelID)
                .askToDeleteSwipe { pendingAssignment = assignment }
            }
        }
    }

    /// Where the block of a task ends: the start of the next block of this recording. Nil for the last block,
    /// which then plays to the end of the recording.
    private func endSecond(of assignment: Assignment) -> Int? {
        let ordered = lecture.blocks.sorted { $0.second < $1.second }
        let start = ordered.first { $0.token == assignment.sourceBlockID }?.second ?? assignment.sourceSecond
        return ordered.first { $0.second > start }?.second
    }

    /// Homework that came from this lecture's own text.
    private var lectureAssignments: [Assignment] {
        guard let course = lecture.course else { return [] }
        let ids = Set(lecture.blocks.map(\.token))
        return course.assignments.filter { ids.contains($0.sourceBlockID) }
    }

    /// Ask and Listen, as one menu in the navigation bar. The icon is the same as the Ask button of the course
    /// page.
    private func studyMenu(_ course: Course) -> some View {
        Menu {
            Button {
                showStudy = true
            } label: {
                Label("Ask", systemImage: "sparkles")
            }
            Button {
                if reader.isSpeaking {
                    reader.stop()
                } else {
                    listen(course)
                }
            } label: {
                if reader.isSpeaking {
                    Label("Stop", systemImage: "stop.fill")
                } else {
                    Label("Listen", systemImage: "speaker.wave.2.fill")
                }
            }
        } label: {
            Image(systemName: "sparkles")
        }
        .accessibilityLabel(Text("Ask"))
    }

    /// Puts the player in the tab bar's accessory when the recording is loaded and no run is going.
    /// A run that starts takes it away and stops the sound, so no sound plays without its controls.
    private func syncPlayer() {
        if workingStage == nil, audio.duration > 0 {
            session.player = audio
        } else if session.player === audio {
            if workingStage != nil { audio.stop() }
            session.player = nil
        }
    }

    private var hasCorrection: Bool {
        !lecture.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var bodyText: String {
        let summary = lecture.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { return summary }
        if let failure = lecture.failureMessageKey, !failure.isEmpty {
            return String(localized: String.LocalizationValue(failure))
        }
        return String(localized: "No AI correction yet.")
    }

    private var chapters: [Block] {
        lecture.blocks
            .filter { $0.role != SpeakerRole.room.rawValue && !$0.text.isEmpty }
            .sorted { $0.second < $1.second }
    }

    private var orphanFlags: [Int] {
        lecture.flaggedSeconds.filter { second in
            !chapters.contains { abs($0.second - second) <= 3 }
        }
    }

    private func chapterLabel(_ block: Block, isCurrent current: Bool, isSource: Bool = false) -> some View {
        let emphasize = current || isSource
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if block.speaker > 0 {
                    Text(speakerTitle(block.speaker))
                        .appFont(size: speakerPoint, weight: .semibold)
                        .foregroundStyle(Color.accentColor)
                }
                Button {
                    audio.seek(to: block.second, play: true)
                } label: {
                    Text(MediaClock.short(block.second))
                        .appFont(size: speakerPoint, digits: true)
                        .foregroundStyle(emphasize ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                audio.seek(to: block.second, play: true)
            } label: {
                Text(verbatim: block.text)
                    .appFont(.callout, weight: emphasize ? .semibold : .regular)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            if block.missing || block.userFlag {
                Text("Missing")
                    .appFont(size: noteMetaSize)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Switches to Raw, marks the block, and scrolls it into view after the list redraws.
    private func openRawSource(_ blockToken: UUID) {
        tab = .raw
        highlightBlockToken = blockToken
        rawScrollTick += 1
    }

    /// What the share button of the bar shares: the text of the open tab, as a file. Nil when the tab has nothing.
    private var textToShare: SharedText? {
        let text: String
        let part: String
        switch tab {
        case .correction:
            // The AI correction, without the highlight markers.
            text = hasCorrection ? CorrectionText.plain(lecture.summary) : ""
            part = "correction"
        case .raw:
            text = rawTranscriptText
            part = "raw"
        case .assignments:
            text = assignmentsText
            part = "assignments"
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let day = lecture.startedAt.formatted(.iso8601.year().month().day())
        let course = lecture.course?.name ?? "bellnote"
        return SharedText(name: "\(course) \(day) \(part)", text: text)
    }

    /// The raw text: one line per speaker turn, "[time] Speaker: words", with an empty line between turns. The
    /// speakers chosen above the list decide which turns go; none chosen means all of them.
    private var rawTranscriptText: String {
        let filter = activeSpeakers
        return lecture.blocks
            .filter { !$0.text.isEmpty }
            .filter { filter.isEmpty || filter.contains($0.speaker) }
            .sorted { $0.second < $1.second }
            .map { block -> String in
                let time = MediaClock.short(block.second)
                if block.speaker > 0 {
                    return "[\(time)] \(speakerTitle(block.speaker)): \(block.text)"
                }
                return "[\(time)] \(block.text)"
            }
            .joined(separator: "\n\n")
    }

    /// The assignments of this recording, one per line, with the due date when there is one and a mark for a done
    /// task.
    private var assignmentsText: String {
        lectureAssignments
            .filter { !$0.cancelled }
            .map { assignment -> String in
                var line = assignment.done ? "[x] " : "[ ] "
                line += assignment.text
                if let due = assignment.due {
                    line += " (\(due.formatted(date: .abbreviated, time: .omitted)))"
                }
                return line
            }
            .joined(separator: "\n")
    }

    /// The speakers of this recording, in the order the numbers were given.
    private var speakerClusters: [Int] {
        Array(Set(lecture.blocks.filter { !$0.text.isEmpty && $0.speaker > 0 }.map(\.speaker))).sorted()
    }

    /// The chosen speakers that this recording still has. After a new run an old choice can vanish.
    /// With fewer than two tags there is nothing to choose from, so nothing is filtered.
    private var activeSpeakers: Set<Int> {
        speakerTagGroups.count > 1 ? chosenSpeakers.intersection(speakerClusters) : []
    }

    /// One tag of the speaker filter. Speakers that carry the same name share a tag.
    private struct SpeakerTag: Identifiable {
        let title: String
        var clusters: [Int]
        var id: Int { clusters.first ?? 0 }
    }

    /// Two names are the same when they differ only in case, accents or spaces around them.
    private static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private var speakerTagGroups: [SpeakerTag] {
        var tags: [SpeakerTag] = []
        var position: [String: Int] = [:]
        for cluster in speakerClusters {
            let title = speakerTitle(cluster)
            let key = Self.nameKey(title)
            if let index = position[key] {
                tags[index].clusters.append(cluster)
            } else {
                position[key] = tags.count
                tags.append(SpeakerTag(title: title, clusters: [cluster]))
            }
        }
        return tags
    }

    /// One tag per speaker above the list. A tag shows the name the student gave. No tag chosen
    /// shows every speaker.
    private var speakerTags: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(speakerTagGroups) { tag in
                    let chosen = Set(tag.clusters).isSubset(of: chosenSpeakers)
                    Button {
                        if chosen {
                            chosenSpeakers.subtract(tag.clusters)
                        } else {
                            chosenSpeakers.formUnion(tag.clusters)
                        }
                    } label: {
                        Text(verbatim: tag.title)
                            .appFont(.subheadline, weight: chosen ? .semibold : .regular)
                            .lineLimit(1)
                            // A black fill is the label color and reads as a solid black capsule.
                            // The chosen capsule uses the same system gray as a selected switch track in dark,
                            // with white letters, so the choice stays visible in both modes.
                            .foregroundStyle(chosen ? Color.white : Color.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    // Plain style with a glass capsule that is not interactive. The `.glass` button style
                    // grows and shrinks under the finger, and this does not.
                    .buttonStyle(.plain)
                    .glassEffect(chosen ? .regular.tint(Color(.systemGray)) : .regular, in: .capsule)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func speakerTitle(_ cluster: Int) -> String {
        if let name = lecture.speakerName(for: cluster) { return name }
        return String(format: String(localized: "Speaker %lld"), cluster)
    }

    /// The block that is playing now: the last one that starts at or before the current second.
    /// `ordered` is sorted by start second.
    private func playingBlockToken(in ordered: [Block]) -> UUID? {
        let second = audio.currentSecond
        guard second > 0 else { return nil }
        return ordered.last { $0.second <= second }?.token
    }

    private func openCount(_ course: Course) -> Int {
        course.assignments.filter { !$0.done && !$0.cancelled }.count
    }

    private func listen(_ course: Course) {
        let text = lecture.summary.isEmpty
            ? chapters.map(\.text).joined(separator: "\n")
            : CorrectionText.plain(lecture.summary)
        Logger(subsystem: "app.bellnote", category: "listen").info(
            "Listen tap characters=\(text.count) locale=\(course.localeIdentifier, privacy: .public) speaking=\(reader.isSpeaking)"
        )
        reader.read(text, locale: Locale(identifier: course.localeIdentifier))
    }

    /// Warns first when no text model is installed, so minutes of transcript work are not a surprise.
    private func start() {
        Task {
            if await LocalModelRuntime.shared.hasTextModel() {
                fluidGate.request { await process() }
            } else {
                askNoModel = true
            }
        }
    }

    private func process() async {
        guard let context = lecture.modelContext else { return }
        let restart = lecture.state == LectureState.ready.rawValue
        if restart {
            LecturePipeline.discardProcessedNotes(lecture, context: context)
        }
        await LecturePipeline.advance(
            lecture: lecture,
            context: context,
            pageModel: AppPreferences.pageModel()
        )
    }

    /// The raw text has something the correction and the homework can read.
    private var hasSpokenText: Bool {
        lecture.blocks.contains { block in
            block.role != SpeakerRole.room.rawValue
                && !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func rewriteCorrection() {
        Task {
            guard await LocalModelRuntime.shared.hasTextModel() else {
                askNoModel = true
                return
            }
            guard let context = lecture.modelContext else { return }
            await LecturePipeline.rewriteCorrection(lecture: lecture, context: context)
        }
    }

    private func rewriteAssignments() {
        Task {
            guard await LocalModelRuntime.shared.hasTextModel() else {
                askNoModel = true
                return
            }
            guard let context = lecture.modelContext else { return }
            await LecturePipeline.rewriteAssignments(lecture: lecture, context: context)
        }
    }

    private func deleteTurn(_ block: Block) {
        guard let context = lecture.modelContext else { return }
        lecture.blocks.removeAll { $0.token == block.token }
        context.delete(block)
        do {
            try context.save()
        } catch {
            Logger(subsystem: "app.bellnote", category: "raw").error("Turn delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Edits one speaker turn. The name sits above the text. Chosen sentences can be given to another speaker.
private struct RawTurnEditor: View {
    @Bindable var block: Block
    var lecture: Lecture
    var onSpeakerNamed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var text: String
    @State private var nameChoice: NameChoice?
    @State private var typedName: String
    @State private var chosen: Set<Int> = []
    @State private var targetSpeaker: Int
    @State private var saveFailed = false

    /// A picker value that means a speaker who is not on the recording yet.
    private static let newSpeaker = -1

    /// A name already used, or a name the student types after choosing Other.
    private enum NameChoice: Hashable {
        case known(String)
        case other
    }

    init(block: Block, lecture: Lecture, onSpeakerNamed: @escaping () -> Void) {
        self.block = block
        self.lecture = lecture
        self.onSpeakerNamed = onSpeakerNamed
        _text = State(initialValue: block.text)
        let stored = lecture.speakerName(for: block.speaker) ?? ""
        let known = Self.suggestions(for: block, lecture: lecture)
        let match = known.first { Self.sameName($0, stored) }
        if let match {
            _nameChoice = State(initialValue: NameChoice.known(match))
            _typedName = State(initialValue: "")
        } else if !stored.isEmpty {
            _nameChoice = State(initialValue: NameChoice.other)
            _typedName = State(initialValue: stored)
        } else {
            // No name yet. The list is the names already used, plus Other. The field stays hidden until Other.
            _nameChoice = State(initialValue: nil)
            _typedName = State(initialValue: "")
        }
        let others = Set(
            lecture.blocks
                .filter { candidate in
                    candidate.speaker > 0
                        && candidate.speaker != block.speaker
                        && !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                .map(\.speaker)
        )
        _targetSpeaker = State(initialValue: others.sorted().first ?? Self.newSpeaker)
    }

    private var sentences: [String] {
        CorrectionText.sentences(in: text)
    }

    /// On selects every sentence. Off clears them. It stays on while each sentence is chosen.
    private var allSentencesChosen: Binding<Bool> {
        Binding(
            get: { !sentences.isEmpty && sentences.indices.allSatisfy { chosen.contains($0) } },
            set: { on in
                chosen = on ? Set(sentences.indices) : []
            }
        )
    }

    /// The other speakers who already have words on this recording, then New speaker.
    /// New speaker is the only row that creates a speaker. The next number is not listed before it exists.
    private var moveTargets: [MoveTarget] {
        let existing = Array(Set(
            lecture.blocks
                .filter { block in
                    block.speaker > 0
                        && block.speaker != self.block.speaker
                        && !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                .map(\.speaker)
        )).sorted().map { MoveTarget(id: $0, title: speakerTitle($0)) }
        return existing + [MoveTarget(id: Self.newSpeaker, title: String(localized: "New speaker"))]
    }

    private struct MoveTarget: Identifiable {
        var id: Int
        var title: String
    }

    /// The lecturer first, then names already given to the other speakers, each once.
    private var nameSuggestions: [String] {
        Self.suggestions(for: block, lecture: lecture)
    }

    private static func suggestions(for block: Block, lecture: Lecture) -> [String] {
        let lecturer = lecture.course?.lecturer?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let given = lecture.blocks
            .map(\.speaker)
            .filter { $0 > 0 && $0 != block.speaker }
            .compactMap { lecture.speakerName(for: $0) }
        var seen = Set<String>()
        var result: [String] = []
        for name in (lecturer.isEmpty ? [] : [lecturer]) + given where seen.insert(nameKey(name)).inserted {
            result.append(name)
        }
        return result
    }

    private static func sameName(_ left: String, _ right: String) -> Bool {
        nameKey(left) == nameKey(right) && !nameKey(left).isEmpty
    }

    private static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                if block.speaker > 0 {
                    Section {
                        Picker("Who is this?", selection: $nameChoice) {
                            ForEach(nameSuggestions, id: \.self) { name in
                                Text(verbatim: name).tag(NameChoice.known(name) as NameChoice?)
                            }
                            Text("Other").tag(NameChoice.other as NameChoice?)
                        }
                        if nameChoice == .other {
                            TextField("Name", text: $typedName)
                        }
                    }
                }
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                        .appFont(.body)
                }
                Section {
                    if !sentences.isEmpty {
                        Toggle("Select all", isOn: allSentencesChosen)
                            .switchTrackTint()
                    }
                    ForEach(Array(sentences.enumerated()), id: \.offset) { index, sentence in
                        Toggle(isOn: Binding(
                            get: { chosen.contains(index) },
                            set: { on in
                                if on {
                                    chosen.insert(index)
                                } else {
                                    chosen.remove(index)
                                }
                            }
                        )) {
                            Text(verbatim: sentence)
                        }
                        .switchTrackTint()
                    }
                    Picker("Speaker", selection: $targetSpeaker) {
                        ForEach(moveTargets) { target in
                            Text(verbatim: target.title).tag(target.id)
                        }
                    }
                } header: {
                    Text("Move to another speaker")
                } footer: {
                    Text("Chosen sentences leave this speaker and are added to the one you pick.")
                }
            }
            .navigationTitle("Edit turn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onChange(of: text) {
                let count = sentences.count
                chosen = chosen.filter { $0 < count }
            }
            .alert("The change could not be saved.", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    /// The name to store. Nil when the student has not chosen anyone yet.
    private var chosenSpeakerName: String? {
        switch nameChoice {
        case .known(let known): known
        case .other: typedName
        case nil: nil
        }
    }

    private func speakerTitle(_ cluster: Int) -> String {
        if let name = lecture.speakerName(for: cluster) { return name }
        return String(format: String(localized: "Speaker %lld"), cluster)
    }

    private func save() {
        let parts = sentences
        let moving = parts.indices.filter { chosen.contains($0) }.map { parts[$0] }
        if moving.isEmpty {
            block.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let staying = parts.indices.filter { !chosen.contains($0) }.map { parts[$0] }
            block.text = Self.joined(staying)
            give(moving, to: targetSpeaker)
        }
        if block.speaker > 0 {
            let source = block.speaker
            let remains = lecture.blocks.contains { candidate in
                candidate.speaker == source
                    && !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if !remains {
                lecture.setSpeakerName("", cluster: source)
                onSpeakerNamed()
                let leftovers = lecture.blocks.filter { $0.speaker == source }
                for item in leftovers {
                    lecture.blocks.removeAll { $0.token == item.token }
                    context.delete(item)
                }
            } else if let name = chosenSpeakerName {
                lecture.setSpeakerName(name, cluster: source)
                onSpeakerNamed()
            }
        }
        do {
            try context.save()
            dismiss()
        } catch {
            Logger(subsystem: "app.bellnote", category: "raw").error("Turn save failed: \(error.localizedDescription, privacy: .public)")
            saveFailed = true
        }
    }

    /// Puts the sentences on the chosen speaker. A new speaker gets a turn of their own at the same minute.
    private func give(_ sentences: [String], to speaker: Int) {
        let piece = Self.joined(sentences)
        guard !piece.isEmpty else { return }
        if speaker > 0,
           let target = lecture.blocks
            .filter({ $0.speaker == speaker && $0.token != block.token })
            .min(by: { abs($0.second - block.second) < abs($1.second - block.second) }) {
            let existing = target.text.trimmingCharacters(in: .whitespacesAndNewlines)
            target.text = existing.isEmpty ? piece : existing + "\n" + piece
            return
        }
        let speakerID = speaker > 0 ? speaker : nextFreeSpeakerID()
        let role = SpeakerRole(rawValue: block.role) ?? .narrator
        let created = Block(
            lecture: lecture,
            second: block.second,
            role: role,
            kind: .other,
            text: piece,
            speaker: speakerID
        )
        lecture.blocks.append(created)
    }

    /// The smallest speaker number that has no words left. A speaker whose text was moved away can be used again.
    private func nextFreeSpeakerID() -> Int {
        let used = Set(
            lecture.blocks
                .filter { candidate in
                    candidate.speaker > 0
                        && !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                .map(\.speaker)
        )
        var id = 1
        while used.contains(id) {
            id += 1
        }
        return id
    }

    private static func joined(_ sentences: [String]) -> String {
        let body = sentences.joined(separator: ". ")
        guard let last = body.last else { return "" }
        if last == "." || last == "?" || last == "!" { return body }
        return body + "."
    }
}

enum MediaClock {
    static func full(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    static func short(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds >= 3600 { return full(seconds) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = trimmed.firstIndex(where: { $0 == "." || $0 == "?" || $0 == "!" })
        let sentence = end.map { String(trimmed[...$0]) } ?? trimmed
        if sentence.count <= 110 { return sentence }
        return String(sentence.prefix(110)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

@MainActor
@Observable
final class LectureAudio {
    private(set) var isPlaying = false
    private(set) var currentSecond = 0
    private(set) var duration = 0
    /// Playback speed chosen from the player menu (0.5×, 1×, 1.5×, 2×).
    private(set) var rate: Float = 1
    /// Seeks that were asked for and have not finished. Not shown on screen.
    @ObservationIgnored private var pendingSeeks = 0
    private let engine = LecturePlaybackEngine()

    /// Speeds offered in the player menu, slowest to fastest.
    static let rateSteps: [Float] = [0.5, 1, 1.5, 2]

    func load(_ lecture: Lecture) async {
        await engine.reset()
        isPlaying = false
        duration = 0
        currentSecond = 0
        rate = 1
        guard let relative = lecture.audioRelativePath else { return }
        guard let root = try? Vault.documents() else { return }
        let url = root.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let seconds = await engine.load(url)
        guard seconds > 0 else { return }
        duration = seconds
        await engine.setRate(rate)
    }

    func toggle() {
        Task { await togglePlayback() }
    }

    func setRate(_ next: Float) {
        guard Self.rateSteps.contains(next), next != rate else { return }
        rate = next
        Task { await engine.setRate(next) }
    }

    /// `until` is a second where the player pauses by itself. The student can go on from the play button.
    /// Without it the recording plays to its end.
    func seek(to second: Int, play: Bool, until: Int? = nil) {
        // The shown second moves at once, so the slider does not wait for the player.
        currentSecond = min(max(0, second), max(duration, 0))
        pendingSeeks += 1
        Task {
            await seekPlayback(to: second, play: play, until: until)
            pendingSeeks -= 1
        }
    }

    func sync() async {
        let snapshot = await engine.snapshot()
        // A seek is on its way. The snapshot may still show the old second, and would pull the slider back.
        if pendingSeeks == 0 {
            currentSecond = snapshot.timeSeconds
        }
        if !snapshot.isPlaying { isPlaying = false }
    }

    func stop() {
        Task {
            await engine.stop()
            isPlaying = false
        }
    }

    private func togglePlayback() async {
        if await engine.isPlaying() {
            await engine.pause()
            isPlaying = false
            return
        }
        isPlaying = await engine.play()
    }

    private func seekPlayback(to second: Int, play: Bool, until: Int?) async {
        let clamped = min(max(0, second), max(duration, 0))
        if play {
            // A stop at or before the start would pause at once, so it is ignored.
            let stop = until.flatMap { $0 > clamped ? TimeInterval($0) : nil }
            isPlaying = await engine.play(from: TimeInterval(clamped), until: stop)
        } else {
            await engine.setCurrentTime(TimeInterval(clamped))
        }
    }
}

/// `AVAudioPlayer.play` calls synchronous `setActive`. Keep that off the main thread.
private final class LecturePlaybackEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.bellnote.lecture-playback", qos: .userInitiated)
    private var player: AVAudioPlayer?
    private var sessionReady = false
    /// The pause that is waiting for the end of a task sentence. Only used on `queue`.
    private var stopItem: DispatchWorkItem?

    struct Snapshot: Sendable {
        var timeSeconds: Int
        var isPlaying: Bool
    }

    func reset() async {
        await onQueue { [self] in
            stopItem?.cancel()
            stopItem = nil
            player?.stop()
            player = nil
            sessionReady = false
        }
        await deactivateSession()
    }

    func load(_ url: URL) async -> Int {
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        guard let data else { return 0 }
        return await onQueue { [self] in
            guard let player = try? AVAudioPlayer(data: data) else { return 0 }
            self.player = player
            return Int(player.duration.rounded())
        }
    }

    func isPlaying() async -> Bool {
        await onQueue { [self] in player?.isPlaying ?? false }
    }

    func pause() async {
        await onQueue { [self] in
            stopItem?.cancel()
            stopItem = nil
            player?.pause()
        }
    }

    func stop() async {
        await onQueue { [self] in
            stopItem?.cancel()
            stopItem = nil
            player?.stop()
            sessionReady = false
        }
        await deactivateSession()
    }

    func setCurrentTime(_ time: TimeInterval) async {
        await onQueue { [self] in player?.currentTime = time }
    }

    /// Plays from `time`, or from where it is. With `until` the player pauses at that second by itself.
    /// Any other play, pause, stop or reset cancels an earlier stop, so the play button always goes on.
    func play(from time: TimeInterval? = nil, until: TimeInterval? = nil) async -> Bool {
        guard await ensureSession() else { return false }
        return await onQueue { [self] in
            stopItem?.cancel()
            stopItem = nil
            guard let player else {
                Logger(subsystem: "app.bellnote", category: "player").error("Play asked with no player")
                return false
            }
            if let time { player.currentTime = time }
            player.enableRate = true
            player.prepareToPlay()
            let started = player.play()
            if started, let until {
                // The item runs on `queue` too, so it reads the player there. It holds the engine, not the player.
                // Wall time shrinks when the rate is above 1, so the pause still lands on the spoken second.
                let item = DispatchWorkItem { [weak self] in self?.player?.pause() }
                stopItem = item
                let speed = max(Double(player.rate), 0.1)
                let delay = max(0, until - player.currentTime) / speed
                queue.asyncAfter(deadline: .now() + delay, execute: item)
            }
            return started
        }
    }

    func setRate(_ rate: Float) async {
        await onQueue { [self] in
            guard let player else { return }
            player.enableRate = true
            player.rate = rate
        }
    }

    func snapshot() async -> Snapshot {
        await onQueue { [self] in
            Snapshot(
                timeSeconds: Int(player?.currentTime ?? 0),
                isPlaying: player?.isPlaying ?? false
            )
        }
    }

    private func ensureSession() async -> Bool {
        if await onQueue({ [self] in sessionReady }) { return true }
        let ready = await activateSession()
        await onQueue { [self] in sessionReady = ready }
        return ready
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    private func activateSession() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(.playback, mode: .spokenAudio)
                } catch {
                    continuation.resume(returning: false)
                    return
                }
                session.activate(options: []) { activated, _ in
                    continuation.resume(returning: activated)
                }
            }
        }
    }

    private func deactivateSession() async {
        await withCheckedContinuation { continuation in
            queue.async {
                AVAudioSession.sharedInstance().deactivate(options: [.notifyOthersOnDeactivation]) { _, _ in
                    continuation.resume()
                }
            }
        }
    }
}
