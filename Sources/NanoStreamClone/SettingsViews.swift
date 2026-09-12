import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("subtitleFontSize") private var subtitleFontSize = 18.0
    @AppStorage("httpProxy") private var httpProxy = ""
    @AppStorage("userAgent") private var userAgent = "Mozilla/5.0 (AppleTV; CPU OS 17_0 like Mac..."
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                Text(state.localized("设置")).font(.system(size: 22, weight: .bold)).padding(.top, 52)
                SettingsSection(title: state.localized("语言"), icon: "globe") {
                    SettingsPickerRow(title: state.localized("语言"), value: Binding(get: { state.language }, set: { state.setLanguage($0) }), options: ["English", "Tiếng Việt", "中文", "繁體中文"])
                }
                SettingsSection(title: state.localized("外观"), icon: "paintbrush") {
                    SettingsPickerRow(title: state.localized("主题模式"), value: Binding(get: { state.themeMode }, set: { state.setTheme($0) }), options: ["System", "Light", "Dark"])
                    SettingsPickerRow(title: state.localized("色彩主题"), value: Binding(get: { state.colorTheme }, set: { state.setColorTheme($0) }), options: ["Cyberpunk", "落日金", "剧毒绿", "霓虹粉", "深海蓝"])
                }
                SettingsSection(title: state.localized("播放设置"), icon: "play.circle") {
                    ToggleRow(title: state.localized("画中画"), value: Binding(get: { state.pictureInPicture }, set: { state.setPictureInPicture($0) }))
                    ToggleRow(title: state.localized("硬件加速"), value: Binding(get: { state.hardwareAcceleration }, set: { state.setHardwareAcceleration($0) }))
                    ToggleRow(title: state.localized("自动选择音轨"), value: Binding(get: { state.automaticAudioSelection }, set: { state.setAutomaticAudioSelection($0) }))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(state.localized("首选播放器")).font(.system(size: 18))
                        Picker("", selection: Binding(get: { state.preferredPlayer }, set: { state.setPreferredPlayer($0) })) { ForEach(PreferredPlayer.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).tint(state.accent)
                        Text(state.localized(state.preferredPlayer == .avPlayer ? "AVPlayer 使用系统原生解码，不支持的视频轨自动交给 KSPlayer。" : state.preferredPlayer == .ksPlayer ? "KSPlayer 使用 FFmpeg，适合更多 IPTV 流格式。" : "Auto 先尝试 AVPlayer，失败后自动切换 KSPlayer。")).font(.caption).foregroundStyle(.white.opacity(0.5))
                    }.padding(.vertical, 8)
                    HStack { Text("\(state.localized("字幕大小"))  \(Int(subtitleFontSize)) pt").font(.system(size: 18)); Spacer(); Stepper("", value: $subtitleFontSize, in: 12...40, step: 1).labelsHidden() }
                }
                SettingsSection(title: state.localized("网络"), icon: "globe.americas") {
                    LabeledField(title: "User-Agent", text: $userAgent)
                    LabeledField(title: "HTTP Proxy", text: $httpProxy, placeholder: "HTTP Proxy")
                }
                SettingsSection(title: state.localized("缓冲区"), icon: "memorychip") {
                    HStack { Text(state.localized("网络缓存大小")).font(.system(size: 18)); Spacer(); Text("\(Int(state.networkBufferMilliseconds)) ms").font(.system(size: 18, design: .monospaced)).foregroundStyle(state.accent) }
                    Slider(value: Binding(get: { state.networkBufferMilliseconds }, set: { state.setBuffer($0) }), in: 0...10000, step: 250).tint(state.accent)
                    Text(state.localized("网络连接较慢或不稳定时，可增加缓存")).font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                SettingsSection(title: state.localized("数据与缓存"), icon: "externaldrive") {
                    ActionRow(title: state.localized("清除图片缓存"), icon: "trash") { state.clearImageCache() }
                    ActionRow(title: state.localized("清除播放历史"), icon: "clock.badge.xmark") { state.clearHistory() }
                }
                SettingsSection(title: state.localized("EPG节目单"), icon: "list.bullet.rectangle.portrait") {
                    LabeledField(title: state.localized("EPG地址"), text: Binding(get: { state.epgURL }, set: { state.setEPGURL($0) }), placeholder: "https://example.com/guide.xml")
                    HStack(spacing: 12) {
                        Button(state.localized("刷新节目单")) { state.reloadEPG() }
                            .buttonStyle(.borderedProminent).tint(state.accent)
                            .disabled(state.epgURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isLoadingEPG)
                        if state.isLoadingEPG { ProgressView().tint(state.accent) }
                        if state.epgError == nil, !state.epgURL.isEmpty, !state.isLoadingEPG, !state.epgGuide.programsByChannelID.isEmpty {
                            Label(state.localized("节目单已更新。"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(state.accent)
                        }
                    }.padding(.top, 6)
                    if let epgError = state.epgError { Text(epgError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(.top, 4) }
                }
                Text(state.localized("NanoStream 是一个媒体播放器外壳。请仅添加您有权观看的播放列表和视频流。")).font(.caption).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.leading).padding(.horizontal, 22).padding(.bottom, 120)
            }
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String; let icon: String; @ViewBuilder let content: Content
    var body: some View { VStack(alignment: .leading, spacing: 0) { Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.72)).padding(.bottom, 14); content }.padding(18).background(Color.card, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.neon.opacity(0.42), lineWidth: 1)).padding(.horizontal, 22) }
}
struct SettingsPickerRow: View {
    @EnvironmentObject private var state: AppState
    let title: String
    @Binding var value: String
    let options: [String]

    var body: some View {
        HStack {
            Text(title).font(.system(size: 18))
            Spacer()
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(state.localizedValue(option)) { value = option }
                }
            } label: {
                Text(state.localizedValue(value)).foregroundStyle(.neon)
                Image(systemName: "chevron.up.chevron.down").foregroundStyle(.neon)
            }.buttonStyle(.plain)
        }.padding(.vertical, 11).overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) }
    }
}
struct ToggleRow: View { let title: String; @Binding var value: Bool; var body: some View { HStack { Text(title).font(.system(size: 18)); Spacer(); Toggle("", isOn: $value).labelsHidden().tint(.neon) }.padding(.vertical, 8).overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) } } }
struct LabeledField: View { let title: String; @Binding var text: String; var placeholder = ""; var body: some View { VStack(alignment: .leading, spacing: 7) { Text(title).font(.subheadline).foregroundStyle(.white.opacity(0.55)); TextField(placeholder.isEmpty ? title : placeholder, text: $text).textFieldStyle(.plain).padding(12).background(Color.cardInner, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.12))) } .padding(.vertical, 5) } }
struct ActionRow: View { let title: String; let icon: String; let action: () -> Void; var body: some View { Button(action: action) { HStack { Image(systemName: icon).foregroundStyle(.neon); Text(title).font(.system(size: 18)).foregroundStyle(.neon); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4)) }.padding(.vertical, 11).overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) } }.buttonStyle(.plain) } }

struct PlaylistFormView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let editingPlaylist: Playlist?
    @State private var source = "M3U 链接"
    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showFileImporter = false
    @State private var isSaving = false
    @State private var errorText: String?

    init(editingPlaylist: Playlist? = nil) {
        self.editingPlaylist = editingPlaylist
        let source: String
        switch editingPlaylist?.kind {
        case .xtream: source = "Xtream"
        case .m3u: source = editingPlaylist?.endpoint == "本地文件" ? "本地文件" : "M3U 链接"
        case .tvHeadend: source = "M3U 链接"
        case .none: source = "M3U 链接"
        }
        _source = State(initialValue: source)
        _name = State(initialValue: editingPlaylist?.name ?? "")
        _url = State(initialValue: editingPlaylist?.endpoint == "本地文件" ? "" : editingPlaylist?.endpoint ?? "")
        _username = State(initialValue: editingPlaylist?.username ?? "")
        _password = State(initialValue: editingPlaylist?.password ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(state.localized(editingPlaylist == nil ? "添加播放列表" : "编辑播放列表"))
                        .font(.system(size: 24, weight: .bold))
                        .padding(.top, 8)
                    Text(state.localized("播放列表来源"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.neon)
                    SourcePicker(source: $source, chooseFile: { showFileImporter = true })
                    Text(state.localized("详细信息"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.neon)
                    TextField(state.localized("输入列表名称"), text: $name)
                        .fieldStyle()
                    if source == "Xtream" {
                        TextField(state.localized("服务器地址 (http://...)"), text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().fieldStyle()
                        TextField(state.localized("用户名"), text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().fieldStyle()
                        SecureField(state.localized("密码"), text: $password).fieldStyle()
                    } else if source == "M3U 链接" {
                        TextField("URL (http://...)", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().fieldStyle()
                    } else {
                        Button { showFileImporter = true } label: { Label(url.isEmpty ? state.localized("选择本地 M3U 文件") : url, systemImage: "doc.badge.plus").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).fieldStyle()
                    }
                    if source != "本地文件" || editingPlaylist != nil {
                    AddPlaylistButton(name: name, source: source, url: source == "本地文件" ? "local-file" : url, username: username, password: password, isSaving: isSaving, title: state.localized(editingPlaylist == nil ? "添加列表" : "保存并刷新")) {
                        isSaving = true
                        if let editingPlaylist {
                            let updated = Playlist(id: editingPlaylist.id, name: name, kind: source == "Xtream" ? .xtream : .m3u, endpoint: source == "本地文件" ? "本地文件" : url, username: username, password: password, channelCount: editingPlaylist.channelCount, lastRefresh: editingPlaylist.lastRefresh)
                            state.updatePlaylist(updated) { success in
                                isSaving = false
                                if success { dismiss() } else { errorText = state.playlistError ?? state.localized("播放列表添加失败。") }
                            }
                        } else {
                            state.addPlaylist(name: name, kind: source == "Xtream" ? .xtream : .m3u, endpoint: url, username: username, password: password) { success in
                                isSaving = false
                                if success { dismiss() } else { errorText = state.playlistError ?? state.localized("播放列表添加失败。") }
                            }
                        }
                    }
                    }
                    if let errorText { Text(errorText).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(22)
            }
            .background(Color.appBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(state.localized("关闭")) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.plainText, .data], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let fileURL = urls.first else { return }
            guard fileURL.startAccessingSecurityScopedResource() else { return }
            defer { fileURL.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else { return }
            state.addPlaylistFromText(name: name.isEmpty ? fileURL.deletingPathExtension().lastPathComponent : name, text: text)
            url = fileURL.lastPathComponent
            source = "本地文件"
        }
    }
}

struct SourcePicker: View {
    @EnvironmentObject private var state: AppState
    @Binding var source: String
    let chooseFile: () -> Void
    private let options = ["本地文件", "M3U 链接", "Xtream"]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.self) { item in
                Button { if item == "本地文件" { chooseFile() } else { source = item } } label: {
                    VStack(spacing: 8) {
                        Image(systemName: icon(for: item)).font(.title2)
                        Text(displayName(for: item)).font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 82)
                    .foregroundStyle(source == item ? Color.neon : .white.opacity(0.7))
                    .background(source == item ? Color.neon.opacity(0.15) : Color.panel, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(source == item ? Color.neon : .white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func icon(for item: String) -> String {
        switch item { case "本地文件": return "doc"; case "M3U 链接": return "link"; default: return "server.rack" }
    }

    private func displayName(for item: String) -> String {
        state.localized(item)
    }
}

struct AddPlaylistButton: View {
    let name: String
    let source: String
    let url: String
    let username: String
    let password: String
    let isSaving: Bool
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(!isValid || isSaving ? Color.panel : Color.neon)
                if isSaving { ProgressView().tint(.white) }
                else { Text(title).font(.headline).foregroundStyle(!isValid ? .white.opacity(0.35) : Color.appBackground) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .disabled(!isValid || isSaving)
    }

    private var isValid: Bool { !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (source != "Xtream" || (!username.isEmpty && !password.isEmpty)) }
}
private extension View { func fieldStyle() -> some View { self.textFieldStyle(.plain).padding(16).background(Color.cardInner, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.14))) } }
