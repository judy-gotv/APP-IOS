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
    @Published var gridLayout: GridLayout
    @Published var pictureInPicture: Bool
    let player = StreamPlayer()

    // v4 intentionally starts with no bundled/demo channels. Existing installs
    // using the old demo state are migrated to a clean, user-owned library.
    private let storageKey = "nanostream.state.v4"

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
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "nanostream.ksPlayerDefault.v1") {
            preferredPlayer = PreferredPlayer(rawValue: defaults.string(forKey: "nanostream.player") ?? "KSPlayer") ?? .ksPlayer
        } else {
            preferredPlayer = .ksPlayer
            defaults.set(PreferredPlayer.ksPlayer.rawValue, forKey: "nanostream.player")
            defaults.set(true, forKey: "nanostream.ksPlayerDefault.v1")
        }
        networkBufferMilliseconds = UserDefaults.standard.object(forKey: "nanostream.buffer") as? Double ?? 3000
        gridLayout = GridLayout(rawValue: UserDefaults.standard.string(forKey: "nanostream.grid") ?? GridLayout.twoColumns.rawValue) ?? .twoColumns
        pictureInPicture = UserDefaults.standard.object(forKey: "nanostream.pip") as? Bool ?? true
    }

    var groups: [String] { ["全部"] + Array(Set(channels.map(\.group))).sorted() }

    var visibleChannels: [Channel] {
        channels.filter { channel in
            (selectedGroup == "全部" || channel.group == selectedGroup) &&
            (searchText.isEmpty || channel.name.localizedCaseInsensitiveContains(searchText))
        }
    }

    var favoriteChannels: [Channel] { channels.filter { favorites.contains($0.id) } }

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
    func setGridLayout(_ value: GridLayout) { gridLayout = value; UserDefaults.standard.set(value.rawValue, forKey: "nanostream.grid") }
    func setPictureInPicture(_ value: Bool) { pictureInPicture = value; UserDefaults.standard.set(value, forKey: "nanostream.pip") }
    func localized(_ key: String) -> String {
        guard language != "中文" else { return key }
        let table: [String: (String, String)] = [
            "设置": ("Settings", "Cài đặt"), "播放列表": ("Playlists", "Danh sách phát"), "收藏": ("Favorites", "Yêu thích"), "主页": ("Home", "Trang chủ"),
            "全部": ("All", "Tất cả"), "搜索频道...": ("Search channels...", "Tìm kênh..."), "最近播放": ("Recently played", "Đã phát gần đây"),
            "暂无播放记录": ("No playback history", "Chưa có lịch sử phát"), "暂无频道": ("No channels", "Chưa có kênh"),
            "请先在“播放列表”中添加 M3U 或 Xtream 来源。": ("Add an M3U or Xtream source in Playlists first.", "Hãy thêm nguồn M3U hoặc Xtream trong Danh sách phát."),
            "无收藏频道": ("No favorite channels", "Chưa có kênh yêu thích"), "用星号标记频道以便在此快速访问。": ("Star a channel to access it here.", "Đánh dấu sao để truy cập nhanh tại đây."),
            "暂无播放列表": ("No playlists", "Chưa có danh sách phát"), "添加播放列表": ("Add playlist", "Thêm danh sách phát"), "关闭": ("Close", "Đóng"),
            "订阅": ("Subscriptions", "Đăng ký"), "频道": ("Channels", "Kênh"), "节目": ("Programs", "Chương trình"), "暂无节目数据": ("No program data", "Chưa có dữ liệu chương trình"),
            "编码信息": ("Stream information", "Thông tin luồng"), "暂无数据": ("Unavailable", "Không có dữ liệu"), "播放失败，请检查频道地址。": ("Playback failed. Check the channel URL.", "Phát không thành công. Hãy kiểm tra URL kênh."),
            "语言": ("Language", "Ngôn ngữ"), "外观": ("Appearance", "Giao diện"), "播放设置": ("Playback", "Phát lại"), "网络": ("Network", "Mạng"), "缓冲区": ("Buffer", "Bộ đệm"), "数据与缓存": ("Data & cache", "Dữ liệu & bộ nhớ đệm"),
            "主题模式": ("Theme", "Chủ đề"), "色彩主题": ("Accent color", "Màu nhấn"), "画中画": ("Picture in Picture", "Hình trong hình"), "硬件加速": ("Hardware acceleration", "Tăng tốc phần cứng"), "自动选择音轨": ("Auto-select audio", "Tự chọn âm thanh"), "首选播放器": ("Preferred player", "Trình phát ưu tiên"), "字幕大小": ("Subtitle size", "Cỡ phụ đề"),
            "网络缓存大小": ("Network buffer", "Bộ đệm mạng"), "清除图片缓存": ("Clear image cache", "Xóa bộ nhớ ảnh"), "清除播放历史": ("Clear playback history", "Xóa lịch sử phát"), "选择本地 M3U 文件": ("Choose local M3U file", "Chọn tệp M3U cục bộ"), "输入列表名称": ("Playlist name", "Tên danh sách phát"), "详细信息": ("Details", "Chi tiết"), "播放列表来源": ("Playlist source", "Nguồn danh sách phát"), "添加列表": ("Add playlist", "Thêm danh sách phát"),
            "2列": ("2 columns", "2 cột"), "4列": ("4 columns", "4 cột"),
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
            "本地文件": ("Local file", "Tệp cục bộ"), "M3U 链接": ("M3U link", "Liên kết M3U"), "服务器地址 (http://...)": ("Server URL (http://...)", "URL máy chủ (http://...)"), "用户名": ("Username", "Tên người dùng"), "密码": ("Password", "Mật khẩu")
        ]
        if language == "English" { return table[key]?.0 ?? key }
        if language == "Tiếng Việt" { return table[key]?.1 ?? key }
        let traditional: [String: String] = [
            "设置": "設定", "播放列表": "播放清單", "收藏": "收藏", "主页": "首頁", "全部": "全部",
            "搜索频道...": "搜尋頻道...", "最近播放": "最近播放", "暂无播放记录": "暫無播放記錄", "暂无频道": "暫無頻道",
            "请先在“播放列表”中添加 M3U 或 Xtream 来源。": "請先在「播放清單」中加入 M3U 或 Xtream 來源。",
            "无收藏频道": "沒有收藏的頻道", "用星号标记频道以便在此快速访问。": "以星號標記頻道，即可在這裡快速開啟。",
            "暂无播放列表": "暫無播放清單", "添加播放列表": "加入播放清單", "关闭": "關閉",
            "订阅": "訂閱", "频道": "頻道", "节目": "節目", "暂无节目数据": "暫無節目資料",
            "编码信息": "編碼資訊", "暂无数据": "暫無資料", "播放失败，请检查频道地址。": "播放失敗，請檢查頻道網址。",
            "语言": "語言", "外观": "外觀", "播放设置": "播放設定", "网络": "網路", "缓冲区": "緩衝區", "数据与缓存": "資料與快取",
            "主题模式": "主題模式", "色彩主题": "色彩主題", "画中画": "子母畫面", "首选播放器": "偏好播放器", "字幕大小": "字幕大小",
            "网络缓存大小": "網路緩衝大小", "清除图片缓存": "清除圖片快取", "清除播放历史": "清除播放記錄",
            "选择本地 M3U 文件": "選擇本機 M3U 檔案", "输入列表名称": "輸入清單名稱", "详细信息": "詳細資訊", "播放列表来源": "播放清單來源", "添加列表": "加入清單",
            "2列": "2 欄", "4列": "4 欄", "AVPlayer 使用系统原生解码，不支持的视频轨自动交给 KSPlayer。": "AVPlayer 使用系統原生解碼，不支援的視訊軌會自動交給 KSPlayer。",
            "KSPlayer 使用 FFmpeg，适合更多 IPTV 流格式。": "KSPlayer 使用 FFmpeg，支援更多 IPTV 串流格式。",
            "Auto 先尝试 AVPlayer，失败后自动切换 KSPlayer。": "Auto 會先嘗試 AVPlayer，失敗後自動切換至 KSPlayer。",
            "网络连接较慢或不稳定时，可增加缓存": "網路較慢或不穩定時，可增加緩衝。",
            "NanoStream 是一个媒体播放器外壳。请仅添加您有权观看的播放列表和视频流。": "NanoStream 是媒體播放器。請只加入您有權觀看的播放清單與串流。",
            "文件中没有找到有效频道。": "檔案中找不到有效頻道。", "播放列表添加失败。": "無法加入播放清單。", "图片缓存已清除。": "圖片快取已清除。",
            "播放列表地址无效。": "播放清單網址無效。", "播放列表为空或没有有效频道。": "播放清單為空或沒有有效頻道。", "返回内容不是有效的 M3U 播放列表。": "回傳內容不是有效的 M3U 播放清單。",
            "系统": "系統", "浅色": "淺色", "深色": "深色", "赛博朋克": "電馭叛客", "落日金": "落日金", "剧毒绿": "劇毒綠", "霓虹粉": "霓虹粉", "深海蓝": "深海藍",
            "本地文件": "本機檔案", "M3U 链接": "M3U 連結", "服务器地址 (http://...)": "伺服器網址 (http://...)", "用户名": "使用者名稱", "密码": "密碼"
        ]
        return traditional[key] ?? key.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? key
    }

    func localizedValue(_ value: String) -> String {
        switch value {
        case "System": return localized("系统")
        case "Light": return localized("浅色")
        case "Dark": return localized("深色")
        case "Cyberpunk": return localized("赛博朋克")
        case "落日金": return localized("落日金")
        case "剧毒绿": return localized("剧毒绿")
        case "霓虹粉": return localized("霓虹粉")
        case "深海蓝": return localized("深海蓝")
        default: return value
        }
    }

    func localizedError(_ error: Error) -> String {
        if let playlistError = error as? PlaylistLoadError {
            switch playlistError {
            case .invalidURL: return localized("播放列表地址无效。")
            case .httpStatus(let status):
                if language == "中文" { return "服务器返回 HTTP \(status)。" }
                if language == "繁體中文" { return "伺服器回傳 HTTP \(status)。" }
                return language == "Tiếng Việt" ? "Máy chủ trả về HTTP \(status)." : "The server returned HTTP \(status)."
            case .empty: return localized("播放列表为空或没有有效频道。")
            case .invalidFormat: return localized("返回内容不是有效的 M3U 播放列表。")
            }
        }
        return error.localizedDescription
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
        save()
    }

    func channel(for id: String) -> Channel? { channels.first { $0.id == id } }

    func addPlaylist(name: String, kind: PlaylistKind, endpoint: String, username: String = "", password: String = "", completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        Task { await importPlaylist(name: name, kind: kind, endpoint: endpoint, username: username, password: password, completion: completion) }
    }

    func addPlaylistFromText(name: String, text: String) {
        Task { @MainActor in
            let parsed = M3UParser.parse(text: text)
            guard !parsed.isEmpty else { playlistError = localized("文件中没有找到有效频道。"); return }
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
        activatePlaylist(playlist)
    }

    func activatePlaylist(_ playlist: Playlist) {
        Task { await reloadPlaylist(playlist) }
    }

    func clearHistory() { recent.removeAll(); save() }
    func clearImageCache() { URLCache.shared.removeAllCachedResponses(); playlistError = localized("图片缓存已清除。") }

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
            playlistError = localizedError(error)
            await completion(false)
        }
        isLoadingPlaylist = false
    }

    private func reloadPlaylist(_ playlist: Playlist) async {
        isLoadingPlaylist = true
        playlistError = nil
        do {
            let loaded = try await PlaylistLoader.load(kind: playlist.kind, endpoint: playlist.endpoint, username: playlist.username, password: playlist.password)
            guard !loaded.isEmpty else { throw PlaylistLoadError.empty }
            channels = loaded
            if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                playlists[index].channelCount = loaded.count
                playlists[index].lastRefresh = Date()
            }
            selectedGroup = "全部"
            searchText = ""
            save()
        } catch {
            playlistError = localizedError(error)
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

enum GridLayout: String, CaseIterable, Identifiable {
    case twoColumns = "2列"
    case fourColumns = "4列"
    var id: String { rawValue }
    var columns: Int { self == .twoColumns ? 2 : 4 }
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
