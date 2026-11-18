import OSLog
import SwiftData
import SwiftUI

/// Tab between Files and Assistant. Multiple-choice quiz from notes and selected course files.
struct QuizPage: View {
    private static let log = Logger(subsystem: "app.bellnote", category: "quiz")

    @Bindable var term: Term
    @Environment(AppSession.self) private var session
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    @State private var quiz = QuizSession()
    @State private var sourceJump: QuizSourceJump?
    @State private var filePreview: QuizFilePreview?
    @State private var pdfSource: QuizPDFSourceItem?
    @State private var stickyJump: QuizStickyJump?
    @State private var fileNotice: String?

    private var courses: [Course] {
        term.courses.sorted { lhs, rhs in
            if lhs.homeOrder != rhs.homeOrder { return lhs.homeOrder < rhs.homeOrder }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    private var replyLanguage: Locale {
        let code = session.languageCode
        let language = AppLanguage(rawValue: code) ?? .english
        return Locale(identifier: language.speechLocaleIdentifier)
    }

    var body: some View {
        @Bindable var quiz = quiz
        Group {
            switch quiz.phase {
            case .pickCourse:
                courseList
            case .setup:
                if let course = quiz.course {
                    setupView(course, quiz: quiz)
                } else {
                    courseList
                }
            case .preparing:
                preparingView
            case .taking:
                takingView
            case .results:
                resultsView
            case .review:
                reviewView
            case .needsModel:
                ContentUnavailableView {
                    Label("Text model needed", systemImage: "arrow.down.circle")
                } description: {
                    Text("Download a text model in Settings.")
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Could not prepare", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: message)
                } actions: {
                    Button("Try again") { quiz.backToSetup() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(quizNavigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if quiz.phase == .setup || quiz.phase == .results || quiz.phase == .review
                || quiz.phase == .needsModel || failedPhase
            {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") {
                        switch quiz.phase {
                        case .setup, .needsModel, .failed:
                            quiz.resetToCourses()
                        case .results:
                            quiz.backToSetup()
                        case .review:
                            quiz.closeReview()
                        default:
                            break
                        }
                    }
                }
            }
            if quiz.phase == .setup, let course = quiz.course {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Prepare") {
                        quiz.startPreparing(replyLanguage: replyLanguage)
                    }
                    .disabled(!canPrepare(course))
                }
            }
            if quiz.phase == .results {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        quiz.backToSetup()
                    }
                }
            }
        }
        .navigationDestination(item: $sourceJump) { jump in
            LecturePage(
                lecture: jump.lecture,
                startSecond: jump.second,
                focusRawBlockToken: jump.blockToken
            )
        }
        .navigationDestination(item: $stickyJump) { jump in
            CourseCabinetPage(course: jump.course, openSticky: jump.token)
        }
        .fullScreenCover(item: $filePreview) { preview in
            CourseFilePreview(url: preview.url, title: preview.title) { error in
                Self.log.error("Quiz preview save failed \(error.localizedDescription, privacy: .public)")
                fileNotice = String(localized: "The change could not be saved.")
            } onEdited: {
                markFileUpdated(courseID: preview.courseID, fileID: preview.fileID)
            } onDismiss: {
                filePreview = nil
            }
        }
        .fullScreenCover(item: $pdfSource) { item in
            QuizPDFSourceView(
                url: item.url,
                title: item.title,
                pageIndex: item.pageIndex,
                excerpt: item.excerpt
            ) {
                pdfSource = nil
            }
        }
        .alert(
            fileNotice ?? "",
            isPresented: Binding(
                get: { fileNotice != nil },
                set: { if !$0 { fileNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) { fileNotice = nil }
        }
    }

    private var failedPhase: Bool {
        if case .failed = quiz.phase { return true }
        return false
    }

    /// “Quiz” alone on the course grid; “Quiz - Edebiyat” once a course is open.
    private var quizNavigationTitle: String {
        guard let name = quiz.course?.name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              quiz.phase != .pickCourse
        else {
            return String(localized: "Quiz")
        }
        return String(format: String(localized: "%@ - %@"), String(localized: "Quiz"), name)
    }

    /// Same grid as Files, but each tile is a Liquid Glass exam card — not a folder.
    private var courseList: some View {
        Group {
            if courses.isEmpty {
                ContentUnavailableView("No courses yet", systemImage: "checkmark.seal")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 16)], spacing: 22) {
                        ForEach(courses) { course in
                            Button {
                                quiz.selectCourse(course)
                            } label: {
                                examTile(course)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    /// One course as a glass quiz card tinted with that course’s color. The name sits under it.
    /// The count is how many PDFs, images, and slides sit in that course’s Files cabinet.
    private func examTile(_ course: Course) -> some View {
        let tintOpacity = colorScheme == .dark ? 0.5 : 0.28
        let documentCount = quizDocumentCount(course)
        return VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "list.clipboard.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(course.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
                Text(verbatim: "\(documentCount)")
                    .appFont(.caption, weight: .semibold, digits: true)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 10)
                    .padding(.bottom, 8)
                    .accessibilityHidden(true)
            }
            .frame(width: 96, height: 96)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.clear)
                    .glassEffect(
                        .regular.tint(course.color.opacity(tintOpacity)),
                        in: .rect(cornerRadius: 22)
                    )
            }
            Text(course.name)
                .appFont(.footnote, weight: .semibold)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 96)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect(cornerRadius: 22))
        .accessibilityLabel(
            Text(
                "\(course.name), \(String(format: String(localized: "%lld documents"), documentCount))"
            )
        )
    }

    private func quizDocumentCount(_ course: Course) -> Int {
        course.files.reduce(0) { total, file in
            switch CourseFileKind(rawValue: file.kind) {
            case .pdf, .image, .slide: total + 1
            default: total
            }
        }
    }

    /// Section title like “This week”, with the short note directly under it.
    private func sectionTitle(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textCase(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Same layout when the title is already a formatted string (question index, wrong count).
    private func sectionTitle(verbatim title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
            if let detail {
                Text(verbatim: detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textCase(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let setupCoverSize: CGFloat = 48
    private static let setupCoverGap: CGFloat = 12

    private func setupView(_ course: Course, quiz: QuizSession) -> some View {
        @Bindable var quiz = quiz
        let media = quizFiles(course)
        // Same plain list as the course page. Prepare sits in the navigation bar.
        return List {
            Section {
                Picker("Difficulty", selection: $quiz.difficulty) {
                    ForEach(QuizDifficulty.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.clear)
                .listRowInsets(.vertical, 8)
            } header: {
                sectionTitle("Difficulty")
            }

            Section {
                Picker("Questions", selection: $quiz.questionCount) {
                    ForEach(QuizQuestionCount.allCases) { count in
                        Text(count.title).tag(count)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.clear)
                .listRowInsets(.vertical, 8)
            } header: {
                sectionTitle("Questions")
            }

            Section {
                Toggle("Include lecture notes", isOn: $quiz.includeLectureNotes)
                    .switchTrackTint()
                    .listRowBackground(Color.clear)
                    .listRowInsets(.vertical, 8)
            } header: {
                sectionTitle(
                    "Lecture notes",
                    detail: "Off by default. Turn on to also write questions from ready recordings of this course."
                )
            }

            Section {
                if media.isEmpty {
                    Text("Add a PDF or image in Files for this course to include it here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.vertical, 8)
                } else {
                    ForEach(media) { file in
                        let id = file.persistentModelID
                        let selected = quiz.selectedFileIDs.contains(id)
                        let separatorStart = Self.setupCoverSize + Self.setupCoverGap
                        Button {
                            quiz.toggleFile(id)
                        } label: {
                            HStack(alignment: .center, spacing: Self.setupCoverGap) {
                                setupFileCover(symbol(for: file))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: setupFileDetail(file))
                                        .appFont(.subheadline, weight: .medium)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(verbatim: file.displayName)
                                        .appFont(.subheadline)
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // Same mark size as an assignment circle — bare SF Symbol shrinks to list text.
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .appFont(.title3)
                                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.vertical, 8)
                        .alignmentGuide(.listRowSeparatorLeading) { [separatorStart] _ in
                            separatorStart
                        }
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            } header: {
                sectionTitle(
                    "Course files",
                    detail: "Pick PDFs or images from this course’s Files. There is no upload here."
                )
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 16, for: .scrollContent)
    }

    /// Same outlined square as a file on the Files list / a recording on This week.
    private func setupFileCover(_ systemName: String) -> some View {
        let size = Self.setupCoverSize
        let shape = RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
        return Image(systemName: systemName)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background {
                shape.strokeBorder(Color.secondary, lineWidth: max(1.5, size * 0.045))
            }
            .accessibilityHidden(true)
    }

    private func symbol(for file: CourseFile) -> String {
        switch CourseFileKind(rawValue: file.kind) {
        case .pdf: "doc.richtext"
        case .slide: "rectangle.on.rectangle"
        case .image: "photo"
        case .other, nil: "doc"
        }
    }

    private func setupFileDetail(_ file: CourseFile) -> String {
        let ext = URL(fileURLWithPath: file.displayName).pathExtension
        if !ext.isEmpty { return ext.uppercased() }
        return String(localized: "Other")
    }

    private var preparingView: some View {
        ProcessingCircle(step: quiz.preparingStep)
            .animation(.easeOut(duration: 0.2), value: quiz.statusLine)
            .animation(.easeOut(duration: 0.2), value: quiz.statusCaption)
            .animation(.easeOut(duration: 0.2), value: quiz.prepareFraction)
    }

    private var courseTint: Color {
        quiz.course?.color ?? Color.accentColor
    }

    private var takingView: some View {
        Group {
            if let question = quiz.current {
                List {
                    Section {
                        Text(verbatim: question.prompt)
                            .appFont(.body, weight: .semibold)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.vertical, 8)
                    } header: {
                        sectionTitle(
                            verbatim: String(
                                format: String(localized: "Question %1$lld of %2$lld"),
                                quiz.index + 1,
                                quiz.questions.count
                            ),
                            detail: String(localized: "Pick one letter to continue.")
                        )
                    }

                    Section {
                        ForEach(question.choiceLines, id: \.0) { choice, text in
                            takingChoiceRow(choice: choice, text: text)
                        }
                    } header: {
                        sectionTitle("Choices")
                    }
                }
                .listStyle(.plain)
                .contentMargins(.top, 16, for: .scrollContent)
            } else {
                ContentUnavailableView("No questions", systemImage: "questionmark.circle")
            }
        }
    }

    /// Palette marks used for quiz score / review (same family as exam grade tints).
    private var quizCorrectTint: Color { CourseStyle.scoreTint(.passed) }
    private var quizWrongTint: Color { CourseStyle.scoreTint(.notPassed) }

    /// Letter badge + row tap. No trailing checkbox — the row itself selects.
    private func takingChoiceRow(choice: QuizChoice, text: String) -> some View {
        Button {
            quiz.pick(choice)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                choiceLetterBadge(choice.rawValue, fill: courseTint)
                Text(verbatim: text)
                    .appFont(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
    }

    private var resultsView: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "\(quiz.correctCount)")
                            .appFont(.largeTitle, weight: .bold, digits: true)
                            .foregroundStyle(courseTint)
                        Text(
                            verbatim: String(
                                format: String(localized: "of %lld"),
                                quiz.questions.count
                            )
                        )
                        .appFont(.title2, weight: .semibold)
                        .foregroundStyle(.secondary)
                    }
                    Text(
                        verbatim: String(
                            format: String(localized: "%1$lld wrong"),
                            quiz.wrongCount
                        )
                    )
                    .appFont(.subheadline, weight: .semibold)
                    .foregroundStyle(quiz.wrongCount > 0 ? quizWrongTint : Color.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowBackground(Color.clear)
                .listRowInsets(.vertical, 8)
            } header: {
                sectionTitle("Results", detail: "How this quiz went. Done returns to setup.")
            }

            Section {
                resultRow(String(localized: "Total time"), formatDuration(quiz.totalSeconds))
                resultRow(String(localized: "Average per question"), formatDuration(quiz.averageSeconds))
            } header: {
                sectionTitle("Duration")
            }

            if !quiz.wrongAnswers.isEmpty {
                Section {
                    Button {
                        quiz.openReview()
                    } label: {
                        HStack {
                            Text("Review wrong answers")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .appFont(.footnote, weight: .semibold)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.vertical, 8)
                } header: {
                    sectionTitle(
                        "Review",
                        detail: "See the keyed letter and open the source."
                    )
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 16, for: .scrollContent)
    }

    /// All wrong answers in one scrolling list; each block has its own Source.
    private var reviewView: some View {
        let wrongs = quiz.wrongAnswers
        return Group {
            if wrongs.isEmpty {
                ContentUnavailableView("No questions", systemImage: "questionmark.circle")
            } else {
                List {
                    ForEach(Array(wrongs.enumerated()), id: \.element.id) { place, answer in
                        Section {
                            Text(verbatim: answer.question.prompt)
                                .appFont(.body, weight: .semibold)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .listRowBackground(Color.clear)
                                .listRowInsets(.vertical, 8)

                            ForEach(answer.question.choiceLines, id: \.0) { choice, text in
                                reviewChoiceRow(choice: choice, text: text, answer: answer)
                            }

                            Button("Source", systemImage: "text.quote") {
                                openSource(answer.question)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.vertical, 10)
                        } header: {
                            sectionTitle(
                                verbatim: String(
                                    format: String(localized: "Wrong %1$lld of %2$lld"),
                                    place + 1,
                                    wrongs.count
                                ),
                                detail: answer.question.sourceTitle
                            )
                        }
                    }
                }
                .listStyle(.plain)
                .contentMargins(.top, 16, for: .scrollContent)
            }
        }
    }

    private func reviewChoiceRow(choice: QuizChoice, text: String, answer: QuizAnswerRecord) -> some View {
        let role = reviewRole(choice: choice, answer: answer)
        let mark = reviewMarkColor(role)
        return HStack(alignment: .center, spacing: 12) {
            choiceLetterBadge(
                choice.rawValue,
                fill: mark ?? Color(.tertiaryLabel)
            )
            Text(verbatim: text)
                .appFont(.body)
                .foregroundStyle(role == .other ? Color.secondary : Color.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let mark {
                Image(systemName: role == .correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .appFont(.title3)
                    .foregroundStyle(mark)
                    .accessibilityHidden(true)
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .accessibilityLabel(reviewAccessibility(choice: choice, text: text, answer: answer))
    }

    private enum ReviewChoiceRole {
        case correct
        case wrongPick
        case other
    }

    private func reviewRole(choice: QuizChoice, answer: QuizAnswerRecord) -> ReviewChoiceRole {
        if choice == answer.question.correct { return .correct }
        if choice == answer.picked { return .wrongPick }
        return .other
    }

    private func reviewMarkColor(_ role: ReviewChoiceRole) -> Color? {
        switch role {
        case .correct: quizCorrectTint
        case .wrongPick: quizWrongTint
        case .other: nil
        }
    }

    private func choiceLetterBadge(_ letter: String, fill: Color) -> some View {
        Text(verbatim: letter)
            .appFont(.subheadline, weight: .bold)
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(fill, in: Circle())
            .accessibilityHidden(true)
    }

    private func reviewAccessibility(choice: QuizChoice, text: String, answer: QuizAnswerRecord) -> String {
        if choice == answer.question.correct {
            return String(format: String(localized: "%@, correct answer"), "\(choice.rawValue). \(text)")
        }
        if choice == answer.picked {
            return String(format: String(localized: "%@, your answer"), "\(choice.rawValue). \(text)")
        }
        return "\(choice.rawValue). \(text)"
    }

    private func resultRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(verbatim: title)
            Spacer()
            Text(verbatim: value)
                .foregroundStyle(.secondary)
                .appFont(.body, digits: true)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(.vertical, 8)
    }

    private func canPrepare(_ course: Course) -> Bool {
        let hasFile = !quiz.selectedFileIDs.isEmpty
        if hasFile { return true }
        guard quiz.includeLectureNotes else { return false }
        return course.lectures.contains {
            $0.state == LectureState.ready.rawValue
                && $0.blocks.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    private func quizFiles(_ course: Course) -> [CourseFile] {
        course.files
            .filter { file in
                switch CourseFileKind(rawValue: file.kind) {
                case .pdf, .image, .slide: true
                default: false
                }
            }
            .sorted { lhs, rhs in
                if lhs.listOrder != rhs.listOrder { return lhs.listOrder < rhs.listOrder }
                return lhs.addedAt > rhs.addedAt
            }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let rem = total % 60
        if minutes > 0 {
            return String(format: String(localized: "%1$lld min %2$lld sec"), minutes, rem)
        }
        return String(format: String(localized: "%lld sec"), rem)
    }

    private func openSource(_ question: QuizQuestion) {
        guard let courseID = question.courseID,
              let course = courses.first(where: { $0.persistentModelID == courseID })
                ?? quiz.course
        else {
            Self.log.error("Quiz source course missing")
            return
        }
        switch question.sourceKind {
        case .block:
            guard let lectureID = question.lectureID,
                  let lecture = course.lectures.first(where: { $0.persistentModelID == lectureID }),
                  let token = question.blockToken
            else {
                Self.log.error("Quiz source block missing")
                return
            }
            sourceJump = QuizSourceJump(
                id: token.uuidString,
                lecture: lecture,
                blockToken: token,
                second: question.second
            )
        case .file:
            guard let fileID = question.fileID,
                  let file = course.files.first(where: { $0.persistentModelID == fileID })
            else {
                fileNotice = String(localized: "The file could not be opened.")
                return
            }
            do {
                let url = try Vault.documents().appendingPathComponent(file.relativePath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    fileNotice = String(localized: "The file could not be opened.")
                    return
                }
                let kind = CourseFileKind(rawValue: file.kind) ?? .other
                if kind == .pdf || kind == .slide {
                    // Include question id so each Source tap gets a fresh jump (same PDF, different page).
                    pdfSource = QuizPDFSourceItem(
                        id: "\(question.id.uuidString)-\(question.sourcePageIndex ?? -1)",
                        url: url,
                        title: file.displayName,
                        pageIndex: question.sourcePageIndex,
                        excerpt: question.sourceExcerpt
                    )
                } else {
                    filePreview = QuizFilePreview(
                        id: String(describing: fileID),
                        url: url,
                        title: file.displayName,
                        courseID: course.persistentModelID,
                        fileID: fileID
                    )
                }
            } catch {
                fileNotice = String(localized: "The file could not be opened.")
            }
        case .sticky:
            guard let token = question.stickyToken else { return }
            stickyJump = QuizStickyJump(id: token.uuidString, course: course, token: token)
        }
    }

    private func markFileUpdated(courseID: PersistentIdentifier, fileID: PersistentIdentifier) {
        guard let course = courses.first(where: { $0.persistentModelID == courseID })
            ?? quiz.course,
            let file = course.files.first(where: { $0.persistentModelID == fileID })
        else { return }
        file.updatedAt = Date()
    }
}

private struct QuizSourceJump: Identifiable, Hashable {
    let id: String
    let lecture: Lecture
    let blockToken: UUID
    let second: Int?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private struct QuizStickyJump: Identifiable, Hashable {
    let id: String
    let course: Course
    let token: UUID

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private struct QuizFilePreview: Identifiable {
    var id: String
    var url: URL
    var title: String
    var courseID: PersistentIdentifier
    var fileID: PersistentIdentifier
}

private struct QuizPDFSourceItem: Identifiable {
    var id: String
    var url: URL
    var title: String
    var pageIndex: Int?
    var excerpt: String
}
