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

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            Group {
                switch tab {
                case .home: HomeView()
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
                        Circle().fill(tab == item ? Color.neon : .clear).frame(width: 4, height: 4)
                    }
                    .foregroundStyle(tab == item ? state.accent : .white.opacity(0.58))
                    .frame(maxWidth: .infinity)
                }.buttonStyle(.plain)
            }
        }
        .padding(.top, 12).padding(.bottom, 9).padding(.horizontal, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.neon.opacity(0.28), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        .padding(.horizontal, 32).padding(.bottom, 10)
    }
}

struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedDetail: Channel?
    @State private var showGroups = false

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
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(state.groups, id: \.self) { group in
                            Button { state.selectedGroup = group; withAnimation { showGroups = false } } label: {
                                HStack { Text(group); Spacer(); if state.selectedGroup == group { Image(systemName: "checkmark").foregroundStyle(state.accent) } }
                                    .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(state.accent.opacity(0.5), lineWidth: 1))
                    .padding(.horizontal, 22).padding(.top, 8)
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.55))
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
                if state.isLoadingPlaylist {
                    ProgressView().tint(state.accent).padding(.top, 42)
                } else if state.channels.isEmpty {
                    EmptyHomeState()
                } else {
                    RecentRail { channel in state.play(channel); selectedDetail = channel }.padding(.top, 23)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: state.gridLayout.columns), spacing: 12) {
                        ForEach(state.visibleChannels) { channel in ChannelCard(channel: channel, compact: state.gridLayout == .fourColumns) { state.play(channel); selectedDetail = channel } }
                    }.padding(.horizontal, 22).padding(.top, 17).padding(.bottom, 110)
                }
            }
        }
        .fullScreenCover(item: $selectedDetail) { channel in ChannelDetailView(channel: channel) }
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
                                ZStack { RoundedRectangle(cornerRadius: 12).fill(Color.cardInner); Text(channel.name).font(.system(size: 11, weight: .bold)).multilineTextAlignment(.center).padding(7) }.frame(width: 112, height: 90)
                                Text(channel.name).font(.caption).lineLimit(1).frame(width: 112, alignment: .leading)
                            }.padding(9).background(Color.card, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.neon.opacity(0.25), lineWidth: 1)).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if state.recent.isEmpty { Text(state.localized("暂无播放记录")).foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 22) }
                }.padding(.horizontal, 22)
            }
        }
    }
}

@MainActor
private final class PreviewSessionPool {
    static let shared = PreviewSessionPool()
    private let limit = 4
    private var active: Set<String> = []

    func acquire(_ id: String) -> Bool {
        if active.contains(id) { return true }
        guard active.count < limit else { return false }
        active.insert(id)
        return true
    }

    func release(_ id: String) { active.remove(id) }
}

@MainActor
private final class PreviewPlayerModel: NSObject, ObservableObject {
    let player: AVPlayer
    @Published private(set) var latencyMilliseconds: Int?
    private var timer: Timer?

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        super.init()
    }

    func start() {
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
        player.pause()
        player.replaceCurrentItem(with: nil)
        latencyMilliseconds = nil
    }

    private func sampleLatency() {
        guard let item = player.currentItem,
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

    deinit { timer?.invalidate(); player.pause() }
}

private struct LivePreviewView: View {
    @EnvironmentObject private var state: AppState
    let channel: Channel
    @StateObject private var model: PreviewPlayerModel
    @State private var acquired = false

    init(channel: Channel) {
        self.channel = channel
        _model = StateObject(wrappedValue: PreviewPlayerModel(url: channel.streamURL!))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if acquired {
                PreviewPlayerLayerView(player: model.player)
                if state.showLatency { StreamLatencyBadge(milliseconds: model.latencyMilliseconds) }
            } else {
                Color.black
                Text("预览连接数已达上限").font(.caption2).foregroundStyle(.white.opacity(0.55)).padding(8)
            }
        }
        .onAppear {
            acquired = PreviewSessionPool.shared.acquire(channel.id)
            if acquired { model.start() }
        }
        .onDisappear {
            if acquired { model.stop(); PreviewSessionPool.shared.release(channel.id); acquired = false }
        }
    }
}

private struct PreviewPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
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
    let milliseconds: Int?
    var body: some View {
        Text(milliseconds.map { "\($0) ms" } ?? "延迟不可用")
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
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8).fill(Color.black).frame(height: 112)
                        if state.previewEnabled, channel.streamURL != nil {
                            LivePreviewView(channel: channel)
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
                    Text(channel.group).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(state.accent.opacity(0.38), lineWidth: 1))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { state.toggleFavorite(channel) } label: {
                Image(systemName: state.favorites.contains(channel.id) ? "star.fill" : "star").foregroundStyle(.white.opacity(0.85)).frame(width: 36, height: 36)
            }.buttonStyle(.plain).padding(10)
        }
    }

    private var fallbackLogo: some View {
        Text(channel.name.contains("FOX") ? "FOX" : channel.name.prefix(1).uppercased())
            .font(.system(size: channel.name.contains("FOX") ? 45 : 30, weight: .heavy))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ChannelDetailView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let channel: Channel
    @State private var activeChannel: Channel
    @State private var mode = "频道"
    @State private var search = ""
    @State private var showGroups = false
    @State private var showInfo = false
    @State private var streamInfo = ""
    @State private var playerReady = true

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
                    if playerReady, let url = activeChannel.streamURL {
                        PlayerSurface(url: url, title: activeChannel.name, engine: state.preferredPlayer, bufferMilliseconds: state.networkBufferMilliseconds, allowsPictureInPicture: state.pictureInPicture, hardwareAcceleration: state.hardwareAcceleration, automaticAudioSelection: state.automaticAudioSelection, showLatency: state.showLatency, streamInfo: $streamInfo).id(activeChannel.id)
                    } else {
                        Color.black
                        ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Text("LIVE").font(.caption.bold()).foregroundStyle(state.accent).padding(8)
                }.frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(state.accent.opacity(0.7), lineWidth: 1)).padding(.horizontal, 16)
                Picker("", selection: $mode) { Text(state.localized("订阅")).tag("订阅"); Text(state.localized("频道")).tag("频道"); Text(state.localized("节目")).tag("节目") }.pickerStyle(.segmented).padding(.horizontal, 18).padding(.vertical, 12)
                ScrollView(showsIndicators: false) {
                    detailContent
                        .padding(.bottom, 110)
                }
            }
        }
        .onAppear {
            if state.selectedChannel?.id != activeChannel.id { state.play(activeChannel) }
        }
        .alert(state.localized("编码信息"), isPresented: $showInfo) { Button(state.localized("关闭"), role: .cancel) {} } message: { Text(streamInfo.isEmpty ? state.localized("暂无数据") : streamInfo) }
    }

    private var detailChannels: [Channel] {
        state.channels.filter { item in
            (state.selectedGroup == "全部" || item.group == state.selectedGroup) &&
            (search.isEmpty || item.name.localizedCaseInsensitiveContains(search))
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch mode {
        case "订阅":
            if state.isLoadingPlaylist { ProgressView().tint(state.accent).padding(.top, 28) }
            ForEach(state.playlists) { playlist in
                Button { state.activatePlaylist(playlist) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.stack.fill").foregroundStyle(state.accent).frame(width: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playlist.name).font(.headline)
                            Text("\(playlist.channelCount) \(state.localized("频道")) · \(playlist.kind.rawValue)").font(.caption).foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer()
                        Image(systemName: "arrow.clockwise.circle").font(.title2).foregroundStyle(state.accent)
                    }
                    .padding(14).background(Color.card, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16)
                }.buttonStyle(.plain).disabled(state.isLoadingPlaylist)
            }
            if let error = state.playlistError { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 20) }
        case "节目":
            EPGProgramList(channel: activeChannel)
        default:
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                TextField(state.localized("搜索频道..."), text: $search)
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.18)) { showGroups.toggle() } } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(state.accent).frame(width: 32, height: 32)
                }.buttonStyle(.plain)
            }.padding(10).background(Color.panel, in: RoundedRectangle(cornerRadius: 11)).padding(.horizontal, 18)
            if showGroups { detailGroupMenu }
            ForEach(detailChannels) { item in
                Button { activeChannel = item; state.play(item) } label: {
                    HStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.panel).frame(width: 76, height: 56).overlay(Image(systemName: "tv").foregroundStyle(.white.opacity(0.45)))
                        VStack(alignment: .leading) { Text(item.name).font(.headline); Text(item.group).font(.caption).foregroundStyle(.white.opacity(0.45)) }
                        Spacer()
                        Image(systemName: item.id == activeChannel.id ? "play.circle.fill" : "play.circle").font(.title2).foregroundStyle(item.id == activeChannel.id ? state.accent : .white.opacity(0.4))
                    }.padding(10).background(item.id == activeChannel.id ? state.accent.opacity(0.12) : Color.card, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16)
                }.buttonStyle(.plain)
            }
        }
    }

    private var detailGroupMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.groups, id: \.self) { group in
                Button { state.selectedGroup = group; withAnimation { showGroups = false } } label: {
                    HStack { Text(group == "全部" ? state.localized("全部") : group); Spacer(); if state.selectedGroup == group { Image(systemName: "checkmark").foregroundStyle(state.accent) } }
                        .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }
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
        let programs = state.programs(for: channel)
        Group {
            if state.isLoadingEPG {
                ProgressView().tint(state.accent).padding(.top, 26)
            } else if let error = state.epgError {
                VStack(spacing: 8) {
                    Text(error).font(.subheadline).foregroundStyle(.red).multilineTextAlignment(.center)
                    Button(state.localized("刷新节目单")) { state.reloadEPG() }.buttonStyle(.borderedProminent).tint(state.accent)
                }.padding(.horizontal, 20).padding(.top, 20)
            } else if programs.isEmpty {
                Text(state.localized("暂无节目数据")).foregroundStyle(.white.opacity(0.5)).padding(.top, 26)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(programs) { program in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(timeFormatter.string(from: program.start))–\(timeFormatter.string(from: program.end))").font(.caption.monospacedDigit()).foregroundStyle(state.accent)
                                Text(program.title).font(.headline).lineLimit(2)
                                Spacer()
                            }
                            if let subtitle = program.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.66)).lineLimit(2) }
                            if let description = program.programDescription { Text(description).font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(3) }
                            ProgressView(value: program.progress).tint(state.accent)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.card, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 16)
                    }
                }
            }
        }
    }
}

struct PlayerSurface: View {
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
    let onAudioSelect: (Int) -> Void
    let onVideoSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 18) {
            controlButton(icon: isPlaying ? "pause.fill" : "play.fill", prominent: true, action: onPlayPause)
            controlButton(icon: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", action: onMute)
            if audioOptions.count > 1 {
                Menu {
                    ForEach(Array(audioOptions.enumerated()), id: \.offset) { index, name in
                        Button { onAudioSelect(index) } label: { Label(name, systemImage: "waveform") }
                    }
                } label: {
                    Image(systemName: "waveform").font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 40).foregroundStyle(.white)
                }.buttonStyle(.plain)
            }
            if videoOptions.count > 1 {
                Menu {
                    ForEach(Array(videoOptions.enumerated()), id: \.offset) { index, name in
                        Button { onVideoSelect(index) } label: { Label(name, systemImage: "sparkles.tv") }
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
    @State private var hideToken = UUID()

    var body: some View {
        ZStack {
            Color.black
            KSVideoPlayer(coordinator: coordinator, url: url, options: options)
                .onStateChanged { layer, playerState in
                    isPlaying = playerState.isPlaying
                    isBuffering = playerState == .preparing || playerState == .buffering
                    if playerState == .readyToPlay || playerState == .bufferFinished {
                        if automaticAudioSelection { selectFirstAudio(on: layer) }
                        updateStreamInfo(from: layer)
                    }
                }
                .onFinish { _, _ in isPlaying = false; controlsVisible = true }
                .contentShape(Rectangle())
                .onTapGesture { controlsVisible ? hideControls() : revealControls() }
            if isBuffering { ProgressView().tint(.white).controlSize(.large) }
            if showLatency { StreamLatencyBadge(milliseconds: nil).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading) }
            if controlsVisible {
                PlaybackControlBar(accent: Color.neon, isPlaying: isPlaying, isMuted: coordinator.isMuted, showsPiP: allowsPictureInPicture, showsProjection: false, onPlayPause: togglePlay, onMute: toggleMute, onPiP: togglePiP, audioOptions: audioOptions, videoOptions: videoOptions, onAudioSelect: selectAudio, onVideoSelect: selectVideo)
                    .transition(.opacity)
            }
        }
        .onAppear { revealControls() }
        .onDisappear { coordinator.resetPlayer() }
    }

    private var options: KSOptions {
        let options = ConfiguredKSOptions(automaticAudioSelection: automaticAudioSelection)
        options.preferredForwardBufferDuration = max(bufferMilliseconds / 1000, 0)
        options.hardwareDecode = hardwareAcceleration
        options.canStartPictureInPictureAutomaticallyFromInline = allowsPictureInPicture
        options.registerRemoteControll = true
        return options
    }

    private func togglePlay() {
        if isPlaying { coordinator.playerLayer?.pause() } else { coordinator.playerLayer?.play() }
        revealControls()
    }

    private func toggleMute() { coordinator.isMuted.toggle(); revealControls() }
    private func togglePiP() { coordinator.playerLayer?.isPipActive.toggle(); revealControls() }

    private func selectAudio(_ index: Int) {
        guard let layer = coordinator.playerLayer else { return }
        let tracks = layer.player.tracks(mediaType: .audio)
        guard tracks.indices.contains(index) else { return }
        tracks[index].isEnabled = true
        updateTrackOptions(from: layer)
        revealControls()
    }

    private func selectVideo(_ index: Int) {
        guard let layer = coordinator.playerLayer else { return }
        let tracks = layer.player.tracks(mediaType: .video)
        guard tracks.indices.contains(index) else { return }
        tracks[index].isEnabled = true
        updateTrackOptions(from: layer)
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
        audioOptions = audioTracks.map { $0.name.isEmpty ? "Audio" : $0.name }
        videoOptions = videoTracks.count > 1 ? videoTracks.map { $0.name.isEmpty ? "Video" : $0.name } : []
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
        audioOptions = player.tracks(mediaType: .audio).map { $0.name.isEmpty ? "Audio" : $0.name }
        let videoTracks = player.tracks(mediaType: .video)
        videoOptions = videoTracks.count > 1 ? videoTracks.map { $0.name.isEmpty ? "Video" : $0.name } : []
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
                KSCompactPlayerView(url: url, bufferMilliseconds: bufferMilliseconds, allowsPictureInPicture: allowsPictureInPicture, hardwareAcceleration: hardwareAcceleration, automaticAudioSelection: automaticAudioSelection, showLatency: showLatency, streamInfo: $streamInfo)
            } else {
                AVPlayerLayerView(session: session)
            }
            if session.isBuffering && !session.didFail { ProgressView().tint(.white).controlSize(.large) }
            if showLatency { StreamLatencyBadge(milliseconds: session.latencyMilliseconds).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading) }
            if !session.didFail {
                PlaybackControlBar(accent: Color.neon, isPlaying: session.isPlaying, isMuted: session.isMuted, showsPiP: allowsPictureInPicture && session.isPiPSupported, showsProjection: true, onPlayPause: session.togglePlay, onMute: session.toggleMute, onPiP: session.togglePiP, audioOptions: session.audioOptions, videoOptions: session.videoOptions, onAudioSelect: session.selectAudio, onVideoSelect: session.selectVideo)
            }
        }
        .onReceive(session.$streamInfo) { streamInfo = $0 }
        .onAppear { session.play() }
        .onDisappear { session.stop() }
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
        playerLayer.player = nil
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
    @Published var streamInfo = ""
    @Published var audioOptions: [String] = []
    @Published var videoOptions: [String] = []
    @Published private(set) var latencyMilliseconds: Int?
    private let automaticAudioSelection: Bool
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
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = max(bufferMilliseconds / 1000, 0)
        player = AVPlayer(playerItem: item)
        currentItem = item
        super.init()
        statusObservation = item.observe(\AVPlayerItem.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.didFail = false
                    self.isBuffering = false
                    if self.automaticAudioSelection { await self.selectAudioTrack(on: item) }
                    self.loadSelectionOptions(for: item, url: url)
                    self.loadStreamInfo(for: item)
                    self.scheduleVideoCheck(for: item)
                    self.startLatencyMonitoring(for: item)
                case .failed:
                    self.didFail = true
                    self.isBuffering = false
                default:
                    break
                }
            }
        }
        timeObservation = player.observe(\AVPlayer.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = player.timeControlStatus == .playing
                self.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
        sizeObservation = item.observe(\AVPlayerItem.presentationSize, options: [.new]) { [weak self] item, _ in
            if item.presentationSize.width > 0 {
                Task { @MainActor [weak self] in
                    self?.videoCheckTask?.cancel()
                    self?.isBuffering = false
                }
            }
        }
    }

    func play() { guard !didFail else { return }; player.play() }
    func stop() { videoCheckTask?.cancel(); optionsTask?.cancel(); latencyTask?.cancel(); player.pause() }
    func togglePlay() { isPlaying ? player.pause() : player.play() }
    func toggleMute() { isMuted.toggle(); player.isMuted = isMuted }

    func attach(playerLayer: AVPlayerLayer) {
        guard attachedLayer !== playerLayer else { return }
        attachedLayer = playerLayer
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller = AVPictureInPictureController(playerLayer: playerLayer)
        controller?.delegate = self
        pipController = controller
        isPiPSupported = controller != nil
    }

    func detach(playerLayer: AVPlayerLayer) {
        guard attachedLayer === playerLayer else { return }
        if pipController?.isPictureInPictureActive == true { pipController?.stopPictureInPicture() }
        pipController?.delegate = nil
        pipController = nil
        isPiPSupported = false
        attachedLayer = nil
    }

    func togglePiP() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive { pipController.stopPictureInPicture() } else { pipController.startPictureInPicture() }
    }

    func selectAudio(_ index: Int) {
        guard let item = currentItem else { return }
        Task { [weak self] in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible), group.options.indices.contains(index) else { return }
            item.select(group.options[index], in: group)
        }
    }

    func selectVideo(_ index: Int) {
        guard videoOptions.indices.contains(index) else { return }
        let option = videoOptions[index]
        switch option {
        case "自动":
            player.currentItem?.preferredPeakBitRate = 0
        case "4K":
            player.currentItem?.preferredPeakBitRate = 16_000_000
        case "1080p":
            player.currentItem?.preferredPeakBitRate = 8_000_000
        case "720p":
            player.currentItem?.preferredPeakBitRate = 4_000_000
        case "480p":
            player.currentItem?.preferredPeakBitRate = 2_000_000
        default:
            // For custom dimensions, keep the current adaptive selection. AVPlayer
            // does not expose a stable public variant-index selector across OSes.
            break
        }
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
                await MainActor.run { self.audioOptions = names }
            }
            if let urlAsset = item.asset as? AVURLAsset,
               let variants = try? await urlAsset.load(.variants) {
                let names = variants.enumerated().map { index, variant -> String in
                    let width = variant.videoAttributes?.presentationSize.width ?? 0
                    let height = variant.videoAttributes?.presentationSize.height ?? 0
                    if height >= 2160 { return "4K" }
                    if height >= 1080 { return "1080p" }
                    if height >= 720 { return "720p" }
                    if height >= 480 { return "480p" }
                    if width > 0 && height > 0 { return "\(Int(width))×\(Int(height))" }
                    return "清晰度 \(index + 1)"
                }
                var unique: [String] = []
                for value in ["自动"] + names where !unique.contains(value) { unique.append(value) }
                await MainActor.run { self.videoOptions = unique.count > 1 ? unique : [] }
            } else {
                await MainActor.run { self.videoOptions = [] }
            }
        }
    }

    private func startLatencyMonitoring(for item: AVPlayerItem) {
        latencyTask?.cancel()
        latencyTask = Task { [weak self, weak item] in
            while !Task.isCancelled {
                guard let self, let item else { return }
                let value: Int? = {
                    guard let range = item.seekableTimeRanges.last?.timeRangeValue,
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
                if let video = tracks.first(where: { $0.mediaType == .video }) {
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
                let message = item.error?.localizedDescription ?? "Stream metadata unavailable"
                await MainActor.run { self.streamInfo = "Engine  AVPlayer\n\(message)" }
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
                guard !Task.isCancelled, tracks.contains(where: { $0.mediaType == .video }), item.presentationSize == .zero else { return }
                await MainActor.run {
                    self.player.pause()
                    self.didFail = true
                    self.isBuffering = false
                }
            } catch {
                // A network stream can delay track discovery; leave it to AVPlayer rather than failing on metadata alone.
            }
        }
    }

    private static func codecName(for descriptions: [Any]) -> String? {
        guard let first = descriptions.first else { return nil }
        let description = first as! CMFormatDescription
        let code = CMFormatDescriptionGetMediaSubType(description)
        let bytes: [UInt8] = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    deinit {
        statusObservation?.invalidate(); timeObservation?.invalidate(); sizeObservation?.invalidate(); infoTask?.cancel(); videoCheckTask?.cancel(); optionsTask?.cancel(); latencyTask?.cancel(); pipController?.delegate = nil; player.pause()
    }
}

extension AVPlaybackSession: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { Task { @MainActor in self.isPiPActive = true } }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { Task { @MainActor in self.isPiPActive = false } }
    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { Task { @MainActor in self.isPiPActive = false } }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { completionHandler(true) }
}

struct FavoritesView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedDetail: Channel?
    var body: some View {
        VStack(spacing: 0) {
            Text(state.localized("收藏")).font(.system(size: 31, weight: .bold)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.top, 62)
            Spacer()
            if state.favoriteChannels.isEmpty {
                Image(systemName: "star").font(.system(size: 58, weight: .thin)).foregroundStyle(.white.opacity(0.5))
                Text(state.localized("无收藏频道")).font(.system(size: 23, weight: .bold)).padding(.top, 22)
                Text(state.localized("用星号标记频道以便在此快速访问。")).font(.system(size: 17)).padding(.top, 5)
                Spacer().frame(height: 180)
            } else {
                LazyVStack(spacing: 12) { ForEach(state.favoriteChannels) { channel in ChannelCard(channel: channel) { state.play(channel); selectedDetail = channel } } }.padding(.horizontal, 22).padding(.top, 28)
                Spacer()
            }
            Spacer()
        }.padding(.bottom, 110)
        .fullScreenCover(item: $selectedDetail) { ChannelDetailView(channel: $0) }
    }
}

struct EmptyHomeState: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 44, weight: .thin)).foregroundStyle(.white.opacity(0.45))
            Text(state.localized("暂无频道")).font(.title3.bold())
            Text(state.localized("请先在“播放列表”中添加 M3U 或 Xtream 来源。")).font(.subheadline).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
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
                if state.playlists.isEmpty {
                    Text(state.localized("暂无播放列表")).foregroundStyle(.white.opacity(0.5)).padding(.horizontal, 28)
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
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(playlist.name).font(.system(size: 18, weight: .bold))
                HStack { Image(systemName: "tv").foregroundStyle(Color.neon); Text("\(playlist.channelCount) \(state.localized("频道"))").foregroundStyle(Color.neon); Text("·").foregroundStyle(.white.opacity(0.4)); Text(playlist.kind.rawValue).foregroundStyle(.white.opacity(0.55)) }.font(.subheadline)
            }
            Spacer()
            Button(action: onEdit) { Image(systemName: "pencil").foregroundStyle(Color.neon).frame(width: 44, height: 44).background(Color.neon.opacity(0.1), in: Circle()) }.buttonStyle(.plain)
            Button(action: onDelete) { Image(systemName: "trash").foregroundStyle(.red).frame(width: 44, height: 44).background(Color.red.opacity(0.1), in: Circle()) }.buttonStyle(.plain)
        }.padding(.horizontal, 18).padding(.vertical, 17).background(Color.card, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.neon.opacity(0.42), lineWidth: 1)).padding(.horizontal, 22)
    }
}

struct CircleButton: View { let icon: String; var body: some View { Image(systemName: icon).font(.title3).foregroundStyle(.white).frame(width: 48, height: 48).background(Color.panel, in: Circle()).overlay(Circle().stroke(.white.opacity(0.2))) } }
struct QualityChip: ButtonStyle { let selected: Bool; let accent: Color; func makeBody(configuration: Configuration) -> some View { configuration.label.font(.subheadline.weight(.semibold)).foregroundStyle(selected ? .white : .white.opacity(0.65)).padding(.horizontal, 18).frame(height: 40).background(selected ? accent : Color.panel, in: Capsule()).opacity(configuration.isPressed ? 0.7 : 1) } }

extension Color {
    static var appBackground: Color {
        UserDefaults.standard.string(forKey: "nanostream.theme") == "Light" ? Color(red: 0.95, green: 0.96, blue: 0.98) : Color(red: 0.015, green: 0.035, blue: 0.055)
    }
    static var panel: Color {
        UserDefaults.standard.string(forKey: "nanostream.theme") == "Light" ? Color.white : Color(red: 0.11, green: 0.13, blue: 0.17)
    }
    static var card: Color {
        UserDefaults.standard.string(forKey: "nanostream.theme") == "Light" ? Color(red: 0.92, green: 0.93, blue: 0.95) : Color(red: 0.12, green: 0.15, blue: 0.16)
    }
    static var cardInner: Color {
        UserDefaults.standard.string(forKey: "nanostream.theme") == "Light" ? Color(red: 0.86, green: 0.88, blue: 0.91) : Color(red: 0.055, green: 0.07, blue: 0.08)
    }
    static var neon: Color {
        switch UserDefaults.standard.string(forKey: "nanostream.colorTheme") {
        case "Cyberpunk": return Color(red: 0.2, green: 0.8, blue: 1)
        case "落日金": return Color(red: 1, green: 0.72, blue: 0.2)
        case "霓虹粉": return Color(red: 1, green: 0.28, blue: 0.72)
        case "深海蓝": return Color(red: 0.25, green: 0.55, blue: 1)
        default: return Color(red: 0.2, green: 1.0, blue: 0.12)
        }
    }
}

// Allows the concise `.neon` style spelling in SwiftUI modifiers.
extension ShapeStyle where Self == Color {
    static var neon: Color { Color.neon }
}
