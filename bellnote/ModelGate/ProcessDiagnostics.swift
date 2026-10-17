import Foundation
import OSLog
import UIKit

/// Writes the events that explain why a long run died or slowed down: memory warnings, heat changes and the
/// app leaving the screen. Nothing here changes behavior and nothing leaves the device.
@MainActor
enum ProcessDiagnostics {
    private nonisolated static let log = Logger(subsystem: "app.bellnote", category: "diagnostics")
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            log.error("Memory warning from iOS \(MemoryProbe.summary())")
        }
        _ = center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            log.warning("Thermal state changed \(MemoryProbe.summary())")
        }
        let lifecycle: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "App will resign active"),
            (UIApplication.didEnterBackgroundNotification, "App entered background"),
            (UIApplication.willEnterForegroundNotification, "App will enter foreground"),
            (UIApplication.didBecomeActiveNotification, "App became active"),
            (UIApplication.willTerminateNotification, "App will terminate"),
        ]
        for (name, message) in lifecycle {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                log.info("\(message, privacy: .public) \(MemoryProbe.summary())")
            }
        }
        log.info("Diagnostics started \(MemoryProbe.summary())")
    }

    /// Logs the memory numbers every 20 seconds until the returned task is cancelled. The last line before a
    /// crash shows whether memory was climbing.
    nonisolated static func heartbeat(label: String) -> Task<Void, Never> {
        Task.detached {
            let log = Logger(subsystem: "app.bellnote", category: "diagnostics")
            var seconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                seconds += 20
                log.info("Alive label=\(label, privacy: .public) seconds=\(seconds) \(MemoryProbe.summary())")
            }
        }
    }
}
