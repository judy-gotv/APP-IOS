import Foundation

struct Channel: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var group: String
    var streamURL: URL?
    var logoURL: URL?
    var quality: String
    var isLive: Bool

    init(id: String? = nil, name: String, group: String, streamURL: URL? = nil, logoURL: URL? = nil, quality: String? = nil, isLive: Bool = true) {
        self.id = id ?? Self.stableID(name: name, streamURL: streamURL)
        self.name = name
        self.group = group.isEmpty ? "其他" : group
        self.streamURL = streamURL
        self.logoURL = logoURL
        self.quality = quality ?? Self.quality(for: name)
        self.isLive = isLive
    }

    private static func stableID(name: String, streamURL: URL?) -> String {
        var first: UInt64 = 1469598103934665603
        var second: UInt64 = 1099511628211
        for byte in "\(name)|\(streamURL?.absoluteString ?? "")".utf8 {
            first ^= UInt64(byte)
            first &*= 1099511628211
            second ^= first
            second &*= 14029467366897019727
        }
        return String(format: "%016llx%016llx", first, second)
    }

    private static func quality(for name: String) -> String {
        let upper = name.uppercased()
        if upper.contains("8K") { return "8K UHD" }
        if upper.contains("4K") || upper.contains("UHD") { return "4K UHD" }
        if upper.contains("FHD") || upper.contains("1080") { return "FHD" }
        return "HD"
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

enum PlaylistKind: String, CaseIterable, Identifiable, Codable {
    case m3u = "M3U / TXT"
    case xtream = "Xtream"
    case tvHeadend = "tvHeadend"

    var id: String { rawValue }
}

struct Playlist: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var kind: PlaylistKind
    var endpoint: String
    var username: String
    var password: String
    var channelCount: Int
    var lastRefresh: Date?

    init(id: UUID = UUID(), name: String, kind: PlaylistKind, endpoint: String, username: String = "", password: String = "", channelCount: Int = 0, lastRefresh: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.channelCount = channelCount
        self.lastRefresh = lastRefresh
    }
}
