import Foundation
import OSLog
import PDFKit
import UIKit
import Vision

/// One page (or whole image) of on-device text for the Quiz tab.
struct FileTextPage: Sendable {
    /// 0-based PDF page index. Images use 0.
    let pageIndex: Int
    let text: String
}

/// Reads text from a course file copy for the Quiz tab only. Talk and Ask still use the file name alone.
enum FileTextExtractor {
    private static let log = Logger(subsystem: "app.bellnote", category: "quiz")

    /// Page-aware text. PDF/slide pages keep their index; an image is a single page at 0.
    static func pages(at url: URL, kind: CourseFileKind) async throws -> [FileTextPage] {
        switch kind {
        case .pdf, .slide:
            return try pdfPages(at: url)
        case .image:
            let text = try await imageText(at: url)
            return [FileTextPage(pageIndex: 0, text: text)]
        case .other:
            if let pages = try? pdfPages(at: url), !pages.isEmpty { return pages }
            let text = try await imageText(at: url)
            return [FileTextPage(pageIndex: 0, text: text)]
        }
    }

    /// Joined text for callers that do not need page breaks.
    static func text(at url: URL, kind: CourseFileKind) async throws -> String {
        let pages = try await pages(at: url, kind: kind)
        let joined = pages.map(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.isEmpty { throw FileTextExtractorError.empty }
        return joined
    }

    private static func pdfPages(at url: URL) throws -> [FileTextPage] {
        guard let document = PDFDocument(url: url) else {
            throw FileTextExtractorError.unreadable
        }
        var pages: [FileTextPage] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let raw = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !raw.isEmpty {
                pages.append(FileTextPage(pageIndex: index, text: raw))
            }
        }
        if pages.isEmpty {
            // Self.log.info("Quiz PDF empty path=\(url.lastPathComponent, privacy: .public)")
            throw FileTextExtractorError.empty
        }
        return pages
    }

    private static func imageText(at url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        guard let image = UIImage(data: data), let cgImage = image.cgImage else {
            throw FileTextExtractorError.unreadable
        }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if joined.isEmpty {
                    continuation.resume(throwing: FileTextExtractorError.empty)
                } else {
                    continuation.resume(returning: joined)
                }
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum FileTextExtractorError: Error {
    case unreadable
    case empty
}
