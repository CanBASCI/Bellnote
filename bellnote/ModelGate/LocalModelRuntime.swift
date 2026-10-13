import Foundation
import FoundationModels
import HuggingFace
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
    private let gate = ModelGate()

    func reset() async {
        await gate.unload()
        resident = nil
        Self.log.info("Model reset")
    }

    func tag(window: String, locale: Locale) async throws -> WindowTag {
        Self.log.info("Tag begin characters=\(window.count) locale=\(locale.identifier, privacy: .public)")
        do {
            try await ensure(.tagger)
            let session = try makeSession(role: .tagger, instructions: tagInstructions)
            let response = try await session.respond(to: window, generating: WindowTag.self)
            if TagValidator.validate(response.content) {
                Self.log.info("Tag ok kind=\(response.content.kind, privacy: .public)")
                return response.content
            }
            Self.log.warning("Tag invalid, retrying")
            let retry = try await session.respond(to: window, generating: WindowTag.self)
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
        Self.log.info("Compose begin tags=\(tags.count)")
        do {
            try await ensure(.page)
            let session = try makeSession(role: .page, instructions: pageInstructions)
            let source = tags.map(\.text).joined(separator: "\n")
            let response = try await session.respond(to: "\(task)\n\n\(source)")
            Self.log.info("Compose ok characters=\(response.content.count)")
            return response.content
        } catch {
            Self.log.error("Compose failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func probe(_ role: ModelRole) -> HubWeights.Snapshot {
        let repo = role == .tagger ? ModelCatalog.taggerRepo : role == .page ? ModelCatalog.pageRepo : ModelCatalog.asrRepo
        let snapshot = HubWeights.snapshot(for: repo)
        Self.log.info(
            "Probe role=\(role.rawValue, privacy: .public) repo=\(snapshot.repo, privacy: .public) path=\(snapshot.path, privacy: .public) directory=\(snapshot.directoryExists) config=\(snapshot.hasConfig) safetensors=\(snapshot.safetensorsCount) files=\(snapshot.fileCount) bytes=\(snapshot.bytes) names=\(snapshot.fileNames.joined(separator: ","), privacy: .public)"
        )
        return snapshot
    }

    func download(_ role: ModelRole) async throws {
        guard role == .tagger || role == .page else { throw LocalModelError.notInstalled }
        let repo = role == .tagger ? ModelCatalog.taggerRepo : ModelCatalog.pageRepo
        Self.log.info("Download tapped role=\(role.rawValue, privacy: .public) repo=\(repo, privacy: .public)")
        _ = probe(role)
        do {
            let model = try makeModel(role)
            let available = await model.isAvailable
            Self.log.info("Availability before preload role=\(role.rawValue, privacy: .public) available=\(available)")
            try await model.preload()
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

    func cancel(lecture id: UUID) async {
        await gate.cancel(lecture: id)
        resident = nil
    }

    private func ensure(_ role: ModelRole) async throws {
        if role == .page, resident == .tagger {
            Self.log.info("Unload tagger before page")
            await gate.unload()
            resident = nil
        }
        if resident == role {
            Self.log.info("Model already resident role=\(role.rawValue, privacy: .public)")
            return
        }
        Self.log.info("Ensure role=\(role.rawValue, privacy: .public)")
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
        let disk = HubWeights.snapshot(for: repo)
        Self.log.info("Make model role=\(role.rawValue, privacy: .public) repo=\(disk.repo, privacy: .public) path=\(disk.path, privacy: .public) bytes=\(disk.bytes) config=\(disk.hasConfig) safetensors=\(disk.safetensorsCount)")
        let configuration = ModelConfiguration(id: repo)
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
    }

    static func directory(for id: String) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent(id.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    static func snapshot(for id: String) -> Snapshot {
        let url = directory(for: id)
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
        if let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let file as URL in enumerator {
                guard
                    let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
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
            fileNames: Array(names.prefix(20))
        )
    }

}
