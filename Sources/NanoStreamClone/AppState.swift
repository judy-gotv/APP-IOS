import Foundation
import AVFoundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var channels: [Channel]
    @Published var playlists: [Playlist]
    @Published var favorites: Set<String>
    @Published var recent: [String]
    @Published var selectedChannel: Channel?
    @Published var selectedGroup = "全部"
    @Published var searchText = ""
    @Published var isLoadingPlaylist = false
    @Published var playlistError: String?
    @Published var language: String
    @Published var themeMode: String
    @Published var colorTheme: String
    @Published var preferredPlayer: PreferredPlayer
    @Published var networkBufferMilliseconds: Double
    let player = StreamPlayer()

    private let storageKey = "nanostream.state.v3"

    init() {
        if let saved = Self.restore(key: storageKey) {
            channels = saved.channels
            playlists = saved.playlists
            favorites = saved.favorites
            recent = saved.recent
        } else {
            channels = []
            playlists = []
            favorites = []
            recent = []
        }
        language = UserDefaults.standard.string(forKey: "nanostream.language") ?? "中文"
        themeMode = UserDefaults.standard.string(forKey: "nanostream.theme") ?? "System"
        colorTheme = UserDefaults.standard.string(forKey: "nanostream.colorTheme") ?? "剧毒绿"
        preferredPlayer = PreferredPlayer(rawValue: UserDefaults.standard.string(forKey: "nanostream.player") ?? "KSPlayer") ?? .ksPlayer
        networkBufferMilliseconds = UserDefaults.standard.object(forKey: "nanostream.buffer") as? Double ?? 3000
    }

    var groups: [String] { ["全部"] + Array(Set(channels.map(\.group))).sorted() }

    var visibleChannels: [Channel] {
        channels.filter { channel in
            (selectedGroup == "全部" || channel.group == selectedGroup) &&
            (searchText.isEmpty || channel.name.localizedCaseInsensitiveContains(searchText))
        }
    }

    var favoriteChannels: [Channel] { channels.filter { favorites.contains($0.id) } }

    func channels(for quality: String) -> [Channel] {
        quality == "全部" ? visibleChannels : visibleChannels.filter { $0.quality == quality }
    }

    var accent: Color {
        switch colorTheme {
        case "Cyberpunk": return Color(red: 0.2, green: 0.8, blue: 1)
        case "落日金": return Color(red: 1, green: 0.72, blue: 0.2)
        case "霓虹粉": return Color(red: 1, green: 0.28, blue: 0.72)
        case "深海蓝": return Color(red: 0.25, green: 0.55, blue: 1)
        default: return Color.neon
        }
    }

    var colorScheme: ColorScheme? {
        switch themeMode { case "Light": return .light; case "Dark": return .dark; default: return nil }
    }

    func setLanguage(_ value: String) { language = value; UserDefaults.standard.set(value, forKey: "nanostream.language") }
    func setTheme(_ value: String) { themeMode = value; UserDefaults.standard.set(value, forKey: "nanostream.theme") }
    func setColorTheme(_ value: String) { colorTheme = value; UserDefaults.standard.set(value, forKey: "nanostream.colorTheme") }
    func setPreferredPlayer(_ value: PreferredPlayer) { preferredPlayer = value; UserDefaults.standard.set(value.rawValue, forKey: "nanostream.player") }
    func setBuffer(_ value: Double) { networkBufferMilliseconds = value; UserDefaults.standard.set(value, forKey: "nanostream.buffer") }
    func localized(_ key: String) -> String {
        guard language != "中文" else { return key }
        let table: [String: (String, String)] = ["设置": ("Settings", "Cài đặt"), "播放列表": ("Playlists", "Danh sách phát"), "收藏": ("Favorites", "Yêu thích"), "主页": ("Home", "Trang chủ")]
        return language == "English" ? (table[key]?.0 ?? key) : (table[key]?.1 ?? key)
    }

    func toggleFavorite(_ channel: Channel) {
        if favorites.contains(channel.id) { favorites.remove(channel.id) } else { favorites.insert(channel.id) }
        save()
    }

    func play(_ channel: Channel) {
        selectedChannel = channel
        recent.removeAll { $0 == channel.id }
        recent.insert(channel.id, at: 0)
        recent = Array(recent.prefix(24))
        player.play(channel: channel, bufferMilliseconds: networkBufferMilliseconds)
        save()
    }

    func channel(for id: String) -> Channel? { channels.first { $0.id == id } }

    func addPlaylist(name: String, kind: PlaylistKind, endpoint: String, username: String = "", password: String = "", completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        Task { await importPlaylist(name: name, kind: kind, endpoint: endpoint, username: username, password: password, completion: completion) }
    }

    func addPlaylistFromText(name: String, text: String) {
        Task { @MainActor in
            let parsed = M3UParser.parse(text: text)
            guard !parsed.isEmpty else { playlistError = "文件中没有找到有效频道。"; return }
            channels = parsed
            playlists.insert(Playlist(name: name.isEmpty ? "本地播放列表" : name, kind: .m3u, endpoint: "本地文件", channelCount: parsed.count, lastRefresh: Date()), at: 0)
            playlistError = nil
            save()
        }
    }

    func removePlaylist(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
        if playlists.isEmpty { channels.removeAll() }
        save()
    }

    func refreshPlaylists() {
        guard let playlist = playlists.first else { return }
        addPlaylist(name: playlist.name, kind: playlist.kind, endpoint: playlist.endpoint, username: playlist.username, password: playlist.password)
    }

    func clearHistory() { recent.removeAll(); save() }
    func clearImageCache() { URLCache.shared.removeAllCachedResponses(); playlistError = "图片缓存已清除。" }

    private func importPlaylist(name: String, kind: PlaylistKind, endpoint: String, username: String, password: String, completion: @escaping @MainActor (Bool) -> Void) async {
        isLoadingPlaylist = true
        playlistError = nil
        do {
            let loaded = try await PlaylistLoader.load(kind: kind, endpoint: endpoint, username: username, password: password)
            guard !loaded.isEmpty else { throw PlaylistLoadError.empty }
            channels = loaded
            let playlist = Playlist(name: name.isEmpty ? "新播放列表" : name, kind: kind, endpoint: endpoint, username: username, password: password, channelCount: loaded.count, lastRefresh: Date())
            playlists.insert(playlist, at: 0)
            selectedGroup = "全部"
            searchText = ""
            save()
            await completion(true)
        } catch {
            playlistError = error.localizedDescription
            await completion(false)
        }
        isLoadingPlaylist = false
    }

    private func save() {
        let state = SavedState(channels: channels, playlists: playlists, favorites: favorites, recent: recent)
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func restore(key: String) -> SavedState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }
}

private struct SavedState: Codable {
    var channels: [Channel]
    var playlists: [Playlist]
    var favorites: Set<String>
    var recent: [String]
}

enum PreferredPlayer: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case avPlayer = "AVPlayer"
    case ksPlayer = "KSPlayer"
    var id: String { rawValue }
}

@MainActor
final class StreamPlayer: ObservableObject {
    @Published private(set) var player = AVPlayer()
    @Published private(set) var currentURL: URL?
    @Published private(set) var errorMessage: String?
    private var statusObservation: NSKeyValueObservation?

    func play(channel: Channel, bufferMilliseconds: Double = 3000) {
        guard let url = channel.streamURL else {
            errorMessage = "该频道没有可播放地址。"
            return
        }
        errorMessage = nil
        currentURL = url
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = max(bufferMilliseconds / 1000, 0)
        statusObservation = item.observe(\AVPlayerItem.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "播放失败，请检查频道地址。"
            Task { @MainActor [weak self] in self?.errorMessage = message }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
    }
}

enum PlaylistLoadError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case empty
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "播放列表地址无效。"
        case .httpStatus(let status): return "服务器返回 HTTP \(status)。"
        case .empty: return "播放列表为空或没有有效频道。"
        case .invalidFormat: return "返回内容不是有效的 M3U 播放列表。"
        }
    }
}

enum PlaylistLoader {
    static func load(kind: PlaylistKind, endpoint: String, username: String, password: String) async throws -> [Channel] {
        switch kind {
        case .m3u, .tvHeadend:
            return try await M3UParser.fetch(endpoint: endpoint)
        case .xtream:
            let url = try xtreamPlaylistURL(endpoint: endpoint, username: username, password: password)
            return try await M3UParser.fetch(endpoint: url.absoluteString)
        }
    }

    private static func xtreamPlaylistURL(endpoint: String, username: String, password: String) throws -> URL {
        guard var components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), components.scheme != nil, components.host != nil else { throw PlaylistLoadError.invalidURL }
        if components.path.lowercased().contains("get.php") { return components.url! }
        components.path = "/get.php"
        components.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password), URLQueryItem(name: "type", value: "m3u_plus"), URLQueryItem(name: "output", value: "ts")]
        guard let url = components.url else { throw PlaylistLoadError.invalidURL }
        return url
    }
}

enum M3UParser {
    static func fetch(endpoint: String) async throws -> [Channel] {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw PlaylistLoadError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw PlaylistLoadError.httpStatus(http.statusCode) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw PlaylistLoadError.invalidFormat }
        let channels = parse(text: text)
        guard !channels.isEmpty else { throw PlaylistLoadError.empty }
        return channels
    }

    static func parse(text: String) -> [Channel] {
        var result: [Channel] = []
        var pendingName: String?
        var pendingGroup = "其他"
        var pendingLogo: URL?
        var pendingQuality: String?
        let lines = text.replacingOccurrences(of: "\u{feff}", with: "").split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        for line in lines {
            if line.uppercased().hasPrefix("#EXTINF") {
                let display = line.split(separator: ",", maxSplits: 1).last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
                pendingName = attribute("tvg-name", in: line) ?? display ?? "未命名频道"
                pendingGroup = attribute("group-title", in: line) ?? "其他"
                pendingLogo = attribute("tvg-logo", in: line).flatMap(URL.init(string:))
                pendingQuality = attribute("resolution", in: line) ?? attribute("quality", in: line)
            } else if !line.hasPrefix("#"), !line.isEmpty {
                let streamPart = line.split(separator: "|", maxSplits: 1).first.map(String.init) ?? line
                guard let url = URL(string: streamPart), let name = pendingName else { continue }
                result.append(Channel(name: name, group: pendingGroup, streamURL: url, logoURL: pendingLogo, quality: pendingQuality))
                pendingName = nil
                pendingLogo = nil
                pendingQuality = nil
            }
        }
        return result
    }

    private static func attribute(_ key: String, in line: String) -> String? {
        let marker = key + "=\""
        guard let start = line.range(of: marker, options: .caseInsensitive)?.upperBound,
              let end = line[start...].firstIndex(of: "\"") else { return nil }
        return String(line[start..<end])
    }
}
