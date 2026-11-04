import SwiftUI

// Dev round 10 (D-01/D-07): the lab page. Every switch here is
// wired to real behaviour (see LabServices and the detail page);
// nothing on this page is a stored-but-unwired placeholder. The
// header and captions are written in this app's own words: the
// reference screenshots were used only to decide WHICH five
// experiments exist, never as copy to paste.
// Live-subtitle engine settings live here too because live captions
// are lab-grade: they lag, they skip segments, and they only work
// on streams with an audio track.

/// A key field: reads the stored key (if any) on appear, writes it
/// to the Keychain on commit, never to UserDefaults. The field
/// shows dots, never the key itself, and "清除" deletes it.
struct SecretKeyField: View {
    @EnvironmentObject private var state: AppState
    let title: String
    let account: String
    @State private var text = ""
    @State private var hasStoredKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            SecureField(title, text: $text)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Color.cardInner, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.12)))
            HStack(spacing: 12) {
                Button(state.localized("保存密钥")) {
                    KeychainStore.saveSecret(text, forAccount: account)
                    hasStoredKey = !text.isEmpty
                }.buttonStyle(.bordered).tint(state.accent)
                if hasStoredKey {
                    Button(state.localized("清除密钥")) {
                        KeychainStore.deleteSecret(forAccount: account)
                        text = ""
                        hasStoredKey = false
                    }.buttonStyle(.bordered).tint(.red)
                }
                if hasStoredKey {
                    Text(state.localized("已保存")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 5)
        .onAppear {
            let stored = KeychainStore.readSecret(forAccount: account) ?? ""
            hasStoredKey = !stored.isEmpty
            // Never prefill the actual key into the field: the dots
            // only say "a key exists". Typing a new value replaces it.
            text = ""
        }
    }
}

struct LabView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(state.localized("这里是还没做完的实验功能，可能不稳定、可能播不出、可能更耗电。开之前想清楚，出了问题关掉就能回到原来的播放方式。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 18).padding(.top, 12)
                    labToggle(
                        title: state.localized("组播快速启动"),
                        value: Binding(get: { state.labMulticastFCC }, set: { state.setLabMulticastFCC($0) }),
                        caption: state.localized("只对组播地址起作用：缩短探测和初始缓冲，让组播频道起播更快。完整的运营商级快速换台需要服务端配合，没有服务端时这个开关只做播放器一侧的加速。")
                    )
                    labToggle(
                        title: state.localized("多码率起播预选"),
                        value: Binding(get: { state.labHLSVariantPreselect }, set: { state.setLabHLSVariantPreselect($0) }),
                        caption: state.localized("多码率直播起播前先选定一档直接播，不用等播放器把全部码率都探一遍。只在自动和 KSPlayer 下生效；个别源预选后播不出来时，关掉就回到原来的播法。")
                    )
                    labToggle(
                        title: state.localized("回看地址替换"),
                        value: Binding(get: { state.labReplayPLTVToTVOD }, set: { state.setLabReplayPLTVToTVOD($0) }),
                        caption: state.localized("回看播放前，把回看地址里的 PLTV 路径段换成 TVOD。只动回看地址，不动直播地址；回看源本来就不需要替换时，保持关闭。")
                    )
                    labToggle(
                        title: state.localized("增强系统播放器"),
                        value: Binding(get: { state.labEnhancedSystemPlayer }, set: { state.setLabEnhancedSystemPlayer($0) }),
                        caption: state.localized("系统播放器遇到播不出的频道时，会换一条兼容路径再试一次，试过还不行才显示失败。下次播放生效；和自动切换 KSPlayer 是两回事。")
                    )
                    labToggle(
                        title: state.localized("Metal 渲染"),
                        value: Binding(get: { state.labMetalRendering }, set: { state.setLabMetalRendering($0) }),
                        // Compile-fix round 2 (M-01): the switch is
                        // real now — on selects KSPlayer's Metal
                        // backend (KSMEPlayer), off keeps the
                        // AVFoundation backend (KSAVPlayer). It only
                        // affects the KS playback path; the pure
                        // system-player path has no app-level Metal
                        // switch and is unaffected. Toggling rebuilds
                        // the player with the new backend.
                        caption: state.localized("开：KS 播放改走 Metal 渲染后端；关：保持 AVFoundation 后端。只影响 KS 播放路径，纯系统播放器路径不受影响；切换后播放器会重建并改用新后端。")
                    )
                    VStack(alignment: .leading, spacing: 10) {
                        Text(state.localized("实时字幕")).font(.headline)
                        Text(state.localized("实验功能：识别会比画面慢，也可能漏段；只有带音频轨的流才能识别，没有音频轨的源会明确提示不支持，绝不会用麦克风冒充流内音频。默认关闭。"))
                            .font(.caption).foregroundStyle(.secondary)
                        ToggleRow(title: state.localized("实时字幕"), value: Binding(get: { state.liveSubtitleEnabled }, set: { state.setLiveSubtitleEnabled($0) }))
                        SettingsPickerRow(
                            title: state.localized("识别来源"),
                            value: Binding(
                                get: { state.liveSubtitleEngine.rawValue },
                                set: { if let engine = LiveSubtitleEngine(rawValue: $0) { state.setLiveSubtitleEngine(engine) } }
                            ),
                            options: LiveSubtitleEngine.allCases.map(\.rawValue)
                        )
                        LabeledField(title: state.localized("转录接口地址"), text: Binding(get: { state.liveSubAPIBaseURL }, set: { state.setLiveSubAPIBaseURL($0) }))
                        SecretKeyField(title: state.localized("转录密钥"), account: KeychainStore.liveSubAPIKeyAccount)
                        LabeledField(title: state.localized("AI 转录接口地址"), text: Binding(get: { state.liveSubAIBaseURL }, set: { state.setLiveSubAIBaseURL($0) }))
                        LabeledField(title: state.localized("AI 转录模型"), text: Binding(get: { state.liveSubAIModel }, set: { state.setLiveSubAIModel($0) }))
                        SecretKeyField(title: state.localized("AI 转录密钥"), account: KeychainStore.liveSubAIKeyAccount)
                        Text(state.localized("接口地址为空时对应档位不可用；识别失败时不显示任何文字，绝不编造字幕。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 18)
                }.padding(.bottom, 40)
            }
            .navigationTitle(state.localized("实验室"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(state.localized("完成")) { dismiss() }
                }
            }
        }
    }

    private func labToggle(title: String, value: Binding<Bool>, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ToggleRow(title: title, value: value)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
    }
}

// MARK: - Subtitle overlays (detail page player stack)

/// Translated subtitle overlay (D-02): shows the cue covering the
/// current playhead, translated through the selected source. While
/// a cue is untranslated, the original shows with an "untranslated"
/// mark; with no subtitle track, nothing renders at all.
struct TranslatedSubtitleOverlay: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = TranslatedSubtitleModel()
    @AppStorage("subtitleFontSize") private var subtitleFontSize: Double = 18
    let masterURL: URL
    let position: Double

    var body: some View {
        Group {
            if let text = model.displayText {
                Text(text + (model.isUntranslated ? " " + state.localized("（未译出）") : ""))
                    .font(.system(size: subtitleFontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .onAppear { model.load(masterURL: masterURL) }
        // Compile-fix round 1 (items 49-54): the zero-parameter
        // closure resolves to the iOS 17-only onChange(of:initial:_:)
        // overload; an explicit single parameter pins the iOS 14+
        // overload, so the iOS 16 deployment target still builds.
        .onChange(of: masterURL) { _ in model.reset(); model.load(masterURL: masterURL) }
        .onChange(of: position) { _ in
            model.update(position: position, engine: state.translationEngine, target: state.translationTargetCode, apiBaseURL: state.translateAPIBaseURL, aiBaseURL: state.translateAIBaseURL, aiModel: state.translateAIModel, enabled: state.subtitleTranslationEnabled)
        }
        .onDisappear { model.reset() }
    }
}

/// Live subtitle overlay (D-07): shows the latest recognised text
/// for a few seconds, or an explicit notice when the stream has no
/// audio track / the engine is unusable. Never shows text that was
/// not recognised from a real segment.
struct LiveSubtitleOverlay: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = LiveSubtitleModel()
    @AppStorage("subtitleFontSize") private var subtitleFontSize: Double = 18
    let masterURL: URL

    var body: some View {
        Group {
            if let text = model.currentText {
                Text(text)
                    .font(.system(size: subtitleFontSize, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            } else if model.unsupported {
                Text(state.localized("该源不支持实时字幕"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.engineUnavailable {
                Text(state.localized("实时字幕识别当前不可用"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            model.start(masterURL: masterURL, engine: state.liveSubtitleEngine, apiBaseURL: state.liveSubAPIBaseURL, aiBaseURL: state.liveSubAIBaseURL, aiModel: state.liveSubAIModel)
        }
        .onChange(of: state.liveSubtitleEngine) { _ in
            model.start(masterURL: masterURL, engine: state.liveSubtitleEngine, apiBaseURL: state.liveSubAPIBaseURL, aiBaseURL: state.liveSubAIBaseURL, aiModel: state.liveSubAIModel)
        }
        .onDisappear { model.stop() }
    }
}

/// Listen-translation overlay (dev round 19, T-02): recognised
/// audio translated through the shared translation service and
/// shown as a caption bar. This is NOT dubbing — the original
/// audio is never replaced. A failed translation keeps the
/// original with an untranslated mark; no recognised text means
/// no caption at all. The detail page renders this INSTEAD of the
/// raw live-subtitle overlay when listen mode is active, never
/// stacked on top of it.
struct ListenTranslatedSubtitleOverlay: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var model = ListenTranslatedSubtitleModel()
    @AppStorage("subtitleFontSize") private var subtitleFontSize: Double = 18
    let masterURL: URL

    private func restart() {
        model.start(
            masterURL: masterURL,
            recognitionEngine: state.liveSubtitleEngine,
            recognitionAPIBaseURL: state.liveSubAPIBaseURL,
            recognitionAIBaseURL: state.liveSubAIBaseURL,
            recognitionAIModel: state.liveSubAIModel,
            translationEngine: state.translationEngine,
            translationTarget: state.translationTargetCode,
            translateAPIBaseURL: state.translateAPIBaseURL,
            translateAIBaseURL: state.translateAIBaseURL,
            translateAIModel: state.translateAIModel
        )
    }

    var body: some View {
        Group {
            if let text = model.displayText {
                Text(text + (model.isUntranslated ? " " + state.localized("（未译出）") : ""))
                    .font(.system(size: subtitleFontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            } else if model.unsupported {
                Text(state.localized("该源不支持听翻"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.engineUnavailable {
                Text(state.localized("听翻识别当前不可用"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { restart() }
        .onChange(of: masterURL) { _ in model.stop(); restart() }
        .onChange(of: state.liveSubtitleEngine) { _ in restart() }
        .onChange(of: state.translationEngine) { _ in restart() }
        .onDisappear { model.stop() }
    }
}
