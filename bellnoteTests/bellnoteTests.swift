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

@Test func turkishDueHintsAreRead() {
    #expect(DueDateMath.parse("Haftaya bu konuyu araştırıp gelin") == .nextWeek)
    #expect(DueDateMath.parse("Bir sonraki derse kadar okuyun") == .nextWeek)
    #expect(DueDateMath.parse("Yarın teslim edin") == .tomorrow)
    #expect(DueDateMath.parse("3 gün sonra getirin") == .inDays(3))
    #expect(DueDateMath.parse("2 hafta sonra") == .inDays(14))
    #expect(DueDateMath.parse("Bu konuyu çalışın") == nil)
}

@Test func nextWeekIsTheSameWeekdayAtTheSlotHour() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let lecture = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 10, minute: 7)) ?? Date()
    let slot = DueDateMath.due(from: lecture, hint: .nextWeek, slotStartMinutes: 10 * 60, calendar: calendar)
    let slotParts = calendar.dateComponents([.day, .hour, .minute], from: slot)
    #expect(slotParts.day == 12 && slotParts.hour == 10 && slotParts.minute == 0)
    let plain = DueDateMath.due(from: lecture, hint: .nextWeek, calendar: calendar)
    let plainParts = calendar.dateComponents([.day, .hour, .minute], from: plain)
    #expect(plainParts.day == 12 && plainParts.hour == 10 && plainParts.minute == 7)
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
    #expect(ModelLock.installedGigabytes(3_840_000_000) == 4)
    #expect(ModelLock.installedGigabytes(5_910_110_208) == 6)
    #expect(ModelLock.installedGigabytes(8_022_114_304) == 8)
    #expect(ModelLock.installedGigabytes(12_034_228_224) == 12)
    let eightGigabytePhone = DeviceBudget(freeDiskBytes: 20_000_000_000, physicalMemoryBytes: 8_022_114_304)
    #expect(!ModelLock.taggerLocked(eightGigabytePhone))
    #expect(!ModelLock.pageLocked(eightGigabytePhone))
    let sixGigabytePhone = DeviceBudget(freeDiskBytes: 20_000_000_000, physicalMemoryBytes: 5_910_110_208)
    #expect(!ModelLock.taggerLocked(sixGigabytePhone))
    #expect(ModelLock.pageLocked(sixGigabytePhone))
}

@Test func whisperLocksOnDiskOnly() {
    let smallPhone = DeviceBudget(freeDiskBytes: 20_000_000_000, physicalMemoryBytes: 5_910_110_208)
    #expect(!ModelLock.whisperLocked(smallPhone))
    #expect(ModelLock.locked(.whisper, DeviceBudget(freeDiskBytes: 1_000_000_000, physicalMemoryBytes: 8_022_114_304)))
    #expect(!ModelRole.whisper.isTextModel)
}

@Test func coreMLFoldersCountAsWeights() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("whisper-\(UUID().uuidString)", isDirectory: true)
    defer { try? manager.removeItem(at: root) }
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
    for name in ["AudioEncoder", "MelSpectrogram"] {
        let folder = root.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("model.mil"))
    }
    #expect(!HubWeights.snapshot(at: root, id: "test").isReady)
    let last = root.appendingPathComponent("TextDecoder.mlmodelc", isDirectory: true)
    try manager.createDirectory(at: last, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: last.appendingPathComponent("model.mil"))
    #expect(HubWeights.snapshot(at: root, id: "test").isReady)
}

@Test func wordsGoToTheSpeakerWhoseRunCoversThem() {
    func run(_ start: Int, _ end: Int, _ cluster: Int) -> SpeechRun {
        SpeechRun(start: start, end: end, cluster: cluster, overlap: false, near: false, addressedLecturer: false)
    }
    let runs = [run(0, 10, 1), run(10, 13, 2), run(13, 30, 1)]
    func word(_ start: Double, _ end: Double, _ text: String) -> LectureTranscriber.TimedWord {
        LectureTranscriber.TimedWord(start: start, end: end, text: text)
    }
    let words = [
        word(0.5, 1.0, " Bugün"), word(1.2, 2.0, " sınav"),
        word(10.2, 10.8, " Hocam"), word(11.0, 12.0, " ödev?"),
        word(14.0, 15.0, " Haftaya"), word(15.1, 16.0, " getirin."),
    ]
    let lines = LectureTranscriber.speakerLines(words: words, runs: runs)
    #expect(lines.map(\.text) == ["Bugün sınav", "Hocam ödev?", "Haftaya getirin."])
    #expect(lines.map(\.speaker) == [1, 2, 1])
    #expect(lines.map(\.second) == [0, 10, 14])
    #expect(lines[0].role == .narrator)
    #expect(lines[2].role == .narrator)
}

@Test func aWordInAGapStaysWithTheSpeakerBefore() {
    let runs = [
        SpeechRun(start: 0, end: 5, cluster: 1, overlap: false, near: false, addressedLecturer: false),
        SpeechRun(start: 20, end: 30, cluster: 2, overlap: false, near: false, addressedLecturer: false),
    ]
    let words = [
        LectureTranscriber.TimedWord(start: 1, end: 2, text: "bir"),
        LectureTranscriber.TimedWord(start: 10, end: 11, text: "iki"),
        LectureTranscriber.TimedWord(start: 21, end: 22, text: "üç"),
    ]
    let lines = LectureTranscriber.speakerLines(words: words, runs: runs)
    #expect(lines.map(\.text) == ["bir iki", "üç"])
    #expect(LectureTranscriber.speakerLines(words: words, runs: []).isEmpty)
}

@Test func pageModelFallsBackToTheOlderSwitch() {
    let suite = "bellnote.pageModel.test"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defaults.removePersistentDomain(forName: suite)
    #expect(AppPreferences.pageModel(defaults) == .page)
    defaults.set(true, forKey: AppPreferences.pagePrefersTaggerKey)
    #expect(AppPreferences.pageModel(defaults) == .tagger)
    defaults.set(ModelRole.page.rawValue, forKey: AppPreferences.pageModelKey)
    #expect(AppPreferences.pageModel(defaults) == .page)
    // A model that was removed from the app, or one that only hears audio, is never the AI model.
    defaults.set("gemmaSmall", forKey: AppPreferences.pageModelKey)
    #expect(AppPreferences.pageModel(defaults) == .tagger)
    defaults.set(ModelRole.whisper.rawValue, forKey: AppPreferences.pageModelKey)
    #expect(AppPreferences.pageModel(defaults) == .tagger)
    defaults.removePersistentDomain(forName: suite)
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
