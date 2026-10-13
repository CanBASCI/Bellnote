import OSLog
import SwiftData
import SwiftUI

@main
struct bellnoteApp: App {
    @State private var session = AppSession()
    private let container: ModelContainer?

    init() {
        do {
            container = try AppSchema.container()
        } catch {
            Logger(subsystem: "app.bellnote", category: "store").error("Store could not open: \(error.localizedDescription, privacy: .public)")
            container = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container {
                    RootView()
                        .modelContainer(container)
                        .environment(session)
                        .environment(\.locale, session.locale)
                } else {
                    ContentUnavailableView {
                        Text("Bellnote")
                    } description: {
                        Text("Notes could not be opened.")
                    }
                }
            }
            .preferredColorScheme(colorScheme)
        }
    }

    private var colorScheme: ColorScheme? {
        switch session.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        if session.unlocked {
            TermHomeView()
        } else {
            LockGate()
        }
    }
}
