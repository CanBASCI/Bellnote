import Foundation
import FoundationModels
import HuggingFace
import MLX
import MLXFoundationModels
import MLXLLM
import MLXLMCommon
import OSLog
import Tokenizers

enum LocalModelError: Error, Equatable {
    case notInstalled
    case locked
    case loadFailed
}

actor LocalModelRuntime {
    static let shared = LocalModelRuntime()
    nonisolated private static let log = Logger(subsystem: "app.bellnote", category: "model")

    private var resident: ModelRole?
    private var activeCalls = 0
    private var idleTask: Task<Void, Never>?
    private static let idleSeconds = 45
    private let gate = ModelGate()

    func reset() async {
        await evictResident()
        Self.log.info("Model reset")
    }

    /// Frees the loaded text model. Skipped while a call is running.
    func unloadAll() async {
        guard activeCalls == 0, resident != nil else { return }
        await evictResident()
        Self.log.info("Models unloaded")
    }

    /// `gate.unload()` only changes bookkeeping. The weights stay in MLX's cache until evicted.
    private func evictResident() async {
        idleTask?.cancel()
        idleTask = nil
        await MLXLanguageModel.evictAll()
        Memory.clearCache()
        await gate.unload()
        resident = nil
        Self.log.info("Memory after evict \(MemoryProbe.summary())")
    }

    /// Runs one model call so that an MLX error is thrown to the caller and does not stop the app.
    /// After an error the loaded model is dropped, because its state can no longer be trusted.
    /// The next call loads it again.
    /// `work` is `@Sendable` because MLX runs it away from this actor. It only captures a session
    /// (`LanguageModelSession` is Sendable) and strings.
    private func guarded<T>(_ work: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await withError(work)
        } catch let error as MLXError {
            Self.log.error("MLX error, the model is dropped message=\(error.localizedDescription, privacy: .public) footprintMB=\(MemoryProbe.footprintMB())")
            await evictResident()
            throw error
        }
    }

    /// Between two windows: gives the MLX buffer cache back and writes the memory use to the log.
    func trimMemory(note: String) {
        guard activeCalls == 0 else { return }
        Memory.clearCache()
        Self.log.info("Memory trimmed note=\(note, privacy: .public) \(MemoryProbe.summary())")
    }

    private func beginCall() {
        activeCalls += 1
        idleTask?.cancel()
        idleTask = nil
    }

    private func endCall() {
        activeCalls -= 1
        guard activeCalls == 0 else { return }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleSeconds))
            guard !Task.isCancelled else { return }
            await self?.unloadAll()
        }
    }

    func tag(window: String, locale: Locale) async throws -> WindowTagging {
        beginCall()
        defer { endCall() }
        let role = try composeRole()
        Self.log.info("Tag begin characters=\(window.count) locale=\(locale.identifier, privacy: .public) role=\(role.rawValue, privacy: .public)")
        do {
            try await ensure(role)
            let session = try makeSession(role: role, instructions: tagInstructions)
            let language = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            let response = try await guarded {
                try await session.respond(
                    to: "Lecture language: \(language). Do not translate.\n\n\(window)",
                    generating: WindowTagging.self,
                    options: GenerationOptions(maximumResponseTokens: 256)
                )
            }
            if TagValidator.validate(response.content) {
                Self.log.info("Tag ok kind=\(response.content.kind, privacy: .public)")
                return response.content
            }
            Self.log.warning("Tag invalid, retrying")
            let retry = try await guarded {
                try await session.respond(
                    to: "Lecture language: \(language). Do not translate.\n\n\(window)",
                    generating: WindowTagging.self,
                    options: GenerationOptions(maximumResponseTokens: 256)
                )
            }
            guard TagValidator.validate(retry.content) else {
                Self.log.error("Tag retry invalid")
                throw LocalModelError.loadFailed
            }
            Self.log.info("Tag retry ok kind=\(retry.content.kind, privacy: .public)")
            return retry.content
        } catch {
            Self.log.error("Tag failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func compose(tags: [WindowTag], task: String) async throws -> String {
        beginCall()
        defer { endCall() }
        let role = try composeRole()
        Self.log.info("Compose begin tags=\(tags.count) role=\(role.rawValue, privacy: .public)")
        do {
            try await ensure(role)
            let session = try makeSession(role: role, instructions: pageInstructions)
            let source = tags.map(\.text).joined(separator: "\n")
            let response = try await guarded { try await session.respond(to: "\(task)\n\n\(source)") }
            Self.log.info("Compose ok characters=\(response.content.count)")
            return response.content
        } catch {
            Self.log.error("Compose failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Rewrites dictated text with correct spelling, punctuation and word order.
    /// The model marks important parts with ** and lists homework as ASSIGNMENT lines.
    func correct(_ text: String, lectureName: String, localeIdentifier: String) async throws -> String {
        beginCall()
        defer { endCall() }
        let role = try composeRole()
        Self.log.info("Correct begin characters=\(text.count) role=\(role.rawValue, privacy: .public) input=\(text, privacy: .public)")
        do {
            try await ensure(role)
            let instructions = correctionInstructions(lectureName: lectureName, localeIdentifier: localeIdentifier)
            let session = try makeSession(role: role, instructions: instructions)
            let limit = min(1500, text.count / 2 + 300)
            let started = Date()
            let response = try await guarded {
                try await session.respond(
                    to: "Text:\n\(text)\n\nCorrected text:",
                    options: GenerationOptions(temperature: 0, maximumResponseTokens: limit)
                )
            }
            let output = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.log.info("Correct ok characters=\(output.count) inputCharacters=\(text.count) tokenLimit=\(limit) modelSeconds=\(String(format: "%.1f", Date().timeIntervalSince(started))) text=\(output, privacy: .public)")
            return output
        } catch {
            Self.log.error("Correct failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Writes a short headline for a lecture from its corrected text. The caller checks that the words
    /// of the headline come from the text.
    func headline(for text: String) async throws -> String {
        beginCall()
        defer { endCall() }
        let role = try composeRole()
        Self.log.info("Headline begin characters=\(text.count) role=\(role.rawValue, privacy: .public)")
        do {
            try await ensure(role)
            let session = try makeSession(role: role, instructions: headlineInstructions)
            let response = try await guarded {
                try await session.respond(
                    to: "Text:\n\(text)\n\nHeadline:",
                    options: GenerationOptions(temperature: 0, maximumResponseTokens: 80)
                )
            }
            let output = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.log.info("Headline ok characters=\(output.count) text=\(output, privacy: .public)")
            return output
        } catch {
            Self.log.error("Headline failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Answers one question from the notes. The notes come first and the question last,
    /// otherwise a small model copies the notes back instead of answering.
    func answer(question: String, tags: [WindowTag]) async throws -> String {
        beginCall()
        defer { endCall() }
        let role = try composeRole()
        let started = Date()
        Self.log.info("Answer begin tags=\(tags.count) role=\(role.rawValue, privacy: .public) footprintMB=\(MemoryProbe.footprintMB())")
        // The model call is silent while it reads the notes. This line says every 15 seconds that it still runs,
        // how much memory it uses and how warm the phone is.
        let heartbeat = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                Self.log.info("Answer still working seconds=\(Int(Date().timeIntervalSince(started))) footprintMB=\(MemoryProbe.footprintMB()) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
            }
        }
        defer { heartbeat.cancel() }
        do {
            try await ensure(role)
            Self.log.info("Answer model ready seconds=\(Int(Date().timeIntervalSince(started))) footprintMB=\(MemoryProbe.footprintMB())")
            let session = try makeSession(role: role, instructions: answerInstructions)
            let source = tags.map(\.text).joined(separator: "\n")
            Self.log.info("Answer question=\(question, privacy: .public) notesCharacters=\(source.count) notesHead=\(String(source.prefix(200)), privacy: .public)")
            let response = try await guarded {
                try await session.respond(
                    to: "Notes:\n\(source)\n\nQuestion: \(question)\nShort answer:",
                    options: GenerationOptions(maximumResponseTokens: 120)
                )
            }
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.log.info("Answer ok seconds=\(Int(Date().timeIntervalSince(started))) footprintMB=\(MemoryProbe.footprintMB()) characters=\(text.count) text=\(text, privacy: .public)")
            return text
        } catch {
            Self.log.error("Answer failed seconds=\(Int(Date().timeIntervalSince(started))) footprintMB=\(MemoryProbe.footprintMB()) message=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func repoID(_ role: ModelRole) -> String {
        ModelCatalog.repo(for: role)
    }

    func probe(_ role: ModelRole) -> HubWeights.Snapshot {
        let repo = repoID(role)
        var snapshot = HubWeights.snapshot(for: repo)
        if role == .whisper {
            snapshot = WhisperASR.snapshot()
        }
        Self.log.info(
            "Probe role=\(role.rawValue, privacy: .public) repo=\(snapshot.repo, privacy: .public) path=\(snapshot.path, privacy: .public) directory=\(snapshot.directoryExists) config=\(snapshot.hasConfig) safetensors=\(snapshot.safetensorsCount) files=\(snapshot.fileCount) bytes=\(snapshot.bytes) names=\(snapshot.fileNames.joined(separator: ","), privacy: .public)"
        )
        return snapshot
    }

    func download(
        _ role: ModelRole,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onPreparing: (@Sendable () -> Void)? = nil
    ) async throws {
        let repo = repoID(role)
        Self.log.info("Download tapped role=\(role.rawValue, privacy: .public) repo=\(repo, privacy: .public)")
        _ = probe(role)
        if role == .whisper {
            try await WhisperASR.download(onProgress: onProgress, onPreparing: onPreparing)
            _ = probe(role)
            return
        }
        do {
            let model = try makeModel(role, onProgress: onProgress)
            let available = await model.isAvailable
            Self.log.info("Availability before preload role=\(role.rawValue, privacy: .public) available=\(available)")
            onProgress?(0)
            try await model.preload()
            onProgress?(1)
            try await ensure(role)
            let after = probe(role)
            let availableAfter = await model.isAvailable
            Self.log.info("Download finished role=\(role.rawValue, privacy: .public) available=\(availableAfter) bytes=\(after.bytes) config=\(after.hasConfig) safetensors=\(after.safetensorsCount)")
        } catch {
            let nsError = error as NSError
            _ = probe(role)
            Self.log.error("Download failed role=\(role.rawValue, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code) message=\(error.localizedDescription, privacy: .public) detail=\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func delete(_ role: ModelRole) async throws {
        let repo = repoID(role)
        Self.log.info("Delete tapped role=\(role.rawValue, privacy: .public) repo=\(repo, privacy: .public)")
        if resident == role {
            await evictResident()
        }
        if role == .whisper {
            try WhisperASR.remove()
        } else {
            try HubWeights.remove(repo)
        }
        _ = probe(role)
        Self.log.info("Delete finished role=\(role.rawValue, privacy: .public)")
    }

    func isInstalled(_ role: ModelRole) -> Bool {
        probe(role).isReady
    }

    /// True when at least one text model (2B or 4B) is on the device.
    func hasTextModel() -> Bool {
        isInstalled(.tagger) || isInstalled(.page)
    }

    func cancel(lecture id: UUID) async {
        await gate.cancel(lecture: id)
        resident = nil
    }

    /// The installed model the user picked. Tags, page, correction and Ask all use it.
    /// A missing model is never downloaded from here.
    private func composeRole() throws -> ModelRole {
        let preferred = AppPreferences.pageModel()
        if isInstalled(preferred) { return preferred }
        for role in [ModelRole.tagger, .page] where isInstalled(role) {
            return role
        }
        throw LocalModelError.notInstalled
    }

    private func ensure(_ role: ModelRole) async throws {
        guard isInstalled(role) else {
            Self.log.error("Model is not installed role=\(role.rawValue, privacy: .public)")
            throw LocalModelError.notInstalled
        }
        if let loaded = resident, loaded != role {
            Self.log.info("Unload \(loaded.rawValue, privacy: .public) before \(role.rawValue, privacy: .public)")
            await evictResident()
        }
        if resident == role {
            Self.log.info("Model already resident role=\(role.rawValue, privacy: .public)")
            return
        }
        Self.log.info("Ensure role=\(role.rawValue, privacy: .public) \(MemoryProbe.summary())")
        Memory.cacheLimit = 128 * 1_024 * 1_024
        SupertonicSpeech.unload()
        switch role {
        case .tagger:
            await gate.loadTagger()
        case .page:
            await gate.loadPage()
        case .whisper:
            throw LocalModelError.notInstalled
        }
        resident = role
    }

    private func makeSession(role: ModelRole, instructions: String) throws -> LanguageModelSession {
        guard isInstalled(role) else {
            Self.log.error("Refusing to fetch a model that was not downloaded role=\(role.rawValue, privacy: .public)")
            throw LocalModelError.notInstalled
        }
        return LanguageModelSession(model: try makeModel(role), tools: [], instructions: instructions)
    }

    /// Generation stops the moment the model writes one of these. They are labels a small model puts in front of its
    /// own remarks ("Düzeltme: …", "*Sonuç:* …") or the start of the next example block ("Text: …"). The lecture text
    /// comes before them, so nothing the student needs is lost, and the model does not write comments until the token
    /// limit. Each one starts on a new line, so a word in the middle of a sentence never matches.
    private static let stopStrings: Set<String> = {
        let labels = [
            "Düzeltme", "Düzeltmeler", "Düzeltilmiş metin", "Geri çekme", "Sonuç", "Açıklama", "Not", "Notlar",
            "Correction", "Corrections", "Corrected text", "Result", "Explanation", "Note", "Notes", "Text",
        ]
        var strings = Set<String>()
        for label in labels {
            strings.insert("\n\(label):")
            strings.insert("\n*\(label):")
        }
        return strings
    }()

    private func makeModel(
        _ role: ModelRole,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws -> MLXLanguageModel {
        guard role.isTextModel else { throw LocalModelError.notInstalled }
        let repo = ModelCatalog.repo(for: role)
        let disk = HubWeights.snapshot(for: repo)
        Self.log.info("Make model role=\(role.rawValue, privacy: .public) repo=\(disk.repo, privacy: .public) path=\(disk.path, privacy: .public) bytes=\(disk.bytes) config=\(disk.hasConfig) safetensors=\(disk.safetensorsCount)")
        let configuration = ModelConfiguration(id: repo, stopStrings: Self.stopStrings)
        Self.log.info("Make model stop strings count=\(Self.stopStrings.count)")
        let model = MLXLanguageModel(
            configuration: configuration,
            capabilities: [.guidedGeneration],
            weightsLocation: { id in
                HubWeights.directory(for: id)
            },
            load: { configuration, progressHandler in
                Self.log.info("Load container repo=\(configuration.name, privacy: .public)")
                do {
                    let container = try await loadModelContainer(
                        from: HubSnapshotDownloader(),
                        using: HuggingFaceTokenizerLoader(),
                        configuration: configuration,
                        progressHandler: { progress in
                            if progress.fractionCompleted == 0 || progress.isFinished || Int(progress.fractionCompleted * 100) % 10 == 0 {
                                Self.log.info("Load progress repo=\(configuration.name, privacy: .public) fraction=\(progress.fractionCompleted)")
                            }
                            onProgress?(progress.fractionCompleted)
                            progressHandler(progress)
                        }
                    )
                    let after = HubWeights.snapshot(for: configuration.name)
                    Self.log.info("Load container ok repo=\(configuration.name, privacy: .public) bytes=\(after.bytes) config=\(after.hasConfig) safetensors=\(after.safetensorsCount)")
                    return container
                } catch {
                    let nsError = error as NSError
                    let after = HubWeights.snapshot(for: configuration.name)
                    Self.log.error("Load container failed repo=\(configuration.name, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code) message=\(error.localizedDescription, privacy: .public) detail=\(String(describing: error), privacy: .public) bytes=\(after.bytes) config=\(after.hasConfig)")
                    throw error
                }
            }
        )
        return model
    }

    private var tagInstructions: String {
        """
        Tag one lecture window. Do not translate. Use only words from the window. \
        kind is one of definition, list, example, emphasis, reference, assignment, examScope, decision, other. \
        topics has at most five short names that appear in the window. \
        missing is true only if part of the window is unintelligible. Do not invent facts.
        """
    }

    /// Examples for the correction, by lecture language. A language without examples gets none,
    /// so a lecture is never shown an example in another language. One example changes nothing
    /// on purpose, so that the model leaves correct text alone.
    private static let correctionExamples: [String: [(text: String, corrected: String)]] = [
        "tr": [
            (
                "bugün sinavda cikacak konulari anlatiyorum herkes halini kaldirsin",
                "Bugün sınavda çıkacak konuları anlatıyorum. Herkes elini kaldırsın."
            ),
            (
                "Bugün derse geç kaldım, kusura bakmayın.",
                "Bugün derse geç kaldım, kusura bakmayın."
            )
        ],
        "en": [
            (
                "to day we start with the second chapter every one open you're books",
                "Today we start with the second chapter. Everyone, open your books."
            ),
            (
                "Sorry I'm late. Let's get started.",
                "Sorry I'm late. Let's get started."
            )
        ]
    ]

    /// The correction prompt: the rules, the lecture name and language, and the examples of the language.
    private func correctionInstructions(lectureName: String, localeIdentifier: String) -> String {
        let intro = """
            You proofread a transcript of a spoken lecture. The text comes from speech recognition: \
            it has little punctuation and some misheard words. Work in the same language.
            """
        let rules = """
            1. Add punctuation, capital letters and sentence breaks. \
            2. Put each sentence in normal word order, for example the verb at the end in Turkish. \
            3. Change a word only when it is clearly misheard and the right word sounds almost the \
            same, for example halini to elini. Otherwise copy the word exactly, including informal \
            words like abi or hocam. Keep the person and tense endings as they are. \
            4. If a part makes no sense, keep those words as they are. Never guess a new meaning, \
            never add, remove or replace ideas, and never summarise, shorten or translate. \
            5. If a sentence is already correct, keep its words exactly. The marking and homework \
            rules below still apply. \
            6. Do not translate terms from other languages. \
            Wrap short important phrases in double asterisks, like **this**: terms, names, numbers \
            and dates. Never wrap whole sentences. \
            Only when the teacher clearly gives homework, or says the students are responsible for \
            something, add a line after the text that starts with ASSIGNMENT: followed by that task \
            in the teacher's own words, copied from the text. Never invent a task. \
            Output the corrected text and nothing else: no notes, comments, explanations or \
            remarks about the text, and never say that something is missing. If a part is unclear, \
            copy it exactly and do not explain why. Stop after the last sentence. Thinking is off.
            """
        var sections = [intro]

        let name = String(
            lectureName
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(80)
        )
        let languageCode = Locale(identifier: localeIdentifier).language.languageCode?.identifier
        let languageName = languageCode.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0) }
        var context: [String] = []
        if !name.isEmpty { context.append("Lecture: \(name).") }
        if let languageName { context.append("Main language: \(languageName). Other languages may appear.") }
        if !context.isEmpty { sections.append(context.joined(separator: " ")) }

        sections.append(rules)

        if let languageCode, let examples = Self.correctionExamples[languageCode] {
            let lines = examples.map { "Text: \($0.text)\nCorrected text: \($0.corrected)" }
            sections.append("Examples:\n" + lines.joined(separator: "\n\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private var headlineInstructions: String {
        """
        You write the headline of a lecture from its text. Work in the same language as the text. \
        The headline says what the lecture is about, in 8 to 18 words, on one line. \
        Use words that are in the text. Never add a fact, a name or a number that is not in the text. \
        Do not use quotation marks, a list or a full stop at the end. \
        Output the headline and nothing else. Thinking is off.
        """
    }

    private var answerInstructions: String {
        """
        Answer the question using only the notes. Reply with the answer alone, \
        in one or two short sentences, in the language of the question. \
        Never repeat or list the notes. \
        If the notes do not contain the answer, reply exactly: NOT_IN_NOTES
        """
    }

    private var pageInstructions: String {
        """
        Write from the tagged notes only. Do not add facts that are not in the notes. \
        Do not use outside knowledge. Thinking is off.
        """
    }
}

struct HubSnapshotDownloader: Downloader {
    private static let log = Logger(subsystem: "app.bellnote", category: "hub")

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else {
            Self.log.error("Hub repo id invalid id=\(id, privacy: .public)")
            throw LocalModelError.loadFailed
        }
        Self.log.info("Hub snapshot begin id=\(id, privacy: .public) revision=\(revision ?? "main", privacy: .public)")
        do {
            let url = try await HubClient().downloadSnapshot(
                of: repo,
                revision: revision ?? "main",
                matching: patterns,
                progressHandler: { @MainActor progress in
                    if progress.fractionCompleted == 0 || progress.isFinished || Int(progress.fractionCompleted * 100) % 10 == 0 {
                        Self.log.info("Hub progress id=\(id, privacy: .public) fraction=\(progress.fractionCompleted)")
                    }
                    progressHandler(progress)
                }
            )
            Self.log.info("Hub snapshot ok id=\(id, privacy: .public) path=\(url.path, privacy: .public)")
            return url
        } catch {
            Self.log.error("Hub snapshot failed id=\(id, privacy: .public) message=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

struct HuggingFaceTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return HuggingFaceTokenizerBridge(upstream: upstream)
    }
}

struct HuggingFaceTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

enum HubWeights {
    struct Snapshot: Sendable {
        var repo: String
        var path: String
        var directoryExists: Bool
        var hasConfig: Bool
        var safetensorsCount: Int
        var fileCount: Int
        var bytes: Int64
        var fileNames: [String]
        /// Core ML model folders (`*.mlmodelc`), the weights format of Whisper.
        var coreMLCount = 0

        var isReady: Bool {
            directoryExists && hasConfig && (safetensorsCount > 0 || coreMLCount >= 3)
        }
    }

    static func remove(_ id: String) throws {
        let cache = HubCache.default
        guard let repo = Repo.ID(rawValue: id) else {
            throw LocalModelError.loadFailed
        }
        let manager = FileManager.default
        let repoDirectory = cache.repoDirectory(repo: repo, kind: .model)
        if manager.fileExists(atPath: repoDirectory.path) {
            try manager.removeItem(at: repoDirectory)
        }
        let metadata = cache.metadataDirectory(repo: repo, kind: .model)
        if manager.fileExists(atPath: metadata.path) {
            try manager.removeItem(at: metadata)
        }
    }

    static func directory(for id: String) -> URL {
        let cache = HubCache.default
        guard let repo = Repo.ID(rawValue: id) else {
            return cache.cacheDirectory
                .appendingPathComponent("models--" + id.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
        }
        let snapshots = cache.snapshotsDirectory(repo: repo, kind: .model)
        if let revision = cache.resolveRevision(repo: repo, kind: .model, ref: "main") {
            let url = snapshots.appendingPathComponent(revision, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        if let children = try? FileManager.default.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), let newest = children.max(by: { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }) {
            return newest
        }
        return snapshots
    }

    static func snapshot(for id: String) -> Snapshot {
        snapshot(at: directory(for: id), id: id)
    }

    /// Looks at a model folder that is not in the Hub cache.
    static func snapshot(at url: URL, id: String) -> Snapshot {
        let manager = FileManager.default
        let directoryExists = manager.fileExists(atPath: url.path)
        let hasConfig = manager.fileExists(atPath: url.appendingPathComponent("config.json").path)
        guard directoryExists else {
            return Snapshot(
                repo: id,
                path: url.path,
                directoryExists: false,
                hasConfig: false,
                safetensorsCount: 0,
                fileCount: 0,
                bytes: 0,
                fileNames: []
            )
        }
        var names: [String] = []
        var total: Int64 = 0
        var safetensors = 0
        var coreML = 0
        if let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let file as URL in enumerator {
                if file.pathExtension == "mlmodelc" { coreML += 1 }
                let target = file.resolvingSymlinksInPath()
                guard
                    let values = try? target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                    values.isRegularFile == true
                else { continue }
                total += Int64(values.fileSize ?? 0)
                let name = file.lastPathComponent
                names.append(name)
                if name.hasSuffix(".safetensors") { safetensors += 1 }
            }
        }
        names.sort()
        return Snapshot(
            repo: id,
            path: url.path,
            directoryExists: true,
            hasConfig: hasConfig,
            safetensorsCount: safetensors,
            fileCount: names.count,
            bytes: total,
            fileNames: Array(names.prefix(20)),
            coreMLCount: coreML
        )
    }

}
