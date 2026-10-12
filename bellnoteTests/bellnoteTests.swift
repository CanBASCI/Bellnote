import Foundation
import Testing
@testable import bellnote

@Test func topicMatchIgnoresCaseHyphenAndDiacritics() {
    #expect(TopicMatch.match(["p-value"], ["P value"]))
    #expect(TopicMatch.match(["café"], ["cafe"]))
    #expect(!TopicMatch.match(["mean"], ["expected value"]))
}

@Test func aliasMatchesMarkedPairOnly() {
    #expect(TopicMatch.match(["mean"], ["expected value"], aliases: [("mean", "expected value")]))
    #expect(!TopicMatch.match(["mean"], ["variance"], aliases: [("mean", "expected value")]))
}

@Test func bindStaysInsideCourseAndTime() {
    let course = UUID()
    let other = UUID()
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    let earlier = BindableBlock(courseId: course, at: day.addingTimeInterval(-86_400), topics: ["p-value"])
    let otherCourse = BindableBlock(courseId: other, at: day.addingTimeInterval(-86_400), topics: ["p-value"])
    let later = BindableBlock(courseId: course, at: day.addingTimeInterval(86_400), topics: ["p-value"])
    let current = BindableBlock(courseId: course, at: day, topics: ["P value"])
    let link = Linker.bind(current, in: [earlier, otherCourse, later], timeHint: TimeHint(daysBack: 14))
    #expect(link.to == earlier.id)
    #expect(link.why == "topic+time")
}

@Test func bindUsesEmbeddingOnlyAboveCutoff() {
    let course = UUID()
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    let weak = BindableBlock(courseId: course, at: day.addingTimeInterval(-100), topics: ["other"], embedding: [0, 1])
    let strong = BindableBlock(courseId: course, at: day.addingTimeInterval(-50), topics: ["other"], embedding: [1, 0])
    let current = BindableBlock(courseId: course, at: day, topics: ["unrelated"], embedding: [1, 0])
    let low = Linker.bind(current, in: [weak])
    #expect(low.to == nil)
    #expect(low.why == "no-match")
    let high = BindableBlock(courseId: course, at: day, topics: ["unrelated"], embedding: [1, 0])
    let hit = Linker.bind(high, in: [strong])
    #expect(hit.to == strong.id)
}

@Test func dueDateFromLectureHint() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let lecture = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5)) ?? Date()
    let hint = DueDateMath.parse("next week")
    #expect(hint == .nextWeek)
    let due = DueDateMath.due(from: lecture, hint: .tomorrow, calendar: calendar)
    let parts = calendar.dateComponents([.day], from: due)
    #expect(parts.day == 6)
    let explicit = DueDateMath.parse("hand in on 2026-10-20", calendar: calendar)
    #expect(explicit == .explicit(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20)) ?? lecture))
}

@Test func missedStaysMissedAndCancelledDoesNotCount() {
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    let sessions = [
        SessionMark(day: day, kind: .recorded),
        SessionMark(day: day, kind: .missed),
        SessionMark(day: day, kind: .cancelled),
        SessionMark(day: day, kind: .noRecording)
    ]
    let counts = GapRules.counts(in: sessions)
    #expect(counts.missed == 1)
    #expect(counts.cancelled == 1)
    #expect(GapRules.subtractsHours(.cancelled))
    #expect(!GapRules.subtractsHours(.missed))
}

@Test func examRowsSortByDateThenTime() {
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    let rows = [
        ExamRow(id: UUID(), courseName: "B", kind: "final", date: day, startMinutes: 90, endMinutes: 120),
        ExamRow(id: UUID(), courseName: "A", kind: "midterm", date: day.addingTimeInterval(-86_400), startMinutes: nil, endMinutes: nil),
        ExamRow(id: UUID(), courseName: "C", kind: "other", date: day, startMinutes: 30, endMinutes: 60),
        ExamRow(id: UUID(), courseName: "D", kind: "other", date: nil, startMinutes: nil, endMinutes: nil)
    ]
    let ordered = ExamSort.ordered(rows)
    #expect(ordered.map(\.courseName) == ["A", "C", "B", "D"])
    let marked = ExamSort.markingOverlaps([
        ExamRow(id: UUID(), courseName: "A", kind: "midterm", date: day, startMinutes: 60, endMinutes: 120),
        ExamRow(id: UUID(), courseName: "B", kind: "final", date: day, startMinutes: 90, endMinutes: 150)
    ])
    #expect(marked[0].overlaps)
    #expect(marked[1].overlaps)
}

@Test func modelRowsLockOnDiskAndMemory() {
    let tight = DeviceBudget(freeDiskBytes: 1_000_000_000, physicalMemoryBytes: 6_000_000_000)
    #expect(ModelLock.taggerLocked(tight))
    #expect(ModelLock.pageLocked(tight))
    let eight = DeviceBudget(freeDiskBytes: 20_000_000_000, physicalMemoryBytes: ModelLock.eightGigabytes)
    #expect(!ModelLock.taggerLocked(eight))
    #expect(!ModelLock.pageLocked(eight))
    let lowMemory = DeviceBudget(freeDiskBytes: 20_000_000_000, physicalMemoryBytes: ModelLock.eightGigabytes - 1)
    #expect(!ModelLock.taggerLocked(lowMemory))
    #expect(ModelLock.pageLocked(lowMemory))
}

@Test func suggestionsStopAtThree() {
    let ids = (0..<5).map { _ in UUID() }
    let rows = Suggestions.make(
        examTopicsWithoutNote: ids,
        dueAssignments: ids,
        missedEmphasis: ids,
        nilLinks: ids,
        missingFormulas: ids
    )
    #expect(rows.count == 3)
    #expect(rows.allSatisfy { $0.kind == .examTopicMissing })
}
