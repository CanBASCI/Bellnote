import AVFoundation
import Foundation
import MLX
import MLXLMCommon
import MLXNN
import OSLog

enum QwenASR {
    fileprivate static let log = Logger(subsystem: "app.bellnote", category: "qwen-asr")
    private static let audioPad = 151676
    private static let audioStart = 151669
    private static let audioEnd = 151670
    private static let imStart = 151644
    private static let imEnd = 151645
    private static let endOfText = 151643
    private static let asrText = 151704
    private static let sampleRate = 16_000
    private static let chunkSamples = 30 * sampleRate
    private static let maxTokens = 192

    static func transcribe(url: URL, locale: Locale, runs: [SpeechRun]) async throws -> [TranscriptLine] {
        Memory.cacheLimit = 512 * 1_024 * 1_024
        let session = try QwenSession.load()
        defer {
            Memory.clearCache()
        }
        let turns = LectureTranscriber.speakerTurns(runs)
        let longest = RoleRules.longestCluster(runs) ?? 1
        if turns.isEmpty {
            let samples = try readSamples(url: url, from: 0, through: duration(url))
            let text = try session.write(samples: samples, locale: locale)
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            log.info("Qwen ASR whole words=\(cleaned.split(separator: " ").count)")
            guard !cleaned.isEmpty else { throw TranscriptError.qualityFailed }
            return [TranscriptLine(second: 0, text: cleaned, role: .unknown)]
        }
        log.info("Qwen ASR speakers=\(Set(turns.map(\.cluster)).count) turns=\(turns.count)")
        var lines: [TranscriptLine] = []
        for turn in turns {
            let samples = try readSamples(url: url, from: turn.start, through: turn.end)
            let text = try session.write(samples: samples, locale: locale)
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            log.info("Qwen ASR speaker=\(turn.cluster) seconds=\(turn.end - turn.start) words=\(cleaned.split(separator: " ").count) text=\(cleaned, privacy: .public)")
            guard !cleaned.isEmpty else { continue }
            lines.append(TranscriptLine(
                second: turn.start,
                text: cleaned,
                role: RoleRules.label(turn, longestCluster: longest),
                speaker: turn.cluster
            ))
        }
        guard !lines.isEmpty else { throw TranscriptError.qualityFailed }
        return lines
    }

    private static func duration(_ url: URL) throws -> Int {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { throw TranscriptError.unreadable }
        return max(1, Int(Double(file.length) / rate))
    }

    private static func readSamples(url: URL, from start: Int, through end: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: source, to: target) else {
            throw TranscriptError.unreadable
        }
        let startFrame = min(file.length, AVAudioFramePosition(Double(max(0, start)) * source.sampleRate))
        let endFrame = min(file.length, AVAudioFramePosition(Double(max(start + 1, end)) * source.sampleRate))
        guard endFrame > startFrame else { throw TranscriptError.unreadable }
        file.framePosition = startFrame
        var output: [Float] = []
        let capacity: AVAudioFrameCount = 8_192
        while file.framePosition < endFrame {
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(capacity), endFrame - file.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else {
                throw TranscriptError.unreadable
            }
            try file.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0 { break }
            let ratio = target.sampleRate / source.sampleRate
            let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames) else {
                throw TranscriptError.unreadable
            }
            var consumed = false
            var convertError: NSError?
            converter.convert(to: converted, error: &convertError) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if let convertError { throw convertError }
            if let channel = converted.floatChannelData?.pointee {
                output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            }
            converter.reset()
        }
        return output
    }
}

private final class QwenSession {
    let model: Qwen3ASRModel
    let tokenizer: QwenBPE

    init(model: Qwen3ASRModel, tokenizer: QwenBPE) {
        self.model = model
        self.tokenizer = tokenizer
    }

    static func load() throws -> QwenSession {
        let directory = HubWeights.directory(for: ModelCatalog.asrRepo)
        let weightsURL = directory.appendingPathComponent("model.safetensors")
        guard FileManager.default.fileExists(atPath: weightsURL.path) else { throw TranscriptError.qwenMissing }
        let model = Qwen3ASRModel()
        let weights = try loadArrays(url: weightsURL)
        let parameters = model.parameters().flattened()
        let names = Set(parameters.map(\.0))
        let used = weights.filter { names.contains($0.key) }
        let missing = names.subtracting(used.keys).sorted()
        if !missing.isEmpty {
            throw QwenASRError.missingWeights(missing.prefix(8).joined(separator: ","))
        }
        try model.update(parameters: ModuleParameters.unflattened(used), verify: [.shapeMismatch, .noUnusedKeys])
        eval(model.parameters())
        let tokenizer = try QwenBPE(directory: directory)
        return QwenSession(model: model, tokenizer: tokenizer)
    }

    func write(samples: [Float], locale: Locale) throws -> String {
        guard !samples.isEmpty else { return "" }
        var parts: [String] = []
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + QwenASRChunk.samples)
            let text = try writeChunk(Array(samples[offset..<end]), locale: locale)
            if !text.isEmpty { parts.append(text) }
            offset = end
        }
        return parts.joined(separator: " ")
    }

    private func writeChunk(_ samples: [Float], locale: Locale) throws -> String {
        let features = QwenMel.features(samples)
        let frames = features.dim(2)
        guard frames > 0 else { return "" }
        let mask = MLXArray.ones([1, frames])
        let audio = model.audioTower(features, mask: mask)
        eval(audio)
        let tokens = audio.dim(0)
        let ids = tokenizer.prompt(audioTokens: tokens, language: QwenLanguage.name(locale))
        let embeds = model.mergedEmbeddings(ids: ids, audio: audio)
        eval(embeds)
        let generated = model.generate(embeds: embeds, promptCount: ids.count, limit: 192)
        let raw = tokenizer.decode(generated)
        let text = QwenSpeech.plain(raw)
        QwenASR.log.info("Qwen ASR raw=\(raw, privacy: .public)")
        QwenASR.log.info("Qwen ASR text=\(text, privacy: .public)")
        return text
    }
}

private enum QwenASRChunk {
    static let samples = 30 * 16_000
}

private enum QwenASRError: Error {
    case missingWeights(String)
}

private enum QwenSpeech {
    static func plain(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tag = text.range(of: "<asr_text>", options: .backwards) {
            text = String(text[tag.upperBound...])
        }
        text = text.replacingOccurrences(of: "<[^>\n]+>", with: "", options: .regularExpression)
        if let spoken = jsonText(text) { text = spoken }
        let lowered = text.lowercased()
        if lowered.hasPrefix("language none") { return "" }
        if lowered.hasPrefix("language ") {
            let rest = text.dropFirst("language ".count)
            if let space = rest.firstIndex(of: " ") ?? rest.firstIndex(of: "\n") {
                let head = rest[..<space]
                if head.allSatisfy({ $0.isLetter }) {
                    text = String(rest[rest.index(after: space)...])
                }
            }
        }
        text = QwenRepeat.collapse(text)
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func jsonText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return firstString(object)
    }

    private static func firstString(_ value: Any) -> String? {
        let keys = ["transcription", "text", "content", "sentence"]
        if let object = value as? [String: Any] {
            for key in keys {
                if let text = object[key] as? String {
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty { return cleaned }
                }
            }
            for nested in object.values {
                if let text = firstString(nested) { return text }
            }
        }
        if let list = value as? [Any] {
            for item in list {
                if let text = firstString(item) { return text }
            }
        }
        return nil
    }
}

private enum QwenRepeat {
    static func penalize(_ row: MLXArray, recent: [Int32]) -> MLXArray {
        let unique = Array(Set(recent.suffix(32)))
        guard !unique.isEmpty else { return row }
        let index = MLXArray(unique.map { Int32($0) })
        let scores = takeAlong(row, index, axis: 0)
        let adjusted = which(scores .< 0, scores * 1.15, scores / 1.15)
        return putAlong(row, index, values: adjusted, axis: 0)
    }

    static func cut(_ ids: [Int32]) -> Int? {
        let count = ids.count
        guard count >= 6 else { return nil }
        let longest = min(16, count / 3)
        guard longest >= 2 else { return nil }
        for length in stride(from: longest, through: 2, by: -1) {
            let end = count
            let once = ids[(end - length)..<end]
            let twice = ids[(end - 2 * length)..<(end - length)]
            let thrice = ids[(end - 3 * length)..<(end - 2 * length)]
            if Array(once) == Array(twice), Array(twice) == Array(thrice) {
                return end - 2 * length
            }
        }
        return nil
    }

    static func collapse(_ text: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 4 else { return text }
        var kept: [String] = []
        var index = 0
        while index < words.count {
            let room = words.count - index
            let longest = min(12, room / 2)
            var folded = false
            if longest >= 2 {
                for length in stride(from: longest, through: 2, by: -1) {
                    let phrase = Array(words[index..<(index + length)])
                    var copies = 1
                    var cursor = index + length
                    while cursor + length <= words.count, Array(words[cursor..<(cursor + length)]) == phrase {
                        copies += 1
                        cursor += length
                    }
                    if copies >= 3 {
                        kept.append(contentsOf: phrase)
                        index = cursor
                        folded = true
                        break
                    }
                }
            }
            if !folded {
                kept.append(words[index])
                index += 1
            }
        }
        return kept.joined(separator: " ")
    }
}

private enum QwenLanguage {
    static func name(_ locale: Locale) -> String? {
        let code = locale.language.languageCode?.identifier ?? locale.identifier
        let names = [
            "tr": "Turkish", "en": "English", "de": "German", "fr": "French", "es": "Spanish",
            "pt": "Portuguese", "id": "Indonesian", "it": "Italian", "ko": "Korean", "ru": "Russian",
            "th": "Thai", "vi": "Vietnamese", "ja": "Japanese", "zh": "Chinese", "ar": "Arabic",
            "hi": "Hindi", "ms": "Malay", "nl": "Dutch", "sv": "Swedish", "da": "Danish",
            "fi": "Finnish", "pl": "Polish", "cs": "Czech", "fil": "Filipino", "fa": "Persian",
            "el": "Greek", "ro": "Romanian", "hu": "Hungarian", "mk": "Macedonian"
        ]
        if code.hasPrefix("zh") { return code.contains("HK") || code.contains("yue") ? "Cantonese" : "Chinese" }
        return names[code]
    }
}

private func qLinear(input: Int, output: Int) -> QuantizedLinear {
    QuantizedLinear(
        weight: MLXArray.zeros([output, input / 8], dtype: .uint32),
        scales: MLXArray.zeros([output, input / 64]),
        biases: MLXArray.zeros([output, input / 64]),
        groupSize: 64,
        bits: 4
    )
}

private final class Qwen3ASRModel: Module {
    @ModuleInfo(key: "audio_tower") var audioTower: QwenAudioEncoder
    @ModuleInfo(key: "model") var text: QwenTextModel

    init(loaded: Bool = true) {
        super.init()
        _ = loaded
        self.audioTower = QwenAudioEncoder()
        self.text = QwenTextModel()
    }

    func mergedEmbeddings(ids: [Int32], audio: MLXArray) -> MLXArray {
        let tokens = MLXArray(ids).reshaped([1, ids.count])
        let embeds = text.embedTokens(tokens)
        let hidden = embeds.dim(-1)
        let flat = embeds.reshaped([ids.count, hidden])
        var rows: [MLXArray] = []
        rows.reserveCapacity(ids.count)
        var audioIndex = 0
        let audioCount = audio.dim(0)
        for (index, id) in ids.enumerated() where true {
            if id == Int32(151676), audioIndex < audioCount {
                rows.append(audio[audioIndex].asType(flat.dtype))
                audioIndex += 1
            } else {
                rows.append(flat[index])
            }
        }
        return stacked(rows).reshaped([1, ids.count, hidden])
    }

    func generate(embeds: MLXArray, promptCount: Int, limit: Int) -> [Int32] {
        let cache = (0..<28).map { _ in KVCacheSimple() }
        var logits = text(embeds, cache: cache)
        eval(logits)
        var row = QwenRepeat.penalize(logits[0, -1], recent: [])
        var token = argMax(row, axis: -1)
        eval(token)
        var output: [Int32] = []
        let stop: Set<Int32> = [151645, 151643]
        for _ in 0..<limit {
            let id = token.item(Int32.self)
            if stop.contains(id) { break }
            output.append(id)
            if let cut = QwenRepeat.cut(output) {
                return Array(output.prefix(cut))
            }
            let step = text.embedTokens(MLXArray(id).reshaped([1, 1]))
            logits = text(step, cache: cache)
            eval(logits)
            row = QwenRepeat.penalize(logits[0, -1], recent: output)
            token = argMax(row, axis: -1)
            eval(token)
        }
        _ = promptCount
        return output
    }
}

private final class QwenAudioEncoder: Module {
    @ModuleInfo(key: "conv2d1") var conv2d1: Conv2d
    @ModuleInfo(key: "conv2d2") var conv2d2: Conv2d
    @ModuleInfo(key: "conv2d3") var conv2d3: Conv2d
    @ModuleInfo(key: "conv_out") var convOut: Linear
    @ModuleInfo(key: "layers") var layers: [QwenAudioLayer]
    @ModuleInfo(key: "ln_post") var lnPost: LayerNorm
    @ModuleInfo(key: "proj1") var proj1: Linear
    @ModuleInfo(key: "proj2") var proj2: Linear

    init(loaded: Bool = true) {
        super.init()
        _ = loaded
        conv2d1 = Conv2d(inputChannels: 1, outputChannels: 480, kernelSize: 3, stride: 2, padding: 1)
        conv2d2 = Conv2d(inputChannels: 480, outputChannels: 480, kernelSize: 3, stride: 2, padding: 1)
        conv2d3 = Conv2d(inputChannels: 480, outputChannels: 480, kernelSize: 3, stride: 2, padding: 1)
        convOut = Linear(7680, 896, bias: false)
        layers = (0..<18).map { _ in QwenAudioLayer() }
        lnPost = LayerNorm(dimensions: 896)
        proj1 = Linear(896, 896)
        proj2 = Linear(896, 1024)
    }

    func callAsFunction(_ features: MLXArray, mask: MLXArray) -> MLXArray {
        let frames = Int(mask.sum().item(Float.self))
        let chunkSize = 100
        let chunkCount = max(1, Int(ceil(Double(frames) / Double(chunkSize))))
        var chunks: [MLXArray] = []
        var lengths: [Int] = []
        var position = 0
        let feat = features[0]
        for index in 0..<chunkCount {
            let remaining = frames - position
            let length = index == chunkCount - 1 ? (remaining % chunkSize == 0 ? chunkSize : remaining % chunkSize) : chunkSize
            let taken = min(length, frames - position)
            var chunk = feat[0..., position..<(position + taken)]
            if taken < chunkSize {
                chunk = padded(chunk, widths: [IntOrPair((0, 0)), IntOrPair((0, chunkSize - taken))])
            }
            chunks.append(chunk)
            lengths.append(taken)
            position += taken
        }
        let stackedFeatures = stacked(chunks)
        var hidden = gelu(conv2d1(stackedFeatures.reshaped([chunks.count, 128, chunkSize, 1])))
        hidden = gelu(conv2d2(hidden))
        hidden = gelu(conv2d3(hidden))
        let batch = hidden.dim(0)
        let frequency = hidden.dim(1)
        let time = hidden.dim(2)
        let channels = hidden.dim(3)
        hidden = hidden.transposed(0, 2, 3, 1).reshaped([batch, time, channels * frequency])
        hidden = convOut(hidden)
        let positions = QwenSinusoid.embedding(length: hidden.dim(1), channels: 896)
        hidden = hidden + positions.asType(hidden.dtype)
        let tokenLengths = lengths.map(QwenAudioMath.tokens(forMelFrames:))
        var pieces: [MLXArray] = []
        for index in 0..<batch {
            let count = max(0, tokenLengths[index])
            if count == 0 { continue }
            pieces.append(hidden[index, 0..<count])
        }
        guard !pieces.isEmpty else { return MLXArray.zeros([0, 1024]) }
        var sequence = concatenated(pieces, axis: 0)
        let blocks = QwenAudioMath.blocks(tokenLengths: tokenLengths, window: max(tokenLengths.max() ?? 1, 1) * 8)
        let attention = QwenAudioMath.blockMask(length: sequence.dim(0), blocks: blocks)
        sequence = sequence.reshaped([1, sequence.dim(0), 896])
        for layer in layers {
            sequence = layer(sequence, mask: attention)
        }
        sequence = sequence[0]
        sequence = lnPost(sequence)
        sequence = gelu(proj1(sequence))
        return proj2(sequence)
    }
}

private enum QwenSinusoid {
    static func embedding(length: Int, channels: Int) -> MLXArray {
        let half = channels / 2
        let increment = log(Float(10_000)) / Float(half - 1)
        let inverse = exp(-increment * MLXArray((0..<half).map { Float($0) }))
        let positions = MLXArray((0..<length).map { Float($0) }).reshaped([length, 1])
        let scaled = positions * inverse.reshaped([1, half])
        return concatenated([sin(scaled), cos(scaled)], axis: 1)
    }
}

private enum QwenAudioMath {
    static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        let remainder = value % divisor
        if remainder != 0, (value < 0) != (divisor < 0) { return quotient - 1 }
        return quotient
    }

    static func tokens(forMelFrames frames: Int) -> Int {
        let leave = frames % 100
        let first = floorDiv(leave - 1, 2) + 1
        let folded = floorDiv(floorDiv(first - 1, 2) + 1 - 1, 2) + 1
        return folded + (frames / 100) * 13
    }

    static func blocks(tokenLengths: [Int], window: Int) -> [(Int, Int)] {
        var cursor = 0
        var ranges: [(Int, Int)] = []
        let span = max(window, 1)
        for length in tokenLengths {
            var left = length
            while left > 0 {
                let size = min(span, left)
                ranges.append((cursor, cursor + size))
                cursor += size
                left -= size
            }
        }
        return ranges
    }

    static func blockMask(length: Int, blocks: [(Int, Int)]) -> MLXArray {
        var values = [Float](repeating: -1e9, count: max(length * length, 1))
        for (start, end) in blocks {
            for row in start..<end {
                for column in start..<end where row < length && column < length {
                    values[row * length + column] = 0
                }
            }
        }
        return MLXArray(values).reshaped([1, 1, length, length])
    }
}

private final class QwenAudioLayer: Module {
    @ModuleInfo(key: "self_attn_layer_norm") var selfAttnLayerNorm: LayerNorm
    @ModuleInfo(key: "self_attn") var selfAttn: QwenAudioAttention
    @ModuleInfo(key: "final_layer_norm") var finalLayerNorm: LayerNorm
    @ModuleInfo(key: "fc1") var fc1: Linear
    @ModuleInfo(key: "fc2") var fc2: Linear

    init(loaded: Bool = true) {
        super.init()
        _ = loaded
        selfAttnLayerNorm = LayerNorm(dimensions: 896)
        selfAttn = QwenAudioAttention()
        finalLayerNorm = LayerNorm(dimensions: 896)
        fc1 = Linear(896, 3584)
        fc2 = Linear(3584, 896)
    }

    func callAsFunction(_ hidden: MLXArray, mask: MLXArray) -> MLXArray {
        var states = hidden + selfAttn(selfAttnLayerNorm(hidden), mask: mask)
        states = states + fc2(gelu(fc1(finalLayerNorm(states))))
        return states
    }
}

private final class QwenAudioAttention: Module {
    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    init(loaded: Bool = true) {
        super.init()
        _ = loaded
        qProj = Linear(896, 896)
        kProj = Linear(896, 896)
        vProj = Linear(896, 896)
        outProj = Linear(896, 896)
    }

    func callAsFunction(_ hidden: MLXArray, mask: MLXArray) -> MLXArray {
        let batch = hidden.dim(0)
        let length = hidden.dim(1)
        let scale = 1 / sqrt(Float(64))
        let queries = (qProj(hidden) * scale).reshaped([batch, length, 14, 64]).transposed(0, 2, 1, 3)
        let keys = kProj(hidden).reshaped([batch, length, 14, 64]).transposed(0, 2, 1, 3)
        let values = vProj(hidden).reshaped([batch, length, 14, 64]).transposed(0, 2, 1, 3)
        let attended = MLXFast.scaledDotProductAttention(
            queries: queries, keys: keys, values: values, scale: 1, mask: mask.asType(queries.dtype)
        )
        return outProj(attended.transposed(0, 2, 1, 3).reshaped([batch, length, 896]))
    }
}

private final class QwenTextModel: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "layers") var layers: [QwenTextLayer]
    @ModuleInfo(key: "norm") var norm: RMSNorm

    init(loaded: Bool = true) {
        super.init()
        _ = loaded
        embedTokens = QuantizedEmbedding(
            weight: MLXArray.zeros([151_936, 128], dtype: .uint32),
            scales: MLXArray.zeros([151_936, 16]),
            biases: MLXArray.zeros([151_936, 16]),
            groupSize: 64,
            bits: 4
        )
        layers = (0..<28).map { _ in QwenTextLayer() }
        norm = RMSNorm(dimensions: 1024, eps: 1e-6)
    }

    func callAsFunction(_ embeds: MLXArray, cache: [KVCacheSimple]) -> MLXArray {
        var hidden = embeds
        let length = hidden.dim(1)
        let mask = length == 1 ? nil : QwenCausal.mask(query: length, keys: length + (cache.first?.offset ?? 0))
        for (index, layer) in layers.enumerated() {
            hidden = layer(hidden, mask: mask, cache: cache[index])
        }
        let states = norm(hidden)
        return embedTokens.asLinear(states)
    }
}

private enum QwenCausal {
    static func mask(query: Int, keys: Int) -> MLXArray {
        let offset = keys - query
        let rows = MLXArray((0..<query).map { Int32($0 + offset) }).reshaped([query, 1])
        let columns = MLXArray((0..<keys).map { Int32($0) }).reshaped([1, keys])
        let allowed = rows .>= columns
        return which(allowed, MLXArray(Float(0)), MLXArray(Float(-1e9))).reshaped([1, 1, query, keys])
    }
}

private final class QwenTextLayer: Module {
    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "self_attn") var selfAttn: QwenTextAttention
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm
    @ModuleInfo(key: "mlp") var mlp: QwenTextMLP

    init(loaded: Bool = true) {
        super.init()
        _ = loaded
        inputLayerNorm = RMSNorm(dimensions: 1024, eps: 1e-6)
        selfAttn = QwenTextAttention()
        postAttentionLayerNorm = RMSNorm(dimensions: 1024, eps: 1e-6)
        mlp = QwenTextMLP()
    }

    func callAsFunction(_ hidden: MLXArray, mask: MLXArray?, cache: KVCacheSimple) -> MLXArray {
        var states = hidden + selfAttn(inputLayerNorm(hidden), mask: mask, cache: cache)
        states = states + mlp(postAttentionLayerNorm(states))
        return states
    }
}

private final class QwenTextAttention: Module {
    let rope = RoPE(dimensions: 128, traditional: false, base: 1_000_000)
    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    init(loaded: Bool = true) {
        super.init()
        _ = loaded
        qProj = qLinear(input: 1024, output: 2048)
        kProj = qLinear(input: 1024, output: 1024)
        vProj = qLinear(input: 1024, output: 1024)
        oProj = qLinear(input: 2048, output: 1024)
        qNorm = RMSNorm(dimensions: 128, eps: 1e-6)
        kNorm = RMSNorm(dimensions: 128, eps: 1e-6)
    }

    func callAsFunction(_ hidden: MLXArray, mask: MLXArray?, cache: KVCacheSimple) -> MLXArray {
        let batch = hidden.dim(0)
        let length = hidden.dim(1)
        var queries = qNorm(qProj(hidden).reshaped([batch, length, 16, 128])).transposed(0, 2, 1, 3)
        var keys = kNorm(kProj(hidden).reshaped([batch, length, 8, 128])).transposed(0, 2, 1, 3)
        var values = vProj(hidden).reshaped([batch, length, 8, 128]).transposed(0, 2, 1, 3)
        let offset = cache.offset
        queries = rope(queries, offset: offset)
        keys = rope(keys, offset: offset)
        (keys, values) = cache.update(keys: keys, values: values)
        let attended = MLXFast.scaledDotProductAttention(
            queries: queries, keys: keys, values: values, scale: 1 / sqrt(Float(128)), mask: mask?.asType(queries.dtype)
        )
        return oProj(attended.transposed(0, 2, 1, 3).reshaped([batch, length, 2048]))
    }
}

private final class QwenTextMLP: Module {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(loaded: Bool = true) {
        super.init()
        _ = loaded
        gateProj = qLinear(input: 1024, output: 3072)
        upProj = qLinear(input: 1024, output: 3072)
        downProj = qLinear(input: 3072, output: 1024)
    }

    func callAsFunction(_ hidden: MLXArray) -> MLXArray {
        downProj(silu(gateProj(hidden)) * upProj(hidden))
    }
}

private enum QwenMel {
    static func features(_ samples: [Float]) -> MLXArray {
        let frames = spectrogram(samples)
        guard !frames.isEmpty else { return MLXArray.zeros([1, 128, 0]) }
        let filters = filterBank()
        var values = [Float](repeating: 0, count: 128 * frames.count)
        for frame in frames.enumerated() {
            for mel in 0..<128 {
                var sum: Float = 0
                let row = mel * 201
                for bin in 0..<201 {
                    sum += filters[row + bin] * frame.element[bin]
                }
                values[mel * frames.count + frame.offset] = sum
            }
        }
        var peak: Float = 1e-10
        for value in values { peak = max(peak, value) }
        let floor = log10(max(peak, 1e-10)) - 8
        for index in values.indices {
            let logged = log10(max(values[index], 1e-10))
            values[index] = (max(logged, floor) + 4) / 4
        }
        return MLXArray(values).reshaped([1, 128, frames.count])
    }

    private static func spectrogram(_ samples: [Float]) -> [[Float]] {
        let fft = 400
        let hop = 160
        let padded = reflect(samples, 200)
        guard padded.count >= fft else { return [] }
        let count = 1 + (padded.count - fft) / hop
        guard count > 1 else { return [] }
        let window = hann(fft)
        var frame = [Float](repeating: 0, count: count * fft)
        for index in 0..<count {
            let start = index * hop
            for bin in 0..<fft {
                frame[index * fft + bin] = padded[start + bin] * window[bin]
            }
        }
        let spectrum = rfft(MLXArray(frame).reshaped([count, fft]), n: fft, axis: -1)
        let power = abs(spectrum).square()
        eval(power)
        let kept = count - 1
        var output = [[Float]](repeating: [Float](repeating: 0, count: 201), count: kept)
        let flat = power.asArray(Float.self)
        let width = power.dim(1)
        for index in 0..<kept {
            for bin in 0..<min(201, width) {
                output[index][bin] = flat[index * width + bin]
            }
        }
        return output
    }

    private static func hann(_ length: Int) -> [Float] {
        (0..<length).map { index in
            0.5 - 0.5 * cos(2 * Float.pi * Float(index) / Float(length))
        }
    }

    private static func reflect(_ samples: [Float], _ width: Int) -> [Float] {
        guard !samples.isEmpty else { return [] }
        var output: [Float] = []
        output.reserveCapacity(samples.count + width * 2)
        if samples.count == 1 {
            output.append(contentsOf: Array(repeating: samples[0], count: width))
            output.append(samples[0])
            output.append(contentsOf: Array(repeating: samples[0], count: width))
            return output
        }
        for index in stride(from: width, to: 0, by: -1) {
            output.append(samples[min(index, samples.count - 1)])
        }
        output.append(contentsOf: samples)
        for index in 1...width {
            let mirror = samples.count - 1 - (index % (samples.count - 1))
            output.append(samples[max(0, min(samples.count - 1, mirror))])
        }
        return output
    }

    private static func filterBank() -> [Float] {
        let bins = 201
        let mels = 128
        let points = (0..<(mels + 2)).map { hertz(mel: Float($0) / Float(mels + 1) * mel(8_000)) }
        let frequencies = (0..<bins).map { Float($0) * 8_000 / Float(bins - 1) }
        var bank = [Float](repeating: 0, count: mels * bins)
        for mel in 0..<mels {
            let left = points[mel]
            let center = points[mel + 1]
            let right = points[mel + 2]
            let enorm = 2 / max(right - left, 1e-6)
            for bin in 0..<bins {
                let frequency = frequencies[bin]
                let slope: Float
                if frequency < left || frequency > right {
                    slope = 0
                } else if frequency < center {
                    slope = (frequency - left) / max(center - left, 1e-6)
                } else {
                    slope = (right - frequency) / max(right - center, 1e-6)
                }
                bank[mel * bins + bin] = slope * enorm
            }
        }
        return bank
    }

    private static func mel(_ frequency: Float) -> Float {
        let minLog: Float = 1_000
        if frequency < minLog { return 3 * frequency / 200 }
        return 15 + log(frequency / minLog) * (27 / log(6.4))
    }

    private static func hertz(mel value: Float) -> Float {
        if value < 15 { return 200 * value / 3 }
        return 1_000 * exp((value - 15) * log(6.4) / 27)
    }
}

private final class QwenBPE {
    private let tokenToID: [String: Int]
    private let idToToken: [Int: String]
    private let ranks: [Pair: Int]
    private let specials: [String]
    private let bytesToUnicode: [UInt8: Character]
    private let unicodeToBytes: [Character: UInt8]

    init(directory: URL) throws {
        let vocabURL = directory.appendingPathComponent("vocab.json")
        let mergesURL = directory.appendingPathComponent("merges.txt")
        let vocabData = try Data(contentsOf: vocabURL)
        var vocab = try JSONDecoder().decode([String: Int].self, from: vocabData)
        var reverse: [Int: String] = [:]
        for (token, id) in vocab { reverse[id] = token }
        let addedURL = directory.appendingPathComponent("tokenizer_config.json")
        if let addedData = try? Data(contentsOf: addedURL),
           let json = try? JSONSerialization.jsonObject(with: addedData) as? [String: Any],
           let added = json["added_tokens_decoder"] as? [String: Any] {
            for (idText, value) in added {
                guard let id = Int(idText),
                      let entry = value as? [String: Any],
                      let content = entry["content"] as? String,
                      !content.isEmpty else { continue }
                if vocab[content] == nil { vocab[content] = id }
                reverse[id] = content
            }
        }
        tokenToID = vocab
        idToToken = reverse
        var rank: [Pair: Int] = [:]
        let lines = try String(contentsOf: mergesURL, encoding: .utf8).split(separator: "\n")
        var index = 0
        for line in lines where !line.hasPrefix("#") {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            rank[Pair(String(parts[0]), String(parts[1]))] = index
            index += 1
        }
        ranks = rank
        specials = vocab.keys.filter { $0.contains("<") }.sorted { $0.count > $1.count }
        var forward: [UInt8: Character] = [:]
        var backward: [Character: UInt8] = [:]
        var seen = Set<Int>()
        let ranges = Array(33...126) + Array(161...172) + Array(174...255)
        for value in ranges {
            let scalar = Character(UnicodeScalar(value)!)
            forward[UInt8(value)] = scalar
            backward[scalar] = UInt8(value)
            seen.insert(value)
        }
        var extra = 0
        for value in 0..<256 where !seen.contains(value) {
            let scalar = Character(UnicodeScalar(256 + extra)!)
            forward[UInt8(value)] = scalar
            backward[scalar] = UInt8(value)
            extra += 1
        }
        bytesToUnicode = forward
        unicodeToBytes = backward
    }

    func prompt(audioTokens: Int, language: String?) -> [Int32] {
        var text = "<|im_start|>system\n<|im_end|>\n<|im_start|>user\n<|audio_start|>"
        text += String(repeating: "<|audio_pad|>", count: audioTokens)
        text += "<|audio_end|><|im_end|>\n<|im_start|>assistant\n"
        if let language {
            text += "language \(language)<asr_text>"
        }
        return encode(text).map(Int32.init)
    }

    func decode(_ ids: [Int32]) -> String {
        var pieces = ""
        for id in ids {
            guard let token = idToToken[Int(id)] else { continue }
            if token.hasPrefix("<"), token.hasSuffix(">") { continue }
            pieces += token
        }
        var bytes: [UInt8] = []
        for character in pieces {
            if let byte = unicodeToBytes[character] {
                bytes.append(byte)
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private func encode(_ text: String) -> [Int] {
        var ids: [Int] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            if let special = specials.first(where: { rest.hasPrefix($0) }), let id = tokenToID[special] {
                ids.append(id)
                rest = rest.dropFirst(special.count)
                continue
            }
            var end = rest.endIndex
            for special in specials {
                if let range = rest.range(of: special), range.lowerBound < end {
                    end = range.lowerBound
                }
            }
            ids.append(contentsOf: encodePlain(String(rest[..<end])))
            rest = rest[end...]
        }
        return ids
    }

    private func encodePlain(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        let pattern = #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return bpe(text) }
        let range = NSRange(text.startIndex..., in: text)
        let matches = expression.matches(in: text, range: range)
        if matches.isEmpty { return bpe(text) }
        return matches.flatMap { match in
            guard let piece = Range(match.range, in: text) else { return [Int]() }
            return bpe(String(text[piece]))
        }
    }

    private func bpe(_ text: String) -> [Int] {
        let mapped = String(text.utf8.map { bytesToUnicode[$0] ?? "?" })
        var symbols = mapped.map(String.init)
        if symbols.count < 2 {
            return symbols.compactMap { tokenToID[$0] }
        }
        while symbols.count > 1 {
            var best: Pair?
            var bestRank = Int.max
            for index in 0..<(symbols.count - 1) {
                let pair = Pair(symbols[index], symbols[index + 1])
                guard let rank = ranks[pair], rank < bestRank else { continue }
                best = pair
                bestRank = rank
            }
            guard let pair = best else { break }
            var merged: [String] = []
            var index = 0
            while index < symbols.count {
                if index < symbols.count - 1, symbols[index] == pair.left, symbols[index + 1] == pair.right {
                    merged.append(pair.left + pair.right)
                    index += 2
                } else {
                    merged.append(symbols[index])
                    index += 1
                }
            }
            symbols = merged
        }
        return symbols.compactMap { tokenToID[$0] }
    }
}

private struct Pair: Hashable {
    var left: String
    var right: String
    init(_ left: String, _ right: String) {
        self.left = left
        self.right = right
    }
}
