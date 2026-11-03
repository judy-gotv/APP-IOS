import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("subtitleFontSize") private var subtitleFontSize = 18.0
    @AppStorage("httpProxy") private var httpProxy = ""
    // Round-6 fix (A02): mirrors M3UParser.proxyMigrationFailed, synced
    // on appear/disappear of the proxy field. A failed Keychain migration
    // leaves the password in plain text in UserDefaults and the fetch path
    // keeps using it as a fallback; without this state the failure was
    // completely silent.
    @State private var proxyMigrationFailed = false
    // Round-7 fix (A02): incremented when the "clear stored proxy
    // password" button is tapped, so the body re-evaluates and the
    // button/warning visibility updates immediately instead of
    // lingering until the next render. (Since round 10 the visibility
    // reads cached flags, refreshed by refreshCachedProxyPasswordFlags
    // at the same tap; the counter remains as a re-render guarantee.)
    @State private var proxyPasswordClearedCount = 0
    // Round-9 fix (A03): hasAnyProxyPassword() enumerates the Keychain
    // on every call, and the clear-all button's visibility used to call
    // it directly in the body — so every keystroke in the proxy field
    // (an @AppStorage change re-evaluates the body) ran a Keychain
    // enumeration. Cache it and refresh only at nodes where the answer
    // can actually change: field appear/disappear, the clear buttons,
    // and proxy-password-stored notifications (round-10 A02).
    @State private var cachedHasAnyProxyPassword = false
    // Round-10 fix (A03): the single-identity clear button and the
    // no-password warning had the same per-keystroke Keychain read
    // (a single-entry lookup, not an enumeration — which is why round
    // 9 left them alone). Cache the current identity's password
    // existence alongside the flag above, refreshed at the same nodes.
    // Known trade-off, stated plainly: while the user is mid-edit the
    // cache tracks the identity as of the last refresh node, so typing
    // a new username can transiently show the previous identity's
    // button/warning state until the next node (appear/disappear, a
    // clear tap, or a background migration success). The button's
    // action always computes its target from the live field text, so a
    // tap can never delete another identity's entry; and leaving the
    // field refreshes both flags, so the settled state is exact.
    @State private var cachedCurrentProxyPasswordExists = false
    // Round-11 fix (A03): the canonical identity the cached flags were
    // last refreshed for ("" when the field has no username identity).
    // A stored-notification for an unchanged identity with both flags
    // already true cannot change either flag — a Keychain write can
    // only turn them false -> true — so that refresh can skip the
    // enumeration entirely (see the notification handler below).
    @State private var lastProxyFlagRefreshIdentity = ""
    // The canonical identity the cached flags describe, or "" when the
    // field holds no username identity (a username-less value can never
    // gain a Keychain entry, so it never satisfies the skip condition).
    private func currentProxyFlagIdentity() -> String {
        if let parsed = M3UParser.parseProxy(httpProxy), let proxyUser = parsed.username, !proxyUser.isEmpty {
            return M3UParser.canonicalProxy(host: parsed.host, port: parsed.port, username: proxyUser)
        }
        return ""
    }
    // Refreshes both cached proxy-password flags from the Keychain for
    // the field's current value. Called at the nodes above, never from
    // the body itself, so keystrokes do no Keychain reads.
    private func refreshCachedProxyPasswordFlags() {
        cachedHasAnyProxyPassword = KeychainStore.hasAnyProxyPassword()
        if let parsed = M3UParser.parseProxy(httpProxy), let proxyUser = parsed.username, !proxyUser.isEmpty {
            cachedCurrentProxyPasswordExists = KeychainStore.proxyPassword(forProxy: M3UParser.canonicalProxy(host: parsed.host, port: parsed.port, username: proxyUser)) != nil
        } else {
            cachedCurrentProxyPasswordExists = false
        }
        lastProxyFlagRefreshIdentity = currentProxyFlagIdentity()
    }
    // Previously this default was literally a truncated sentence ending in
    // "...". An empty value now means "use the app's built-in UA" (see
    // M3UParser.configuredSession); a user value is used as-is.
    @AppStorage("userAgent") private var userAgent = ""
    @State private var showClearHistoryConfirm = false
    @State private var showClearFavoritesConfirm = false
    @State private var showDeleteEPGConfirm = false
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                Text(state.localized("设置")).font(.system(size: 22, weight: .bold)).padding(.top, 52)
                SettingsSection(title: state.localized("语言"), icon: "globe") {
                    SettingsPickerRow(title: state.localized("语言"), value: Binding(get: { state.language }, set: { state.setLanguage($0) }), options: ["English", "Tiếng Việt", "中文", "繁體中文"])
                }
                SettingsSection(title: state.localized("外观"), icon: "paintbrush") {
                    SettingsPickerRow(title: state.localized("主题模式"), value: Binding(get: { state.themeMode }, set: { state.setTheme($0) }), options: ["System", "Light", "Dark"])
                    SettingsPickerRow(title: state.localized("色彩主题"), value: Binding(get: { state.colorTheme }, set: { state.setColorTheme($0) }), options: ["cyberpunk", "sunset", "toxic", "neonPink", "deepBlue"])
                }
                SettingsSection(title: state.localized("播放设置"), icon: "play.circle") {
                    ToggleRow(title: state.localized("画中画"), value: Binding(get: { state.pictureInPicture }, set: { state.setPictureInPicture($0) }))
                    ToggleRow(title: state.localized("硬件加速"), value: Binding(get: { state.hardwareAcceleration }, set: { state.setHardwareAcceleration($0) }))
                    // Round-3 fix (B02): the switch had no caption while
                    // the subtitle/UA/proxy rows all did, so users assumed
                    // it did something on AVPlayer too. It only affects
                    // KSPlayer; AVPlayer decoding is the system default.
                    Text(state.localized("硬件加速仅影响 KSPlayer；AVPlayer 侧为系统默认解码行为，无额外效果。")).font(.caption).foregroundStyle(.secondary)
                    ToggleRow(title: state.localized("自动选择音轨"), value: Binding(get: { state.automaticAudioSelection }, set: { state.setAutomaticAudioSelection($0) }))
                    ToggleRow(title: state.localized("预览"), value: Binding(get: { state.previewEnabled }, set: { state.setPreviewEnabled($0) }))
                    ToggleRow(title: state.localized("显示延迟"), value: Binding(get: { state.showLatency }, set: { state.setShowLatency($0) }))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(state.localized("首选播放器")).font(.system(size: 18))
                        Picker("", selection: Binding(get: { state.preferredPlayer }, set: { state.setPreferredPlayer($0) })) { ForEach(PreferredPlayer.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).tint(state.accent)
                        Text(state.localized(state.preferredPlayer == .avPlayer ? "AVPlayer 使用系统原生解码，不支持的视频轨自动交给 KSPlayer。" : state.preferredPlayer == .ksPlayer ? "KSPlayer 使用 FFmpeg，适合更多 IPTV 流格式。" : "Auto 先尝试 AVPlayer，失败后自动切换 KSPlayer。")).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                    HStack { Text("\(state.localized("字幕大小"))  \(Int(subtitleFontSize)) pt").font(.system(size: 18)); Spacer(); Stepper("", value: $subtitleFontSize, in: 12...40, step: 1).labelsHidden() }
                    Text(state.localized("此设置暂未接入播放器字幕渲染，仅保存偏好。")).font(.caption).foregroundStyle(.secondary)
                }
                SettingsSection(title: state.localized("网络"), icon: "globe.americas") {
                    LabeledField(title: "User-Agent", text: $userAgent)
                    Text(state.localized("留空时使用内置标识；仅用于 M3U/EPG 请求，KSPlayer 不读取此设置。")).font(.caption).foregroundStyle(.secondary)
                    LabeledField(title: "HTTP Proxy", text: $httpProxy, placeholder: "HTTP Proxy")
                        // Round-5 fix (A01): migrate an embedded proxy
                        // password into the Keychain when the field
                        // appears or is left — deliberately NOT onChange:
                        // stripping on every keystroke would corrupt a
                        // password still being typed (the first keystroke
                        // that completes a valid host:port would rewrite
                        // the field and eat the rest of the input).
                        // Round-6 fix (A01/A02): on leaving the field,
                        // prune a stored password only when the field was
                        // left empty (the proxy was removed entirely) or
                        // when it never contained an inline password at
                        // all — never right after a migration, because a
                        // successfully migrated field looks exactly like
                        // "user@host:port" and pruning there would delete
                        // the password the user expects to keep. The
                        // explicit button below covers that case. The
                        // migration-failure flag is synced here so a
                        // failed Keychain write surfaces as a warning
                        // instead of silently falling back to plain text.
                        // Round-7 fix (A06): prune is no longer tied
                        // only to leaving the field. If the field is
                        // already empty when it appears (e.g. the app
                        // was killed after the user cleared it, before
                        // onDisappear ever ran), prune now; and any
                        // change that empties the field prunes at once,
                        // so a killed app cannot leave a stored password
                        // behind for a later re-entry to resurrect.
                        .onAppear {
                            // Round-9 fix (A02): mark the field open
                            // BEFORE migrating, so a migrate triggered
                            // while this page is mounted never deletes a
                            // previous identity mid-edit (see
                            // M3UParser.proxyFieldOpen).
                            M3UParser.proxyFieldOpen = true
                            if httpProxy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { M3UParser.pruneStoredProxyPassword() }
                            M3UParser.migrateStoredProxyPassword(); proxyMigrationFailed = M3UParser.proxyMigrationFailed
                            refreshCachedProxyPasswordFlags()
                        }
                        .onChange(of: httpProxy) { newValue in
                            // Round-11 fix (A01): emptying the field
                            // prunes the last recorded identity's entry
                            // but used to leave cachedHasAnyProxyPassword
                            // stale (true), so the clear-all button and
                            // its caption lingered until the field was
                            // left and re-entered. Refresh here too, the
                            // one node the round-10 list missed.
                            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                M3UParser.pruneStoredProxyPassword()
                                refreshCachedProxyPasswordFlags()
                            }
                        }
                        // Round-7 fix (A03): the failure flag used to
                        // sync only on appear/disappear, so a migration
                        // failure during a background refresh while the
                        // settings page was open stayed invisible until
                        // the field was left and re-entered. The fetch
                        // path posts on every flag change; listen here.
                        .onReceive(NotificationCenter.default.publisher(for: M3UParser.proxyMigrationFailedChanged)) { _ in
                            proxyMigrationFailed = M3UParser.proxyMigrationFailed
                        }
                        // Round-10 fix (A02/10-D03, merged): a
                        // background refresh can store a proxy password
                        // while this page is open, which used to leave
                        // cachedHasAnyProxyPassword stale (false) until
                        // the field was left and re-entered — hiding the
                        // clear-all button for a password that was
                        // already stored. Refresh on every successful
                        // migration write.
                        // Round-11 fix (A03): that notification used to
                        // fire on every background migration success
                        // while the field still held its inline password,
                        // and every one triggered a Keychain enumeration
                        // via refreshCachedProxyPasswordFlags — a new
                        // repeated cost created by stacking round-10's
                        // notification on round-10's retain-the-field
                        // behavior. Skip the refresh when it cannot
                        // change anything: the identity is unchanged
                        // since the last refresh and both flags are
                        // already true (a write can only turn flags
                        // false -> true, never the reverse). Any other
                        // case still refreshes: a false hasAny flag may
                        // have just become true, a changed identity may
                        // carry a different current-identity flag, and a
                        // false current flag may have just gained its
                        // entry.
                        .onReceive(NotificationCenter.default.publisher(for: M3UParser.proxyPasswordStoredChanged)) { _ in
                            if currentProxyFlagIdentity() == lastProxyFlagRefreshIdentity, cachedHasAnyProxyPassword, cachedCurrentProxyPasswordExists {
                                // No flag can change; skip the enumeration.
                            } else {
                                refreshCachedProxyPasswordFlags()
                            }
                        }
                        .onDisappear {
                            // Round-9 fix (A02): clear the editing flag
                            // BEFORE migrating — leaving the field is
                            // the confirmed identity-change path, so the
                            // migrate below may now delete a superseded
                            // previous identity (which it must not do
                            // while the field is still open).
                            M3UParser.proxyFieldOpen = false
                            let hadInlinePassword = M3UParser.parseProxy(httpProxy)?.password != nil
                            M3UParser.migrateStoredProxyPassword()
                            if !hadInlinePassword { M3UParser.pruneStoredProxyPassword() }
                            proxyMigrationFailed = M3UParser.proxyMigrationFailed
                            refreshCachedProxyPasswordFlags()
                        }
                    Text(state.localized("仅用于 M3U/EPG 请求（格式 host:port、http://host:port 或 user:pass@host:port；带认证的代理会把用户名密码发给代理服务器，密码会迁移到钥匙串中；迁移失败时仍以明文保存在本地并显示警告），KSPlayer 不读取此设置。")).font(.caption).foregroundStyle(.secondary)
                    // Round-3 fix (B07): an invalid proxy used to fail
                    // silently into a direct connection (and a missing or
                    // bad port silently became 8080). Show the problem
                    // here instead of letting the user believe the proxy
                    // is in effect.
                    // Round-5 fix (A05): the warning used to name only
                    // "host:port" even though the caption and the parser
                    // also accept http(s):// and user:pass@ forms, so a
                    // user whose http:// value failed for another reason
                    // (e.g. an out-of-range port) got a misleading hint.
                    if !httpProxy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, M3UParser.parseProxy(httpProxy) == nil {
                        Text(state.localized("代理格式无效，将直连。请使用 host:port、http://host:port 或 user:pass@host:port 格式。")).font(.caption).foregroundStyle(.red)
                    }
                    // Round-6 fix (A02): a failed Keychain migration used
                    // to fall back to the plain-text stored password with
                    // no indication at all. Surface it here (the flag is
                    // synced on appear/disappear above, and the fetch path
                    // sets it too on its next migration attempt).
                    // Round-12 fix (A01): scope the warning to the
                    // identity that actually failed, matching
                    // proxyAuthWarning — a stale flag from a previous
                    // identity must not fire against the identity now
                    // in the field, which round-11 deferred saving
                    // never attempted to write.
                    if proxyMigrationFailed, let parsed = M3UParser.parseProxy(httpProxy), parsed.password != nil,
                       M3UParser.proxyMigrationFailedIdentity == nil || M3UParser.proxyMigrationFailedIdentity == M3UParser.canonicalProxy(host: parsed.host, port: parsed.port, username: parsed.username) {
                        Text(state.localized("代理密码未能存入钥匙串，仍以明文保存在本地。请重新输入代理密码。")).font(.caption).foregroundStyle(.red)
                    }
                    // Round-6 fix (C01): a username with no password
                    // anywhere (neither inline nor in the Keychain for
                    // this exact proxy identity) used to send requests
                    // unauthenticated with no warning — the other half of
                    // the round-5 "password without username" fix. A
                    // username that looks authenticated must never
                    // silently go out without credentials.
                    if let parsed = M3UParser.parseProxy(httpProxy), let proxyUser = parsed.username, !proxyUser.isEmpty, parsed.password == nil,
                       !cachedCurrentProxyPasswordExists {
                        Text(state.localized("代理已填写用户名但未提供密码，请求将以无认证方式发出。请补全密码或清除用户名。")).font(.caption).foregroundStyle(.red)
                    }
                    // Round-6 fix (A01): the explicit delete path. Before
                    // this, a stored proxy password could never be removed:
                    // clearing the field only pruned when the field was
                    // left entirely empty, and a migrated field
                    // ("user@host:port") is indistinguishable from a field
                    // whose password the user deliberately removed. This
                    // button deletes the Keychain entry for the current
                    // proxy identity, so removing authentication is a
                    // deliberate, visible action instead of a silent
                    // resurrection on the next request.
                    if let parsed = M3UParser.parseProxy(httpProxy), let proxyUser = parsed.username, !proxyUser.isEmpty,
                       cachedCurrentProxyPasswordExists {
                        Button(state.localized("清除已存代理密码")) {
                            KeychainStore.deleteProxyPassword(forProxy: M3UParser.canonicalProxy(host: parsed.host, port: parsed.port, username: proxyUser))
                            // Round-7 fix (A01): deleting the Keychain
                            // entry alone did not invalidate the cached
                            // URLSession, whose key is the stripped field
                            // value (unchanged by this tap) — so the next
                            // request reused a session built with the
                            // deleted password until restart. Invalidate
                            // it here, matching migration/prune.
                            M3UParser.invalidateCachedSession()
                            // Round-7 fix (A02): this tap changes no
                            // @State/@Published value, so the body (whose
                            // button/warning visibility reads live from
                            // the Keychain) would not re-evaluate and the
                            // button appeared to do nothing. Bump a
                            // counter to force a re-render.
                            proxyPasswordClearedCount += 1
                            refreshCachedProxyPasswordFlags()
                        }.buttonStyle(.bordered).tint(state.accent)
                    }
                    // Round-8 fix (C02): rotation deletes only ever
                    // removed the last-recorded identity, so passwords
                    // orphaned during the round-5/6 rotation era could
                    // never be cleaned up — switching back to an old
                    // identity silently resurrected them. Offer a sweep
                    // over every stored proxy identity. It appears only
                    // when at least one proxy password is stored, and
                    // it deletes Keychain entries only: an inline
                    // password still in the field will migrate into
                    // the Keychain when the field is left (departure
                    // confirmation), by design — not on the next fetch
                    // while the field is still open (round-12 A02).
                    if cachedHasAnyProxyPassword {
                        Button(state.localized("清除全部已存代理密码")) {
                            KeychainStore.deleteAllProxyPasswords()
                            UserDefaults.standard.removeObject(forKey: "httpProxyLastIdentity")
                            M3UParser.invalidateCachedSession()
                            proxyPasswordClearedCount += 1
                            refreshCachedProxyPasswordFlags()
                        }.buttonStyle(.bordered).tint(state.accent)
                        // Round-9 fix (A01): clear-all deletes Keychain
                        // entries only — a password still typed in the
                        // field above is NOT touched by the button and
                        // will migrate into the Keychain when the field
                        // is left (departure confirmation; round-12
                        // A02 corrected the old "on the next fetch"
                        // wording, which no longer holds while the
                        // field is open), silently undoing the clear
                        // from the user's point of view. Stripping the
                        // field here would risk destroying the only
                        // copy when a previous migration failed, so say
                        // so instead: the scope is "stored passwords",
                        // not "the field's current password".
                        // Round-13 fix (C01): the old wording promised
                        // a re-save unconditionally, but a stripped
                        // field (user@host:port, password already in
                        // the Keychain) holds no password to re-save —
                        // the caption now says so conditionally.
                        Text(state.localized("清除全部仅删除已存入钥匙串的密码，若字段中仍带有密码，离场确认时仍会重新存入。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                SettingsSection(title: state.localized("缓冲区"), icon: "memorychip") {
                    HStack { Text(state.localized("网络缓存大小")).font(.system(size: 18)); Spacer(); Text("\(Int(state.networkBufferMilliseconds)) ms").font(.system(size: 18, design: .monospaced)).foregroundStyle(state.accent) }
                    Slider(value: Binding(get: { state.networkBufferMilliseconds }, set: { state.setBuffer($0) }), in: 500...10000, step: 250).tint(state.accent)
                    Text(state.localized("网络连接较慢或不稳定时，可增加缓存")).font(.caption).foregroundStyle(.secondary)
                }
                SettingsSection(title: state.localized("数据与缓存"), icon: "externaldrive") {
                    ActionRow(title: state.localized("清除图片缓存"), icon: "trash") { state.clearImageCache() }
                    ActionRow(title: state.localized("清除播放历史"), icon: "clock.badge.xmark") { showClearHistoryConfirm = true }
                    ActionRow(title: state.localized("清除收藏"), icon: "star.slash") { showClearFavoritesConfirm = true }
                    if let notice = state.currentNotice { Text(notice).font(.caption).foregroundStyle(state.accent) }
                }
                .alert(state.localized("清除播放历史"), isPresented: $showClearHistoryConfirm) {
                    Button(state.localized("清除"), role: .destructive) { state.clearHistory() }
                    Button(state.localized("关闭"), role: .cancel) {}
                } message: { Text(state.localized("确定清除全部播放历史吗？该操作无法撤销。")) }
                .alert(state.localized("清除收藏"), isPresented: $showClearFavoritesConfirm) {
                    Button(state.localized("清除"), role: .destructive) { state.clearFavorites() }
                    Button(state.localized("关闭"), role: .cancel) {}
                } message: { Text(state.localized("确定清除全部收藏吗？该操作无法撤销。")) }
                SettingsSection(title: state.localized("EPG节目单"), icon: "list.bullet.rectangle.portrait") {
                    LabeledField(title: state.localized("EPG地址"), text: Binding(get: { state.epgDraftURL }, set: { state.setEPGURL($0) }), placeholder: "https://example.com/guide.xml")
                    HStack(spacing: 10) {
                        // "保存" and "更新" previously did exactly the same
                        // thing; only one button remains.
                        Button(state.localized("保存节目单")) { state.saveEPGSource() }
                            .buttonStyle(.borderedProminent).tint(state.accent)
                            .disabled(state.epgDraftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isLoadingEPG)
                    }
                    HStack(spacing: 10) {
                        Button(state.localized("刷新节目单")) { state.reloadEPG() }
                            .buttonStyle(.bordered).tint(state.accent)
                            .disabled(state.epgURL.isEmpty || state.isLoadingEPG)
                        Button(state.localized("删除节目单"), role: .destructive) { showDeleteEPGConfirm = true }
                            .buttonStyle(.bordered)
                            .disabled(state.epgURL.isEmpty)
                            .alert(state.localized("删除节目单"), isPresented: $showDeleteEPGConfirm) {
                                Button(state.localized("删除"), role: .destructive) { state.deleteEPGSource() }
                                Button(state.localized("关闭"), role: .cancel) {}
                                // Round-3 fix (B10): the old message said
                                // only "the source" would be deleted, while
                                // deleteEPGSource also drops the draft, the
                                // cached guide, the timestamp and the
                                // refresh interval. The message now says so.
                            } message: { Text(state.localized("确定删除已保存的节目单来源、草稿、缓存指南、更新时间与自动刷新间隔吗？该操作无法撤销。")) }
                        if state.isLoadingEPG { ProgressView().tint(state.accent) }
                    }.padding(.top, 4)
                    SettingsPickerRow(title: state.localized("自动刷新"), value: Binding(get: {
                        switch state.epgRefreshIntervalMinutes { case 15: return "15分钟"; case 30: return "30分钟"; case 60: return "60分钟"; case 360: return "6小时"; default: return "关闭自动刷新" }
                    }, set: { value in
                        let minutes: Int
                        switch value { case "15分钟": minutes = 15; case "30分钟": minutes = 30; case "60分钟": minutes = 60; case "6小时": minutes = 360; default: minutes = 0 }
                        state.setEPGRefreshInterval(minutes)
                    }), options: ["关闭自动刷新", "15分钟", "30分钟", "60分钟", "6小时"])
                    Text(state.localized("仅在 App 前台运行时刷新节目单。")).font(.caption).foregroundStyle(.secondary)
                    if let updated = state.epgLastUpdated, !state.epgGuide.programsByChannelID.isEmpty {
                        Text("\(state.localized("节目单已更新。"))  (updated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(state.accent)
                    }
                    if let epgError = state.epgError { Text(epgError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(.top, 4) }
                }
                Text(state.localized("NanoStream 是一个媒体播放器外壳。请仅添加您有权观看的播放列表和视频流。")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading).padding(.horizontal, 22).padding(.bottom, 120)
            }
        }
    }
}

struct SettingsSection<Content: View>: View {
    @EnvironmentObject private var state: AppState
    let title: String; let icon: String; @ViewBuilder let content: Content
    var body: some View { VStack(alignment: .leading, spacing: 0) { Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 14); content }.padding(18).background(Color.card, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(state.accent.opacity(0.42), lineWidth: 1)).padding(.horizontal, 22) }
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
                Text(state.localizedValue(value)).foregroundStyle(state.accent)
                Image(systemName: "chevron.up.chevron.down").foregroundStyle(state.accent)
            }.buttonStyle(.plain)
        }.padding(.vertical, 11).overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) }
    }
}
struct ToggleRow: View { @EnvironmentObject private var state: AppState; let title: String; @Binding var value: Bool; var body: some View { HStack { Text(title).font(.system(size: 18)); Spacer(); Toggle("", isOn: $value).labelsHidden().tint(state.accent) }.padding(.vertical, 8).overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) } } }
struct LabeledField: View { let title: String; @Binding var text: String; var placeholder = ""; var body: some View { VStack(alignment: .leading, spacing: 7) { Text(title).font(.subheadline).foregroundStyle(.secondary); TextField(placeholder.isEmpty ? title : placeholder, text: $text).textFieldStyle(.plain).padding(12).background(Color.cardInner, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.12))) } .padding(.vertical, 5) } }
struct ActionRow: View { @EnvironmentObject private var state: AppState; let title: String; let icon: String; let action: () -> Void; var body: some View { Button(action: action) { HStack { Image(systemName: icon).foregroundStyle(state.accent); Text(title).font(.system(size: 18)).foregroundStyle(state.accent); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }.padding(.vertical, 11).overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) } }.buttonStyle(.plain) } }

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
    @State private var pendingLocalText: String?
    @State private var pendingLocalName: String?
    /// Directory of the staged local file, so relative stream/logo URLs
    /// in it can be resolved instead of silently dropped (round-3 C04).
    @State private var pendingLocalBaseURL: URL?

    init(editingPlaylist: Playlist? = nil) {
        self.editingPlaylist = editingPlaylist
        let source: String
        switch editingPlaylist?.kind {
        case .xtream: source = "Xtream"
        case .tvHeadend: source = "tvHeadend"
        case .m3u: source = editingPlaylist?.isLocalFile == true ? "本地文件" : "M3U 链接"
        case .none: source = "M3U 链接"
        }
        _source = State(initialValue: source)
        _name = State(initialValue: editingPlaylist?.name ?? "")
        _url = State(initialValue: editingPlaylist?.isLocalFile == true ? "" : editingPlaylist?.endpoint ?? "")
        _username = State(initialValue: editingPlaylist?.username ?? "")
        // Passwords are never prefilled from storage: an empty field on edit
        // means "keep the existing password" (see AppState.updatePlaylist).
        _password = State(initialValue: "")
    }

    private var kindForSource: PlaylistKind {
        switch source { case "Xtream": return .xtream; case "tvHeadend": return .tvHeadend; default: return .m3u }
    }

    private var formTitle: String {
        if editingPlaylist == nil { return state.localized("添加列表") }
        if source == "本地文件" { return state.localized("保存") }
        return state.localized("保存并刷新")
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
                        .foregroundStyle(state.accent)
                    SourcePicker(source: $source, chooseFile: { showFileImporter = true })
                    Text(state.localized("详细信息"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(state.accent)
                    TextField(state.localized("输入列表名称"), text: $name)
                        .fieldStyle()
                    if source == "Xtream" {
                        TextField(state.localized("服务器地址 (http://...)"), text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().fieldStyle()
                        TextField(state.localized("用户名"), text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().fieldStyle()
                        SecureField(state.localized("密码"), text: $password).fieldStyle()
                        if editingPlaylist != nil { Text(state.localized("留空表示保持原密码")).font(.caption).foregroundStyle(.secondary) }
                    } else if source == "tvHeadend" {
                        TextField(state.localized("服务器地址 (http://...)"), text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().fieldStyle()
                        TextField(state.localized("用户名"), text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().fieldStyle()
                        SecureField(state.localized("密码"), text: $password).fieldStyle()
                        if editingPlaylist != nil { Text(state.localized("留空表示保持原密码")).font(.caption).foregroundStyle(.secondary) }
                    } else if source == "M3U 链接" {
                        TextField(state.localized("服务器地址 (http://...)"), text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().fieldStyle()
                    } else {
                        Button { showFileImporter = true } label: { Label(pendingLocalName ?? (url.isEmpty ? state.localized("选择本地 M3U 文件") : url), systemImage: "doc.badge.plus").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).fieldStyle()
                    }
                    if let editingPlaylist, kindForSource != editingPlaylist.kind {
                        Text(state.localized("更改播放列表类型后，原地址将按新类型解析。")).font(.caption).foregroundStyle(.red)
                    }
                    if source != "本地文件" || editingPlaylist != nil {
                        AddPlaylistButton(name: name, source: source, url: source == "本地文件" ? (pendingLocalName ?? "local-file") : url, username: username, password: password, isSaving: isSaving, isEditing: editingPlaylist != nil, hasStoredPassword: editingPlaylist.map { !state.password(for: $0).isEmpty } ?? false, isEditingLocal: editingPlaylist?.isLocalFile ?? false, localFileSelected: pendingLocalText != nil, title: formTitle) {
                            isSaving = true
                            errorText = nil
                            if let editingPlaylist {
                                if source == "本地文件", let text = pendingLocalText {
                                    state.updateLocalPlaylist(editingPlaylist, name: name, text: text, baseURL: pendingLocalBaseURL) { success in
                                        isSaving = false
                                        if success { dismiss() } else { if let err = state.playlistError { errorText = err } }
                                    }
                                } else {
                                    // Endpoint is derived from the current source
                                    // at tap time, never from a stale captured
                                    // value (previously a file name could be
                                    // saved as a remote URL).
                                    let endpoint = source == "本地文件" ? Playlist.localFileEndpoint : url.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let updated = Playlist(id: editingPlaylist.id, name: name, kind: kindForSource, endpoint: endpoint, username: kindForSource == .m3u ? "" : username, password: password, channelCount: editingPlaylist.channelCount, lastRefresh: editingPlaylist.lastRefresh)
                                    state.updatePlaylist(updated) { success in
                                        isSaving = false
                                        if success { dismiss() } else { if let err = state.playlistError { errorText = err } }
                                    }
                                }
                            } else {
                                state.addPlaylist(name: name, kind: kindForSource, endpoint: url.trimmingCharacters(in: .whitespacesAndNewlines), username: username, password: password) { success in
                                    isSaving = false
                                    if success { dismiss() } else { if let err = state.playlistError { errorText = err } }
                                }
                            }
                        }
                    }
                    if let errorText { Text(errorText).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    if let notice = state.currentNotice { Text(notice).font(.caption).foregroundStyle(state.accent) }
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
            switch result {
            case .failure(let error):
                // Round-2 fix: the old code treated every picker failure as
                // a cancel and stayed silent. Only a genuine user cancel is
                // silent; a real picker failure now shows an error.
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError { break }
                errorText = state.localized("选择文件失败。")
            case .success(let urls):
                guard let fileURL = urls.first else { errorText = state.localized("选择文件失败。"); return }
                guard fileURL.startAccessingSecurityScopedResource() else { errorText = state.localized("选择文件失败。"); return }
                defer { fileURL.stopAccessingSecurityScopedResource() }
                guard let data = try? Data(contentsOf: fileURL) else { errorText = state.localized("文件读取失败。"); return }
                // Round-2 fix: local files go through the same decode chain
                // as network playlists (UTF-8, then GB18030, then ISO-Latin-1).
                // Previously a GBK file was decoded as ISO-Latin-1 garbage.
                guard let text = M3UParser.decodePlaylist(data: data) else { errorText = state.localized("文件编码不受支持，请使用 UTF-8 文本。"); return }
                let displayName = fileURL.deletingPathExtension().lastPathComponent
                if editingPlaylist != nil {
                    // Editing a local playlist: stage the new content for the
                    // Save button instead of creating a duplicate playlist.
                    pendingLocalText = text
                    pendingLocalName = displayName
                    pendingLocalBaseURL = fileURL.deletingLastPathComponent()
                    source = "本地文件"
                    if name.isEmpty { name = displayName }
                } else {
                    // Round-2 fix: dismiss only after the import actually
                    // commits. The old code dismissed immediately, before
                    // parsing finished, so a failed import left the user on
                    // the playlist page with no visible error.
                    state.addPlaylistFromText(name: name.isEmpty ? displayName : name, text: text, baseURL: fileURL.deletingLastPathComponent()) { success in
                        if success { dismiss() } else if let err = state.playlistError { errorText = err }
                    }
                }
            }
        }
    }
}

struct SourcePicker: View {
    @EnvironmentObject private var state: AppState
    @Binding var source: String
    let chooseFile: () -> Void
    private let options = ["本地文件", "M3U 链接", "Xtream", "tvHeadend"]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.self) { item in
                Button {
                    // Switch the source first, then open the picker: cancelling
                    // no longer leaves the highlight on the previous source.
                    source = item
                    if item == "本地文件" { chooseFile() }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: icon(for: item)).font(.title2)
                        // Round-3 mitigation (B17, still unverified on
                        // device): long translations (e.g. Vietnamese)
                        // shrink instead of wrapping into the fixed 82pt
                        // cell; whether any label still clips needs a
                        // real-device screenshot to confirm.
                        Text(displayName(for: item)).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 82)
                    .foregroundStyle(source == item ? state.accent : .secondary)
                    .background(source == item ? state.accent.opacity(0.15) : Color.panel, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(source == item ? state.accent : .white.opacity(0.12), lineWidth: 1))
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
    @EnvironmentObject private var state: AppState
    let name: String
    let source: String
    let url: String
    let username: String
    let password: String
    let isSaving: Bool
    // Round-2 fix: on edit, a blank password means "keep the stored one"
    // (see AppState.updatePlaylist), so the save button must not demand a
    // freshly typed password. On create, Xtream still requires both fields.
    let isEditing: Bool
    // Round-3 fix (B12): isEditing alone used to allow a blank password
    // even when no password is stored at all (type change to Xtream, or a
    // deleted stored password), so the button looked valid and the load
    // failed later with an empty-credentials error. Blank is only valid
    // when a stored password actually exists.
    let hasStoredPassword: Bool
    // Round-3 fix (B15): editing a remote playlist to "local file" with
    // no file chosen used to save anyway and wipe the remote address and
    // credential with no confirmation. Such an edit is only valid when
    // the playlist is already local (rename) or a file was just chosen.
    let isEditingLocal: Bool
    let localFileSelected: Bool
    let title: String
    let action: () -> Void

    // Compile-fix round: CI reported the line-508 call as having
    // extra arguments (#7/#8/#9/#10/#12) and missing `action`, even
    // though the call matches the memberwise initializer parameter
    // for parameter. An explicit initializer with exactly the call's
    // signature removes any synthesis ambiguity; a future mismatch
    // will then surface as a plain type error instead of a
    // misleading extra/missing-argument diagnostic. Defaults match
    // the previous memberwise defaults, and line 508 is the only
    // call site, so no other construction is affected.
    init(name: String, source: String, url: String, username: String, password: String, isSaving: Bool, isEditing: Bool = false, hasStoredPassword: Bool = false, isEditingLocal: Bool = false, localFileSelected: Bool = false, title: String, action: @escaping () -> Void) {
        self.name = name
        self.source = source
        self.url = url
        self.username = username
        self.password = password
        self.isSaving = isSaving
        self.isEditing = isEditing
        self.hasStoredPassword = hasStoredPassword
        self.isEditingLocal = isEditingLocal
        self.localFileSelected = localFileSelected
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(!isValid || isSaving ? Color.panel : state.accent)
                if isSaving { ProgressView().tint(.white) }
                else { Text(title).font(.headline).foregroundStyle(!isValid ? .secondary : Color.appBackground) }
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

    /// Real validation, not just non-empty: http/https + host for remote
    /// sources, and username+password for Xtream. tvHeadend credentials are
    /// optional (Basic Auth is only sent when supplied).
    private var isValid: Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if source == "本地文件" { return !isEditing || isEditingLocal || localFileSelected }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else { return false }
        if source == "Xtream" { return !username.isEmpty && (!password.isEmpty || (isEditing && hasStoredPassword)) }
        return true
    }
}
private extension View { func fieldStyle() -> some View { self.textFieldStyle(.plain).padding(16).background(Color.cardInner, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.14))) } }
