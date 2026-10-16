import LocalAuthentication
import OSLog
import SwiftUI

struct LockGate: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var message: String?

    private static let log = Logger(subsystem: "app.bellnote", category: "lock")

    var body: some View {
        VStack(spacing: 16) {
            Text("Bellnote")
                .font(.largeTitle)
            Text("Notes stay on this device.")
            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
            }
            Button("Unlock") {
                Self.log.info("Unlock button tapped")
                Task { await unlock() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .task {
            Self.log.info("Lock screen appeared, scene phase \(String(describing: scenePhase), privacy: .public)")
            await unlock()
        }
        .onChange(of: scenePhase) { old, new in
            Self.log.info("Scene phase \(String(describing: old), privacy: .public) -> \(String(describing: new), privacy: .public)")
        }
    }

    private func unlock() async {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        let reason = error?.localizedDescription ?? "none"
        let errorCode = error?.code ?? 0
        Self.log.info("Can evaluate: \(canEvaluate, privacy: .public), biometry type: \(context.biometryType.rawValue, privacy: .public), error: \(reason, privacy: .public) (code \(errorCode, privacy: .public))")
        guard canEvaluate else {
            UserDefaults.standard.set(false, forKey: AppPreferences.lockEnabledKey)
            session.unlocked = true
            message = String(localized: "The device could not lock the notes, so the lock is off.")
            Self.log.error("The device cannot evaluate the policy, so the lock is turned off")
            return
        }
        do {
            Self.log.info("Asking the system to unlock, scene phase \(String(describing: scenePhase), privacy: .public)")
            let granted = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: "Unlock Bellnote")
            )
            Self.log.info("The system answered: \(granted, privacy: .public)")
            session.unlocked = granted
            if !granted {
                message = String(localized: "Unlock was not completed.")
            }
        } catch {
            let code = (error as NSError).code
            let domain = (error as NSError).domain
            Self.log.error("Unlock failed: \(error.localizedDescription, privacy: .public) (domain \(domain, privacy: .public), code \(code, privacy: .public))")
            message = String(localized: "Unlock was not completed.")
        }
    }
}
