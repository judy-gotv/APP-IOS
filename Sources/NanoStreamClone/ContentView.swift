import SwiftUI
import AVKit
import KSPlayer

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
                    .foregroundStyle(tab == item ? Color.neon : .white.opacity(0.58))
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
    @State private var selectedQuality = "全部"
    @State private var selectedDetail: Channel?
    let qualities = ["全部", "4K UHD", "FHD", "HD"]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    CircleButton(icon: "line.3.horizontal")
                    Spacer()
                    Capsule().fill(Color.panel).frame(width: 125, height: 42).overlay { Label("全部", systemImage: "list.bullet.rectangle").font(.subheadline.weight(.semibold)) }
                }.padding(.horizontal, 22).padding(.top, 12)
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.55))
                    TextField("搜索频道...", text: $state.searchText).textFieldStyle(.plain)
                }.padding(.horizontal, 14).frame(height: 48).background(Color.panel, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 22).padding(.top, 12)
                HStack(spacing: 10) {
                    ForEach(qualities, id: \.self) { quality in
                        Button(quality) { selectedQuality = quality }.buttonStyle(QualityChip(selected: selectedQuality == quality))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "square.grid.2x2").foregroundStyle(.neon).frame(width: 46, height: 40).background(Color.panel, in: RoundedRectangle(cornerRadius: 20))
                }.padding(.horizontal, 22).padding(.top, 16)
                if state.channels.isEmpty {
                    EmptyHomeState()
                } else {
                    RecentRail().padding(.top, 23)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(state.channels(for: selectedQuality)) { channel in ChannelCard(channel: channel) { state.play(channel); selectedDetail = channel } }
                    }.padding(.horizontal, 22).padding(.top, 17).padding(.bottom, 110)
                }
            }
        }
        .fullScreenCover(item: $selectedDetail) { channel in ChannelDetailView(channel: channel) }
    }
}

struct RecentRail: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("最近播放").font(.system(size: 20, weight: .bold)); Spacer(); Image(systemName: "clock.fill").foregroundStyle(.neon) }.padding(.horizontal, 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(state.recent.compactMap(state.channel(for:))) { channel in
                        VStack(spacing: 7) {
                            ZStack { RoundedRectangle(cornerRadius: 12).fill(Color.cardInner); Text(channel.name).font(.system(size: 11, weight: .bold)).multilineTextAlignment(.center).padding(7) }.frame(width: 112, height: 90)
                            Text(channel.name).font(.caption).lineLimit(1).frame(width: 112, alignment: .leading)
                        }.padding(9).background(Color.card, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.neon.opacity(0.25), lineWidth: 1))
                    }
                    if state.recent.isEmpty { Text("暂无播放记录").foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 22) }
                }.padding(.horizontal, 22)
            }
        }
    }
}

struct ChannelCard: View {
    @EnvironmentObject private var state: AppState
    let channel: Channel
    let onOpen: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 11).fill(Color.black).frame(height: 112)
                if let logoURL = channel.logoURL {
                    AsyncImage(url: logoURL) { phase in
                        if let image = phase.image { image.resizable().scaledToFit().padding(18) } else { fallbackLogo }
                    }
                } else { fallbackLogo }
                HStack { Text("● LIVE").font(.system(size: 9, weight: .bold)).foregroundStyle(.neon).padding(.horizontal, 7).padding(.vertical, 4).background(Color.green.opacity(0.22), in: Capsule()); Spacer(); Text("4K UHD").font(.system(size: 9, weight: .bold)).foregroundStyle(.neon).padding(.horizontal, 6).padding(.vertical, 4).background(Color.green.opacity(0.22), in: Capsule()) }.padding(9)
                VStack { Spacer(); HStack { Text("198ms").font(.system(size: 10, design: .monospaced)).foregroundStyle(.neon); Spacer(); Button { state.toggleFavorite(channel) } label: { Image(systemName: state.favorites.contains(channel.id) ? "star.fill" : "star").foregroundStyle(.white.opacity(0.75)) }.buttonStyle(.plain) }.padding(9) }.frame(height: 112)
            }
            Text(channel.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Text("\(channel.quality) · 50 FPS").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }.padding(10).background(Color.card, in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.neon.opacity(0.38), lineWidth: 1)).contentShape(Rectangle()).onTapGesture(perform: onOpen)
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
    @State private var mode = "频道"
    @State private var search = ""
    @State private var showInfo = false
    var body: some View {
        ZStack { Color.appBackground.ignoresSafeArea(); ScrollView(showsIndicators: false) { VStack(spacing: 14) {
            HStack { Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3).frame(width: 44, height: 44).background(Color.panel, in: Circle()) }.buttonStyle(.plain); Text(channel.name).font(.headline); Spacer(); Button { showInfo = true } label: { Image(systemName: "info.circle") }.buttonStyle(.plain); Button { state.toggleFavorite(channel) } label: { Image(systemName: state.favorites.contains(channel.id) ? "star.fill" : "star") }.buttonStyle(.plain) }.padding(.horizontal, 18).padding(.top, 12)
            ZStack(alignment: .bottomLeading) { if let url = channel.streamURL { PlayerSurface(url: url, title: channel.name, engine: state.preferredPlayer, bufferMilliseconds: state.networkBufferMilliseconds) } else { Color.black; Image(systemName: "play.rectangle").font(.largeTitle).foregroundStyle(.white.opacity(0.3)) }; Text("LIVE").font(.caption.bold()).foregroundStyle(.neon).padding(8) }.frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.neon.opacity(0.7), lineWidth: 1)).padding(.horizontal, 16)
            Picker("", selection: $mode) { Text("订阅").tag("订阅"); Text("频道").tag("频道"); Text("节目").tag("节目") }.pickerStyle(.segmented).padding(.horizontal, 18)
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5)); TextField("搜索频道...", text: $search); Spacer(); Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.neon) }.padding(14).background(Color.panel, in: RoundedRectangle(cornerRadius: 11)).padding(.horizontal, 18)
            ForEach(state.channels.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { item in Button { state.play(item) } label: { HStack { RoundedRectangle(cornerRadius: 8).fill(Color.panel).frame(width: 76, height: 56).overlay(Image(systemName: "tv").foregroundStyle(.white.opacity(0.45))); VStack(alignment: .leading) { Text(item.name).font(.headline); Text("IPTV Channel").font(.caption).foregroundStyle(.white.opacity(0.45)) }; Spacer(); Image(systemName: item.id == channel.id ? "play.circle.fill" : "play.circle").font(.title2).foregroundStyle(item.id == channel.id ? .neon : .white.opacity(0.4)) }.padding(10).background(item.id == channel.id ? Color.neon.opacity(0.12) : Color.card, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16) }.buttonStyle(.plain) }
            Spacer(minLength: 110)
        } } }
        .onAppear { state.play(channel) }
        .alert("编码信息", isPresented: $showInfo) { Button("关闭", role: .cancel) {} } message: { Text("Video\nResolution 1920 × 1080\nFrame Rate 50 fps\nCodec H.264\nAudio AAC") }
    }
}

struct PlayerSurface: View {
    let url: URL
    let title: String
    let engine: PreferredPlayer
    let bufferMilliseconds: Double

    var body: some View {
        switch engine {
        case .ksPlayer:
            KSVideoPlayerView(url: url, options: ksOptions, title: title)
        case .avPlayer, .auto:
            VideoPlayer(player: avPlayer)
        }
    }

    private var ksOptions: KSOptions {
        let options = KSOptions()
        options.preferredForwardBufferDuration = bufferMilliseconds / 1000
        return options
    }

    private var avPlayer: AVPlayer {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = bufferMilliseconds / 1000
        let player = AVPlayer(playerItem: item)
        player.play()
        return player
    }
}


struct FavoritesView: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            Text("收藏").font(.system(size: 31, weight: .bold)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.top, 62)
            Spacer()
            if state.favoriteChannels.isEmpty {
                Image(systemName: "star").font(.system(size: 58, weight: .thin)).foregroundStyle(.white.opacity(0.5))
                Text("无收藏频道").font(.system(size: 23, weight: .bold)).padding(.top, 22)
                Text("用星号标记频道以便在此快速访问。").font(.system(size: 17)).padding(.top, 5)
                Spacer().frame(height: 180)
            } else {
                LazyVStack(spacing: 12) { ForEach(state.favoriteChannels) { channel in ChannelCard(channel: channel) { state.play(channel) } } }.padding(.horizontal, 22).padding(.top, 28)
                Spacer()
            }
            Spacer()
        }.padding(.bottom, 110)
    }
}

struct EmptyHomeState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 44, weight: .thin)).foregroundStyle(.white.opacity(0.45))
            Text("暂无频道").font(.title3.bold())
            Text("请先在“播放列表”中添加 M3U 或 Xtream 来源。").font(.subheadline).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
        }.padding(.top, 72).padding(.horizontal, 28)
    }
}

struct PlaylistsView: View {
    @EnvironmentObject private var state: AppState
    @Binding var showAdd: Bool
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Button { state.refreshPlaylists() } label: { Image(systemName: "arrow.clockwise").font(.title2).foregroundStyle(state.accent) }.buttonStyle(.plain); Spacer(); Button { showAdd = true } label: { Image(systemName: "plus").font(.title2).foregroundStyle(state.accent) }.buttonStyle(.plain) }.padding(.horizontal, 28).padding(.top, 54)
                Text("播放列表").font(.system(size: 31, weight: .bold)).padding(.horizontal, 28).padding(.bottom, 16)
                if state.playlists.isEmpty {
                    Text("暂无播放列表").foregroundStyle(.white.opacity(0.5)).padding(.horizontal, 28)
                } else {
                    ForEach(state.playlists) { playlist in PlaylistRow(playlist: playlist) { state.removePlaylist(playlist) } }
                }
            }.padding(.bottom, 120)
        }
    }
}

struct PlaylistRow: View {
    let playlist: Playlist
    let onDelete: () -> Void
    var body: some View {
        HStack { VStack(alignment: .leading, spacing: 8) { Text(playlist.name).font(.system(size: 18, weight: .bold)); HStack { Image(systemName: "tv").foregroundStyle(Color.neon); Text("\(playlist.channelCount) kênh").foregroundStyle(Color.neon); Text("·").foregroundStyle(.white.opacity(0.4)); Text(playlist.kind.rawValue).foregroundStyle(.white.opacity(0.55)) }.font(.subheadline) }; Spacer(); Button(action: onDelete) { Image(systemName: "trash").foregroundStyle(Color.neon).padding(12).background(Color.neon.opacity(0.1), in: Circle()) }.buttonStyle(.plain) }.padding(.horizontal, 18).padding(.vertical, 17).background(Color.card, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.neon.opacity(0.42), lineWidth: 1)).padding(.horizontal, 22)
    }
}

struct CircleButton: View { let icon: String; var body: some View { Image(systemName: icon).font(.title3).foregroundStyle(.white).frame(width: 48, height: 48).background(Color.panel, in: Circle()).overlay(Circle().stroke(.white.opacity(0.2))) } }
struct QualityChip: ButtonStyle { let selected: Bool; func makeBody(configuration: Configuration) -> some View { configuration.label.font(.subheadline.weight(.semibold)).foregroundStyle(selected ? .white : .white.opacity(0.65)).padding(.horizontal, 18).frame(height: 40).background(selected ? Color.neon : Color.panel, in: Capsule()).opacity(configuration.isPressed ? 0.7 : 1) } }

extension Color {
    static let appBackground = Color(red: 0.015, green: 0.035, blue: 0.055)
    static let panel = Color(red: 0.11, green: 0.13, blue: 0.17)
    static let card = Color(red: 0.12, green: 0.15, blue: 0.16)
    static let cardInner = Color(red: 0.055, green: 0.07, blue: 0.08)
    static let neon = Color(red: 0.2, green: 1.0, blue: 0.12)
}

// Allows the concise `.neon` style spelling in SwiftUI modifiers.
extension ShapeStyle where Self == Color {
    static var neon: Color { Color.neon }
}
