import SwiftUI

/// The step before a recording starts.
/// The first recording of a course asks for the two attestations in a sheet.
/// Every later recording of that course needs only one confirm, so it is not a sheet.
/// The confirm is a system alert, or a popover with the red Start recording button when `asPopover` is set.
private struct ConsentFlow: ViewModifier {
    var course: Course?
    var asPopover: Bool
    @Binding var isPresented: Bool
    var onConfirm: (Course, Bool) -> Void

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

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: sheetBinding) {
                if let course {
                    ConsentSheet(course: course) { faceID in
                        onConfirm(course, faceID)
                    }
                }
            }
            .alert(
                "Record this class for \(course?.name ?? "")?",
                isPresented: alertBinding
            ) {
                Button("Cancel", role: .cancel) {}
                // The system gives an alert button no custom colour. The destructive role is the only red it offers.
                Button("Start recording", role: .destructive) {
                    if let course { onConfirm(course, false) }
                }
            }
            .popover(isPresented: popoverBinding) {
                if let course {
                    VStack(spacing: 14) {
                        Text("Record this class for \(course.name)?")
                            .multilineTextAlignment(.center)
                        Button {
                            isPresented = false
                            onConfirm(course, false)
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
                    }
                    .padding(20)
                    .frame(width: 280)
                    .presentationCompactAdaptation(.popover)
                }
            }
    }
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
