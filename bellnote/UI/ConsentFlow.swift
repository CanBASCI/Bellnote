import OSLog
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The step before a recording starts.
/// The first recording of a course asks for the two attestations in a sheet.
/// Every later recording of that course needs only one confirm, so it is not a sheet.
/// The confirm is a system alert, or a popover with the red Start recording button when `asPopover` is set.
private struct ConsentFlow: ViewModifier {
    var course: Course?
    var asPopover: Bool
    @Binding var isPresented: Bool
    var onConfirm: (Course, Bool) -> Void

    @Environment(\.modelContext) private var modelContext
    /// The course kept until the document picker closes. The recording is created only after a file is chosen.
    @State private var pendingLoad: PendingLoad?
    @State private var importingAudio = false
    @State private var importNotice: String?
    /// The first sheet can load a file instead of starting the microphone. Cleared when that sheet finishes closing.
    @State private var loadInstead = false
    private static let log = Logger(subsystem: "app.bellnote", category: "capture")

    private var isLater: Bool {
        course?.lectures.contains { $0.attestation != nil } ?? false
    }

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { isPresented && !isLater },
            set: { if !$0 { isPresented = false } }
        )
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { isPresented && isLater && !asPopover },
            set: { if !$0 { isPresented = false } }
        )
    }

    private var popoverBinding: Binding<Bool> {
        Binding(
            get: { isPresented && isLater && asPopover },
            set: { if !$0 { isPresented = false } }
        )
    }

    /// The answer of the consent sheet, kept until that sheet has finished closing. The recording starts in the
    /// `onDismiss` of the sheet, which the system calls after the sheet is gone.
    @State private var answered: (course: Course, faceID: Bool)?

    private func startAfterConsentSheet() {
        guard let answered else { return }
        let loading = loadInstead
        self.answered = nil
        loadInstead = false
        if loading {
            beginImport(answered.course, faceID: answered.faceID, wait: false)
        } else {
            onConfirm(answered.course, answered.faceID)
        }
    }

    /// For the alert and the popover. They have no callback for the end of their closing, so the recording starts
    /// after a short wait. The recorder sheet cannot open while they are still on their way out; iOS then drops it,
    /// and the recording would exist without a sheet. `isPresented` is closed first, which also keeps `isLater`
    /// from opening the confirm alert again: starting adds a lecture with an attestation, and from then on
    /// `isLater` is true.
    private func start(_ course: Course, faceID: Bool) {
        isPresented = false
        let onConfirm = onConfirm
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                // The task was cancelled, the view is gone. No recording is started then.
                return
            }
            onConfirm(course, faceID)
        }
    }

    /// Closes the confirm, then opens the document picker. A popover has no dismiss callback, so that one waits.
    private func load(_ course: Course, faceID: Bool) {
        isPresented = false
        beginImport(course, faceID: faceID, wait: true)
    }

    private func beginImport(_ course: Course, faceID: Bool, wait: Bool) {
        pendingLoad = PendingLoad(course: course, faceID: faceID)
        guard wait else {
            importingAudio = true
            return
        }
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            importingAudio = true
        }
    }

    private func finishImport(_ result: Result<URL, Error>) {
        guard let pendingLoad else { return }
        self.pendingLoad = nil
        switch result {
        case .failure(let error):
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.userCancelled.rawValue { return }
            Self.log.error(
                "Recording import failed: \(String(describing: error), privacy: .public) [\(ns.domain, privacy: .public) \(ns.code)] \(ns.localizedDescription, privacy: .public)"
            )
            importNotice = String(localized: "The recording could not be added.")
        case .success(let url):
            do {
                try LectureStarter.importAudio(
                    course: pendingLoad.course,
                    faceID: pendingLoad.faceID,
                    from: url,
                    context: modelContext
                )
            } catch {
                let ns = error as NSError
                Self.log.error(
                    "Recording import failed: \(String(describing: error), privacy: .public) [\(ns.domain, privacy: .public) \(ns.code)] \(ns.localizedDescription, privacy: .public)"
                )
                importNotice = String(localized: "The recording could not be added.")
            }
        }
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: sheetBinding, onDismiss: startAfterConsentSheet) {
                if let course {
                    ConsentSheet(course: course) { faceID in
                        // Closed first, and the recording starts in `onDismiss`, not here. Starting adds a lecture
                        // with an attestation, and from then on `isLater` is true, which would open the confirm
                        // alert while the sheet is still open.
                        loadInstead = false
                        answered = (course, faceID)
                        isPresented = false
                    } onLoad: {
                        loadInstead = true
                        answered = (course, false)
                        isPresented = false
                    }
                }
            }
            .alert(
                String(format: String(localized: "Record this class for %@?"), course?.name ?? ""),
                isPresented: alertBinding
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Load recording") {
                    if let course { load(course, faceID: false) }
                }
                // The system gives an alert button no custom colour. The destructive role is the only red it offers.
                Button("Start recording", role: .destructive) {
                    if let course { start(course, faceID: false) }
                }
            }
            .popover(isPresented: popoverBinding) {
                if let course {
                    VStack(spacing: 14) {
                        Text(String(format: String(localized: "Record this class for %@?"), course.name))
                            .multilineTextAlignment(.center)
                        Button {
                            start(course, faceID: false)
                        } label: {
                            // The same button as "Start recording" on the Today screen.
                            Label("Start recording", systemImage: "record.circle.fill")
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .tint(.red)
                        Button {
                            load(course, faceID: false)
                        } label: {
                            Label("Load recording", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                    .padding(20)
                    .frame(width: 280)
                    .presentationCompactAdaptation(.popover)
                }
            }
            .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio]) { result in
                finishImport(result)
            }
            .alert(
                importNotice ?? "",
                isPresented: Binding(
                    get: { importNotice != nil },
                    set: { if !$0 { importNotice = nil } }
                )
            ) {
                Button("OK", role: .cancel) { importNotice = nil }
            }
    }
}

private struct PendingLoad {
    var course: Course
    var faceID: Bool
}

extension View {
    func consentFlow(
        course: Course?,
        asPopover: Bool = false,
        isPresented: Binding<Bool>,
        onConfirm: @escaping (Course, Bool) -> Void
    ) -> some View {
        modifier(
            ConsentFlow(course: course, asPopover: asPopover, isPresented: isPresented, onConfirm: onConfirm)
        )
    }
}
