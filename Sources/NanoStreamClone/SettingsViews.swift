import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("subtitleFontSize") private var subtitleFontSize = 18.0
    @AppStorage("httpProxy") private var httpProxy = ""
    @AppStorage("userAgent") private var userAgent = "Mozilla/5.0 (AppleTV; CPU OS 17_0 like Mac..."
    @State private var language = "中文"
    @State private var theme = "System"
    @State private var colorTheme = "剧毒绿"
    @State private var pictureInPicture = true
    @State private var hardwareAcceleration = true
    @State private var autoAudio = true
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                Text("设置").font(.system(size: 22, weight: .bold)).padding(.top, 52)
                SettingsSection(title: "语言", icon: "globe") {
                    SettingsPickerRow(title: "语言", value: $language, options: ["English", "Tiếng Việt", "中文"])
                }
                SettingsSection(title: "外观", icon: "paintbrush") {
                    SettingsPickerRow(title: "主题模式", value: $theme, options: ["System", "Light", "Dark"])
                    SettingsPickerRow(title: "色彩主题", value: $colorTheme, options: ["Cyberpunk", "落日金", "剧毒绿", "霓虹粉", "深海蓝"])
                }
                SettingsSection(title: "播放设置", icon: "play.circle") {
                    ToggleRow(title: "画中画", value: $pictureInPicture)
                    ToggleRow(title: "硬件加速", value: $hardwareAcceleration)
                    ToggleRow(title: "自动选择音轨", value: $autoAudio)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("首选播放器").font(.system(size: 18))
                        Picker("", selection: .constant("KSPlayer")) { Text("Auto").tag("Auto"); Text("AVPlayer").tag("AVPlayer"); Text("KSPlayer").tag("KSPlayer") }.pickerStyle(.segmented)
                        Text("Dùng KSPlayer (FFmpeg) riêng cho IPTV. Tương thích hầu hết mọi định dạng stream.").font(.caption).foregroundStyle(.white.opacity(0.5))
                    }.padding(.vertical, 8)
                    HStack { Text("字幕大小  \(Int(subtitleFontSize)) pt").font(.system(size: 18)); Spacer(); Stepper("", value: $subtitleFontSize, in: 12...40, step: 1).labelsHidden() }
                }
                SettingsSection(title: "网络", icon: "globe.americas") {
                    LabeledField(title: "User-Agent", text: $userAgent)
                    LabeledField(title: "HTTP Proxy", text: $httpProxy, placeholder: "HTTP Proxy")
                }
                SettingsSection(title: "缓冲区", icon: "memorychip") {
                    HStack { Text("网络缓存大小").font(.system(size: 18)); Spacer(); Text("3,000 ms").font(.system(size: 18, design: .monospaced)).foregroundStyle(.neon) }
                    Slider(value: .constant(0.18)).tint(.neon)
                    Text("网络连接较慢或不稳定时，可增加缓存").font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                SettingsSection(title: "数据与缓存", icon: "externaldrive") {
                    ActionRow(title: "清除图片缓存", icon: "trash")
                    ActionRow(title: "清除播放历史", icon: "clock.badge.xmark")
                }
                Text("NanoStream 是一个媒体播放器外壳。请仅添加您有权观看的播放列表和视频流。").font(.caption).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.leading).padding(.horizontal, 22).padding(.bottom, 120)
            }
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String; let icon: String; @ViewBuilder let content: Content
    var body: some View { VStack(alignment: .leading, spacing: 0) { Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.72)).padding(.bottom, 14); content }.padding(18).background(Color.card, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.neon.opacity(0.42), lineWidth: 1)).padding(.horizontal, 22) }
}
struct SettingsPickerRow: View { let title: String; @Binding var value: String; let options: [String]; var body: some View { HStack { Text(title).font(.system(size: 18)); Spacer(); Menu { ForEach(options, id: \.self) { option in Button(option) { value = option } } } label: { Text(value).foregroundStyle(.neon); Image(systemName: "chevron.up.chevron.down").foregroundStyle(.neon) }.buttonStyle(.plain) }.padding(.vertical, 11).overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) } } }
struct ToggleRow: View { let title: String; @Binding var value: Bool; var body: some View { HStack { Text(title).font(.system(size: 18)); Spacer(); Toggle("", isOn: $value).labelsHidden().tint(.neon) }.padding(.vertical, 8).overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) } } }
struct LabeledField: View { let title: String; @Binding var text: String; var placeholder = ""; var body: some View { VStack(alignment: .leading, spacing: 7) { Text(title).font(.subheadline).foregroundStyle(.white.opacity(0.55)); TextField(placeholder.isEmpty ? title : placeholder, text: $text).textFieldStyle(.plain).padding(12).background(Color.cardInner, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.12))) } .padding(.vertical, 5) } }
struct ActionRow: View { let title: String; let icon: String; var body: some View { HStack { Image(systemName: icon).foregroundStyle(.neon); Text(title).font(.system(size: 18)).foregroundStyle(.neon); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4)) }.padding(.vertical, 11).overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) } } }

struct PlaylistFormView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var source = "M3U 链接"
    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showFileImporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("添加播放列表")
                        .font(.system(size: 24, weight: .bold))
                        .padding(.top, 8)
                    Text("播放列表来源")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.neon)
                    SourcePicker(source: $source, chooseFile: { showFileImporter = true })
                    Text("详细信息")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.neon)
                    TextField("输入列表名称", text: $name)
                        .fieldStyle()
                    if source == "Xtream" {
                        TextField("服务器地址 (http://...)", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().fieldStyle()
                        TextField("用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().fieldStyle()
                        SecureField("密码", text: $password).fieldStyle()
                    } else if source == "M3U 链接" {
                        TextField("URL (http://...)", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().fieldStyle()
                    } else {
                        Button { showFileImporter = true } label: { Label(url.isEmpty ? "选择本地 M3U 文件" : url, systemImage: "doc.badge.plus").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).fieldStyle()
                    }
                    AddPlaylistButton(name: name, source: source, url: url) {
                        state.addPlaylist(name: name, kind: source == "Xtream" ? .xtream : .m3u, endpoint: url, username: username, password: password)
                        dismiss()
                    }
                }
                .padding(22)
            }
            .background(Color.appBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
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
    @Binding var source: String
    let chooseFile: () -> Void
    private let options = ["本地文件", "M3U 链接", "Xtream"]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.self) { item in
                Button { if item == "本地文件" { chooseFile() } else { source = item } } label: {
                    VStack(spacing: 8) {
                        Image(systemName: icon(for: item)).font(.title2)
                        Text(item).font(.caption)
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
}

struct AddPlaylistButton: View {
    let name: String
    let source: String
    let url: String
    let action: () -> Void

    var body: some View {
        Button("添加列表", action: action)
            .font(.headline)
            .foregroundStyle(url.isEmpty ? .white.opacity(0.35) : Color.appBackground)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(url.isEmpty ? Color.panel : Color.neon, in: RoundedRectangle(cornerRadius: 14))
            .disabled(url.isEmpty)
    }
}
private extension View { func fieldStyle() -> some View { self.textFieldStyle(.plain).padding(16).background(Color.cardInner, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.14))) } }
