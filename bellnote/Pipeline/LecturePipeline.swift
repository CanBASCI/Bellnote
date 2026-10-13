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
                try await finishPage(lecture, preferTagger: preferTaggerForPage)
                stage = .page
                lecture.stage = stage.rawValue
                try context.save()
                log.info("Page summary characters=\(lecture.summary.count)")
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
        let lines = try await LectureTranscriber.transcribe(url: url, locale: locale, runs: runs)
        lecture.blocks.removeAll()
        for line in lines {
            let block = Block(
                lecture: lecture,
                second: line.second,
                role: line.role,
                kind: .other,
                text: line.text
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
            block.kind = BlockKind(tag: tag.kind).rawValue
            block.text = tag.text
            block.topics = tag.topics
            block.listItems = tag.listItems
            block.numbers = tag.numbers
            block.importance = tag.importanceCue
            block.missing = tag.missing
            block.role = SpeakerRole(rawValue: tag.speakerRole)?.rawValue ?? block.role
            if tag.kind == BlockKind.reference.rawValue || tag.kind == BlockKind.assignment.rawValue {
                block.timeHintRaw = tag.text
                block.dueHintRaw = tag.text
            }
            if block.role == SpeakerRole.room.rawValue {
                continue
            }
            tagged.append(block)
            lecture.processedThroughSecond = block.second
        }
        lecture.blocks = tagged.isEmpty ? source.filter { $0.role != SpeakerRole.room.rawValue } : tagged
    }

    private static func finishPage(_ lecture: Lecture, preferTagger: Bool) async throws {
        let tags = lecture.blocks.map { block in
            WindowTag(
                language: "",
                speakerRole: block.role,
                kind: block.kind,
                topics: block.topics,
                text: block.text,
                listItems: block.listItems,
                numbers: block.numbers,
                importanceCue: block.importance,
                missing: block.missing
            )
        }
        let role: ModelRole = preferTagger ? .tagger : .page
        if role == .tagger {
            lecture.summary = tags.map(\.text).joined(separator: "\n")
            return
        }
        lecture.summary = try await LocalModelRuntime.shared.compose(
            tags: tags,
            task: "Write a short page summary. Every claim must come from the notes."
        )
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
        for block in lecture.blocks where block.kind == BlockKind.assignment.rawValue {
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
