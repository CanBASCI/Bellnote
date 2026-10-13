import Foundation
import OSLog
import SwiftData

@MainActor
enum LecturePipeline {
    private static let log = Logger(subsystem: "app.bellnote", category: "pipeline")

    static func advance(
        lecture: Lecture,
        context: ModelContext,
        preferTaggerForPage: Bool,
        onProgress: ((PipelineStage) -> Void)? = nil
    ) async {
        func report(_ working: PipelineStage) async {
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
        log.info("Process start course=\(course.name, privacy: .public) stage=\(stage.rawValue, privacy: .public) audio=\(lecture.audioRelativePath ?? "none", privacy: .public)")
        do {
            if stage == .idle || stage == .audio {
                log.info("Stage audio")
                await report(.audio)
                try await finishAudio(lecture)
                stage = .audio
                lecture.stage = stage.rawValue
                try context.save()
            }
            if stage == .audio {
                log.info("Stage speakers")
                await report(.speakers)
                try await finishSpeakers(lecture)
                stage = .speakers
                lecture.stage = stage.rawValue
                try context.save()
            }
            if stage == .speakers {
                log.info("Stage transcript")
                await report(.transcript)
                try await finishTranscript(lecture, course: course)
                stage = .transcript
                lecture.stage = stage.rawValue
                try context.save()
                log.info("Transcript blocks=\(lecture.blocks.count)")
            }
            if stage == .transcript {
                log.info("Stage tags model=\(ModelCatalog.taggerRepo, privacy: .public)")
                await report(.tags)
                try await finishTags(lecture, course: course)
                stage = .tags
                lecture.stage = stage.rawValue
                try context.save()
                log.info("Tags blocks=\(lecture.blocks.count)")
            }
            if stage == .tags {
                log.info("Stage page preferTagger=\(preferTaggerForPage) model=\(preferTaggerForPage ? ModelCatalog.taggerRepo : ModelCatalog.pageRepo, privacy: .public)")
                await report(.page)
                await finishPage(lecture, course: course, context: context)
                stage = .page
                lecture.stage = stage.rawValue
                try context.save()
                log.info("AI correction characters=\(lecture.summary.count)")
            }
            if stage == .page {
                log.info("Stage links")
                await report(.links)
                finishLinks(lecture, course: course, context: context)
                stage = .links
                lecture.stage = PipelineStage.ready.rawValue
                lecture.state = LectureState.ready.rawValue
                try context.save()
                await ReminderScheduler.notifyReady(course: course.name, startedAt: lecture.startedAt)
                log.info("Process ready")
                await LocalModelRuntime.shared.unloadAll()
            }
        } catch let error as TranscriptError {
            lecture.state = LectureState.failed.rawValue
            lecture.stage = stage.rawValue
            switch error {
            case .qualityFailed:
                lecture.failureMessageKey = "The transcript failed the quality check."
                lecture.neededModel = ModelRole.asr.rawValue
            case .assetMissing:
                lecture.failureMessageKey = "The speech asset is not installed."
            case .unreadable:
                lecture.failureMessageKey = "The recording could not be read."
            case .qwenMissing:
                lecture.failureMessageKey = "A model is not available."
                lecture.neededModel = ModelRole.asr.rawValue
            case .qwenNotWriting:
                lecture.failureMessageKey = "Qwen ASR cannot write yet."
                lecture.neededModel = nil
            }
            log.error("Transcript failed stage=\(stage.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
        } catch let error as LocalModelError {
            lecture.state = LectureState.failed.rawValue
            lecture.stage = stage.rawValue
            lecture.neededModel = (stage == .transcript || stage == .tags) ? ModelRole.tagger.rawValue : ModelRole.page.rawValue
            lecture.failureMessageKey = error == .locked ? "This model is locked on this device." : "A model is not available."
            log.error("Local model failed stage=\(stage.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
        } catch {
            lecture.state = LectureState.failed.rawValue
            lecture.stage = stage.rawValue
            let nsError = error as NSError
            if nsError.domain == "SFSpeechErrorDomain" {
                lecture.neededModel = nil
                log.error("Apple Speech failed (not the 2B/4B model) stage=\(stage.rawValue, privacy: .public) code=\(nsError.code) message=\(error.localizedDescription, privacy: .public)")
            } else {
                lecture.neededModel = (stage == .page || stage == .links) ? ModelRole.page.rawValue : ModelRole.tagger.rawValue
                log.error("Process failed stage=\(stage.rawValue, privacy: .public) type=\(String(describing: type(of: error)), privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code) message=\(error.localizedDescription, privacy: .public) detail=\(String(describing: error), privacy: .public)")
            }
            lecture.failureMessageKey = error.localizedDescription
        }
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
        lecture.speakerNames = []
        lecture.processedThroughSecond = 0
        lecture.failureMessageKey = nil
        lecture.neededModel = nil
        lecture.stage = PipelineStage.idle.rawValue
        lecture.state = LectureState.paused.rawValue
        try? context.save()
    }

    private static func finishSpeakers(_ lecture: Lecture) async throws {
        lecture.stage = PipelineStage.speakers.rawValue
    }

    private static func finishTranscript(_ lecture: Lecture, course: Course) async throws {
        guard let path = lecture.audioRelativePath else { throw TranscriptError.unreadable }
        let engine = SpeechEngine(rawValue: UserDefaults.standard.string(forKey: AppPreferences.speechEngineKey) ?? "") ?? .apple
        let qwenReady = await LocalModelRuntime.shared.probe(.asr).isReady
        log.info("Transcript engine=\(engine.rawValue, privacy: .public) qwenReady=\(qwenReady)")
        let url = try Vault.documents().appendingPathComponent(path)
        let locale = Locale(identifier: course.localeIdentifier)
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
        if engine == .qwen {
            guard qwenReady else { throw TranscriptError.qwenMissing }
            log.info("Qwen ASR writing")
            do {
                lines = try await QwenASR.transcribe(url: url, locale: locale, runs: runs)
            } catch let error as TranscriptError {
                throw error
            } catch {
                log.error("Qwen ASR failed message=\(error.localizedDescription, privacy: .public)")
                throw TranscriptError.qwenNotWriting
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

    private static func finishTags(_ lecture: Lecture, course: Course) async throws {
        let source = lecture.blocks.sorted { $0.second < $1.second }
        var tagged: [Block] = []
        let locale = Locale(identifier: course.localeIdentifier)
        for block in source where block.second >= lecture.processedThroughSecond {
            let tag: WindowTag
            do {
                tag = try await LocalModelRuntime.shared.tag(window: block.text, locale: locale)
            } catch {
                block.kind = BlockKind.other.rawValue
                tagged.append(block)
                lecture.processedThroughSecond = block.second
                continue
            }
            let spoken = block.text
            block.kind = BlockKind(tag: tag.kind).rawValue
            block.topics = TagKeep.topics(tag.topics, spoken: spoken)
            block.listItems = TagKeep.items(tag.listItems, spoken: spoken)
            block.numbers = TagKeep.numbers(tag.numbers, spoken: spoken)
            block.importance = tag.importanceCue
            block.missing = tag.missing
            log.info("Tag keep model=\(tag.text, privacy: .public) spoken=\(block.text, privacy: .public)")
            if tag.kind == BlockKind.reference.rawValue || tag.kind == BlockKind.assignment.rawValue {
                block.timeHintRaw = block.text
                block.dueHintRaw = block.text
            }
            if block.role == SpeakerRole.room.rawValue {
                continue
            }
            tagged.append(block)
            lecture.processedThroughSecond = block.second
        }
        lecture.blocks = tagged.isEmpty ? source.filter { $0.role != SpeakerRole.room.rawValue } : tagged
    }

    /// Writes the AI correction: the lecturer's words with correct spelling, punctuation and
    /// word order, important parts marked, homework collected. Apple's raw text stays untouched
    /// in the blocks. If a model is missing or its answer drifts, the raw words are kept.
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
        for chunk in CorrectionText.chunks(source.map(\.text)) {
            do {
                let output = try await LocalModelRuntime.shared.correct(chunk)
                let parts = CorrectionText.split(output)
                let faithful = CorrectionText.isFaithful(parts.body, to: chunk)
                let kept = CorrectionText.overlap(chunk, CorrectionText.plain(parts.body))
                log.info("Correction check faithful=\(faithful) sourceCharacters=\(chunk.count) bodyCharacters=\(CorrectionText.plain(parts.body).count) wordsKept=\(kept) assignments=\(parts.assignments.count) highlights=\(parts.body.components(separatedBy: "**").count / 2)")
                log.info("Correction body=\(parts.body, privacy: .public)")
                if faithful {
                    paragraphs.append(parts.body)
                    // A task must be made of words the teacher said, otherwise the model invented it.
                    // A real homework also needs a word like "ödev" or "teslim" in the spoken text.
                    let cue = CorrectionText.hasHomeworkCue(chunk)
                    let spokenTasks = parts.assignments.filter { cue && CorrectionText.overlap($0, chunk) >= 0.6 }
                    if spokenTasks.count < parts.assignments.count {
                        log.warning("Assignment dropped count=\(parts.assignments.count - spokenTasks.count) homeworkCue=\(cue)")
                    }
                    tasks.append(contentsOf: spokenTasks)
                } else {
                    log.warning("Correction rejected, keeping the raw words")
                    paragraphs.append(chunk)
                }
            } catch {
                log.error("Correction failed, keeping the raw words message=\(error.localizedDescription, privacy: .public)")
                paragraphs.append(chunk)
            }
        }
        lecture.summary = paragraphs.joined(separator: "\n\n")
        log.info("Correction final characters=\(lecture.summary.count) paragraphs=\(paragraphs.count) tasks=\(tasks.count)")
        addAssignments(tasks, lecture: lecture, course: course, source: source, context: context)
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
            let hint = DueDateMath.parse(task)
            let due = hint.map { DueDateMath.due(from: lecture.startedAt, hint: $0) }
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
        let blockIDs = Set(lecture.blocks.map(\.token))
        for block in lecture.blocks where block.kind == BlockKind.assignment.rawValue {
            let existing = course.assignments.filter { blockIDs.contains($0.sourceBlockID) }
            if existing.contains(where: { CorrectionText.overlap(block.text, $0.text) >= 0.5 }) { continue }
            let hint = block.dueHintRaw.flatMap { DueDateMath.parse($0) }
            let due = hint.map { DueDateMath.due(from: lecture.startedAt, hint: $0) }
            let assignment = Assignment(
                course: course,
                text: block.text,
                due: due,
                sourceBlockID: block.token,
                sourceSecond: block.second
            )
            context.insert(assignment)
        }
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

    static func items(_ items: [String], spoken: String) -> [String] {
        items.filter { shares($0, spoken) }
    }

    static func numbers(_ numbers: [Double], spoken: String) -> [Double] {
        let ints = numbers.map { Int($0.rounded()) }
        if ints.count >= 4 {
            let steps = zip(ints, ints.dropFirst()).filter { $1 == $0 + 1 }.count
            if steps >= ints.count - 1 { return [] }
        }
        return numbers.filter { spoken.contains(String(Int($0.rounded()))) }
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
