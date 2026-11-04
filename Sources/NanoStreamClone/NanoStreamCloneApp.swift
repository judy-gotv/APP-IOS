import SwiftUI

@main
struct NanoStreamCloneApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            // Dev round 10 (D-03): tvOS gets its own focus-driven
            // shell; every other platform keeps the shared UI.
            #if os(tvOS)
            TVChannelBrowserView()
                .environmentObject(appState)
                .onAppear {
                    #if os(iOS)
                    let state = appState
                    WatchBridge.appStateProvider = { [weak state] in state }
                    #endif
                }
            #else
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    #if os(iOS)
                    let state = appState
                    WatchBridge.appStateProvider = { [weak state] in state }
                    #endif
                }
            #endif
        }
        // Dev round 10 (D-03): macOS native menu playback controls.
        // The menu posts notifications; the AV view in ContentView
        // observes them (iOS ignores them — no menu exists there).
        #if os(macOS)
        .commands {
            CommandMenu("播放") {
                Button("播放/暂停") { NotificationCenter.default.post(name: .nanoStreamTogglePlay, object: nil) }
                    .keyboardShortcut(" ", modifiers: [])
                Button("静音") { NotificationCenter.default.post(name: .nanoStreamToggleMute, object: nil) }
                    .keyboardShortcut("m", modifiers: .command)
            }
        }
        #endif
        // Dev round 10 (D-03): visionOS opens as a windowed app, not
        // a fullscreen immersive space — no fake 3D is claimed.
        #if os(visionOS)
        .defaultSize(width: 1280, height: 720)
        #endif
    }

    // Dev round 10 (D-03): the watch bridge resolves the app state
    // lazily through the onAppear closure above (weak, so the
    // static bridge never retains the state object).
}
