import SwiftData
import SwiftUI

struct LecturePage: View {
    @Bindable var lecture: Lecture
    @State private var segment = 0
    @State private var playerSecond: Int?

    var body: some View {
        VStack {
            Picker("Note", selection: $segment) {
                Text("Summary").tag(0)
                Text("Notes").tag(1)
                Text("Raw").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            List {
                if segment == 0 {
                    Section {
                        Text(lecture.summary.isEmpty ? String(localized: "No summary yet.") : lecture.summary)
                    }
                    if !emphasis.isEmpty {
                        Section("Emphasis") {
                            ForEach(emphasis) { block in
                                blockRow(block)
                            }
                        }
                    }
                } else if segment == 1 {
                    ForEach(noteBlocks) { block in
                        blockRow(block)
                    }
                } else {
                    ForEach(lecture.blocks.sorted { $0.second < $1.second }) { block in
                        Text(block.text)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle(lecture.startedAt.formatted(date: .abbreviated, time: .shortened))
        .toolbar {
            if lecture.state != LectureState.ready.rawValue && lecture.audioRelativePath != nil {
                ToolbarItem(placement: .bottomBar) {
                    Button("Process") {
                        Task { await process() }
                    }
                }
            }
        }
    }

    private var emphasis: [Block] {
        lecture.blocks.filter { $0.importance || $0.kind == BlockKind.emphasis.rawValue }
    }

    private var noteBlocks: [Block] {
        lecture.blocks
            .filter { $0.role != SpeakerRole.room.rawValue }
            .sorted { $0.second < $1.second }
    }

    @ViewBuilder
    private func blockRow(_ block: Block) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(block.second.formatted()) {
                playerSecond = block.second
            }
            Text(block.text)
            if block.importance {
                Image(systemName: "exclamationmark")
            }
            if block.missing {
                Text("Missing")
                    .font(.caption)
            }
            ForEach(block.outgoing) { link in
                Text(link.toBlockID == nil ? String(localized: "No matching note.") : String(localized: "Linked"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func process() async {
        guard let context = lecture.modelContext else { return }
        await LecturePipeline.advance(
            lecture: lecture,
            context: context,
            preferTaggerForPage: UserDefaults.standard.bool(forKey: AppPreferences.pagePrefersTaggerKey)
        )
    }
}
