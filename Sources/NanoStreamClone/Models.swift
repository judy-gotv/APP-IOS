import Foundation

/// Language-independent group sentinels. Never shown directly to the user;
/// UI code maps them through AppState.localizedGroup(_:).
enum GroupID {
    static let all = "__all__"
    static let other = "__other__"
}

struct Channel: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var group: String
    var streamURL: URL?
    var logoURL: URL?
    var epgID: String?
    var quality: String
    var isLive: Bool

    init(id: String? = nil, name: String, group: String, streamURL: URL? = nil, logoURL: URL? = nil, epgID: String? = nil, quality: String? = nil, isLive: Bool = true) {
        self.id = id ?? Self.stableID(name: name, streamURL: streamURL)
        self.name = name
        self.group = group.isEmpty ? GroupID.other : group
        self.streamURL = streamURL
        self.logoURL = logoURL
        self.epgID = epgID
        self.quality = Self.normalizedQuality(quality)
        self.isLive = isLive
    }

    private enum CodingKeys: String, CodingKey { case id, name, group, streamURL, logoURL, epgID, quality, isLive }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        group = try container.decode(String.self, forKey: .group)
        streamURL = try container.decodeIfPresent(URL.self, forKey: .streamURL)
        logoURL = try container.decodeIfPresent(URL.self, forKey: .logoURL)
        epgID = try container.decodeIfPresent(String.self, forKey: .epgID)
        quality = Self.normalizedQuality(try container.decodeIfPresent(String.self, forKey: .quality))
        isLive = try container.decodeIfPresent(Bool.self, forKey: .isLive) ?? true
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

    /// Quality is only ever taken from a source-provided attribute, normalized
    /// to a small set of labels. A missing attribute stays empty ("unknown")
    /// instead of being guessed from the channel name (which produced false
    /// positives such as "18K" -> "8K UHD" and labelled every SD channel "HD").
    static func normalizedQuality(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return "" }
        let upper = raw.uppercased().replacingOccurrences(of: " ", with: "")
        switch upper {
        case "3840X2160", "2160P", "2160", "4K", "4KUHD", "UHD": return "4K UHD"
        case "1920X1080", "1080P", "1080", "FHD": return "FHD"
        case "1280X720", "720P", "720": return "HD"
        case "854X480", "720X480", "480P", "480", "SD": return "SD"
        default: return raw
        }
    }
}

struct EPGProgram: Identifiable, Hashable, Codable {
    let id: String
    var channelID: String
    var title: String
    var subtitle: String?
    var programDescription: String?
    var start: Date
    var end: Date

    init(channelID: String, title: String, subtitle: String? = nil, programDescription: String? = nil, start: Date, end: Date) {
        self.channelID = channelID
        self.title = title
        self.subtitle = subtitle
        self.programDescription = programDescription
        self.start = start
        self.end = end
        self.id = "\(channelID)|\(Int(start.timeIntervalSince1970))|\(Int(end.timeIntervalSince1970))|\(title)|\(subtitle ?? "")"
    }

    var progress: Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(max(Date().timeIntervalSince(start) / total, 0), 1)
    }
}

struct EPGGuide: Codable {
    var programsByChannelID: [String: [EPGProgram]]
    /// Raw XMLTV display names per guide channel id. Round-6 fix (C03):
    /// the normalized-name map alone cannot be rebuilt under a new
    /// locale at decode time, because the display names it was folded
    /// from were never stored — so a cache written under another locale
    /// silently lost its name matching with no correction path. The
    /// raw names are now persisted (one extra map, same keys as the
    /// programmes), and the decoder rebuilds the name map from them
    /// under the current locale, exactly like the id map since round 5.
    var channelDisplayNames: [String: [String]]
    var channelIDsByNormalizedName: [String: [String]]
    /// Precomputed normalized-id lookup (round-4 C09): programs(for:)
    /// used to scan and normalize every guide key on every call when the
    /// exact id missed. The map is built once by the guide builder and
    /// rebuilt on every decode (round-5 C05: a stored map folded under
    /// another locale must never be trusted).
    var channelIDsByNormalizedID: [String: [String]]

    init(programsByChannelID: [String: [EPGProgram]], channelIDsByNormalizedName: [String: [String]], channelIDsByNormalizedID: [String: [String]] = [:], channelDisplayNames: [String: [String]] = [:]) {
        self.programsByChannelID = programsByChannelID
        self.channelIDsByNormalizedName = channelIDsByNormalizedName
        self.channelIDsByNormalizedID = channelIDsByNormalizedID
        self.channelDisplayNames = channelDisplayNames
    }

    private enum CodingKeys: String, CodingKey { case programsByChannelID, channelIDsByNormalizedName, channelIDsByNormalizedID, channelDisplayNames }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        programsByChannelID = try container.decode([String: [EPGProgram]].self, forKey: .programsByChannelID)
        channelDisplayNames = try container.decodeIfPresent([String: [String]].self, forKey: .channelDisplayNames) ?? [:]
        // Round-6 fix (C03): rebuild the name map from the stored raw
        // display names under the current locale, mirroring the round-5
        // id-map rebuild. The stored name map is only trusted as a
        // fallback for caches written before display names were
        // persisted (those caches are replaced on the next guide
        // refresh); trusting it unconditionally was the bug — folding is
        // locale-sensitive, so a non-empty stored map can miss every key
        // computed under the current locale while programs(for:) has no
        // scan fallback on the name path at all.
        if channelDisplayNames.isEmpty {
            channelIDsByNormalizedName = try container.decodeIfPresent([String: [String]].self, forKey: .channelIDsByNormalizedName) ?? [:]
        } else {
            var rebuilt: [String: [String]] = [:]
            for (channelID, names) in channelDisplayNames {
                for name in names where !rebuilt[Self.normalizedID(name), default: []].contains(channelID) {
                    rebuilt[Self.normalizedID(name), default: []].append(channelID)
                }
            }
            channelIDsByNormalizedName = rebuilt
        }
        // Round-5 fix (C05): the stored map used to be trusted as-is,
        // but its keys were folded under the locale in effect when the
        // cache was written (folding is locale-sensitive, e.g. Turkish
        // case folding). A map built under another locale can be
        // non-empty yet miss every key computed under the current
        // locale, and programs(for:) only scanned as a fallback when the
        // map was empty — so id matching silently failed with no
        // correction path. Rebuild from the guide keys on every decode
        // (one pass at load time, not per body evaluation); the encoded
        // map is kept for format compatibility but never trusted.
        // The programs(for:) empty-map scan stays as the fallback for
        // in-memory guides built without the map; it is deliberately
        // not widened into a map refresh there, because mutating the
        // @Published guide during a view body evaluation would itself
        // trigger a re-render cycle.
        var built: [String: [String]] = [:]
        for id in programsByChannelID.keys {
            built[Self.normalizedID(id), default: []].append(id)
        }
        channelIDsByNormalizedID = built
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(programsByChannelID, forKey: .programsByChannelID)
        try container.encode(channelIDsByNormalizedName, forKey: .channelIDsByNormalizedName)
        try container.encode(channelIDsByNormalizedID, forKey: .channelIDsByNormalizedID)
        try container.encode(channelDisplayNames, forKey: .channelDisplayNames)
    }

    /// Same normalization as AppState's id matching: case/diacritic/
    /// width folding, letters and numbers only.
    static func normalizedID(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    static let empty = EPGGuide(programsByChannelID: [:], channelIDsByNormalizedName: [:])
}

enum PlaylistKind: String, CaseIterable, Identifiable, Codable {
    case m3u = "M3U / TXT"
    case xtream = "Xtream"
    case tvHeadend = "tvHeadend"

    var id: String { rawValue }
}

struct Playlist: Identifiable, Hashable, Codable {
    /// Sentinel endpoint for playlists imported from a local file. Centralized
    /// here so no call site compares against a bare localized string.
    static let localFileEndpoint = "本地文件"
    let id: UUID
    var name: String
    var kind: PlaylistKind
    var endpoint: String
    var username: String
    /// Transient only: never encoded. The real credential lives in the
    /// Keychain (see KeychainStore); this field only carries a value across
    /// a single add/edit operation or a one-time legacy migration.
    var password: String
    var channelCount: Int
    var lastRefresh: Date?

    var isLocalFile: Bool { endpoint == Self.localFileEndpoint }

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

    private enum CodingKeys: String, CodingKey { case id, name, kind, endpoint, username, channelCount, lastRefresh }
    private enum LegacyCodingKeys: String, CodingKey { case id, name, kind, endpoint, username, password, channelCount, lastRefresh }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LegacyCodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(PlaylistKind.self, forKey: .kind)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        // Legacy files stored the password in plain text. It is read here
        // only so AppState can migrate it to the Keychain and then drop it.
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        channelCount = try container.decodeIfPresent(Int.self, forKey: .channelCount) ?? 0
        lastRefresh = try container.decodeIfPresent(Date.self, forKey: .lastRefresh)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(username, forKey: .username)
        try container.encode(channelCount, forKey: .channelCount)
        try container.encodeIfPresent(lastRefresh, forKey: .lastRefresh)
    }
}
