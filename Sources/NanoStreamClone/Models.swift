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
    // Dev round 1 (DEV-MODEL): optional channel number (M3U tvg-chno),
    // alternate/lineup URLs merged from duplicate entries of the same
    // name+group, and a catchup template (M3U catchup-source) used by
    // DEV-REPLAY. All three stay empty when the source does not provide
    // them; nothing here is ever guessed from the channel name.
    var channelNumber: String?
    var alternateURLs: [URL]
    var catchupSource: String?
    // Dev round 8 (R8-08): user-assigned tags. Never filled from the
    // source at import (nothing is guessed); the AppState tag map is
    // the source of truth and re-attaches them after every refresh,
    // so a re-parse never wipes them. Empty stays empty.
    var tags: [String]

    init(id: String? = nil, name: String, group: String, streamURL: URL? = nil, logoURL: URL? = nil, epgID: String? = nil, quality: String? = nil, isLive: Bool = true, channelNumber: String? = nil, alternateURLs: [URL] = [], catchupSource: String? = nil, tags: [String] = []) {
        self.id = id ?? Self.stableID(name: name, streamURL: streamURL)
        self.name = name
        self.group = group.isEmpty ? GroupID.other : group
        self.streamURL = streamURL
        self.logoURL = logoURL
        self.epgID = epgID
        self.quality = Self.normalizedQuality(quality)
        self.isLive = isLive
        self.channelNumber = channelNumber?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.alternateURLs = alternateURLs
        self.catchupSource = catchupSource?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.tags = Self.normalizedTags(tags)
    }

    /// Trimmed, deduplicated, order-preserving. Used by init and by
    /// AppState's tag map so both sides agree on what a tag list is.
    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            result.append(cleaned)
        }
        return result
    }

    private enum CodingKeys: String, CodingKey { case id, name, group, streamURL, logoURL, epgID, quality, isLive, channelNumber, alternateURLs, catchupSource, tags }

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
        // decodeIfPresent keeps caches written before dev round 1
        // readable: the new fields simply default to empty.
        channelNumber = try container.decodeIfPresent(String.self, forKey: .channelNumber)
        alternateURLs = try container.decodeIfPresent([URL].self, forKey: .alternateURLs) ?? []
        catchupSource = try container.decodeIfPresent(String.self, forKey: .catchupSource)
        // decodeIfPresent keeps caches written before dev round 8
        // readable: untagged channels simply decode to [].
        tags = Self.normalizedTags(try container.decodeIfPresent([String].self, forKey: .tags) ?? [])
    }

    /// Dev round 4 (R4-01): whether an id belongs to one of the
    /// pre-merge independent rows that folded into this entry. The
    /// first row's id is the entry id itself (a direct match); a
    /// second row's id was stableID(name|its URL), and that URL now
    /// lives in streamURL (adopted when the first row had none) or in
    /// alternateURLs. Matching those ids keeps old favorites and
    /// history resolving to the merged entry instead of silently
    /// disappearing. Nothing here is guessed: only ids the merge
    /// actually produced from this name and these URLs match.
    func matchesPreMergeLineID(_ id: String) -> Bool {
        if id == self.id { return true }
        if Self.stableID(name: name, streamURL: streamURL) == id { return true }
        return alternateURLs.contains { Self.stableID(name: name, streamURL: $0) == id }
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

    /// Dev round 1 (DEV-REPLAY): builds a catchup URL for a programme
    /// from the source-provided catchup-source template, or nil when the
    /// source gave no template or the template has no placeholder this
    /// app understands. Supported placeholders (unix seconds unless
    /// noted): {start} / {utc_start}, {end} / {utc_end}, {duration}
    /// (seconds). A template without any of these is NOT guessed at:
    /// callers show an explicit "unsupported format" prompt instead of
    /// playing a fabricated URL.
    func replayURL(for program: EPGProgram) -> URL? {
        guard let template = catchupSource, !template.isEmpty else { return nil }
        let start = Int(program.start.timeIntervalSince1970)
        let end = Int(program.end.timeIntervalSince1970)
        let duration = max(end - start, 0)
        var url = template
        let substitutions: [(String, String)] = [
            ("{start}", "\(start)"), ("{utc_start}", "\(start)"),
            ("{end}", "\(end)"), ("{utc_end}", "\(end)"),
            ("{duration}", "\(duration)"),
        ]
        var replaced = false
        for (placeholder, value) in substitutions where url.contains(placeholder) {
            url = url.replacingOccurrences(of: placeholder, with: value)
            replaced = true
        }
        guard replaced else { return nil }
        return URL(string: url)
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

/// Dev round 2 (R2-17): one history entry. watchedAt is the moment
/// playback started; progress is the VOD position fraction (0...1) at
/// the last switch/close, or nil for live streams and for entries
/// migrated from the old plain-id history (no time is fabricated).
struct RecentEntry: Codable, Hashable {
    var channelID: String
    var watchedAt: Date?
    var progress: Double?

    init(channelID: String, watchedAt: Date? = nil, progress: Double? = nil) {
        self.channelID = channelID
        self.watchedAt = watchedAt
        self.progress = progress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelID = try container.decode(String.self, forKey: .channelID)
        watchedAt = try container.decodeIfPresent(Date.self, forKey: .watchedAt)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress)
    }

    private enum CodingKeys: String, CodingKey { case channelID, watchedAt, progress }
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
    // Dev round 2 (R2-12): whether this playlist joins the home merged
    // browse. Defaults true; decodeIfPresent keeps old files enabled.
    // Disabling only affects home merged browsing, never favorites,
    // history resolution or per-playlist detail browsing.
    var isEnabled: Bool = true
    // Dev round 2 (R2-13): the x-tvg-url carried by this playlist's own
    // M3U header (#EXTM3U), or nil when the header has none. Never a
    // fabricated default; a manually entered guide URL always wins over
    // this value when AppState resolves the effective EPG source.
    var autoEPGURL: String?

    var isLocalFile: Bool { endpoint == Self.localFileEndpoint }

    init(id: UUID = UUID(), name: String, kind: PlaylistKind, endpoint: String, username: String = "", password: String = "", channelCount: Int = 0, lastRefresh: Date? = nil, isEnabled: Bool = true, autoEPGURL: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.channelCount = channelCount
        self.lastRefresh = lastRefresh
        self.isEnabled = isEnabled
        self.autoEPGURL = autoEPGURL
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, endpoint, username, channelCount, lastRefresh, isEnabled, autoEPGURL }
    private enum LegacyCodingKeys: String, CodingKey { case id, name, kind, endpoint, username, password, channelCount, lastRefresh, isEnabled, autoEPGURL }

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
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        autoEPGURL = try container.decodeIfPresent(String.self, forKey: .autoEPGURL)
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
