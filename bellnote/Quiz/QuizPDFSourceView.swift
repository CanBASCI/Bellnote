import OSLog
import PDFKit
import SwiftUI

/// Read-only PDF sheet for a quiz Source tap: opens at the material page and selects the passage when found.
struct QuizPDFSourceView: View {
    let url: URL
    let title: String
    let pageIndex: Int?
    let excerpt: String
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            QuizPDFKitView(url: url, pageIndex: pageIndex, excerpt: excerpt)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { onDismiss() }
                    }
                }
        }
    }
}

private struct QuizPDFKitView: UIViewRepresentable {
    private static let log = Logger(subsystem: "app.bellnote", category: "quiz")

    let url: URL
    let pageIndex: Int?
    let excerpt: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        let jumpKey = "\(url.standardizedFileURL.path)#\(pageIndex.map(String.init) ?? "-")#\(excerpt)"
        let needsDocument =
            view.document == nil
            || view.document?.documentURL?.standardizedFileURL != url.standardizedFileURL
        if needsDocument {
            guard let document = PDFDocument(url: url) else {
                Self.log.error("Quiz PDF open failed path=\(self.url.lastPathComponent, privacy: .public)")
                return
            }
            view.document = document
            context.coordinator.lastJumpKey = nil
        }
        guard context.coordinator.lastJumpKey != jumpKey else { return }
        context.coordinator.lastJumpKey = jumpKey
        // PDFView ignores go(to:) until it has a laid-out frame.
        scheduleJump(on: view, attempt: 0)
    }

    private func scheduleJump(on view: PDFView, attempt: Int) {
        let delay = attempt == 0 ? 0.05 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let landed = performJump(on: view)
            if !landed, attempt < 2 {
                scheduleJump(on: view, attempt: attempt + 1)
            }
        }
    }

    @discardableResult
    private func performJump(on view: PDFView) -> Bool {
        guard let document = view.document else { return false }
        if view.bounds.width < 2 || view.bounds.height < 2 {
            return false
        }

        let queries = Self.findQueries(from: excerpt)
        for query in queries {
            let hits = document.findString(query, withOptions: [.caseInsensitive])
            if let hit = preferredHit(in: hits, document: document) {
                view.currentSelection = hit
                show(hit, in: view, document: document)
                return true
            }
        }

        if let pageIndex, pageIndex >= 0, pageIndex < document.pageCount,
           let page = document.page(at: pageIndex)
        {
            let box = page.bounds(for: view.displayBox)
            let destination = PDFDestination(page: page, at: CGPoint(x: 0, y: box.maxY))
            view.go(to: destination)
            // Self.log.info("Quiz PDF jump page=\(pageIndex) (find miss)")
            return true
        }

        // Self.log.info(
            // "Quiz PDF jump missed page=\(self.pageIndex ?? -1) excerptChars=\(self.excerpt.count)"
        // )
        return false
    }

    /// A window starts on `pageIndex` and may run on to the next pages, so the passage is never above it.
    /// The first match at or after that page wins; a match above it is a repeated phrase.
    private func preferredHit(in hits: [PDFSelection], document: PDFDocument) -> PDFSelection? {
        guard let pageIndex else { return hits.first }
        let later = hits.first { hit in
            guard let page = hit.pages.first else { return false }
            return document.index(for: page) >= pageIndex
        }
        return later ?? hits.first
    }

    /// Opens the page that holds the passage, from its top, so the highlight is on screen with the text around it.
    /// `go(to:)` with the selection scrolls the passage to the top edge, and when it sits low on the page the
    /// student lands on the start of the next page. A page taller than the view is scrolled to just above the passage.
    private func show(_ hit: PDFSelection, in view: PDFView, document: PDFDocument) {
        guard let page = hit.pages.first else {
            view.go(to: hit)
            return
        }
        let box = page.bounds(for: view.displayBox)
        let passage = hit.bounds(for: page)
        let pageFits = box.height * view.scaleFactor <= view.bounds.height
        let top = pageFits ? box.maxY : min(box.maxY, passage.maxY + 60)
        view.go(to: PDFDestination(page: page, at: CGPoint(x: box.minX, y: top)))
    }

    /// Queries that usually still match a PDF text layer after OCR/spacing quirks.
    private static func findQueries(from excerpt: String) -> [String] {
        let normalized = normalize(excerpt)
        guard !normalized.isEmpty else { return [] }
        var queries: [String] = []
        func add(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 12, !queries.contains(trimmed) else { return }
            queries.append(trimmed)
        }
        add(normalized)
        if normalized.count > 48 {
            add(String(normalized.prefix(48)))
        }
        if normalized.count > 28 {
            add(String(normalized.prefix(28)))
        }
        let words = normalized.split(separator: " ").map(String.init)
        if words.count >= 4 {
            add(words.prefix(4).joined(separator: " "))
        }
        if words.count >= 6 {
            add(words.prefix(6).joined(separator: " "))
        }
        return queries
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    final class Coordinator {
        var lastJumpKey: String?
    }
}
