import Foundation

struct Channel: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var group: String
    var streamURL: URL?
    var logoURL: URL?
    var isLive: Bool

    init(id: UUID = UUID(), name: String, group: String, streamURL: URL? = nil, logoURL: URL? = nil, isLive: Bool = true) {
        self.id = id
        self.name = name
        self.group = group
        self.streamURL = streamURL
        self.logoURL = logoURL
        self.isLive = isLive
    }
}

struct EPGProgram: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var start: Date
    var end: Date

    var progress: Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(max(Date().timeIntervalSince(start) / total, 0), 1)
    }
}

enum PlaylistKind: String, CaseIterable, Identifiable {
    case m3u = "M3U / TXT"
    case xtream = "Xtream Codes"
    case tvHeadend = "tvHeadend"

    var id: String { rawValue }
}

struct Playlist: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var kind: PlaylistKind
    var endpoint: String
    var channelCount: Int
    var lastRefresh: Date?
}
