import Foundation
import AVFoundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var channels: [Channel] { didSet { cachedGroups = nil } }
    @Published var playlists: [Playlist]
    @Published var favorites: Set<String>
    @Published var recent: [String]
    @Published var selectedChannel: Channel?
    @Published var selectedGroup = GroupID.all
    @Published var searchText = ""
    @Published var isLoadingPlaylist = false
    @Published var playlistError: String?
    @Published var language: String
    @Published var themeMode: String
    @Published var colorTheme: String
    @Published var preferredPlayer: PreferredPlayer
    @Published var networkBufferMilliseconds: Double
    @Published var gridLayout: GridLayout
    @Published var pictureInPicture: Bool
    @Published var hardwareAcceleration: Bool
    @Published var automaticAudioSelection: Bool
    @Published var activePlaylistID: UUID?
    @Published var epgURL: String
    @Published var epgDraftURL: String
    @Published var epgRefreshIntervalMinutes: Int
    @Published private(set) var epgLastUpdated: Date?
    @Published private(set) var epgGuide = EPGGuide.empty
    @Published private(set) var isLoadingEPG = false
    @Published private(set) var epgError: String?
    @Published var previewEnabled: Bool
    @Published var showLatency: Bool
    /// Non-error notice channel (e.g. "image cache cleared"). Success messages
    /// used to be written into playlistError, which both hid real errors and
    /// rendered success text in the error style.
    @Published var notice: String?
    /// When the current notice was set. Round-6 fix (A03): `notice` used
    /// to live for the whole session (nothing ever cleared it), so a
    /// dedup-refresh message shown once kept reappearing on the playlist
    /// page, the settings data section and the form page long after it
    /// was relevant. Notices are now time-gated: views render
    /// `currentNotice`, which is nil once the notice is older than
    /// 30 seconds (a fresh render after that point hides it). The raw
    /// value is kept for the gating computation itself.
    private var noticeDate = Date.distantPast
    /// Whether the current notice is an error. Round-7 fix (A04): the
    /// round-6 30-second window was applied blindly to every notice,
    /// including the save-failure error, which the home page never
    /// rendered — so a failure on the home/detail page could expire
    /// unseen. Success notices still expire after 30 seconds; error
    /// notices persist until replaced (the pre-round-6 behaviour for
    /// errors) and are now also rendered on the home page.
    private var noticeIsError = false
    /// The notice to display, if it is still fresh (see noticeDate).
    /// Error notices do not expire (see noticeIsError).
    var currentNotice: String? {
        guard let notice else { return nil }
        if noticeIsError { return notice }
        guard Date().timeIntervalSince(noticeDate) < 30 else { return nil }
        return notice
    }
    /// Home-visible proxy authentication warning, or nil when the proxy
    /// looks usable. Round-7 fix (C04): the no-password and
    /// migration-failure warnings used to render only on the settings
    /// page, so a refresh from the home/detail page that hit a 407
    /// showed only a generic load error. The home error bar now also
    /// shows this text (same conditions and wording as the settings
    /// warnings, so the two surfaces cannot disagree).
    /// Compile-fix round: this property used to live on enum M3UParser,
    /// where it could neither call AppState's instance method
    /// localized(_:) nor be reached as state.proxyAuthWarning from
    /// ContentView — both are AppState members, so the property lives
    /// here now. Logic unchanged.
    var proxyAuthWarning: String? {
        let raw = UserDefaults.standard.string(forKey: "httpProxy") ?? ""
        guard let parsed = M3UParser.parseProxy(raw) else { return nil }
        // Round-12 fix (A01): the migration-failure warning fires only
        // for the identity that actually failed. A stale flag from a
        // previous identity must not be blamed on the identity now in
        // the field — with round-11 deferred saving, a background
        // refresh during an edit never attempts a write, so without
        // this scoping the old warning would linger against a password
        // that was never tried. (A nil failed identity still warns, as
        // a defensive fallback; see proxyMigrationFailedIdentity.)
        if M3UParser.proxyMigrationFailed, parsed.password != nil,
           M3UParser.proxyMigrationFailedIdentity == nil || M3UParser.proxyMigrationFailedIdentity == M3UParser.canonicalProxy(host: parsed.host, port: parsed.port, username: parsed.username) {
            return localized("代理密码未能存入钥匙串，仍以明文保存在本地。请重新输入代理密码。")
        }
        if let user = parsed.username, !user.isEmpty, parsed.password == nil,
           KeychainStore.proxyPassword(forProxy: M3UParser.canonicalProxy(host: parsed.host, port: parsed.port, username: user)) == nil {
            return localized("代理已填写用户名但未提供密码，请求将以无认证方式发出。请补全密码或清除用户名。")
        }
        return nil
    }
    /// Sets a notice and stamps it, so its 30-second display window
    /// starts at the moment it is produced, not at some later render.
    /// Pass isError: true for failure notices, which must not expire
    /// unseen (round-7 A04).
    func setNotice(_ text: String?, isError: Bool = false) {
        notice = text
        noticeIsError = isError
        noticeDate = Date()
    }
    /// True when the persisted library failed to decode at launch. The corrupt
    /// bytes are preserved under storageKey + ".bak" (see init) instead of
    /// being silently overwritten by an empty state.
    @Published private(set) var stateRestoreFailed = false
    /// True while a cached playlist is being refreshed in the background.
    /// Distinct from isLoadingPlaylist (no cache yet): cached channels stay
    /// visible during a refresh instead of flashing to an empty grid.
    @Published private(set) var isRefreshingPlaylist = false
    private var channelSetsByPlaylist: [UUID: [Channel]]
    private var epgTask: Task<Void, Never>?
    /// The in-flight EPG download/parse itself. Cancelling only epgTask
    /// used to leave a detached download running to completion (its result
    /// was merely discarded); this handle is cancelled alongside it.
    private var epgFetchTask: Task<EPGGuide, Error>?
    /// Handles of the detached local-file parses (round-4 C13): the
    /// generation guard used to only discard a superseded parse's result
    /// while the parse itself ran to completion. Cancelling the handle
    /// (plus the checkpoint in parseReport) actually stops it early.
    private var localChannelsParseTask: Task<[Channel], Never>?
    private var localReportParseTask: Task<(channels: [Channel], skipped: Int), Never>?
    private var epgRefreshLoopTask: Task<Void, Never>?
    /// Generation guard for EPG loads: a manual reload, a timer tick and a
    /// previous load must never race, with the slower older result
    /// overwriting a newer guide.
    private var epgGeneration = 0
    private var playlistGeneration = 0
    private var activeLoadTask: Task<Void, Never>?
    private var cachedGroups: [String]?
    private let epgGuideCacheKey = "nanostream.epgGuide"
    private let epgDraftCacheKey = "nanostream.epgDraftURL"

    /// File cache for the EPG guide (replaces the old UserDefaults cache).
    static func epgGuideCacheFileURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("nanostream.epgGuide.json")
    }

    // v4 intentionally starts with no bundled/demo channels. Existing installs
    // using the old demo state are migrated to a clean, user-owned library.
    private let storageKey = "nanostream.state.v4"

    init() {
        let initialEPGURL = UserDefaults.standard.string(forKey: "nanostream.epgURL") ?? ""
        var restoreFailed = false
        if let data = UserDefaults.standard.data(forKey: storageKey) {
            if let saved = Self.restore(data: data) {
                channels = saved.channels
                playlists = saved.playlists
                favorites = saved.favorites
                recent = saved.recent
                // Do not guess an active playlist: a saved id that no longer
                // exists stays nil so the UI can prompt for a choice instead
                // of showing another playlist's channels under its name.
                activePlaylistID = saved.activePlaylistID.flatMap { id in saved.playlists.contains(where: { $0.id == id }) ? id : nil }
                channelSetsByPlaylist = saved.channelSetsByPlaylist ?? [:]
                // A clean restore supersedes any backup from an earlier
                // corrupt launch; delete the expired backup.
                UserDefaults.standard.removeObject(forKey: storageKey + ".bak")
            } else {
                // Preserve the corrupt bytes for manual recovery, then clear
                // the main key so the next save does not destroy the only copy.
                // Round-2 fix: the backup is stored with every "password"
                // key stripped (legacy files stored passwords in plain text),
                // and it is deleted again on the next successful save or
                // restore, so no stale plain-text backup lingers forever.
                if let stripped = Self.strippedBackupData(data) {
                    UserDefaults.standard.set(stripped, forKey: storageKey + ".bak")
                }
                UserDefaults.standard.removeObject(forKey: storageKey)
                restoreFailed = true
                channels = []
                playlists = []
                favorites = []
                recent = []
                activePlaylistID = nil
                channelSetsByPlaylist = [:]
            }
        } else {
            channels = []
            playlists = []
            favorites = []
            recent = []
            activePlaylistID = nil
            channelSetsByPlaylist = [:]
        }
        stateRestoreFailed = restoreFailed
        language = UserDefaults.standard.string(forKey: "nanostream.language") ?? "中文"
        themeMode = UserDefaults.standard.string(forKey: "nanostream.theme") ?? "System"
        colorTheme = Self.migratedColorTheme(UserDefaults.standard.string(forKey: "nanostream.colorTheme") ?? "toxic")
        let defaults = UserDefaults.standard
        // Migration fix: respect a previously stored player preference even
        // when the v1 flag is absent (older installs were forced to KSPlayer).
        // Second-launch regression (round 2): the old code set the flag AND
        // overwrote nanostream.player with KSPlayer whenever the flag was
        // absent, so a stored AVPlayer preference was clobbered on the very
        // next launch. Now a stored value is only honoured, never rewritten;
        // the KSPlayer default is written only when no value exists at all.
        if let storedPlayer = defaults.string(forKey: "nanostream.player"),
           let preferred = PreferredPlayer(rawValue: storedPlayer) {
            preferredPlayer = preferred
        } else {
            preferredPlayer = .ksPlayer
            defaults.set(PreferredPlayer.ksPlayer.rawValue, forKey: "nanostream.player")
        }
        if !defaults.bool(forKey: "nanostream.ksPlayerDefault.v1") {
            defaults.set(true, forKey: "nanostream.ksPlayerDefault.v1")
        }
        networkBufferMilliseconds = Self.clampedBuffer(Self.doubleValue(forKey: "nanostream.buffer") ?? 3000)
        gridLayout = GridLayout(rawValue: UserDefaults.standard.string(forKey: "nanostream.grid") ?? GridLayout.twoColumns.rawValue) ?? .twoColumns
        pictureInPicture = Self.boolValue(forKey: "nanostream.pip") ?? true
        hardwareAcceleration = Self.boolValue(forKey: "nanostream.hardwareAcceleration") ?? true
        automaticAudioSelection = Self.boolValue(forKey: "nanostream.automaticAudioSelection") ?? true
        epgURL = initialEPGURL
        epgDraftURL = UserDefaults.standard.string(forKey: epgDraftCacheKey) ?? initialEPGURL
        epgRefreshIntervalMinutes = Self.intValue(forKey: "nanostream.epgRefreshIntervalMinutes") ?? 0
        epgLastUpdated = UserDefaults.standard.object(forKey: "nanostream.epgLastUpdated") as? Date
        // Round-2 fix: the guide cache no longer lives in UserDefaults
        // (a 7-day guide can approach the 32MB fetch cap and does not
        // belong in a preferences store). It is a file in the caches
        // directory; a legacy UserDefaults cache is migrated once, then
        // its key is deleted.
        if let legacyData = UserDefaults.standard.data(forKey: epgGuideCacheKey) {
            // Round-3 fix (C10): write the file FIRST and only delete the
            // old key on success. The old order (delete, then try? write)
            // destroyed the only copy whenever the caches directory was
            // unwritable or the disk was full.
            var migratedCache = false
            if let url = Self.epgGuideCacheFileURL() {
                do {
                    try legacyData.write(to: url, options: .atomic)
                    migratedCache = true
                } catch {
                    migratedCache = false
                }
            }
            if migratedCache {
                UserDefaults.standard.removeObject(forKey: epgGuideCacheKey)
            }
        }
        if let url = Self.epgGuideCacheFileURL(),
           let guideData = try? Data(contentsOf: url),
           let guide = try? JSONDecoder().decode(EPGGuide.self, from: guideData),
           !guide.programsByChannelID.isEmpty {
            epgGuide = guide
        } else {
            // A stale "last updated" timestamp with no guide is misleading.
            epgLastUpdated = nil
        }
        previewEnabled = Self.boolValue(forKey: "nanostream.previewEnabled") ?? false
        showLatency = Self.boolValue(forKey: "nanostream.showLatency") ?? false
        // (moved) Cached channels for the active playlist: this reads
        // self properties, so it must run after every stored property
        // has been assigned (see below); it used to sit inside the
        // restore branch, before the rest of init had run.
        if let active = activePlaylistID, let cached = channelSetsByPlaylist[active] {
            channels = cached
        }

        // One-time migration: legacy playlists decoded with a plain-text
        // password move it to the Keychain, then drop it from memory.
        // SavedState encoding no longer writes passwords at all.
        // Round-3 fix (C01): credentials embedded in the endpoint string
        // itself (a pasted get.php?username=&password=, or a tvHeadend
        // address with userinfo) are stripped here too, not just the
        // password field. The generic tvHeadend sanitizer strips userinfo
        // and username/password query items for any path, so it doubles
        // as the endpoint cleaner for both kinds.
        var migrated = false
        var migrationPasswordFailed = false
        for index in playlists.indices {
            let cleaned = PlaylistLoader.sanitizedTvHeadend(endpoint: playlists[index].endpoint, username: playlists[index].username, password: playlists[index].password)
            if cleaned.endpoint != playlists[index].endpoint || cleaned.username != playlists[index].username || cleaned.password != playlists[index].password {
                playlists[index].endpoint = cleaned.endpoint
                playlists[index].username = cleaned.username
                playlists[index].password = cleaned.password
                migrated = true
            }
        }
        for index in playlists.indices where !playlists[index].password.isEmpty {
            // Round-3 fix (C14): only clear the in-memory password when
            // the Keychain write (with read-back verification) actually
            // succeeded. Previously the return value was ignored, so a
            // failed write silently destroyed the only copy.
            if KeychainStore.savePassword(playlists[index].password, for: playlists[index].id) {
                playlists[index].password = ""
                migrated = true
            } else {
                migrationPasswordFailed = true
            }
        }
        // Round-4 fix (C04): on a migration failure the old persisted
        // state is the ONLY other copy of the password (SavedState never
        // writes passwords), so saving now would overwrite it with a
        // passwordless state and lose the credential on the next launch.
        // Skip the migration save, keep the in-memory password for this
        // session, and surface a visible error prompting the user to
        // re-enter the password (which re-saves it to Keychain). The
        // residual gap: any later save() in this session still persists
        // a passwordless state, so re-entering promptly matters.
        if migrationPasswordFailed {
            saveError = localized("播放列表密码迁移失败，请重新输入该列表的密码。")
        } else if migrated { save() }

        if !epgURL.isEmpty {
            reloadEPG()
            startEPGRefreshLoop()
        }
    }

    /// Maps legacy color-theme storage values (a mix of an English name and
    /// Chinese names) to language-independent ids.
    static func migratedColorTheme(_ raw: String) -> String {
        switch raw {
        case "cyberpunk", "sunset", "toxic", "neonPink", "deepBlue": return raw
        case "Cyberpunk": return "cyberpunk"
        case "落日金": return "sunset"
        case "剧毒绿": return "toxic"
        case "霓虹粉": return "neonPink"
        case "深海蓝": return "deepBlue"
        default: return "toxic"
        }
    }

    static func clampedBuffer(_ value: Double) -> Double { min(max(value, 500), 10000) }

    /// Type-tolerant UserDefaults reads: an Int stored where a Double is
    /// expected (or a numeric string) no longer silently resets the setting.
    static func doubleValue(forKey key: String) -> Double? {
        let value = UserDefaults.standard.object(forKey: key)
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
    static func intValue(forKey key: String) -> Int? {
        let value = UserDefaults.standard.object(forKey: key)
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
    static func boolValue(forKey key: String) -> Bool? {
        let value = UserDefaults.standard.object(forKey: key)
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch text.lowercased() { case "true", "1", "yes": return true; case "false", "0", "no": return false; default: return nil }
        }
        return nil
    }

    var groups: [String] {
        if let cached = cachedGroups { return cached }
        // A channel whose literal group is "全部" must not duplicate the
        // "all" sentinel (that produced duplicate ForEach ids).
        let names = Set(channels.map(\.group)).filter { $0 != GroupID.all }.sorted()
        let result = [GroupID.all] + names
        cachedGroups = result
        return result
    }

    /// Display name for a group sentinel or a real group name.
    func localizedGroup(_ group: String) -> String {
        switch group {
        case GroupID.all: return localized("全部")
        case GroupID.other: return localized("其他")
        // Round-4 fix (C08): a real group literally named "__all__" /
        // "__other__" is escaped with a zero-width space at parse time,
        // which displays identically to the sentinel — the menu showed
        // two indistinguishable "全部" entries with different behaviour.
        // Suffix the escaped name so the real group is visibly distinct.
        case GroupID.all + "\u{200B}": return "\(localized("全部"))（\(localized("分组")))"
        case GroupID.other + "\u{200B}": return "\(localized("其他"))（\(localized("分组")))"
        // Round-5 fix (C06): the same collision exists at the label
        // level - a real group literally named like a sentinel label
        // in any language displays identically to the sentinel in the
        // menu but filters instead of showing all. The groups filter
        // only excludes the internal __all__ id, so this was never
        // caught; suffix such real groups the same way as the escaped
        // internal sentinels. All four languages' labels are checked,
        // so switching language cannot re-create the clash.
        default:
            let sentinelLabels: Set<String> = ["全部", "All", "Tất cả", "其他", "Other", "Khác"]
            if sentinelLabels.contains(group) {
                return "\(group)（\(localized("分组"))）"
            }
            return group
        }
    }

    /// Every channel known to any playlist, not just the active one, so
    /// favorites and recent items do not "disappear" when switching playlists.
    /// Round-3 fix (C05): stableID is still name|streamURL by design, so
    /// the same channel in two subscriptions still shares one id — but
    /// resolution is now deterministic: playlists are walked in list order
    /// (first playlist wins) instead of dictionary order, which previously
    /// made "which copy wins" nondeterministic across launches. A
    /// favorite/recent entry therefore always resolves to the first
    /// playlist that contains it.
    var allChannels: [Channel] {
        var seen = Set<String>()
        var result: [Channel] = []
        var ordered: [Channel] = []
        for playlist in playlists {
            ordered.append(contentsOf: channelSetsByPlaylist[playlist.id] ?? [])
        }
        ordered.append(contentsOf: channels)
        for channel in ordered where seen.insert(channel.id).inserted {
            result.append(channel)
        }
        return result
    }

    var visibleChannels: [Channel] {
        // Loading no longer blanks the grid: callers show a spinner over the
        // previous (or empty) list, and a background refresh keeps its cache.
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return channels.filter { channel in
            (selectedGroup == GroupID.all || channel.group == selectedGroup) &&
            (query.isEmpty || channel.name.localizedCaseInsensitiveContains(query) || channel.group.localizedCaseInsensitiveContains(query))
        }
    }

    var favoriteChannels: [Channel] { allChannels.filter { favorites.contains($0.id) } }

    var accent: Color {
        switch colorTheme {
        case "cyberpunk": return Color(red: 0.2, green: 0.8, blue: 1)
        case "sunset": return Color(red: 1, green: 0.72, blue: 0.2)
        case "neonPink": return Color(red: 1, green: 0.28, blue: 0.72)
        case "deepBlue": return Color(red: 0.25, green: 0.55, blue: 1)
        default: return Color(red: 0.2, green: 1.0, blue: 0.12)
        }
    }

    var colorScheme: ColorScheme? {
        switch themeMode { case "Light": return .light; case "Dark": return .dark; default: return nil }
    }

    func setLanguage(_ value: String) { language = value; UserDefaults.standard.set(value, forKey: "nanostream.language") }
    func setTheme(_ value: String) { themeMode = value; UserDefaults.standard.set(value, forKey: "nanostream.theme") }
    func setColorTheme(_ value: String) { colorTheme = value; UserDefaults.standard.set(value, forKey: "nanostream.colorTheme") }
    func setPreferredPlayer(_ value: PreferredPlayer) { preferredPlayer = value; UserDefaults.standard.set(value.rawValue, forKey: "nanostream.player") }
    func setBuffer(_ value: Double) { networkBufferMilliseconds = Self.clampedBuffer(value); UserDefaults.standard.set(networkBufferMilliseconds, forKey: "nanostream.buffer") }
    func setGridLayout(_ value: GridLayout) { gridLayout = value; UserDefaults.standard.set(value.rawValue, forKey: "nanostream.grid") }
    func setPictureInPicture(_ value: Bool) { pictureInPicture = value; UserDefaults.standard.set(value, forKey: "nanostream.pip") }
    func setHardwareAcceleration(_ value: Bool) { hardwareAcceleration = value; UserDefaults.standard.set(value, forKey: "nanostream.hardwareAcceleration") }
    func setAutomaticAudioSelection(_ value: Bool) { automaticAudioSelection = value; UserDefaults.standard.set(value, forKey: "nanostream.automaticAudioSelection") }
    func setPreviewEnabled(_ value: Bool) { previewEnabled = value; UserDefaults.standard.set(value, forKey: "nanostream.previewEnabled") }
    func setShowLatency(_ value: Bool) { showLatency = value; UserDefaults.standard.set(value, forKey: "nanostream.showLatency") }
    func localized(_ key: String) -> String {
        guard language != "中文" else { return key }
        let table: [String: (String, String)] = [
            "设置": ("Settings", "Cài đặt"), "播放列表": ("Playlists", "Danh sách phát"), "收藏": ("Favorites", "Yêu thích"), "主页": ("Home", "Trang chủ"),
            "全部": ("All", "Tất cả"), "搜索频道...": ("Search channels...", "Tìm kênh..."), "最近播放": ("Recently played", "Đã phát gần đây"),
            "暂无播放记录": ("No playback history", "Chưa có lịch sử phát"), "暂无频道": ("No channels", "Chưa có kênh"),
            "请先在“播放列表”中添加 M3U 或 Xtream 来源。": ("Add an M3U or Xtream source in Playlists first.", "Hãy thêm nguồn M3U hoặc Xtream trong Danh sách phát."),
            "无收藏频道": ("No favorite channels", "Chưa có kênh yêu thích"), "用星号标记频道以便在此快速访问。": ("Star a channel to access it here.", "Đánh dấu sao để truy cập nhanh tại đây."),
            "暂无播放列表": ("No playlists", "Chưa có danh sách phát"), "添加播放列表": ("Add playlist", "Thêm danh sách phát"), "关闭": ("Close", "Đóng"),
            "订阅": ("Subscriptions", "Đăng ký"), "频道": ("Channels", "Kênh"), "节目": ("Programs", "Chương trình"), "选择订阅": ("Choose subscription", "Chọn đăng ký"), "暂无节目数据": ("No program data", "Chưa có dữ liệu chương trình"), "当前节目": ("Now", "Đang phát"), "下一节目": ("Next", "Tiếp theo"),
            "编码信息": ("Stream information", "Thông tin luồng"), "暂无数据": ("Unavailable", "Không có dữ liệu"), "播放失败，请检查频道地址。": ("Playback failed. Check the channel URL.", "Phát không thành công. Hãy kiểm tra URL kênh."),
            "语言": ("Language", "Ngôn ngữ"), "外观": ("Appearance", "Giao diện"), "播放设置": ("Playback", "Phát lại"), "网络": ("Network", "Mạng"), "缓冲区": ("Buffer", "Bộ đệm"), "数据与缓存": ("Data & cache", "Dữ liệu & bộ nhớ đệm"), "预览": ("Live preview", "Xem trước trực tiếp"), "显示延迟": ("Show latency", "Hiển thị độ trễ"),
            "主题模式": ("Theme", "Chủ đề"), "色彩主题": ("Accent color", "Màu nhấn"), "画中画": ("Picture in Picture", "Hình trong hình"), "硬件加速": ("Hardware acceleration", "Tăng tốc phần cứng"), "自动选择音轨": ("Auto-select audio", "Tự chọn âm thanh"), "首选播放器": ("Preferred player", "Trình phát ưu tiên"), "字幕大小": ("Subtitle size", "Cỡ phụ đề"), "EPG节目单": ("EPG guide", "EPG"), "EPG地址": ("EPG URL", "URL EPG"), "保存节目单": ("Save guide", "Lưu EPG"), "更新节目单地址": ("Update guide URL", "Cập nhật URL EPG"), "删除节目单": ("Delete guide", "Xóa EPG"), "刷新节目单": ("Refresh guide", "Làm mới EPG"), "自动刷新": ("Auto refresh", "Tự động làm mới"), "关闭自动刷新": ("Off", "Tắt"), "15分钟": ("15 minutes", "15 phút"), "30分钟": ("30 minutes", "30 phút"), "60分钟": ("60 minutes", "60 phút"), "6小时": ("6 hours", "6 giờ"), "节目单已更新。": ("Guide updated.", "EPG đã cập nhật."),
            "网络缓存大小": ("Network buffer", "Bộ đệm mạng"), "清除图片缓存": ("Clear image cache", "Xóa bộ nhớ ảnh"), "清除播放历史": ("Clear playback history", "Xóa lịch sử phát"), "选择本地 M3U 文件": ("Choose local M3U file", "Chọn tệp M3U cục bộ"), "输入列表名称": ("Playlist name", "Tên danh sách phát"), "详细信息": ("Details", "Chi tiết"), "播放列表来源": ("Playlist source", "Nguồn danh sách phát"), "添加列表": ("Add playlist", "Thêm danh sách phát"),
            "2列": ("2 columns", "2 cột"), "3列": ("3 columns", "3 cột"), "4列": ("4 columns", "4 cột"),
            "AVPlayer 使用系统原生解码，不支持的视频轨自动交给 KSPlayer。": ("AVPlayer uses Apple's native decoder and hands unsupported video tracks to KSPlayer.", "AVPlayer dùng bộ giải mã gốc của Apple và chuyển video không được hỗ trợ sang KSPlayer."),
            "KSPlayer 使用 FFmpeg，适合更多 IPTV 流格式。": ("KSPlayer uses FFmpeg for broader IPTV format support.", "KSPlayer dùng FFmpeg để hỗ trợ nhiều định dạng IPTV hơn."),
            "Auto 先尝试 AVPlayer，失败后自动切换 KSPlayer。": ("Auto tries AVPlayer first, then switches to KSPlayer if it fails.", "Tự động thử AVPlayer trước, sau đó chuyển sang KSPlayer nếu lỗi."),
            "网络连接较慢或不稳定时，可增加缓存": ("Increase the buffer for slow or unstable connections.", "Tăng bộ đệm khi kết nối chậm hoặc không ổn định."),
            "NanoStream 是一个媒体播放器外壳。请仅添加您有权观看的播放列表和视频流。": ("NanoStream is a media player shell. Only add playlists and streams you are authorized to watch.", "NanoStream là trình phát đa phương tiện. Chỉ thêm danh sách và luồng bạn được phép xem."),
            "文件中没有找到有效频道。": ("No valid channels were found in the file.", "Không tìm thấy kênh hợp lệ trong tệp."),
            "播放列表添加失败。": ("Failed to add the playlist.", "Không thể thêm danh sách phát."),
            "图片缓存已清除。": ("Image cache cleared.", "Đã xóa bộ nhớ ảnh."),
            "播放列表地址无效。": ("The playlist URL is invalid.", "URL danh sách phát không hợp lệ."),
            "播放列表为空或没有有效频道。": ("The playlist is empty or has no valid channels.", "Danh sách phát trống hoặc không có kênh hợp lệ."),
            "返回内容不是有效的 M3U 播放列表。": ("The response is not a valid M3U playlist.", "Nội dung trả về không phải danh sách M3U hợp lệ."),
            "系统": ("System", "Hệ thống"), "浅色": ("Light", "Sáng"), "深色": ("Dark", "Tối"),
            "赛博朋克": ("Cyberpunk", "Cyberpunk"), "落日金": ("Sunset Gold", "Vàng hoàng hôn"), "剧毒绿": ("Toxic Green", "Xanh độc"), "霓虹粉": ("Neon Pink", "Hồng neon"), "深海蓝": ("Deep Sea Blue", "Xanh biển sâu"),
            "本地文件": ("Local file", "Tệp cục bộ"), "M3U 链接": ("M3U link", "Liên kết M3U"), "服务器地址 (http://...)": ("Server URL (http://...)", "URL máy chủ (http://...)"), "用户名": ("Username", "Tên người dùng"), "密码": ("Password", "Mật khẩu"), "编辑播放列表": ("Edit playlist", "Sửa danh sách phát"), "保存并刷新": ("Save & refresh", "Lưu và làm mới"), "播放列表已更新。": ("Playlist updated.", "Đã cập nhật danh sách phát"), "节目单地址无效。": ("The EPG URL is invalid.", "URL EPG không hợp lệ."), "节目单服务器返回 HTTP": ("The EPG server returned HTTP", "Máy chủ EPG trả về HTTP"), "返回内容不是有效的 XMLTV 节目单。": ("The response is not a valid XMLTV guide.", "Nội dung không phải EPG XMLTV hợp lệ."), "节目单中没有找到有效节目。": ("No valid programmes were found in the guide.", "Không tìm thấy chương trình hợp lệ trong EPG."),
            "预览连接数已达上限": ("Preview connection limit reached", "Đã đạt giới hạn kết nối xem trước"), "延迟不可用": ("Latency unavailable", "Không có độ trễ"), "该频道没有可播放地址。": ("This channel has no playable URL.", "Kênh này không có URL phát được."), "无播放地址": ("No playable URL", "Không có URL phát"), "保存": ("Save", "Lưu"), "保存失败，数据未写入。": ("Save failed; data was not written.", "Lưu thất bại; dữ liệu chưa được ghi."), "网络超时，请检查网络后重试。": ("Network timed out. Check your connection and try again.", "Hết thời gian chờ mạng. Kiểm tra kết nối và thử lại."), "无网络连接。": ("No network connection.", "Không có kết nối mạng."), "无法找到服务器。": ("Server not found.", "Không tìm thấy máy chủ."), "无法连接到服务器。": ("Could not connect to the server.", "Không thể kết nối tới máy chủ."), "清除收藏": ("Clear favorites", "Xóa mục yêu thích"), "Xtream 账号或密码为空。": ("Xtream username or password is empty.", "Tên người dùng hoặc mật khẩu Xtream trống."), "节目单过大，超过 32MB 上限。": ("The guide is too large (over the 32 MB limit).", "EPG quá lớn (vượt giới hạn 32 MB)."), "已跳过无效频道行。": ("Skipped invalid channel lines.", "Đã bỏ qua các dòng kênh không hợp lệ."), "重试": ("Retry", "Thử lại"), "用 AVPlayer 重试": ("Retry with AVPlayer", "Thử lại bằng AVPlayer"), "正在加载新订阅…": ("Loading subscription…", "Đang tải đăng ký…"), "清除筛选": ("Clear filters", "Xóa bộ lọc"), "当前分组或搜索没有匹配的频道。": ("No channels match the current group or search.", "Không có kênh nào khớp với nhóm hoặc tìm kiếm hiện tại."), "旧播放列表数据损坏，已备份，无法自动恢复。": ("The saved library was corrupt and has been backed up; it could not be restored automatically.", "Thư viện đã lưu bị hỏng và đã được sao lưu; không thể khôi phục tự động."), "留空表示保持原密码": ("Leave blank to keep the existing password", "Để trống để giữ mật khẩu hiện tại"), "更改播放列表类型后，原地址将按新类型解析。": ("Changing the playlist type will re-interpret the existing address as the new type.", "Thay đổi loại danh sách sẽ diễn giải lại địa chỉ hiện tại theo loại mới."), "选择文件失败。": ("Failed to open the file picker.", "Không mở được trình chọn tệp."), "文件读取失败。": ("Failed to read the file.", "Không đọc được tệp."), "文件编码不受支持，请使用 UTF-8 文本。": ("The file encoding is not supported. Use UTF-8 text.", "Mã hóa tệp không được hỗ trợ. Hãy dùng văn bản UTF-8."), "前台自动刷新": ("Foreground auto-refresh", "Tự động làm mới khi mở ứng dụng"), "仅在 App 前台运行时刷新节目单。": ("The guide only refreshes while the app is in the foreground.", "EPG chỉ làm mới khi ứng dụng đang mở."), "码率上限": ("Bitrate cap", "Giới hạn tốc độ bit"), "其他": ("Other", "Khác"),
            // Round-3 localization batch (B01/A05/A13/B10/C23/A09): these
            // strings were previously hardcoded Chinese in the UI.
            "此设置暂未接入播放器字幕渲染，仅保存偏好。": ("This setting is not wired into player subtitle rendering yet; it only saves a preference.", "Cài đặt này chưa nối với kết xuất phụ đề của trình phát; chỉ lưu tùy chọn."),
            "留空时使用内置标识；仅用于 M3U/EPG 请求，KSPlayer 不读取此设置。": ("Leave blank to use the built-in identifier. Only used for M3U/EPG requests; KSPlayer does not read this setting.", "Để trống để dùng định danh tích hợp. Chỉ dùng cho yêu cầu M3U/EPG; KSPlayer không đọc cài đặt này."),
            "仅用于 M3U/EPG 请求（格式 host:port、http://host:port 或 user:pass@host:port，带认证的代理会把用户名密码发给代理服务器），KSPlayer 不读取此设置。": ("Only used for M3U/EPG requests (format host:port, http://host:port, or user:pass@host:port; an authenticated proxy receives the username and password); KSPlayer does not read this setting.", "Chỉ dùng cho yêu cầu M3U/EPG (định dạng host:port, http://host:port hoặc user:pass@host:port; proxy có xác thực sẽ nhận tên người dùng và mật khẩu); KSPlayer không đọc cài đặt này."),
            // Round-4 localization batch (A03 caption, A05 refresh notice,
            // C04 migration failure, C08 escaped-group suffix).
            "分组": ("Group", "Nhóm"),
            "已刷新已有本地列表。": ("Refreshed the existing local playlist.", "Đã làm mới danh sách phát cục bộ hiện có."),
            "播放列表密码迁移失败，请重新输入该列表的密码。": ("Playlist password migration failed. Please re-enter the password for that playlist.", "Không di chuyển được mật khẩu của danh sách phát. Hãy nhập lại mật khẩu cho danh sách đó."),
            "硬件加速仅影响 KSPlayer；AVPlayer 侧为系统默认解码行为，无额外效果。": ("Hardware acceleration only affects KSPlayer. On AVPlayer it is the system default decoding behaviour and has no extra effect.", "Tăng tốc phần cứng chỉ ảnh hưởng tới KSPlayer. Với AVPlayer, đó là hành vi giải mã mặc định của hệ thống và không có tác dụng thêm."),
            "代理格式无效，将直连。请使用 host:port 格式。": ("Invalid proxy format; connecting directly. Use the host:port format.", "Định dạng proxy không hợp lệ; sẽ kết nối trực tiếp. Hãy dùng định dạng host:port."),
            "清除": ("Clear", "Xóa"), "删除": ("Delete", "Xóa"),
            "确定清除全部播放历史吗？该操作无法撤销。": ("Clear all playback history? This cannot be undone.", "Xóa toàn bộ lịch sử phát? Hành động này không thể hoàn tác."),
            "确定清除全部收藏吗？该操作无法撤销。": ("Clear all favorites? This cannot be undone.", "Xóa toàn bộ mục yêu thích? Hành động này không thể hoàn tác."),
            "确定删除已保存的节目单来源、草稿、缓存指南、更新时间与自动刷新间隔吗？该操作无法撤销。": ("Delete the saved guide source, draft, cached guide, last-updated time and auto-refresh interval? This cannot be undone.", "Xóa nguồn EPG đã lưu, bản nháp, EPG đã lưu đệm, thời gian cập nhật và khoảng tự động làm mới? Hành động này không thể hoàn tác."),
            "确定删除播放列表吗？该操作无法撤销。": ("Delete this playlist? This cannot be undone.", "Xóa danh sách phát này? Hành động này không thể hoàn tác."),
            "播放列表过大，超过 32MB 上限。": ("The playlist is too large (over the 32 MB limit).", "Danh sách phát quá lớn (vượt giới hạn 32 MB)."),
            "预览连接数已达上限，点按重试": ("Preview connection limit reached. Tap to retry.", "Đã đạt giới hạn kết nối xem trước. Chạm để thử lại."),
            "画中画已停止": ("Picture in Picture stopped", "Hình trong hình đã dừng"),
            // Round-5 localization batch (A01 caption, A05 warning).
            "仅用于 M3U/EPG 请求（格式 host:port、http://host:port 或 user:pass@host:port；带认证的代理会把用户名密码发给代理服务器，密码存放在钥匙串中，不以明文保存），KSPlayer 不读取此设置。": ("Only used for M3U/EPG requests (format host:port, http://host:port, or user:pass@host:port; an authenticated proxy receives the username and password, and the password is stored in the Keychain, never in plain text); KSPlayer does not read this setting.", "Chỉ dùng cho yêu cầu M3U/EPG (định dạng host:port, http://host:port hoặc user:pass@host:port; proxy có xác thực sẽ nhận tên người dùng và mật khẩu, và mật khẩu được lưu trong Keychain, không lưu dưới dạng văn bản thuần); KSPlayer không đọc cài đặt này."),
            "代理格式无效，将直连。请使用 host:port、http://host:port 或 user:pass@host:port 格式。": ("Invalid proxy format; connecting directly. Use host:port, http://host:port, or user:pass@host:port.", "Định dạng proxy không hợp lệ; sẽ kết nối trực tiếp. Hãy dùng host:port, http://host:port hoặc user:pass@host:port."),
            // Round-6 localization batch (A01/A02/C01 proxy password).
            "仅用于 M3U/EPG 请求（格式 host:port、http://host:port 或 user:pass@host:port；带认证的代理会把用户名密码发给代理服务器，密码会迁移到钥匙串中；迁移失败时仍以明文保存在本地并显示警告），KSPlayer 不读取此设置。": ("Only used for M3U/EPG requests (format host:port, http://host:port, or user:pass@host:port; an authenticated proxy receives the username and password, and the password migrates to the Keychain; if migration fails it stays in plain text locally and a warning is shown); KSPlayer does not read this setting.", "Chỉ dùng cho yêu cầu M3U/EPG (định dạng host:port, http://host:port hoặc user:pass@host:port; proxy có xác thực sẽ nhận tên người dùng và mật khẩu, và mật khẩu được chuyển vào Keychain; nếu chuyển thất bại, mật khẩu vẫn lưu dưới dạng văn bản thuần và sẽ hiện cảnh báo); KSPlayer không đọc cài đặt này."),
            "代理密码未能存入钥匙串，仍以明文保存在本地。请重新输入代理密码。": ("The proxy password could not be stored in the Keychain and is still saved in plain text locally. Please re-enter the proxy password.", "Không lưu được mật khẩu proxy vào Keychain, mật khẩu vẫn lưu dưới dạng văn bản thuần. Hãy nhập lại mật khẩu proxy."),
            "代理已填写用户名但未提供密码，请求将以无认证方式发出。请补全密码或清除用户名。": ("The proxy has a username but no password, so requests will go out unauthenticated. Please complete the password or clear the username.", "Proxy đã có tên người dùng nhưng chưa có mật khẩu, yêu cầu sẽ được gửi mà không xác thực. Hãy bổ sung mật khẩu hoặc xóa tên người dùng."),
            "清除已存代理密码": ("Clear stored proxy password", "Xóa mật khẩu proxy đã lưu"),
            // Round-8 localization batch (C02 clear-all sweep).
            "清除全部已存代理密码": ("Clear all stored proxy passwords", "Xóa tất cả mật khẩu proxy đã lưu"),
            // Round-9 localization batch (A01 clear-all scope note).
            "清除全部仅删除已存入钥匙串的密码，若字段中仍带有密码，离场确认时仍会重新存入。": ("Clear-all only removes passwords already stored in the Keychain; if a password is still in the field, it will be saved again once you leave the field.", "Xóa tất cả chỉ xóa mật khẩu đã lưu trong Keychain; nếu mật khẩu vẫn còn trong ô nhập, mật khẩu sẽ được lưu lại khi rời khỏi ô nhập.")
        ]
        if language == "English" { return table[key]?.0 ?? key }
        if language == "Tiếng Việt" { return table[key]?.1 ?? key }
        let traditional: [String: String] = [
            "设置": "設定", "播放列表": "播放清單", "收藏": "收藏", "主页": "首頁", "全部": "全部",
            "搜索频道...": "搜尋頻道...", "最近播放": "最近播放", "暂无播放记录": "暫無播放記錄", "暂无频道": "暫無頻道",
            "请先在“播放列表”中添加 M3U 或 Xtream 来源。": "請先在「播放清單」中加入 M3U 或 Xtream 來源。",
            "无收藏频道": "沒有收藏的頻道", "用星号标记频道以便在此快速访问。": "以星號標記頻道，即可在這裡快速開啟。",
            "暂无播放列表": "暫無播放清單", "添加播放列表": "加入播放清單", "关闭": "關閉",
            "订阅": "訂閱", "频道": "頻道", "节目": "節目", "选择订阅": "選擇訂閱", "暂无节目数据": "暫無節目資料", "当前节目": "目前", "下一节目": "下一個",
            "编码信息": "編碼資訊", "暂无数据": "暫無資料", "播放失败，请检查频道地址。": "播放失敗，請檢查頻道網址。",
            "语言": "語言", "外观": "外觀", "播放设置": "播放設定", "网络": "網路", "缓冲区": "緩衝區", "数据与缓存": "資料與快取", "预览": "預覽", "显示延迟": "顯示延遲", "EPG节目单": "EPG 節目表", "EPG地址": "EPG 網址", "保存节目单": "儲存節目表", "更新节目单地址": "更新節目表網址", "删除节目单": "刪除節目表", "刷新节目单": "重新整理節目表", "自动刷新": "自動重新整理", "关闭自动刷新": "關閉自動重新整理", "15分钟": "15 分鐘", "30分钟": "30 分鐘", "60分钟": "60 分鐘", "6小时": "6 小時", "节目单已更新。": "節目表已更新。",
            "主题模式": "主題模式", "色彩主题": "色彩主題", "画中画": "子母畫面", "首选播放器": "偏好播放器", "字幕大小": "字幕大小",
            "网络缓存大小": "網路緩衝大小", "清除图片缓存": "清除圖片快取", "清除播放历史": "清除播放記錄",
            "选择本地 M3U 文件": "選擇本機 M3U 檔案", "输入列表名称": "輸入清單名稱", "详细信息": "詳細資訊", "播放列表来源": "播放清單來源", "添加列表": "加入清單",
            "2列": "2 欄", "3列": "3 欄", "4列": "4 欄", "AVPlayer 使用系统原生解码，不支持的视频轨自动交给 KSPlayer。": "AVPlayer 使用系統原生解碼，不支援的視訊軌會自動交給 KSPlayer。",
            "KSPlayer 使用 FFmpeg，适合更多 IPTV 流格式。": "KSPlayer 使用 FFmpeg，支援更多 IPTV 串流格式。",
            "Auto 先尝试 AVPlayer，失败后自动切换 KSPlayer。": "Auto 會先嘗試 AVPlayer，失敗後自動切換至 KSPlayer。",
            "网络连接较慢或不稳定时，可增加缓存": "網路較慢或不穩定時，可增加緩衝。",
            "NanoStream 是一个媒体播放器外壳。请仅添加您有权观看的播放列表和视频流。": "NanoStream 是媒體播放器。請只加入您有權觀看的播放清單與串流。",
            "文件中没有找到有效频道。": "檔案中找不到有效頻道。", "播放列表添加失败。": "無法加入播放清單。", "图片缓存已清除。": "圖片快取已清除。",
            "播放列表地址无效。": "播放清單網址無效。", "播放列表为空或没有有效频道。": "播放清單為空或沒有有效頻道。", "返回内容不是有效的 M3U 播放列表。": "回傳內容不是有效的 M3U 播放清單。",
            "系统": "系統", "浅色": "淺色", "深色": "深色", "赛博朋克": "電馭叛客", "落日金": "落日金", "剧毒绿": "劇毒綠", "霓虹粉": "霓虹粉", "深海蓝": "深海藍",
            "硬件加速": "硬體加速", "自动选择音轨": "自動選擇音軌", "其他": "其他", "预览连接数已达上限": "已達預覽連線上限", "延迟不可用": "無法取得延遲", "该频道没有可播放地址。": "此頻道沒有可播放的網址。", "无播放地址": "沒有可播放的網址", "保存": "儲存", "保存失败，数据未写入。": "儲存失敗，資料未寫入。", "网络超时，请检查网络后重试。": "網路逾時，請檢查網路後再試一次。", "无网络连接。": "沒有網路連線。", "无法找到服务器。": "找不到伺服器。", "无法连接到服务器。": "無法連線至伺服器。", "清除收藏": "清除收藏", "Xtream 账号或密码为空。": "Xtream 帳號或密碼為空。", "节目单过大，超过 32MB 上限。": "節目表過大（超過 32 MB 上限）。", "已跳过无效频道行。": "已略過無效的頻道行。", "重试": "重試", "用 AVPlayer 重试": "用 AVPlayer 重試", "正在加载新订阅…": "正在載入訂閱…", "清除筛选": "清除篩選", "当前分组或搜索没有匹配的频道。": "目前的分組或搜尋沒有符合的頻道。", "旧播放列表数据损坏，已备份，无法自动恢复。": "已儲存的資料庫已損毀並已備份，無法自動還原。", "留空表示保持原密码": "留空表示保留原密碼", "更改播放列表类型后，原地址将按新类型解析。": "變更播放清單類型後，原網址將依新類型解析。", "选择文件失败。": "無法開啟檔案選擇器。", "文件读取失败。": "無法讀取檔案。", "文件编码不受支持，请使用 UTF-8 文本。": "不支援此檔案編碼，請使用 UTF-8 文字。", "前台自动刷新": "前景自動重新整理", "仅在 App 前台运行时刷新节目单。": "節目表僅在 App 於前景執行時重新整理。", "码率上限": "位元率上限", "本地文件": "本機檔案", "M3U 链接": "M3U 連結", "服务器地址 (http://...)": "伺服器網址 (http://...)", "用户名": "使用者名稱", "密码": "密碼", "编辑播放列表": "編輯播放清單", "保存并刷新": "儲存並重新整理", "播放列表已更新。": "播放清單已更新。", "节目单地址无效。": "節目表網址無效。", "返回内容不是有效的 XMLTV 节目单。": "回傳內容不是有效的 XMLTV 節目表。", "节目单中没有找到有效节目。": "節目表中找不到有效節目。",
            "此设置暂未接入播放器字幕渲染，仅保存偏好。": "此設定尚未接入播放器字幕渲染，僅儲存偏好。",
            "留空时使用内置标识；仅用于 M3U/EPG 请求，KSPlayer 不读取此设置。": "留空時使用內建識別；僅用於 M3U/EPG 請求，KSPlayer 不讀取此設定。",
            "仅用于 M3U/EPG 请求（格式 host:port、http://host:port 或 user:pass@host:port，带认证的代理会把用户名密码发给代理服务器），KSPlayer 不读取此设置。": "僅用於 M3U/EPG 請求（格式 host:port、http://host:port 或 user:pass@host:port，帶認證的代理會把使用者名稱密碼發給代理伺服器），KSPlayer 不讀取此設定。",
            "分组": "分組",
            "已刷新已有本地列表。": "已重新整理現有的本機清單。",
            "播放列表密码迁移失败，请重新输入该列表的密码。": "播放清單密碼遷移失敗，請重新輸入該清單的密碼。",
            "硬件加速仅影响 KSPlayer；AVPlayer 侧为系统默认解码行为，无额外效果。": "硬體加速僅影響 KSPlayer；AVPlayer 側為系統預設解碼行為，沒有額外效果。",
            "代理格式无效，将直连。请使用 host:port 格式。": "代理格式無效，將直接連線。請使用 host:port 格式。",
            "清除": "清除", "删除": "刪除",
            "确定清除全部播放历史吗？该操作无法撤销。": "確定清除全部播放記錄嗎？此操作無法復原。",
            "确定清除全部收藏吗？该操作无法撤销。": "確定清除全部收藏嗎？此操作無法復原。",
            "确定删除已保存的节目单来源、草稿、缓存指南、更新时间与自动刷新间隔吗？该操作无法撤销。": "確定刪除已儲存的節目表來源、草稿、快取節目表、更新時間與自動重新整理間隔嗎？此操作無法復原。",
            "确定删除播放列表吗？该操作无法撤销。": "確定刪除播放清單嗎？此操作無法復原。",
            "播放列表过大，超过 32MB 上限。": "播放清單過大（超過 32 MB 上限）。",
            "预览连接数已达上限，点按重试": "已達預覽連線上限，點按重試",
            "画中画已停止": "子母畫面已停止",
            "仅用于 M3U/EPG 请求（格式 host:port、http://host:port 或 user:pass@host:port；带认证的代理会把用户名密码发给代理服务器，密码存放在钥匙串中，不以明文保存），KSPlayer 不读取此设置。": "僅用於 M3U/EPG 請求（格式 host:port、http://host:port 或 user:pass@host:port；帶認證的代理會把使用者名稱密碼發給代理伺服器，密碼存放在鑰匙圈中，不以明文儲存），KSPlayer 不讀取此設定。",
            "代理格式无效，将直连。请使用 host:port、http://host:port 或 user:pass@host:port 格式。": "代理格式無效，將直接連線。請使用 host:port、http://host:port 或 user:pass@host:port 格式。",
            "仅用于 M3U/EPG 请求（格式 host:port、http://host:port 或 user:pass@host:port；带认证的代理会把用户名密码发给代理服务器，密码会迁移到钥匙串中；迁移失败时仍以明文保存在本地并显示警告），KSPlayer 不读取此设置。": "僅用於 M3U/EPG 請求（格式 host:port、http://host:port 或 user:pass@host:port，帶認證的代理會把使用者名稱密碼發給代理伺服器，密碼會遷移到鑰匙圈中；遷移失敗時仍以明文儲存在本機並顯示警告），KSPlayer 不讀取此設定。",
            "代理密码未能存入钥匙串，仍以明文保存在本地。请重新输入代理密码。": "代理密碼未能存入鑰匙圈，仍以明文儲存在本機。請重新輸入代理密碼。",
            "代理已填写用户名但未提供密码，请求将以无认证方式发出。请补全密码或清除用户名。": "代理已填寫使用者名稱但未提供密碼，請求將以無認證方式發出。請補全密碼或清除使用者名稱。",
            "清除已存代理密码": "清除已存的代理密碼",
            "清除全部已存代理密码": "清除全部已存的代理密碼",
            "清除全部仅删除已存入钥匙串的密码，若字段中仍带有密码，离场确认时仍会重新存入。": "清除全部僅刪除已存入鑰匙圈的密碼，若欄位中仍帶有密碼，離開欄位時仍會重新存入。"
        ]
        // No machine Simplified->Traditional fallback: an untranslated key
        // is shown as-is so missing translations are visible, not silently
        // machine-translated with inconsistent terminology.
        return traditional[key] ?? key
    }

    func localizedValue(_ value: String) -> String {
        switch value {
        case "System": return localized("系统")
        case "Light": return localized("浅色")
        case "Dark": return localized("深色")
        case "cyberpunk": return localized("赛博朋克")
        case "sunset": return localized("落日金")
        case "toxic": return localized("剧毒绿")
        case "neonPink": return localized("霓虹粉")
        case "deepBlue": return localized("深海蓝")
        case "3列": return localized("3列")
        case "4列": return localized("4列")
        case "2列": return localized("2列")
        case "关闭自动刷新": return localized("关闭自动刷新")
        case "15分钟": return localized("15分钟")
        case "30分钟": return localized("30分钟")
        case "60分钟": return localized("60分钟")
        case "6小时": return localized("6小时")
        default: return value
        }
    }

    func localizedError(_ error: Error) -> String {
        if let epgError = error as? EPGLoadError {
            switch epgError {
            case .invalidURL: return localized("节目单地址无效。")
            case .httpStatus(let status):
                if language == "中文" { return "节目单服务器返回 HTTP \(status)。" }
                if language == "繁體中文" { return "節目表伺服器回傳 HTTP \(status)。" }
                return language == "Tiếng Việt" ? "Máy chủ EPG trả về HTTP \(status)." : "The EPG server returned HTTP \(status)."
            case .invalidFormat: return localized("返回内容不是有效的 XMLTV 节目单。")
            case .empty: return localized("节目单中没有找到有效节目。")
            case .tooLarge: return localized("节目单过大，超过 32MB 上限。")
            }
        }
        if let playlistError = error as? PlaylistLoadError {
            switch playlistError {
            case .invalidURL: return localized("播放列表地址无效。")
            case .httpStatus(let status):
                if language == "中文" { return "服务器返回 HTTP \(status)。" }
                if language == "繁體中文" { return "伺服器回傳 HTTP \(status)。" }
                return language == "Tiếng Việt" ? "Máy chủ trả về HTTP \(status)." : "The server returned HTTP \(status)."
            case .empty: return localized("播放列表为空或没有有效频道。")
            case .invalidFormat: return localized("返回内容不是有效的 M3U 播放列表。")
            case .emptyCredentials: return localized("Xtream 账号或密码为空。")
            case .tooLarge: return localized("播放列表过大，超过 32MB 上限。")
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return localized("网络超时，请检查网络后重试。")
            case .notConnectedToInternet: return localized("无网络连接。")
            case .cannotFindHost: return localized("无法找到服务器。")
            case .cannotConnectToHost: return localized("无法连接到服务器。")
            default: break
            }
        }
        return error.localizedDescription
    }

    /// Set when a persist fails so the home page can show it: save()
    /// failures used to surface only via `notice`, which is rendered on
    /// the settings/form pages, never on the home page where the user
    /// actually starred or played the channel.
    @Published var saveError: String?
    func toggleFavorite(_ channel: Channel) {
        // Round-3 fix (C09): roll the in-memory change back when the
        // persist fails, instead of showing a starred channel that
        // vanishes on restart with no visible error on this page.
        let wasFavorite = favorites.contains(channel.id)
        if wasFavorite { favorites.remove(channel.id) } else { favorites.insert(channel.id) }
        if save() {
            saveError = nil
        } else {
            if wasFavorite { favorites.insert(channel.id) } else { favorites.remove(channel.id) }
            saveError = localized("保存失败，数据未写入。")
        }
    }

    func play(_ channel: Channel) {
        let previousSelected = selectedChannel
        let previousRecent = recent
        selectedChannel = channel
        recent.removeAll { $0 == channel.id }
        recent.insert(channel.id, at: 0)
        recent = Array(recent.prefix(24))
        if save() {
            saveError = nil
        } else {
            selectedChannel = previousSelected
            recent = previousRecent
            saveError = localized("保存失败，数据未写入。")
        }
    }

    func programs(for channel: Channel, now: Date = Date()) -> [EPGProgram] {
        // Merge id-matched and name-matched programmes (deduplicated) instead
        // of letting a stale epgID silently shadow a correct name match.
        var seen = Set<String>()
        var merged: [EPGProgram] = []
        let key = channel.epgID?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Round-3 fix (C03): id matching used to compare the raw tvg-id
        // only, while name matching normalizes case/diacritics/width, so
        // "cctv1" never matched an XML channel "CCTV1". Fall back to a
        // normalized comparison over guide keys when the exact key misses
        // (exact match first, so this costs nothing in the common case).
        var idPrograms: [EPGProgram] = key.flatMap { epgGuide.programsByChannelID[$0] } ?? []
        if idPrograms.isEmpty, let key, !key.isEmpty {
            // Round-4 fix (C09): look up the precomputed normalized-id
            // map instead of scanning and normalizing every guide key on
            // every body evaluation. The scan survives only as a fallback
            // for an in-memory guide built without the map (never via the
            // builder or the cache decoder, which both fill it).
            let normalizedKey = EPGGuide.normalizedID(key)
            let matchedIDs = epgGuide.channelIDsByNormalizedID[normalizedKey] ?? []
            if !matchedIDs.isEmpty {
                idPrograms = matchedIDs.flatMap { epgGuide.programsByChannelID[$0] ?? [] }
            } else if epgGuide.channelIDsByNormalizedID.isEmpty {
                for (guideID, programs) in epgGuide.programsByChannelID where normalizeEPGName(guideID) == normalizedKey {
                    idPrograms.append(contentsOf: programs)
                }
            }
        }
        let nameKey = normalizeEPGName(channel.name)
        let nameIDs = epgGuide.channelIDsByNormalizedName[nameKey] ?? []
        let namePrograms = nameIDs.flatMap { epgGuide.programsByChannelID[$0] ?? [] }
        for program in idPrograms + namePrograms where seen.insert(program.id).inserted {
            merged.append(program)
        }
        // Round-2 fix: the merged list was previously id-matches followed
        // by name-matches with no sort, so currentProgram/nextProgram (which
        // take the first match) could return a later programme, and the
        // 200-item cap cut an arbitrary unsorted slice. Sort by start
        // first, then filter and cap.
        merged.sort { $0.start < $1.start }
        // Round-3 fix (C18): the old 60-second tolerance kept a just-ended
        // programme in this list while currentProgram (end > now) and
        // nextProgram (start > now) both excluded it, so the same page
        // showed a programme with no "current" and no "next" badge. The
        // list now uses the same end > now definition as current/next.
        // Cap the list so a 7-day guide does not re-filter/copy on every body evaluation.
        return merged.filter { $0.end > now }.prefix(200).map { $0 }
    }

    func currentProgram(for channel: Channel, now: Date = Date()) -> EPGProgram? {
        programs(for: channel, now: now).first { $0.start <= now && $0.end > now }
    }

    func nextProgram(for channel: Channel, now: Date = Date()) -> EPGProgram? {
        programs(for: channel, now: now).first { $0.start > now }
    }

    func setEPGURL(_ value: String) {
        epgDraftURL = value
        epgError = nil
        // Draft survives a process kill; it is a separate key from the saved source.
        UserDefaults.standard.set(value, forKey: epgDraftCacheKey)
    }

    func saveEPGSource() {
        let value = epgDraftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        epgURL = value
        UserDefaults.standard.set(value, forKey: "nanostream.epgURL")
        UserDefaults.standard.set(value, forKey: epgDraftCacheKey)
        if value.isEmpty {
            deleteEPGSource()
            return
        }
        reloadEPG()
        startEPGRefreshLoop()
    }


    func deleteEPGSource() {
        epgTask?.cancel()
        epgFetchTask?.cancel()
        epgRefreshLoopTask?.cancel()
        epgTask = nil
        epgFetchTask = nil
        epgRefreshLoopTask = nil
        epgGeneration += 1
        epgURL = ""
        epgDraftURL = ""
        epgGuide = .empty
        epgError = nil
        epgLastUpdated = nil
        isLoadingEPG = false
        // Deleting the source also deletes its refresh interval; otherwise
        // the old interval silently revives when a new address is saved.
        epgRefreshIntervalMinutes = 0
        UserDefaults.standard.removeObject(forKey: "nanostream.epgURL")
        UserDefaults.standard.removeObject(forKey: "nanostream.epgLastUpdated")
        UserDefaults.standard.removeObject(forKey: "nanostream.epgRefreshIntervalMinutes")
        UserDefaults.standard.removeObject(forKey: epgGuideCacheKey)
        UserDefaults.standard.removeObject(forKey: epgDraftCacheKey)
        if let url = Self.epgGuideCacheFileURL() { try? FileManager.default.removeItem(at: url) }
    }

    func setEPGRefreshInterval(_ minutes: Int) {
        epgRefreshIntervalMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: "nanostream.epgRefreshIntervalMinutes")
        startEPGRefreshLoop()
        // A new interval takes effect immediately, not after one full sleep.
        if minutes > 0, !epgURL.isEmpty { reloadEPG() }
    }

    func reloadEPG() {
        epgTask?.cancel()
        epgFetchTask?.cancel()
        epgFetchTask = nil
        epgGeneration += 1
        let generation = epgGeneration
        epgTask = Task { [weak self] in await self?.refreshEPG(generation: generation) }
    }

    func startEPGRefreshLoop() {
        epgRefreshLoopTask?.cancel()
        guard epgRefreshIntervalMinutes > 0, !epgURL.isEmpty else { return }
        let interval = UInt64(epgRefreshIntervalMinutes) * 60 * 1_000_000_000
        epgRefreshLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                // Go through reloadEPG so the tick gets its own generation
                // instead of racing a manual reload as a second live load.
                await self?.reloadEPG()
            }
        }
    }

    func refreshEPG(generation: Int) async {
        let endpoint = epgURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else {
            if generation == epgGeneration {
                epgGuide = .empty
                epgError = nil
                isLoadingEPG = false
            }
            return
        }
        // Only the current generation drives the loading indicator; a
        // superseded load must not clear it while a newer load runs.
        if generation == epgGeneration {
            isLoadingEPG = true
            epgError = nil
        }
        defer { if generation == epgGeneration { isLoadingEPG = false } }
        // Round-4 fix (C05): a reload/delete that cancelled this outer
        // task before it started used to still create a download task
        // below and run it to completion before discarding the result.
        guard !Task.isCancelled else { return }
        do {
            // Round-2 fix: fetching AND parsing used to run on the main
            // actor, so a large XMLTV file froze the UI. Parsing runs off
            // the main actor; only the result commit runs on MainActor.
            // Round-3 fix (C20): the fetch is a stored, cancellable task
            // instead of a detached one, so changing the address or
            // deleting the source actually stops the old download instead
            // of letting it finish and only then discarding the result.
            guard !Task.isCancelled else { return }
            let fetchTask = Task(priority: .userInitiated) {
                try await EPGService.fetch(endpoint: endpoint)
            }
            epgFetchTask = fetchTask
            let guide = try await fetchTask.value
            // Round-4 fix (C05): the old code cleared the handle
            // unconditionally, so a superseded task's catch/success path
            // could wipe a NEWER load's handle, after which nothing
            // could cancel the newer download. Only clear our own
            // generation's handle.
            if generation == epgGeneration { epgFetchTask = nil }
            guard !Task.isCancelled, generation == epgGeneration else { return }
            epgGuide = guide
            epgLastUpdated = Date()
            UserDefaults.standard.set(epgLastUpdated, forKey: "nanostream.epgLastUpdated")
            if let data = try? JSONEncoder().encode(guide), let url = Self.epgGuideCacheFileURL() {
                try? data.write(to: url, options: .atomic)
            }
        } catch {
            if generation == epgGeneration { epgFetchTask = nil }
            guard !Task.isCancelled, generation == epgGeneration else { return }
            // Keep the last good guide on failure: a network blip must not
            // blank the whole programme page. The error explains that the
            // displayed guide may be stale.
            epgError = localizedError(error)
        }
    }

    private func normalizeEPGName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    func channel(for id: String) -> Channel? { allChannels.first { $0.id == id } }

    /// First cached channel of a playlist, used when switching subscriptions
    /// from the detail page so the player does not keep playing the old
    /// subscription's channel.
    func channelSetsFirstChannel(for playlist: Playlist) -> Channel? {
        channelSetsByPlaylist[playlist.id]?.first
    }

    /// Replace a local playlist's channels with freshly parsed file content.
    /// Previously a local edit could only rename; re-importing created a
    /// duplicate playlist instead.
    /// Round-3 fix (B14): switching a remote playlist to local now really
    /// converts it — kind becomes M3U, the endpoint becomes the local-file
    /// sentinel, and the username/Keychain credential are dropped — instead
    /// of leaving a remote identity that the next refresh re-fetched over
    /// the local channels. Round-3 fix (C12): the import carries a
    /// generation guard, so parsing that finishes after the user switched
    /// subscriptions no longer hijacks the current subscription.
    /// Round-3 fix (C19): the selected group/search/selection/recent
    /// state is reset together with the channels, not left pointing at
    /// the old remote playlist's snapshot.
    func updateLocalPlaylist(_ playlist: Playlist, name: String, text: String, baseURL: URL? = nil, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        localChannelsParseTask?.cancel()
        localReportParseTask?.cancel()
        playlistGeneration += 1
        let generation = playlistGeneration
        Task {
            let parseTask = Task.detached(priority: .userInitiated) { M3UParser.parse(text: text, baseURL: baseURL) }
            localChannelsParseTask = parseTask
            let parsed = await parseTask.value
            await MainActor.run {
                guard playlistGeneration == generation else { completion(false); return }
                // Round-7 fix (C02): a local import bumps the generation,
                // so an in-flight activation's trailing block will not
                // clear the loading flags. A local import that settles
                // (success or terminal failure) owns the flags from here.
                guard !parsed.isEmpty else { playlistError = localized("文件中没有找到有效频道。"); isLoadingPlaylist = false; isRefreshingPlaylist = false; completion(false); return }
                guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { isLoadingPlaylist = false; isRefreshingPlaylist = false; completion(false); return }
                var updated = playlists[index]
                updated.name = name.isEmpty ? updated.name : name
                updated.kind = .m3u
                updated.endpoint = Playlist.localFileEndpoint
                updated.username = ""
                updated.password = ""
                KeychainStore.deletePassword(for: playlist.id)
                updated.channelCount = parsed.count
                updated.lastRefresh = Date()
                playlists[index] = updated
                channelSetsByPlaylist[playlist.id] = parsed
                if activePlaylistID == playlist.id {
                    channels = parsed
                    selectedGroup = GroupID.all
                    searchText = ""
                    selectedChannel = nil
                    recent = recent.filter { channel(for: $0) != nil }
                }
                // Round-4 fix (C11): the round-3 cleanup only ran for
                // the active playlist. Turning a NON-active playlist
                // local replaced its cache but left a selected channel
                // and recent entries pointing at its old remote snapshot.
                // The cache above is already replaced, so a lookup that
                // misses now really means "gone from every playlist".
                recent = recent.filter { channel(for: $0) != nil }
                if let selected = selectedChannel, channel(for: selected.id) == nil {
                    selectedChannel = nil
                }
                playlistError = nil
                // Round-7 fix (C02): this commit supersedes any in-flight
                // activation/edit, whose generation-guarded trailing block
                // will not clear the flags. The local import has taken
                // over, so it settles the flags too.
                isLoadingPlaylist = false
                isRefreshingPlaylist = false
                save()
                completion(true)
            }
        }
    }

    /// Password source of truth: Keychain first, transient in-memory value
    /// second (used only during a single add/edit operation).
    func password(for playlist: Playlist) -> String {
        KeychainStore.password(for: playlist.id) ?? playlist.password
    }

    func addPlaylist(name: String, kind: PlaylistKind, endpoint: String, username: String = "", password: String = "", completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        Task { await importPlaylist(name: name, kind: kind, endpoint: endpoint, username: username, password: password, completion: completion) }
    }

    func addPlaylistFromText(name: String, text: String, baseURL: URL? = nil, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        // Parsing runs off the main actor so a large local file does not
        // freeze the UI; only the result commit runs on the main actor.
        localChannelsParseTask?.cancel()
        localReportParseTask?.cancel()
        playlistGeneration += 1
        let generation = playlistGeneration
        Task {
            let parseTask = Task.detached(priority: .userInitiated) { M3UParser.parseReport(text: text, baseURL: baseURL) }
            localReportParseTask = parseTask
            let report = await parseTask.value
            let parsed = report.channels
            await MainActor.run {
                // Round-3 fix (C12): a local import that finishes after
                // the user switched subscriptions must not steal the
                // active subscription, mirroring the remote import guard.
                guard playlistGeneration == generation else { completion(false); return }
                // Round-7 fix (C02): same generation-bump flag gap as
                // updateLocalPlaylist — a settled local import owns the
                // flags, a superseded one (guard above) must not clear
                // flags owned by the newer operation.
                guard !parsed.isEmpty else { playlistError = localized("文件中没有找到有效频道。"); isLoadingPlaylist = false; isRefreshingPlaylist = false; completion(false); return }
                if report.skipped > 0 { setNotice(localized("已跳过无效频道行。")) }
                let displayName = name.isEmpty ? "本地播放列表" : name
                // Duplicate import, round-3 fix (B16/C17): the old test
                // (same name + same first channel + same count) silently
                // overwrote a different file that happened to share those
                // three values, and missed same-content files renamed by
                // the user. Identity is now the full channel-id set: same
                // set refreshes the existing local playlist, anything else
                // creates a new one (renames no longer collide, different
                // files no longer overwrite each other).
                let parsedIDs = Set(parsed.map(\.id))
                if let existingIndex = playlists.firstIndex(where: { $0.isLocalFile && Set(channelSetsByPlaylist[$0.id]?.map(\.id) ?? []) == parsedIDs }) {
                    let existing = playlists[existingIndex]
                    // Round-4 fix (A05): the refresh used to keep the
                    // old name, so a user who typed a new name on import
                    // saw the old name after a "successful" import and
                    // thought it had not applied. The imported name wins.
                    playlists[existingIndex].name = displayName
                    playlists[existingIndex].channelCount = parsed.count
                    playlists[existingIndex].lastRefresh = Date()
                    channelSetsByPlaylist[existing.id] = parsed
                    setNotice(localized("已刷新已有本地列表。"))
                    activePlaylistID = existing.id
                    channels = parsed
                    selectedGroup = GroupID.all
                    searchText = ""
                    playlistError = nil
                    // Round-7 fix (C02): see updateLocalPlaylist — this
                    // commit supersedes any in-flight activation/edit.
                    isLoadingPlaylist = false
                    isRefreshingPlaylist = false
                    save()
                    completion(true)
                    return
                }
                channels = parsed
                let playlist = Playlist(name: displayName, kind: .m3u, endpoint: Playlist.localFileEndpoint, channelCount: parsed.count, lastRefresh: Date())
                playlists.insert(playlist, at: 0)
                activePlaylistID = playlist.id
                channelSetsByPlaylist[playlist.id] = parsed
                selectedGroup = GroupID.all
                searchText = ""
                playlistError = nil
                // Round-7 fix (C02): see above.
                isLoadingPlaylist = false
                isRefreshingPlaylist = false
                save()
                completion(true)
            }
        }
    }

    func removePlaylist(_ playlist: Playlist) {
        let wasActive = activePlaylistID == playlist.id
        playlists.removeAll { $0.id == playlist.id }
        channelSetsByPlaylist.removeValue(forKey: playlist.id)
        KeychainStore.deletePassword(for: playlist.id)
        // Round-4 fix (C01): the round-3 favorites filter ran while
        // channels was still the deleted playlist's channels, and
        // allChannels appends channels after the caches — so
        // channel(for:) still found the deleted ids and the filter was
        // a no-op for the active playlist (the common case). Clear the
        // stale tail first; the filter below then only sees caches of
        // surviving playlists.
        if wasActive { channels = [] }
        // Round-3 fix (C06): favorites were never filtered here, so a
        // deleted channel's id lingered and "resurrected" its star the
        // moment another subscription produced the same stable id.
        favorites = favorites.filter { channel(for: $0) != nil }
        if wasActive {
            activePlaylistID = playlists.first?.id
            selectedGroup = GroupID.all
            searchText = ""
            // Round-3 fix (C07): deleting the active subscription used
            // to leave an empty grid with no loading state and no refresh
            // when the next subscription had no cache. Activate (and
            // therefore reload) the next subscription instead.
            if let next = activePlaylistID, let nextPlaylist = playlists.first(where: { $0.id == next }) {
                activatePlaylist(nextPlaylist)
            } else {
                channels = []
                // Round-5 fix (C02): same stranded-spinner gap as
                // cancelPlaylistLoad — with no next playlist, no later
                // activation will clear flags set by the deleted load.
                // (When a next playlist exists, activatePlaylist owns
                // the flags itself, so nothing is cleared here.)
                isLoadingPlaylist = false
                isRefreshingPlaylist = false
            }
        }
        // Round-5 fix (C01): the selected-channel cleanup used to live
        // inside the wasActive branch, but play() is not limited to the
        // active subscription (favorites/recent can point at any
        // subscription's channel). Deleting a NON-active subscription
        // therefore left selectedChannel pointing at a deleted channel
        // object even though its cache was gone. Check unconditionally,
        // after activation has settled channels for the next playlist.
        if let selected = selectedChannel, channel(for: selected.id) == nil {
            selectedChannel = nil
        }
        // Drop recent entries that no longer exist in any playlist.
        recent = recent.filter { channel(for: $0) != nil }
        save()
    }

    func refreshPlaylists() {
        // Refresh the active playlist, not blindly the first one.
        guard let playlist = (activePlaylistID.flatMap { id in playlists.first(where: { $0.id == id }) } ?? playlists.first) else { return }
        activatePlaylist(playlist)
    }

    /// Cancels an in-flight playlist load (used when the user abandons a
    /// subscription switch from the detail waiting state). Bumping the
    /// generation invalidates the load's commit guard even if its network
    /// request has already returned, so the abandoned subscription's
    /// channels can never land afterwards and leave the old channel
    /// playing under the new subscription's name (round-3 A11).
    func cancelPlaylistLoad() {
        activeLoadTask?.cancel()
        activeLoadTask = nil
        localChannelsParseTask?.cancel()
        localReportParseTask?.cancel()
        playlistGeneration += 1
        // Round-5 fix (C02): cancelling used to bump the generation
        // without touching the loading flags, and the superseded load's
        // trailing block refuses to clear them on a generation mismatch
        // — so a cancelled load left the spinner turning until some
        // other load happened to take over. The cancel owns the flags
        // now; a newer load that starts afterwards sets them itself.
        isLoadingPlaylist = false
        isRefreshingPlaylist = false
    }

    func activatePlaylist(_ playlist: Playlist) {
        guard playlists.contains(where: { $0.id == playlist.id }) else {
            // Stale object (e.g. deleted in a race): fall back to the first
            // playlist instead of pointing active at a missing playlist.
            if let first = playlists.first { activatePlaylist(first) }
            return
        }
        playlistGeneration += 1
        let generation = playlistGeneration
        activeLoadTask?.cancel()
        // Round-4 fix (C13): switching subscriptions supersedes a local
        // parse just like a remote load; cancel its handle too so a large
        // file does not keep parsing after the user moved on.
        localChannelsParseTask?.cancel()
        localReportParseTask?.cancel()
        activePlaylistID = playlist.id
        selectedGroup = GroupID.all
        searchText = ""
        save()
        if playlist.isLocalFile {
            // Local playlists have no remote content to re-fetch.
            channels = channelSetsByPlaylist[playlist.id] ?? []
            isLoadingPlaylist = false
            isRefreshingPlaylist = false
            return
        }
        if let cached = channelSetsByPlaylist[playlist.id] {
            channels = cached
            isLoadingPlaylist = false
            isRefreshingPlaylist = true
        } else {
            channels = []
            isLoadingPlaylist = true
            isRefreshingPlaylist = false
        }
        activeLoadTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.reloadPlaylist(playlist, generation: generation)
            await MainActor.run {
                if self.playlistGeneration == generation {
                    self.isLoadingPlaylist = false
                    self.isRefreshingPlaylist = false
                }
            }
        }
    }

    func updatePlaylist(_ playlist: Playlist, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else {
            completion(false)
            return
        }
        let old = playlists[index]
        // Round-3 fix (C11): an edit now takes its own generation. The
        // old code only captured the current value, so an activate reload
        // that started BEFORE the edit still passed its guard after the
        // edit committed and overwrote the new channels with stale ones.
        // Taking a generation here invalidates any in-flight reload, and
        // the commit below refuses to run when a newer operation has
        // since taken a generation ("last started wins").
        playlistGeneration += 1
        let startGeneration = playlistGeneration
        var playlist = playlist
        if playlist.kind == .xtream {
            let sanitized = PlaylistLoader.sanitizedXtream(endpoint: playlist.endpoint, username: playlist.username, password: playlist.password)
            playlist.endpoint = sanitized.endpoint
            if playlist.username.isEmpty { playlist.username = sanitized.username }
            if playlist.password.isEmpty { playlist.password = sanitized.password }
        }
        if playlist.kind == .tvHeadend {
            // Same calibre as Xtream: credentials embedded in a pasted
            // tvHeadend endpoint are split out instead of being persisted
            // as part of the endpoint string.
            let sanitized = PlaylistLoader.sanitizedTvHeadend(endpoint: playlist.endpoint, username: playlist.username, password: playlist.password)
            playlist.endpoint = sanitized.endpoint
            if playlist.username.isEmpty { playlist.username = sanitized.username }
            if playlist.password.isEmpty { playlist.password = sanitized.password }
        }
        if playlist.kind == .m3u {
            // M3U carries no credentials. The form hides the username field
            // for M3U, but its @State is prefilled from the edited playlist,
            // so an Xtream -> M3U type change previously carried the old
            // username invisibly on the saved playlist.
            playlist.username = ""
        }
        if playlist.isLocalFile {
            // Local files have no stored content to re-fetch: a local edit
            // only renames. The form title reflects this ("Save", not
            // "Save & refresh"), so this is not a fake refresh.
            var renamed = playlist
            // Local files carry no credentials: a type change to local must
            // not leave a stale username/password on the playlist.
            renamed.username = ""
            renamed.password = ""
            KeychainStore.deletePassword(for: playlist.id)
            renamed.channelCount = old.channelCount
            renamed.lastRefresh = old.lastRefresh
            playlists[index] = renamed
            // A type change TO local must not keep the old remote playlist's
            // channels on screen as if they belonged to the local file.
            if old.kind != renamed.kind || !old.isLocalFile {
                channelSetsByPlaylist.removeValue(forKey: playlist.id)
                if activePlaylistID == playlist.id {
                    channels = []
                    // Round-3 fix (C19): the old code cleared channels
                    // but left the group/search/selection/recent state
                    // pointing at the old remote playlist's snapshot.
                    selectedGroup = GroupID.all
                    searchText = ""
                    selectedChannel = nil
                    recent = recent.filter { channel(for: $0) != nil }
                }
                // Round-4 fix (C11): same cleanup for a NON-active
                // playlist turned local: its cache is gone above, so a
                // selected/recent entry that no longer resolves anywhere
                // is stale even though this playlist was not active.
                recent = recent.filter { channel(for: $0) != nil }
                if let selected = selectedChannel, channel(for: selected.id) == nil {
                    selectedChannel = nil
                }
                renamed.channelCount = 0
                renamed.lastRefresh = nil
                playlists[index] = renamed
            }
            // Round-4 fix (C02): this edit took a generation at the top,
            // invalidating any in-flight activate reload — but that
            // reload's trailing block then refuses to clear the loading
            // flags, and nothing else cleared them either. This branch
            // runs synchronously right after the bump, so no newer load
            // can have started; the edit owns the flags now and clears
            // them unconditionally (the superseded load will never commit
            // or clear them itself).
            isLoadingPlaylist = false
            isRefreshingPlaylist = false
            activePlaylistID = playlist.id
            // Round-5 fix (C03): a migration-failure saveError banner
            // used to survive a successful password re-entry, because
            // only toggleFavorite/play cleared it. A successful commit
            // here proves the credential is good again, so clear it —
            // but only on a successful save, never unconditionally in
            // save() itself (a later unrelated save must not hide an
            // unresolved migration failure).
            if save() { saveError = nil }
            completion(true)
            return
        }
        // Load-first: validate the new endpoint/credentials before committing
        // them, so a failed edit cannot leave "new address + old channels".
        Task {
            // Empty password in an edit means "keep the stored one": resolve
            // from Keychain before loading, otherwise an Xtream/tvHeadend
            // edit with a blank password field would fail auth even though
            // a valid password is stored.
            let candidatePassword = playlist.password.isEmpty ? (KeychainStore.password(for: old.id) ?? "") : playlist.password
            let loaded: [Channel]
            do {
                loaded = try await PlaylistLoader.load(kind: playlist.kind, endpoint: playlist.endpoint, username: playlist.username, password: candidatePassword)
            } catch {
                // Round-2 fix: the old code used try? and always reported
                // "empty playlist", swallowing invalid URLs, HTTP errors and
                // empty-credential errors alike.
                // Round-3 fix (C13): a failed edit must not write the
                // global error when the playlist was deleted mid-load or
                // a newer operation has superseded this edit; the success
                // branch already had the equivalent guard.
                await MainActor.run {
                    guard playlists.contains(where: { $0.id == playlist.id }),
                          playlistGeneration == startGeneration else { completion(false); return }
                    // Round-4 fix (C02): a failed edit still superseded
                    // the in-flight reload, so its flags would otherwise
                    // spin forever exactly like the success case.
                    isLoadingPlaylist = false
                    isRefreshingPlaylist = false
                    playlistError = localizedError(error)
                    completion(false)
                }
                return
            }
            await MainActor.run {
                guard playlistGeneration == startGeneration else { completion(false); return }
                // Round-4 fix (C03): deleting a NON-active playlist does
                // not bump the generation, so the two branches below used
                // to write a global error for a playlist that no longer
                // exists, polluting the current playlist's error bar.
                // Deleted mid-load: just report failure, no global error.
                guard playlists.contains(where: { $0.id == playlist.id }) else { completion(false); return }
                guard !loaded.isEmpty else {
                    // Round-6 fix (C02): the old code returned without
                    // touching the loading flags here (and in the two
                    // branches below). The generation guard above already
                    // proves no newer operation has taken a generation, so
                    // this edit still owns the flags — and the in-flight
                    // activate reload's trailing block will refuse to
                    // clear them because the edit bumped the generation.
                    // Without this, the home page spinner spins forever.
                    isLoadingPlaylist = false
                    isRefreshingPlaylist = false
                    playlistError = localizedError(PlaylistLoadError.empty)
                    completion(false)
                    return
                }
                // Round-2 fix: never write through a stale index captured
                // before the await. A delete, insert or reorder during the
                // load previously wrote the edit onto the wrong playlist or
                // crashed on an out-of-range index, and could resurrect a
                // deleted playlist as active.
                guard let currentIndex = playlists.firstIndex(where: { $0.id == playlist.id }) else {
                    // Same round-6 (C02) reasoning as the empty-result
                    // branch above: unreachable on the MainActor after the
                    // contains-guard, but a failure return must never
                    // leave the loading flags owned by this edit behind.
                    isLoadingPlaylist = false
                    isRefreshingPlaylist = false
                    playlistError = localized("播放列表添加失败。")
                    completion(false)
                    return
                }
                // Round-3 fix (C14): persist the new credential BEFORE
                // committing the playlist, with read-back verification.
                // The old order (save metadata, then Keychain) left a
                // crash window where the edit was saved but the new
                // password was not, so the next launch silently used the
                // old password. A failed Keychain write aborts the whole
                // edit instead of committing half of it.
                if (playlist.kind == .xtream || playlist.kind == .tvHeadend), !playlist.password.isEmpty {
                    guard KeychainStore.savePassword(playlist.password, for: playlist.id) else {
                        // Round-6 fix (C02): same flag ownership as the
                        // empty-result branch — a failed Keychain write
                        // aborts the edit but must not strand the flags.
                        isLoadingPlaylist = false
                        isRefreshingPlaylist = false
                        playlistError = localized("保存失败，数据未写入。")
                        completion(false)
                        return
                    }
                }
                var committed = playlist
                committed.password = ""
                committed.channelCount = loaded.count
                committed.lastRefresh = Date()
                playlists[currentIndex] = committed
                channelSetsByPlaylist[playlist.id] = loaded
                // If the user switched subscriptions while this edit was
                // loading, commit the metadata and cache but do not clobber
                // the now-current playlist's channels or active id.
                if playlistGeneration == startGeneration {
                    activePlaylistID = playlist.id
                    channels = loaded
                    selectedGroup = GroupID.all
                    searchText = ""
                    // Round-4 fix (C02): this commit superseded the
                    // in-flight reload, whose trailing block will not
                    // clear the flags (generation mismatch). Clear them
                    // here; the generation guard above guarantees no
                    // newer load has started since this edit.
                    isLoadingPlaylist = false
                    isRefreshingPlaylist = false
                }
                playlistError = nil
                // Round-4 fix (C04): save() used to be fire-and-forget
                // here, so a save failure after the Keychain write left
                // the new password in Keychain against the OLD persisted
                // playlist. On failure, restore the previous Keychain
                // password so the next launch is self-consistent (old
                // persisted playlist + old password); the in-memory state
                // stays new for this session, which is the residual gap.
                if !save() {
                    if (playlist.kind == .xtream || playlist.kind == .tvHeadend), !playlist.password.isEmpty {
                        if candidatePassword.isEmpty { KeychainStore.deletePassword(for: playlist.id) }
                        else { _ = KeychainStore.savePassword(candidatePassword, for: playlist.id) }
                    }
                    // Round-6 fix (C02): same flag ownership as the
                    // empty-result branch — a save failure after the
                    // commit must not strand the loading flags either.
                    // The generation guard at the top of this block still
                    // holds here (no newer operation has taken a
                    // generation since this edit started).
                    isLoadingPlaylist = false
                    isRefreshingPlaylist = false
                    playlistError = localized("保存失败，数据未写入。")
                    completion(false)
                    return
                }
                if !(playlist.kind == .xtream || playlist.kind == .tvHeadend) {
                    KeychainStore.deletePassword(for: playlist.id)
                }
                // Round-5 fix (C03): same as the local branch — a
                // successful commit clears a stale migration-failure
                // banner; the save-failure path above already returns
                // before reaching this point.
                saveError = nil
                // Blank password field: keep the stored password untouched.
                completion(true)
            }
        }
    }

    func clearHistory() { recent.removeAll(); save() }
    func clearFavorites() { favorites.removeAll(); save() }
    func clearImageCache() { URLCache.shared.removeAllCachedResponses(); setNotice(localized("图片缓存已清除。")) }

    private func importPlaylist(name: String, kind: PlaylistKind, endpoint: String, username: String, password: String, completion: @escaping @MainActor (Bool) -> Void) async {
        let sanitized: (endpoint: String, username: String, password: String)
        switch kind {
        case .xtream: sanitized = PlaylistLoader.sanitizedXtream(endpoint: endpoint, username: username, password: password)
        case .tvHeadend: sanitized = PlaylistLoader.sanitizedTvHeadend(endpoint: endpoint, username: username, password: password)
        case .m3u: sanitized = (endpoint, "", "")
        }
        let endpoint = sanitized.endpoint
        let username = sanitized.username
        let password = sanitized.password
        playlistGeneration += 1
        let generation = playlistGeneration
        isLoadingPlaylist = true
        playlistError = nil
        do {
            let loaded = try await PlaylistLoader.load(kind: kind, endpoint: endpoint, username: username, password: password)
            guard !loaded.isEmpty else { throw PlaylistLoadError.empty }
            // Round-2 fix: a superseded import previously returned without
            // calling completion at all, leaving the form's save spinner
            // running forever. Report failure (without touching state, so
            // the newer import's channels/error are not clobbered); the
            // form only shows an error when playlistError is actually set,
            // so a superseded import just resets the spinner.
            guard playlistGeneration == generation else { await completion(false); return }
            let playlist = Playlist(name: name.isEmpty ? "新播放列表" : name, kind: kind, endpoint: endpoint, username: username, password: "", channelCount: loaded.count, lastRefresh: Date())
            // Round-3 fix (C14): same credential-before-commit order as
            // updatePlaylist — a failed Keychain write aborts the import
            // instead of leaving a playlist whose password was never stored.
            if (kind == .xtream || kind == .tvHeadend), !password.isEmpty {
                guard KeychainStore.savePassword(password, for: playlist.id) else {
                    // Round-7 fix (C01): the round-6 flag cleanup only
                    // covered updatePlaylist; these early returns in
                    // importPlaylist skipped the trailing flag clear, so
                    // a Keychain failure left isLoadingPlaylist stuck.
                    // Clear on the generation guard, same as the success
                    // path — a superseded import must not clear flags
                    // owned by the newer import.
                    // Round-8 fix (C01): same gap for the refresh flag
                    // (see the trailing settlement below).
                    if playlistGeneration == generation { isLoadingPlaylist = false; isRefreshingPlaylist = false }
                    playlistError = localized("保存失败，数据未写入。")
                    await completion(false)
                    return
                }
            }
            channels = loaded
            playlists.insert(playlist, at: 0)
            activePlaylistID = playlist.id
            channelSetsByPlaylist[playlist.id] = loaded
            selectedGroup = GroupID.all
            searchText = ""
            // Round-4 fix (C04): same Keychain/save ordering hazard as
            // updatePlaylist. On save failure, drop the just-written
            // Keychain password so the next launch is not left with a
            // credential for a playlist that was never persisted (the
            // in-memory insert stays for this session: residual gap).
            if !save() {
                if (kind == .xtream || kind == .tvHeadend), !password.isEmpty {
                    KeychainStore.deletePassword(for: playlist.id)
                }
                // Round-7 fix (C01): same early-return flag gap as the
                // Keychain branch above (round-6 only fixed updatePlaylist).
                // Round-8 fix (C01): also clear the refresh flag here.
                if playlistGeneration == generation { isLoadingPlaylist = false; isRefreshingPlaylist = false }
                playlistError = localized("保存失败，数据未写入。")
                await completion(false)
                return
            }
            // Round-5 fix (C03): same stale-banner cleanup as
            // updatePlaylist, for the import success path.
            saveError = nil
            await completion(true)
        } catch {
            guard playlistGeneration == generation else { await completion(false); return }
            playlistError = localizedError(error)
            await completion(false)
        }
        // Round-8 fix (C01): the trailing settlement (which the catch
        // branch falls through to) previously cleared only the loading
        // flag, leaving a refresh flag stranded by a superseding import.
        if playlistGeneration == generation { isLoadingPlaylist = false; isRefreshingPlaylist = false }
    }

    /// Returns true on success. Callers use this result directly instead of
    /// reading the shared playlistError, which concurrent loads could clobber.
    private func reloadPlaylist(_ playlist: Playlist, generation: Int? = nil) async -> Bool {
        let effectiveGeneration: Int
        if let generation {
            effectiveGeneration = generation
        } else {
            playlistGeneration += 1
            effectiveGeneration = playlistGeneration
        }
        isLoadingPlaylist = channelSetsByPlaylist[playlist.id] == nil
        isRefreshingPlaylist = channelSetsByPlaylist[playlist.id] != nil
        playlistError = nil
        do {
            let loaded = try await PlaylistLoader.load(kind: playlist.kind, endpoint: playlist.endpoint, username: playlist.username, password: password(for: playlist))
            guard !loaded.isEmpty else { throw PlaylistLoadError.empty }
            // Discard stale results: deleted playlists must not resurrect,
            // and a slower earlier load must not overwrite a newer active one.
            guard playlistGeneration == effectiveGeneration,
                  playlists.contains(where: { $0.id == playlist.id }),
                  activePlaylistID == playlist.id else { return false }
            channels = loaded
            channelSetsByPlaylist[playlist.id] = loaded
            if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                playlists[index].channelCount = loaded.count
                playlists[index].lastRefresh = Date()
            }
            selectedGroup = GroupID.all
            searchText = ""
            save()
            return true
        } catch {
            guard playlistGeneration == effectiveGeneration, activePlaylistID == playlist.id else { return false }
            playlistError = localizedError(error)
            return false
        }
    }

    /// Returns false when encoding fails. Callers that already mutated
    /// in-memory state (toggleFavorite/play) roll back on false; other
    /// callers keep the old fire-and-forget behaviour via @discardableResult.
    @discardableResult
    private func save() -> Bool {
        // Channels are derived from channelSetsByPlaylist for the active
        // playlist, so they are not written twice. When there is no per-
        // playlist cache (legacy state), the flat list is still written.
        let channelsToSave = channelSetsByPlaylist.isEmpty ? channels : []
        let state = SavedState(channels: channelsToSave, playlists: playlists, favorites: favorites, recent: recent, activePlaylistID: activePlaylistID, channelSetsByPlaylist: channelSetsByPlaylist)
        guard let data = try? JSONEncoder().encode(state) else {
            setNotice(localized("保存失败，数据未写入。"), isError: true)
            return false
        }
        UserDefaults.standard.set(data, forKey: storageKey)
        // A backup from a previous corrupt restore is now expired: the
        // current state saved cleanly, so the stale backup must not linger.
        UserDefaults.standard.removeObject(forKey: storageKey + ".bak")
        return true
    }

    private static func restore(data: Data) -> SavedState? {
        try? JSONDecoder().decode(SavedState.self, from: data)
    }

    /// Recursively removes credential material from a JSON document so a
    /// corrupt-library backup never preserves a plain-text credential.
    /// Returns nil when the data is not JSON at all (then no backup is
    /// written, rather than a raw copy of unknown bytes).
    /// Round-3 fix (B13): the old strip only removed "password" keys,
    /// but a legacy endpoint string could still carry ?username=&password=
    /// or userinfo, and "username" keys survived untouched. String values
    /// are now cleaned of userinfo and username/password query items too,
    /// and "username" keys are removed alongside "password" keys.
    private static func strippedBackupData(_ data: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        func stripString(_ value: String) -> String {
            guard var components = URLComponents(string: value) else { return value }
            var changed = false
            if components.user != nil || components.password != nil {
                components.user = nil
                components.password = nil
                changed = true
            }
            if let items = components.queryItems, items.contains(where: { $0.name == "username" || $0.name == "password" }) {
                let kept = items.filter { $0.name != "username" && $0.name != "password" }
                components.queryItems = kept.isEmpty ? nil : kept
                changed = true
            }
            return changed ? (components.string ?? value) : value
        }
        func strip(_ value: Any) -> Any {
            if var dict = value as? [String: Any] {
                dict.removeValue(forKey: "password")
                dict.removeValue(forKey: "username")
                return dict.mapValues { strip($0) }
            }
            if let array = value as? [Any] { return array.map { strip($0) } }
            if let text = value as? String { return stripString(text) }
            return value
        }
        return try? JSONSerialization.data(withJSONObject: strip(json))
    }
}

private struct SavedState: Codable {
    var channels: [Channel]
    var playlists: [Playlist]
    var favorites: Set<String>
    var recent: [String]
    var activePlaylistID: UUID?
    var channelSetsByPlaylist: [UUID: [Channel]]?

    init(channels: [Channel], playlists: [Playlist], favorites: Set<String>, recent: [String], activePlaylistID: UUID?, channelSetsByPlaylist: [UUID: [Channel]]) {
        self.channels = channels
        self.playlists = playlists
        self.favorites = favorites
        self.recent = recent
        self.activePlaylistID = activePlaylistID
        self.channelSetsByPlaylist = channelSetsByPlaylist
    }

    private enum CodingKeys: String, CodingKey { case channels, playlists, favorites, recent, activePlaylistID, channelSetsByPlaylist }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerant per-element decoding: one corrupt channel or playlist
        // must not destroy the whole library (previously a single bad
        // element failed the entire decode).
        channels = Self.tolerantArray(from: container, forKey: .channels)
        playlists = Self.tolerantArray(from: container, forKey: .playlists)
        favorites = Set(Self.tolerantArray(from: container, forKey: .favorites) as [String])
        recent = Self.tolerantArray(from: container, forKey: .recent)
        activePlaylistID = try container.decodeIfPresent(UUID.self, forKey: .activePlaylistID)
        // Round-3 fix (C02): the channel cache used to decode as one
        // all-or-nothing dictionary, so a single corrupt channel in any
        // subscription failed the whole decode and restore() returned nil
        // (full library wipe via the corrupt-backup path). It is now
        // decoded per subscription and per channel, like the top-level
        // arrays: bad entries are skipped, good ones survive.
        channelSetsByPlaylist = Self.tolerantChannelSets(from: container)
    }

    private static func tolerantChannelSets(from container: KeyedDecodingContainer<CodingKeys>) -> [UUID: [Channel]]? {
        guard let nested = try? container.nestedContainer(keyedBy: UUIDCodingKey.self, forKey: .channelSetsByPlaylist) else {
            return try? container.decodeIfPresent([UUID: [Channel]].self, forKey: .channelSetsByPlaylist)
        }
        var result: [UUID: [Channel]] = [:]
        for key in nested.allKeys {
            guard let id = UUID(uuidString: key.stringValue),
                  var array = try? nested.nestedUnkeyedContainer(forKey: key) else { continue }
            var channels: [Channel] = []
            while !array.isAtEnd {
                if let channel = try? array.decode(Channel.self) { channels.append(channel) }
                // Round-4 fix (C15): the old fallback decoded an empty
                // struct, which fails on non-object elements (string /
                // number / bool / null) — and the code then broke out of
                // the loop, dropping every remaining channel of that
                // subscription. AnyJSONValue consumes exactly one JSON
                // value of any shape, so a bad element is skipped and
                // parsing continues. The break survives only for a value
                // that is not valid JSON at all, where continuing would
                // spin forever on an unconsumed element.
                else if (try? array.decode(AnyJSONValue.self)) != nil { continue }
                else { break }
            }
            result[id] = channels
        }
        return result
    }

    private struct UUIDCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func tolerantArray<T: Decodable>(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> [T] {
        guard var nested = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [T] = []
        while !nested.isAtEnd {
            if let value = try? nested.decode(T.self) { result.append(value) }
            // Same family as C15: an empty-struct skip fails on scalar
            // elements and would leave the container unadvanced (an
            // infinite loop on a corrupt scalar element). AnyJSONValue
            // consumes exactly one value of any shape, so the loop
            // always progresses on a well-formed JSON document; the
            // break survives only for a value that is not valid JSON
            // at all, where continuing could spin forever.
            else if (try? nested.decode(AnyJSONValue.self)) != nil { continue }
            else { break }
        }
        return result
    }

    /// Decodes (and discards) exactly one JSON value of any shape, so
    /// tolerant decoding can skip a corrupt element without losing its
    /// siblings. An empty struct cannot do this: it fails on scalars,
    /// and a failed decode does not advance the unkeyed container.
    private struct AnyJSONValue: Decodable {
        init(from decoder: Decoder) throws {
            if var unkeyed = try? decoder.unkeyedContainer() {
                while !unkeyed.isAtEnd { _ = try unkeyed.decode(AnyJSONValue.self) }
            } else if let keyed = try? decoder.container(keyedBy: AnyCodingKey.self) {
                for key in keyed.allKeys { _ = try keyed.decode(AnyJSONValue.self, forKey: key) }
            } else {
                var single = try decoder.singleValueContainer()
                if single.decodeNil() { return }
                if (try? single.decode(Bool.self)) != nil { return }
                if (try? single.decode(Double.self)) != nil { return }
                if (try? single.decode(String.self)) != nil { return }
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Not a JSON value"))
            }
        }
    }

    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

enum PreferredPlayer: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case avPlayer = "AVPlayer"
    case ksPlayer = "KSPlayer"
    var id: String { rawValue }
}

enum GridLayout: String, CaseIterable, Identifiable {
    case twoColumns = "2列"
    case threeColumns = "3列"
    case fourColumns = "4列"
    var id: String { rawValue }
    var columns: Int {
        switch self { case .twoColumns: return 2; case .threeColumns: return 3; case .fourColumns: return 4 }
    }
}

enum PlaylistLoadError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case empty
    case invalidFormat
    case emptyCredentials
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "播放列表地址无效。"
        case .httpStatus(let status): return "服务器返回 HTTP \(status)。"
        case .empty: return "播放列表为空或没有有效频道。"
        case .invalidFormat: return "返回内容不是有效的 M3U 播放列表。"
        case .emptyCredentials: return "Xtream 账号或密码为空。"
        case .tooLarge: return "播放列表过大，超过 32MB 上限。"
        }
    }
}

enum PlaylistLoader {
    static func load(kind: PlaylistKind, endpoint: String, username: String, password: String) async throws -> [Channel] {
        switch kind {
        case .m3u:
            return try await M3UParser.fetch(endpoint: endpoint)
        case .tvHeadend:
            // tvHeadend was previously fetched as a plain M3U with credentials
            // silently dropped; it now uses HTTP Basic Auth when credentials
            // are supplied.
            return try await M3UParser.fetch(endpoint: endpoint, username: username, password: password)
        case .xtream:
            let url = try xtreamPlaylistURL(endpoint: endpoint, username: username, password: password)
            return try await M3UParser.fetch(endpoint: url.absoluteString)
        }
    }

    /// Splits credentials out of a pasted Xtream URL so they are never
    /// persisted as part of the endpoint string.
    /// Round-3 fix (C08/C16): credential stripping used to require the
    /// path to end in get.php, so player_api.php or any other panel
    /// address kept its ?username=&password= in SavedState; and userinfo
    /// (user:pass@host, e.g. carried over by a tvHeadend -> Xtream type
    /// change) was never stripped at all. Both are now stripped for any
    /// path, matching the tvHeadend sanitizer's calibre.
    static func sanitizedXtream(endpoint: String, username: String, password: String) -> (endpoint: String, username: String, password: String) {
        guard var components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return (endpoint, username, password)
        }
        var foundUsername = username
        var foundPassword = password
        if let user = components.user, !user.isEmpty, foundUsername.isEmpty { foundUsername = user }
        if let pass = components.password, !pass.isEmpty, foundPassword.isEmpty { foundPassword = pass }
        components.user = nil
        components.password = nil
        if let items = components.queryItems, !items.isEmpty {
            let kept = items.filter { item in
                if item.name == "username", foundUsername.isEmpty, let value = item.value, !value.isEmpty { foundUsername = value; return false }
                if item.name == "password", foundPassword.isEmpty, let value = item.value, !value.isEmpty { foundPassword = value; return false }
                if item.name == "username" || item.name == "password" { return false }
                return true
            }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        return (components.string ?? endpoint, foundUsername, foundPassword)
    }

    /// tvHeadend equivalent of sanitizedXtream: credentials embedded in a
    /// pasted endpoint (userinfo, or username/password query items) are
    /// split out so they are never persisted as part of the endpoint.
    static func sanitizedTvHeadend(endpoint: String, username: String, password: String) -> (endpoint: String, username: String, password: String) {
        guard var components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return (endpoint, username, password)
        }
        var foundUsername = username
        var foundPassword = password
        if let user = components.user, !user.isEmpty, foundUsername.isEmpty { foundUsername = user }
        if let pass = components.password, !pass.isEmpty, foundPassword.isEmpty { foundPassword = pass }
        components.user = nil
        components.password = nil
        if let items = components.queryItems, !items.isEmpty {
            let kept = items.filter { item in
                if item.name == "username", foundUsername.isEmpty, let value = item.value, !value.isEmpty { foundUsername = value; return false }
                if item.name == "password", foundPassword.isEmpty, let value = item.value, !value.isEmpty { foundPassword = value; return false }
                if item.name == "username" || item.name == "password" { return false }
                return true
            }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        return (components.string ?? endpoint, foundUsername, foundPassword)
    }

    private static func xtreamPlaylistURL(endpoint: String, username: String, password: String) throws -> URL {
        guard var components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme, !scheme.isEmpty,
              let host = components.host, !host.isEmpty else { throw PlaylistLoadError.invalidURL }
        guard !username.isEmpty, !password.isEmpty else { throw PlaylistLoadError.emptyCredentials }
        let lastComponent = components.path.split(separator: "/").last.map(String.init)?.lowercased()
        if lastComponent != "get.php" {
            // Preserve any reverse-proxy sub-path (e.g. /iptv/) instead of
            // forcing the path to "/get.php".
            var directory = components.path
            if !directory.hasSuffix("/") {
                if let slash = directory.lastIndex(of: "/") { directory = String(directory[...slash]) }
                else { directory = "/" }
            }
            components.path = directory + "get.php"
        }
        // Merge required parameters into the existing query instead of
        // overwriting it (which dropped tokens and other panel parameters).
        // Round-3 fix (C15): type/output are FORCED, not "filled when
        // empty". A pasted URL carrying type=json or output=xml used to
        // be requested as-is, and the user saw a misleading "not a valid
        // M3U" error instead of a wrong-format request.
        var items = components.queryItems ?? []
        func upsert(_ name: String, _ value: String) {
            if let index = items.firstIndex(where: { $0.name == name }) {
                items[index].value = value
            } else {
                items.append(URLQueryItem(name: name, value: value))
            }
        }
        upsert("username", username)
        upsert("password", password)
        upsert("type", "m3u_plus")
        upsert("output", "ts")
        components.queryItems = items
        guard let url = components.url else { throw PlaylistLoadError.invalidURL }
        return url
    }
}

enum M3UParser {
    /// Hard cap for downloaded playlists/guides, enforced WHILE streaming
    /// (see fetchData) instead of after the whole body is already in memory.
    static let maxDownloadBytes = 32 * 1024 * 1024

    /// Session shared by playlist/EPG fetches: a complete, identifiable
    /// User-Agent (never the previously truncated "Mozilla/5.0 ... " default)
    /// and, when the user configured one, an HTTP proxy. KSPlayer itself does
    /// not read these settings; that gap is documented in the README.
    /// Round-3 fix (C24): the session is cached and reused while the
    /// UA/proxy settings are unchanged, instead of building (and never
    /// invalidating) a new URLSession on every fetch and retry.
    private static var cachedSession: URLSession?
    private static var cachedSessionKey: String?
    static func configuredSession() -> URLSession {
        let storedUA = UserDefaults.standard.string(forKey: "userAgent") ?? ""
        let userAgent = storedUA.trimmingCharacters(in: .whitespacesAndNewlines)
        // Round-5 fix (A01): migrate a password embedded in the stored
        // proxy value into the Keychain (and rewrite the stored value
        // without it) before parsing. Round-12 fix (A02): that
        // "before parsing" timing holds only while the settings field
        // is NOT open — while it is open, the round-11 deferred save
        // returns early without writing, and the request below
        // deliberately uses the field's inline password directly
        // (parsed.password ?? Keychain), so a request path CAN read a
        // plain-text proxy password out of UserDefaults mid-edit, by
        // design, until the departure confirmation migrates it. The
        // migration is best-effort: if the Keychain write fails, the
        // inline password below is still used as a fallback rather than
        // silently dropping authentication for this session.
        migrateStoredProxyPassword()
        let proxy = UserDefaults.standard.string(forKey: "httpProxy")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = userAgent + "|" + proxy
        if let session = cachedSession, cachedSessionKey == key { return session }
        cachedSession?.finishTasksAndInvalidate()
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": (!userAgent.isEmpty && !userAgent.contains("...")) ? userAgent : "NanoStreamClone/1.0 (iOS)"]
        if !proxy.isEmpty, let parsed = parseProxy(proxy) {
            // Round-4 fix (A03): a user:pass@host:port proxy used to have
            // its credentials silently dropped, so requests went out
            // unauthenticated and a 407 gave the user no explanation.
            // Credentials are now passed to the proxy (and the settings
            // caption says so); the cached-session key is in-memory only.
            // Round-5 fix (A01): the password comes from the Keychain
            // (keyed by the exact proxy identity), falling back to an
            // inline password only when migration into the Keychain
            // failed. Round-6 fix (A02): that fallback DOES read the
            // plain-text stored value, and the settings page warns when
            // migration failed (proxyMigrationFailed) instead of the old
            // comment's claim that this never happens.
            let canonical = canonicalProxy(host: parsed.host, port: parsed.port, username: parsed.username)
            let proxyPassword = parsed.password ?? KeychainStore.proxyPassword(forProxy: canonical)
            var proxyDict: [String: Any] = [
                "HTTPEnable": true, "HTTPProxy": parsed.host, "HTTPPort": parsed.port,
                "HTTPSEnable": true, "HTTPSProxy": parsed.host, "HTTPSPort": parsed.port,
            ]
            if let proxyUser = parsed.username, !proxyUser.isEmpty {
                proxyDict["HTTPProxyUsername"] = proxyUser
                proxyDict["HTTPSProxyUsername"] = proxyUser
                if let proxyPassword { proxyDict["HTTPProxyPassword"] = proxyPassword; proxyDict["HTTPSProxyPassword"] = proxyPassword }
            }
            config.connectionProxyDictionary = proxyDict
        }
        let session = URLSession(configuration: config)
        cachedSession = session
        cachedSessionKey = key
        return session
    }

    /// Canonical stripped proxy identity used as the Keychain account
    /// for the proxy password ("user@host:port" or "host:port").
    static func canonicalProxy(host: String, port: Int, username: String?) -> String {
        (username.map { "\($0)@" } ?? "") + "\(host):\(port)"
    }

    /// True when the last proxy-password migration attempt failed to
    /// write to the Keychain. The settings page reads this (via its own
    /// @State, synced on appear/disappear and via the notification below)
    /// to warn, because a failed migration leaves the password in plain
    /// text in UserDefaults and configuredSession keeps using it as a
    /// fallback — silently, if nothing surfaces the failure. In-memory
    /// only, never persisted.
    /// Round-12 fix (A01): the flag is scoped to the identity that
    /// failed — see proxyMigrationFailedIdentity. A stale flag from a
    /// previous identity must not be blamed on the identity now in the
    /// field: with round-11 deferred saving, a background refresh
    /// while the user edits a new identity never attempts a write, so
    /// the old flag would otherwise linger and the warning would fire
    /// against a password that was never tried.
    static var proxyMigrationFailed = false
    /// The proxy identity (canonical "user@host:port" or "host:port")
    /// whose password failed to migrate, or nil when no failure is
    /// outstanding. In-memory only, never persisted. Warnings surface
    /// only when this matches the identity currently in the field —
    /// or when it is nil, a defensive fallback so a flag set without
    /// an identity can never hide a genuine warning (the notification
    /// posted by the setter below is synchronous, so an observer may
    /// read the flag an instant before the call site records the
    /// identity; the nil case keeps that first render warning).
    static var proxyMigrationFailedIdentity: String?
    /// True while the settings page's proxy field is mounted (set by
    /// SettingsView's field onAppear/onDisappear). Round-9 fix (A02):
    /// identity-change deletion must only happen on a user-confirmed
    /// path (field left, explicit clear, with-password migration). A
    /// background refresh that runs migrateStoredProxyPassword while
    /// the user is still mid-edit must not permanently delete the
    /// previous identity's password before the user has confirmed the
    /// new identity — so the no-password and unparseable branches below
    /// skip deletion while this flag is set, and the confirmed
    /// onDisappear migration (which clears the flag first) performs it.
    /// Round-10 fix (A01/10-D01, merged): the same gate now covers the
    /// with-password branch (which round 9 left ungated, so a background
    /// refresh could still delete the previous identity and rewrite the
    /// field mid-typing) and the no-password branch's record-when-empty
    /// case (round-10 C01) — while the field is open, migrate only
    /// saved the new password and changed nothing else.
    /// Round-11 fix (A02/11-D01, merged): even that save is now
    /// deferred while the field is open (see the with-password branch
    /// below). Saving an unconfirmed identity orphaned it: if the user
    /// then abandoned the edit, no later path deleted the entry, and
    /// re-entering that identity without a password silently resurrected
    /// it. Deferring loses nothing — configuredSession prefers the
    /// inline password in the field itself, so requests made mid-edit
    /// still authenticate, and the confirmed onDisappear migration
    /// saves exactly the identity the user left behind.
    static var proxyFieldOpen = false
    /// Posted whenever proxyMigrationFailed changes value, so a settings
    /// page that is already open learns about a failure that happened
    /// mid-session (e.g. a background EPG refresh), instead of only
    /// syncing on field appear/disappear (round-7 A03). Round-13 fix
    /// (A01): also posted when the failed identity changes while the
    /// flag is already true (see the failure branch below), so a
    /// second failure is not left waiting on an unrelated re-render.
    static let proxyMigrationFailedChanged = Notification.Name("NanoStreamClone.ProxyMigrationFailedChanged")
    /// Posted whenever a with-password migration successfully writes a
    /// proxy password into the Keychain (round-10 A02/10-D03, merged):
    /// a background refresh can do this while the settings page is
    /// already open, and the page's cached "any password stored" flag
    /// would otherwise stay stale until the field is left and
    /// re-entered. The settings page refreshes its cached proxy flags
    /// on this notification.
    static let proxyPasswordStoredChanged = Notification.Name("NanoStreamClone.ProxyPasswordStoredChanged")
    private static func setProxyMigrationFailed(_ value: Bool) {
        guard proxyMigrationFailed != value else { return }
        proxyMigrationFailed = value
        // Round-12 fix (A01): every path that clears the flag also
        // clears the failed identity, so a later warning can never be
        // scoped to an identity whose failure is already resolved.
        // The failure call site records the identity itself, before
        // calling this setter with true (see below).
        if !value { proxyMigrationFailedIdentity = nil }
        NotificationCenter.default.post(name: proxyMigrationFailedChanged, object: nil)
    }
    /// Drops the cached URLSession so the next fetch rebuilds it (with
    /// the current proxy credentials). Shared by migration, prune and
    /// the explicit clear-password button, which previously forgot this
    /// step and kept sending a deleted password until restart (round-7
    /// A01).
    static func invalidateCachedSession() {
        cachedSession?.finishTasksAndInvalidate()
        cachedSession = nil
        cachedSessionKey = nil
    }
    /// Moves a password embedded in the stored "httpProxy" value into
    /// the Keychain and rewrites the stored value without it. Idempotent:
    /// a value with no embedded password is left untouched, and a failed
    /// Keychain write leaves the stored value untouched too (so the
    /// credential is never lost by the migration itself). Also drops the
    /// cached session, so a password rotation typed into the field takes
    /// effect instead of reusing a session built with the old password.
    /// Called from configuredSession and from the settings field's
    /// onAppear/onDisappear, so a stored password is stripped promptly
    /// without disturbing a password still being typed.
    /// Round-6 fix (A02): a failed write used to be completely silent
    /// (the old comment even claimed "no request ever uses a UserDefaults
    /// password", which the fallback path contradicted). The failure is
    /// now recorded in proxyMigrationFailed for the settings warning,
    /// and the caption no longer claims plain-text storage never happens.
    static func migrateStoredProxyPassword() {
        let raw = UserDefaults.standard.string(forKey: "httpProxy") ?? ""
        guard let parsed = parseProxy(raw) else {
            setProxyMigrationFailed(false)
            // Round-9 fix (C02): a non-empty unparseable value is also
            // a departure from the previous identity — the user has a
            // reason to believe the proxy is off (the settings warning
            // itself says an invalid format connects directly), yet the
            // old entry used to survive and resurrect when the field was
            // later set back to the old identity. Delete it on the same
            // terms as a no-password switch, but only when the field is
            // not currently being edited (see proxyFieldOpen): while the
            // user is mid-typing, "host:ab" is transiently unparseable
            // and must not cost them the previous password. The empty
            // field is deliberately excluded here — it is prune's case
            // (field emptied), not this branch's.
            if !proxyFieldOpen, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let last = UserDefaults.standard.string(forKey: "httpProxyLastIdentity"), !last.isEmpty {
                KeychainStore.deleteProxyPassword(forProxy: last)
                UserDefaults.standard.removeObject(forKey: "httpProxyLastIdentity")
                invalidateCachedSession()
            }
            return
        }
        guard let password = parsed.password, !password.isEmpty else {
            // Round-8 fix (B): the round-7 rotation delete only ran
            // on the with-password migration path, so switching to a
            // different identity WITHOUT an inline password orphaned
            // the previous identity's entry — and switching back later
            // silently resurrected it. A no-password field is the
            // migrated shape, but only for its OWN identity: if the
            // identity changed, drop the previous entry and record
            // the new identity (also recording it when none was
            // recorded yet, so a later switch can delete correctly).
            // The session is invalidated in the delete branch too:
            // strictly the field value itself changed, so the cached
            // session key would no longer match anyway, but invalidating
            // here is cheap and removes any doubt about a stale
            // session carrying the deleted identity's password.
            let canonical = canonicalProxy(host: parsed.host, port: parsed.port, username: parsed.username)
            let previous = UserDefaults.standard.string(forKey: "httpProxyLastIdentity")
            if let previous, !previous.isEmpty, previous != canonical {
                // Round-9 fix (A02/9-D02, merged): this branch used to
                // delete the previous entry on ANY migrate run, including
                // a background EPG refresh that happened to fire while
                // the user was still mid-edit in the settings field —
                // permanently deleting a password the user had not
                // confirmed discarding. While the field is open, do
                // neither the delete nor the record: recording the new
                // identity here would make the later confirmed
                // onDisappear migration see "no change" and skip the
                // delete, orphaning the old entry for good. Leaving
                // lastIdentity untouched keeps the confirmed path able
                // to detect the change and delete it when the user
                // actually leaves the field.
                if !proxyFieldOpen {
                    KeychainStore.deleteProxyPassword(forProxy: previous)
                    UserDefaults.standard.set(canonical, forKey: "httpProxyLastIdentity")
                    invalidateCachedSession()
                }
            } else if (previous ?? "").isEmpty {
                // Round-10 fix (C01): this record branch was outside the
                // proxyFieldOpen gate above, so editing a new identity
                // while no identity was recorded yet recorded it
                // mid-edit — and the confirmed onDisappear migration
                // then saw "no change" and never deleted the old
                // identity's orphaned entry. While the field is open,
                // neither delete nor record: leaving lastIdentity
                // untouched keeps the confirmed path able to detect the
                // change and delete it when the user actually leaves
                // the field.
                if !proxyFieldOpen {
                    UserDefaults.standard.set(canonical, forKey: "httpProxyLastIdentity")
                }
            }
            setProxyMigrationFailed(false)
            return
        }
        let canonical = canonicalProxy(host: parsed.host, port: parsed.port, username: parsed.username)
        // Round-11 fix (A02/11-D01, merged): while the field is open,
        // do not save at all — not even the round-10 "save only".
        // A background refresh that saved a mid-edit identity left it
        // orphaned when the user abandoned the edit: no later path
        // (switch back to the old identity, clear the field, switch to
        // a third identity) deletes an entry that is neither the
        // current canonical nor the last recorded identity, so it sat
        // in the Keychain until a "clear all" sweep — and silently
        // resurrected if the user later re-entered that identity
        // without a password. This is the round-11 two-way decision,
        // settled on deferring the save (not a departure-time sweep):
        // a sweep would need an in-memory set of mid-edit identities
        // that is lost if the app is killed mid-edit, leaving the same
        // orphan, while deferring loses nothing — the field value
        // itself still holds the password, and configuredSession
        // prefers the inline password, so mid-edit requests still
        // authenticate. The confirmed onDisappear migration (which
        // clears proxyFieldOpen first) then saves exactly the
        // confirmed identity, deletes the previous one, and rewrites
        // the field, and still sees the change because lastIdentity
        // was left untouched. Round-12 fix (A01): the failure flag is
        // deliberately left alone here too — no write was attempted,
        // so there is no new failure to record — but a stale flag can
        // no longer be misattributed, because warnings are scoped to
        // proxyMigrationFailedIdentity: a failure that belonged to the
        // previous identity stays silent while this new identity is in
        // the field, and reappears if the field returns to the failed
        // identity before any confirmed save.
        guard !proxyFieldOpen else { return }
        guard KeychainStore.saveProxyPassword(password, forProxy: canonical) else {
            // Round-12 fix (A01): record which identity failed BEFORE
            // setting the flag, so observers of the synchronous
            // notification posted by the setter see the scoped
            // identity immediately. Round-13 fix (A01): if the flag
            // was already true for another identity, the setter
            // early-returns without posting, so a second failure
            // would update the identity but leave observers stale
            // until an unrelated re-render. Post explicitly in that
            // case, so the identity change itself carries a refresh
            // signal; when the flag was false the setter below posts
            // exactly once, so there is no double notification. (The
            // deferred-save branch above still never sets the flag —
            // no write was attempted there, so there is no new
            // failure to report.)
            let identityChanged = proxyMigrationFailedIdentity != canonical
            proxyMigrationFailedIdentity = canonical
            if proxyMigrationFailed, identityChanged {
                NotificationCenter.default.post(name: proxyMigrationFailedChanged, object: nil)
            }
            setProxyMigrationFailed(true)
            return
        }
        setProxyMigrationFailed(false)
        // The password itself is now safely in the Keychain; tell the
        // settings page (round-10 A02/10-D03, merged) so its cached
        // "any password stored" flag refreshes even when this write
        // happened on a background refresh while the page was open.
        // Round-11 note: with the deferred save above, this no longer
        // fires while the field is open (no write happens then); it
        // still fires for confirmed writes and for fetch-path writes
        // when the field is not mounted.
        NotificationCenter.default.post(name: proxyPasswordStoredChanged, object: nil)
        // Round-7 fix (A05/C03, merged): rotating to a different proxy
        // identity used to orphan the previous identity's password in
        // the Keychain forever, and switching back later silently
        // resurrected it. Delete the previous identity's entry when the
        // migration lands on a different identity, so only the current
        // identity's password is retained.
        if let previous = UserDefaults.standard.string(forKey: "httpProxyLastIdentity"), !previous.isEmpty, previous != canonical {
            KeychainStore.deleteProxyPassword(forProxy: previous)
        }
        UserDefaults.standard.set(canonical, forKey: "httpProxy")
        // Round-6 fix (A01): remember which proxy identity the stored
        // password belongs to, so clearing the field entirely can delete
        // it (see pruneStoredProxyPassword). The identity alone is not
        // a credential; the password itself lives only in the Keychain.
        UserDefaults.standard.set(canonical, forKey: "httpProxyLastIdentity")
        invalidateCachedSession()
    }

    /// Deletes the stored proxy password when the user has removed the
    /// proxy entirely. Round-6 fix (A01): previously there was no delete
    /// path at all — deleteProxyPassword was only reachable from
    /// saveProxyPassword("") and no caller ever passed an empty password
    /// — so clearing the field and re-entering the same proxy identity
    /// silently resurrected the old password from the Keychain.
    /// Deliberately narrow: only an EMPTY field prunes, using the last
    /// recorded identity. A non-empty field without an inline password
    /// is exactly what a successfully migrated proxy looks like, so
    /// pruning on that shape would delete passwords the user expects to
    /// keep. For that case the settings page offers an explicit
    /// "clear stored proxy password" button instead.
    static func pruneStoredProxyPassword() {
        let raw = UserDefaults.standard.string(forKey: "httpProxy") ?? ""
        guard raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let last = UserDefaults.standard.string(forKey: "httpProxyLastIdentity"), !last.isEmpty {
            KeychainStore.deleteProxyPassword(forProxy: last)
            UserDefaults.standard.removeObject(forKey: "httpProxyLastIdentity")
        }
        invalidateCachedSession()
    }

    /// Strict proxy parsing, also used by the settings page to warn about
    /// an invalid value. Round-3 fix (B07): a missing, non-numeric or
    /// out-of-range port used to silently become 8080, so a proxy the user
    /// meant for another port received traffic meant for it — and an
    /// unparsable proxy silently fell back to a direct connection. Both
    /// now return nil (no proxy, and the settings page shows a warning).
    static func parseProxy(_ raw: String) -> (host: String, port: Int, username: String?, password: String?)? {
        // Round-4 fix (A04): the settings warning used to pass the raw
        // (untrimmed) input here while configuredSession trimmed first,
        // so a pasted proxy with trailing whitespace warned "invalid"
        // while actually working. Trimming is now done inside parseProxy,
        // so every caller judges the same string.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "http://" + trimmed
        guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty,
              let port = components.port, (1...65535).contains(port) else { return nil }
        // Round-5 fix (A03): a path (or query/fragment) used to be
        // silently dropped, so "host:8080/anything" passed validation
        // while the "/anything" part never took effect. A lone trailing
        // slash is still accepted; anything else is invalid.
        guard components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil else { return nil }
        // Round-5 fix (A02): a password without a username used to
        // parse successfully and then be silently dropped again by the
        // session builder (which only writes credentials when a username
        // is present). Reject it here so the settings warning fires and
        // the user is told to complete the username instead.
        if let password = components.password, !password.isEmpty, components.user?.nonEmpty == nil { return nil }
        return (host: host, port: port, username: components.user?.nonEmpty, password: components.password)
    }

    /// Streams a response body with an early size cap and HTTP status
    /// check. Round-3 fix (C23): the old data(for:) path downloaded the
    /// whole body first and only then rejected it, so a 100MB response
    /// peaked at 100MB in memory before failing. A non-2xx status throws
    /// before any body byte is read; an over-cap body throws as soon as
    /// the cap is crossed, without waiting for the rest of the download.
    static func fetchData(for request: URLRequest, tooLargeError: Error, statusError: (Int) -> Error) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await configuredSession().bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw statusError(http.statusCode)
        }
        // Round-4 fix (C10): a known Content-Length over the cap used to
        // only cap the reserve, then still stream 32MB before failing.
        // Reject it up front, before any body byte is read.
        if response.expectedContentLength > maxDownloadBytes {
            throw tooLargeError
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        // Chunked accumulation: URLSession.AsyncBytes yields bytes one at
        // a time, so append to a 64KB staging buffer and flush in bulk
        // instead of growing Data one byte at a time (the per-byte
        // iteration itself is an AsyncBytes property and remains; a
        // delegate-based bulk reader would be the further step).
        var staging = [UInt8]()
        staging.reserveCapacity(65536)
        func flush(into data: inout Data, staging: inout [UInt8]) {
            if !staging.isEmpty { data.append(contentsOf: staging); staging.removeAll(keepingCapacity: true) }
        }
        for try await byte in bytes {
            if Task.isCancelled { throw CancellationError() }
            staging.append(byte)
            if staging.count >= 65536 {
                flush(into: &data, staging: &staging)
                if data.count > maxDownloadBytes { throw tooLargeError }
            }
        }
        flush(into: &data, staging: &staging)
        if data.count > maxDownloadBytes { throw tooLargeError }
        return (data, response)
    }

    static func fetch(endpoint: String, username: String = "", password: String = "") async throws -> [Channel] {
        guard var url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw PlaylistLoadError.invalidURL }
        // Round-2 fix: credentials embedded in the URL itself (userinfo)
        // are used for Basic Auth and stripped from the request URL, so a
        // reload path that never went through the form sanitizer cannot
        // leak them either. Blank credentials send no header at all: the
        // old "username non-empty" test sent a bogus header whenever only
        // a password was supplied, and sent nothing (correctly) only when
        // both were blank.
        var effectiveUsername = username
        var effectivePassword = password
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let user = components.user, !user.isEmpty {
            if effectiveUsername.isEmpty { effectiveUsername = user }
            if effectivePassword.isEmpty { effectivePassword = components.password ?? "" }
            var stripped = components
            stripped.user = nil
            stripped.password = nil
            if let clean = stripped.url { url = clean }
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if !effectiveUsername.isEmpty || !effectivePassword.isEmpty {
            let credentials = Data("\(effectiveUsername):\(effectivePassword)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                // Size-capped streaming fetch (round-3 C23); the status
                // check now happens before any body byte is read.
                let (data, _) = try await fetchData(for: request, tooLargeError: PlaylistLoadError.tooLarge, statusError: { PlaylistLoadError.httpStatus($0) })
                guard let text = decodePlaylist(data: data) else { throw PlaylistLoadError.invalidFormat }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // An HTML error page or JSON body is not a playlist, even if
                // it happens to parse to zero channels (which used to be
                // misreported as "empty playlist").
                if trimmed.hasPrefix("<") || trimmed.hasPrefix("{") { throw PlaylistLoadError.invalidFormat }
                // Compile-fix round: Task.detached's closure runs
                // concurrently, so it must not capture the mutable
                // local `url`; copy it to a let first.
                let reportBaseURL = url
                let report = await Task.detached(priority: .userInitiated) { parseReport(text: text, baseURL: reportBaseURL) }.value
                guard !report.channels.isEmpty else { throw PlaylistLoadError.empty }
                return report.channels
            } catch let error as PlaylistLoadError {
                throw error
            } catch {
                lastError = error
                if attempt == 0, (error as? URLError) != nil { try? await Task.sleep(nanoseconds: 500_000_000); continue }
                throw error
            }
        }
        throw lastError ?? PlaylistLoadError.invalidFormat
    }

    static func decodePlaylist(data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        // GBK/GB18030 Chinese sources previously decoded as ISO-Latin-1 garbage.
        let gbEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let text = String(data: data, encoding: String.Encoding(rawValue: gbEncoding)) { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    static func parse(text: String, baseURL: URL? = nil) -> [Channel] {
        parseReport(text: text, baseURL: baseURL).channels
    }

    static func parseReport(text: String, baseURL: URL? = nil) -> (channels: [Channel], skipped: Int) {
        var result: [Channel] = []
        var skipped = 0
        var pendingName: String?
        var pendingLogo: URL?
        var pendingEPGID: String?
        var pendingQuality: String?
        var pendingIsLive = true
        var extgrpGroup: String?
        var pendingGroup = GroupID.other
        let lines = text.replacingOccurrences(of: "\u{feff}", with: "").split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        func resolve(_ raw: String) -> URL? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let url = URL(string: trimmed), url.scheme != nil {
                return ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? url : nil
            }
            // Round-3 fix (C04): a relative entry against a local file's
            // directory resolves to a file URL, which is kept (previously
            // the http/https-only check dropped every relative stream and
            // logo from local imports). Absolute non-http(s) URLs are
            // still rejected. Note: playing a file URL later still needs
            // the file to be reachable; the security-scoped access granted
            // by the picker ends after import, so this mainly preserves
            // logos and documents the address instead of silently dropping it.
            if let base = baseURL, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
                return url
            }
            if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let url = URL(string: encoded), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                return url
            }
            return nil
        }
        /// Round-3 fix (C26): a real M3U group literally named "__all__"
        /// or "__other__" used to collide with the internal sentinels and
        /// get hidden or relabelled. Such names are escaped with a
        /// zero-width space at parse time, so they stay distinct internally
        /// while displaying identically.
        func escapedGroup(_ raw: String) -> String {
            raw == GroupID.all || raw == GroupID.other ? raw + "\u{200B}" : raw
        }
        func flushPending() {
            pendingName = nil; pendingLogo = nil; pendingEPGID = nil; pendingQuality = nil
            pendingIsLive = true; pendingGroup = extgrpGroup ?? GroupID.other
        }
        // Round-4 fix (C13): the parse is synchronous, so cancelling its
        // detached task only helps if the parse itself notices. Check
        // every 512 lines and bail out early; callers discard a cancelled
        // parse's result via the generation guard, and an uncancelled
        // parse never hits this branch, so no partial result can commit.
        var lineIndex = 0
        for line in lines {
            lineIndex += 1
            if lineIndex % 512 == 0, Task.isCancelled { return ([], skipped) }
            let upper = line.uppercased()
            if upper.hasPrefix("#EXTGRP:") {
                extgrpGroup = escapedGroup(line.dropFirst("#EXTGRP:".count).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? GroupID.other)
                pendingGroup = extgrpGroup ?? GroupID.other
            } else if upper.hasPrefix("#EXTINF") {
                // A previous EXTINF that never got a URL line is dropped, but
                // counted now instead of silently overwritten.
                if pendingName != nil { skipped += 1 }
                let display = displayName(from: line)
                let rawName = attribute("tvg-name", in: line)
                pendingName = (rawName?.nonEmpty ?? display?.nonEmpty) ?? "未命名频道"
                pendingGroup = escapedGroup(attribute("group-title", in: line)?.nonEmpty ?? extgrpGroup ?? GroupID.other)
                pendingLogo = attribute("tvg-logo", in: line).flatMap(resolve)
                pendingEPGID = attribute("tvg-id", in: line)?.nonEmpty
                pendingQuality = attribute("resolution", in: line) ?? attribute("quality", in: line)
                pendingIsLive = extinfIsLive(line)
            } else if upper.hasPrefix("#EXTVLCOPT") {
                // Deliberately not applied: AVPlayer/KSPlayer do not consume
                // VLC options, and silently claiming otherwise would be worse
                // than ignoring them. See README "known gaps".
                continue
            } else if line.hasPrefix("#") || line.isEmpty {
                continue
            } else if let pending = pendingName {
                // Kodi-style "|Header=..." suffixes are not applied to playback
                // (neither player consumes them); only the URL part is kept.
                let streamPart = line.split(separator: "|", maxSplits: 1).first.map(String.init) ?? line
                guard let url = resolve(streamPart) else { skipped += 1; flushPending(); continue }
                result.append(Channel(name: pending, group: pendingGroup, streamURL: url, logoURL: pendingLogo, epgID: pendingEPGID, quality: pendingQuality, isLive: pendingIsLive))
                flushPending()
            } else if let txt = parseTXTLine(line, baseURL: baseURL) {
                result.append(txt)
            } else {
                skipped += 1
            }
        }
        if pendingName != nil { skipped += 1 }
        // Deduplicate by stable id, keeping the first occurrence, and give
        // later duplicates a suffixed id so ForEach/favorites never collide.
        var seen = Set<String>()
        var deduped: [Channel] = []
        for channel in result {
            if seen.insert(channel.id).inserted {
                deduped.append(channel)
            } else {
                var suffix = 2
                var newID = "\(channel.id)-\(suffix)"
                while seen.contains(newID) { suffix += 1; newID = "\(channel.id)-\(suffix)" }
                seen.insert(newID)
                deduped.append(Channel(id: newID, name: channel.name, group: channel.group, streamURL: channel.streamURL, logoURL: channel.logoURL, epgID: channel.epgID, quality: channel.quality, isLive: channel.isLive))
            }
        }
        return (deduped, skipped)
    }

    /// "Name,http://..." plain-text lines (TXT format), which the old parser
    /// dropped entirely because it required a preceding #EXTINF.
    private static func parseTXTLine(_ line: String, baseURL: URL?) -> Channel? {
        guard let comma = line.firstIndex(of: ",") else { return nil }
        let name = line[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
        let urlPart = line[line.index(after: comma)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !urlPart.isEmpty else { return nil }
        let streamPart = urlPart.split(separator: "|", maxSplits: 1).first.map(String.init) ?? urlPart
        // Round-4 fix (C07): the relative branches used to allow only
        // http/https while M3U's resolve() also keeps file URLs, so a
        // local TXT file's relative stream was silently dropped. Mirror
        // resolve(): relative-to-base allows file; an absolute file URL
        // is only trusted for a local import (base is a file URL), never
        // for a remote TXT, where it would point at the reader's disk.
        let isLocalImport = baseURL?.scheme?.lowercased() == "file"
        let absoluteSchemes = isLocalImport ? ["http", "https", "file"] : ["http", "https"]
        if let url = URL(string: streamPart), absoluteSchemes.contains(url.scheme?.lowercased() ?? "") {
            return Channel(name: name, group: GroupID.other, streamURL: url)
        }
        // Round-5 fix (C04): URL(string:relativeTo:) ignores the base
        // for an already-absolute string, so a remote TXT's absolute
        // file:// address sailed past the absolute-branch rejection and
        // was admitted by this relative branch's un-gated file scheme.
        // The relative branches now use the same local/remote scheme
        // table as the absolute branches.
        let relativeSchemes = absoluteSchemes
        if let base = baseURL, let url = URL(string: streamPart, relativeTo: base)?.absoluteURL, relativeSchemes.contains(url.scheme?.lowercased() ?? "") {
            return Channel(name: name, group: GroupID.other, streamURL: url)
        }
        // Round-3 fix (C22): TXT lines get the same percent-encoding
        // fallback as M3U lines, so an unencoded Chinese/space URL that
        // plays from an #EXTINF line is no longer dropped from a TXT line.
        if let encoded = streamPart.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let url = URL(string: encoded), absoluteSchemes.contains(url.scheme?.lowercased() ?? "") {
            return Channel(name: name, group: GroupID.other, streamURL: url)
        }
        if let base = baseURL, let encoded = streamPart.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let url = URL(string: encoded, relativeTo: base)?.absoluteURL, relativeSchemes.contains(url.scheme?.lowercased() ?? "") {
            return Channel(name: name, group: GroupID.other, streamURL: url)
        }
        return nil
    }

    /// Display name is the text after the last comma *outside* quotes, so
    /// commas inside tvg-name="A,B" no longer truncate the name. With no
    /// such comma, there is no display name (previously the whole EXTINF
    /// line became the channel name).
    private static func displayName(from line: String) -> String? {
        var inDouble = false
        var inSingle = false
        var lastComma: String.Index?
        for index in line.indices {
            let ch = line[index]
            if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "," && !inDouble && !inSingle { lastComma = index }
        }
        guard let comma = lastComma else { return nil }
        return String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// EXTINF duration: -1 (or missing) means live; any other duration is VOD.
    private static func extinfIsLive(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return true }
        let rest = line[line.index(after: colon)...]
        let token = rest.split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init) ?? ""
        return token.isEmpty || token == "-1"
    }

    /// Supports double-quoted, single-quoted and unquoted values. An empty
    /// quoted value returns "" so callers can distinguish it from "missing"
    /// (they use .nonEmpty to fall back).
    private static func attribute(_ key: String, in line: String) -> String? {
        // Round-3 fix (C27): the range used to be taken from a lowercased
        // copy and then applied to the original string. Lowercasing can
        // change grapheme-cluster boundaries before the key, so the index
        // could land mid-character for non-ASCII lines. The lookup now
        // runs case-insensitively on the original string itself, so the
        // range is valid by construction.
        // Round-4 fix (C12): the first case-insensitive match could sit
        // INSIDE a previous attribute's quoted value (e.g. searching
        // tvg-logo in tvg-name="x tvg-logo=y" tvg-logo="real" returned
        // "y"). Scan left to right tracking quotes, and only accept a
        // match that starts outside quotes at an attribute boundary
        // (start of line, space or comma).
        let needle = (key + "=").lowercased()
        var index = line.startIndex
        var inDouble = false
        var inSingle = false
        var keyRange: Range<String.Index>?
        while index < line.endIndex {
            let ch = line[index]
            if ch == "\"" && !inSingle { inDouble.toggle(); index = line.index(after: index); continue }
            if ch == "'" && !inDouble { inSingle.toggle(); index = line.index(after: index); continue }
            if !inDouble && !inSingle {
                let rest = line[index...]
                if rest.lowercased().hasPrefix(needle) {
                    let isBoundary = index == line.startIndex || line[line.index(before: index)] == " " || line[line.index(before: index)] == ","
                    if isBoundary {
                        keyRange = index..<line.index(index, offsetBy: needle.count)
                        break
                    }
                }
            }
            index = line.index(after: index)
        }
        guard let keyRange else { return nil }
        var rest = line[keyRange.upperBound...]
        while rest.first == " " { rest = rest.dropFirst() }
        guard let first = rest.first else { return nil }
        if first == "\"" {
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: "\"") else { return nil }
            return String(body[..<end])
        }
        if first == "'" {
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: "'") else { return nil }
            return String(body[..<end])
        }
        let token = rest.split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init) ?? ""
        return token.isEmpty ? nil : token
    }
}

extension String {
    /// nil for an empty/whitespace-only string, otherwise the trimmed value.
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
