import AppKit
import Foundation
import SwiftUI

// Native self-contained acceptance probe. Compile together with
// Sources/Codexer/ApplicationActivityMonitor.swift; no provider data is accessed.
@MainActor enum LifecycleProbe {
    static var started = false
    static var sceneGate = false
    static var nativeGate = false
    static var monitor: ApplicationActivityMonitor?
    static func record(_ event: String) {
        let result: [String: Any] = ["event": event, "application_active": NSApp.isActive,
            "visible_windows": NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.count,
            "scene_gate": sceneGate, "native_gate": nativeGate]
        let data = try! JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout)
    }
}

@main struct ResourceLifecycleProbe: App {
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup("Synthetic Resource Lifecycle Probe", id: "probe") {
            ProbeView()
                .task {
                    LifecycleProbe.sceneGate = phase == .active
                    LifecycleProbe.record("scene-task")
                }
                .onChange(of: phase) {
                    LifecycleProbe.sceneGate = phase == .active
                    LifecycleProbe.record("scene-change")
                }
        }
    }
}

struct ProbeView: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Synthetic lifecycle acceptance probe").frame(width: 420, height: 200)
            .task {
                guard !LifecycleProbe.started else { return }
                LifecycleProbe.started = true
                NSApp.setActivationPolicy(.regular)
                LifecycleProbe.monitor = ApplicationActivityMonitor {
                    LifecycleProbe.nativeGate = $0
                    LifecycleProbe.record("native-change")
                }
                // Unstructured task survives closure of its starting view.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    NSApp.activate(ignoringOtherApps: true)
                    try? await Task.sleep(for: .seconds(1))
                    LifecycleProbe.record("foreground")
                    openWindow(id: "probe")
                    try? await Task.sleep(for: .seconds(1))
                    LifecycleProbe.record("multiple-windows")
                    NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })?.close()
                    try? await Task.sleep(for: .seconds(1))
                    LifecycleProbe.record("one-window-remaining")
                    NSApp.hide(nil)
                    try? await Task.sleep(for: .seconds(1))
                    LifecycleProbe.record("hidden")
                    NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true)
                    try? await Task.sleep(for: .seconds(1))
                    LifecycleProbe.record("returned")
                    for window in NSApp.windows where window.isVisible && window.canBecomeMain { window.close() }
                    try? await Task.sleep(for: .seconds(1))
                    LifecycleProbe.record("closed-all")
                    openWindow(id: "probe"); NSApp.activate(ignoringOtherApps: true)
                    try? await Task.sleep(for: .seconds(1))
                    LifecycleProbe.record("reopened")
                    for _ in 0..<30 {
                        NSApp.hide(nil)
                        try? await Task.sleep(for: .milliseconds(50))
                        NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true)
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    LifecycleProbe.record("rapid-switch-complete")
                    NSApp.terminate(nil)
                }
            }
    }
}
