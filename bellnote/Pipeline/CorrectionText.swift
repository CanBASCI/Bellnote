import Foundation
import SwiftUI

/// Helpers for the AI correction. The model wraps important parts in `**double asterisks**`
/// and may write homework on lines that start with `ASSIGNMENT:`. Homework is primarily taken from
/// cue-bearing sentences in the text; those lines are a secondary source.
enum CorrectionText {
    static let assignmentPrefix = "ASSIGNMENT:"

    struct Parts: Equatable {
        var body: String
        var assignments: [String]
        /// Why reading stopped before the end of the output, or nil when all of it was read. For the log.
        var cutReason: String?
    }

    /// Separates the corrected text from the homework lines.
    static func split(_ output: String) -> Parts {
        var body: [String] = []
        var assignments: [String] = []
        var cutReason: String?
        let edge = CharacterSet(charactersIn: "-•* \t")
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let bare = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: edge)
            if bare.uppercased().hasPrefix(assignmentPrefix) {
                let task = bare.dropFirst(assignmentPrefix.count).trimmingCharacters(in: .whitespaces)
                if !task.isEmpty { assignments.append(task) }
                continue
            }
            // The model sometimes adds its own comment, such as "Note: there are no assignments".
            if isCommentary(bare) || isLabelLine(line) {
                // Once the text has started, a comment means the model has left the task. Whatever follows is more
                // comment, often the same lines again until the token limit, so reading stops here. A chunk that
                // loses real text this way fails the faithfulness check and the raw words are kept instead.
                if body.contains(where: { !$0.isEmpty }) {
                    cutReason = "commentary: \(String(line.prefix(60)))"
                    break
                }
                continue
            }
            // The same long line twice is a loop, not lecture text.
            if line.count >= 25, body.contains(line) {
                cutReason = "repeated line: \(String(line.prefix(60)))"
                break
            }
            body.append(line)
        }
        let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Parts(body: text, assignments: assignments, cutReason: cutReason)
    }

    private static let commentaryPrefixes = [
        "note:", "notes:", "note -", "(note", "not:", "açıklama:", "explanation:", "comment:",
        "corrected text:", "düzeltilmiş metin:",
        "düzeltme:", "düzeltmeler:", "geri çekme", "sonuç:", "özet:", "yorum:", "uyarı:", "dikkat:",
        "talimat", "correction:", "corrections:", "result:", "summary:", "warning:", "retraction",
        "instruction", "output:", "answer:",
    ]

    /// A line written as a label for the model's own remarks, in markdown: a heading (`# Result`) or a label wrapped
    /// in single asterisks (`*Result:* …`). The lecture text never has those: its highlights use double asterisks.
    private static func isLabelLine(_ line: String) -> Bool {
        if line.hasPrefix("#") { return true }
        if line.hasPrefix("*"), !line.hasPrefix("**"), line.contains(":*") { return true }
        return false
    }

    /// A line the model wrote about its own answer instead of as part of the lecture text.
    static func isCommentary(_ line: String) -> Bool {
        let lower = line.lowercased(with: Locale(identifier: "en"))
        if commentaryPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        return lower.contains("no specific assignment") || lower.contains("no assignments")
    }

    private static let homeworkCues = [
        "ödev", "sorumlu", "teslim", "haftaya", "getirin", "getirmeniz", "hazırlayın", "hazırlamanız",
        // "yapın", "yazın", "okuyun" and "çalışın" are left out on purpose: a teacher says them in class all the time
        // ("odaklanmaya çalışın"), so alone they do not mean homework.
        "araştırın", "araştırmanız", "okumanız", "yapmanız", "yazmanız",
        "çözün", "çalışmanız", "inceleyin", "ezberleyin", "bitirin", "gönderin", "gelirken",
        "getirip", "okumalısınız", "araştırmalısınız",
        "homework", "assignment", "due ", "hand in", "submit", "responsible for", "read chapter",
        // The space keeps "return in" from matching.
        " turn in", "problem set", "worksheet", "come prepared",
        "hand it in", " turn it in", "read page", "come to class prepared",
        "araştırma yap",
    ]

    /// A verb in -ıp/-ip/-up/-üp, then gelmek or getirmek spoken to the class.
    /// A few words, or a number, may sit between them. The ending is any second-person form:
    /// imperative, future, aorist, optative, necessity, or the gelmeniz / getirmeniz request,
    /// including a following question word such as "misiniz".
    /// A story ("okuyup geldi", "yapıp getirdi") is not a task. A letter before the ending keeps a lone "ip" from matching.
    /// A computed property, because `Regex` is not `Sendable` and a stored static one is not allowed.
    private static var comeHavingDone: Regex<(Substring, Substring)> {
        #/\p{L}[ıiuü]p(?:\s+[\p{L}\d]+){0,4}\s+((?:getir|gel)\p{L}*\b(?:\s+m[iıuü]\p{L}*)?)/#
    }

    /// The part after "gel" or "getir" when the verb addresses "you".
    private static var classRequestEnding: Regex<Substring> {
        #/^(?:in(?:iz\p{L}*)?|men\p{L}*|(?:ebilir|ecek|meli|ir)(?:mi)?sin(?:iz)?|se(?:n(?:iz)?|sin(?:iz)?))$/#
    }

    /// Whether the spoken text contains a word a teacher uses when giving homework.
    /// The model alone is not trusted: it once turned "you will learn" into a task.
    static func hasHomeworkCue(_ text: String) -> Bool {
        let lower = text.lowercased(with: Locale(identifier: "tr"))
        return homeworkCues.contains { lower.contains($0) } || hasComeHavingDone(lower)
    }

    /// Come or bring having done it, addressed to the class, in any second-person form.
    private static func hasComeHavingDone(_ text: String) -> Bool {
        let spaced = String(text.map { $0.isLetter || $0.isNumber || $0.isWhitespace ? $0 : " " })
        for match in spaced.matches(of: comeHavingDone) {
            if isClassRequest(String(match.output.1)) { return true }
        }
        return false
    }

    /// `phrase` is "gel…" or "getir…", optionally with a question word stuck on ("gelir misiniz").
    private static func isClassRequest(_ phrase: String) -> Bool {
        let word = phrase.replacingOccurrences(of: " ", with: "")
        for stem in ["getir", "gel"] {
            guard word.hasPrefix(stem) else { continue }
            let rest = String(word.dropFirst(stem.count))
            if rest.isEmpty { return true }
            return rest.wholeMatch(of: classRequestEnding) != nil
        }
        return false
    }

    /// Whether the words around a task hold a homework cue. Only the sentence of the task and the one before and
    /// after it count, so a word from another part of a long text does not make an ordinary sentence a task.
    static func hasHomeworkCue(near task: String, in text: String) -> Bool {
        let parts = sentences(in: text)
        guard !parts.isEmpty else { return false }
        var best = 0
        var bestScore = -1.0
        for (index, sentence) in parts.enumerated() {
            let score = overlap(task, sentence)
            if score > bestScore {
                best = index
                bestScore = score
            }
        }
        let around = parts[max(0, best - 1)...min(parts.count - 1, best + 1)]
        return hasHomeworkCue(around.joined(separator: " "))
    }

    /// Sentences of the text, split on `.?!` and line breaks, with highlight markers removed.
    static func sentences(in text: String) -> [String] {
        plain(text)
            .split(whereSeparator: { ".?!\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Sentences that already carry a homework cue. These are the primary homework source: the teacher's
    /// own wording, found without waiting for an `ASSIGNMENT:` line from the model.
    static func homeworkSentences(in text: String) -> [String] {
        sentences(in: text).filter(hasHomeworkCue)
    }

    /// Rule sentences first. A model task is kept only when it is not the same job as a rule sentence, so the
    /// teacher's wording wins when the model rewrites or merges two tasks into one.
    static func mergeTasks(fromRules rules: [String], fromModel model: [String]) -> [String] {
        var result = rules
        for task in model {
            let same = result.contains { overlap(task, $0) >= 0.6 || overlap($0, task) >= 0.6 }
            if same { continue }
            result.append(task)
        }
        return result
    }

    /// The text without highlight markers, for lists, previews and reading aloud.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
    }

    /// Highlights the marked parts. A marker that is never closed stays plain.
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        let parts = text.components(separatedBy: "**")
        for (index, part) in parts.enumerated() where !part.isEmpty {
            var piece = AttributedString(part)
            if index % 2 == 1, index < parts.count - 1 {
                piece.backgroundColor = Color.yellow.opacity(0.4)
                piece.font = .body.weight(.semibold)
            }
            result.append(piece)
        }
        return result
    }

    /// Groups lines into pieces small enough for one model call.
    static func chunks(_ lines: [String], limit: Int = 1100) -> [String] {
        var result: [String] = []
        var current = ""
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if !current.isEmpty, current.count + text.count + 1 > limit {
                result.append(current)
                current = ""
            }
            current += current.isEmpty ? text : " " + text
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// A correction may fix spelling and order but must keep the same content.
    /// Anything much shorter, longer or with different words is rejected.
    static func isFaithful(_ corrected: String, to source: String) -> Bool {
        let output = plain(corrected)
        guard output.count * 10 >= source.count * 6, output.count <= source.count * 2 else { return false }
        return overlap(source, output) >= 0.6
    }

    /// A headline from the model, cleaned and checked. It is one line without quotation marks or a closing
    /// full stop, and most of its words come from the text. Otherwise nil, and the lecture has no headline.
    static func headline(_ raw: String, from source: String) -> String? {
        let quotes = CharacterSet(charactersIn: "\"“”«»'’‘`")
        var line = raw
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        line = line
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: quotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while line.last == "." { line.removeLast() }
        let wordCount = line.split(separator: " ").count
        guard wordCount >= 2, line.count <= 200 else { return nil }
        guard stemOverlap(line, plain(source)) >= 0.6 else { return nil }
        return line
    }

    /// Like `overlap`, but a word counts when the text has a word that starts with the same first
    /// five letters. A headline says "dersin konusu" where the text says "dersi", and Turkish
    /// endings would fail an exact match.
    private static func stemOverlap(_ left: String, _ right: String) -> Double {
        let wanted = words(left)
        guard !wanted.isEmpty else { return 0 }
        let have = Set(words(right).map { String($0.prefix(5)) })
        let hits = wanted.filter { have.contains(String($0.prefix(5))) }.count
        return Double(hits) / Double(wanted.count)
    }

    /// Share of the words of `left` that also appear in `right`.
    static func overlap(_ left: String, _ right: String) -> Double {
        let wanted = words(left)
        guard !wanted.isEmpty else { return 0 }
        let have = words(right)
        let hits = wanted.filter { have.contains($0) }.count
        return Double(hits) / Double(wanted.count)
    }

    private static func words(_ text: String) -> Set<String> {
        Set(
            text.lowercased(with: Locale(identifier: "tr"))
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count > 2 }
        )
    }
}
