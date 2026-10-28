import OSLog
import PencilKit
import PhotosUI
import QuickLook
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The courses of the open term, as folders. The order is the home order.
struct FilesPage: View {
    @Bindable var term: Term

    private var courses: [Course] {
        term.courses.sorted { lhs, rhs in
            if lhs.homeOrder != rhs.homeOrder { return lhs.homeOrder < rhs.homeOrder }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if courses.isEmpty {
                ContentUnavailableView("No courses yet", systemImage: "folder")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 16)], spacing: 22) {
                        ForEach(courses) { course in
                            NavigationLink {
                                CourseCabinetPage(course: course)
                            } label: {
                                folder(course)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One course, drawn as a folder in that course’s color. The name sits under it, as in the Finder.
    private func folder(_ course: Course) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 68))
                .foregroundStyle(course.color)
                .accessibilityHidden(true)
            Text(course.name)
                .appFont(.footnote)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 96)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The console line for a file edit that the screen reports as unsaved. Domain and code say which step failed.
private nonisolated func logFileFailure(_ error: Error, step: String) {
    let ns = error as NSError
    Logger(subsystem: "app.bellnote", category: "files").error(
        "File save failed at \(step, privacy: .public): \(String(describing: error), privacy: .public) [\(ns.domain, privacy: .public) \(ns.code, privacy: .public)] \(ns.localizedDescription, privacy: .public)"
    )
}

extension View {
    /// The plain list draws a line above the first row and under the last. Those two are not the lines between rows.
    /// Hiding the edge is not enough on this list, so the line is also painted in the page ground.
    @ViewBuilder
    fileprivate func fileEdgeSeparators(first: Bool, last: Bool) -> some View {
        let ground = Color(.systemGroupedBackground)
        if first, last {
            listRowSeparator(.hidden, edges: .all)
                .listRowSeparatorTint(ground, edges: .all)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.trailing] }
                .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
        } else if first {
            listRowSeparator(.hidden, edges: .top)
                .listRowSeparatorTint(ground, edges: .top)
        } else if last {
            listRowSeparator(.hidden, edges: .bottom)
                .listRowSeparatorTint(ground, edges: .bottom)
        } else {
            self
        }
    }
}

/// The file rows are one reorderable collection, the same kind of drag as the home course list.
private enum CourseFileList: Hashable, Sendable {
    case files
}

private enum CabinetSegment: String, CaseIterable, Identifiable {
    case files
    case stickies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: String(localized: "Files")
        case .stickies: String(localized: "Stickies")
        }
    }
}

/// Files and stickies for one course. The picker is this course only.
private struct CourseCabinetPage: View {
    @Bindable var course: Course
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    @State private var segment: CabinetSegment = .files
    @State private var importing = false
    @State private var pickingPhoto = false
    @State private var photoItem: PhotosPickerItem?
    @State private var previewURL: URL?
    @State private var pendingFile: CourseFile?
    @State private var pendingSticky: StickyNote?
    @State private var creatingSticky = false
    @State private var editingSticky: StickyNote?
    @State private var selectedSticky: UUID?
    @State private var fileNotice: String?

    private var files: [CourseFile] {
        course.files.sorted { lhs, rhs in
            if lhs.listOrder != rhs.listOrder { return lhs.listOrder < rhs.listOrder }
            return lhs.addedAt > rhs.addedAt
        }
    }

    /// Older notes sit further back. A note that was just moved comes forward.
    private var stickies: [StickyNote] {
        course.stickies.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.token.uuidString < rhs.token.uuidString
        }
    }

    var body: some View {
        Group {
            switch segment {
            case .files:
                fileList
            case .stickies:
                stickyBoard
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        // The same place as AI correction, Raw, and Assignments: under the title, and the page moves under it.
        .safeAreaBar(edge: .top) {
            Picker("", selection: $segment) {
                ForEach(CabinetSegment.allCases) { item in
                    Text(verbatim: item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .scenePadding(.horizontal)
            .padding(.bottom, 12)
        }
        .onChange(of: course.stickies.count) { oldCount, newCount in
            guard newCount > oldCount else {
                if let selectedSticky, !course.stickies.contains(where: { $0.token == selectedSticky }) {
                    self.selectedSticky = nil
                }
                return
            }
            if let newest = course.stickies.max(by: { $0.createdAt < $1.createdAt }) {
                selectedSticky = newest.token
            }
        }
        .navigationTitle(course.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if segment == .files {
                    Menu {
                        Button("Add file", systemImage: "doc.badge.plus") { importing = true }
                        Button("Add photo", systemImage: "photo.badge.plus") { pickingPhoto = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text("Add file"))
                } else {
                    Button("New sticky", systemImage: "plus") { creatingSticky = true }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls { importFile(url) }
            case .failure(let error):
                report(error, notice: String(localized: "The file could not be added."))
            }
        }
        .photosPicker(isPresented: $pickingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await importPhoto(item) }
        }
        .fullScreenCover(isPresented: Binding(
            get: { previewURL != nil },
            set: { if !$0 { previewURL = nil } }
        )) {
            if let url = previewURL {
                StoredFilePreview(url: url) { error in
                    report(error, notice: String(localized: "The change could not be saved."))
                } onEdited: {
                    markFileUpdated(at: url)
                } onDismiss: {
                    previewURL = nil
                }
            }
        }
        .sheet(isPresented: $creatingSticky) {
            StickyEditor(course: course, editing: nil)
        }
        .sheet(item: $editingSticky) { note in
            StickyEditor(course: course, editing: note)
        }
        .alert(
            "Delete this file?",
            isPresented: Binding(
                get: { pendingFile != nil },
                set: { if !$0 { pendingFile = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let file = pendingFile { delete(file) }
                pendingFile = nil
            }
            Button("Cancel", role: .cancel) { pendingFile = nil }
        } message: {
            Text("This copy will be deleted. The original file stays. This cannot be undone.")
        }
        .alert(
            "Delete this sticky?",
            isPresented: Binding(
                get: { pendingSticky != nil },
                set: { if !$0 { pendingSticky = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let note = pendingSticky { delete(note) }
                pendingSticky = nil
            }
            Button("Cancel", role: .cancel) { pendingSticky = nil }
        } message: {
            Text("This sticky will be deleted. This cannot be undone.")
        }
        .alert(
            fileNotice ?? "",
            isPresented: Binding(
                get: { fileNotice != nil },
                set: { if !$0 { fileNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) { fileNotice = nil }
        }
    }

    /// The same square and gap as a recording on This week.
    private static let coverSize: CGFloat = 48
    private static let coverGap: CGFloat = 12

    private func fileRow(_ file: CourseFile) -> some View {
        let separatorStart = Self.coverSize + Self.coverGap
        return HStack(alignment: .center, spacing: Self.coverGap) {
            fileCover(symbol(for: file))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: fileDetail(file))
                    .appFont(.subheadline, weight: .medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: file.displayName)
                    .appFont(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            fileDates(file)
        }
        // The line between rows starts at the name, not under the square, as on This week.
        .alignmentGuide(.listRowSeparatorLeading) { [separatorStart] _ in
            separatorStart
        }
    }

    /// An outlined square. The line is secondary and the symbol is primary. No glass.
    private func fileCover(_ systemName: String) -> some View {
        let size = Self.coverSize
        let shape = RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
        return Image(systemName: systemName)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background {
                shape.strokeBorder(Color.secondary, lineWidth: max(1.5, size * 0.045))
            }
            .accessibilityHidden(true)
    }

    /// The added day stays. One later edit replaces the day above it. Edits are not listed.
    private func fileDates(_ file: CourseFile) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let updated = file.updatedAt, updated.timeIntervalSince(file.addedAt) > 1 {
                Text(verbatim: dateLine(updated))
            }
            Text(verbatim: dateLine(file.addedAt))
        }
        .appFont(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .layoutPriority(1)
    }

    private func dateLine(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
    }

    private var fileList: some View {
        Group {
            if files.isEmpty {
                emptyCabinetLine("No files yet", systemImage: "doc")
            } else {
                fileRows
            }
        }
    }

    /// A secondary icon above a secondary title, centered. The title matches an unprocessed recording.
    private func emptyCabinetLine(_ title: LocalizedStringKey, systemImage: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .appFont(.title3, weight: .semibold)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileRows: some View {
        List {
            Section {
                ForEach(files) { file in
                    let isFirst = file.persistentModelID == files.first?.persistentModelID
                    let isLast = file.persistentModelID == files.last?.persistentModelID
                    Button {
                        open(file)
                    } label: {
                        fileRow(file)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(.vertical, 8)
                    .listRowBackground(Color(.systemGroupedBackground))
                    .fileEdgeSeparators(first: isFirst, last: isLast)
                    .askToDeleteSwipe { pendingFile = file }
                }
                .reorderable(collectionID: CourseFileList.files)
            }
            .listSectionSeparator(.hidden, edges: .all)
        }
        .reorderContainer(for: CourseFile.self, in: CourseFileList.self) { difference in
            applyFileOrder(difference)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listSectionSeparator(.hidden, edges: .all)
        .environment(\.defaultMinListHeaderHeight, 0)
        .background(Color(.systemGroupedBackground))
        .background(FileListChrome())
        // The list starts closer to the bar. Only the list moves; the bar and the tabs stay as they are.
        .contentMargins(.top, 0, for: .scrollContent)
    }

    private var stickyBoard: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selectedSticky = nil }
                if stickies.isEmpty {
                    emptyCabinetLine("No stickies yet", systemImage: "note.text")
                        .allowsHitTesting(false)
                }
                ForEach(stickies) { note in
                    StickyPaper(
                        note: note,
                        courseName: course.name,
                        boardSize: geo.size,
                        selected: selectedSticky == note.token,
                        onSelect: { selectedSticky = note.token },
                        onEdit: { editingSticky = note },
                        onDelete: { pendingSticky = note },
                        onCommit: commitCabinet
                    )
                    .zIndex(selectedSticky == note.token ? 1 : 0)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(.named("stickyBoard"))
        }
        .background(Color(.systemGroupedBackground))
        .onAppear(perform: separateStackedDefaults)
    }

    /// Notes saved before the board all shared one spot. Spread those, and leave a note the student has moved.
    private func separateStackedDefaults() {
        let stacked = stickies.filter { note in
            abs(note.centerX - 0.5) < 0.0001
                && abs(note.centerY - 0.28) < 0.0001
                && abs(note.rotation - (-6)) < 0.0001
        }
        guard stacked.count > 1 else { return }
        for (index, note) in stacked.enumerated() {
            let spot = StickyLayout.spot(index: index)
            note.centerX = spot.centerX
            note.centerY = spot.centerY
            note.rotation = spot.rotation
        }
        commitCabinet()
    }

    /// A new copy leads the list. After a drag, each row has its own place, so the new one takes the place above the first.
    private func placeNewFile(_ file: CourseFile) {
        file.listOrder = (course.files.map(\.listOrder).min() ?? 0) - 1
    }

    /// The same drag the home course list uses. The finger’s drop is the new order.
    private func applyFileOrder(_ difference: ReorderDifference<CourseFile.ID, CourseFileList>) {
        var rows = files
        let moving = difference.sources.compactMap { id in rows.first { $0.id == id } }
        guard moving.count == difference.sources.count, !moving.isEmpty else { return }
        let sourceIDs = Set(difference.sources)
        let destinationIndex: Int
        switch difference.destination.position {
        case .end:
            destinationIndex = rows.count
        case .before(let id):
            destinationIndex = rows.firstIndex { $0.id == id } ?? rows.count
        }
        let removedBefore = rows.prefix(destinationIndex).filter { sourceIDs.contains($0.id) }.count
        rows.removeAll { sourceIDs.contains($0.id) }
        let index = min(destinationIndex - removedBefore, rows.count)
        rows.insert(contentsOf: moving, at: index)
        for (place, file) in rows.enumerated() where file.listOrder != place {
            file.listOrder = place
        }
        commitCabinet()
    }

    private func commitCabinet() {
        guard modelContext.hasChanges else { return }
        do {
            try modelContext.save()
        } catch {
            report(error, notice: String(localized: "The change could not be saved."))
        }
    }

    private func symbol(for file: CourseFile) -> String {
        switch CourseFileKind(rawValue: file.kind) {
        case .pdf: "doc.richtext"
        case .slide: "rectangle.on.rectangle"
        case .image: "photo"
        case .other, nil: "doc"
        }
    }

    private func fileDetail(_ file: CourseFile) -> String {
        let ext = URL(fileURLWithPath: file.displayName).pathExtension
        if !ext.isEmpty { return ext.uppercased() }
        return String(localized: "Other")
    }

    private func open(_ file: CourseFile) {
        do {
            let url = try Vault.documents().appendingPathComponent(file.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                fileNotice = String(localized: "The file could not be opened.")
                return
            }
            previewURL = url
        } catch {
            report(error, notice: String(localized: "The file could not be opened."))
        }
    }

    private func importFile(_ url: URL) {
        do {
            let imported = try Vault.importCourseFile(courseID: course.token, from: url)
            let kind = CourseFileKind(url: URL(fileURLWithPath: imported.displayName))
            let file = CourseFile(
                course: course,
                relativePath: imported.relativePath,
                displayName: imported.displayName,
                kind: kind
            )
            placeNewFile(file)
            modelContext.insert(file)
            course.files.append(file)
            try modelContext.save()
        } catch {
            report(error, notice: String(localized: "The file could not be added."))
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
                fileNotice = String(localized: "The file could not be added.")
                return
            }
            let stamp = Date.now.formatted(date: .abbreviated, time: .shortened)
            let display = "\(String(localized: "Photo")) \(stamp)"
            let relative = try Vault.writeCourseData(
                courseID: course.token,
                data: data,
                fileExtension: "jpg",
                displayName: display
            )
            let file = CourseFile(course: course, relativePath: relative, displayName: display, kind: .image)
            placeNewFile(file)
            modelContext.insert(file)
            course.files.append(file)
            try modelContext.save()
        } catch {
            report(error, notice: String(localized: "The file could not be added."))
        }
    }

    /// A preview edit was written into this copy. The row then shows that date above the day it was added.
    private func markFileUpdated(at url: URL) {
        let root: URL
        do {
            root = try Vault.documents()
        } catch {
            report(error, notice: String(localized: "The change could not be saved."))
            return
        }
        let wanted = url.standardizedFileURL.path
        guard let file = course.files.first(where: {
            root.appendingPathComponent($0.relativePath).standardizedFileURL.path == wanted
        }) else {
            Logger(subsystem: "app.bellnote", category: "files").error("Edited file was not on this course")
            return
        }
        // One date. The next edit replaces it.
        file.updatedAt = .now
        commitCabinet()
    }

    private func delete(_ file: CourseFile) {
        do {
            try Vault.removeStoredFile(relativePath: file.relativePath)
            modelContext.delete(file)
            try modelContext.save()
        } catch {
            report(error, notice: String(localized: "The file could not be deleted."))
        }
    }

    private func delete(_ note: StickyNote) {
        modelContext.delete(note)
        do {
            try modelContext.save()
        } catch {
            report(error, notice: String(localized: "The change could not be saved."))
        }
    }

    private func report(_ error: Error, notice: String) {
        logFileFailure(error, step: notice)
        fileNotice = notice
    }
}

/// Where a new note lands, and the slight turn that keeps it from looking like a row.
private enum StickyLayout {
    private static let tilts = [-8.0, 6.0, -4.0, 9.0, -5.0, 3.0]

    static func spot(index: Int) -> (centerX: Double, centerY: Double, rotation: Double) {
        let slot = ((index % 6) + 6) % 6
        let column = slot % 3
        let row = slot / 3
        return (
            centerX: 0.24 + Double(column) * 0.26,
            centerY: 0.26 + Double(row) * 0.30,
            rotation: tilts[slot]
        )
    }
}

/// One paper note. Drag moves it. The corner changes its size. The top knob turns it.
private struct StickyPaper: View {
    @Bindable var note: StickyNote
    var courseName: String
    var boardSize: CGSize
    var selected: Bool
    var onSelect: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onCommit: () -> Void

    @State private var moveStart: CGPoint?
    @State private var resizeStart: (width: Double, height: Double, centerX: Double, centerY: Double)?
    @State private var rotationStart: Double?
    @State private var pinchStart: CGSize?
    /// The strokes, once read off the note. The paper draws this, not only the value SwiftData has already faulted.
    @State private var inkData: Data?

    private var paperWidth: CGFloat {
        min(max(CGFloat(note.width), 128), max(160, boardSize.width * 0.9))
    }

    private var paperHeight: CGFloat {
        min(max(CGFloat(note.height), 112), max(140, boardSize.height * 0.75))
    }

    private var maxPaper: CGSize {
        CGSize(width: max(160, boardSize.width * 0.9), height: max(140, boardSize.height * 0.75))
    }

    var body: some View {
        let width = paperWidth
        let height = paperHeight
        ZStack {
            paper(width: width, height: height)
            if selected {
                knob("arrow.clockwise", "Rotate")
                    .offset(y: -height / 2 - 20)
                    .highPriorityGesture(rotateDrag)
                knob("arrow.down.right", "Resize")
                    .offset(x: width / 2, y: height / 2)
                    .highPriorityGesture(resizeDrag)
            }
        }
        .frame(width: selected ? width + 88 : width, height: selected ? height + 88 : height)
        .rotationEffect(.degrees(note.rotation))
        .position(center)
    }

    private var center: CGPoint {
        guard boardSize.width > 1, boardSize.height > 1 else { return .zero }
        return CGPoint(
            x: CGFloat(note.centerX) * boardSize.width,
            y: CGFloat(note.centerY) * boardSize.height
        )
    }

    private func paper(width: CGFloat, height: CGFloat) -> some View {
        let live = note.drawingData
        let stored = (live?.isEmpty == false) ? live : inkData
        let drawn = stored?.isEmpty == false
        return ZStack(alignment: .topLeading) {
            if drawn, let data = stored {
                StickyInk(data: data, paper: .white)
                    .allowsHitTesting(false)
            } else {
                Text(verbatim: note.text)
                    .appFont(.body)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(10)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(14)
            }
        }
        .frame(width: width, height: height)
        .background(
            drawn ? Color.white : CourseStyle.color(at: note.colorIndex, fallbackName: courseName),
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(drawn ? Color.primary : Color.white.opacity(0.92), lineWidth: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .onTapGesture {
            if selected { onEdit() } else { onSelect() }
        }
        .contextMenu {
            Button("Edit sticky", systemImage: "pencil") { onEdit() }
            Button("Delete", systemImage: "trash", role: .destructive) { onDelete() }
        }
        .gesture(moveDrag)
        .simultaneousGesture(pinch)
        .simultaneousGesture(twist)
        .accessibilityLabel(paperLabel(drawn: drawn))
        .accessibilityAddTraits(.isButton)
        // The strokes live beside the note. Reading them here loads that copy onto the paper.
        // Width changes when a drawing is attached, including when the note was already on screen.
        .task(id: note.updatedAt) {
            loadInk()
        }
        .task(id: note.drawingWidth) {
            loadInk()
        }
    }

    private func loadInk() {
        guard let data = note.drawingData, !data.isEmpty else { return }
        inkData = data
    }

    private func paperLabel(drawn: Bool) -> Text {
        let words = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty, drawn { return Text("Drawing") }
        return Text(verbatim: note.text)
    }

    private func knob(_ systemName: String, _ label: LocalizedStringKey, tint: Color = .primary) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(.background, in: Circle())
            .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
            .accessibilityLabel(Text(label))
    }

    private var moveDrag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("stickyBoard"))
            .onChanged { value in
                guard boardSize.width > 1, boardSize.height > 1 else { return }
                if moveStart == nil {
                    moveStart = CGPoint(
                        x: CGFloat(note.centerX) * boardSize.width,
                        y: CGFloat(note.centerY) * boardSize.height
                    )
                    onSelect()
                }
                let origin = moveStart ?? .zero
                let x = origin.x + value.translation.width
                let y = origin.y + value.translation.height
                note.centerX = min(max(Double(x / boardSize.width), 0.1), 0.9)
                note.centerY = min(max(Double(y / boardSize.height), 0.1), 0.9)
            }
            .onEnded { _ in
                moveStart = nil
                finish()
            }
    }

    private var resizeDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("stickyBoard"))
            .onChanged { value in
                guard boardSize.width > 1, boardSize.height > 1 else { return }
                if resizeStart == nil {
                    resizeStart = (note.width, note.height, note.centerX, note.centerY)
                    onSelect()
                }
                guard let start = resizeStart else { return }
                let theta = note.rotation * .pi / 180
                let cosT = cos(theta)
                let sinT = sin(theta)
                let tx = Double(value.translation.width)
                let ty = Double(value.translation.height)
                let localX = tx * cosT + ty * sinT
                let localY = -tx * sinT + ty * cosT
                let width = min(max(start.width + localX, 128), Double(maxPaper.width))
                let height = min(max(start.height + localY, 112), Double(maxPaper.height))
                let dw = width - start.width
                let dh = height - start.height
                let shiftX = (dw / 2) * cosT - (dh / 2) * sinT
                let shiftY = (dw / 2) * sinT + (dh / 2) * cosT
                let boardW = Double(boardSize.width)
                let boardH = Double(boardSize.height)
                note.width = width
                note.height = height
                note.centerX = min(max((start.centerX * boardW + shiftX) / boardW, 0.08), 0.92)
                note.centerY = min(max((start.centerY * boardH + shiftY) / boardH, 0.08), 0.92)
            }
            .onEnded { _ in
                resizeStart = nil
                finish()
            }
    }

    private var rotateDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("stickyBoard"))
            .onChanged { value in
                guard boardSize.width > 1, boardSize.height > 1 else { return }
                if !selected { onSelect() }
                let dx = Double(value.location.x) - note.centerX * Double(boardSize.width)
                let dy = Double(value.location.y) - note.centerY * Double(boardSize.height)
                guard hypot(dx, dy) > 8 else { return }
                note.rotation = atan2(dx, -dy) * 180 / .pi
            }
            .onEnded { _ in
                finish()
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil {
                    pinchStart = CGSize(width: CGFloat(note.width), height: CGFloat(note.height))
                    onSelect()
                }
                let start = pinchStart ?? CGSize(width: CGFloat(note.width), height: CGFloat(note.height))
                let scale = Double(value.magnification)
                note.width = min(max(Double(start.width) * scale, 128), Double(maxPaper.width))
                note.height = min(max(Double(start.height) * scale, 112), Double(maxPaper.height))
            }
            .onEnded { _ in
                pinchStart = nil
                finish()
            }
    }

    private var twist: some Gesture {
        RotateGesture()
            .onChanged { value in
                if rotationStart == nil {
                    rotationStart = note.rotation
                    onSelect()
                }
                note.rotation = (rotationStart ?? note.rotation) + value.rotation.degrees
            }
            .onEnded { _ in
                rotationStart = nil
                finish()
            }
    }

    private func finish() {
        note.updatedAt = .now
        onCommit()
    }
}

/// Writes one sticky. A new note opens in the course color. The twelve palette colors are the choices.
/// The drawing control turns the text field into the page the student draws, and that drawing is the note.
private struct StickyEditor: View {
    @Bindable var course: Course
    private let editing: StickyNote?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var colorIndex: Int
    @State private var drawing: PKDrawing
    @State private var drawingSize: CGSize
    @State private var drawingMode: Bool
    @State private var detent: PresentationDetent
    @FocusState private var textFocused: Bool

    init(course: Course, editing: StickyNote?) {
        self.course = course
        self.editing = editing
        _text = State(initialValue: editing?.text ?? "")
        let stored = editing?.colorIndex ?? course.colorIndex
        _colorIndex = State(initialValue: stored >= 0 ? stored : 0)
        let restored = Self.restoredDrawing(editing?.drawingData)
        _drawing = State(initialValue: restored.drawing)
        _drawingSize = State(initialValue: CGSize(width: editing?.drawingWidth ?? 0, height: editing?.drawingHeight ?? 0))
        _drawingMode = State(initialValue: restored.hasInk)
        _detent = State(initialValue: restored.hasInk ? .large : .medium)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasInk: Bool { !drawing.strokes.isEmpty }

    private var canSave: Bool { drawingMode ? hasInk : !trimmed.isEmpty }

    private var paperColor: Color {
        CourseStyle.color(at: colorIndex, fallbackName: course.name)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if drawingMode {
                        StickyCanvas(drawing: $drawing, canvasSize: $drawingSize, pen: UIColor(paperColor))
                    } else {
                        // The same line range as before the draw control. The control sits in an overlay, so it
                        // does not take part in this height.
                        TextField("Sticky", text: $text, axis: .vertical)
                            .focused($textFocused)
                            .lineLimit(4...12)
                            .padding(12)
                            .padding(.trailing, 36)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .topTrailing) {
                    if drawingMode {
                        Button(action: closeDrawing) {
                            Image(systemName: "keyboard")
                                .font(.body)
                                .foregroundStyle(.primary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Write"))
                    } else {
                        Button(action: openDrawing) {
                            Image(systemName: "scribble")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Draw"))
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: drawingMode ? 4 : 12, style: .continuous)
                        .fill(drawingMode ? Color.white : Color(.secondarySystemBackground))
                }
                .clipShape(RoundedRectangle(cornerRadius: drawingMode ? 4 : 12, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 4)], spacing: 4) {
                    ForEach(0..<CourseStyle.paletteCount, id: \.self) { index in
                        Button {
                            colorIndex = index
                        } label: {
                            Circle()
                                .fill(CourseStyle.color(at: index, fallbackName: course.name))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if colorIndex == index {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(CourseStyle.paletteTitle(at: index)))
                        .accessibilityAddTraits(colorIndex == index ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .background(Color(.systemBackground))
            }
            .navigationTitle(editing == nil ? LocalizedStringKey("New sticky") : LocalizedStringKey("Edit sticky"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
    }

    private func openDrawing() {
        textFocused = false
        drawingMode = true
        detent = .large
    }

    /// Leaves the drawing page for the text field. Strokes stay until Save, so the student can come back.
    private func closeDrawing() {
        drawingMode = false
        detent = .medium
    }

    private static func restoredDrawing(_ data: Data?) -> (drawing: PKDrawing, hasInk: Bool) {
        guard let data, !data.isEmpty else { return (PKDrawing(), false) }
        do {
            let drawing = try PKDrawing(data: data)
            return (drawing, !drawing.strokes.isEmpty)
        } catch {
            Logger(subsystem: "app.bellnote", category: "files").error(
                "Sticky drawing could not be opened: \(error.localizedDescription, privacy: .public)"
            )
            return (PKDrawing(), false)
        }
    }

    private func save() {
        guard canSave else { return }
        let ink = drawingMode && hasInk ? drawing.dataRepresentation() : nil
        let strokeBounds = drawing.bounds
        let pageWidth = ink == nil ? 0 : Double(strokeBounds.width)
        let pageHeight = ink == nil ? 0 : Double(strokeBounds.height)
        let words = trimmed
        if let editing {
            editing.text = words
            editing.colorIndex = colorIndex
            editing.drawingData = ink
            editing.drawingWidth = pageWidth
            editing.drawingHeight = pageHeight
            editing.updatedAt = .now
        } else {
            let spot = StickyLayout.spot(index: course.stickies.count)
            let note = StickyNote(
                course: course,
                text: words,
                colorIndex: colorIndex,
                centerX: spot.centerX,
                centerY: spot.centerY,
                width: ink == nil ? 168 : 230,
                height: ink == nil ? 156 : 280,
                rotation: spot.rotation
            )
            modelContext.insert(note)
            // The strokes are attached after the note is in the store. Set on a note that is not inserted yet,
            // they were dropped, so the saved paper had no drawing.
            note.drawingData = ink
            note.drawingWidth = pageWidth
            note.drawingHeight = pageHeight
            note.updatedAt = .now
            course.stickies.append(note)
        }
        do {
            try modelContext.save()
            dismiss()
        } catch {
            Logger(subsystem: "app.bellnote", category: "files").error(
                "Sticky save failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

/// One page of ink. The page is white. The pen is the color chosen below, and a stroke keeps that color.
/// The page does not scroll, so the strokes stay on the sticky.
private struct StickyCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    @Binding var canvasSize: CGSize
    var pen: UIColor

    func makeCoordinator() -> Coordinator {
        Coordinator(drawing: $drawing, canvasSize: $canvasSize)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawing = drawing
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.tool = PKInkingTool(.pen, color: pen, width: 6)
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.drawing = $drawing
        context.coordinator.canvasSize = $canvasSize
        canvas.delegate = context.coordinator
        canvas.backgroundColor = .white
        canvas.tool = PKInkingTool(.pen, color: pen, width: 6)
        // Only the first pass copies a stored drawing in. Later refreshes must not replace the strokes
        // the student is drawing, or the save would keep an empty page.
        // The delegate is off for that copy. Setting the drawing otherwise writes the binding during this update.
        guard !context.coordinator.didLoad else { return }
        canvas.delegate = nil
        canvas.drawing = drawing
        canvas.delegate = context.coordinator
        context.coordinator.didLoad = true
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var drawing: Binding<PKDrawing>
        var canvasSize: Binding<CGSize>
        var didLoad = false

        init(drawing: Binding<PKDrawing>, canvasSize: Binding<CGSize>) {
            self.drawing = drawing
            self.canvasSize = canvasSize
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let ink = canvasView.drawing
            drawing.wrappedValue = ink
            let bounds = ink.bounds
            if bounds.width > 0.5, bounds.height > 0.5 {
                canvasSize.wrappedValue = bounds.size
            }
        }
    }
}

/// The strokes of one sticky, fitted onto its paper. The canvas draws the ink. A traced copy left the strokes off the page.
private struct StickyInk: UIViewRepresentable {
    let data: Data
    let paper: UIColor

    func makeUIView(context: Context) -> StickyInkCanvas {
        let canvas = StickyInkCanvas()
        canvas.backgroundColor = paper
        canvas.ink = data
        return canvas
    }

    func updateUIView(_ canvas: StickyInkCanvas, context: Context) {
        canvas.backgroundColor = paper
        canvas.ink = data
    }
}

/// Shows one saved drawing inside the sticky. Finger drags pass through to the paper.
private final class StickyInkCanvas: PKCanvasView {
    var ink = Data() {
        didSet {
            guard ink != oldValue else { return }
            fittedInk = Data()
            setNeedsLayout()
        }
    }

    private var fittedInk = Data()
    private var fittedSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isScrollEnabled = false
        isOpaque = true
        minimumZoomScale = 1
        maximumZoomScale = 1
        drawingGestureRecognizer.isEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { return nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }
        guard size != fittedSize || ink != fittedInk else { return }
        fittedSize = size
        fittedInk = ink
        drawing = Self.fitted(ink, in: size) ?? PKDrawing()
        contentOffset = .zero
    }

    /// Moves the strokes into this paper. They were drawn on the large sheet, so their original place sits outside a sticky.
    private static func fitted(_ data: Data, in size: CGSize) -> PKDrawing? {
        guard !data.isEmpty else { return nil }
        let drawing: PKDrawing
        do {
            drawing = try PKDrawing(data: data)
        } catch {
            Logger(subsystem: "app.bellnote", category: "files").error(
                "Sticky drawing could not be opened: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
        guard !drawing.strokes.isEmpty else { return nil }
        var strokeBounds = drawing.bounds
        if strokeBounds.width < 1 { strokeBounds.size.width = 8 }
        if strokeBounds.height < 1 { strokeBounds.size.height = 8 }
        let margin: CGFloat = 12
        let available = CGSize(width: max(size.width - margin * 2, 1), height: max(size.height - margin * 2, 1))
        let scale = min(available.width / strokeBounds.width, available.height / strokeBounds.height)
        let transform = CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: -strokeBounds.midX * scale + size.width / 2,
            ty: -strokeBounds.midY * scale + size.height / 2
        )
        return drawing.transformed(using: transform)
    }
}

/// The system preview. Any edit made there is written back into the file the course keeps:
/// a pencil mark, typed text, or another markup tool. The arrow at the top still shares a separate copy out. It is not this save.
private struct StoredFilePreview: UIViewControllerRepresentable {
    let url: URL
    var onFailure: (Error) -> Void
    var onEdited: () -> Void
    var onDismiss: () -> Void

    func makeCoordinator() -> StoredFilePreviewCoordinator {
        StoredFilePreviewCoordinator(url: url, onFailure: onFailure, onEdited: onEdited, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> PreviewHostController {
        let host = PreviewHostController()
        host.preview.dataSource = context.coordinator
        host.preview.delegate = context.coordinator
        return host
    }

    func updateUIViewController(_ host: PreviewHostController, context: Context) {
        context.coordinator.url = url
        context.coordinator.onFailure = onFailure
        context.coordinator.onEdited = onEdited
        context.coordinator.onDismiss = onDismiss
        host.preview.dataSource = context.coordinator
        host.preview.delegate = context.coordinator
    }
}

/// Quick Look may call the delegate off the main thread. The file write finishes before that call returns,
/// because the system then deletes its copy. Anything that touches the screen hops to the main actor afterwards.
private final class StoredFilePreviewCoordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    nonisolated(unsafe) var url: URL
    var onFailure: (Error) -> Void
    var onEdited: () -> Void
    var onDismiss: () -> Void
    /// Quick Look already wrote the open file. A later copy error must not say the save failed.
    nonisolated(unsafe) var updatedInPlace = false

    init(
        url: URL,
        onFailure: @escaping (Error) -> Void,
        onEdited: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.url = url
        self.onFailure = onFailure
        self.onEdited = onEdited
        self.onDismiss = onDismiss
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        url as NSURL
    }

    /// Finished edits replace the bytes at this file’s own path. Text and the other tools are included.
    nonisolated func previewController(
        _ controller: QLPreviewController,
        editingModeFor previewItem: any QLPreviewItem
    ) -> QLPreviewItemEditingMode {
        .updateContents
    }

    nonisolated func previewController(_ controller: QLPreviewController, didUpdateContentsOf previewItem: any QLPreviewItem) {
        updatedInPlace = true
        Logger(subsystem: "app.bellnote", category: "files").info("Preview wrote the open file in place")
        onMainActor {
            controller.refreshCurrentPreviewItem()
            self.onEdited()
        }
    }

    nonisolated func previewController(
        _ controller: QLPreviewController,
        didSaveEditedCopyOf previewItem: any QLPreviewItem,
        at modifiedContentsURL: URL
    ) {
        let stored = url
        do {
            try Vault.replaceStoredFile(at: stored, with: modifiedContentsURL)
        } catch {
            logFileFailure(error, step: "preview copy")
            if updatedInPlace {
                Logger(subsystem: "app.bellnote", category: "files").error(
                    "Preview copy failed after the file was already saved in place. The notice is not shown."
                )
                onMainActor {
                    controller.refreshCurrentPreviewItem()
                    self.onEdited()
                }
                return
            }
            onMainActor {
                self.onFailure(error)
            }
            return
        }
        onMainActor {
            controller.refreshCurrentPreviewItem()
            self.onEdited()
        }
    }

    nonisolated func previewControllerDidDismiss(_ controller: QLPreviewController) {
        onMainActor {
            self.onDismiss()
        }
    }
}

/// `assumeIsolated` traps when Quick Look calls back off the main thread, which is where a PDF save finishes.
private nonisolated func onMainActor(_ work: @escaping @MainActor () -> Void) {
    Task { @MainActor in
        work()
    }
}

private struct StoredFileWriteError: LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
}

/// The plain list draws a hairline above the first row and under the last. Those two are covered with the page ground.
private struct FileListChrome: UIViewRepresentable {
    func makeUIView(context: Context) -> FileListChromeView {
        FileListChromeView()
    }

    func updateUIView(_ view: FileListChromeView, context: Context) {
        view.apply()
    }
}

private final class FileListChromeView: UIView {
    private let topCover = UIView()
    private let bottomCover = UIView()
    private var placeScheduled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        for cover in [topCover, bottomCover] {
            cover.isUserInteractionEnabled = false
            cover.backgroundColor = .systemGroupedBackground
        }
    }

    required init?(coder: NSCoder) { return nil }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        topCover.removeFromSuperview()
        bottomCover.removeFromSuperview()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        apply()
    }

    func apply() {
        guard let collection = enclosingCollectionView() else { return }
        collection.backgroundColor = .systemGroupedBackground
        if topCover.superview !== collection { collection.addSubview(topCover) }
        if bottomCover.superview !== collection { collection.addSubview(bottomCover) }
        for cell in collection.visibleCells {
            paint(cell)
        }
        placeCovers()
        guard !placeScheduled else { return }
        placeScheduled = true
        onMainActor { [weak self] in
            self?.placeScheduled = false
            self?.placeCovers()
        }
    }

    private func placeCovers() {
        guard let collection = topCover.superview as? UICollectionView ?? enclosingCollectionView() else { return }
        guard let firstPath = firstItemPath(in: collection), let lastPath = lastItemPath(in: collection) else {
            topCover.frame = .zero
            bottomCover.frame = .zero
            return
        }
        if let first = collection.cellForItem(at: firstPath) {
            let frame = first.convert(first.bounds, to: collection)
            topCover.frame = CGRect(x: 0, y: frame.minY - 2, width: collection.bounds.width, height: 4)
            collection.bringSubviewToFront(topCover)
            hideEdgeLine(in: first, atTop: true)
        } else {
            topCover.frame = .zero
        }
        if let last = collection.cellForItem(at: lastPath) {
            let frame = last.convert(last.bounds, to: collection)
            bottomCover.frame = CGRect(x: 0, y: frame.maxY - 1, width: collection.bounds.width, height: 4)
            collection.bringSubviewToFront(bottomCover)
            hideEdgeLine(in: last, atTop: false)
        } else {
            bottomCover.frame = .zero
        }
    }

    /// A drawn line is about one pixel. Only the line past the row is hidden, not the line between rows.
    private func hideEdgeLine(in cell: UIView, atTop: Bool) {
        let limit = 1 / max(cell.traitCollection.displayScale, 1) + 1
        func walk(_ view: UIView) {
            for sub in view.subviews {
                let frame = sub.convert(sub.bounds, to: cell)
                let thin = frame.height > 0 && frame.height <= limit && frame.width > 20
                let atEdge = atTop ? frame.minY <= 1 : frame.maxY >= cell.bounds.height - 1
                if thin, atEdge {
                    sub.isHidden = true
                    sub.alpha = 0
                }
                walk(sub)
            }
        }
        walk(cell)
    }

    private func firstItemPath(in collection: UICollectionView) -> IndexPath? {
        for section in 0..<collection.numberOfSections where collection.numberOfItems(inSection: section) > 0 {
            return IndexPath(item: 0, section: section)
        }
        return nil
    }

    private func lastItemPath(in collection: UICollectionView) -> IndexPath? {
        for section in stride(from: collection.numberOfSections - 1, through: 0, by: -1) {
            let count = collection.numberOfItems(inSection: section)
            if count > 0 { return IndexPath(item: count - 1, section: section) }
        }
        return nil
    }

    private func paint(_ cell: UIView) {
        guard let listCell = cell as? UICollectionViewListCell else { return }
        var config = listCell.backgroundConfiguration ?? UIBackgroundConfiguration.listCell()
        config.backgroundColor = .systemGroupedBackground
        listCell.backgroundConfiguration = config
    }

    private func enclosingCollectionView() -> UICollectionView? {
        var node: UIView? = superview
        var hops = 0
        while let current = node, hops < 20 {
            if let collection = current as? UICollectionView { return collection }
            if let found = collectionView(in: current, depth: 0) { return found }
            node = current.superview
            hops += 1
        }
        guard let window else { return nil }
        let mine = convert(bounds, to: window)
        return collectionView(in: window, depth: 0, overlapping: mine)
    }

    private func collectionView(in view: UIView, depth: Int, overlapping mine: CGRect? = nil) -> UICollectionView? {
        if depth > 24 { return nil }
        var best: UICollectionView?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for sub in view.subviews {
            let candidate = sub as? UICollectionView ?? collectionView(in: sub, depth: depth + 1, overlapping: mine)
            guard let candidate else { continue }
            guard let mine, let host = window else { return candidate }
            let frame = candidate.convert(candidate.bounds, to: host)
            guard frame.intersects(mine) else { continue }
            let area = frame.width * frame.height
            if area < bestArea {
                best = candidate
                bestArea = area
            }
        }
        return best
    }
}

/// Presents Quick Look as its own screen, so its Done button writes every edit into the stored file.
private final class PreviewHostController: UIViewController {
    let preview = QLPreviewController()
    private var presentedPreview = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !presentedPreview, presentedViewController == nil else { return }
        presentedPreview = true
        preview.modalPresentationStyle = .fullScreen
        present(preview, animated: false)
    }
}
