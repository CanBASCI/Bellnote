import LocalAuthentication
import SwiftUI

struct LockGate: View {
    @Environment(AppSession.self) private var session
    @State private var message: String?

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
                Task { await unlock() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .task { await unlock() }
    }

    private func unlock() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            UserDefaults.standard.set(false, forKey: AppPreferences.lockEnabledKey)
            session.unlocked = true
            message = String(localized: "The device could not lock the notes, so the lock is off.")
            return
        }
        do {
            session.unlocked = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: "Unlock Bellnote")
            )
        } catch {
            message = String(localized: "Unlock was not completed.")
        }
    }
}
