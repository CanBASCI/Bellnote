import SwiftUI

@MainActor
@Observable
final class FluidAudioGate {
    var showConfirm = false
    var showDownload = false
    var downloadProgress = 0.0
    var downloadFailed = false
    private var pending: (() async -> Void)?

    func request(_ work: @escaping () async -> Void) {
        if SpeakerPass.modelsAreInstalled() {
            Task { await work() }
            return
        }
        pending = work
        showConfirm = true
    }

    func confirmInstall() {
        showConfirm = false
        showDownload = true
        downloadProgress = 0
        downloadFailed = false
        Task { await runDownload() }
    }

    func cancelConfirm() {
        showConfirm = false
        pending = nil
    }

    func dismissDownload() {
        showDownload = false
        pending = nil
    }

    private func runDownload() async {
        do {
            try await SpeakerPass.downloadModels { fraction in
                Task { @MainActor [self] in
                    downloadProgress = max(downloadProgress, FluidAudioGate.clamp(fraction))
                }
            }
            showDownload = false
            if let pending {
                self.pending = nil
                await pending()
            }
        } catch {
            downloadFailed = true
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

struct FluidAudioGateModifier: ViewModifier {
    @Bindable var gate: FluidAudioGate

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                String(localized: "Download FluidAudio?"),
                isPresented: $gate.showConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "OK")) { gate.confirmInstall() }
                Button(String(localized: "Cancel"), role: .cancel) { gate.cancelConfirm() }
            } message: {
                Text(
                    String(
                        localized:
                            "Speaker separation needs the FluidAudio models on this device. Download now?"
                    )
                )
            }
            .sheet(isPresented: $gate.showDownload) {
                NavigationStack {
                    VStack(spacing: 20) {
                        Text(String(localized: "Downloading FluidAudio…"))
                            .multilineTextAlignment(.center)
                        ProgressView(value: gate.downloadProgress)
                            .padding(.horizontal)
                        Text(gate.downloadProgress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if gate.downloadFailed {
                            Text(
                                String(
                                    localized: "Download failed. Check your connection and try again."
                                )
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            Button(String(localized: "Retry")) { gate.confirmInstall() }
                        }
                    }
                    .padding()
                    .navigationTitle("FluidAudio")
                    .navigationBarTitleDisplayMode(.inline)
                    .interactiveDismissDisabled(!gate.downloadFailed)
                    .toolbar {
                        if gate.downloadFailed {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(String(localized: "Close")) { gate.dismissDownload() }
                            }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
    }
}

extension View {
    func fluidAudioGate(_ gate: FluidAudioGate) -> some View {
        modifier(FluidAudioGateModifier(gate: gate))
    }
}
