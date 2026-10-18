import Foundation
import OSLog
import SwiftData

@MainActor
enum LecturePipeline {
    private static let log = Logger(subsystem: "app.bellnote", category: "pipeline")

    static func advance(
        lecture: Lecture,
        context: ModelContext,
        pageModel: ModelRole,
        onProgress: ((PipelineStage) -> Void)? = nil
    ) async {
        let activity = PipelineActivity.shared
        // A second tap, or a screen opened while this lecture runs, must not start it again.
        guard !activity.isRunning(lecture) else {
            log.info("Process skipped: this lecture is already running")
            return
        }
        activity.set(PipelineStage(rawValue: lecture.stage)?.next ?? .audio, for: lecture)
        defer { activity.clear(for: lecture) }
        // The work runs in a task of its own that the activity keeps, so Stop can cancel it.
        let work = Task {
            await run(lecture: lecture, context: context, pageModel: pageModel, onProgress: onProgress)
        }
        activity.register(work, for: lecture)
        let beat = ProcessDiagnostics.heartbeat(label: "process")
        defer { beat.cancel() }
        await work.value
        log.info("Run ended stopping=\(activity.isStopping(lecture)) state=\(lecture.state, privacy: .public) stage=\(lecture.stage, privacy: .public)")
    }

    private static func run(
        lecture: Lecture,
        context: ModelContext,
        pageModel: ModelRole,
        onProgress: ((PipelineStage) -> Void)?
    ) async {
        let activity = PipelineActivity.shared
        func report(_ working: PipelineStage) async {
            activity.set(working, for: lecture)
            onProgress?(working)
            await Task.yield()
        }
        guard let course = lecture.course else {
            lecture.state = LectureState.failed.rawValue
            lecture.failureMessageKey = "Missing course."
            log.error("Process stopped: missing course.")
            return
        }
        SupertonicSpeech.unload()
        lecture.state = LectureState.processing.rawValue
        lecture.failureMessageKey = nil
        var stage = PipelineStage(rawValue: lecture.stage) ?? .idle
        if stage == .failed { stage = .idle }
        if stage == .ready {
            discardProcessedNotes(lecture, context: context)
            stage = .idle
        }
        log.info("Process start course=\(course.name, privacy: .public) stage=\(stage.rawValue, privacy: .public) audio=\(lecture.audioRelativePath ?? "none", privacy: .public) \(MemoryProbe.summary())")
        do {
            if stage == .idle || stage == .audio {
                try Task.checkCancellation()
                log.info("Stage audio \(MemoryProbe.summary())")
                await report(.audio)
                try await finishAudio(lecture)
                stage = .audio
                lecture.stage = stage.rawValue
                try context.save()
            }
            if stage == .audio {
                try Task.checkCancellation()
                log.info("Stage speakers \(MemoryProbe.summary())")
                await report(.speakers)
                try await finishSpeakers(lecture)
                stage = .speakers
                lecture.stage = stage.rawValue
                try context.save()
            }
            if stage == .speakers {
                try Task.checkCancellation()
                log.info("Stage transcript \(MemoryProbe.summary())")
                await report(.transcript)
                try await finishTranscript(lecture, course: course)
                stage = .transcript
                lecture.stage = stage.rawValue
                try context.save()
                log.info("Transcript blocks=\(lecture.blocks.count) \(MemoryProbe.summary())")
            }
            if stage == .transcript {
                try Task.checkCancellation()
                // The transcript is saved. Stopping here keeps it, and a later run resumes at the tags.
                guard await LocalModelRuntime.shared.hasTextModel() else {
                    log.error("Tags stopped: no text model is installed, the transcript is kept")
                    throw LocalModelError.notInstalled
                }
                log.info("Stage tags model=\(ModelCatalog.repo(for: pageModel), privacy: .public) \(MemoryProbe.summary())")
                await report(.tags)
                try await finishTags(lecture, course: course)
                try Task.checkCancellation()
                stage = .tags
                lecture.stage = stage.rawValue
                try context.save()
                log.info("Tags blocks=\(lecture.blocks.count) \(MemoryProbe.summary())")
            }
            if stage == .tags {
                try Task.checkCancellation()
                log.info("Stage page model=\(ModelCatalog.repo(for: pageModel), privacy: .public) \(MemoryProbe.summary())")
                await report(.page)
                await finishPage(lecture, course: course, context: context)
                await finishHeadline(lecture)
                // A stop during these two steps drops their half result.
                try Task.checkCancellation()
                stage = .page
                lecture.stage = stage.rawValue
                try context.save()
                log.info("AI correction characters=\(lecture.summary.count)")
            }
            if stage == .page {
                try Task.checkCancellation()
                log.info("Stage links")
                await report(.links)
                finishLinks(lecture, course: course, context: context)
                stage = .links
                lecture.stage = PipelineStage.ready.rawValue
                lecture.state = LectureState.ready.rawValue
                try context.save()
                await ReminderScheduler.notifyReady(course: course.name, startedAt: lecture.startedAt)
                log.info("Process ready \(MemoryProbe.summary())")
                await LocalModelRuntime.shared.unloadAll()
            }
        } catch where activity.isStopping(lecture) || error is CancellationError {
            // Stopped by the student. A step that fails because it was cancelled lands here too.
            log.info("Stop caught completed=\(stage.rawValue, privacy: .public) isStopping=\(activity.isStopping(lecture)) isCancelled=\(Task.isCancelled) errorType=\(String(describing: type(of: error)), privacy: .public) error=\(String(describing: error), privacy: .public)")
            await markStopped(lecture, completed: stage, context: context)
        } catch let error as TranscriptError {
            lecture.state = LectureState.failed.rawValue
            lecture.stage = stage.rawValue
            switch error {
            case .qualityFailed:
                lecture.failureMessageKey = "The transcript failed the quality check."
                lecture.neededModel = ModelRole.whisper.rawValue
            case .assetMissing:
                lecture.failureMessageKey = "The speech asset is not installed."
            case .unreadable:
                lecture.failureMessageKey = "The recording could not be read."
            case .whisperMissing:
                lecture.failureMessageKey = "A model is not available."
                lecture.neededModel = ModelRole.whisper.rawValue
            case .whisperNotWriting:
                lecture.failureMessageKey = "Whisper could not write the transcript."
                lecture.neededModel = nil
            }
            log.error("Transcript failed stage=\(stage.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
        } catch let error as LocalModelError {
            lecture.state = LectureState.failed.rawValue
            lecture.stage = stage.rawValue
            lecture.neededModel = pageModel.rawValue
            switch error {
            case .locked: lecture.failureMessageKey = "This model is locked on this device."
            case .notInstalled: lecture.failureMessageKey = "No AI model is installed. Download one in Settings, Models, then process again."
            case .loadFailed: lecture.failureMessageKey = "A model is not available."
            }
            log.error("Local model failed stage=\(stage.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
        } catch {
            lecture.state = LectureState.failed.rawValue
            lecture.stage = stage.rawValue
            let nsError = error as NSError
            if nsError.domain == "SFSpeechErrorDomain" {
                lecture.neededModel = nil
                log.error("Apple Speech failed (not a local model) stage=\(stage.rawValue, privacy: .public) code=\(nsError.code) message=\(error.localizedDescription, privacy: .public)")
            } else {
                lecture.neededModel = pageModel.rawValue
                log.error("Process failed stage=\(stage.rawValue, privacy: .public) type=\(String(describing: type(of: error)), privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code) message=\(error.localizedDescription, privacy: .public) detail=\(String(describing: error), privacy: .public)")
            }
            lecture.failureMessageKey = error.localizedDescription
        }
    }

    /// A lecture that is saved as "processing" while nothing runs it: the app was closed or killed in the middle of the
    /// run, or before a stop reached its end. It would stay "processing" for good. It goes back to paused at the last
    /// finished stage, so Process resumes it. Call it when the app opens, before anything shows the lectures.
    static func recoverInterrupted(context: ModelContext) {
        let processing = LectureState.processing.rawValue
        let descriptor = FetchDescriptor<Lecture>(predicate: #Predicate { $0.state == processing })
        do {
            let stuck = try context.fetch(descriptor).filter { !PipelineActivity.shared.isRunning($0) }
            guard !stuck.isEmpty else { return }
            for lecture in stuck {
                lecture.state = LectureState.paused.rawValue
                lecture.failureMessageKey = nil
                lecture.neededModel = nil
                log.info("Recovered an interrupted run stage=\(lecture.stage, privacy: .public)")
            }
            try context.save()
        } catch {
            log.error("Recover failed message=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// The run was stopped. The steps that finished stay, and Process resumes after them. The text of a
    /// step that was cut half way is dropped, so no half correction stays on the page.
    private static func markStopped(_ lecture: Lecture, completed: PipelineStage, context: ModelContext) async {
        let correctionDone = completed == .page || completed == .links || completed == .ready
        if !correctionDone {
            lecture.summary = ""
            if !lecture.titleEdited { lecture.title = "" }
        }
        lecture.stage = completed.rawValue
        lecture.state = LectureState.paused.rawValue
        lecture.failureMessageKey = nil
        lecture.neededModel = nil
        do {
            try context.save()
        } catch {
            log.error("Stop save failed message=\(error.localizedDescription, privacy: .public)")
        }
        await LocalModelRuntime.shared.unloadAll()
        log.info("Process stopped by the student, completed=\(completed.rawValue, privacy: .public)")
    }

    private static func finishAudio(_ lecture: Lecture) async throws {
        guard let path = lecture.audioRelativePath else { throw TranscriptError.unreadable }
        let url = try Vault.documents().appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw TranscriptError.unreadable }
    }

    static func discardProcessedNotes(_ lecture: Lecture, context: ModelContext) {
        let blockIDs = Set(lecture.blocks.map(\.token))
        if let course = lecture.course {
            for assignment in course.assignments where blockIDs.contains(assignment.sourceBlockID) {
                context.delete(assignment)
            }
        }
        for block in lecture.blocks {
            context.delete(block)
        }
        lecture.blocks.removeAll()
        lecture.summary = ""
        // The notes are written again, so the headline goes too, a typed one as well. Until the model
        // writes a new one, the bar shows the date.
        lecture.title = ""
        lecture.titleEdited = false
        lecture.speakerNames = []
        lecture.processedThroughSecond = 0
        lecture.failureMessageKey = nil
        lecture.neededModel = nil
        lecture.stage = PipelineStage.idle.rawValue
        lecture.state = LectureState.paused.rawValue
        do {
            try context.save()
        } catch {
            log.error("Discard save failed message=\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func finishSpeakers(_ lecture: Lecture) async throws {
        lecture.stage = PipelineStage.speakers.rawValue
    }

    private static func finishTranscript(_ lecture: Lecture, course: Course) async throws {
        let activity = PipelineActivity.shared
        guard let path = lecture.audioRelativePath else { throw TranscriptError.unreadable }
        let engine = SpeechEngine(rawValue: UserDefaults.standard.string(forKey: AppPreferences.speechEngineKey) ?? "") ?? .apple
        log.info("Transcript engine=\(engine.rawValue, privacy: .public)")
        let url = try Vault.documents().appendingPathComponent(path)
        let locale = Locale(identifier: course.localeIdentifier)
        // Telling the speakers apart comes first, so the bar must not say the text is being written.
        activity.setDetail(
            .init(
                fraction: PipelineStage.transcript.fraction,
                title: PipelineStage.speakers.title,
                info: PipelineStage.speakers.info
            ),
            for: lecture
        )
        let runs: [SpeechRun]
        do {
            runs = try await SpeakerPass.runs(url: url)
            log.info("Speaker runs count=\(runs.count)")
        } catch {
            log.error("Speaker pass failed message=\(error.localizedDescription, privacy: .public)")
            runs = []
        }
        SpeakerPass.release()
        let lines: [TranscriptLine]
        if engine == .whisper {
            guard WhisperASR.isInstalled() else { throw TranscriptError.whisperMissing }
            log.info("Whisper ASR writing")
            do {
                lines = try await WhisperASR.transcribe(url: url, locale: locale, runs: runs) { step in
                    activity.setDetail(whisperStep(step), for: lecture)
                }
            } catch let error as TranscriptError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.error("Whisper ASR failed message=\(error.localizedDescription, privacy: .public)")
                throw TranscriptError.whisperNotWriting
            }
        } else {
            lines = try await LectureTranscriber.transcribe(url: url, locale: locale, runs: runs)
        }
        lecture.blocks.removeAll()
        for line in lines {
            let block = Block(
                lecture: lecture,
                second: line.second,
                role: line.role,
                kind: .other,
                text: line.text,
                speaker: line.speaker
            )
            lecture.blocks.append(block)
        }
    }

    /// The bar inside the transcript stage: getting ready, loading, then writing.
    private static func whisperStep(_ step: WhisperASR.Step) -> PipelineActivity.Step {
        let base = PipelineStage.transcript.fraction
        let span = PipelineStage.tags.fraction - base
        switch step {
        case .preparing(let elapsed, let expected):
            // Core ML gives no progress while it compiles. The bar follows the time the last
            // compile took and never reaches the end before the work is done.
            let guess = min(0.95, Double(elapsed) / Double(max(expected, 1)))
            let note = String(localized: "Whisper is being set up for this phone. The first time takes a few minutes, later runs are quick. The ring is a guide from the last time, not a measurement.")
            return .init(
                fraction: base + span * (0.1 + 0.55 * guess),
                title: String(localized: "Preparing audio analysis"),
                info: "\(note) \(MediaClock.short(elapsed))"
            )
        case .loading:
            return .init(
                fraction: base + span * 0.75,
                title: String(localized: "Loading Whisper"),
                info: String(localized: "Whisper is being loaded into memory.")
            )
        case .writing(let done):
            let clamped = min(max(done, 0), 1)
            return .init(
                fraction: base + span * (0.8 + 0.2 * clamped),
                title: PipelineStage.transcript.title,
                info: PipelineStage.transcript.info
            )
        }
    }

    /// Windows between two saves of the tagging progress. A stop, a crash or a kill then loses at most this many.
    private static let tagSaveEvery = 10

    private static func finishTags(_ lecture: Lecture, course: Course) async throws {
        let source = lecture.blocks.sorted { $0.second < $1.second }
        let pending = source.filter { $0.second >= lecture.processedThroughSecond }
        let locale = Locale(identifier: course.localeIdentifier)
        var modelMissing = false
        var handled = 0
        log.info("Tags begin windows=\(pending.count) all=\(source.count) resumeSecond=\(lecture.processedThroughSecond) \(MemoryProbe.summary())")
        for block in pending {
            // A stop must not turn the windows that were never tagged into finished ones.
            try Task.checkCancellation()
            var tag: WindowTagging?
            // Logged before the call, so a window that never comes back is named in the log.
            log.info("Tag window=\(handled + 1) of=\(pending.count) second=\(block.second) speaker=\(block.speaker) role=\(block.role, privacy: .public) characters=\(block.text.count) \(MemoryProbe.summary())")
            do {
                // Without an installed model every window would fail the same way.
                guard !modelMissing else { throw LocalModelError.notInstalled }
                tag = try await LocalModelRuntime.shared.tag(window: block.text, locale: locale)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                if error as? LocalModelError == .notInstalled, !modelMissing {
                    modelMissing = true
                    log.error("Tagging skipped: no text model is installed, the raw words are kept")
                } else if !modelMissing {
                    log.error("Tag failed for one window, the raw words are kept second=\(block.second) message=\(error.localizedDescription, privacy: .public)")
                }
                block.kind = BlockKind.other.rawValue
            }
            if let tag {
                let spoken = block.text
                block.kind = BlockKind(tag: tag.kind).rawValue
                block.topics = TagKeep.topics(tag.topics, spoken: spoken)
                block.missing = tag.missing
                log.info("Tag keep kind=\(tag.kind, privacy: .public) missing=\(tag.missing) topics=\(tag.topics.joined(separator: ", "), privacy: .public) spoken=\(block.text, privacy: .public)")
                if tag.kind == BlockKind.reference.rawValue {
                    block.timeHintRaw = block.text
                }
            }
            lecture.processedThroughSecond = block.second
            handled += 1
            if handled % tagSaveEvery == 0 {
                // The blocks are changed in place, so this keeps every window done so far. A run that starts
                // again goes on from the last saved window.
                do {
                    try lecture.modelContext?.save()
                } catch {
                    log.error("Tag progress save failed window=\(handled) message=\(error.localizedDescription, privacy: .public)")
                }
                await LocalModelRuntime.shared.trimMemory(note: "tags \(handled) of \(pending.count)")
                log.info("Tag progress window=\(handled) of=\(pending.count) second=\(block.second)")
            }
        }
        // The speech of the room is not part of the notes.
        lecture.blocks = source.filter { $0.role != SpeakerRole.room.rawValue }
    }

    /// Writes the AI correction: the lecturer's words with correct spelling, punctuation and
    /// word order, important parts marked. Homework is collected from cue-bearing sentences in that
    /// text, then from gated `ASSIGNMENT:` lines. Apple's raw text stays untouched in the blocks.
    /// If a model is missing or its answer drifts, the raw words are kept and still scanned for cues.
    private static func finishPage(_ lecture: Lecture, course: Course, context: ModelContext) async {
        let spoken = lecture.blocks
            .sorted { $0.second < $1.second }
            .filter { $0.role != SpeakerRole.room.rawValue }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let lecturer = spoken.filter { $0.role == SpeakerRole.narrator.rawValue }
        let source = lecturer.isEmpty ? spoken : lecturer
        log.info("Correction source blocks=\(source.count) lecturerOnly=\(!lecturer.isEmpty)")
        var paragraphs: [String] = []
        var tasks: [String] = []
        let chunks = CorrectionText.chunks(source.map(\.text))
        let stageStarted = Date()
        log.info("Correction begin chunks=\(chunks.count) characters=\(chunks.reduce(0) { $0 + $1.count }) \(MemoryProbe.summary())")
        for (index, chunk) in chunks.enumerated() {
            let chunkStarted = Date()
            // One line per chunk when it ends, whether it passed, was rejected or failed.
            defer {
                log.info("Correction chunk \(index + 1) of \(chunks.count) seconds=\(Int(Date().timeIntervalSince(chunkStarted))) totalSeconds=\(Int(Date().timeIntervalSince(stageStarted))) \(MemoryProbe.summary())")
            }
            do {
                let output = try await LocalModelRuntime.shared.correct(
                    chunk,
                    lectureName: course.name,
                    localeIdentifier: course.localeIdentifier
                )
                let parts = CorrectionText.split(output)
                if let reason = parts.cutReason {
                    log.warning("Correction output cut chunk=\(index + 1) outputCharacters=\(output.count) reason=\(reason, privacy: .public)")
                }
                let faithful = CorrectionText.isFaithful(parts.body, to: chunk)
                let kept = CorrectionText.overlap(chunk, CorrectionText.plain(parts.body))
                log.info("Correction check faithful=\(faithful) sourceCharacters=\(chunk.count) bodyCharacters=\(CorrectionText.plain(parts.body).count) wordsKept=\(kept) assignments=\(parts.assignments.count) highlights=\(parts.body.components(separatedBy: "**").count / 2)")
                log.info("Correction body=\(parts.body, privacy: .public)")
                if faithful {
                    paragraphs.append(parts.body)
                    // Primary: sentences that already hold a homework cue. Secondary: ASSIGNMENT lines from the
                    // model, kept only when their words are from the text and a cue stands near them. On overlap
                    // the rule sentence wins, so a rewritten or merged model task does not replace the teacher.
                    let ruleTasks = CorrectionText.homeworkSentences(in: parts.body)
                    let spokenTasks = parts.assignments.filter { task in
                        let overlap = CorrectionText.overlap(task, chunk)
                        let cue = CorrectionText.hasHomeworkCue(near: task, in: chunk)
                        log.info("Assignment check kept=\(overlap >= 0.6 && cue) wordsFromText=\(overlap) cueNearTask=\(cue) task=\(task, privacy: .public)")
                        return overlap >= 0.6 && cue
                    }
                    if spokenTasks.count < parts.assignments.count {
                        log.warning("Assignment dropped count=\(parts.assignments.count - spokenTasks.count) of \(parts.assignments.count), no homework cue near the task or the words are not from the text")
                    }
                    let merged = CorrectionText.mergeTasks(fromRules: ruleTasks, fromModel: spokenTasks)
                    log.info("Assignment merge rules=\(ruleTasks.count) model=\(spokenTasks.count) kept=\(merged.count)")
                    for sentence in ruleTasks {
                        log.info("Assignment rule sentence=\(sentence, privacy: .public)")
                    }
                    tasks.append(contentsOf: merged)
                } else {
                    log.warning("Correction rejected, keeping the raw words")
                    paragraphs.append(chunk)
                    let ruleTasks = CorrectionText.homeworkSentences(in: chunk)
                    log.info("Assignment merge rules=\(ruleTasks.count) model=0 kept=\(ruleTasks.count)")
                    for sentence in ruleTasks {
                        log.info("Assignment rule sentence=\(sentence, privacy: .public)")
                    }
                    tasks.append(contentsOf: ruleTasks)
                }
            } catch {
                log.error("Correction failed, keeping the raw words message=\(error.localizedDescription, privacy: .public)")
                paragraphs.append(chunk)
                let ruleTasks = CorrectionText.homeworkSentences(in: chunk)
                log.info("Assignment merge rules=\(ruleTasks.count) model=0 kept=\(ruleTasks.count)")
                for sentence in ruleTasks {
                    log.info("Assignment rule sentence=\(sentence, privacy: .public)")
                }
                tasks.append(contentsOf: ruleTasks)
            }
        }
        lecture.summary = paragraphs.joined(separator: "\n\n")
        log.info("Correction final characters=\(lecture.summary.count) paragraphs=\(paragraphs.count) tasks=\(tasks.count) seconds=\(Int(Date().timeIntervalSince(stageStarted)))")
        addAssignments(tasks, lecture: lecture, course: course, source: source, context: context)
    }

    /// Writes the headline of the lecture from its AI correction. A title the student typed is kept.
    /// If the model fails or its words are not from the text, the lecture just has no headline.
    private static func finishHeadline(_ lecture: Lecture) async {
        guard !lecture.titleEdited else { return }
        let text = CorrectionText.plain(lecture.summary).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            let raw = try await LocalModelRuntime.shared.headline(for: String(text.prefix(3000)))
            if let headline = CorrectionText.headline(raw, from: text) {
                lecture.title = headline
                log.info("Headline kept characters=\(headline.count)")
            } else {
                log.warning("Headline rejected, the lecture has no headline")
            }
        } catch {
            log.error("Headline failed, the lecture has no headline message=\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func addAssignments(
        _ tasks: [String],
        lecture: Lecture,
        course: Course,
        source: [Block],
        context: ModelContext
    ) {
        guard !source.isEmpty else { return }
        let tokens = Set(lecture.blocks.map(\.token))
        var known = course.assignments.filter { tokens.contains($0.sourceBlockID) }.map(\.text)
        for task in tasks {
            guard !known.contains(where: { CorrectionText.overlap(task, $0) >= 0.6 }) else { continue }
            guard let block = source.max(by: {
                CorrectionText.overlap(task, $0.text) < CorrectionText.overlap(task, $1.text)
            }) else { continue }
            let due = Assignment.dueDate(for: task, lecture: lecture)
                ?? Assignment.dueDate(for: block.text, lecture: lecture)
            context.insert(Assignment(
                course: course,
                text: task,
                due: due,
                sourceBlockID: block.token,
                sourceSecond: block.second
            ))
            known.append(task)
            log.info("Assignment added text=\(task, privacy: .public)")
        }
    }

    private static func finishLinks(_ lecture: Lecture, course: Course, context: ModelContext) {
        let aliases = course.aliases.map { ($0.left, $0.right) }
        let prior = course.lectures
            .filter { $0.startedAt < lecture.startedAt }
            .flatMap(\.blocks)
        for block in lecture.blocks where block.kind == BlockKind.reference.rawValue || block.kind == BlockKind.examScope.rawValue {
            let hint = block.timeHintRaw.flatMap(TimeHint.parse)
            let current = BindableBlock(
                id: block.token,
                courseId: course.token,
                at: lecture.startedAt.addingTimeInterval(TimeInterval(block.second)),
                topics: block.topics
            )
            let notes = prior.map { other in
                BindableBlock(
                    id: other.token,
                    courseId: course.token,
                    at: (other.lecture?.startedAt ?? .distantPast).addingTimeInterval(TimeInterval(other.second)),
                    topics: other.topics
                )
            }
            let link = Linker.bind(current, in: notes, timeHint: hint, aliases: aliases)
            let stored = NoteLink(from: block, toBlockID: link.to, why: link.why)
            block.outgoing.append(stored)
            context.insert(stored)
        }
        // Assignments are not made here. `finishPage` collects them: cue-bearing sentences first, then
        // gated ASSIGNMENT lines from the model, merged so the teacher's wording wins.
    }
}

private enum TagKeep {
    static func sentence(_ candidate: String, spoken: String) -> String {
        let proposed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let spokenCount = words(spoken).count
        let proposedCount = words(proposed).count
        guard proposedCount >= max(4, spokenCount / 2), shares(proposed, spoken) else { return spoken }
        return proposed
    }

    static func topics(_ topics: [String], spoken: String) -> [String] {
        topics.filter { topic in
            let folded = topic.lowercased()
            guard !folded.contains("asr_text"), !folded.contains("astr_text") else { return false }
            return shares(topic, spoken)
        }
    }

    private static func shares(_ candidate: String, _ spoken: String) -> Bool {
        let left = words(candidate)
        let right = words(spoken)
        guard !left.isEmpty else { return false }
        let hits = left.filter { right.contains($0) }.count
        return hits * 2 >= left.count
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
    }
}
