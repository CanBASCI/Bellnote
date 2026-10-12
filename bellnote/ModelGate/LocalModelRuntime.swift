import Foundation
import FoundationModels
import HuggingFace
import MLXFoundationModels
import MLXLLM
import MLXLMCommon
import Tokenizers

enum LocalModelError: Error, Equatable {
    case notInstalled
    case locked
    case loadFailed
}

actor LocalModelRuntime {
    static let shared = LocalModelRuntime()

    private var resident: ModelRole?
    private let gate = ModelGate()

    func reset() async {
        await gate.unload()
        resident = nil
    }

    func tag(window: String, locale: Locale) async throws -> WindowTag {
        try await ensure(.tagger)
        let session = try makeSession(role: .tagger, instructions: tagInstructions)
        let response = try await session.respond(to: window, generating: WindowTag.self)
        if TagValidator.validate(response.content) {
            return response.content
        }
        let retry = try await session.respond(to: window, generating: WindowTag.self)
        guard TagValidator.validate(retry.content) else {
            throw LocalModelError.loadFailed
        }
        return retry.content
    }

    func compose(tags: [WindowTag], task: String) async throws -> String {
        try await ensure(.page)
        let session = try makeSession(role: .page, instructions: pageInstructions)
        let source = tags.map(\.text).joined(separator: "\n")
        let response = try await session.respond(to: "\(task)\n\n\(source)")
        return response.content
    }

    func download(_ role: ModelRole) async throws {
        guard role == .tagger || role == .page else { throw LocalModelError.notInstalled }
        let model = try makeModel(role)
        try await model.preload()
        try await ensure(role)
    }

    func cancel(lecture id: UUID) async {
        await gate.cancel(lecture: id)
        resident = nil
    }

    private func ensure(_ role: ModelRole) async throws {
        if role == .page, resident == .tagger {
            await gate.unload()
            resident = nil
        }
        if resident == role { return }
        switch role {
        case .tagger:
            await gate.loadTagger()
        case .page:
            await gate.loadPage()
        case .asr:
            throw LocalModelError.notInstalled
        }
        resident = role
    }

    private func makeSession(role: ModelRole, instructions: String) throws -> LanguageModelSession {
        LanguageModelSession(model: try makeModel(role), tools: [], instructions: instructions)
    }

    private func makeModel(_ role: ModelRole) throws -> MLXLanguageModel {
        let repo = role == .tagger ? ModelCatalog.taggerRepo : ModelCatalog.pageRepo
        let configuration = ModelConfiguration(id: repo)
        let model = MLXLanguageModel(
            configuration: configuration,
            capabilities: [.guidedGeneration],
            weightsLocation: { id in
                HubWeights.directory(for: id)
            },
            load: { configuration, progressHandler in
                try await loadModelContainer(
                    from: HubSnapshotDownloader(),
                    using: HuggingFaceTokenizerLoader(),
                    configuration: configuration,
                    progressHandler: progressHandler
                )
            }
        )
        return model
    }

    private var tagInstructions: String {
        """
        Tag one lecture window. Use only words from the window. \
        kind is one of definition, list, example, emphasis, reference, assignment, examScope, decision, other. \
        If items are unintelligible, keep the row and set missing true. Do not invent facts.
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
    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else {
            throw LocalModelError.loadFailed
        }
        return try await HubClient().downloadSnapshot(
            of: repo,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            }
        )
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
    static func directory(for id: String) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent(id.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }
}
