import Foundation
import SwiftUI

/// Helpers for the AI correction. The model wraps important parts in `**double asterisks**`
/// and writes each homework on a line that starts with `ASSIGNMENT:`.
enum CorrectionText {
    static let assignmentPrefix = "ASSIGNMENT:"

    struct Parts: Equatable {
        var body: String
        var assignments: [String]
    }

    /// Separates the corrected text from the homework lines.
    static func split(_ output: String) -> Parts {
        var body: [String] = []
        var assignments: [String] = []
        let edge = CharacterSet(charactersIn: "-•* \t")
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let bare = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: edge)
            if bare.uppercased().hasPrefix(assignmentPrefix) {
                let task = bare.dropFirst(assignmentPrefix.count).trimmingCharacters(in: .whitespaces)
                if !task.isEmpty { assignments.append(task) }
                continue
            }
            body.append(line)
        }
        let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Parts(body: text, assignments: assignments)
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
