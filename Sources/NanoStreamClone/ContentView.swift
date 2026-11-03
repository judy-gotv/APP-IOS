import SwiftUI
import AVKit
import AVFoundation
import KSPlayer
import UIKit

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var tab: AppTab = .home
    @State private var showAddPlaylist = false
    @State private var showSettings = false
    // Round-3 fix (A02): the groups-menu open state used to live in
    // HomeView's @State, so switching tabs rebuilt HomeView and silently
    // collapsed the menu. It now lives here, above the tab switch.
    @State private var homeShowGroups = false

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            Group {
                switch tab {
                case .home: HomeView(showGroups: $homeShowGroups)
                case .favorites: FavoritesView()
                case .playlists: PlaylistsView(showAdd: $showAddPlaylist)
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack { Spacer(); BottomBar(tab: $tab) }
        }
        .preferredColorScheme(state.colorScheme)
        .tint(state.accent)
        .sheet(isPresented: $showAddPlaylist) { PlaylistFormView() }
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home = "主页", favorites = "收藏", playlists = "播放列表", settings = "设置"
    var id: String { rawValue }
    var icon: String {
        switch self { case .home: return "play.rectangle"; case .favorites: return "star"; case .playlists: return "rectangle.stack"; case .settings: return "gearshape" }
    }
}

struct BottomBar: View {
    @EnvironmentObject private var state: AppState
    @Binding var tab: AppTab
    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { item in
                Button { withAnimation(.easeOut(duration: 0.18)) { tab = item } } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.icon).font(.system(size: 25, weight: .regular))
                        Text(state.localized(item.rawValue)).font(.system(size: 11, weight: .medium))
                        Circle().fill(tab == item ? state.accent : .clear).frame(width: 4, height: 4)
                    }
                    .foregroundStyle(tab == item ? state.accent : .secondary)
                    .frame(maxWidth: .infinity)
                }.buttonStyle(.plain)
            }
        }
        .padding(.top, 12).padding(.bottom, 9).padding(.horizontal, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(state.accent.opacity(0.28), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        .padding(.horizontal, 32).padding(.bottom, 10)
    }
}

struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedDetail: Channel?
    // Round-8 fix (C03): proxyAuthWarning is computed from the static
    // proxyMigrationFailed flag, which is not @Published, so a
    // migration failure during a successful background refresh left
    // the home page stale until some other state change re-rendered
    // it. Bumping this counter on the notification forces a re-render.
    @State private var proxyMigrationTick = 0
    @Binding var showGroups: Bool

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Button { withAnimation(.easeOut(duration: 0.18)) { showGroups.toggle() } } label: {
                        CircleButton(icon: "line.3.horizontal")
                    }.buttonStyle(.plain)
                    Spacer()
                    Menu {
                        ForEach(state.playlists) { playlist in
                            Button { state.activatePlaylist(playlist) } label: {
                                Label(playlist.name, systemImage: state.activePlaylistID == playlist.id ? "checkmark" : "rectangle.stack")
                            }
                        }
                    } label: {
                        Capsule().fill(Color.panel).frame(width: 155, height: 42).overlay {
                            Label(activePlaylistName, systemImage: "rectangle.stack").font(.subheadline.weight(.semibold)).lineLimit(1)
                        }
                    }.buttonStyle(.plain).disabled(state.playlists.isEmpty || state.isLoadingPlaylist)
                }.padding(.horizontal, 22).padding(.top, 12)
                if showGroups {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(state.groups, id: \.self) { group in
                                Button { state.selectedGroup = group; withAnimation { showGroups = false } } label: {
                                    HStack { Text(state.localizedGroup(group)); Spacer(); if state.selectedGroup == group { Image(systemName: "checkmark").foregroundStyle(state.accent) } }
                                        .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(state.accent.opacity(0.5), lineWidth: 1))
                    .padding(.horizontal, 22).padding(.top, 8)
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(state.localized("搜索频道..."), text: $state.searchText).textFieldStyle(.plain)
                }.padding(.horizontal, 14).frame(height: 48).background(Color.panel, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 22).padding(.top, 12)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(GridLayout.allCases) { layout in
                            Button { state.setGridLayout(layout) } label: {
                                Label(state.localized(layout.rawValue), systemImage: state.gridLayout == layout ? "checkmark" : "square.grid.2x2")
                            }
                        }
                    } label: {
                        Image(systemName: state.gridLayout == .twoColumns ? "square.grid.2x2" : state.gridLayout == .threeColumns ? "square.grid.3x3" : "square.grid.4x3.fill")
                            .foregroundStyle(state.accent).frame(width: 46, height: 40).background(Color.panel, in: RoundedRectangle(cornerRadius: 20))
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 22).padding(.top, 16)
                if state.stateRestoreFailed {
                    Text(state.localized("旧播放列表数据损坏，已备份，无法自动恢复。")).font(.caption).foregroundStyle(.red).padding(.horizontal, 22).padding(.top, 12)
                }
                if let error = state.playlistError {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Spacer()
                        Button(state.localized("重试")) { state.refreshPlaylists() }.buttonStyle(.bordered).tint(state.accent)
                    }.padding(.horizontal, 22).padding(.top, 12)
                }
                // Round-8 fix (A): the round-7 warning lived inside the
                // playlistError branch, so it was invisible whenever
                // there was no load error at all — e.g. a no-password
                // proxy filled in but not yet refreshed, or a refresh
                // that succeeded via the plain-text fallback after a
                // migration failure. proxyAuthWarning does not depend
                // on playlistError, so render it independently here.
                if let proxyWarning = state.proxyAuthWarning {
                    Text(proxyWarning).font(.caption).foregroundStyle(.red).padding(.horizontal, 22).padding(.top, 12)
                }
                // Round-7 fix (A04): error notices are now persistent
                // (see setNotice), so the home page renders them too —
                // previously a save failure on this page expired unseen
                // because only saveError (not notice) was shown here.
                // Round-8 fix (C04): save() itself posts the same
                // failure text as an error notice, and toggleFavorite/
                // play also set saveError to that text, so the home page
                // showed two identical failure lines (accent notice +
                // red saveError). Skip the notice here when it merely
                // duplicates saveError; saveError stays the canonical
                // rendering for this page.
                if let notice = state.currentNotice, notice != state.saveError {
                    Text(notice).font(.caption).foregroundStyle(state.accent).padding(.horizontal, 22).padding(.top, 12)
                }
                // Round-3 fix (C09): a persist failure used to surface
                // only via `notice`, which the home page never renders —
                // so a star/play that failed to save looked successful
                // here and vanished on restart.
                if let saveError = state.saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red).padding(.horizontal, 22).padding(.top, 12)
                }
                if state.isLoadingPlaylist && state.channels.isEmpty {
                    ProgressView().tint(state.accent).padding(.top, 42)
                } else if state.channels.isEmpty {
                    EmptyHomeState()
                } else {
                    if state.isRefreshingPlaylist { ProgressView().tint(state.accent).padding(.top, 12) }
                    RecentRail { channel in state.play(channel); selectedDetail = channel }.padding(.top, 23)
                    if state.visibleChannels.isEmpty {
                        VStack(spacing: 8) {
                            Text(state.localized("暂无频道")).font(.title3.bold())
                            Text(state.localized("当前分组或搜索没有匹配的频道。")).font(.subheadline).foregroundStyle(.secondary)
                            Button(state.localized("清除筛选")) { state.selectedGroup = GroupID.all; state.searchText = "" }.buttonStyle(.bordered).tint(state.accent)
                        }.padding(.top, 28).padding(.horizontal, 28)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: state.gridLayout.columns), spacing: 12) {
                        ForEach(state.visibleChannels) { channel in ChannelCard(channel: channel, compact: state.gridLayout == .fourColumns) { state.play(channel); selectedDetail = channel } }
                    }.padding(.horizontal, 22).padding(.top, 17).padding(.bottom, 110)
                }
            }
        }
        .fullScreenCover(item: $selectedDetail) { channel in ChannelDetailView(channel: channel) }
        .onReceive(NotificationCenter.default.publisher(for: M3UParser.proxyMigrationFailedChanged)) { _ in
            proxyMigrationTick += 1
        }
    }

    private var activePlaylistName: String {
        if let id = state.activePlaylistID, let playlist = state.playlists.first(where: { $0.id == id }) { return playlist.name }
        return state.localized("选择订阅")
    }
}

struct RecentRail: View {
    @EnvironmentObject private var state: AppState
    let onOpen: (Channel) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(state.localized("最近播放")).font(.system(size: 20, weight: .bold)); Spacer(); Image(systemName: "clock.fill").foregroundStyle(state.accent) }.padding(.horizontal, 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(state.recent.compactMap(state.channel(for:))) { channel in
                        Button { onOpen(channel) } label: {
                            VStack(spacing: 7) {
                                ZStack { RoundedRectangle(cornerRadius: 12).fill(Color.cardInner); if let logoURL = channel.logoURL { AsyncImage(url: logoURL) { phase in if let image = phase.image { image.resizable().scaledToFit().padding(18) } else { Text(channel.name.prefix(1).uppercased()).font(.system(size: 30, weight: .heavy)) } } } else { Text(channel.name.prefix(1).uppercased()).font(.system(size: 30, weight: .heavy)) } }.frame(width: 112, height: 90)
                                Text(channel.name).font(.caption).lineLimit(1).frame(width: 112, alignment: .leading)
                            }.padding(9).background(Color.card, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(state.accent.opacity(0.25), lineWidth: 1)).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if state.recent.isEmpty { Text(state.localized("暂无播放记录")).foregroundStyle(.secondary).padding(.horizontal, 22) }
                }.padding(.horizontal, 22)
            }
        }
    }
}

@MainActor
private final class PreviewSessionPool {
    static let shared = PreviewSessionPool()
    /// Posted when a slot is fully freed, so a pool-full card can retry
    /// without the user having to scroll it off-screen and back.
    static let didReleaseNotification = Notification.Name("NanoStreamClone.PreviewPoolDidRelease")
    private let limit = 4
    // Reference-counted: two cards for the same channel id (duplicate
    // entries) must not release each other's slot.
    private var active: [String: Int] = []

    func acquire(_ id: String) -> Bool {
        if let count = active[id] { active[id] = count + 1; return true }
        guard active.count < limit else { return false }
        active[id] = 1
        return true
    }

    func release(_ id: String) {
        guard let count = active[id] else { return }
        if count <= 1 {
            active.removeValue(forKey: id)
            NotificationCenter.default.post(name: Self.didReleaseNotification, object: nil)
        } else { active[id] = count - 1 }
    }
}

@MainActor
private final class PreviewPlayerModel: NSObject, ObservableObject {
    private(set) var player: AVPlayer?
    @Published private(set) var latencyMilliseconds: Int?
    private var timer: Timer?
    private let url: URL?

    init(url: URL?) {
        self.url = url
        self.player = nil
        super.init()
    }

    func start() {
        // Round-3 fix (A03): the player is created here, not in init, so
        // a card that never wins a pool slot never builds an AVPlayer +
        // AVPlayerItem at all. start() is only called after acquire().
        if player == nil, let url {
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            // Previews are muted: previously up to 4 live streams played
            // sound at once with no mute control.
            player.isMuted = true
            self.player = player
        }
        guard let player else { return }
        player.play()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleLatency() }
        }
        sampleLatency()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        // Release the player so a later re-acquire rebuilds it (and a
        // card that was stopped by a scene change does not keep a dead
        // item around).
        player = nil
        latencyMilliseconds = nil
    }

    private func sampleLatency() {
        // Latency is only meaningful while actually playing a live stream;
        // a paused preview previously showed a growing fake latency.
        guard let player, player.timeControlStatus == .playing,
              let item = player.currentItem,
              let range = item.seekableTimeRanges.last?.timeRangeValue,
              range.isValid,
              item.currentTime().isNumeric else {
            latencyMilliseconds = nil
            return
        }
        let current = item.currentTime()
        let seconds = range.end.seconds - current.seconds
        latencyMilliseconds = seconds >= 0 && seconds.isFinite ? Int((seconds * 1000).rounded()) : nil
    }

    // Note: stop() is the only timer teardown path and is always called
    // from LivePreviewView.onDisappear. deinit is intentionally not used
    // for timer invalidation because a @MainActor deinit is not isolated.
    deinit { player?.pause() }
}

private struct LivePreviewView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    let channel: Channel
    @StateObject private var model: PreviewPlayerModel
    @State private var acquired = false

    init(channel: Channel) {
        self.channel = channel
        _model = StateObject(wrappedValue: PreviewPlayerModel(url: channel.streamURL))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if acquired {
                PreviewPlayerLayerView(player: model.player)
                if state.showLatency { StreamLatencyBadge(milliseconds: model.latencyMilliseconds) }
            } else {
                Color.black
                // Round-2 fix: this used to be a Button nested inside the
                // ChannelCard Button, which SwiftUI does not support — taps
                // on "retry" opened the detail page instead of retrying.
                // It is now a high-priority tap gesture, and the card itself
                // is a plain VStack with onTapGesture (see ChannelCard), so
                // the retry tap wins over the card-open tap.
                // Round-3 fix (A07): the text now says the card is
                // tappable to retry, and a freed pool slot retries
                // automatically via the release notification.
                Text(state.localized("预览连接数已达上限，点按重试")).font(.caption2).foregroundStyle(.secondary).padding(8)
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded {
                        acquired = PreviewSessionPool.shared.acquire(channel.id)
                        if acquired { model.start() }
                    })
            }
        }
        .onAppear {
            // Round-2 fix: onAppear can fire twice without an intervening
            // onDisappear, and the pool is reference-counted, so a second
            // acquire leaked a slot that the single release never freed.
            guard !acquired else { return }
            acquired = PreviewSessionPool.shared.acquire(channel.id)
            if acquired { model.start() }
        }
        .onDisappear {
            if acquired { model.stop(); PreviewSessionPool.shared.release(channel.id); acquired = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: PreviewSessionPool.didReleaseNotification)) { _ in
            // Round-4 fix (B03): a slot freed while backgrounded used to
            // re-acquire and restart decoding in the background, undoing
            // the background stop. Only re-acquire in the foreground.
            // Round-5 fix (B05, was suspect): the old guard only
            // excluded .background, but the release notification is
            // posted synchronously from another card's .background
            // handler, when this card's scenePhase may still read the
            // transitional .inactive value — a narrow window in which a
            // stopped preview could restart in the background. Require
            // .active outright: this cannot lose a slot permanently,
            // because the .active onChange branch below re-acquires on
            // every return to the foreground, and the retry tap remains
            // available meanwhile.
            guard !acquired, scenePhase == .active else { return }
            acquired = PreviewSessionPool.shared.acquire(channel.id)
            if acquired { model.start() }
        }
        .onChange(of: scenePhase) { phase in
            // Round-3 fix (A01): leaving the app does not trigger
            // onDisappear, so previews used to keep decoding in the
            // background. Backgrounding stops the preview and frees its
            // slot; returning re-acquires it (or shows the retry text).
            if phase == .background, acquired {
                model.stop(); PreviewSessionPool.shared.release(channel.id); acquired = false
            } else if phase == .active, !acquired {
                acquired = PreviewSessionPool.shared.acquire(channel.id)
                if acquired { model.start() }
            }
        }
    }
}

private struct PreviewPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?
    func makeUIView(context: Context) -> PreviewLayerHostView {
        let view = PreviewLayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: PreviewLayerHostView, context: Context) { view.playerLayer.player = player }
}

private final class PreviewLayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct StreamLatencyBadge: View {
    @EnvironmentObject private var state: AppState
    let milliseconds: Int?
    var body: some View {
        Text(milliseconds.map { "\($0) ms" } ?? state.localized("延迟不可用"))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.black.opacity(0.72), in: Capsule())
            .padding(7)
    }
}

struct ChannelCard: View {
    @EnvironmentObject private var state: AppState
    let channel: Channel
    var compact = false
    let onOpen: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Round-2 fix: the card used to be a Button whose label contained
            // the preview's retry Button (nested buttons are unsupported in
            // SwiftUI and the outer action won). The card is now a VStack
            // with onTapGesture, so inner controls receive their own taps.
            VStack(alignment: .leading, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8).fill(Color.black).frame(height: compact ? 72 : 112)
                        if state.previewEnabled, channel.streamURL != nil {
                            LivePreviewView(channel: channel).id(channel.id)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else if let logoURL = channel.logoURL {
                            AsyncImage(url: logoURL) { phase in
                                if let image = phase.image { image.resizable().scaledToFit().padding(18) } else { fallbackLogo }
                            }
                        } else { fallbackLogo }
                        if channel.isLive { Text("● LIVE").font(.system(size: 9, weight: .bold)).foregroundStyle(state.accent).padding(.horizontal, 7).padding(.vertical, 4).background(state.accent.opacity(0.2), in: Capsule()).padding(9) }
                    }
                    Text(channel.name)
                        .font(.system(size: compact ? 12 : 14, weight: .semibold))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: compact ? 42 : 20, alignment: .top)
                    Text(state.localizedGroup(channel.group)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(state.accent.opacity(0.38), lineWidth: 1))
                .contentShape(Rectangle())
                // Round-3 fix (A12): the round-2 nested-button fix turned
                // the card into a plain VStack, which VoiceOver no longer
                // announced as a button. Restore the button trait (the
                // press feedback of a real Button is still absent; the
                // nested retry gesture is why it cannot be a Button).
                // Round-4 fix (B05): the trait alone does not prove a
                // VoiceOver double-tap reaches onTapGesture, so give the
                // card an explicit accessibility activation as well.
                // Real VoiceOver behaviour still needs a device check.
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onOpen() }
                .onTapGesture { onOpen() }
            Button { state.toggleFavorite(channel) } label: {
                Image(systemName: state.favorites.contains(channel.id) ? "star.fill" : "star").foregroundStyle(.primary).frame(width: 36, height: 36)
            }.buttonStyle(.plain).padding(10)
        }
    }

    private var fallbackLogo: some View {
        Text(channel.name.localizedCaseInsensitiveContains("FOX") ? "FOX" : channel.name.prefix(1).uppercased())
            .font(.system(size: channel.name.localizedCaseInsensitiveContains("FOX") ? 45 : 30, weight: .heavy))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum DetailMode: String, CaseIterable {
    case subscriptions = "订阅"
    case channels = "频道"
    case programs = "节目"
}

struct ChannelDetailView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let channel: Channel
    @State private var activeChannel: Channel
    @State private var mode = DetailMode.channels
    @State private var detailGroup = GroupID.all
    @State private var search = ""
    @State private var showGroups = false
    @State private var showInfo = false
    // Round-8 fix (C03, detail-page extension): same staleness as the
    // home page — proxyAuthWarning is computed from a static flag, so
    // a migration failure during a successful refresh would not
    // re-render this page either. Bump on the notification.
    @State private var proxyMigrationTick = 0
    @State private var streamInfo = ""
    // Round-2 fix: set when the user switches subscriptions from the
    // detail page and the new subscription has no cached channels yet.
    // While set, the old subscription's player is NOT rendered (so it
    // stops instead of silently continuing), and the first channel of the
    // newly loaded subscription is picked up via onChange below.
    @State private var awaitingSubscriptionLoad = false

    init(channel: Channel) {
        self.channel = channel
        _activeChannel = State(initialValue: channel)
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3).frame(width: 44, height: 44).background(Color.panel, in: Circle()) }.buttonStyle(.plain)
                    Text(activeChannel.name).font(.headline).lineLimit(1)
                    Spacer()
                    Button { showInfo = true } label: { Image(systemName: "info.circle").font(.title3).frame(width: 44, height: 44) }.buttonStyle(.plain)
                    Button { state.toggleFavorite(activeChannel) } label: { Image(systemName: state.favorites.contains(activeChannel.id) ? "star.fill" : "star").font(.title3).frame(width: 44, height: 44) }.buttonStyle(.plain)
                }.padding(.horizontal, 18).padding(.top, 8)
                ZStack(alignment: .bottomLeading) {
                    if awaitingSubscriptionLoad {
                        Color.black
                        VStack(spacing: 8) {
                            if state.isLoadingPlaylist || state.isRefreshingPlaylist {
                                ProgressView().tint(.white)
                                Text(state.localized("正在加载新订阅…")).font(.caption).foregroundStyle(.secondary)
                            } else if let error = state.playlistError {
                                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                                Button(state.localized("订阅")) { state.cancelPlaylistLoad(); awaitingSubscriptionLoad = false; mode = .subscriptions }.buttonStyle(.bordered).tint(state.accent)
                            } else {
                                ProgressView().tint(.white)
                                Text(state.localized("正在加载新订阅…")).font(.caption).foregroundStyle(.secondary)
                                Button(state.localized("订阅")) { state.cancelPlaylistLoad(); awaitingSubscriptionLoad = false; mode = .subscriptions }.buttonStyle(.bordered).tint(state.accent)
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let url = activeChannel.streamURL {
                        PlayerSurface(url: url, title: activeChannel.name, engine: state.preferredPlayer, bufferMilliseconds: state.networkBufferMilliseconds, allowsPictureInPicture: state.pictureInPicture, hardwareAcceleration: state.hardwareAcceleration, automaticAudioSelection: state.automaticAudioSelection, showLatency: state.showLatency, streamInfo: $streamInfo).id(activeChannel.id)
                    } else {
                        Color.black
                        VStack(spacing: 8) {
                            Text(state.localized("无播放地址")).font(.headline)
                            Text(state.localized("该频道没有可播放地址。")).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if activeChannel.isLive { Text("LIVE").font(.caption.bold()).foregroundStyle(state.accent).padding(8) }
                }.aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(state.accent.opacity(0.7), lineWidth: 1)).padding(.horizontal, 16)
                Picker("", selection: $mode) { Text(state.localized("订阅")).tag(DetailMode.subscriptions); Text(state.localized("频道")).tag(DetailMode.channels); Text(state.localized("节目")).tag(DetailMode.programs) }.pickerStyle(.segmented).padding(.horizontal, 18).padding(.vertical, 12)
                // Round-9 fix (B01/C01/C03): one independent status
                // block for the whole detail page, below the player and
                // above the tab content. The round-8 warnings lived in
                // three separate branches (waiting-state error,
                // subscriptions list, programme-tab EPG error), so they
                // could appear twice at once (waiting warning + a tab
                // warning, the player and the tab list being on screen
                // together) and were missing entirely from the channels
                // tab, the waiting loading branch and the programme
                // tab's non-error states. Rendering once here, outside
                // every mode/error branch, covers all of them and can
                // never duplicate. The save-failure lines are new here
                // too: detail-page plays/favorites used to fail
                // silently on this page (saveError/currentNotice were
                // only rendered on the home page), with the same
                // notice-vs-saveError dedup the home page uses.
                if let proxyWarning = state.proxyAuthWarning {
                    Text(proxyWarning).font(.caption).foregroundStyle(.red).padding(.horizontal, 18)
                }
                if let notice = state.currentNotice, notice != state.saveError {
                    Text(notice).font(.caption).foregroundStyle(state.accent).padding(.horizontal, 18)
                }
                if let saveError = state.saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red).padding(.horizontal, 18)
                }
                ScrollView(showsIndicators: false) {
                    detailContent
                        .padding(.bottom, 24)
                }
            }
        }
        .onAppear {
            if state.selectedChannel?.id != activeChannel.id { state.play(activeChannel) }
        }
        .onChange(of: state.channels) { newChannels in
            if awaitingSubscriptionLoad, let first = newChannels.first {
                awaitingSubscriptionLoad = false
                activeChannel = first
                // Round-3 fix (A15): the shared stream-info line belongs
                // to the previous channel until the new session reports
                // its own; clear it on every switch so the info dialog
                // never briefly shows the old channel's codec/bitrate.
                streamInfo = ""
                state.play(first)
            }
        }
        .alert(state.localized("编码信息"), isPresented: $showInfo) { Button(state.localized("关闭"), role: .cancel) {} } message: { Text(streamInfo.isEmpty ? state.localized("暂无数据") : streamInfo) }
        .onReceive(NotificationCenter.default.publisher(for: M3UParser.proxyMigrationFailedChanged)) { _ in
            proxyMigrationTick += 1
        }
    }

    private var detailChannels: [Channel] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.channels.filter { item in
            (detailGroup == GroupID.all || item.group == detailGroup) &&
            (query.isEmpty || item.name.localizedCaseInsensitiveContains(query) || item.group.localizedCaseInsensitiveContains(query))
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch mode {
        case .subscriptions:
            if state.isLoadingPlaylist { ProgressView().tint(state.accent).padding(.top, 28) }
            ForEach(state.playlists) { playlist in
                Button {
                    state.activatePlaylist(playlist)
                    mode = .channels
                    if let first = state.channelSetsFirstChannel(for: playlist) {
                        activeChannel = first
                        streamInfo = ""
                        awaitingSubscriptionLoad = false
                    } else {
                        // No cache: do not keep playing the old
                        // subscription's channel while the new one loads.
                        awaitingSubscriptionLoad = true
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.stack.fill").foregroundStyle(state.accent).frame(width: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playlist.name).font(.headline)
                            Text("\(playlist.channelCount) \(state.localized("频道")) · \(playlist.kind.rawValue)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.clockwise.circle").font(.title2).foregroundStyle(state.accent)
                    }
                    .padding(14).background(Color.card, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16)
                }.buttonStyle(.plain).disabled(state.isLoadingPlaylist)
            }
            if let error = state.playlistError { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 20) }
        case .programs:
            EPGProgramList(channel: activeChannel)
        case .channels:
            // Round-4 fix (B06): DetailMode is a closed 3-case enum, so
            // the old default only ever meant .channels — but a future
            // case would silently have been treated as channels. Spell
            // it out so the compiler forces a decision for new cases.
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(state.localized("搜索频道..."), text: $search)
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.18)) { showGroups.toggle() } } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(state.accent).frame(width: 32, height: 32)
                }.buttonStyle(.plain)
            }.padding(10).background(Color.panel, in: RoundedRectangle(cornerRadius: 11)).padding(.horizontal, 18)
            if showGroups { detailGroupMenu }
            if detailChannels.isEmpty {
                VStack(spacing: 8) {
                    Text(state.localized("暂无频道")).font(.headline)
                    Button(state.localized("清除筛选")) { detailGroup = GroupID.all; search = "" }.buttonStyle(.bordered).tint(state.accent)
                }.padding(.top, 24)
            }
            ForEach(detailChannels) { item in
                Button { activeChannel = item; awaitingSubscriptionLoad = false; streamInfo = ""; state.play(item) } label: {
                    HStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.panel).frame(width: 76, height: 56).overlay {
                            if let logoURL = item.logoURL {
                                AsyncImage(url: logoURL) { phase in if let image = phase.image { image.resizable().scaledToFit().padding(8) } else { Image(systemName: "tv").foregroundStyle(.secondary) } }
                            } else { Image(systemName: "tv").foregroundStyle(.secondary) }
                        }
                        VStack(alignment: .leading) { Text(item.name).font(.headline); Text(state.localizedGroup(item.group)).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Image(systemName: item.id == activeChannel.id ? "play.circle.fill" : "play.circle").font(.title2).foregroundStyle(item.id == activeChannel.id ? state.accent : .secondary)
                    }.padding(10).background(item.id == activeChannel.id ? state.accent.opacity(0.12) : Color.card, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16)
                }.buttonStyle(.plain)
            }
        }
    }

    private var detailGroupMenu: some View {
        ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.groups, id: \.self) { group in
                Button { detailGroup = group; withAnimation { showGroups = false } } label: {
                    HStack { Text(state.localizedGroup(group)); Spacer(); if detailGroup == group { Image(systemName: "checkmark").foregroundStyle(state.accent) } }
                        .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }
        }
        .frame(maxHeight: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(state.accent.opacity(0.5), lineWidth: 1))
        .padding(.horizontal, 18)
    }

}

private struct EPGProgramList: View {
    @EnvironmentObject private var state: AppState
    let channel: Channel
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        // Round-3 fix (C25): currentProgram/nextProgram each re-ran the
        // full merge+sort+filter internally, so one body evaluation did
        // the work three times. Evaluate once and derive both markers
        // from the same list (and the same `now`).
        Group {
            if state.isLoadingEPG {
                ProgressView().tint(state.accent).padding(.top, 26)
            } else if let error = state.epgError {
                VStack(spacing: 8) {
                    Text(error).font(.subheadline).foregroundStyle(.red).multilineTextAlignment(.center)
                    Button(state.localized("刷新节目单")) { state.reloadEPG() }.buttonStyle(.borderedProminent).tint(state.accent)
                }.padding(.horizontal, 20).padding(.top, 20)
            } else {
                // Round-5 fix (B04): every row used to embed its own
                // TimelineView just to refresh its progress bar, so the
                // page ran one timer per visible row. One page-level
                // timer now drives all rows.
                // Round-6 fix (B02): the round-5 version computed
                // programs/current/next OUTSIDE the TimelineView, so a
                // tick only redrew the progress bars (whose `progress`
                // is a live Date() computation) while the "current" and
                // "next" markers stayed frozen on the values from the last
                // outer body evaluation — a programme could end and its
                // successor start without either marker moving. Derive
                // everything from the tick's own date inside the closure.
                TimelineView(.periodic(from: Date(), by: 60)) { timeline in
                    let now = timeline.date
                    let programs = state.programs(for: channel, now: now)
                    let current = programs.first { $0.start <= now && $0.end > now }
                    let next = programs.first { $0.start > now }
                    if programs.isEmpty {
                        Text(state.localized("暂无节目数据")).foregroundStyle(.secondary).padding(.top, 26)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(programs) { program in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("\(timeFormatter.string(from: program.start))–\(timeFormatter.string(from: program.end))").font(.caption.monospacedDigit()).foregroundStyle(state.accent)
                                        Text(program.title).font(.headline).lineLimit(2)
                                        Spacer()
                                        if program.id == current?.id { Text(state.localized("当前节目")).font(.caption2.bold()).foregroundStyle(state.accent) }
                                        else if program.id == next?.id { Text(state.localized("下一节目")).font(.caption2.bold()).foregroundStyle(.secondary) }
                                    }
                                    if let subtitle = program.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                                    if let description = program.programDescription { Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                                    ProgressView(value: program.progress).tint(state.accent)
                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.card, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 16)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct PlayerSurface: View {
    @EnvironmentObject private var state: AppState
    let url: URL
    let title: String
    let engine: PreferredPlayer
    let bufferMilliseconds: Double
    let allowsPictureInPicture: Bool
    let hardwareAcceleration: Bool
    let automaticAudioSelection: Bool
    let showLatency: Bool
    @Binding var streamInfo: String

    var body: some View {
        switch engine {
        case .ksPlayer:
            KSCompactPlayerView(url: url, bufferMilliseconds: bufferMilliseconds, allowsPictureInPicture: allowsPictureInPicture, hardwareAcceleration: hardwareAcceleration, automaticAudioSelection: automaticAudioSelection, showLatency: showLatency, streamInfo: $streamInfo)
        case .avPlayer, .auto:
            AdaptiveAVPlayerView(url: url, title: title, bufferMilliseconds: bufferMilliseconds, allowsPictureInPicture: allowsPictureInPicture, hardwareAcceleration: hardwareAcceleration, automaticAudioSelection: automaticAudioSelection, showLatency: showLatency, streamInfo: $streamInfo)
        }
    }
}

private struct PlaybackControlBar: View {
    let accent: Color
    let isPlaying: Bool
    let isMuted: Bool
    let showsPiP: Bool
    let showsProjection: Bool
    let onPlayPause: () -> Void
    let onMute: () -> Void
    let onPiP: () -> Void
    let audioOptions: [String]
    let videoOptions: [String]
    // Round-2 fix: AV "quality" options are bitrate caps, not forced
    // renditions, and the only place that said so was a code comment and
    // the README. When set, the menu shows this as a section header in-app.
    var videoMenuNote: String = ""
    var audioSelectedIndex: Int? = nil
    var videoSelectedIndex: Int? = nil
    let onAudioSelect: (Int) -> Void
    let onVideoSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 18) {
            controlButton(icon: isPlaying ? "pause.fill" : "play.fill", prominent: true, action: onPlayPause)
            controlButton(icon: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", action: onMute)
            if audioOptions.count > 1 {
                Menu {
                    ForEach(Array(audioOptions.enumerated()), id: \.offset) { index, name in
                        Button { onAudioSelect(index) } label: { Label(name, systemImage: audioSelectedIndex == index ? "checkmark" : "waveform") }
                    }
                } label: {
                    Image(systemName: "waveform").font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 40).foregroundStyle(.white)
                }.buttonStyle(.plain)
            }
            if videoOptions.count > 1 {
                Menu {
                    if videoMenuNote.isEmpty {
                        ForEach(Array(videoOptions.enumerated()), id: \.offset) { index, name in
                            Button { onVideoSelect(index) } label: { Label(name, systemImage: videoSelectedIndex == index ? "checkmark" : "sparkles.tv") }
                        }
                    } else {
                        Section {
                            ForEach(Array(videoOptions.enumerated()), id: \.offset) { index, name in
                                Button { onVideoSelect(index) } label: { Label(name, systemImage: videoSelectedIndex == index ? "checkmark" : "sparkles.tv") }
                            }
                        } header: { Text(videoMenuNote) }
                    }
                } label: {
                    Image(systemName: "4k.tv").font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 40).foregroundStyle(.white)
                }.buttonStyle(.plain)
            }
            if showsPiP { controlButton(icon: "rectangle.on.rectangle", action: onPiP) }
            if showsProjection { AirPlayButton() }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
    }

    private func controlButton(icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: prominent ? 21 : 17, weight: .semibold))
                .frame(width: prominent ? 44 : 40, height: prominent ? 44 : 40)
                .foregroundStyle(.white)
                .background(prominent ? accent.opacity(0.84) : .clear, in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain)
    }
}

private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .white
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

private struct KSCompactPlayerView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    let url: URL
    let bufferMilliseconds: Double
    let allowsPictureInPicture: Bool
    let hardwareAcceleration: Bool
    let automaticAudioSelection: Bool
    let showLatency: Bool
    @Binding var streamInfo: String
    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @State private var controlsVisible = true
    @State private var isPlaying = true
    @State private var isBuffering = true
    @State private var audioOptions: [String] = []
    @State private var videoOptions: [String] = []
    @State private var latencyMilliseconds: Int?
    @State private var hideToken = UUID()
    @State private var latencyTimer: Timer?
    @State private var didAutoSelectAudio = false
    @State private var pipActive = false
    @State private var stoppedForBackground = false
    // Round-7 fix (B01): an explicit user-pause flag, mirroring AV's
    // userPaused. The round-6 background test (isPlaying) cannot tell
    // "user paused" from "still buffering" — both read false — so a
    // buffering stream was neither stopped nor flagged on backgrounding.
    // Set only by togglePlay; cleared by play/rebuild/retry.
    @State private var ksUserPaused = false
    // Set when the stream finishes on its own, so a finished stream is
    // not mistaken for a buffering one and rebuilt on foreground return.
    @State private var ksDidFinish = false
    @State private var ksError: String?
    @State private var retryID = 0
    @State private var audioSelectedIndex: Int?
    @State private var videoSelectedIndex: Int?

    var body: some View {
        ZStack {
            Color.black
            KSVideoPlayer(coordinator: coordinator, url: url, options: options)
                .id(retryID)
                .onStateChanged { layer, playerState in
                    isPlaying = playerState.isPlaying
                    isBuffering = playerState == .preparing || playerState == .buffering
                    if playerState == .error {
                        isBuffering = false
                        ksError = state.localized("播放失败，请检查频道地址。")
                    } else if playerState == .readyToPlay || playerState == .bufferFinished {
                        ksError = nil
                        // Auto audio selection runs once at first readiness;
                        // it previously re-ran on every buffer finish and
                        // silently undid the user's manual track choice.
                        if automaticAudioSelection && !didAutoSelectAudio {
                            selectFirstAudio(on: layer)
                            didAutoSelectAudio = true
                        }
                        updateStreamInfo(from: layer)
                    }
                }
                .onFinish { _, _ in isPlaying = false; ksDidFinish = true; controlsVisible = true }
                .contentShape(Rectangle())
                .onTapGesture { controlsVisible ? hideControls() : revealControls() }
            if isBuffering { ProgressView().tint(.white).controlSize(.large) }
            if let ksError {
                VStack(spacing: 10) {
                    Text(ksError).font(.subheadline).foregroundStyle(.white).multilineTextAlignment(.center)
                    // Round-3 fix (A05): the retry label was hardcoded
                    // Chinese while the AV retry button was localized.
                    // Round-3 fix (D02): retrying used to only bump the
                    // view id, leaving the coordinator and the old track
                    // options/selected indices/auto-select flag in place
                    // for the new player. Reset all of them, plus the
                    // shared stream info, before recreating the view.
                    Button(state.localized("重试")) {
                        resetForRebuild()
                    }.buttonStyle(.borderedProminent)
                }.padding(.horizontal, 24)
            }
            if showLatency { StreamLatencyBadge(milliseconds: latencyMilliseconds).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading) }
            if controlsVisible {
                // Round-3 fix (A06): the PiP button used to show whenever
                // the setting was on, while the AV side gated on system
                // PiP support. KSPlayer exposes no per-stream support
                // query in this codebase, so the gate is the same system
                // support check the AV side uses; stream-level support
                // remains unverifiable statically.
                PlaybackControlBar(accent: state.accent, isPlaying: isPlaying, isMuted: coordinator.isMuted, showsPiP: allowsPictureInPicture && AVPictureInPictureController.isPictureInPictureSupported(), showsProjection: true, onPlayPause: togglePlay, onMute: toggleMute, onPiP: togglePiP, audioOptions: audioOptions, videoOptions: videoOptions, audioSelectedIndex: audioSelectedIndex, videoSelectedIndex: videoSelectedIndex, onAudioSelect: selectAudio, onVideoSelect: selectVideo)
                    .transition(.opacity)
            }
        }
        .onAppear {
            revealControls()
            // Re-sync PiP state from the layer: KSPlayer exposes no
            // PiP-stop callback in this codebase, so a stale @State value
            // previously survived a PiP stop made from the system UI and
            // then blocked every later player reset.
            pipActive = coordinator.playerLayer?.isPipActive ?? false
            latencyTimer?.invalidate()
            latencyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in sampleLatency() }
        }
        .onDisappear {
            latencyTimer?.invalidate(); latencyTimer = nil
            hideToken = UUID()
            // Re-read the layer instead of trusting the possibly stale
            // @State flag, then reset only when PiP is really inactive.
            pipActive = coordinator.playerLayer?.isPipActive ?? false
            if !pipActive { coordinator.resetPlayer() }
        }
        .onChange(of: scenePhase) { phase in
            // Round-3 fix (A01): backgrounding does not trigger
            // onDisappear, so a non-PiP KS player used to keep playing
            // under the audio background mode. Stop it unless PiP is
            // really active on the layer.
            if phase == .background {
                pipActive = coordinator.playerLayer?.isPipActive ?? false
                if !pipActive {
                    // Round-6 fix (B01): only a stream that was actually
                    // playing when backgrounded gets the rebuild flag.
                    // The old code set it for any non-PiP backgrounding,
                    // so a paused stream came back auto-playing (its pause
                    // intent lost) and a failed stream came back silently
                    // retried (its error banner cleared) — the same class
                    // of bug the round-5 AV fix (D5-07) closed on the AV
                    // side. A paused/failed player is not playing, so
                    // there is nothing to stop: leave it alone and do not
                    // set the flag. Only its latency timer is stopped;
                    // the foreground branch restarts the timer without
                    // rebuilding the player.
                    // Round-7 fix (B01): the round-6 test (isPlaying)
                    // cannot tell "user paused" from "still buffering"
                    // — both read false — so a buffering stream was
                    // neither stopped nor flagged. Judge by intent
                    // instead, like AV's stopUnlessPiP: stop unless PiP
                    // (outer guard), the stream failed, the user paused
                    // it, or it already finished on its own. A buffering
                    // stream is therefore stopped and flagged, exactly
                    // like a playing one.
                    let shouldStop = ksError == nil && !ksUserPaused && !ksDidFinish
                    latencyTimer?.invalidate(); latencyTimer = nil
                    if shouldStop {
                        coordinator.resetPlayer()
                        isPlaying = false
                        stoppedForBackground = true
                    }
                }
            } else if phase == .active {
                // Round-6 fix (B04, partial): re-sync pipActive from the
                // layer — PiP may have been stopped from the system UI
                // while backgrounded, leaving the @State flag stale for
                // later onDisappear decisions. This only keeps the flag
                // accurate; whether KSPlayer needs a rebuild after a
                // background PiP stop is still unverified on device, so
                // no rebuild is forced here on that basis alone.
                pipActive = coordinator.playerLayer?.isPipActive ?? pipActive
                if stoppedForBackground {
                    // Round-4 fix (B01): the round-3 background stop left a
                    // dead player on return (resetPlayer with no rebuild, and
                    // a stale pause icon). Rebuild the same way the retry
                    // button does: reset + bump the view id so the player is
                    // recreated, then play. PiP sessions never set this flag.
                    // Round-5 fix (B02/B03): the foreground branch used to
                    // skip the retry button's cleanup (stale error banner,
                    // track menus, selected indices, auto-select flag) and
                    // never rebuilt the latency timer the background branch
                    // had invalidated, freezing the latency badge.
                    stoppedForBackground = false
                    resetForRebuild()
                    latencyTimer?.invalidate()
                    latencyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in sampleLatency() }
                    revealControls()
                } else if latencyTimer == nil {
                    // Paused/failed players were not rebuilt above, but
                    // their timer was stopped on backgrounding; restart it
                    // so the badge follows the (paused/failed) player again
                    // instead of freezing on its pre-background value.
                    latencyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in sampleLatency() }
                }
            }
        }
    }

    private var options: KSOptions {
        let options = ConfiguredKSOptions(automaticAudioSelection: automaticAudioSelection)
        options.preferredForwardBufferDuration = max(bufferMilliseconds / 1000, 0)
        options.hardwareDecode = hardwareAcceleration
        options.canStartPictureInPictureAutomaticallyFromInline = allowsPictureInPicture
        options.registerRemoteControll = true
        return options
    }

    /// Shared rebuild path for the retry button and the foreground
    /// resume (round-5 B02): both must clear the same state, otherwise
    /// a rebuilt player briefly shows the previous stream's error banner,
    /// track menus and selected indices, and a stale auto-select flag can
    /// skip first-readiness audio selection on the new player.
    private func resetForRebuild() {
        ksError = nil
        // Round-6 fix (B03): the old code left latencyMilliseconds
        // untouched, so for up to one sampling period after a rebuild
        // the badge still showed the previous stream's last value.
        latencyMilliseconds = nil
        coordinator.resetPlayer()
        audioOptions = []
        videoOptions = []
        audioSelectedIndex = nil
        videoSelectedIndex = nil
        didAutoSelectAudio = false
        ksUserPaused = false
        ksDidFinish = false
        isPlaying = true
        isBuffering = true
        streamInfo = ""
        retryID += 1
    }

    private func togglePlay() {
        // Use the player's actual state, not the asynchronously updated
        // isPlaying snapshot, so rapid taps cannot invert the action.
        let playing = coordinator.playerLayer?.player.isPlaying ?? isPlaying
        // Round-7 fix (B01): record the user's pause intent here — the
        // only place it can be known — so the background handler can
        // tell "paused" apart from "buffering" (both read isPlaying
        // false). Resuming clears both the pause and finish flags.
        if playing { coordinator.playerLayer?.pause(); ksUserPaused = true } else { coordinator.playerLayer?.play(); ksUserPaused = false; ksDidFinish = false }
        revealControls()
    }

    private func toggleMute() { coordinator.isMuted.toggle(); revealControls() }
    private func togglePiP() {
        guard let layer = coordinator.playerLayer else { return }
        layer.isPipActive.toggle()
        pipActive = layer.isPipActive
        revealControls()
    }

    private func selectAudio(_ index: Int) {
        guard let layer = coordinator.playerLayer else { return }
        let tracks = layer.player.tracks(mediaType: .audio)
        guard tracks.indices.contains(index) else { return }
        tracks.forEach { $0.isEnabled = false }
        tracks[index].isEnabled = true
        didAutoSelectAudio = true
        updateTrackOptions(from: layer)
        updateStreamInfo(from: layer)
        revealControls()
    }

    private func selectVideo(_ index: Int) {
        guard let layer = coordinator.playerLayer else { return }
        let tracks = layer.player.tracks(mediaType: .video)
        guard tracks.indices.contains(index) else { return }
        tracks.forEach { $0.isEnabled = false }
        tracks[index].isEnabled = true
        updateTrackOptions(from: layer)
        updateStreamInfo(from: layer)
        revealControls()
    }

    private func selectFirstAudio(on layer: KSPlayerLayer) {
        guard let track = layer.player.tracks(mediaType: .audio).first else { return }
        if !track.isEnabled { layer.player.select(track: track) }
    }

    private func revealControls() {
        withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true }
        let token = UUID()
        hideToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if hideToken == token && isPlaying { withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false } }
        }
    }

    private func hideControls() { hideToken = UUID(); withAnimation(.easeOut(duration: 0.15)) { controlsVisible = false } }

    private func updateStreamInfo(from layer: KSPlayerLayer) {
        let player = layer.player
        var lines: [String] = ["Engine  KSPlayer"]
        let videoTracks = player.tracks(mediaType: .video)
        let audioTracks = player.tracks(mediaType: .audio)
        audioOptions = audioTracks.enumerated().map { index, track in track.name.isEmpty ? "Audio \(index + 1)" : track.name }
        audioSelectedIndex = audioTracks.firstIndex(where: { $0.isEnabled })
        videoOptions = videoTracks.count > 1 ? videoTracks.enumerated().map { index, track in track.name.isEmpty ? "Video \(index + 1)" : track.name } : []
        videoSelectedIndex = videoTracks.firstIndex(where: { $0.isEnabled })
        if let video = videoTracks.first(where: { $0.isEnabled }) ?? videoTracks.first {
            lines.append("Video  \(video.name)")
            if video.nominalFrameRate > 0 { lines.append(String(format: "Frame rate  %.2f fps", video.nominalFrameRate)) }
            if video.bitRate > 0 { lines.append("Bit rate  \(Int(video.bitRate / 1000)) kbps") }
            lines.append("Codec  \(video.description)")
        }
        if let audio = audioTracks.first(where: { $0.isEnabled }) ?? audioTracks.first { lines.append("Audio  \(audio.name)") }
        let size = player.naturalSize
        if size.width > 0 && size.height > 0 { lines.append("Resolution  \(Int(size.width)) × \(Int(size.height))") }
        streamInfo = lines.joined(separator: "\n")
    }

    private func updateTrackOptions(from layer: KSPlayerLayer) {
        let player = layer.player
        let audioTracks = player.tracks(mediaType: .audio)
        audioOptions = audioTracks.enumerated().map { index, track in track.name.isEmpty ? "Audio \(index + 1)" : track.name }
        audioSelectedIndex = audioTracks.firstIndex(where: { $0.isEnabled })
        let videoTracks = player.tracks(mediaType: .video)
        videoOptions = videoTracks.count > 1 ? videoTracks.enumerated().map { index, track in track.name.isEmpty ? "Video \(index + 1)" : track.name } : []
        videoSelectedIndex = videoTracks.firstIndex(where: { $0.isEnabled })
    }

    private func sampleLatency() {
        guard let player = coordinator.playerLayer?.player,
              player.isPlaying,
              player.seekable,
              player.playableTime.isFinite,
              player.currentPlaybackTime.isFinite else {
            latencyMilliseconds = nil
            return
        }
        let seconds = player.playableTime - player.currentPlaybackTime
        latencyMilliseconds = seconds >= 0 && seconds.isFinite ? Int((seconds * 1000).rounded()) : nil
    }
}

private final class ConfiguredKSOptions: KSOptions {
    let automaticAudioSelection: Bool
    init(automaticAudioSelection: Bool) {
        self.automaticAudioSelection = automaticAudioSelection
        super.init()
    }

    override func wantedAudio(tracks: [MediaPlayerTrack]) -> Int? {
        automaticAudioSelection ? (tracks.isEmpty ? nil : 0) : nil
    }
}

private struct AdaptiveAVPlayerView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    let url: URL
    let title: String
    let bufferMilliseconds: Double
    let allowsPictureInPicture: Bool
    let hardwareAcceleration: Bool
    let automaticAudioSelection: Bool
    let showLatency: Bool
    @Binding var streamInfo: String
    @StateObject private var session: AVPlaybackSession

    init(url: URL, title: String, bufferMilliseconds: Double, allowsPictureInPicture: Bool, hardwareAcceleration: Bool, automaticAudioSelection: Bool, showLatency: Bool, streamInfo: Binding<String>) {
        self.url = url
        self.title = title
        self.bufferMilliseconds = bufferMilliseconds
        self.allowsPictureInPicture = allowsPictureInPicture
        self.hardwareAcceleration = hardwareAcceleration
        self.automaticAudioSelection = automaticAudioSelection
        self.showLatency = showLatency
        _streamInfo = streamInfo
        _session = StateObject(wrappedValue: AVPlaybackSession(url: url, bufferMilliseconds: bufferMilliseconds, automaticAudioSelection: automaticAudioSelection))
    }

    var body: some View {
        ZStack {
            if session.didFail {
                // Round-2 fix: AV retry was previously unreachable — the
                // fallback branch replaced the whole AV UI and session.play()
                // only runs on onAppear, so a failed stream could only be
                // retried by closing and reopening the detail page. The
                // retry button rebuilds the AV item in place (session.retry()
                // also clears didFail, which swaps the AV layer back in).
                ZStack(alignment: .topTrailing) {
                    KSCompactPlayerView(url: url, bufferMilliseconds: bufferMilliseconds, allowsPictureInPicture: allowsPictureInPicture, hardwareAcceleration: hardwareAcceleration, automaticAudioSelection: automaticAudioSelection, showLatency: showLatency, streamInfo: $streamInfo)
                    Button(state.localized("用 AVPlayer 重试")) { session.retry() }
                        .buttonStyle(.bordered).tint(state.accent)
                        .font(.caption).padding(8)
                }
            } else {
                AVPlayerLayerView(session: session)
            }
            if session.isBuffering && !session.didFail { ProgressView().tint(.white).controlSize(.large) }
            if showLatency && !session.didFail { StreamLatencyBadge(milliseconds: session.latencyMilliseconds).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading) }
            if !session.didFail {
                PlaybackControlBar(accent: state.accent, isPlaying: session.isPlaying, isMuted: session.isMuted, showsPiP: allowsPictureInPicture && session.isPiPSupported, showsProjection: true, onPlayPause: session.togglePlay, onMute: session.toggleMute, onPiP: session.togglePiP, audioOptions: session.audioOptions, videoOptions: session.videoOptions, videoMenuNote: state.localized("码率上限"), audioSelectedIndex: session.audioSelectedIndex, videoSelectedIndex: session.videoSelectedIndex, onAudioSelect: session.selectAudio, onVideoSelect: session.selectVideo)
            }
            // Round-3 fix (A09): when an AV failure stops a live PiP
            // session, say so instead of silently replacing it with an
            // inline KS player (KS cannot take over an AV PiP session).
            if session.didFail && session.fallbackStoppedPiP {
                Text(state.localized("画中画已停止")).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 8)
            }
        }
        .onReceive(session.$streamInfo) { if !session.didFail { streamInfo = $0 } }
        .onAppear { session.play() }
        // Round-3 fix (A14): stopUnlessPiP reads the controller's live
        // value instead of the asynchronously updated flag, so a PiP
        // session started an instant before closing the detail page is
        // not killed by a stale "not active" snapshot.
        .onDisappear { session.stopUnlessPiP() }
        .onChange(of: scenePhase) { phase in
            // Round-3 fix (A01): backgrounding does not trigger
            // onDisappear, so a non-PiP AV player used to keep playing
            // under the audio background mode.
            if phase == .background { session.stopUnlessPiP() }
            // Round-4 fix (B01): the background stop replaced the item
            // with nil, and returning to the foreground never rebuilt it
            // (onAppear does not re-fire), leaving a dead player with no
            // retry button because didFail is false.
            // Round-5 fix (B01): resumeAfterBackground, not play():
            // an unconditional play() rebuilt a nil item via retry(),
            // which silently swapped a KS fallback back to AV after a
            // failure and auto-played a stream the user had paused.
            else if phase == .active { session.resumeAfterBackground() }
        }
    }
}

private struct AVPlayerLayerView: UIViewRepresentable {
    @ObservedObject var session: AVPlaybackSession

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.attach(session: session)
        return view
    }

    func updateUIView(_ view: PlayerLayerHostView, context: Context) { view.attach(session: session) }
    static func dismantleUIView(_ view: PlayerLayerHostView, coordinator: ()) { view.detach() }
}

private final class PlayerLayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private weak var session: AVPlaybackSession?

    func attach(session: AVPlaybackSession) {
        self.session = session
        playerLayer.player = session.player
        playerLayer.videoGravity = .resizeAspect
        session.attach(playerLayer: playerLayer)
    }

    func detach() {
        session?.detach(playerLayer: playerLayer)
        // Do not nil the player here: the session keeps the PiP controller
        // alive so picture-in-picture survives the detail view disappearing.
        // When PiP later stops, the session stops itself (see delegate).
        session = nil
    }
}

@MainActor
private final class AVPlaybackSession: NSObject, ObservableObject {
    let player: AVPlayer
    @Published var didFail = false
    @Published var isPlaying = false
    @Published var isBuffering = true
    @Published var isMuted = false
    @Published var isPiPSupported = false
    @Published var isPiPActive = false
    /// Set when a fallback stops a live PiP session, so the UI can tell
    /// the user instead of silently swapping PiP for an inline player.
    @Published var fallbackStoppedPiP = false
    @Published var streamInfo = ""
    @Published var audioOptions: [String] = []
    @Published var videoOptions: [String] = []
    @Published var audioSelectedIndex: Int?
    @Published var videoSelectedIndex: Int?
    @Published private(set) var latencyMilliseconds: Int?
    private let automaticAudioSelection: Bool
    private let sourceURL: URL
    private let bufferSeconds: Double
    private var viewDetached = false
    /// Explicit user-pause flag (round-4 B02): timeControlStatus alone
    /// cannot tell "user paused" from "buffering", so the video check
    /// must not use it as its guard. Set only by togglePlay.
    private var userPaused = false
    /// Round-5 fix (B01): whether the background stop interrupted a
    /// session that was actually playing. The round-4 foreground resume
    /// called play() unconditionally, which rebuilt a nil item via
    /// retry() — silently swapping a KS fallback back to AV after a
    /// failure, and auto-playing a stream the user had paused. Only a
    /// session stopped while playing (not paused, not failed) resumes.
    private var stoppedForBackground = false
    private var notReadyTask: Task<Void, Never>?
    private var audioGroupOptions: [AVMediaSelectionOption] = []
    private var audioGroup: AVMediaSelectionGroup?
    private var statusObservation: NSKeyValueObservation?
    private var timeObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var pipController: AVPictureInPictureController?
    private var attachedLayer: AVPlayerLayer?
    private var infoTask: Task<Void, Never>?
    private var videoCheckTask: Task<Void, Never>?
    private var optionsTask: Task<Void, Never>?
    private var latencyTask: Task<Void, Never>?
    private weak var currentItem: AVPlayerItem?

    init(url: URL, bufferMilliseconds: Double, automaticAudioSelection: Bool) {
        self.automaticAudioSelection = automaticAudioSelection
        self.sourceURL = url
        self.bufferSeconds = max(bufferMilliseconds / 1000, 0)
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = bufferSeconds
        player = AVPlayer(playerItem: item)
        currentItem = item
        super.init()
        observe(item: item)
        scheduleNotReadyTimeout()
    }

    private func observe(item: AVPlayerItem) {
        statusObservation?.invalidate()
        statusObservation = item.observe(\AVPlayerItem.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.didFail = false
                    self.notReadyTask?.cancel()
                    // Buffering is driven solely by timeControlStatus (see
                    // timeObservation); readyToPlay no longer fights it.
                    if self.automaticAudioSelection { await self.selectAudioTrack(on: item) }
                    self.loadSelectionOptions(for: item, url: self.sourceURL)
                    self.loadStreamInfo(for: item)
                    self.scheduleVideoCheck(for: item)
                    self.startLatencyMonitoring(for: item)
                case .failed:
                    self.teardownForFallback()
                default:
                    break
                }
            }
        }
        timeObservation?.invalidate()
        timeObservation = player.observe(\AVPlayer.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = player.timeControlStatus == .playing
                self.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
        sizeObservation?.invalidate()
        sizeObservation = item.observe(\AVPlayerItem.presentationSize, options: [.new]) { [weak self] item, _ in
            // Read on the main actor, like the other observations.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if item.presentationSize.width > 0 {
                    self.videoCheckTask?.cancel()
                }
            }
        }
    }

    /// A stream stuck before readyToPlay previously spun forever: no
    /// timeout, no failure, no KS fallback. After 15s it now falls back.
    private func scheduleNotReadyTimeout() {
        notReadyTask?.cancel()
        notReadyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                if self.player.currentItem?.status != .readyToPlay && !self.didFail {
                    self.teardownForFallback()
                }
            }
        }
    }

    /// Pause, release the item and cancel every task, so a KS fallback does
    /// not run alongside a still-alive AV session.
    private func teardownForFallback() {
        cancelAllTasks()
        // Round-2 fix: the old teardown left the item's KVO observations
        // live and left a PiP controller attached to a dead item. Item
        // observations are invalidated here (retry() re-creates them via
        // observe(item:)); a live PiP session is stopped rather than left
        // showing a black frame, and its delegate (not a nilled controller)
        // reports the stop back to isPiPActive.
        statusObservation?.invalidate(); statusObservation = nil
        sizeObservation?.invalidate(); sizeObservation = nil
        // Round-3 fix (A08): the timeControlStatus observation was left
        // live, so it kept writing isPlaying/isBuffering for the dead
        // session until retry() or deinit rebuilt it.
        timeObservation?.invalidate(); timeObservation = nil
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
            // Round-3 fix (A09): remember that PiP was stopped by the
            // fallback so the UI can say so (see AdaptiveAVPlayerView).
            fallbackStoppedPiP = true
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        didFail = true
        isBuffering = false
        // Round-7 fix (B02): the round-6 latency cleanup only covered
        // KS's resetForRebuild; AV's teardown left the previous stream's
        // last latency value on screen until the next sample.
        latencyMilliseconds = nil
    }

    private func cancelAllTasks() {
        infoTask?.cancel(); videoCheckTask?.cancel(); optionsTask?.cancel(); latencyTask?.cancel(); notReadyTask?.cancel()
        infoTask = nil; videoCheckTask = nil; optionsTask = nil; latencyTask = nil; notReadyTask = nil
    }

    func play() {
        if didFail { retry(); return }
        // Round-4 fix (B01/B04): a background stop leaves currentItem
        // nil, so a plain player.play() is a no-op on return; rebuild
        // via retry(). Also re-arm the 15s not-ready timeout from play()
        // instead of only from init (B04): the item starts loading at
        // init, but play() is the user-visible start of playback.
        if currentItem == nil { retry(); return }
        scheduleNotReadyTimeout()
        userPaused = false
        player.play()
    }

    /// Explicit retry: rebuild the item and its observations instead of
    /// leaving didFail permanently latched for the view's lifetime.
    func retry() {
        cancelAllTasks()
        userPaused = false
        didFail = false
        isBuffering = true
        // Round-7 fix (B02): same KS-parity gap as teardownForFallback
        // — the badge kept the old stream's value until the new item's
        // first sample (about one sampling period).
        latencyMilliseconds = nil
        // Round-3 fix (A10): the old retry kept the previous item's
        // menus and stream info, so before the new item was ready the
        // control bar could apply a stale audio-group snapshot to it
        // and select the wrong track. Clear first; readyToPlay rebuilds.
        audioOptions = []
        videoOptions = []
        audioGroupOptions = []
        audioGroup = nil
        audioSelectedIndex = nil
        videoSelectedIndex = nil
        streamInfo = ""
        fallbackStoppedPiP = false
        let item = AVPlayerItem(url: sourceURL)
        item.preferredForwardBufferDuration = bufferSeconds
        player.replaceCurrentItem(with: item)
        currentItem = item
        observe(item: item)
        scheduleNotReadyTimeout()
        player.play()
    }

    func stop() {
        cancelAllTasks()
        userPaused = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        // Round-7 fix (B02): stop() cancels the latency sampling task,
        // so without this the badge froze on the stopped stream's last
        // value (notably for a paused session returning from background
        // without a rebuild).
        latencyMilliseconds = nil
    }

    /// Stops unless picture-in-picture is really running. Reads the
    /// controller's synchronous value first (round-3 A14): the @Published
    /// flag is updated from an async delegate callback and can still read
    /// false in the instant after PiP starts.
    func stopUnlessPiP() {
        if pipController?.isPictureInPictureActive == true || isPiPActive { return }
        // Round-5 fix (B01): record the intent BEFORE stop() clears
        // userPaused and nils the item, so the foreground handler can
        // tell "was playing, interrupted by backgrounding" apart from
        // "was paused" and "had already failed over to KS".
        stoppedForBackground = !userPaused && !didFail && currentItem != nil
        stop()
    }

    /// Foreground counterpart of stopUnlessPiP: rebuilds only a session
    /// the background stop actually interrupted. A paused session stays
    /// paused and a failed session keeps its KS fallback (and its manual
    /// "retry with AVPlayer" button) instead of being auto-retried.
    func resumeAfterBackground() {
        guard stoppedForBackground else { return }
        stoppedForBackground = false
        guard !didFail else { return }
        play()
    }
    func togglePlay() {
        if player.timeControlStatus == .playing {
            userPaused = true
            player.pause()
        } else {
            userPaused = false
            player.play()
            // Round-4 fix (B02): a pause inside the 8s window used to
            // swallow the video check forever. Resuming re-arms it, so
            // a still-pictureless stream still falls back after 8s.
            if let item = currentItem { scheduleVideoCheck(for: item) }
        }
    }
    func toggleMute() { isMuted.toggle(); player.isMuted = isMuted }

    func attach(playerLayer: AVPlayerLayer) {
        guard attachedLayer !== playerLayer else { return }
        if let old = pipController { old.delegate = nil }
        attachedLayer = playerLayer
        viewDetached = false
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller = AVPictureInPictureController(playerLayer: playerLayer)
        controller?.delegate = self
        pipController = controller
        isPiPSupported = controller != nil
    }

    func detach(playerLayer: AVPlayerLayer) {
        guard attachedLayer === playerLayer else { return }
        // Do NOT stop PiP here: that killed picture-in-picture whenever the
        // detail view disappeared. Keep the controller alive; when PiP
        // later stops, the delegate stops playback if the view is gone.
        viewDetached = true
        isPiPActive = pipController?.isPictureInPictureActive ?? false
        attachedLayer = nil
    }

    func togglePiP() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive { pipController.stopPictureInPicture() } else { pipController.startPictureInPicture() }
    }

    func selectAudio(_ index: Int) {
        guard let item = currentItem else { return }
        Task { @MainActor [weak self] in
            guard let self, let item = self.currentItem else { return }
            // Use the group snapshot taken when the menu was built, so the
            // menu index cannot drift from the option it selects. Fall back
            // to a fresh group only if no snapshot exists.
            if let group = self.audioGroup, group.options.indices.contains(index) {
                item.select(group.options[index], in: group)
                self.audioSelectedIndex = index
                return
            }
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                  group.options.indices.contains(index) else { return }
            item.select(group.options[index], in: group)
            self.audioSelectedIndex = index
        }
    }

    func selectVideo(_ index: Int) {
        guard videoOptions.indices.contains(index) else { return }
        // Honest label: AVPlayer does not let us pick a variant index; these
        // are preferred peak bitrates (a cap), not a forced rendition. The
        // menu header in the UI now says so via the "码率上限" note in the
        // README; the option list itself stays short and factual.
        let option = videoOptions[index]
        switch option {
        case "自动":
            player.currentItem?.preferredPeakBitRate = 0
        case "4K":
            player.currentItem?.preferredPeakBitRate = 16_000_000
        case "1440p":
            player.currentItem?.preferredPeakBitRate = 12_000_000
        case "1080p":
            player.currentItem?.preferredPeakBitRate = 8_000_000
        case "720p":
            player.currentItem?.preferredPeakBitRate = 4_000_000
        case "540p":
            player.currentItem?.preferredPeakBitRate = 3_000_000
        case "480p":
            player.currentItem?.preferredPeakBitRate = 2_000_000
        case "360p":
            player.currentItem?.preferredPeakBitRate = 1_000_000
        default:
            break
        }
        videoSelectedIndex = index
    }

    private func selectAudioTrack(on item: AVPlayerItem) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
        let option = group.defaultOption ?? group.options.first
        if let option { item.select(option, in: group) }
    }

    private func loadSelectionOptions(for item: AVPlayerItem, url: URL) {
        optionsTask?.cancel()
        optionsTask = Task { [weak self, weak item] in
            guard let self, let item else { return }
            if let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) {
                let names = group.options.enumerated().map { index, option in
                    let display = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    return display.isEmpty ? "Audio \(index + 1)" : display
                }
                let selected = group.options.firstIndex(where: { $0 == item.currentMediaSelection.selectedMediaOption(in: group) })
                await MainActor.run {
                    self.audioGroup = group
                    self.audioGroupOptions = group.options
                    self.audioOptions = names
                    self.audioSelectedIndex = selected
                }
            }
            if let urlAsset = item.asset as? AVURLAsset,
               let variants = try? await urlAsset.load(.variants) {
                let names = variants.compactMap { variant -> String? in
                    let height = variant.videoAttributes?.presentationSize.height ?? 0
                    if height >= 2160 { return "4K" }
                    if height >= 1440 { return "1440p" }
                    if height >= 1080 { return "1080p" }
                    if height >= 720 { return "720p" }
                    if height >= 540 { return "540p" }
                    if height >= 480 { return "480p" }
                    if height >= 360 { return "360p" }
                    return nil
                }
                var unique: [String] = []
                for value in ["自动"] + names where !unique.contains(value) { unique.append(value) }
                await MainActor.run {
                    self.videoOptions = unique.count > 1 ? unique : []
                    self.videoSelectedIndex = unique.count > 1 ? 0 : nil
                }
            } else {
                await MainActor.run { self.videoOptions = []; self.videoSelectedIndex = nil }
            }
        }
    }

    private func startLatencyMonitoring(for item: AVPlayerItem) {
        latencyTask?.cancel()
        latencyTask = Task { [weak self, weak item] in
            while !Task.isCancelled {
                guard let self, let item else { return }
                let value: Int? = {
                    guard self.player.timeControlStatus == .playing,
                          let range = item.seekableTimeRanges.last?.timeRangeValue,
                          range.isValid,
                          range.duration.isNumeric,
                          let current = self.player.currentItem?.currentTime(),
                          current.isNumeric else { return nil }
                    let seconds = range.end.seconds - current.seconds
                    guard seconds >= 0, seconds.isFinite else { return nil }
                    return Int((seconds * 1000).rounded())
                }()
                await MainActor.run { self.latencyMilliseconds = value }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func loadStreamInfo(for item: AVPlayerItem) {
        infoTask?.cancel()
        infoTask = Task { [weak self, weak item] in
            guard let self, let item else { return }
            do {
                let tracks = try await item.asset.load(.tracks)
                var lines = ["Engine  AVPlayer"]
                if let video = tracks.first(where: { $0.mediaType == .video && $0.isEnabled }) ?? tracks.first(where: { $0.mediaType == .video }) {
                    let size = try await video.load(.naturalSize)
                    let fps = try await video.load(.nominalFrameRate)
                    let rate = try await video.load(.estimatedDataRate)
                    if size.width > 0 && size.height > 0 { lines.append("Resolution  \(Int(size.width)) × \(Int(size.height))") }
                    if fps > 0 { lines.append(String(format: "Frame rate  %.2f fps", fps)) }
                    if rate > 0 { lines.append("Bit rate  \(Int(rate / 1000)) kbps") }
                    let descriptions = try await video.load(.formatDescriptions)
                    if let codec = Self.codecName(for: descriptions) { lines.append("Video codec  \(codec)") }
                }
                if let audio = tracks.first(where: { $0.mediaType == .audio }) {
                    let descriptions = try await audio.load(.formatDescriptions)
                    if let codec = Self.codecName(for: descriptions) { lines.append("Audio codec  \(codec)") }
                }
                await MainActor.run { self.streamInfo = lines.joined(separator: "\n") }
            } catch {
                // Round-3 fix (D01): the fallback sentence used to be a
                // hardcoded English string in every language. The system
                // error description (already localized by the OS) is kept
                // when present; otherwise only the engine line is shown.
                let message = item.error?.localizedDescription
                await MainActor.run { self.streamInfo = message.map { "Engine  AVPlayer\n\($0)" } ?? "Engine  AVPlayer" }
            }
        }
    }

    private func scheduleVideoCheck(for item: AVPlayerItem) {
        videoCheckTask?.cancel()
        videoCheckTask = Task { [weak self, weak item] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self, let item, item.presentationSize == .zero else { return }
            do {
                let tracks = try await item.asset.load(.tracks)
                // Pure-audio streams legitimately have presentationSize == .zero;
                // they must not be failed over after 8 seconds.
                guard !Task.isCancelled, tracks.contains(where: { $0.mediaType == .video }), item.presentationSize == .zero else { return }
                await MainActor.run {
                    // Final recheck on the main actor: the picture may have
                    // appeared while tracks were loading.
                    // Round-4 fix (B02): the round-3 guard used
                    // timeControlStatus == .playing, which also skips a
                    // buffering stream (waitingToPlayAtSpecifiedRate) —
                    // exactly the "picture never appears" case this check
                    // exists for. Only an explicit user pause skips it,
                    // and togglePlay re-arms the check on resume.
                    guard item.presentationSize == .zero, !self.userPaused else { return }
                    self.teardownForFallback()
                }
            } catch {
                // A network stream can delay track discovery; leave it to AVPlayer rather than failing on metadata alone.
            }
        }
    }

    private static func codecName(for descriptions: [Any]) -> String? {
        guard let first = descriptions.first else { return nil }
        guard let description = first as? CMFormatDescription else { return nil }
        let code = CMFormatDescriptionGetMediaSubType(description)
        let bytes: [UInt8] = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    deinit {
        // Defensive only: stop() is the real teardown path and is always
        // called from onDisappear (except when PiP is active). A @MainActor
        // deinit is not isolated, so this does the minimum safe cleanup.
        statusObservation?.invalidate(); timeObservation?.invalidate(); sizeObservation?.invalidate()
        cancelAllTasks(); pipController?.delegate = nil; player.pause(); player.replaceCurrentItem(with: nil)
    }
}

extension AVPlaybackSession: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { Task { [weak self] in await MainActor.run { self?.isPiPActive = true } } }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { Task { [weak self] in await MainActor.run { self?.isPiPActive = false } } }
    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { Task { [weak self] in await MainActor.run { guard let self else { return }; self.isPiPActive = false; if self.viewDetached { self.stop() } } } }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { completionHandler(true) }
}

struct FavoritesView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedDetail: Channel?
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Text(state.localized("收藏")).font(.system(size: 31, weight: .bold)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.top, 62)
                if state.favoriteChannels.isEmpty {
                    VStack(spacing: 0) {
                        Spacer()
                        Image(systemName: "star").font(.system(size: 58, weight: .thin)).foregroundStyle(.secondary)
                        Text(state.localized("无收藏频道")).font(.system(size: 23, weight: .bold)).padding(.top, 22)
                        Text(state.localized("用星号标记频道以便在此快速访问。")).font(.system(size: 17)).padding(.top, 5)
                        Spacer()
                    }.frame(minHeight: 400)
                } else {
                    LazyVStack(spacing: 12) { ForEach(state.favoriteChannels) { channel in ChannelCard(channel: channel) { state.play(channel); selectedDetail = channel } } }.padding(.horizontal, 22).padding(.top, 28)
                }
            }.padding(.bottom, 110)
        }
        .fullScreenCover(item: $selectedDetail) { ChannelDetailView(channel: $0) }
    }
}

struct EmptyHomeState: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 44, weight: .thin)).foregroundStyle(.secondary)
            Text(state.localized("暂无频道")).font(.title3.bold())
            Text(state.localized("请先在“播放列表”中添加 M3U 或 Xtream 来源。")).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(.top, 72).padding(.horizontal, 28)
    }
}

struct PlaylistsView: View {
    @EnvironmentObject private var state: AppState
    @Binding var showAdd: Bool
    @State private var editingPlaylist: Playlist?
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Button { state.refreshPlaylists() } label: { Image(systemName: "arrow.clockwise").font(.title2).foregroundStyle(state.accent) }.buttonStyle(.plain); Spacer(); Button { showAdd = true } label: { Image(systemName: "plus").font(.title2).foregroundStyle(state.accent) }.buttonStyle(.plain) }.padding(.horizontal, 28).padding(.top, 54)
                Text(state.localized("播放列表")).font(.system(size: 31, weight: .bold)).padding(.horizontal, 28).padding(.bottom, 16)
                // Round-5 fix (A04): the dedup-refresh notice ("already
                // refreshed") was only rendered on the settings page and
                // on the form page that had just dismissed, never here
                // where the import lands — so a user who expected a new
                // entry saw the count unchanged with no explanation.
                if let notice = state.currentNotice { Text(notice).font(.caption).foregroundStyle(state.accent).padding(.horizontal, 28) }
                if state.playlists.isEmpty {
                    Text(state.localized("暂无播放列表")).foregroundStyle(.secondary).padding(.horizontal, 28)
                } else {
                    ForEach(state.playlists) { playlist in PlaylistRow(playlist: playlist, onEdit: { editingPlaylist = playlist }) { state.removePlaylist(playlist) } }
                }
            }.padding(.bottom, 120)
        }
        .sheet(item: $editingPlaylist) { playlist in PlaylistFormView(editingPlaylist: playlist) }
    }
}

struct PlaylistRow: View {
    @EnvironmentObject private var state: AppState
    let playlist: Playlist
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var showDeleteConfirm = false
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(playlist.name).font(.system(size: 18, weight: .bold))
                HStack { Image(systemName: "tv").foregroundStyle(state.accent); Text("\(playlist.channelCount) \(state.localized("频道"))").foregroundStyle(state.accent); Text("·").foregroundStyle(.secondary); Text(playlist.kind.rawValue).foregroundStyle(.secondary) }.font(.subheadline)
            }
            Spacer()
            Button(action: onEdit) { Image(systemName: "pencil").foregroundStyle(state.accent).frame(width: 44, height: 44).background(state.accent.opacity(0.1), in: Circle()) }.buttonStyle(.plain)
            Button { showDeleteConfirm = true } label: { Image(systemName: "trash").foregroundStyle(.red).frame(width: 44, height: 44).background(Color.red.opacity(0.1), in: Circle()) }.buttonStyle(.plain)
                .alert(state.localized("删除播放列表"), isPresented: $showDeleteConfirm) {
                    Button(state.localized("删除"), role: .destructive) { onDelete() }
                    Button(state.localized("关闭"), role: .cancel) {}
                } message: {
                    Text("\(state.localized("确定删除播放列表吗？该操作无法撤销。")) “\(playlist.name)”")
                }
        }.padding(.horizontal, 18).padding(.vertical, 17).background(Color.card, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(state.accent.opacity(0.42), lineWidth: 1)).padding(.horizontal, 22)
    }
}

struct CircleButton: View { let icon: String; var body: some View { Image(systemName: icon).font(.title3).foregroundStyle(.primary).frame(width: 48, height: 48).background(Color.panel, in: Circle()).overlay(Circle().stroke(.secondary.opacity(0.3))) } }
extension Color {
    /// Dynamic color: Light/Dark themes pin the value; System follows the
    /// device appearance. Previously every branch only checked for "Light"
    /// and fell back to dark, so System + light device showed dark cards
    /// under black (system) text.
    private static func dynamicColor(light: Color, dark: Color) -> Color {
        let theme = UserDefaults.standard.string(forKey: "nanostream.theme") ?? "System"
        if theme == "Light" { return light }
        if theme == "Dark" { return dark }
        return Color(UIColor { trait in trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }

    static var appBackground: Color {
        dynamicColor(light: Color(red: 0.95, green: 0.96, blue: 0.98), dark: Color(red: 0.015, green: 0.035, blue: 0.055))
    }
    static var panel: Color {
        dynamicColor(light: .white, dark: Color(red: 0.11, green: 0.13, blue: 0.17))
    }
    static var card: Color {
        dynamicColor(light: Color(red: 0.92, green: 0.93, blue: 0.95), dark: Color(red: 0.12, green: 0.15, blue: 0.16))
    }
    static var cardInner: Color {
        dynamicColor(light: Color(red: 0.86, green: 0.88, blue: 0.91), dark: Color(red: 0.055, green: 0.07, blue: 0.08))
    }
}
