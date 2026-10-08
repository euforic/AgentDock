import AppKit

/// App-level observations remain alive after the final SwiftUI window closes.
@MainActor
final class ApplicationActivityMonitor {
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    private var updateTask: Task<Void, Never>?
    private let changed: @MainActor (Bool) -> Void

    init(changed: @escaping @MainActor (Bool) -> Void) {
        self.changed = changed
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleUpdate() }
            })
        }
        update()
    }

    deinit {
        updateTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func scheduleUpdate() {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            // willClose fires before the window's visibility changes.
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    private func update() {
        changed(NSApp.isActive && NSApp.windows.contains { $0.isVisible && $0.canBecomeMain })
    }
}
