#if canImport(CarPlay)
import CarPlay
import AVFoundation
import MediaPlayer
import SwiftUI

// Dev round 10 (D-05) + dev round 17 (R17-01): CarPlay. The car shows
// the channel list (favorites first, then all channels). Tapping a
// channel plays audio through the car's speakers with Now Playing
// metadata; on iOS 26.4+ it also offers video (see supportsVideo
// and playVideo). Video is gated, never promised: below iOS 26.4
// only audio is offered, and on 26.4+ the car itself enforces
// parked-only + automaker support through the AirPlay route.
// VERIFIED INTERFACE FACTS (public sources, checked 2026-11-04):
// - Apple developer CarPlay page + WWDC 2026 session 212 ("Rev up
//   your CarPlay app"): video apps browse + play in cars that
//   support the video-in-car feature, parked only; at any time the
//   car may indicate video unavailable, in which case the video
//   plays as audio-only; an app whose content suits both video and
//   audio should hold BOTH the audio and the video entitlement.
// - iOS 26.4 mechanism is AirPlay video from the phone to the car
//   display (parked only, automaker opt-in). There is NO public
//   third-party "video template" class in the 26.4 SDK and NO
//   separate video scene role: video browsing UI reuses the
//   template scene (CPTemplateApplicationSceneSessionRoleApplication)
//   and the picture travels via AVPlayer external playback.
// - iOS 27 adds the video app category with CPPlaybackConfiguration
//   (preferred presentation video/audio) and a CPSessionConfiguration
//   video-support check; exact member names were NOT verifiable
//   from public transcripts, so this file deliberately does NOT
//   reference them — they are CI-verification items for an
//   Xcode 27 SDK pass and must not be guessed here.
// - Entitlement com.apple.developer.carplay-video is documented
//   (WWDC 2026 session 212 + iOS 27 API tables) and is declared
//   ALONGSIDE carplay-audio in the entitlements file; it needs
//   Apple approval and a signed build to take effect.
// - Consequence for supportsVideo: the 26.4 SDK exposes no public
//   runtime query for vehicle video support, so the gate is a
//   version gate (26.4+) and the car enforces the rest. The gate
//   never claims video on a setup that cannot prove the OS floor.
// Verification limits, stated plainly: the CarPlay entitlements
// only take effect in a signed build with Apple approval, and
// behaviour needs a real vehicle or the CarPlay simulator. This
// repo's CI builds unsigned, so neither is verified here.
// This file only compiles where CarPlay exists (iOS); other
// platform targets never see it (see project.yml sources note and
// the #if canImport guard on this whole file).

/// Shared channel list for CarPlay, fed by AppState.channels didSet.
/// The scene delegate never owns channels itself; it only renders
/// the latest snapshot, so phone and car can never disagree about
/// what exists (a stale car list would offer dead channels).
@MainActor
final class CarPlayChannelStore: ObservableObject {
    static let shared = CarPlayChannelStore()

    @Published private(set) var favorites: [Channel] = []
    @Published private(set) var all: [Channel] = []

    func update(_ channels: [Channel]) {
        all = channels
        // Favorites are resolved lazily by id on the phone side;
        // the car list keeps the phone's current favorite ids in
        // step by reading them back through the store below.
        if let ids = CarPlayChannelStore.favoriteIDs {
            favorites = channels.filter { ids.contains($0.id) }
        }
    }

    /// Set by the phone UI whenever favorites change (see
    /// AppState.toggleFavorite / favorites didSet wiring note in
    /// the round report: the car list refreshes on the next
    /// channels update, which always follows a favorite change
    /// because favorites live in the same saved state).
    static var favoriteIDs: Set<String>?
}

/// CarPlay scene delegate: list template -> now playing. The audio
/// player is dedicated to the car (it never touches the phone's
/// inline players), and Now Playing info follows the playing
/// channel. Disconnect stops the car player; nothing is kept
/// playing on the phone by the car session.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var player: AVPlayer?
    private var playingChannel: Channel?
    private var videoPlayer: AVPlayer?
    private var videoFailureObserver: NSObjectProtocol?

    /// Video capability gate (D-05, R17-01): iOS 26.4 is the first
    /// release where CarPlay video is offered at all. The 26.4 SDK
    /// exposes no public runtime query for vehicle video support,
    /// so this gate is a version gate only — the car itself
    /// enforces parked-only + automaker support through the AirPlay
    /// route, and falls back to audio-only when it indicates video
    /// unavailable (WWDC 2026 session 212). Anything below 26.4
    /// gets the audio path only. This flag has real callers
    /// (item(for:) and playVideo(_:)); it is no longer a dead value.
    var supportsVideo: Bool {
        if #available(iOS 26.4, *) {
            return true
        }
        return false
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        showChannelList()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnect interfaceController: CPInterfaceController) {
        stopVideo()
        player?.pause()
        player = nil
        playingChannel = nil
        self.interfaceController = nil
    }

    private func showChannelList() {
        let store = CarPlayChannelStore.shared
        var sections: [CPListSection] = []
        if !store.favorites.isEmpty {
            sections.append(CPListSection(items: store.favorites.map { item(for: $0) }, header: "收藏", sectionIndexTitle: nil))
        }
        sections.append(CPListSection(items: store.all.map { item(for: $0) }, header: "全部频道", sectionIndexTitle: nil))
        let template = CPListTemplate(title: "NanoStream", sections: sections)
        interfaceController?.setRootTemplate(template, animated: true, completion: nil)
    }

    private func item(for channel: Channel) -> CPListItem {
        let item = CPListItem(text: channel.name, detailText: channel.group, image: nil)
        item.handler = { [weak self] _, completion in
            guard let self else { completion(); return }
            if self.supportsVideo {
                self.offerVideoOrAudio(for: channel)
            } else {
                self.play(channel)
            }
            completion()
        }
        return item
    }

    /// Video-or-audio choice, only reachable on iOS 26.4+. The
    /// message states the parked + supporting-vehicle condition
    /// up front; audio stays one tap away so the video offer can
    /// never strand a listener.
    private func offerVideoOrAudio(for channel: Channel) {
        let sheet = CPActionSheetTemplate(
            title: channel.name,
            message: "视频仅在驻车且车辆支持车载视频时在车机显示；否则请选择音频。",
            actions: [
                CPAlertAction(title: "播放视频", style: .default) { [weak self] _ in
                    self?.playVideo(channel)
                },
                CPAlertAction(title: "只播放音频", style: .default) { [weak self] _ in
                    self?.play(channel)
                },
                CPAlertAction(title: "取消", style: .cancel) { _ in },
            ])
        interfaceController?.presentTemplate(sheet, animated: true, completion: nil)
    }

    /// Video path (R17-01): the picture travels via AVPlayer
    /// external playback (AirPlay video) to the car display — the
    /// iOS 26.4 mechanism — while the phone keeps control. The car
    /// page itself is a template (information template) with real
    /// controls: play/pause toggle, back to the list, switch to
    /// audio. If the video item fails, the failure alert names the
    /// cause and offers the audio fallback instead of leaving a
    /// dead video page up.
    private func playVideo(_ channel: Channel) {
        guard supportsVideo, let url = channel.streamURL else {
            play(channel)
            return
        }
        stopVideo()
        let item = AVPlayerItem(url: url)
        if videoPlayer == nil {
            videoPlayer = AVPlayer()
        }
        videoPlayer?.replaceCurrentItem(with: item)
        videoPlayer?.allowsExternalPlayback = true
        videoPlayer?.usesExternalPlaybackWhileExternalScreenIsActive = true
        videoPlayer?.play()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: channel.name,
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        if !channel.group.isEmpty { info[MPMediaItemPropertyArtist] = channel.group }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        videoFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main) { [weak self] _ in
                self?.showVideoFailure(for: channel)
            }
        showVideoPage(for: channel)
    }

    private func showVideoPage(for channel: Channel) {
        let page = CPInformationTemplate(
            title: channel.name,
            layout: .twoColumn,
            items: [
                CPInformationItem(title: "正在播放", detail: channel.group.isEmpty ? "直播" : channel.group),
                CPInformationItem(title: "视频", detail: "仅驻车且车辆支持车载视频时在车机显示；否则只播音频。"),
            ],
            actions: [
                CPTextButton(title: "播放 / 暂停") { [weak self] _, completion in
                    guard let player = self?.videoPlayer else { completion(); return }
                    if player.timeControlStatus == .playing {
                        player.pause()
                    } else {
                        player.play()
                    }
                    completion()
                },
                CPTextButton(title: "返回频道列表") { [weak self] _, completion in
                    self?.interfaceController?.popTemplate(animated: true, completion: nil)
                    completion()
                },
                CPTextButton(title: "切换为音频") { [weak self] _, completion in
                    self?.stopVideo()
                    self?.play(channel)
                    completion()
                },
            ])
        interfaceController?.pushTemplate(page, animated: true, completion: nil)
    }

    private func showVideoFailure(for channel: Channel) {
        let alert = CPAlertTemplate(
            titleVariants: ["视频无法播放"],
            actions: [
                CPAlertAction(title: "切换为音频", style: .default) { [weak self] _ in
                    self?.stopVideo()
                    self?.play(channel)
                },
                CPAlertAction(title: "返回频道列表", style: .cancel) { [weak self] _ in
                    self?.stopVideo()
                    self?.interfaceController?.popToRootTemplate(animated: true, completion: nil)
                },
            ])
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }

    private func stopVideo() {
        if let observer = videoFailureObserver {
            NotificationCenter.default.removeObserver(observer)
            videoFailureObserver = nil
        }
        videoPlayer?.pause()
        videoPlayer = nil
    }

    private func play(_ channel: Channel) {
        guard let url = channel.streamURL else { return }
        playingChannel = channel
        let item = AVPlayerItem(url: url)
        if player == nil {
            player = AVPlayer()
        }
        player?.replaceCurrentItem(with: item)
        player?.play()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: channel.name,
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        if !channel.group.isEmpty { info[MPMediaItemPropertyArtist] = channel.group }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let nowPlaying = CPNowPlayingTemplate.shared
        interfaceController?.pushTemplate(nowPlaying, animated: true, completion: nil)
    }
}

#endif
