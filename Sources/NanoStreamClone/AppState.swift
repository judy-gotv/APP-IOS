import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var channels: [Channel] = Channel.samples
    @Published var playlists: [Playlist] = []
    @Published var favorites: Set<UUID> = []
    @Published var recent: [UUID] = []
    @Published var selectedChannel: Channel?
    @Published var selectedGroup = "全部"
    @Published var searchText = ""

    var groups: [String] {
        ["全部"] + Array(Set(channels.map(\.group))).sorted()
    }

    var visibleChannels: [Channel] {
        channels.filter { channel in
            (selectedGroup == "全部" || channel.group == selectedGroup) &&
            (searchText.isEmpty || channel.name.localizedCaseInsensitiveContains(searchText))
        }
    }

    func toggleFavorite(_ channel: Channel) {
        if favorites.contains(channel.id) {
            favorites.remove(channel.id)
        } else {
            favorites.insert(channel.id)
        }
    }

    func play(_ channel: Channel) {
        selectedChannel = channel
        recent.removeAll { $0 == channel.id }
        recent.insert(channel.id, at: 0)
        recent = Array(recent.prefix(12))
    }

    func channel(for id: UUID) -> Channel? {
        channels.first { $0.id == id }
    }

    func addPlaylist(name: String, kind: PlaylistKind, endpoint: String) {
        let parsed = M3UParser.parse(endpoint: endpoint)
        if !parsed.isEmpty { channels = parsed }
        playlists.insert(Playlist(name: name.isEmpty ? "新播放列表" : name, kind: kind, endpoint: endpoint, channelCount: parsed.count, lastRefresh: Date()), at: 0)
    }
}

enum M3UParser {
    static func parse(endpoint: String) -> [Channel] {
        guard let url = URL(string: endpoint), let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text: text)
    }

    static func parse(text: String) -> [Channel] {
        var result: [Channel] = []
        var pendingName = ""
        var pendingGroup = "其他"
        var pendingLogo: URL?
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("#EXTINF") {
                pendingName = line.split(separator: ",", maxSplits: 1).last.map(String.init) ?? "未命名频道"
                pendingGroup = attribute("group-title", in: line) ?? "其他"
                pendingLogo = attribute("tvg-logo", in: line).flatMap(URL.init(string:))
            } else if !line.hasPrefix("#"), let url = URL(string: line.trimmingCharacters(in: .whitespacesAndNewlines)), !pendingName.isEmpty {
                result.append(Channel(name: pendingName, group: pendingGroup, streamURL: url, logoURL: pendingLogo))
                pendingName = ""
            }
        }
        return result
    }

    private static func attribute(_ key: String, in line: String) -> String? {
        let marker = key + "=\""
        guard let start = line.range(of: marker)?.upperBound,
              let end = line[start...].firstIndex(of: "\"") else { return nil }
        return String(line[start..<end])
    }
}

private extension Channel {
    static let samples: [Channel] = [
        Channel(name: "K-20 News", group: "新闻", streamURL: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")),
        Channel(name: "City Sports", group: "体育", streamURL: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")),
        Channel(name: "Cinema One", group: "电影"),
        Channel(name: "World Focus", group: "新闻"),
        Channel(name: "Nature Live", group: "纪录片"),
        Channel(name: "Kids Planet", group: "少儿"),
        Channel(name: "Music Lounge", group: "音乐"),
        Channel(name: "Arena Max", group: "体育")
    ]
}
