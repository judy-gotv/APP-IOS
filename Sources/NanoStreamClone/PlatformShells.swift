import SwiftUI
import Foundation

// Dev round 10 (D-03): multi-platform shells.
//
// Platform map (see project.yml):
// - iPadOS: NOT a separate target. XcodeGen's iOS platform covers
//   iPhone + iPad; the main target is now universal
//   (TARGETED_DEVICE_FAMILY 1,2) and HomeView adapts its grid to a
//   regular size class. A separate "iPad target" would duplicate the
//   whole app for no behavioural difference.
// - tvOS / macOS / visionOS: targets sharing Sources/NanoStreamClone.
//   iOS-only APIs in the shared code are isolated with #if os()
//   guards (see the guard notes at each site); anything left
//   unverified is a CI-extension verification item, not a claim.
// - watchOS: its own target and its own sources
//   (Sources/NanoStreamCloneWatch) because WatchKit apps cannot share
//   the UIKit-based views; the phone side of the bridge is
//   WatchBridge in this file (iOS only).
// - Platform-exclusive capabilities (CarPlay, iCloud, DLNA) are
//   iOS-only: their settings rows are gated with #if os(iOS) in
//   SettingsViews, and CarPlayScene.swift only compiles where
//   CarPlay exists. No other target shows those switches.

/// macOS menu-bar playback commands. The App file posts these from
/// its CommandMenu; the KS and AV player views observe the toggle
/// (and mute) notifications. Channel switching stays in the detail
/// page on purpose: a menu item cannot know which detail page is
/// open, so it must not pretend to switch channels.
extension Notification.Name {
    static let nanoStreamTogglePlay = Notification.Name("com.k20.nanostream.togglePlay")
    static let nanoStreamToggleMute = Notification.Name("com.k20.nanostream.toggleMute")
}

#if os(tvOS)
/// tvOS shell: focus-driven channel browsing. Rows are Buttons, so
/// the remote's focus engine reaches every row; selecting a row
/// pushes a full-screen player. Playback reuses PlayerSurface (the
/// AV path; KSPlayer is a dependency of the tvOS target too, with
/// its tvOS support left as a CI-extension verification item).
struct TVChannelBrowserView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationStack {
            List(state.channels) { channel in
                NavigationLink {
                    TVPlayerView(channel: channel)
                } label: {
                    HStack {
                        Text(channel.name).font(.headline)
                        Spacer()
                        if !channel.quality.isEmpty { Text(channel.quality).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("NanoStream")
        }
    }
}

private struct TVPlayerView: View {
    @EnvironmentObject private var state: AppState
    let channel: Channel
    @State private var streamInfo = ""
    @State private var position: Double = 0
    @State private var duration: Double = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = channel.streamURL {
                PlayerSurface(url: url, title: channel.name, engine: state.preferredPlayer, bufferMilliseconds: state.networkBufferMilliseconds, allowsPictureInPicture: state.pictureInPicture, hardwareAcceleration: state.hardwareAcceleration, automaticAudioSelection: state.automaticAudioSelection, showLatency: false, streamInfo: $streamInfo, deinterlace: state.deinterlace, isLive: channel.isLive, playbackPosition: $position, playbackDuration: $duration)
            } else {
                Text("No playable URL").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(channel.name)
    }
}
#endif


#if os(iOS)
import WatchConnectivity

/// Phone side of the watch bridge (D-03, watchOS target companion).
/// The watch asks for favorites; the phone answers with the current
/// favorite channels (id, name, group, stream URL) over
/// WatchConnectivity. No playback state is synced: the watch plays
/// its own audio copy. Unpaired / unreachable watches simply get no
/// answer; nothing is queued and nothing errors on the phone side.
final class WatchBridge: NSObject, WCSessionDelegate, ObservableObject {
    static let shared = WatchBridge()

    private override init() {
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    // WCSessionDelegate on iOS requires these two; the bridge holds
    // no session state, so both are intentional no-ops.
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {}

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        // Only one message exists: "requestFavorites". Anything else
        // gets an empty reply, never an error.
        guard message["requestFavorites"] as? Bool == true else { replyHandler([:]); return }
        Task { @MainActor in
            let appState = WatchBridge.appStateProvider?()
            let favorites = (appState?.favorites ?? []).compactMap { id in
                appState?.channels.first(where: { $0.id == id })
            }
            let payload = favorites.compactMap { channel -> [String: String]? in
                guard let url = channel.streamURL else { return nil }
                return ["id": channel.id, "name": channel.name, "group": channel.group, "url": url.absoluteString]
            }
            replyHandler(["favorites": payload])
        }
    }

    /// Set once by the App entry point so the bridge can read the
    /// live AppState without owning it.
    static var appStateProvider: (() -> AppState?)?
}
#endif
