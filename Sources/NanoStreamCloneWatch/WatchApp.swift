import SwiftUI
import WatchConnectivity
import AVFoundation

// Dev round 10 (D-03): watchOS target. This is a separate target with
// its own sources because a WatchKit app cannot share the UIKit
// views. Scope choice, as the checklist allows: the watch offers a
// favorites quick-play entry (not phone remote control). The phone
// side is WatchBridge (PlatformShells.swift, iOS only): the watch
// asks for favorites over WatchConnectivity and plays the chosen
// channel's audio locally with AVPlayer. No phone, no pairing, or
// no favorites simply shows an explicit empty state — never a
// fabricated channel list. Audio-only is a watch hardware reality
// (no video playback surface is claimed here).

@main
struct NanoStreamWatchApp: App {
    @StateObject private var bridge = WatchSession()

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environmentObject(bridge)
        }
    }
}

struct WatchChannel: Identifiable, Hashable {
    var id: String
    var name: String
    var group: String
    var url: URL
}

@MainActor
final class WatchSession: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var channels: [WatchChannel] = []
    @Published private(set) var status = ""
    @Published private(set) var playingID: String?
    private var player: AVPlayer?

    override init() {
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated { requestFavorites() }
    }

    func requestFavorites() {
        guard WCSession.isSupported(), WCSession.default.isReachable else {
            status = "Phone not reachable"
            return
        }
        status = "Loading…"
        WCSession.default.sendMessage(["requestFavorites": true], replyHandler: { [weak self] reply in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let payload = reply["favorites"] as? [[String: String]] ?? []
                self.channels = payload.compactMap { dict in
                    guard let id = dict["id"], let name = dict["name"], let urlString = dict["url"], let url = URL(string: urlString) else { return nil }
                    return WatchChannel(id: id, name: name, group: dict["group"] ?? "", url: url)
                }
                self.status = self.channels.isEmpty ? "No favorites on phone" : ""
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.status = "Phone not reachable"
            }
        })
    }

    func play(_ channel: WatchChannel) {
        if playingID == channel.id {
            player?.pause()
            playingID = nil
            return
        }
        if player == nil { player = AVPlayer() }
        player?.replaceCurrentItem(with: AVPlayerItem(url: channel.url))
        player?.play()
        playingID = channel.id
    }

    func stop() {
        player?.pause()
        player = nil
        playingID = nil
    }
}

struct WatchHomeView: View {
    @EnvironmentObject private var bridge: WatchSession

    var body: some View {
        NavigationStack {
            if bridge.channels.isEmpty {
                VStack(spacing: 8) {
                    Text(bridge.status.isEmpty ? "No favorites" : bridge.status)
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Refresh") { bridge.requestFavorites() }
                }
            } else {
                List(bridge.channels) { channel in
                    Button {
                        bridge.play(channel)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(channel.name).lineLimit(1)
                                if !channel.group.isEmpty { Text(channel.group).font(.caption2).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Image(systemName: bridge.playingID == channel.id ? "pause.fill" : "play.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Refresh") { bridge.requestFavorites() }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Stop") { bridge.stop() }
                    }
                }
            }
        }
        .navigationTitle("NanoStream")
    }
}
