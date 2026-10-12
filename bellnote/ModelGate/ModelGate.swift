import Foundation

actor ModelGate {
    enum Resident: Sendable {
        case none
        case tagger
        case page
    }

    private(set) var resident: Resident = .none
    private var cancelledLectureIDs: Set<UUID> = []

    func loadTagger() {
        resident = .tagger
    }

    func loadPage() {
        resident = .none
        resident = .page
    }

    func unload() {
        resident = .none
    }

    func cancel(lecture id: UUID) {
        cancelledLectureIDs.insert(id)
        resident = .none
    }

    func isCancelled(_ id: UUID) -> Bool {
        cancelledLectureIDs.contains(id)
    }
}
