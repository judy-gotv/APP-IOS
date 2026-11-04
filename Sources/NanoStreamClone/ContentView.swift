import SwiftUI
import AVKit
import AVFoundation
import CoreMedia
import KSPlayer
// Dev round 10 (D-03): UIKit does not exist on macOS; the views
// that need it are isolated with #if os() guards below, so the
// import itself must be conditional too. iOS/tvOS/visionOS keep
// the existing behaviour unchanged.
#if canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers

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
                case .home: HomeView(showGroups: $homeShowGroups, showAddPlaylist: $showAddPlaylist)
                case .favorites: FavoritesView()
                case .playlists: PlaylistsView(showAdd: $showAddPlaylist)
                case .guide: EPGOverviewView()
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
    // Dev round 6 (R6-04): guide overview tab, outside the detail
    // page's program tab: current + next programme per channel.
    case home = "主页", favorites = "收藏", playlists = "播放列表", guide = "节目总览", settings = "设置"
    var id: String { rawValue }
    var icon: String {
        switch self { case .home: return "play.rectangle"; case .favorites: return "star"; case .playlists: return "rectangle.stack"; case .guide: return "list.bullet.rectangle.portrait"; case .settings: return "gearshape" }
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
    // Dev round 10 (D-03): iPad idiom adaptation. A regular-width
    // size class (iPad, and iPhone landscape on larger phones) gets
    // one extra grid column so the large screen is not just a
    // stretched phone grid; list mode is untouched.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var effectiveColumns: Int {
        let base = state.gridLayout.columns
        if horizontalSizeClass == .regular { return min(base + 1, 5) }
        return base
    }
    @State private var selectedDetail: Channel?
    // Dev round 6 (R6-05): focus drives the history chips below the
    // search field; history is recorded on submit only.
    @FocusState private var searchFocused: Bool
    // Round-8 fix (C03): proxyAuthWarning is computed from the static
    // proxyMigrationFailed flag, which is not @Published, so a
    // migration failure during a successful background refresh left
    // the home page stale until some other state change re-rendered
    // it. Bumping this counter on the notification forces a re-render.
    @State private var proxyMigrationTick = 0
    @Binding var showGroups: Bool
    // Dev round 4 (R4-11): the empty-state "add playlist" button
    // needs ContentView's add sheet, which lives above this view.
    @Binding var showAddPlaylist: Bool
    // Dev round 4 (R4-09): history page sheet state.
    @State private var showHistory = false

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
                            ForEach(state.homeGroups, id: \.self) { group in
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
                        .focused($searchFocused)
                        .onSubmit { state.recordSearchHistory(state.searchText) }
                }.padding(.horizontal, 14).frame(height: 48).background(Color.panel, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 22).padding(.top, 12)
                // Dev round 6 (R6-05): search history chips, shown
                // only while the field is focused and empty. A tap
                // fills the field (it does not re-record: the term is
                // already in history). No separate results page: the
                // home grid itself is the result surface.
                if searchFocused, state.searchText.isEmpty, !state.searchHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(state.localized("搜索历史")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(state.localized("清除搜索历史")) { state.clearSearchHistory() }.font(.caption).foregroundStyle(.red)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(state.searchHistory, id: \.self) { term in
                                    Button(term) { state.searchText = term }
                                        .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(Color.card, in: Capsule())
                                }
                            }
                        }
                    }.padding(.horizontal, 22).padding(.top, 10)
                }
                // Dev round 8 (R8-08): tag filter chips, shown only
                // when the user has assigned at least one tag. "All
                // tags" clears the filter; a chip narrows the grid to
                // channels carrying that tag (on top of the group and
                // search filters). Tags come only from the user's own
                // assignments, never from source data.
                if !state.allTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button(state.localized("全部标签")) { state.selectedTag = nil }
                                .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6)
                                .background(state.selectedTag == nil ? state.accent.opacity(0.25) : Color.card, in: Capsule())
                                .foregroundStyle(state.selectedTag == nil ? state.accent : .primary)
                            ForEach(state.allTags, id: \.self) { tag in
                                Button(tag) { state.selectedTag = tag }
                                    .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(state.selectedTag == tag ? state.accent.opacity(0.25) : Color.card, in: Capsule())
                                    .foregroundStyle(state.selectedTag == tag ? state.accent : .primary)
                            }
                        }
                    }.padding(.horizontal, 22).padding(.top, 10)
                }
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(GridLayout.allCases) { layout in
                            Button { state.setGridLayout(layout) } label: {
                                Label(state.localized(layout.rawValue), systemImage: state.gridLayout == layout ? "checkmark" : "square.grid.2x2")
                            }
                        }
                    } label: {
                        Image(systemName: state.gridLayout == .twoColumns ? "square.grid.2x2" : state.gridLayout == .threeColumns ? "square.grid.3x3" : state.gridLayout == .list ? "list.bullet" : "square.grid.4x3.fill")
                            .foregroundStyle(state.accent).frame(width: 46, height: 40).background(Color.panel, in: RoundedRectangle(cornerRadius: 20))
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 22).padding(.top, 16)
                if state.stateRestoreFailed {
                    Text(state.localized("旧播放列表数据损坏，已备份，无法自动恢复。")).font(.caption).foregroundStyle(.red).padding(.horizontal, 22).padding(.top, 12)
                }
                // Dev round 4 (R4-12): loading / refreshing / failed
                // are three distinct states. A failure renders only
                // when neither loading flag is set, so a stale error
                // never sits next to a spinner for a new load; the
                // error text itself already comes from localizedError
                // (timeout/offline/host mapping, same as the
                // subscription-load path), so a background-refresh
                // failure shows its network/timeout wording here.
                if let error = state.playlistError, !state.isLoadingPlaylist, !state.isRefreshingPlaylist {
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
                if state.isLoadingPlaylist && state.homeChannels.isEmpty {
                    // Dev round 4 (R4-12): initial load is labelled,
                    // not a bare spinner.
                    VStack(spacing: 8) {
                        ProgressView().tint(state.accent)
                        Text(state.localized("正在加载新订阅…")).font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 42)
                } else if state.homeChannels.isEmpty {
                    EmptyHomeState(onAddPlaylist: { showAddPlaylist = true })
                } else {
                    // Dev round 4 (R4-12): background refresh keeps
                    // the list and shows its own labelled spinner,
                    // distinct from the initial-load state above.
                    if state.isRefreshingPlaylist {
                        VStack(spacing: 4) {
                            ProgressView().tint(state.accent)
                            Text(state.localized("正在刷新…")).font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }
                    RecentRail(onShowAll: { showHistory = true }) { channel in state.play(channel); selectedDetail = channel }.padding(.top, 23)
                    if state.visibleChannels.isEmpty {
                        VStack(spacing: 8) {
                            Text(state.localized("暂无频道")).font(.title3.bold())
                            Text(state.localized("当前分组或搜索没有匹配的频道。")).font(.subheadline).foregroundStyle(.secondary)
                            Button(state.localized("清除筛选")) { state.selectedGroup = GroupID.all; state.searchText = ""; state.selectedTag = nil }.buttonStyle(.bordered).tint(state.accent)
                        }.padding(.top, 28).padding(.horizontal, 28)
                    }
                    // Dev round 2 (R2-16): row list mode, one row per
                    // channel with the same row information as the
                    // detail list (see ChannelRow).
                    if state.gridLayout == .list {
                        LazyVStack(spacing: 10) {
                            ForEach(state.visibleChannels) { channel in ChannelRow(channel: channel) { state.play(channel); selectedDetail = channel } }
                        }.padding(.horizontal, 22).padding(.top, 17).padding(.bottom, 110)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: effectiveColumns), spacing: 12) {
                            ForEach(state.visibleChannels) { channel in ChannelCard(channel: channel, compact: state.gridLayout == .fourColumns) { state.play(channel); selectedDetail = channel } }
                        }.padding(.horizontal, 22).padding(.top, 17).padding(.bottom, 110)
                    }
                }
            }
        }
        .fullScreenCover(item: $selectedDetail) { channel in ChannelDetailView(channel: channel) }
        .sheet(isPresented: $showHistory) { HistoryView() }
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
    // Dev round 4 (R4-09): opens the independent history page.
    // Nil for any future caller that wants the rail without it.
    var onShowAll: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(state.localized("最近播放")).font(.system(size: 20, weight: .bold)); Spacer(); if let onShowAll { Button(state.localized("查看全部")) { onShowAll() }.font(.subheadline) }; Image(systemName: "clock.fill").foregroundStyle(state.accent) }.padding(.horizontal, 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    // Dev round 2 (R2-17): history entries now carry a
                    // watch time; entries without one (migrated from the
                    // old plain-id history) render no time, never a
                    // fabricated one.
                    ForEach(state.recent, id: \.channelID) { entry in
                        if let channel = state.channel(for: entry.channelID) {
                            Button { onOpen(channel) } label: {
                                VStack(spacing: 7) {
                                    ZStack { RoundedRectangle(cornerRadius: 12).fill(Color.cardInner); if let logoURL = channel.logoURL { AsyncImage(url: logoURL) { phase in if let image = phase.image { image.resizable().scaledToFit().padding(18) } else { Text(channel.name.prefix(1).uppercased()).font(.system(size: 30, weight: .heavy)) } } } else { Text(channel.name.prefix(1).uppercased()).font(.system(size: 30, weight: .heavy)) } }.frame(width: 112, height: 90)
                                    Text(channel.name).font(.caption).lineLimit(1).frame(width: 112, alignment: .leading)
                                    if let watchedAt = entry.watchedAt { Text(Self.timeString(for: watchedAt)).font(.caption2).foregroundStyle(.secondary).frame(width: 112, alignment: .leading) }
                                }.padding(9).background(Color.card, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(state.accent.opacity(0.25), lineWidth: 1)).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    if state.recent.isEmpty { Text(state.localized("暂无播放记录")).foregroundStyle(.secondary).padding(.horizontal, 22) }
                }.padding(.horizontal, 22)
            }
        }
    }

    /// Dev round 2 (R2-17): today renders as HH:mm, older entries as
    /// MM-dd HH:mm. No relative ("x hours ago") text is invented.
    /// Dev round 4 (R4-09): no longer private so HistoryView shares
    /// the same rule instead of duplicating the formatter.
    static func timeString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

@MainActor
private final class PreviewSessionPool {
    static let shared = PreviewSessionPool()
    /// Posted when a slot is fully freed, so a pool-full card can retry
    /// without the user having to scroll it off-screen and back.
    static let didReleaseNotification = Notification.Name("NanoStreamClone.PreviewPoolDidRelease")
    // Dev round 6 (R6-07): the limit is no longer hardcoded — it reads
    // the adjustable setting live (unset key reads 0, meaning the
    // default 4), clamped 1...8 like the settings Stepper.
    private var limit: Int { AppState.clampedPreviewLimit(UserDefaults.standard.integer(forKey: "nanostream.previewLimit")) }
    // Reference-counted: two cards for the same channel id (duplicate
    // entries) must not release each other's slot.
    private var active: [String: Int] = [:]

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
    // Dev round 2 (R2-09): retained proxy loader delegate for the
    // preview item (resourceLoader holds weakly); invalidated in stop().
    private var resourceLoaderDelegate: PlaybackResourceLoaderDelegate?
    // Dev round 1 (DEV-LAT): three-state latency (see LatencyDisplay).
    @Published private(set) var latencyDisplay: LatencyDisplay = .sampling
    // Dev round 4 (R4-08): failure of a preview stream, classified
    // through the same PlaybackFailure mapping as the main players.
    // Nil while the preview is healthy or has not started.
    @Published private(set) var previewFailure: (kind: PlaybackFailureKind, isTimeout: Bool)?
    private var timer: Timer?
    private let url: URL?

    init(url: URL?) {
        self.url = url
        self.player = nil
        super.init()
    }

    func start() {
        // Dev round 4 (R4-08): a retry clears the previous failure so
        // a recovered stream does not keep showing stale failure text.
        previewFailure = nil
        // Round-3 fix (A03): the player is created here, not in init, so
        // a card that never wins a pool slot never builds an AVPlayer +
        // AVPlayerItem at all. start() is only called after acquire().
        if player == nil, let url {
            // Dev round 2 (R2-09/R2-10): card previews play through
            // the same proxy/UA path as the main system player.
            // Subtitle size is not applied to previews: they render no
            // subtitle UI (muted live tiles), so the slider has no
            // visible target there.
            let built = PlaybackItemFactory.makeItem(url: url)
            resourceLoaderDelegate = built.loaderDelegate
            let item = built.item
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
        resourceLoaderDelegate?.invalidate()
        resourceLoaderDelegate = nil
        // Release the player so a later re-acquire rebuilds it (and a
        // card that was stopped by a scene change does not keep a dead
        // item around).
        player = nil
        latencyDisplay = .sampling
        previewFailure = nil
    }

    private func sampleLatency() {
        // Dev round 4 (R4-08): a failed preview item used to leave a
        // silent black tile; surface the item's error through the
        // same PlaybackFailure mapping as the main players, checked
        // before the playing guard (a failed item is not playing).
        if let item = player?.currentItem, item.status == .failed {
            let error = item.error
            previewFailure = (PlaybackFailure.classify(error), (error as? URLError)?.code == .timedOut)
            return
        }
        // Latency is only meaningful while actually playing a live stream;
        // a paused preview previously showed a growing fake latency.
        // Dev round 1 (DEV-LAT): a non-playing preview keeps its last
        // display instead of collapsing to "unavailable"; a playing one
        // that yields no window reports unsupported, not sampling.
        guard let player, player.timeControlStatus == .playing,
              let item = player.currentItem,
              let range = item.seekableTimeRanges.last?.timeRangeValue,
              range.isValid,
              item.currentTime().isNumeric else {
            if player?.timeControlStatus == .playing { latencyDisplay = .unsupported }
            return
        }
        let current = item.currentTime()
        let seconds = range.end.seconds - current.seconds
        latencyDisplay = seconds >= 0 && seconds.isFinite ? .milliseconds(Int((seconds * 1000).rounded())) : .unsupported
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
    // Dev round 4 (R4-10): reports the preview's sampled latency to
    // the owning card so the card itself can show a real sample.
    // Nil for the detail rows, which keep the in-preview badge only.
    var onLatencyChange: ((LatencyDisplay) -> Void)? = nil
    @StateObject private var model: PreviewPlayerModel
    @State private var acquired = false
    // Dev round 6 (R6-08): true once the layer reports its first
    // frame; the logo placeholder underneath hides at that point.
    @State private var firstFrameReady = false

    init(channel: Channel, onLatencyChange: ((LatencyDisplay) -> Void)? = nil) {
        self.channel = channel
        self.onLatencyChange = onLatencyChange
        _model = StateObject(wrappedValue: PreviewPlayerModel(url: channel.streamURL))
    }

    // Dev round 6 (R6-08): placeholder shown until the first frame:
    // the channel logo, or its initial letter — never a fake
    // screenshot. It sits under the player layer.
    private var previewPlaceholder: some View {
        ZStack {
            Color.black
            if let logoURL = channel.logoURL {
                AsyncImage(url: logoURL) { phase in if let image = phase.image { image.resizable().scaledToFit().padding(18) } else { Text(channel.name.prefix(1).uppercased()).font(.system(size: 30, weight: .heavy)) } }
            } else { Text(channel.name.prefix(1).uppercased()).font(.system(size: 30, weight: .heavy)) }
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if acquired {
                ZStack {
                    if !firstFrameReady { previewPlaceholder }
                    PreviewPlayerLayerView(player: model.player, onReadyChange: { firstFrameReady = $0 })
                }
                // Dev round 4 (R4-08): a stream that fails after
                // winning a slot used to render a silent black tile.
                // The classified failure text replaces the tile, with
                // a tap to retry; the latency badge hides while failed.
                if let failure = model.previewFailure {
                    Color.black
                    VStack(spacing: 4) {
                        Text(state.localized(PlaybackFailure.textKey(for: failure.kind, isTimeout: failure.isTimeout))).font(.caption2).foregroundStyle(.white).multilineTextAlignment(.center)
                        Text(state.localized("点按重试")).font(.caption2).foregroundStyle(.secondary)
                    }.padding(8)
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded { model.start() })
                } else if state.showLatency { StreamLatencyBadge(display: model.latencyDisplay) }
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
        .onChange(of: model.latencyDisplay) { display in onLatencyChange?(display) }
        .onAppear {
            // Round-2 fix: onAppear can fire twice without an intervening
            // onDisappear, and the pool is reference-counted, so a second
            // acquire leaked a slot that the single release never freed.
            guard !acquired else { return }
            // Dev round 6 (R6-08): a re-appearing card starts from the
            // placeholder again, not from a stale ready flag.
            firstFrameReady = false
            acquired = PreviewSessionPool.shared.acquire(channel.id)
            if acquired { model.start() }
        }
        .onDisappear {
            if acquired { model.stop(); PreviewSessionPool.shared.release(channel.id); acquired = false; firstFrameReady = false }
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

// Dev round 10 (D-03): UIViewRepresentable does not exist on
// macOS; the macOS twin below is an NSViewRepresentable with the
// same call shape, so preview call sites stay unchanged.
#if os(macOS)
private struct PreviewPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer?
    var onReadyChange: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onReadyChange: onReadyChange) }
    func makeNSView(context: Context) -> PreviewLayerHostView {
        let view = PreviewLayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.observe(layer: view.playerLayer)
        return view
    }
    func updateNSView(_ view: PreviewLayerHostView, context: Context) {
        view.playerLayer.player = player
        context.coordinator.onReadyChange = onReadyChange
    }

    final class Coordinator {
        var onReadyChange: ((Bool) -> Void)?
        private var observation: NSKeyValueObservation?
        init(onReadyChange: ((Bool) -> Void)?) { self.onReadyChange = onReadyChange }
        func observe(layer: AVPlayerLayer) {
            observation?.invalidate()
            observation = layer.observe(\.readyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                DispatchQueue.main.async { self?.onReadyChange?(ready) }
            }
        }
        deinit { observation?.invalidate() }
    }
}

private final class PreviewLayerHostView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
#else
private struct PreviewPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?
    // Dev round 6 (R6-08): reports first-frame readiness so the
    // placeholder underneath can hide exactly when video appears.
    // readyForDisplay is KVO-observable on AVPlayerLayer.
    var onReadyChange: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onReadyChange: onReadyChange) }
    func makeUIView(context: Context) -> PreviewLayerHostView {
        let view = PreviewLayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.observe(layer: view.playerLayer)
        return view
    }
    func updateUIView(_ view: PreviewLayerHostView, context: Context) {
        view.playerLayer.player = player
        context.coordinator.onReadyChange = onReadyChange
    }

    final class Coordinator {
        var onReadyChange: ((Bool) -> Void)?
        private var observation: NSKeyValueObservation?
        init(onReadyChange: ((Bool) -> Void)?) { self.onReadyChange = onReadyChange }
        func observe(layer: AVPlayerLayer) {
            observation?.invalidate()
            observation = layer.observe(\.readyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                DispatchQueue.main.async { self?.onReadyChange?(ready) }
            }
        }
        deinit { observation?.invalidate() }
    }
}

private final class PreviewLayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
#endif

/// Dev round 1 (DEV-LAT): latency is three-state, not "value or
/// unavailable". `.sampling` = no sample yet (player starting);
/// `.unsupported` = the stream genuinely yields no latency while
/// playing; `.milliseconds` = a real sample. The old badge collapsed
/// the first two into "延迟不可用", so a healthy starting stream
/// looked broken for its whole session.
enum LatencyDisplay: Equatable {
    case sampling
    case unsupported
    case milliseconds(Int)
}

private struct StreamLatencyBadge: View {
    @EnvironmentObject private var state: AppState
    let display: LatencyDisplay
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.black.opacity(0.72), in: Capsule())
            .padding(7)
    }

    private var text: String {
        switch display {
        case .sampling: return state.localized("延迟采样中")
        case .unsupported: return state.localized("延迟不可用")
        case .milliseconds(let ms): return "\(ms) ms"
        }
    }
}

/// Dev round 1 (DEV-ERRMAP/DEV-AVERR): playback failure
/// classification. It mirrors AppState.localizedError's URLError
/// branches (timeout / offline / cannot reach host) so playback
/// failures use the same wording as subscription/EPG failures.
/// Anything else is generic: player callbacks here carry no
/// decode-specific cause, so a decode label would be a guess —
/// generic + retry is the honest fallback.
enum PlaybackFailureKind {
    case timeout
    case offline
    case unreachable
    case generic
}

private enum PlaybackFailure {
    static func classify(_ error: Error?) -> PlaybackFailureKind {
        guard let urlError = error as? URLError else { return .generic }
        switch urlError.code {
        case .timedOut: return .timeout
        case .notConnectedToInternet: return .offline
        case .cannotFindHost, .cannotConnectToHost: return .unreachable
        default: return .generic
        }
    }

    static func textKey(for kind: PlaybackFailureKind, isTimeout: Bool) -> String {
        if isTimeout { return "播放超时，请检查网络后重试。" }
        switch kind {
        case .timeout: return "网络超时，请检查网络后重试。"
        case .offline: return "无网络连接。"
        case .unreachable: return "无法连接到服务器。"
        case .generic: return "播放失败"
        }
    }
}

private func formatPlaybackTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let total = Int(seconds)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
    return String(format: "%02d:%02d", minutes, secs)
}

/// Dev round 1 (DEV-PROGRESS): VOD/replay progress only. Live
/// streams never render a fake progress bar; callers show LIVE.
private struct PlaybackProgressBar: View {
    let current: Double
    let duration: Double
    let onSeek: (Double) -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text(formatPlaybackTime(current)).font(.caption2.monospacedDigit()).foregroundStyle(.white)
            Slider(value: Binding(get: { duration > 0 ? min(max(current / duration, 0), 1) : 0 }, set: { onSeek($0 * duration) }))
                .tint(.white)
            Text(formatPlaybackTime(duration)).font(.caption2.monospacedDigit()).foregroundStyle(.white)
        }
    }
}

/// Dev round 1 (DEV-NOURL): line-up switch. `lines` are the
/// alternate URLs (the failed/primary line is not offered again);
/// the active one is checkmarked. With no lines there is no menu
/// at all (no fake choice); with exactly one line the caller passes
/// alwaysShow so the single fallback line is still reachable.
private struct SourceSwitchMenu: View {
    @EnvironmentObject private var state: AppState
    let lines: [URL]
    let active: URL?
    var alwaysShow = false
    let onSelect: (URL) -> Void
    var body: some View {
        if !lines.isEmpty && (lines.count > 1 || alwaysShow) {
            Menu {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, url in
                    Button { onSelect(url) } label: {
                        Label("\(state.localized("线路")) \(index + 1)", systemImage: url == active ? "checkmark" : "arrow.left.arrow.right")
                    }
                }
            } label: {
                Label(state.localized("换源"), systemImage: "arrow.left.arrow.right").font(.subheadline)
            }.buttonStyle(.bordered).tint(state.accent)
        }
    }
}

private enum DetailFormatters {
    static let hourMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

struct ChannelCard: View {
    @EnvironmentObject private var state: AppState
    let channel: Channel
    var compact = false
    let onOpen: () -> Void
    // Dev round 4 (R4-10): the card's own preview sample, reported by
    // LivePreviewView. Stays .sampling when previews are off or the
    // pool is full, so the card badge renders nothing in those cases.
    @State private var previewLatency: LatencyDisplay = .sampling
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
                            LivePreviewView(channel: channel, onLatencyChange: { previewLatency = $0 }).id(channel.id)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else if let logoURL = channel.logoURL {
                            AsyncImage(url: logoURL) { phase in
                                if let image = phase.image { image.resizable().scaledToFit().padding(18) } else { fallbackLogo }
                            }
                        } else { fallbackLogo }
                        if channel.isLive { Text("● LIVE").font(.system(size: 9, weight: .bold)).foregroundStyle(state.accent).padding(.horizontal, 7).padding(.vertical, 4).background(state.accent.opacity(0.2), in: Capsule()).padding(9) }
                    }
                    HStack(spacing: 6) {
                        Text(channel.name)
                            .font(.system(size: compact ? 12 : 14, weight: .semibold))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: compact ? 42 : 20, alignment: .top)
                        // Dev round 4 (R4-06): resolution badge on the
                        // card. Dev round 6 (R6-09): the source
                        // attribute still wins, but a real probe result
                        // fills the gap when the source gave none;
                        // empty when neither exists, never guessed.
                        if !state.displayQuality(for: channel).isEmpty { Text(state.displayQuality(for: channel)).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1).background(state.accent.opacity(0.2), in: Capsule()) }
                    }
                    Text(state.localizedGroup(channel.group)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    // Dev round 4 (R4-10): card latency from the
                    // card's own preview sample (see previewLatency).
                    // Only a real sample renders; sampling or
                    // unsupported renders nothing, never a value.
                    if state.showLatency, case .milliseconds(let ms) = previewLatency { Text("\(ms) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    // Dev round 2 (R2-15): current programme on the card
                    // (same data as the detail row, different surface).
                    // Empty when the guide has none — never fabricated.
                    if let program = state.currentProgram(for: channel) { Text(program.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
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
                Image(systemName: state.isFavorite(channel) ? "star.fill" : "star").foregroundStyle(.primary).frame(width: 36, height: 36)
            }.buttonStyle(.plain).padding(10)
        }
    }

    private var fallbackLogo: some View {
        Text(channel.name.localizedCaseInsensitiveContains("FOX") ? "FOX" : channel.name.prefix(1).uppercased())
            .font(.system(size: channel.name.localizedCaseInsensitiveContains("FOX") ? 45 : 30, weight: .heavy))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Dev round 2 (R2-16): one row per channel for the home list mode.
/// Row information mirrors the detail list: logo, name, group, current
/// programme and quality badge; programme/badge render nothing when
/// their data is absent (no guessed values).
struct ChannelRow: View {
    @EnvironmentObject private var state: AppState
    let channel: Channel
    let onOpen: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black).frame(width: 64, height: 48)
                if let logoURL = channel.logoURL {
                    AsyncImage(url: logoURL) { phase in if let image = phase.image { image.resizable().scaledToFit().padding(6) } else { Image(systemName: "tv").foregroundStyle(.secondary) } }
                } else { Image(systemName: "tv").foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(channel.name).font(.headline).lineLimit(1)
                    // Dev round 6 (R6-09): same source-first, probe-
                    // fallback rule as the card badge.
                    if !state.displayQuality(for: channel).isEmpty { Text(state.displayQuality(for: channel)).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1).background(state.accent.opacity(0.2), in: Capsule()) }
                }
                Text(state.localizedGroup(channel.group)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let program = state.currentProgram(for: channel) { Text(program.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Button { state.toggleFavorite(channel) } label: {
                Image(systemName: state.isFavorite(channel) ? "star.fill" : "star").foregroundStyle(.primary).frame(width: 36, height: 36)
            }.buttonStyle(.plain)
        }.padding(10).background(Color.card, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(state.accent.opacity(0.25), lineWidth: 1)).contentShape(Rectangle()).onTapGesture { onOpen() }
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
    // Dev round 1: detail-page playback state. engineOverride nil means
    // "follow the global setting" until the user picks an engine here;
    // replayURL/replayProgram track a catchup session (DEV-REPLAY);
    // sourceOverride tracks a picked alternate line (DEV-NOURL);
    // playbackPosition is the live position report from the player
    // (VOD seeks only); engineSwitchSeek is the position to resume
    // from after an engine switch (VOD only, live passes 0).
    @State private var engineOverride: PreferredPlayer?
    @State private var engineSwitchSeek: Double = 0
    @State private var replayURL: URL?
    @State private var replayProgram: EPGProgram?
    @State private var replayAlertMessage = ""
    @State private var showReplayAlert = false
    @State private var sourceOverride: URL?
    // Dev round 8 (R8-08): draft text for the tag editor row below
    // the player; committed on tap, never on keystroke.
    @State private var newTag = ""
    @State private var playbackPosition: Double = 0
    // Dev round 2 (R2-17): total duration reported by the player
    // (VOD only; live streams report 0 and never get a progress).
    @State private var playbackDuration: Double = 0
    // Round-2 fix: set when the user switches subscriptions from the
    // detail page and the new subscription has no cached channels yet.
    // While set, the old subscription's player is NOT rendered (so it
    // stops instead of silently continuing), and the first channel of the
    // newly loaded subscription is picked up via onChange below.
    @State private var awaitingSubscriptionLoad = false
    // Dev round 10 (D-01): lab preselection result + the key it was
    // resolved for (the loop guard explained at the .task call site).
    @State private var preselectedURL: URL?
    @State private var preselectedForKey: String?
    // Dev round 10 (D-06): DLNA cast session + device sheet flag.
    // The cast state lives here so swapping the player for the
    // casting placeholder stops local playback for real.
    @StateObject private var dlnaCast = DLNACastState()
    @State private var showDLNASheet = false

    init(channel: Channel) {
        self.channel = channel
        _activeChannel = State(initialValue: channel)
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3).frame(width: 44, height: 44).background(Color.panel, in: Circle()) }.buttonStyle(.plain)
                    // Dev round 1 (DEV-HEADERINFO): logo, source-provided
                    // quality badge and channel number (tvg-chno). The
                    // number shows only when the source provided one.
                    if let logoURL = activeChannel.logoURL {
                        AsyncImage(url: logoURL) { phase in if let image = phase.image { image.resizable().scaledToFit() } else { Image(systemName: "tv").foregroundStyle(.secondary) } }.frame(width: 30, height: 30)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(activeChannel.name).font(.headline).lineLimit(1)
                            if !activeChannel.quality.isEmpty { Text(activeChannel.quality).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(state.accent.opacity(0.2), in: Capsule()) }
                            if let number = activeChannel.channelNumber { Text(number).font(.caption).foregroundStyle(.secondary) }
                        }
                        // Dev round 1 (DEV-HEADERPROG): current programme
                        // + window below the title; nothing renders
                        // without programme data (no fake copy).
                        if let program = currentProgram {
                            Text("\(program.title) · \(DetailFormatters.hourMinute.string(from: program.start))–\(DetailFormatters.hourMinute.string(from: program.end))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    // Dev round 1 (DEV-CHNAV): prev/next step through the
                    // filtered list in subscription order (see
                    // navigationChannels); pinning never changes it.
                    Button { if let prev = previousChannel { switchTo(prev) } } label: { Image(systemName: "chevron.up").font(.title3).frame(width: 44, height: 44) }.buttonStyle(.plain).disabled(previousChannel == nil).accessibilityLabel(state.localized("上一频道"))
                    Button { if let next = nextChannel { switchTo(next) } } label: { Image(systemName: "chevron.down").font(.title3).frame(width: 44, height: 44) }.buttonStyle(.plain).disabled(nextChannel == nil).accessibilityLabel(state.localized("下一频道"))
                    // Dev round 1 (DEV-ENGINESWITCH): in-playback engine
                    // switch. Auto means "try AVPlayer, fall back to
                    // KSPlayer on failure" (see the settings caption);
                    // switching rebuilds the player for the same channel.
                    Menu {
                        Button { switchEngine(.auto) } label: { Label(state.localized("自动"), systemImage: effectiveEngine == .auto ? "checkmark" : "wand.and.stars") }
                        Button { switchEngine(.ksPlayer) } label: { Label("KSPlayer", systemImage: effectiveEngine == .ksPlayer ? "checkmark" : "play.rectangle") }
                        Button { switchEngine(.avPlayer) } label: { Label(state.localized("系统播放器"), systemImage: effectiveEngine == .avPlayer ? "checkmark" : "apple.logo") }
                    } label: { Image(systemName: "arrow.triangle.2.circlepath").font(.title3).frame(width: 44, height: 44) }.buttonStyle(.plain)
                    Button { showInfo = true } label: { Image(systemName: "info.circle").font(.title3).frame(width: 44, height: 44) }.buttonStyle(.plain)
                    // Dev round 10 (D-06): DLNA cast, iOS only (the
                    // platform-exclusive capability rule). The sheet
                    // lists only really discovered devices.
                    #if os(iOS)
                    Button { showDLNASheet = true } label: { Image(systemName: "tv.and.mediabox").font(.title3).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel(state.localized("投屏"))
                        .sheet(isPresented: $showDLNASheet) {
                            DLNADeviceSheet(cast: dlnaCast, url: playbackURL)
                        }
                    #endif
                    Button { state.toggleFavorite(activeChannel) } label: { Image(systemName: state.isFavorite(activeChannel) ? "star.fill" : "star").font(.title3).frame(width: 44, height: 44) }.buttonStyle(.plain)
                }.padding(.horizontal, 18).padding(.top, 8)
                if let program = replayProgram {
                    Text("\(state.localized("正在回看")) · \(program.title)").font(.caption).foregroundStyle(state.accent).padding(.horizontal, 18).padding(.top, 4)
                }
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
                    } else if dlnaCast.isCasting {
                        // Dev round 10 (D-06): while casting, the local
                        // player view is gone, so local playback stops
                        // for real. Disconnect restores PlayerSurface
                        // below (and local playback) on the next render.
                        Color.black
                        VStack(spacing: 10) {
                            Text(state.localized("正在投屏")).font(.headline)
                            if let device = dlnaCast.device {
                                Text(device.friendlyName).font(.caption).foregroundStyle(.secondary)
                            }
                            Button(state.localized("断开投屏")) { Task { await dlnaCast.disconnect() } }.buttonStyle(.bordered).tint(state.accent)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let url = effectivePlaybackURL {
                        ZStack(alignment: .bottom) {
                            PlayerSurface(url: url, title: activeChannel.name, engine: playbackEngine, bufferMilliseconds: effectiveBufferMilliseconds, allowsPictureInPicture: state.pictureInPicture, hardwareAcceleration: state.hardwareAcceleration, automaticAudioSelection: state.automaticAudioSelection, showLatency: state.showLatency, streamInfo: $streamInfo, deinterlace: state.deinterlace, metalRendering: state.labMetalRendering, isLive: isLiveStream, playbackPosition: $playbackPosition, playbackDuration: $playbackDuration, initialPosition: isLiveStream ? 0 : engineSwitchSeek, alternateURLs: activeChannel.alternateURLs, activeSourceURL: sourceOverride ?? activeChannel.streamURL, onSourceSelect: { sourceOverride = $0; replayURL = nil; replayProgram = nil; engineSwitchSeek = 0; playbackPosition = 0; playbackDuration = 0 }, onVideoSize: { size in
                                // Dev round 6 (R6-09): record the real
                                // frame size against the channel now
                                // playing; the player rebuilds on every
                                // channel switch (playerID), so the id
                                // captured here matches the stream.
                                state.recordProbedQuality(channelID: activeChannel.id, size: size)
                            }).id(playerID)
                                // Dev round 10 (D-01): multi-bitrate
                                // preselection. The guard below (same
                                // key => return) is load-bearing: the
                                // playerID includes the resolved URL,
                                // so resolving recreates this view and
                                // restarts the task; without the guard
                                // it would clear the result and loop.
                                .task(id: preselectKey) {
                                    guard preselectedForKey != preselectKey else { return }
                                    preselectedForKey = preselectKey
                                    preselectedURL = nil
                                    guard state.labHLSVariantPreselect, isLiveStream,
                                          playbackEngine == .auto || playbackEngine == .ksPlayer,
                                          let base = playbackURL,
                                          base.scheme?.lowercased() == "http" || base.scheme?.lowercased() == "https" else { return }
                                    let variants = await HLSPreselector.variants(of: base)
                                    guard variants.count > 1 else { return }
                                    preselectedURL = HLSPreselector.pick(from: variants, globalCapBitsPerSecond: state.globalBitrateCap)
                                }
                            // Dev round 10 (D-02/D-07): subtitle layers.
                            // Both read the BASE master URL (before
                            // preselection): a preselected variant
                            // playlist carries no #EXT-X-MEDIA groups,
                            // so resolving tracks from it would find
                            // nothing. Nothing renders without a real
                            // track / recognised text.
                            // Dev round 19 (T-02): translation mode
                            // picks the translation input source. In
                            // listen mode the translated listen
                            // captions render INSTEAD of the raw live
                            // subtitles, never stacked on top of them:
                            // when listen translation is active, the
                            // raw overlay is suppressed even if its
                            // switch is on. In subtitle mode the old
                            // behaviour is unchanged.
                            if let base = playbackURL {
                                VStack(spacing: 6) {
                                    Spacer()
                                    if state.subtitleTranslationEnabled {
                                        if state.translationMode == .listen {
                                            ListenTranslatedSubtitleOverlay(masterURL: base)
                                        } else {
                                            TranslatedSubtitleOverlay(masterURL: base, position: playbackPosition)
                                        }
                                    }
                                    if state.liveSubtitleEnabled && !(state.subtitleTranslationEnabled && state.translationMode == .listen) {
                                        LiveSubtitleOverlay(masterURL: base)
                                    }
                                }.padding(.bottom, 44).padding(.horizontal, 12)
                            }
                        }
                    } else {
                        Color.black
                        VStack(spacing: 8) {
                            Text(state.localized("无播放地址")).font(.headline)
                            Text(state.localized("该频道没有可播放地址。")).font(.caption).foregroundStyle(.secondary)
                            // Dev round 1 (DEV-NOURL): retry reloads the
                            // subscription; the source switch offers the
                            // channel's alternate lines when any exist.
                            Button(state.localized("重试")) { state.refreshPlaylists() }.buttonStyle(.bordered).tint(state.accent)
                            SourceSwitchMenu(lines: activeChannel.alternateURLs, active: sourceOverride, alwaysShow: true, onSelect: { sourceOverride = $0; replayURL = nil; replayProgram = nil; engineSwitchSeek = 0; playbackPosition = 0 })
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if activeChannel.isLive { Text("LIVE").font(.caption.bold()).foregroundStyle(state.accent).padding(8) }
                }.aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(state.accent.opacity(0.7), lineWidth: 1)).padding(.horizontal, 16)
                // Dev round 8 (R8-11): say so when the engine was
                // forced (rtsp + a non-KS preference), so the player
                // menu's checkmark never disagrees with what plays.
                if isRTSPForced {
                    Text(state.localized("RTSP 流已自动使用 KSPlayer 播放（系统播放器不支持 RTSP）。")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 6)
                }
                // Dev round 8 (R8-08): user tags for this channel.
                // The map (not the possibly stale activeChannel copy)
                // is the read path, so an edit re-renders immediately.
                // Tags persist by channel id and survive re-parses;
                // import never fabricates them, and an untagged
                // channel simply shows no chips.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(state.localized("标签")).font(.caption).foregroundStyle(.secondary)
                        ForEach(state.tags(for: activeChannel), id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag).font(.caption)
                                Button { state.setTags(state.tags(for: activeChannel).filter { $0 != tag }, for: activeChannel) } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
                            }.padding(.horizontal, 8).padding(.vertical, 4).background(Color.card, in: Capsule())
                        }
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        TextField(state.localized("添加标签"), text: $newTag).textFieldStyle(.plain).padding(8).background(Color.panel, in: RoundedRectangle(cornerRadius: 8))
                        Button(state.localized("添加标签")) {
                            let cleaned = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !cleaned.isEmpty else { return }
                            state.setTags(state.tags(for: activeChannel) + [cleaned], for: activeChannel)
                            newTag = ""
                        }.buttonStyle(.bordered).tint(state.accent).disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(.horizontal, 18).padding(.top, 6)
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
            if engineOverride == nil { engineOverride = state.preferredPlayer }
            if state.selectedChannel?.id != activeChannel.id { state.play(activeChannel) }
        }
        .onDisappear { recordProgress() }
        .onChange(of: state.channels) { newChannels in
            if awaitingSubscriptionLoad, let first = newChannels.first {
                awaitingSubscriptionLoad = false
                recordProgress()
                activeChannel = first
                // Round-3 fix (A15): the shared stream-info line belongs
                // to the previous channel until the new session reports
                // its own; clear it on every switch so the info dialog
                // never briefly shows the old channel's codec/bitrate.
                streamInfo = ""
                replayURL = nil; replayProgram = nil; sourceOverride = nil; playbackPosition = 0; playbackDuration = 0; engineSwitchSeek = 0
                state.play(first)
            }
        }
        .alert(state.localized("编码信息"), isPresented: $showInfo) { Button(state.localized("关闭"), role: .cancel) {} } message: { Text(streamInfo.isEmpty ? state.localized("暂无数据") : streamInfo) }
        .alert(replayAlertMessage, isPresented: $showReplayAlert) { Button(state.localized("关闭"), role: .cancel) {} }
        .onReceive(NotificationCenter.default.publisher(for: M3UParser.proxyMigrationFailedChanged)) { _ in
            proxyMigrationTick += 1
        }
    }

    /// Dev round 1 (DEV-CHNAV): navigation order is the filtered list
    /// in subscription order, WITHOUT the DEV-PIN pinning: pinning is a
    /// display rule for the list, and must not change what "next"
    /// means. detailChannels below is the pinned display order built
    /// on top of this list.
    private var navigationChannels: [Channel] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.channels.filter { item in
            (detailGroup == GroupID.all || item.group == detailGroup) &&
            (query.isEmpty || item.name.localizedCaseInsensitiveContains(query) || item.group.localizedCaseInsensitiveContains(query))
        }
    }

    private var detailChannels: [Channel] {
        // Dev round 1 (DEV-PIN): the playing channel is pinned first;
        // everything else keeps subscription order. When the playing
        // channel is filtered out it is NOT forced back in.
        let filtered = navigationChannels
        guard let current = filtered.first(where: { $0.id == activeChannel.id }) else { return filtered }
        return [current] + filtered.filter { $0.id != activeChannel.id }
    }

    private var previousChannel: Channel? {
        guard let index = navigationChannels.firstIndex(where: { $0.id == activeChannel.id }), index > 0 else { return nil }
        return navigationChannels[index - 1]
    }

    private var nextChannel: Channel? {
        guard let index = navigationChannels.firstIndex(where: { $0.id == activeChannel.id }), index + 1 < navigationChannels.count else { return nil }
        return navigationChannels[index + 1]
    }

    private var effectiveEngine: PreferredPlayer { engineOverride ?? state.preferredPlayer }
    // Dev round 8 (R8-11): the URL the player branch below actually
    // plays (same precedence: replay, picked line, channel address).
    private var playbackURL: URL? { replayURL ?? sourceOverride ?? activeChannel.streamURL }
    // Dev round 8 (R8-11): AVPlayer cannot play rtsp at all, so an
    // rtsp address is forced onto KSPlayer (FFmpeg) instead of being
    // fed to AVPlayer to fail. The forced engine also enters
    // playerID, so a line switch between rtsp and http rebuilds the
    // player instead of reusing the wrong engine's view.
    private var playbackEngine: PreferredPlayer {
        playbackURL?.scheme?.lowercased() == "rtsp" ? .ksPlayer : effectiveEngine
    }
    private var isRTSPForced: Bool {
        playbackURL?.scheme?.lowercased() == "rtsp" && effectiveEngine != .ksPlayer
    }
    private var isLiveStream: Bool { replayURL == nil && activeChannel.isLive }
    // Dev round 10 (D-01): preselection inputs (excluding the result
    // itself) and the effective playback values. The buffer is the
    // lab fast-start value for multicast sources only; every other
    // source keeps the user's buffer setting untouched.
    private var preselectKey: String { "\(activeChannel.id)|\(playbackEngine.rawValue)|\(sourceOverride?.absoluteString ?? "-")|\(replayURL?.absoluteString ?? "-")" }
    private var effectivePlaybackURL: URL? { preselectedURL ?? playbackURL }
    private var effectiveBufferMilliseconds: Double {
        guard let url = playbackURL ?? activeChannel.streamURL else { return state.networkBufferMilliseconds }
        return LabServices.effectiveBufferMilliseconds(base: state.networkBufferMilliseconds, url: url, fastStartEnabled: state.labMulticastFCC)
    }
    // Dev round 2 (R2-07): the effective engine is part of the id,
    // so switching Auto <-> system player rebuilds the player instead
    // of only flipping the menu checkmark (the old id had no engine).
    // Dev round 10 (D-01): the resolved preselect URL is part of the
    // id too, so resolving rebuilds the player onto the variant.
    private var playerID: String { "\(activeChannel.id)|\(playbackEngine.rawValue)|\(sourceOverride?.absoluteString ?? "-")|\(replayURL?.absoluteString ?? "-")|\(preselectedURL?.absoluteString ?? "-")" }

    /// Dev round 1 (DEV-CHNAV/DEV-PIN/DEV-REPLAY): single channel-switch
    /// path for list rows and prev/next. Clears replay/source/position
    /// state so the new channel never inherits the old stream's.
    /// Dev round 2 (R2-17): persist the outgoing channel's VOD
    /// progress (position/duration) on switch and on close. Live
    /// streams and unknown durations record no progress, never a
    /// fabricated fraction.
    private func recordProgress() {
        guard !isLiveStream else { return }
        let progress = playbackDuration > 0 ? playbackPosition / playbackDuration : nil
        state.noteProgress(activeChannel, progress: progress)
    }

    private func switchTo(_ channel: Channel) {
        recordProgress()
        activeChannel = channel
        awaitingSubscriptionLoad = false
        streamInfo = ""
        replayURL = nil
        replayProgram = nil
        sourceOverride = nil
        playbackPosition = 0
        playbackDuration = 0
        engineSwitchSeek = 0
        // Dev round 10 (D-01): a channel switch retires the old
        // preselect result; the .task for the new key resolves fresh.
        preselectedURL = nil
        preselectedForKey = nil
        state.play(channel)
    }

    private func switchEngine(_ engine: PreferredPlayer) {
        // VOD position is captured here so the rebuilt player can resume
        // from it (see initialPosition); live streams pass 0 and resume
        // at the live edge.
        engineSwitchSeek = playbackPosition
        engineOverride = engine
    }

    private var currentProgram: EPGProgram? {
        let now = Date()
        return state.programs(for: activeChannel).first { $0.start <= now && $0.end > now }
    }

    private func rowCurrentProgram(for channel: Channel) -> EPGProgram? {
        let now = Date()
        return state.programs(for: channel).first { $0.start <= now && $0.end > now }
    }

    /// Dev round 1 (DEV-REPLAY): programme-row tap. The current
    /// programme plays live; a past programme plays catchup only when
    /// the source provided a usable template (see Channel.replayURL);
    /// otherwise an explicit prompt — never a fabricated stream. A
    /// future programme prompts instead of playing.
    private func playProgram(_ program: EPGProgram) {
        let now = Date()
        if program.start <= now && now < program.end {
            replayURL = nil; replayProgram = nil; sourceOverride = nil; playbackPosition = 0; playbackDuration = 0; engineSwitchSeek = 0
            state.play(activeChannel)
        } else if program.end <= now {
            if let url = activeChannel.replayURL(for: program) {
                // Dev round 10 (D-01): lab PLTV -> TVOD rewrite, only
                // for catchup URLs (this branch is catchup-only by
                // construction); live URLs never pass through here.
                replayURL = LabServices.applyReplayTransform(url, enabled: state.labReplayPLTVToTVOD); replayProgram = program; sourceOverride = nil; playbackPosition = 0; playbackDuration = 0; engineSwitchSeek = 0
            } else if activeChannel.catchupSource == nil {
                replayAlertMessage = state.localized("该节目无回看地址"); showReplayAlert = true
            } else {
                replayAlertMessage = state.localized("该回看地址格式不受支持"); showReplayAlert = true
            }
        } else {
            replayAlertMessage = state.localized("节目尚未播出"); showReplayAlert = true
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
                        replayURL = nil; replayProgram = nil; sourceOverride = nil; playbackPosition = 0; engineSwitchSeek = 0
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
                            // Dev round 4 (R4-07): last refresh time
                            // and refresh/error status for this source.
                            PlaylistStatusText(playlist: playlist)
                        }
                        Spacer()
                        Image(systemName: "arrow.clockwise.circle").font(.title2).foregroundStyle(state.accent)
                    }
                    .padding(14).background(Color.card, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16)
                }.buttonStyle(.plain).disabled(state.isLoadingPlaylist)
            }
            if let error = state.playlistError { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 20) }
        case .programs:
            EPGProgramList(channel: activeChannel, onPlayProgram: playProgram)
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
                Button { switchTo(item) } label: {
                    HStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.panel).frame(width: 76, height: 56).overlay {
                            // Dev round 1 (DEV-ROWPREVIEW): live preview
                            // reuses the home pool (same 4-slot limit);
                            // without preview it falls back to the logo.
                            if state.previewEnabled, item.streamURL != nil {
                                LivePreviewView(channel: item).id(item.id).clipShape(RoundedRectangle(cornerRadius: 8))
                            } else if let logoURL = item.logoURL {
                                AsyncImage(url: logoURL) { phase in if let image = phase.image { image.resizable().scaledToFit().padding(8) } else { Image(systemName: "tv").foregroundStyle(.secondary) } }
                            } else { Image(systemName: "tv").foregroundStyle(.secondary) }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(item.name).font(.headline)
                                // Dev round 1 (DEV-ROWINFO): quality badge
                                // only from the source-provided attribute
                                // (Channel.quality is never guessed).
                                if !item.quality.isEmpty { Text(item.quality).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1).background(state.accent.opacity(0.2), in: Capsule()) }
                            }
                            Text(state.localizedGroup(item.group)).font(.caption).foregroundStyle(.secondary)
                            // Dev round 1 (DEV-ROWINFO): current programme
                            // name; empty when the guide has none (no
                            // fabricated copy).
                            if let program = rowCurrentProgram(for: item) { Text(program.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
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
    // Dev round 1 (DEV-REPLAY): programme-row tap handler from the
    // detail page; nil keeps rows display-only.
    var onPlayProgram: ((EPGProgram) -> Void)? = nil
    // Dev round 6 (R6-03): a row tap opens the programme detail sheet
    // instead of playing immediately; the sheet owns the play/catchup
    // entry, so a future programme or a catchup-less past programme
    // shows its prompt there instead of starting a stream.
    @State private var selectedProgram: EPGProgram?
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
                        // Dev round 1 (DEV-EPGEMPTY): empty state gets
                        // the same refresh button as the error state.
                        // Dev round 2 (R2-13): with no guide source at
                        // all, a refresh button is meaningless — there
                        // is nothing to refresh from. Show where to set
                        // a source instead (settings, or a playlist
                        // whose header carries x-tvg-url).
                        if state.epgURL.isEmpty {
                            VStack(spacing: 8) {
                                Text(state.localized("未设置节目单来源，请到“设置 → EPG节目单”填写地址，或使用带 x-tvg-url 的播放列表。")).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }.padding(.horizontal, 20).padding(.top, 26)
                        } else {
                            VStack(spacing: 8) {
                                Text(state.localized("暂无节目数据")).foregroundStyle(.secondary)
                                Button(state.localized("刷新节目单")) { state.reloadEPG() }.buttonStyle(.bordered).tint(state.accent)
                            }.padding(.top, 26)
                        }
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(programs) { program in
                                Button { selectedProgram = program } label: {
                                    programRow(program: program, current: current, next: next, now: now)
                                }.buttonStyle(.plain)
                            }
                        }
                        .sheet(item: $selectedProgram) { program in
                            EPGProgramDetailView(channel: channel, program: program, onPlay: onPlayProgram == nil ? nil : { onPlayProgram?(program) })
                        }
                    }
                }
            }
        }
    }

    // Dev round 1 (DEV-REPLAY): programme row (extracted so the same
    // row renders as a button when a tap handler exists and as plain
    // content otherwise). The catchup tag only shows for a past
    // programme when the source actually provided a catchup template.
    private func programRow(program: EPGProgram, current: EPGProgram?, next: EPGProgram?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(timeFormatter.string(from: program.start))–\(timeFormatter.string(from: program.end))").font(.caption.monospacedDigit()).foregroundStyle(state.accent)
                Text(program.title).font(.headline).lineLimit(2)
                Spacer()
                if program.end <= now && channel.catchupSource != nil { Text(state.localized("回看")).font(.caption2.bold()).foregroundStyle(state.accent) }
                if program.id == current?.id { Text(state.localized("当前节目")).font(.caption2.bold()).foregroundStyle(state.accent) }
                else if program.id == next?.id { Text(state.localized("下一节目")).font(.caption2.bold()).foregroundStyle(.secondary) }
            }
            if let subtitle = program.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            if let description = program.programDescription { Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            ProgressView(value: program.progress).tint(state.accent)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.card, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 16)
    }
}

/// Dev round 6 (R6-03): programme detail sheet. Every field comes
/// from the guide: title, start/end, subtitle and description only
/// when the source provided them. The play entry mirrors
/// ChannelDetailView.playProgram exactly — a current programme plays
/// live, a past programme plays catchup only when the source gave a
/// usable template, anything else shows the same prompt instead of
/// a fabricated stream.
private struct EPGProgramDetailView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let channel: Channel
    let program: EPGProgram
    var onPlay: (() -> Void)? = nil

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var status: (text: String, isError: Bool) {
        let now = Date()
        if program.start <= now && now < program.end { return (state.localized("当前节目"), false) }
        if program.end <= now {
            if channel.catchupSource == nil { return (state.localized("该节目无回看地址"), true) }
            if channel.replayURL(for: program) == nil { return (state.localized("该回看地址格式不受支持"), true) }
            return (state.localized("回看"), false)
        }
        return (state.localized("节目尚未播出"), true)
    }

    private var canPlay: Bool {
        let now = Date()
        if program.start <= now && now < program.end { return onPlay != nil }
        if program.end <= now { return onPlay != nil && channel.replayURL(for: program) != nil }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(program.title).font(.title3.bold())
                    Text("\(Self.dayFormatter.string(from: program.start)) – \(Self.timeFormatter.string(from: program.end))")
                        .font(.subheadline).foregroundStyle(state.accent)
                    Text(status.text).font(.caption2.bold()).foregroundStyle(status.isError ? .red : state.accent)
                    if let subtitle = program.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                    if let description = program.programDescription {
                        Text(state.localized("简介")).font(.subheadline.weight(.semibold)).foregroundStyle(state.accent).padding(.top, 4)
                        Text(description).font(.body).foregroundStyle(.secondary)
                    }
                    if canPlay {
                        Button(program.end <= Date() ? state.localized("播放回看") : state.localized("播放")) { onPlay?(); dismiss() }
                            .buttonStyle(.borderedProminent).tint(state.accent).padding(.top, 8)
                    }
                }.padding(22)
            }
            .navigationTitle(state.localized("节目详情"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(state.localized("关闭")) { dismiss() }
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
    // Dev round 8 (R8-09): deinterlacing switch, forwarded to the KS
    // view (and through the AV view to its KS fallback). AVPlayer
    // itself has no such switch.
    var deinterlace: Bool = false
    // Dev round 10 (D-01): lab Metal rendering switch, forwarded to
    // the KS view and, via the AV view, to its KS fallback (dev
    // round 12, R12-01; dev round 14, R14-01, closed the fallback
    // passthrough and the AV declaration). The pure AV path ignores
    // it: AVPlayerLayer is already Metal-backed by the system; there
    // is no app-level switch to flip for it. The lab caption uses
    // the KS-only table key, so the switch never promises AV
    // behaviour.
    var metalRendering: Bool = false
    // Dev round 1: VOD/replay + engine-switch + source-switch plumbing.
    // Defaults keep every other call site unchanged.
    var isLive: Bool = true
    var playbackPosition: Binding<Double> = .constant(0)
    // Dev round 2 (R2-17): total duration reported by the player.
    var playbackDuration: Binding<Double> = .constant(0)
    var initialPosition: Double = 0
    var alternateURLs: [URL] = []
    var activeSourceURL: URL? = nil
    var onSourceSelect: ((URL) -> Void)? = nil
    // Dev round 6 (R6-09): real video size from either engine,
    // forwarded to the detail page's probe record.
    var onVideoSize: ((CGSize) -> Void)? = nil

    var body: some View {
        // Dev round 10 (D-03): macOS has no UIFont, so the KS view
        // (which sets KSOptions.textFont) cannot compile there.
        // macOS therefore always uses the AV path; the engine menu
        // still exists, but KS/auto resolve to AV on this platform
        // and the settings caption for the KS-only switches already
        // says they do not affect the system player.
        #if os(macOS)
        AdaptiveAVPlayerView(url: url, title: title, bufferMilliseconds: bufferMilliseconds, allowsPictureInPicture: allowsPictureInPicture, hardwareAcceleration: false, automaticAudioSelection: automaticAudioSelection, showLatency: showLatency, streamInfo: $streamInfo, deinterlace: false, isLive: isLive, playbackPosition: playbackPosition, playbackDuration: playbackDuration, initialPosition: initialPosition, alternateURLs: alternateURLs, activeSourceURL: activeSourceURL, onSourceSelect: onSourceSelect, allowKSFallback: false, onVideoSize: onVideoSize)
        #else
        // Dev round 2 (R2-07): Auto and system player are no longer the
        // same view. Auto = AVPlayer first, KSPlayer fallback on failure
        // (the old behaviour, now only for Auto); system player = AVPlayer
        // only, failure shows a retry instead of a silent KS swap. The
        // detail page's playerID includes the engine, so switching
        // engines rebuilds the player for real.
        switch engine {
        case .ksPlayer:
            KSCompactPlayerView(url: url, bufferMilliseconds: bufferMilliseconds, allowsPictureInPicture: allowsPictureInPicture, hardwareAcceleration: hardwareAcceleration, automaticAudioSelection: automaticAudioSelection, showLatency: showLatency, streamInfo: $streamInfo, deinterlace: deinterlace, metalRendering: metalRendering, isLive: isLive, playbackPosition: playbackPosition, playbackDuration: playbackDuration, initialPosition: initialPosition, alternateURLs: alternateURLs, activeSourceURL: activeSourceURL, onSourceSelect: onSourceSelect, onVideoSize: onVideoSize)
        case .avPlayer:
            AdaptiveAVPlayerView(url: url, title: title, bufferMilliseconds: bufferMilliseconds, allowsPictureInPicture: allowsPictureInPicture, hardwareAcceleration: hardwareAcceleration, automaticAudioSelection: automaticAudioSelection, showLatency: showLatency, streamInfo: $streamInfo, deinterlace: deinterlace, metalRendering: metalRendering, isLive: isLive, playbackPosition: playbackPosition, playbackDuration: playbackDuration, initialPosition: initialPosition, alternateURLs: alternateURLs, activeSourceURL: activeSourceURL, onSourceSelect: onSourceSelect, allowKSFallback: false, onVideoSize: onVideoSize)
        case .auto:
            AdaptiveAVPlayerView(url: url, title: title, bufferMilliseconds: bufferMilliseconds, allowsPictureInPicture: allowsPictureInPicture, hardwareAcceleration: hardwareAcceleration, automaticAudioSelection: automaticAudioSelection, showLatency: showLatency, streamInfo: $streamInfo, deinterlace: deinterlace, metalRendering: metalRendering, isLive: isLive, playbackPosition: playbackPosition, playbackDuration: playbackDuration, initialPosition: initialPosition, alternateURLs: alternateURLs, activeSourceURL: activeSourceURL, onSourceSelect: onSourceSelect, allowKSFallback: true, onVideoSize: onVideoSize)
        }
        #endif
    }
}

private struct PlaybackControlBar: View {
    @EnvironmentObject private var state: AppState
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
    // Dev round 1 (DEV-VOLUME/DEV-SPEED/DEV-SUBTRACK): volume slider,
    // speed menu and subtitle menu. Defaults keep the old call shape;
    // isLiveStream gates speed (live speed is disabled with a note,
    // never faked as working).
    var volume: Double = 1.0
    var onVolumeChange: (Double) -> Void = { _ in }
    var playbackRate: Double = 1.0
    var onRateSelect: (Double) -> Void = { _ in }
    var subtitleOptions: [String] = []
    var subtitleSelectedIndex: Int? = nil
    var onSubtitleSelect: (Int?) -> Void = { _ in }
    var isLiveStream: Bool = true

    var body: some View {
        // Dev round 1: horizontally scrollable so the added controls
        // (volume, speed, subtitles) cannot push the bar off-screen on
        // narrow phones; previously the bar was a fixed HStack.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                controlButton(icon: isPlaying ? "pause.fill" : "play.fill", prominent: true, action: onPlayPause)
                controlButton(icon: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", action: onMute)
                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Slider(value: Binding(get: { volume }, set: { onVolumeChange($0) }), in: 0...1).frame(width: 80).tint(.white)
                }.accessibilityLabel(state.localized("音量"))
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
                Menu {
                    if isLiveStream {
                        Text(state.localized("直播不支持倍速")).disabled(true)
                    } else {
                        ForEach([0.5, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                            Button { onRateSelect(rate) } label: { Label("\(String(format: "%g", rate))x", systemImage: playbackRate == rate ? "checkmark" : "speedometer") }
                        }
                    }
                } label: {
                    Text("\(String(format: "%g", playbackRate))x").font(.system(size: 14, weight: .semibold)).frame(width: 44, height: 40).foregroundStyle(.white)
                }.buttonStyle(.plain).accessibilityLabel(state.localized("倍速"))
                Menu {
                    if subtitleOptions.isEmpty {
                        Text(state.localized("无字幕轨")).disabled(true)
                    } else {
                        Button { onSubtitleSelect(nil) } label: { Label(state.localized("关闭字幕"), systemImage: subtitleSelectedIndex == nil ? "checkmark" : "captions.bubble") }
                        ForEach(Array(subtitleOptions.enumerated()), id: \.offset) { index, name in
                            Button { onSubtitleSelect(index) } label: { Label(name, systemImage: subtitleSelectedIndex == index ? "checkmark" : "captions.bubble") }
                        }
                    }
                } label: {
                    Image(systemName: "captions.bubble").font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 40).foregroundStyle(.white)
                }.buttonStyle(.plain).accessibilityLabel(state.localized("字幕"))
                if showsPiP { controlButton(icon: "rectangle.on.rectangle", action: onPiP) }
                if showsProjection { AirPlayButton() }
            }
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

// Dev round 10 (D-03): AVRoutePickerView exists only on iOS/tvOS;
// other platforms get an empty view so the control-bar call site
// stays unchanged.
#if os(iOS) || os(tvOS)
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
#else
private struct AirPlayButton: View {
    var body: some View { EmptyView() }
}
#endif

// Dev round 10 (D-03): the KS view uses UIFont/UIScreen, which do
// not exist on macOS, so the whole view is excluded there (the
// PlayerSurface macOS branch and the AV fallback guard below route
// macOS to the AV path instead). iOS/tvOS/visionOS are unaffected.
#if !os(macOS)
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
    // Dev round 8 (R8-09): deinterlacing switch, applied to
    // KSOptions below. CI-verification item for the property
    // spelling, same precedent as textFont/userAgent.
    var deinterlace: Bool = false
    // Dev round 10 (D-01): lab Metal rendering switch, applied to
    // the KS fallback's KSOptions below (dev round 12, R12-01: the
    // pure AV path ignores it). CI-verification item for the property
    // spelling, same precedent as textFont/userAgent/deinterlace:
    // if KSPlayer 2.3.4 has no such property, CI fails here first
    // and the fix is to drop the line (the switch then degrades to
    // a no-op, and the lab caption must say so).
    var metalRendering: Bool = false
    // Dev round 1: VOD/replay + engine-switch + source-switch plumbing.
    // Defaults keep the AV-fallback call site unchanged.
    var isLive: Bool = true
    var playbackPosition: Binding<Double> = .constant(0)
    var playbackDuration: Binding<Double> = .constant(0)
    var initialPosition: Double = 0
    var alternateURLs: [URL] = []
    var activeSourceURL: URL? = nil
    var onSourceSelect: ((URL) -> Void)? = nil
    // Dev round 6 (R6-09): real video size from naturalSize, forwarded
    // to the detail page's probe record.
    var onVideoSize: ((CGSize) -> Void)? = nil
    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    // Dev round 2 (R2-02): subtitle size from the settings slider,
    // wired into KSOptions.textFont below (KSPlayer scales it by
    // screen width on top of this value).
    @AppStorage("subtitleFontSize") private var subtitleFontSize: Double = 18
    @State private var controlsVisible = true
    @State private var isPlaying = true
    @State private var isBuffering = true
    @State private var audioOptions: [String] = []
    @State private var videoOptions: [String] = []
    @State private var latencyDisplay: LatencyDisplay = .sampling
    // Dev round 1 (DEV-PROGRESS/DEV-VOLUME/DEV-SPEED/DEV-SUBTRACK/
    // DEV-GESTURE): VOD position/duration, volume, rate, subtitle
    // options, gesture drag anchor, zoom gravity, one-shot seek flag.
    @State private var ksPosition: Double = 0
    @State private var ksDuration: Double = 0
    @State private var ksVolume: Double = 1.0
    @State private var ksPlaybackRate: Double = 1.0
    @State private var subtitleOptions: [String] = []
    @State private var subtitleSelectedIndex: Int?
    @State private var didApplyInitialSeek = false
    @State private var lastDragY: CGFloat?
    @State private var gravityFill = false
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
                // Compile-fix round: onStateChanged/onFinish are
                // KSVideoPlayer members, not View extensions — the
                // audit-added .id(retryID) between the player and
                // onStateChanged erased the type to `some View` and
                // broke the chain (this is also the order the
                // original, compiling code used). .id() now sits
                // after the KSPlayer modifiers, so a retryID bump
                // still recreates the whole player subtree.
                .onStateChanged { layer, playerState in
                    isPlaying = playerState.isPlaying
                    isBuffering = playerState == .preparing || playerState == .buffering
                    if playerState == .error {
                        isBuffering = false
                        // Dev round 4 (R4-04): probed — KSPlayer 2.3.4's
                        // onStateChanged delivers (layer, state) only;
                        // the layer carries no error object (the
                        // delegate's only cause channel is onFinish's
                        // second parameter, classified below). When
                        // .error arrives without an onFinish error,
                        // the fallback is therefore the unified
                        // generic text from PlaybackFailure, not the
                        // old longer sentence (removed from the tables
                        // in dev round 6). Whichever arrives
                        // first still wins; a classified text is never
                        // overwritten by the generic one.
                        if ksError == nil { ksError = state.localized(PlaybackFailure.textKey(for: .generic, isTimeout: false)) }
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
                        // Dev round 1: re-apply the user's volume/rate
                        // after a rebuild (a new player starts at
                        // defaults), and apply a pending engine-switch
                        // seek for VOD.
                        layer.player.volume = Float(ksVolume)
                        if !isLive { layer.player.playbackRate = Float(ksPlaybackRate) }
                        if initialPosition > 0 && !didApplyInitialSeek {
                            didApplyInitialSeek = true
                            layer.player.seek(time: initialPosition)
                        }
                    }
                }
                // Dev round 2 (R2-01/R2-03): the finish callback DOES
                // carry the failure cause as its second parameter — the
                // dev-round-1 comment claiming "no payload" was wrong
                // (the old code discarded it with `_, _`). KS failures
                // now classify through the same PlaybackFailure mapping
                // as AV; a nil error (normal finish) sets no error.
                .onFinish { _, error in
                    isPlaying = false; ksDidFinish = true; controlsVisible = true
                    if let error {
                        let kind = PlaybackFailure.classify(error)
                        let isTimeout = (error as? URLError)?.code == .timedOut
                        ksError = state.localized(PlaybackFailure.textKey(for: kind, isTimeout: isTimeout))
                    }
                }
                .id(retryID)
            // Dev round 1 (DEV-GESTURE): the two half-width zones own
            // both taps — single tap toggles controls, double tap seeks
            // ±10s (VOD only; live streams ignore it rather than faking
            // a seek). Drag (volume/brightness) and pinch (zoom) ride
            // on the same zones as simultaneous gestures so control-bar
            // drags are untouched.
            // Dev round 2 (R2-05): the old code hung two independent
            // onTapGesture modifiers on each zone, so a double tap
            // always fired one single tap first (controls flickered on
            // every seek). The taps are now one exclusive gesture:
            // double tap wins when it happens; a single tap fires only
            // after the double-tap window passes, so toggling controls
            // is now slightly delayed by design.
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle())
                    .gesture(
                        TapGesture(count: 2).exclusively(before: TapGesture(count: 1))
                            .onEnded { value in
                                switch value {
                                case .first: if !isLive { seekKS(to: max(ksPosition - 10, 0)) }
                                case .second: controlsVisible ? hideControls() : revealControls()
                                }
                            }
                    )
                Color.clear.contentShape(Rectangle())
                    .gesture(
                        TapGesture(count: 2).exclusively(before: TapGesture(count: 1))
                            .onEnded { value in
                                switch value {
                                case .first: if !isLive { seekKS(to: ksDuration > 0 ? min(ksPosition + 10, ksDuration) : ksPosition + 10) }
                                case .second: controlsVisible ? hideControls() : revealControls()
                                }
                            }
                    )
            }
            .simultaneousGesture(dragGesture)
            .simultaneousGesture(MagnificationGesture().onEnded { _ in
                gravityFill.toggle()
                coordinator.playerLayer?.videoGravity = gravityFill ? .resizeAspectFill : .resizeAspect
            })
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
                    // Dev round 1 (DEV-NOURL): alternate lines on failure.
                    SourceSwitchMenu(lines: alternateURLs, active: activeSourceURL, alwaysShow: true, onSelect: { onSourceSelect?($0) })
                }.padding(.horizontal, 24)
            }
            // Dev round 1 (DEV-KSBADGE): the badge hides on failure,
            // matching the AV side (which already hides on didFail).
            if showLatency && ksError == nil { StreamLatencyBadge(display: latencyDisplay).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading) }
            // Dev round 1: bottom-anchored controls (was centered):
            // progress (VOD only, never a fake live bar) + control bar.
            // Dev round 2 (R2-06): hidden on failure, matching the AV
            // side (which already gates its bottom area on !didFail);
            // previously the bar and progress sat under the error text.
            if ksError == nil {
                VStack {
                Spacer()
                if !isLive {
                    PlaybackProgressBar(current: ksPosition, duration: ksDuration, onSeek: { seekKS(to: $0) })
                        .padding(.horizontal, 16)
                }
                if controlsVisible {
                    // Round-3 fix (A06): the PiP button used to show whenever
                    // the setting was on, while the AV side gated on system
                    // PiP support. KSPlayer exposes no per-stream support
                    // query in this codebase, so the gate is the same system
                    // support check the AV side uses; stream-level support
                    // remains unverifiable statically.
                    PlaybackControlBar(accent: state.accent, isPlaying: isPlaying, isMuted: coordinator.isMuted, showsPiP: allowsPictureInPicture && AVPictureInPictureController.isPictureInPictureSupported(), showsProjection: true, onPlayPause: togglePlay, onMute: toggleMute, onPiP: togglePiP, audioOptions: audioOptions, videoOptions: videoOptions, audioSelectedIndex: audioSelectedIndex, videoSelectedIndex: videoSelectedIndex, onAudioSelect: selectAudio, onVideoSelect: selectVideo, volume: ksVolume, onVolumeChange: applyKSVolume, playbackRate: ksPlaybackRate, onRateSelect: applyKSRate, subtitleOptions: subtitleOptions, subtitleSelectedIndex: subtitleSelectedIndex, onSubtitleSelect: selectSubtitle, isLiveStream: isLive)
                        .transition(.opacity)
                }
                }.padding(.bottom, 10)
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
            latencyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in sampleLatency(); updatePosition() }
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
                    latencyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in sampleLatency(); updatePosition() }
                    revealControls()
                } else if latencyTimer == nil {
                    // Paused/failed players were not rebuilt above, but
                    // their timer was stopped on backgrounding; restart it
                    // so the badge follows the (paused/failed) player again
                    // instead of freezing on its pre-background value.
                    latencyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in sampleLatency(); updatePosition() }
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
        // Dev round 2 (R2-02/R2-10): subtitle size from the slider and
        // the user's custom UA (same "..." means unset rule as
        // M3UParser.configuredSession). CI-verification item: these two
        // property spellings on KSPlayer 2.3.4's KSOptions.
        options.textFont = UIFont.systemFont(ofSize: subtitleFontSize)
        options.userAgent = PlaybackItemFactory.effectiveUserAgent()
        // Dev round 8 (R8-09): CI-verification item — deinterlace on
        // KSPlayer 2.3.4's KSOptions, same precedent as the two lines
        // above. AVPlayer has no equivalent switch (system default).
        options.deinterlace = deinterlace
        // Dev round 10 (D-01): lab Metal rendering (see the property
        // note above for the CI-verification caveat).
        options.metalRendering = metalRendering
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
        latencyDisplay = .sampling
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
        // Dev round 1: position/duration/subtitles reset with the
        // player; volume and rate are user choices and survive, and
        // are re-applied on readyToPlay below.
        ksPosition = 0
        ksDuration = 0
        playbackPosition = 0
        playbackDuration = 0
        subtitleOptions = []
        subtitleSelectedIndex = nil
        didApplyInitialSeek = false
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
        if playing { coordinator.playerLayer?.pause(); ksUserPaused = true } else { coordinator.playerLayer?.play(); ksUserPaused = false; ksDidFinish = false; if !isLive { coordinator.playerLayer?.player.playbackRate = Float(ksPlaybackRate) } }
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
        // Dev round 1 (DEV-SUBTRACK): subtitle tracks from the same
        // track enumeration as audio/video. CI-verification item: the
        // `.subtitle` media type on KSPlayer 2.3.4 (see report).
        let subtitleTracks = player.tracks(mediaType: .subtitle)
        subtitleOptions = subtitleTracks.enumerated().map { index, track in track.name.isEmpty ? "Subtitle \(index + 1)" : track.name }
        subtitleSelectedIndex = subtitleTracks.firstIndex(where: { $0.isEnabled })
        if let video = videoTracks.first(where: { $0.isEnabled }) ?? videoTracks.first {
            lines.append("Video  \(video.name)")
            if video.nominalFrameRate > 0 { lines.append(String(format: "Frame rate  %.2f fps", video.nominalFrameRate)) }
            if video.bitRate > 0 { lines.append("Bit rate  \(Int(video.bitRate / 1000)) kbps") }
            lines.append("Codec  \(video.description)")
        }
        if let audio = audioTracks.first(where: { $0.isEnabled }) ?? audioTracks.first { lines.append("Audio  \(audio.name)") }
        let size = player.naturalSize
        if size.width > 0 && size.height > 0 {
            lines.append("Resolution  \(Int(size.width)) × \(Int(size.height))")
            // Dev round 6 (R6-09): forward the real frame size to the
            // probe record; a zero size records nothing.
            onVideoSize?(size)
        }
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
        // Dev round 1 (DEV-SUBTRACK): same subtitle enumeration as
        // updateStreamInfo (see the CI-verification note there).
        let subtitleTracks = player.tracks(mediaType: .subtitle)
        subtitleOptions = subtitleTracks.enumerated().map { index, track in track.name.isEmpty ? "Subtitle \(index + 1)" : track.name }
        subtitleSelectedIndex = subtitleTracks.firstIndex(where: { $0.isEnabled })
    }

    private func sampleLatency() {
        // Dev round 1 (DEV-LAT): the old guard required `seekable`, so
        // a pure live stream (seekable == false) reported nil all
        // session. Latency is still computable from the buffered end
        // minus the play head; only fall back to unsupported when the
        // numbers themselves are not finite. A non-playing player keeps
        // its last display instead of collapsing to unavailable.
        guard let player = coordinator.playerLayer?.player else { return }
        guard player.isPlaying else { return }
        guard player.playableTime.isFinite, player.currentPlaybackTime.isFinite else {
            latencyDisplay = .unsupported
            return
        }
        let seconds = player.playableTime - player.currentPlaybackTime
        latencyDisplay = seconds >= 0 && seconds.isFinite ? .milliseconds(Int((seconds * 1000).rounded())) : .unsupported
    }

    /// Dev round 1 (DEV-PROGRESS): VOD position/duration report, called
    /// from the same 1s timer as sampleLatency. CI-verification item:
    /// the `duration` property spelling on KSPlayer 2.3.4.
    private func updatePosition() {
        guard let player = coordinator.playerLayer?.player else { return }
        ksPosition = player.currentPlaybackTime
        ksDuration = player.duration
        playbackPosition = ksPosition
        playbackDuration = ksDuration
    }

    /// Dev round 1 (DEV-GESTURE/DEV-PROGRESS/DEV-ENGINESWITCH): KSPlayer
    /// seek. CI-verification item: the seek API spelling on KSPlayer
    /// 2.3.4 (see report).
    private func seekKS(to seconds: Double) {
        coordinator.playerLayer?.player.seek(time: seconds)
    }

    /// Dev round 1 (DEV-VOLUME): KSPlayer volume. CI-verification
    /// item: the volume property spelling on KSPlayer 2.3.4.
    private func applyKSVolume(_ value: Double) {
        ksVolume = value
        coordinator.playerLayer?.player.volume = Float(value)
        revealControls()
    }

    /// Dev round 1 (DEV-SPEED): VOD only (the menu is disabled for
    /// live streams, so this never runs for live). CI-verification
    /// item: the playbackRate property spelling on KSPlayer 2.3.4.
    private func applyKSRate(_ rate: Double) {
        ksPlaybackRate = rate
        coordinator.playerLayer?.player.playbackRate = Float(rate)
        revealControls()
    }

    /// Dev round 1 (DEV-SUBTRACK): nil turns all subtitle tracks off.
    private func selectSubtitle(_ index: Int?) {
        guard let layer = coordinator.playerLayer else { return }
        let tracks = layer.player.tracks(mediaType: .subtitle)
        tracks.forEach { $0.isEnabled = false }
        if let index, tracks.indices.contains(index) { tracks[index].isEnabled = true }
        subtitleSelectedIndex = index
        revealControls()
    }

    /// Dev round 1 (DEV-GESTURE): vertical drag adjusts brightness
    /// (left half) or volume (right half). The screen midpoint
    /// approximates the player midpoint (the player spans the full
    /// width in the detail page).
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard let last = lastDragY else { lastDragY = value.location.y; return }
                let delta = (last - value.location.y) / 200
                if value.startLocation.x > UIScreen.main.bounds.width / 2 {
                    applyKSVolume(min(max(ksVolume + delta, 0), 1))
                } else {
                    UIScreen.main.brightness = min(max(UIScreen.main.brightness + delta, 0), 1)
                }
                lastDragY = value.location.y
            }
            .onEnded { _ in lastDragY = nil }
    }
}
#endif

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
    // Dev round 8 (R8-02): this flag is intentionally NOT consumed by
    // the AV path — AVFoundation exposes no hardware/software decode
    // switch (VideoToolbox hardware decode is automatic). It is only
    // forwarded to the KS fallback view below, where it gates
    // KSOptions.hardwareDecode. The settings caption states the
    // KS-only scope, so the switch never promises AV behaviour.
    let hardwareAcceleration: Bool
    let automaticAudioSelection: Bool
    let showLatency: Bool
    @Binding var streamInfo: String
    // Dev round 8 (R8-09): forwarded to the KS fallback view only;
    // the AV path itself has no deinterlace switch.
    var deinterlace: Bool = false
    // Dev round 14 (R14-01): lab Metal rendering switch, declared so
    // PlayerSurface's AV calls compile (the AV path itself ignores
    // it — AVPlayerLayer is already Metal-backed by the system — and
    // it is only forwarded to the KS fallback view below).
    var metalRendering: Bool = false
    // Dev round 1: same VOD/engine/source plumbing as the KS view.
    // Defaults keep the PlayerSurface call shape simple.
    var isLive: Bool = true
    var playbackPosition: Binding<Double> = .constant(0)
    var playbackDuration: Binding<Double> = .constant(0)
    var initialPosition: Double = 0
    var alternateURLs: [URL] = []
    var activeSourceURL: URL? = nil
    var onSourceSelect: ((URL) -> Void)? = nil
    // Dev round 2 (R2-07): Auto allows the KS fallback on AV failure;
    // system player does not (failure shows a retry instead).
    var allowKSFallback: Bool = true
    // Dev round 6 (R6-09): real video size reported by the session,
    // forwarded to the detail page's probe record.
    var onVideoSize: ((CGSize) -> Void)? = nil
    // Dev round 2 (R2-02): subtitle size from the settings slider,
    // applied live to the session (see onChange below).
    @AppStorage("subtitleFontSize") private var subtitleFontSize: Double = 18
    @StateObject private var session: AVPlaybackSession
    // Dev round 1 (DEV-CTRLVIS): AV controls now match KS — tap to
    // toggle, 3s auto-hide while playing (previously always visible
    // with no gesture at all).
    @State private var controlsVisible = true
    @State private var hideToken = UUID()
    @State private var lastDragY: CGFloat?
    @State private var gravityFill = false
    // Dev round 10 (D-01): lab enhanced-system-player retry, once
    // per failure. The view is recreated per playerID, so the flag
    // resets on every channel/engine/source switch by construction.
    @State private var enhancedRetried = false

    // Dev round 15 (R15-01): deinterlace and onVideoSize were missing
    // from this init while PlayerSurface already passed both at all
    // three call sites — an undeclared-argument call, same class as
    // R12-01. AV itself ignores deinterlace (forwarded to the KS
    // fallback view only, as the property comment states); onVideoSize
    // follows the existing body wiring (AV presentationSize observation
    // plus the KS fallback report), no new channel is introduced.
    init(url: URL, title: String, bufferMilliseconds: Double, allowsPictureInPicture: Bool, hardwareAcceleration: Bool, automaticAudioSelection: Bool, showLatency: Bool, streamInfo: Binding<String>, isLive: Bool = true, playbackPosition: Binding<Double> = .constant(0), playbackDuration: Binding<Double> = .constant(0), initialPosition: Double = 0, alternateURLs: [URL] = [], activeSourceURL: URL? = nil, onSourceSelect: ((URL) -> Void)? = nil, allowKSFallback: Bool = true, metalRendering: Bool = false, deinterlace: Bool = false, onVideoSize: ((CGSize) -> Void)? = nil) {
        self.url = url
        self.title = title
        self.bufferMilliseconds = bufferMilliseconds
        self.allowsPictureInPicture = allowsPictureInPicture
        self.hardwareAcceleration = hardwareAcceleration
        self.automaticAudioSelection = automaticAudioSelection
        self.showLatency = showLatency
        _streamInfo = streamInfo
        self.isLive = isLive
        self.playbackPosition = playbackPosition
        self.playbackDuration = playbackDuration
        self.initialPosition = initialPosition
        self.alternateURLs = alternateURLs
        self.activeSourceURL = activeSourceURL
        self.onSourceSelect = onSourceSelect
        self.allowKSFallback = allowKSFallback
        self.metalRendering = metalRendering
        self.deinterlace = deinterlace
        self.onVideoSize = onVideoSize
        _session = StateObject(wrappedValue: AVPlaybackSession(url: url, bufferMilliseconds: bufferMilliseconds, automaticAudioSelection: automaticAudioSelection, initialSeek: initialPosition))
    }

    var body: some View {
        ZStack {
            // Dev round 2 (R2-07): the KS fallback runs only for Auto.
            // For system player a failure leaves the layer empty and the
            // error block below shows a retry (no silent engine swap).
            // Dev round 10 (D-03): the KS fallback view does not exist
            // on macOS (see the KS view guard), so macOS never takes
            // this branch even if allowKSFallback were true.
            #if !os(macOS)
            if session.didFail && allowKSFallback {
                // Round-2 fix: AV retry was previously unreachable — the
                // fallback branch replaced the whole AV UI and session.play()
                // only runs on onAppear, so a failed stream could only be
                // retried by closing and reopening the detail page. The
                // retry button rebuilds the AV item in place (session.retry()
                // also clears didFail, which swaps the AV layer back in).
                ZStack(alignment: .topTrailing) {
                    KSCompactPlayerView(url: url, bufferMilliseconds: bufferMilliseconds, allowsPictureInPicture: allowsPictureInPicture, hardwareAcceleration: hardwareAcceleration, automaticAudioSelection: automaticAudioSelection, showLatency: showLatency, streamInfo: $streamInfo, deinterlace: deinterlace, metalRendering: metalRendering, onVideoSize: onVideoSize)
                    Button(state.localized("用 AVPlayer 重试")) { session.retry() }
                        .buttonStyle(.bordered).tint(state.accent)
                        .font(.caption).padding(8)
                }
            } else if !session.didFail {
                AVPlayerLayerView(session: session, gravity: gravityFill ? .resizeAspectFill : .resizeAspect)
            }
            #else
            if !session.didFail {
                AVPlayerLayerView(session: session, gravity: gravityFill ? .resizeAspectFill : .resizeAspect)
            }
            #endif
            // Dev round 1 (DEV-GESTURE/DEV-CTRLVIS): same tap zones as
            // KS — single tap toggles controls, double tap seeks ±10s
            // (VOD only). Drag (volume/brightness) and pinch (zoom)
            // ride here as simultaneous gestures.
            if !session.didFail {
                // Dev round 2 (R2-05): same exclusive-tap fix as the KS
                // zones — a double tap no longer fires a single tap
                // first; single taps wait out the double-tap window.
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle())
                        .gesture(
                            TapGesture(count: 2).exclusively(before: TapGesture(count: 1))
                                .onEnded { value in
                                    switch value {
                                    case .first: if !isLive { session.seek(to: max(session.playbackPosition - 10, 0)) }
                                    case .second: controlsVisible ? hideControls() : revealControls()
                                    }
                                }
                        )
                    Color.clear.contentShape(Rectangle())
                        .gesture(
                            TapGesture(count: 2).exclusively(before: TapGesture(count: 1))
                                .onEnded { value in
                                    switch value {
                                    case .first: if !isLive { session.seek(to: session.playbackDuration > 0 ? min(session.playbackPosition + 10, session.playbackDuration) : session.playbackPosition + 10) }
                                    case .second: controlsVisible ? hideControls() : revealControls()
                                    }
                                }
                        )
                }
                .simultaneousGesture(dragGesture)
                .simultaneousGesture(MagnificationGesture().onEnded { _ in gravityFill.toggle() })
            }
            if session.isBuffering && !session.didFail { ProgressView().tint(.white).controlSize(.large) }
            if showLatency && !session.didFail { StreamLatencyBadge(display: session.latencyDisplay).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading) }
            // Dev round 1 (DEV-AVERR): failure reason (timeout gets its
            // own text) + alternate lines, over the KS fallback.
            if session.didFail {
                VStack(spacing: 10) {
                    Text(state.localized(PlaybackFailure.textKey(for: session.failureKind, isTimeout: session.failureIsTimeout))).font(.subheadline).foregroundStyle(.white).multilineTextAlignment(.center)
                    // Dev round 10 (D-01): the compat retry already
                    // ran once and still failed — say so, instead of
                    // showing a bare retry as if nothing was tried.
                    if enhancedRetried {
                        Text(state.localized("已尝试兼容路径仍失败")).font(.caption).foregroundStyle(.secondary)
                    }
                    // Dev round 2 (R2-07): system player has no KS
                    // fallback, so a failure needs its own retry here.
                    if !allowKSFallback {
                        Button(state.localized("重试")) { session.retry() }.buttonStyle(.borderedProminent)
                    }
                    SourceSwitchMenu(lines: alternateURLs, active: activeSourceURL, alwaysShow: true, onSelect: { onSourceSelect?($0) })
                }.padding(.horizontal, 24)
            }
            if !session.didFail {
                VStack {
                    Spacer()
                    if !isLive {
                        PlaybackProgressBar(current: session.playbackPosition, duration: session.playbackDuration, onSeek: { session.seek(to: $0) })
                            .padding(.horizontal, 16)
                    }
                    if controlsVisible {
                        PlaybackControlBar(accent: state.accent, isPlaying: session.isPlaying, isMuted: session.isMuted, showsPiP: allowsPictureInPicture && session.isPiPSupported, showsProjection: true, onPlayPause: session.togglePlay, onMute: session.toggleMute, onPiP: session.togglePiP, audioOptions: session.audioOptions, videoOptions: session.videoOptions, videoMenuNote: state.localized("码率上限"), audioSelectedIndex: session.audioSelectedIndex, videoSelectedIndex: session.videoSelectedIndex, onAudioSelect: session.selectAudio, onVideoSelect: session.selectVideo, volume: session.volume, onVolumeChange: session.setVolume, playbackRate: session.playbackRate, onRateSelect: session.setRate, subtitleOptions: session.subtitleOptions, subtitleSelectedIndex: session.subtitleSelectedIndex, onSubtitleSelect: session.selectSubtitle, isLiveStream: isLive)
                    }
                }.padding(.bottom, 10)
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
        // Dev round 6 (R6-09): forward the session's real frame size
        // to the probe record; .zero is filtered by the recorder.
        .onReceive(session.$videoSize) { size in if size.width > 0 && size.height > 0 { onVideoSize?(size) } }
        .onReceive(session.$playbackPosition) { playbackPosition = $0 }
        .onReceive(session.$playbackDuration) { playbackDuration = $0 }
        // Dev round 2 (R2-02): a slider change mid-playback re-applies
        // the size to the current item; creation and retry apply the
        // stored value inside the session.
        .onChange(of: subtitleFontSize) { session.applySubtitleSize($0) }
        .onAppear { session.play(); revealControls() }
        // Dev round 10 (D-01): lab enhanced system player. Only the
        // system player (no KS fallback) gets this: when AV fails
        // and the switch is on, rebuild once through the compat path
        // (plain item, no proxy loader, no custom UA). Auto already
        // has its own KS fallback and is deliberately untouched, so
        // the two mechanisms can never be confused.
        .onChange(of: session.didFail) {
            if session.didFail && !allowKSFallback && state.labEnhancedSystemPlayer && !enhancedRetried {
                enhancedRetried = true
                session.retryWithCompatItem()
            }
        }
        // Dev round 10 (D-03): macOS menu-bar playback commands.
        // Harmless on other platforms (nothing posts them there).
        .onReceive(NotificationCenter.default.publisher(for: .nanoStreamTogglePlay)) { _ in session.togglePlay() }
        .onReceive(NotificationCenter.default.publisher(for: .nanoStreamToggleMute)) { _ in session.toggleMute() }
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

    // Dev round 1 (DEV-CTRLVIS): same 3s auto-hide as KS, only while
    // playing (a paused player keeps its controls visible).
    private func revealControls() {
        withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true }
        let token = UUID()
        hideToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if hideToken == token && session.isPlaying { withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false } }
        }
    }

    private func hideControls() { hideToken = UUID(); withAnimation(.easeOut(duration: 0.15)) { controlsVisible = false } }

    /// Dev round 1 (DEV-GESTURE): vertical drag adjusts brightness
    /// (left half) or volume (right half); see the KS twin.
    /// Dev round 10 (D-03): UIScreen brightness does not exist on
    /// macOS, so the drag there is volume-only on both halves.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard let last = lastDragY else { lastDragY = value.location.y; return }
                let delta = (last - value.location.y) / 200
                #if os(iOS) || os(tvOS) || os(visionOS)
                if value.startLocation.x > UIScreen.main.bounds.width / 2 {
                    session.setVolume(min(max(session.volume + delta, 0), 1))
                } else {
                    UIScreen.main.brightness = min(max(UIScreen.main.brightness + delta, 0), 1)
                }
                #else
                session.setVolume(min(max(session.volume + delta, 0), 1))
                #endif
                lastDragY = value.location.y
            }
            .onEnded { _ in lastDragY = nil }
    }
}

// Dev round 10 (D-03): same macOS twin as the preview layer view
// above (NSViewRepresentable, same call shape).
#if os(macOS)
private struct AVPlayerLayerView: NSViewRepresentable {
    @ObservedObject var session: AVPlaybackSession
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.gravity = gravity
        view.attach(session: session)
        return view
    }

    func updateNSView(_ view: PlayerLayerHostView, context: Context) {
        view.gravity = gravity
        view.playerLayer.videoGravity = gravity
        view.attach(session: session)
    }
    static func dismantleNSView(_ view: PlayerLayerHostView, coordinator: ()) { view.detach() }
}

private final class PlayerLayerHostView: NSView {
    let playerLayer = AVPlayerLayer()
    var gravity: AVLayerVideoGravity = .resizeAspect
    private weak var session: AVPlaybackSession?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func attach(session: AVPlaybackSession) {
        self.session = session
        playerLayer.player = session.player
        playerLayer.videoGravity = gravity
        session.attach(playerLayer: playerLayer)
    }

    func detach() {
        session?.detach(playerLayer: playerLayer)
        session = nil
    }
}
#else
private struct AVPlayerLayerView: UIViewRepresentable {
    @ObservedObject var session: AVPlaybackSession
    // Dev round 1 (DEV-GESTURE): pinch zoom target gravity.
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.gravity = gravity
        view.attach(session: session)
        return view
    }

    func updateUIView(_ view: PlayerLayerHostView, context: Context) {
        view.gravity = gravity
        view.playerLayer.videoGravity = gravity
        view.attach(session: session)
    }
    static func dismantleUIView(_ view: PlayerLayerHostView, coordinator: ()) { view.detach() }
}

private final class PlayerLayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var gravity: AVLayerVideoGravity = .resizeAspect
    private weak var session: AVPlaybackSession?

    func attach(session: AVPlaybackSession) {
        self.session = session
        playerLayer.player = session.player
        playerLayer.videoGravity = gravity
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
#endif

@MainActor
/// Dev round 2 (R2-09/R2-10): one place that builds system-player
/// items with the user's proxy/UA settings applied. Rules:
/// - A configured HTTP proxy (parseable by M3UParser.parseProxy) routes
///   playback through a custom-scheme resource loader (nanohttp/
///   nanohttps) whose requests run on a session built from
///   M3UParser.configuredSession()'s configuration (proxy dictionary +
///   UA header). The loader delegate must be kept alive by the caller
///   (AVAssetResourceLoader holds it weakly).
/// - With no proxy but a custom UA, the item is built from an AVURLAsset
///   carrying the UA header.
/// - With neither, the item is a plain AVPlayerItem(url:) — no behaviour
///   change for users without proxy/UA settings.
/// File URLs and non-http(s) schemes never go through the loader.
/// CI-verification item: kCMTextMarkupAttribute_RelativeFontSize's exact
/// Swift spelling (CoreMedia constant) and KSOptions.textFont/userAgent
/// in KSPlayer 2.3.4 — no local toolchain can check them statically.
enum PlaybackItemFactory {
    /// The UA actually sent: the custom value, or the built-in
    /// identifier. A value containing "..." is treated as unset, the
    /// same rule M3UParser.configuredSession() uses.
    static func effectiveUserAgent() -> String {
        let trimmed = (UserDefaults.standard.string(forKey: "userAgent") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (!trimmed.isEmpty && !trimmed.contains("...")) ? trimmed : "NanoStreamClone/1.0 (iOS)"
    }

    static func hasProxy() -> Bool {
        M3UParser.parseProxy(UserDefaults.standard.string(forKey: "httpProxy") ?? "") != nil
    }

    static func proxiedURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = scheme == "http" ? "nanohttp" : "nanohttps"
        return components?.url
    }

    // Dev round 8 (R8-03): the global bitrate cap, read live so a
    // settings change applies to the next item without relaunch. 0
    // (unset) means unlimited, which is AVPlayerItem's own default,
    // so the assignment is a no-op for users who never set a cap.
    // The in-player menu still overrides this for the current item
    // only (see AVPlaybackSession.selectVideo).
    static func globalBitrateCap() -> Double {
        let value = UserDefaults.standard.double(forKey: "nanostream.globalBitrateCap")
        return value > 0 ? value : 0
    }

    static func makeItem(url: URL) -> (item: AVPlayerItem, loaderDelegate: PlaybackResourceLoaderDelegate?) {
        let cap = globalBitrateCap()
        if hasProxy(), let proxied = proxiedURL(for: url) {
            let delegate = PlaybackResourceLoaderDelegate()
            let asset = AVURLAsset(url: proxied)
            asset.resourceLoader.setDelegate(delegate, queue: .main)
            let item = AVPlayerItem(asset: asset)
            item.preferredPeakBitRate = cap
            return (item, delegate)
        }
        let customUA = (UserDefaults.standard.string(forKey: "userAgent") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !customUA.isEmpty && !customUA.contains("...") {
            let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPHeaderFieldsKey: ["User-Agent": customUA]])
            let item = AVPlayerItem(asset: asset)
            item.preferredPeakBitRate = cap
            return (item, nil)
        }
        let item = AVPlayerItem(url: url)
        item.preferredPeakBitRate = cap
        return (item, nil)
    }

    /// Dev round 2 (R2-02): AVFoundation expresses subtitle size
    /// relative to the default (100%). This app treats 18pt as the
    /// default, matching the settings default; the 12...40pt slider
    /// therefore maps to ~67...222%. KSPlayer takes an absolute UIFont
    /// instead (see KSCompactPlayerView.options), so the two paths are
    /// not numerically identical — both honour the same slider value.
    static func subtitleTextStyleRules(sizePoints: Double) -> [AVTextStyleRule] {
        let percent = max(min(sizePoints / 18 * 100, 222), 67)
        return [AVTextStyleRule(textMarkupAttributes: [kCMTextMarkupAttribute_RelativeFontSize as String: NSNumber(value: percent)])]
    }
}

/// Dev round 2 (R2-09): AVAssetResourceLoaderDelegate that replays
/// proxied-scheme requests through a session built from
/// M3UParser.configuredSession()'s configuration (proxy + UA). All
/// state is touched on the main queue only (resourceLoader delegate
/// queue .main + URLSession delegateQueue .main), so the task map
/// needs no locking. Range requests are forwarded; a server that
/// answers 200 to a ranged request has its leading bytes skipped so
/// the delivered data still starts at the requested offset.
/// Cancellation on either side cancels the other. invalidate() must
/// be called at teardown: the URLSession retains this delegate, and
/// this delegate retains the session, so an un-invalidated pair leaks
/// as a unit after the caller drops its reference.
final class PlaybackResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    private var _session: URLSession?
    private var session: URLSession {
        if let existing = _session { return existing }
        let created = URLSession(configuration: M3UParser.configuredSession().configuration, delegate: self, delegateQueue: .main)
        _session = created
        return created
    }
    private struct InFlight {
        var task: URLSessionDataTask
        var loadingRequest: AVAssetResourceLoadingRequest
        var bytesToSkip: Int64
    }
    private var tasks: [Int: InFlight] = [:]

    func invalidate() {
        // Called from deinit as well as from main-actor teardown, so
        // it must be safe off the main thread too.
        if Thread.isMainThread { invalidateNow() } else { DispatchQueue.main.sync { self.invalidateNow() } }
    }
    private func invalidateNow() {
        _session?.invalidateAndCancel()
        _session = nil
        tasks.removeAll()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let requestURL = loadingRequest.request.url,
              let scheme = requestURL.scheme?.lowercased(),
              scheme == "nanohttp" || scheme == "nanohttps" else { return false }
        var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        components?.scheme = scheme == "nanohttp" ? "http" : "https"
        guard let restored = components?.url else { return false }
        var urlRequest = URLRequest(url: restored)
        var requestedOffset: Int64 = 0
        if let dataRequest = loadingRequest.dataRequest {
            requestedOffset = dataRequest.requestedOffset
            if dataRequest.requestsAllDataToEndOfResource {
                if requestedOffset > 0 { urlRequest.setValue("bytes=\(requestedOffset)-", forHTTPHeaderField: "Range") }
            } else {
                let end = requestedOffset + dataRequest.requestedLength - 1
                urlRequest.setValue("bytes=\(requestedOffset)-\(end)", forHTTPHeaderField: "Range")
            }
        }
        let task = session.dataTask(with: urlRequest)
        tasks[task.taskIdentifier] = InFlight(task: task, loadingRequest: loadingRequest, bytesToSkip: requestedOffset)
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        for (id, flight) in tasks where flight.loadingRequest == loadingRequest {
            flight.task.cancel()
            tasks.removeValue(forKey: id)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let flight = tasks[dataTask.taskIdentifier] else { completionHandler(.cancel); return }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        if status >= 400 {
            flight.loadingRequest.finishLoading(with: NSError(domain: "PlaybackProxy", code: status, userInfo: nil))
            tasks.removeValue(forKey: dataTask.taskIdentifier)
            completionHandler(.cancel)
            return
        }
        if let info = flight.loadingRequest.contentInformationRequest {
            if let mime = response.mimeType, let uti = UTType(mimeType: mime)?.identifier {
                info.contentType = uti
            } else if let ext = flight.loadingRequest.request.url?.pathExtension, let uti = UTType(filenameExtension: ext)?.identifier {
                info.contentType = uti
            }
            if status == 206, let range = http?.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last, let totalLength = Int64(total) {
                info.contentLength = totalLength
            } else if response.expectedContentLength > 0 {
                info.contentLength = response.expectedContentLength
            }
            info.isByteRangeAccessSupported = true
        }
        tasks[dataTask.taskIdentifier] = flight
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var flight = tasks[dataTask.taskIdentifier] else { return }
        var chunk = data
        if flight.bytesToSkip > 0 {
            let skip = Int(min(flight.bytesToSkip, Int64(chunk.count)))
            chunk = Data(chunk.dropFirst(skip))
            flight.bytesToSkip -= Int64(skip)
            tasks[dataTask.taskIdentifier] = flight
        }
        if !chunk.isEmpty { flight.loadingRequest.dataRequest?.respond(with: chunk) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let flight = tasks.removeValue(forKey: task.taskIdentifier) else { return }
        if let error { flight.loadingRequest.finishLoading(with: error) } else { flight.loadingRequest.finishLoading() }
    }
}

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
    // Dev round 6 (R6-09): last reported video presentation size, or
    // .zero before any frame. The detail page records it as the
    // channel's probed resolution; pure-audio streams stay .zero and
    // record nothing.
    @Published private(set) var videoSize: CGSize = .zero
    @Published var audioOptions: [String] = []
    @Published var videoOptions: [String] = []
    @Published var audioSelectedIndex: Int?
    @Published var videoSelectedIndex: Int?
    // Dev round 1: three-state latency (DEV-LAT), VOD position/duration
    // (DEV-PROGRESS), volume/rate (DEV-VOLUME/DEV-SPEED), subtitle
    // options (DEV-SUBTRACK) and failure classification (DEV-AVERR).
    @Published private(set) var latencyDisplay: LatencyDisplay = .sampling
    @Published private(set) var playbackPosition: Double = 0
    @Published private(set) var playbackDuration: Double = 0
    @Published private(set) var volume: Double = 1.0
    @Published private(set) var playbackRate: Double = 1.0
    @Published private(set) var subtitleOptions: [String] = []
    @Published private(set) var subtitleSelectedIndex: Int?
    @Published private(set) var failureKind: PlaybackFailureKind = .generic
    @Published private(set) var failureIsTimeout = false
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
    // Dev round 2 (R2-09): the proxy loader delegate for the current
    // item. The session must retain it (resourceLoader holds weakly);
    // it is invalidated on retry/stop/teardown/deinit (see the
    // delegate's own leak note).
    private var resourceLoaderDelegate: PlaybackResourceLoaderDelegate?
    // Dev round 2 (R2-02): last subtitle size applied, so a retry
    // rebuilds the item at the same size without re-reading defaults.
    private var subtitleSizePoints: Double = Self.storedSubtitleSize()
    // Dev round 1: legible subtitle group snapshot (DEV-SUBTRACK),
    // periodic position observer token (DEV-PROGRESS) and one-shot
    // engine-switch seek (DEV-ENGINESWITCH).
    private var legibleGroup: AVMediaSelectionGroup?
    private var timeObserverToken: Any?
    private let initialSeek: Double
    private var didApplyInitialSeek = false

    init(url: URL, bufferMilliseconds: Double, automaticAudioSelection: Bool, initialSeek: Double = 0) {
        self.automaticAudioSelection = automaticAudioSelection
        self.sourceURL = url
        self.bufferSeconds = max(bufferMilliseconds / 1000, 0)
        self.initialSeek = initialSeek
        // Dev round 2 (R2-09/R2-10/R2-02): proxy/UA applied via the
        // factory (plain item when neither is set); subtitle size
        // applied at creation and on every retry/change.
        let built = PlaybackItemFactory.makeItem(url: url)
        let item = built.item
        resourceLoaderDelegate = built.loaderDelegate
        item.preferredForwardBufferDuration = bufferSeconds
        item.textStyleRules = PlaybackItemFactory.subtitleTextStyleRules(sizePoints: subtitleSizePoints)
        player = AVPlayer(playerItem: item)
        currentItem = item
        super.init()
        observe(item: item)
        scheduleNotReadyTimeout()
        // Dev round 1 (DEV-PROGRESS): 1s position/duration report for
        // the progress bar and for engine-switch resume positions.
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let item = self.currentItem else { return }
                self.playbackPosition = item.currentTime().seconds
                let duration = item.duration.seconds
                self.playbackDuration = duration.isFinite && duration > 0 ? duration : 0
            }
        }
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
                    // Dev round 1 (DEV-ENGINESWITCH): VOD resume position
                    // from an engine switch, applied once on first ready.
                    if self.initialSeek > 0 && !self.didApplyInitialSeek {
                        self.didApplyInitialSeek = true
                        self.seek(to: self.initialSeek)
                    }
                case .failed:
                    // Dev round 1 (DEV-AVERR): classify before teardown
                    // (teardown clears the item); timeouts set their own
                    // flag in the timeout paths below, not here.
                    self.failureKind = PlaybackFailure.classify(item.error)
                    self.failureIsTimeout = false
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
                    // Dev round 6 (R6-09): publish the real frame size
                    // for the probe record; .zero is never published.
                    self.videoSize = item.presentationSize
                    self.videoCheckTask?.cancel()
                }
            }
        }
    }

    /// A stream stuck before readyToPlay previously spun forever: no
    /// timeout, no failure, no KS fallback. After the timeout it now
    /// falls back.
    /// Dev round 8 (R8-10): the timeout is user-adjustable (settings,
    /// default 15s, clamped 5...60s), read live like the subtitle
    /// size below so a change applies to the next item.
    private static func storedNotReadyTimeout() -> Double {
        let value = UserDefaults.standard.double(forKey: "nanostream.playbackNotReadyTimeout")
        return value > 0 ? min(max(value, 5), 60) : 15
    }

    private func scheduleNotReadyTimeout() {
        notReadyTask?.cancel()
        let seconds = Self.storedNotReadyTimeout()
        notReadyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                if self.player.currentItem?.status != .readyToPlay && !self.didFail {
                    // Dev round 1 (DEV-AVERR): the not-ready path is
                    // a timeout, not a generic failure.
                    self.failureKind = .timeout
                    self.failureIsTimeout = true
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
        // Dev round 2 (R2-09): same as stop() — the failed item's proxy
        // loads must not keep fetching after the item is gone.
        resourceLoaderDelegate?.invalidate()
        resourceLoaderDelegate = nil
        didFail = true
        isBuffering = false
        // Round-7 fix (B02): the round-6 latency cleanup only covered
        // KS's resetForRebuild; AV's teardown left the previous stream's
        // last latency value on screen until the next sample.
        latencyDisplay = .sampling
    }

    private func cancelAllTasks() {
        infoTask?.cancel(); videoCheckTask?.cancel(); optionsTask?.cancel(); latencyTask?.cancel(); notReadyTask?.cancel()
        infoTask = nil; videoCheckTask = nil; optionsTask = nil; latencyTask = nil; notReadyTask = nil
    }

    func play() {
        if didFail { retry(); return }
        // Round-4 fix (B01/B04): a background stop leaves currentItem
        // nil, so a plain player.play() is a no-op on return; rebuild
        // via retry(). Also re-arm the not-ready timeout from play()
        // instead of only from init (B04): the item starts loading at
        // init, but play() is the user-visible start of playback.
        if currentItem == nil { retry(); return }
        scheduleNotReadyTimeout()
        userPaused = false
        player.play()
        // Dev round 1 (DEV-SPEED): play() resets the rate to the
        // default, so re-apply the user's rate after every play.
        player.rate = Float(playbackRate)
    }

    /// Dev round 2 (R2-02): apply the slider value to the current
    /// item immediately; a nil item (failed/stopped) just records the
    /// value for the next item built by init/retry.
    func applySubtitleSize(_ points: Double) {
        subtitleSizePoints = points
        if let item = currentItem {
            item.textStyleRules = PlaybackItemFactory.subtitleTextStyleRules(sizePoints: points)
        }
    }

    /// Dev round 2 (R2-02): stored slider value, 18 when unset (the
    /// settings default). A stored 0 or less is treated as unset.
    private static func storedSubtitleSize() -> Double {
        let value = UserDefaults.standard.double(forKey: "subtitleFontSize")
        return value > 0 ? value : 18
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
        latencyDisplay = .sampling
        // Dev round 1: failure classification and subtitle options
        // reset with the item (readyToPlay rebuilds both).
        failureKind = .generic
        failureIsTimeout = false
        subtitleOptions = []
        subtitleSelectedIndex = nil
        legibleGroup = nil
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
        // Dev round 2 (R2-09/R2-10/R2-02): rebuild through the
        // factory so proxy/UA/subtitle size survive a retry; the old
        // loader delegate is invalidated first so its session cannot
        // leak or keep fetching for a dead item.
        resourceLoaderDelegate?.invalidate()
        let built = PlaybackItemFactory.makeItem(url: sourceURL)
        let item = built.item
        resourceLoaderDelegate = built.loaderDelegate
        item.preferredForwardBufferDuration = bufferSeconds
        item.textStyleRules = PlaybackItemFactory.subtitleTextStyleRules(sizePoints: subtitleSizePoints)
        player.replaceCurrentItem(with: item)
        currentItem = item
        observe(item: item)
        scheduleNotReadyTimeout()
        player.play()
        player.rate = Float(playbackRate)
    }

    /// Dev round 10 (D-01): the lab "enhanced system player" retry.
    /// Same rebuild as retry(), except the item is a plain
    /// AVPlayerItem(url:) — no proxy resource loader, no custom UA
    /// header. That is the "compatible path": some streams fail
    /// exactly because of the loader or the header, and a plain item
    /// plays them. Called at most once per failure by the view (see
    /// enhancedRetried); a second failure shows the normal error.
    func retryWithCompatItem() {
        cancelAllTasks()
        userPaused = false
        didFail = false
        isBuffering = true
        latencyDisplay = .sampling
        failureKind = .generic
        failureIsTimeout = false
        subtitleOptions = []
        subtitleSelectedIndex = nil
        legibleGroup = nil
        audioOptions = []
        videoOptions = []
        audioGroupOptions = []
        audioGroup = nil
        audioSelectedIndex = nil
        videoSelectedIndex = nil
        streamInfo = ""
        fallbackStoppedPiP = false
        resourceLoaderDelegate?.invalidate()
        resourceLoaderDelegate = nil
        let item = AVPlayerItem(url: sourceURL)
        item.preferredPeakBitRate = PlaybackItemFactory.globalBitrateCap()
        item.preferredForwardBufferDuration = bufferSeconds
        item.textStyleRules = PlaybackItemFactory.subtitleTextStyleRules(sizePoints: subtitleSizePoints)
        player.replaceCurrentItem(with: item)
        currentItem = item
        observe(item: item)
        scheduleNotReadyTimeout()
        player.play()
        player.rate = Float(playbackRate)
    }

    func stop() {
        cancelAllTasks()
        userPaused = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        // Dev round 2 (R2-09): a stopped item's proxy loads stop too;
        // play() after stop() rebuilds via retry(), which makes a fresh
        // delegate, so nothing here depends on the old one surviving.
        resourceLoaderDelegate?.invalidate()
        resourceLoaderDelegate = nil
        // Round-7 fix (B02): stop() cancels the latency sampling task,
        // so without this the badge froze on the stopped stream's last
        // value (notably for a paused session returning from background
        // without a rebuild).
        latencyDisplay = .sampling
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
            player.rate = Float(playbackRate)
            // Round-4 fix (B02): a pause inside the 8s window used to
            // swallow the video check forever. Resuming re-arms it, so
            // a still-pictureless stream still falls back after 8s.
            if let item = currentItem { scheduleVideoCheck(for: item) }
        }
    }
    func toggleMute() { isMuted.toggle(); player.isMuted = isMuted }

    /// Dev round 1 (DEV-VOLUME): slider value (mute stays separate).
    func setVolume(_ value: Double) {
        volume = value
        player.volume = Float(value)
    }

    /// Dev round 1 (DEV-SPEED): VOD only (the menu is disabled for
    /// live). The rate is re-applied after every play() because play()
    /// resets the rate to the default.
    func setRate(_ rate: Double) {
        playbackRate = rate
        if player.timeControlStatus == .playing { player.rate = Float(rate) }
    }

    /// Dev round 1 (DEV-PROGRESS/DEV-GESTURE): VOD seek.
    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// Dev round 1 (DEV-SUBTRACK): nil turns subtitles off.
    func selectSubtitle(_ index: Int?) {
        guard let item = currentItem, let group = legibleGroup else { return }
        if let index, group.options.indices.contains(index) {
            item.select(group.options[index], in: group)
            subtitleSelectedIndex = index
        } else {
            item.select(nil, in: group)
            subtitleSelectedIndex = nil
        }
    }

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
            // Dev round 1 (DEV-SUBTRACK): legible subtitle group, same
            // snapshot pattern as the audible group above.
            if let legible = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
                let names = legible.options.enumerated().map { index, option in
                    let display = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    return display.isEmpty ? "Subtitle \(index + 1)" : display
                }
                let selected = legible.options.firstIndex(where: { $0 == item.currentMediaSelection.selectedMediaOption(in: legible) })
                await MainActor.run {
                    self.legibleGroup = legible
                    self.subtitleOptions = names
                    self.subtitleSelectedIndex = selected
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
                // Dev round 1 (DEV-LAT): nil keeps the last display
                // (a paused player must not collapse to unavailable);
                // a playing player with no window reports unsupported.
                let display: LatencyDisplay? = {
                    guard self.player.timeControlStatus == .playing else { return nil }
                    guard let range = item.seekableTimeRanges.last?.timeRangeValue,
                          range.isValid,
                          range.duration.isNumeric,
                          let current = self.player.currentItem?.currentTime(),
                          current.isNumeric else { return .unsupported }
                    let seconds = range.end.seconds - current.seconds
                    guard seconds >= 0, seconds.isFinite else { return .unsupported }
                    return .milliseconds(Int((seconds * 1000).rounded()))
                }()
                await MainActor.run { if let display { self.latencyDisplay = display } }
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
                    // Dev round 1 (DEV-AVERR): the 8s no-picture path
                    // is a timeout, not a generic failure.
                    self.failureKind = .timeout
                    self.failureIsTimeout = true
                    self.teardownForFallback()
                }
            } catch {
                // A network stream can delay track discovery; leave it to AVPlayer rather than failing on metadata alone.
            }
        }
    }

    private static func codecName(for descriptions: [Any]) -> String? {
        guard let first = descriptions.first else { return nil }
        // Compile-fix round 2: a conditional downcast (`as?`) to the
        // Core Foundation type CMFormatDescription is rejected (it is
        // treated as always succeeding), and a plain `as` is rejected
        // because `first` is `Any`. Keep the original intent — return
        // nil for a non-CMFormatDescription — with an `is` check
        // followed by the compiler-suggested forced cast, which cannot
        // fail after the check above.
        guard first is CMFormatDescription else { return nil }
        let description = first as! CMFormatDescription
        let code = CMFormatDescriptionGetMediaSubType(description)
        let bytes: [UInt8] = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    deinit {
        // Defensive only: stop() is the real teardown path and is always
        // called from onDisappear (except when PiP is active). A @MainActor
        // deinit is not isolated, so this does the minimum safe cleanup.
        statusObservation?.invalidate(); timeObservation?.invalidate(); sizeObservation?.invalidate()
        // Compile-fix round: deinit is nonisolated and cannot call the
        // MainActor-isolated cancelAllTasks(), but deinit may access
        // the instance's own stored properties, so the two
        // cancellation statements are inlined here (identical effect).
        infoTask?.cancel(); videoCheckTask?.cancel(); optionsTask?.cancel(); latencyTask?.cancel(); notReadyTask?.cancel()
        infoTask = nil; videoCheckTask = nil; optionsTask = nil; latencyTask = nil; notReadyTask = nil
        if let token = timeObserverToken { player.removeTimeObserver(token) }
        pipController?.delegate = nil; player.pause(); player.replaceCurrentItem(with: nil)
        // Dev round 2 (R2-09): break the delegate/session retain pair
        // (invalidate() is main-safe from this nonisolated deinit).
        resourceLoaderDelegate?.invalidate(); resourceLoaderDelegate = nil
    }
}

extension AVPlaybackSession: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}
    // Compile-fix round: these delegate methods are nonisolated, but
    // the session is @MainActor-isolated, so capturing self in a plain
    // Task closure is rejected. `Task { @MainActor [weak self] in }`
    // is the pattern this file already uses elsewhere (e.g. the
    // latency/timeout tasks) and keeps the hop on the main actor.
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { Task { @MainActor [weak self] in self?.isPiPActive = true } }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { Task { @MainActor [weak self] in self?.isPiPActive = false } }
    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { Task { @MainActor [weak self] in guard let self else { return }; self.isPiPActive = false; if self.viewDetached { self.stop() } } }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { completionHandler(true) }
}

/// Dev round 6 (R6-02): favorites management. Favorites carry no
/// timestamp (they are a plain id set), so the deterministic sort
/// rule is by name or by group-then-name — never by an invented
/// "favorited at" order. Batch delete removes only the selected ids.
private enum FavoriteSortMode: String, CaseIterable {
    case name = "按名称排序", group = "按分组排序"
}

struct FavoritesView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedDetail: Channel?
    @State private var groupFilter = GroupID.all
    @State private var sortMode = FavoriteSortMode.name
    @State private var isEditing = false
    @State private var selection: Set<String> = []
    @State private var showDeleteConfirm = false

    private var groups: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for channel in state.favoriteChannels where seen.insert(channel.group).inserted { ordered.append(channel.group) }
        return ordered.sorted()
    }

    private var filteredChannels: [Channel] {
        let base = groupFilter == GroupID.all ? state.favoriteChannels : state.favoriteChannels.filter { $0.group == groupFilter }
        switch sortMode {
        case .name: return base.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .group: return base.sorted {
            if $0.group != $1.group { return $0.group < $1.group }
            return $0.name.localizedCompare($1.name) == .orderedAscending
        }
        }
    }

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
                    HStack(spacing: 10) {
                        Menu {
                            Button { groupFilter = GroupID.all } label: { Label(state.localized("全部"), systemImage: groupFilter == GroupID.all ? "checkmark" : "rectangle.stack") }
                            ForEach(groups, id: \.self) { group in
                                Button { groupFilter = group } label: { Label(state.localizedGroup(group), systemImage: groupFilter == group ? "checkmark" : "rectangle.stack") }
                            }
                        } label: {
                            Text(groupFilter == GroupID.all ? state.localized("全部") : state.localizedGroup(groupFilter)).font(.subheadline).foregroundStyle(state.accent)
                        }.buttonStyle(.plain)
                        Menu {
                            ForEach(FavoriteSortMode.allCases, id: \.self) { mode in
                                Button { sortMode = mode } label: { Label(state.localized(mode.rawValue), systemImage: sortMode == mode ? "checkmark" : "arrow.up.arrow.down") }
                            }
                        } label: {
                            Text(state.localized(sortMode.rawValue)).font(.subheadline).foregroundStyle(state.accent)
                        }.buttonStyle(.plain)
                        Spacer()
                        Button(state.localized(isEditing ? "完成" : "编辑")) { isEditing.toggle(); if !isEditing { selection.removeAll() } }.font(.subheadline).foregroundStyle(state.accent)
                    }.padding(.horizontal, 22).padding(.top, 16)
                    if isEditing {
                        HStack {
                            Text("\(state.localized("删除所选")) (\(selection.count))").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Button(state.localized("删除所选")) { showDeleteConfirm = true }.font(.subheadline).foregroundStyle(.red).disabled(selection.isEmpty)
                        }.padding(.horizontal, 22).padding(.top, 12)
                        .alert(state.localized("删除所选"), isPresented: $showDeleteConfirm) {
                            Button(state.localized("删除"), role: .destructive) {
                                // Intersect with live favorites: a card
                                // unfavorited via its star while selected
                                // is already gone and must not be
                                // re-removed.
                                let live = Set(state.favoriteChannels.map(\.id))
                                state.removeFavorites(selection.intersection(live))
                                selection.removeAll()
                            }
                            Button(state.localized("关闭"), role: .cancel) {}
                        } message: { Text(state.localized("确定删除所选收藏吗？该操作无法撤销。")) }
                    }
                    LazyVStack(spacing: 12) {
                        ForEach(filteredChannels) { channel in
                            HStack(alignment: .top, spacing: 8) {
                                if isEditing {
                                    Button { if selection.contains(channel.id) { selection.remove(channel.id) } else { selection.insert(channel.id) } } label: {
                                        Image(systemName: selection.contains(channel.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(state.accent).font(.title3)
                                    }.buttonStyle(.plain).padding(.top, 8)
                                }
                                ChannelCard(channel: channel) {
                                    if isEditing {
                                        if selection.contains(channel.id) { selection.remove(channel.id) } else { selection.insert(channel.id) }
                                    } else {
                                        state.play(channel); selectedDetail = channel
                                    }
                                }
                            }
                        }
                    }.padding(.horizontal, 22).padding(.top, 16)
                }
            }.padding(.bottom, 110)
        }
        .fullScreenCover(item: $selectedDetail) { ChannelDetailView(channel: $0) }
    }
}

/// Dev round 6 (R6-04): guide overview, outside the detail page's
/// program tab. One row per merged home channel: the programme now
/// and the next one, from the same guide data as the cards. Empty
/// when the guide has none — never fabricated. A tap opens the
/// channel's detail page.
struct EPGOverviewView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedDetail: Channel?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text(state.localized("节目总览")).font(.system(size: 31, weight: .bold)).padding(.horizontal, 28).padding(.top, 62)
                if state.isLoadingEPG {
                    ProgressView().tint(state.accent).padding(.top, 42).frame(maxWidth: .infinity)
                } else if state.homeChannels.isEmpty {
                    Text(state.localized("暂无频道")).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.top, 28)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(state.homeChannels) { channel in
                            Button { selectedDetail = channel } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8).fill(Color.black).frame(width: 64, height: 48)
                                        if let logoURL = channel.logoURL {
                                            AsyncImage(url: logoURL) { phase in if let image = phase.image { image.resizable().scaledToFit().padding(6) } else { Image(systemName: "tv").foregroundStyle(.secondary) } }
                                        } else { Image(systemName: "tv").foregroundStyle(.secondary) }
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(channel.name).font(.headline).lineLimit(1)
                                        if let current = state.currentProgram(for: channel) {
                                            Text("\(state.localized("当前节目"))  \(current.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        if let next = state.nextProgram(for: channel) {
                                            Text("\(state.localized("下一节目"))  \(Self.timeFormatter.string(from: next.start))  \(next.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        if state.currentProgram(for: channel) == nil && state.nextProgram(for: channel) == nil {
                                            Text(state.localized("暂无节目数据")).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(10).background(Color.card, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(state.accent.opacity(0.25), lineWidth: 1)).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 22).padding(.top, 28)
                }
            }.padding(.bottom, 110)
        }
        .fullScreenCover(item: $selectedDetail) { ChannelDetailView(channel: $0) }
    }
}

/// Dev round 4 (R4-11): the no-channel empty state now offers an
/// action (open the add-playlist sheet) instead of text alone. The
/// filtered-empty state (group/search with no match) is a different
/// state with its own "clear filter" button and is untouched.
struct EmptyHomeState: View {
    @EnvironmentObject private var state: AppState
    let onAddPlaylist: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 44, weight: .thin)).foregroundStyle(.secondary)
            Text(state.localized("暂无频道")).font(.title3.bold())
            Text(state.localized("请先在“播放列表”中添加 M3U 或 Xtream 来源。")).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(state.localized("添加播放列表")) { onAddPlaylist() }.buttonStyle(.bordered).tint(state.accent).padding(.top, 4)
        }.padding(.top, 72).padding(.horizontal, 28)
    }
}

/// Dev round 4 (R4-09): independent history page. Rows reuse the
/// R2-17 time/progress data: watch time when recorded, VOD progress
/// fraction when reported; live entries and migrated entries without
/// data render no time/progress, never a fabricated one. Single
/// delete is swipe-to-delete; clear-all confirms first with the
/// existing settings confirmation wording.
struct HistoryView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirm = false

    /// Only entries that still resolve to a channel are listed, so a
    /// removed channel never leaves a dead row; deletion maps back
    /// through this same list, never through raw indices.
    private var entries: [RecentEntry] {
        state.recent.filter { state.channel(for: $0.channelID) != nil }
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    Text(state.localized("暂无播放记录")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(entries, id: \.channelID) { entry in
                            if let channel = state.channel(for: entry.channelID) {
                                Button { state.play(channel); dismiss() } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 8).fill(Color.black).frame(width: 64, height: 48)
                                            if let logoURL = channel.logoURL {
                                                AsyncImage(url: logoURL) { phase in if let image = phase.image { image.resizable().scaledToFit().padding(6) } else { Image(systemName: "tv").foregroundStyle(.secondary) } }
                                            } else { Image(systemName: "tv").foregroundStyle(.secondary) }
                                        }
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(channel.name).font(.headline).lineLimit(1)
                                            if let watchedAt = entry.watchedAt { Text(RecentRail.timeString(for: watchedAt)).font(.caption).foregroundStyle(.secondary) }
                                            if let progress = entry.progress {
                                                HStack(spacing: 6) {
                                                    ProgressView(value: progress).frame(width: 80)
                                                    Text("\(state.localized("进度")) \(Int((progress * 100).rounded()))%").font(.caption).foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                        Spacer()
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { state.removeHistoryEntry(channelID: entries[index].channelID) }
                        }
                    }
                }
            }
            .navigationTitle(state.localized("历史"))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(state.localized("清除")) { showClearConfirm = true }.disabled(entries.isEmpty)
                }
            }
            .alert(state.localized("清除播放历史"), isPresented: $showClearConfirm) {
                Button(state.localized("清除"), role: .destructive) { state.clearHistory() }
                Button(state.localized("关闭"), role: .cancel) {}
            } message: {
                Text(state.localized("确定清除全部播放历史吗？该操作无法撤销。"))
            }
        }
    }
}

/// Dev round 4 (R4-07): one status line shared by the detail
/// subscription rows and the playlist rows: refresh state for the
/// actively loading playlist, its load error when one exists, else
/// the last refresh time (or "never refreshed" when the source never
/// supplied one). No expiry is shown: no source field carries one.
private struct PlaylistStatusText: View {
    @EnvironmentObject private var state: AppState
    let playlist: Playlist
    var body: some View {
        Group {
            if playlist.id == state.activePlaylistID && (state.isLoadingPlaylist || state.isRefreshingPlaylist) {
                Text(state.localized("刷新中")).font(.caption).foregroundStyle(.secondary)
            } else if playlist.id == state.activePlaylistID, let error = state.playlistError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let last = playlist.lastRefresh {
                Text("\(state.localized("上次刷新")) \(Self.dateString(for: last))").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(state.localized("未刷新")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Same day rule as the history rail: today renders HH:mm,
    /// older entries MM-dd HH:mm. No relative text is invented.
    private static func dateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

struct PlaylistsView: View {
    @EnvironmentObject private var state: AppState
    @Binding var showAdd: Bool
    @State private var editingPlaylist: Playlist?
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Button { state.refreshPlaylists() } label: { Image(systemName: "arrow.clockwise").font(.title2).foregroundStyle(state.accent) }.buttonStyle(.plain); Spacer(); if state.isRefreshingAllPlaylists { ProgressView().tint(state.accent) } else { Button(state.localized("全部刷新")) { state.refreshAllPlaylists() }.buttonStyle(.bordered).tint(state.accent).disabled(state.playlists.isEmpty) }; Button { showAdd = true } label: { Image(systemName: "plus").font(.title2).foregroundStyle(state.accent) }.buttonStyle(.plain) }.padding(.horizontal, 28).padding(.top, 54)
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

// Dev round 8 (R8-04/R8-05/R8-06/R8-07): the config center — one
// management hub for every playlist, so it can never disagree with
// the playlist page: both call the same AppState methods (enable,
// move, delete, add/edit form). Rows show the service type from
// PlaylistKind (M3U / Xtream / tvHeadend); a source without service
// information keeps its kind, never a fabricated type. Import and
// export live here too; passwords are never exported (see
// AppState.importConfiguration), and every skipped import entry is
// reported instead of silently dropped.
struct ConfigCenterView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    @State private var editingPlaylist: Playlist?
    @State private var deleteTarget: Playlist?
    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var showImportAlert = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(state.localized("配置中心")).font(.system(size: 24, weight: .bold)).padding(.top, 8)
                    Text(state.localized("密码不会随配置导出，导入后需重新填写。")).font(.caption).foregroundStyle(.secondary)
                    // Playlists, in the same order as the playlist page.
                    ForEach(Array(state.playlists.enumerated()), id: \.element.id) { index, playlist in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playlist.name).font(.headline).lineLimit(1)
                                Text("\(playlist.channelCount) \(state.localized("频道")) · \(playlist.kind.rawValue)").font(.caption).foregroundStyle(.secondary)
                                PlaylistStatusText(playlist: playlist)
                            }
                            Spacer()
                            Toggle(isOn: Binding(get: { playlist.isEnabled }, set: { state.setPlaylistEnabled(playlist, $0) })) {
                                Text(state.localized("启用")).font(.caption).foregroundStyle(.secondary)
                            }.labelsHidden().tint(state.accent)
                            VStack(spacing: 2) {
                                Button { state.movePlaylist(from: index, to: index - 1) } label: { Image(systemName: "chevron.up").font(.caption) }.buttonStyle(.plain).disabled(index == 0)
                                Button { state.movePlaylist(from: index, to: index + 1) } label: { Image(systemName: "chevron.down").font(.caption) }.buttonStyle(.plain).disabled(index == state.playlists.count - 1)
                            }.foregroundStyle(state.accent)
                            Button { editingPlaylist = playlist } label: { Image(systemName: "pencil").foregroundStyle(state.accent) }.buttonStyle(.plain)
                            Button { deleteTarget = playlist } label: { Image(systemName: "trash").foregroundStyle(.red) }.buttonStyle(.plain)
                        }.padding(14).background(Color.card, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16)
                    }
                    Button { showAdd = true } label: { Label(state.localized("添加播放列表"), systemImage: "plus") }.buttonStyle(.bordered).tint(state.accent).padding(.horizontal, 16)
                    // Group management (R8-07): hide only affects home
                    // display; order persists. Hidden groups stay listed
                    // here so they can be shown again.
                    VStack(alignment: .leading, spacing: 10) {
                        Text(state.localized("分组管理")).font(.headline)
                        if state.manageableGroups.isEmpty {
                            Text(state.localized("暂无频道")).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Array(state.manageableGroups.enumerated()), id: \.element) { index, group in
                            HStack {
                                Text(state.localizedGroup(group)).font(.subheadline)
                                Spacer()
                                VStack(spacing: 2) {
                                    Button {
                                        var order = state.manageableGroups
                                        order.remove(at: index); order.insert(group, at: index - 1)
                                        state.setGroupOrder(order)
                                    } label: { Image(systemName: "chevron.up").font(.caption) }.buttonStyle(.plain).disabled(index == 0)
                                    Button {
                                        var order = state.manageableGroups
                                        order.remove(at: index); order.insert(group, at: index + 1)
                                        state.setGroupOrder(order)
                                    } label: { Image(systemName: "chevron.down").font(.caption) }.buttonStyle(.plain).disabled(index == state.manageableGroups.count - 1)
                                }.foregroundStyle(state.accent)
                                Button(state.localized(state.hiddenGroups.contains(group) ? "显示" : "隐藏")) {
                                    state.setGroupHidden(group, !state.hiddenGroups.contains(group))
                                }.buttonStyle(.bordered).tint(state.accent)
                            }
                        }
                    }.padding(14).background(Color.card, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16)
                    // Import / export (R8-05).
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Button(state.localized("导出配置")) {
                                if let data = state.exportConfigurationData(),
                                   let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                                    let url = dir.appendingPathComponent("nanostream-config.json")
                                    if (try? data.write(to: url)) != nil { exportURL = url }
                                }
                            }.buttonStyle(.bordered).tint(state.accent)
                            Button(state.localized("导入配置")) { showImporter = true }.buttonStyle(.bordered).tint(state.accent)
                        }
                        if let url = exportURL {
                            ShareLink(item: url) { Label(state.localized("分享配置文件"), systemImage: "square.and.arrow.up") }.buttonStyle(.bordered).tint(state.accent)
                        }
                    }.padding(14).background(Color.card, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16)
                }.padding(.bottom, 40)
            }
            .background(Color.appBackground)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(state.localized("关闭")) { dismiss() } } }
        }
        .sheet(isPresented: $showAdd) { PlaylistFormView() }
        .sheet(item: $editingPlaylist) { playlist in PlaylistFormView(editingPlaylist: playlist) }
        .alert(state.localized("删除播放列表"), isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button(state.localized("删除"), role: .destructive) { if let target = deleteTarget { state.removePlaylist(target) }; deleteTarget = nil }
            Button(state.localized("关闭"), role: .cancel) { deleteTarget = nil }
        } message: {
            Text("\(state.localized("确定删除播放列表吗？该操作无法撤销。")) “\(deleteTarget?.name ?? "")”")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .failure(let error):
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError { break }
                importMessage = state.localized("文件读取失败。")
                showImportAlert = true
            case .success(let urls):
                guard let fileURL = urls.first else { importMessage = state.localized("文件读取失败。"); showImportAlert = true; return }
                guard fileURL.startAccessingSecurityScopedResource() else { importMessage = state.localized("文件读取失败。"); showImportAlert = true; return }
                defer { fileURL.stopAccessingSecurityScopedResource() }
                guard let data = try? Data(contentsOf: fileURL) else { importMessage = state.localized("文件读取失败。"); showImportAlert = true; return }
                let outcome = state.importConfiguration(data)
                var lines: [String] = ["\(state.localized("已导入播放列表："))\(outcome.added)"]
                if outcome.added > 0 { lines.append("\(state.localized("配置导入后请点“全部刷新”加载频道。"))") }
                for (name, reason) in outcome.failures { lines.append("\(name)：\(reason)") }
                if outcome.added == 0, outcome.failures.isEmpty { lines.append(state.localized("文件格式无效。")) }
                importMessage = lines.joined(separator: "\n")
                showImportAlert = true
            }
        }
        .alert(state.localized("导入配置"), isPresented: $showImportAlert) {
            Button(state.localized("关闭"), role: .cancel) {}
        } message: { Text(importMessage ?? "") }
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
                // Dev round 4 (R4-07): same status line as the detail
                // subscription rows (last refresh / refresh / error).
                PlaylistStatusText(playlist: playlist)
            }
            Spacer()
            // Dev round 2 (R2-12): per-playlist home switch. Disabling
            // removes the playlist from home merged browsing and search
            // only — favorites, history and per-playlist detail browsing
            // are unaffected.
            Toggle(isOn: Binding(get: { playlist.isEnabled }, set: { state.setPlaylistEnabled(playlist, $0) })) {
                Text(state.localized("启用")).font(.caption).foregroundStyle(.secondary)
            }.labelsHidden().tint(state.accent)
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
        // Dev round 10 (D-03): UIColor does not exist on macOS;
        // NSColor is the equivalent there. iOS/tvOS/visionOS keep
        // the existing behaviour.
        #if canImport(UIKit)
        return Color(UIColor { trait in trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        #elseif canImport(AppKit)
        return Color(NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        }))
        #else
        return dark
        #endif
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
