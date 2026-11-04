import Foundation
import SwiftUI
#if canImport(Speech)
import Speech
#endif
#if canImport(Translation)
import Translation
#endif

// Dev round 10 (D-02/D-07): subtitle translation and live-subtitle
// recognition. Nothing here ever fabricates text: no subtitle track
// means no subtitle UI, a failed translation shows the original with
// an "untranslated" mark, and a failed recognition shows nothing.

// MARK: - Engines

enum TranslationEngine: String, CaseIterable {
    case system
    case api
    case ai
}

// Dev round 19 (T-01): translation mode choice. "subtitle" keeps
// the existing behaviour (translate the subtitle track's cues);
// "listen" translates recognised audio instead (see
// ListenTranslatedSubtitleModel). The mode only changes the
// translation input source, never the three translation sources
// or the target-language rule.
enum TranslationMode: String, CaseIterable {
    case subtitle
    case listen
}

enum LiveSubtitleEngine: String, CaseIterable {
    case system
    case api
    case ai
}

enum SubtitleServiceError: Error {
    case endpointNotConfigured
    case systemUnavailable
    case requestFailed
    case badResponse
}

// MARK: - WebVTT

struct SubtitleCue: Identifiable {
    var id: String { "\(start)-\(text)" }
    var start: Double
    var end: Double
    var text: String
}

/// Minimal WebVTT parser: cue headers "HH:MM:SS.mmm -->
/// HH:MM:SS.mmm" followed by one or more text lines up to a blank
/// line. NOTE/REGION/STYLE blocks are skipped. Unparsable input
/// yields no cues, never guessed ones.
enum WebVTTParser {
    static func parse(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var currentStart: Double?
        var currentEnd: Double?
        var currentLines: [String] = []
        func flush() {
            if let start = currentStart, let end = currentEnd, !currentLines.isEmpty {
                cues.append(SubtitleCue(start: start, end: end, text: currentLines.joined(separator: " ")))
            }
            currentStart = nil; currentEnd = nil; currentLines = []
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("WEBVTT") || line.hasPrefix("NOTE") || line.hasPrefix("REGION") || line.hasPrefix("STYLE") { continue }
            if line.contains("-->") {
                flush()
                let parts = line.components(separatedBy: "-->")
                if parts.count == 2,
                   let start = parseTimestamp(parts[0]),
                   let end = parseTimestamp(parts[1]) {
                    currentStart = start; currentEnd = end
                }
                continue
            }
            if currentStart != nil { currentLines.append(line) }
        }
        flush()
        return cues
    }

    static func parseTimestamp(_ raw: String) -> Double? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces).first ?? ""
        let parts = cleaned.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secondsPart = parts.last ?? ""
        let secBits = secondsPart.split(separator: ".")
        guard let seconds = Double(secBits[0]) else { return nil }
        let fraction = secBits.count > 1 ? Double("0." + secBits[1]) ?? 0 : 0
        if parts.count == 3 {
            guard let hours = Double(parts[0]), let minutes = Double(parts[1]) else { return nil }
            return hours * 3600 + minutes * 60 + seconds + fraction
        }
        guard let minutes = Double(parts[0]) else { return nil }
        return minutes * 60 + seconds + fraction
    }
}

// MARK: - HLS subtitle / audio track loading

struct SubtitleTrack {
    var name: String
    var language: String
    var url: URL
}

enum HLSMediaLoader {
    /// Fetches a playlist text through the proxy/UA-configured
    /// session. Any failure returns nil; callers treat nil as "no
    /// track", never as an error to paper over.
    static func fetchText(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (bytes, _) = try await M3UParser.configuredSession().bytes(for: request)
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Parses #EXT-X-MEDIA lines of a master playlist for the given
    /// TYPE (SUBTITLES or AUDIO). Relative URIs resolve against the
    /// master URL; entries without a URI are dropped.
    static func mediaTracks(of masterURL: URL, type: String) async -> [SubtitleTrack] {
        guard let text = await fetchText(masterURL) else { return [] }
        var result: [SubtitleTrack] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-MEDIA:") else { continue }
            let attrs = parseAttributes(line)
            guard attrs["TYPE"] == type, let uri = attrs["URI"], !uri.isEmpty,
                  let resolved = URL(string: uri, relativeTo: masterURL)?.absoluteURL else { continue }
            result.append(SubtitleTrack(
                name: attrs["NAME"] ?? resolved.lastPathComponent,
                language: attrs["LANGUAGE"] ?? "",
                url: resolved
            ))
        }
        return result
    }

    /// Loads every cue of a subtitle media playlist. Segment start
    /// offsets accumulate from #EXTINF durations, so cues carry
    /// playlist-relative times. Capped at 200 segments to bound work
    /// on long VOD playlists; beyond that the tail simply has no
    /// translated subtitles (never fabricated).
    static func cues(of trackURL: URL) async -> [SubtitleCue] {
        guard let text = await fetchText(trackURL) else { return [] }
        var segments: [(duration: Double, url: URL)] = []
        var pendingDuration: Double?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                pendingDuration = Double(value) ?? 0
                continue
            }
            if !line.isEmpty, !line.hasPrefix("#"), let duration = pendingDuration {
                if let resolved = URL(string: line, relativeTo: trackURL)?.absoluteURL {
                    segments.append((duration: duration, url: resolved))
                }
                pendingDuration = nil
                if segments.count >= 200 { break }
            }
        }
        var cues: [SubtitleCue] = []
        var offset = 0.0
        for segment in segments {
            if let segmentText = await fetchText(segment.url) {
                for cue in WebVTTParser.parse(segmentText) {
                    cues.append(SubtitleCue(start: cue.start + offset, end: cue.end + offset, text: cue.text))
                }
            }
            offset += segment.duration
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// Raw bytes of a segment URL (audio segments for recognition).
    /// Nil on any failure; callers skip failed segments silently.
    static func fetchData(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        do {
            let (bytes, _) = try await M3UParser.configuredSession().bytes(for: request)
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            return data
        } catch {
            return nil
        }
    }

    /// Audio segment URLs of an audio media playlist (newest last).
    /// Used by live-subtitle recognition; the caller decides how many
    /// of the newest segments to feed the recognizer.
    static func audioSegments(of trackURL: URL) async -> [(duration: Double, url: URL)] {
        guard let text = await fetchText(trackURL) else { return [] }
        var segments: [(duration: Double, url: URL)] = []
        var pendingDuration: Double?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                pendingDuration = Double(value) ?? 0
                continue
            }
            if !line.isEmpty, !line.hasPrefix("#"), let duration = pendingDuration {
                if let resolved = URL(string: line, relativeTo: trackURL)?.absoluteURL {
                    segments.append((duration: duration, url: resolved))
                }
                pendingDuration = nil
            }
        }
        return segments
    }

    /// Parses comma-separated KEY=VALUE pairs where values may be
    /// double-quoted (the #EXT-X-MEDIA form).
    static func parseAttributes(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        let body = line.dropFirst("#EXT-X-MEDIA:".count)
        var current = ""
        var inQuotes = false
        var parts: [String] = []
        for char in body {
            if char == "\"" { inQuotes.toggle(); current.append(char); continue }
            if char == "," && !inQuotes { parts.append(current); current = ""; continue }
            current.append(char)
        }
        parts.append(current)
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces)
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            result[key] = value
        }
        return result
    }
}

// MARK: - Translation

/// Dev round 10 (D-02): three translation sources for subtitle text.
/// - system: the OS translation capability (iOS 18 Translation API,
///   availability-gated; unavailable -> .systemUnavailable, and the
///   UI then shows the original with an "untranslated" mark).
/// - api: a generic translation endpoint. POST {baseURL} with JSON
///   {"text": ..., "target": ...} and an Authorization: Bearer key
///   when one is stored. Response JSON {"translatedText": ...}
///   (fallbacks: "translation", "translated_text"). The base URL is
///   the full endpoint URL the user configures; empty means the
///   source is unusable (.endpointNotConfigured), never a silent
///   fallback to another source.
/// - ai: an OpenAI-compatible /chat/completions endpoint. POST
///   {baseURL}/chat/completions (a base URL already ending in
///   /chat/completions is used as-is) with {"model": ...,
///   "messages": [{"role": "system", "content": prompt},
///   {"role": "user", "content": text}], "temperature": 0}.
///   The system prompt is: "You are a subtitle translator.
///   Translate the following subtitle text to <target language
///   code>. Reply with only the translation, no explanation."
///   The first choice's message content is the translation.
enum TranslationService {
    static func translate(
        _ text: String,
        target: String,
        engine: TranslationEngine,
        apiBaseURL: String,
        aiBaseURL: String,
        aiModel: String
    ) async throws -> String {
        switch engine {
        case .system:
            return try await translateViaSystem(text, target: target)
        case .api:
            let base = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty, let url = URL(string: base) else { throw SubtitleServiceError.endpointNotConfigured }
            return try await translateViaAPI(text, target: target, url: url, key: KeychainStore.readSecret(forAccount: KeychainStore.translateAPIKeyAccount))
        case .ai:
            let base = aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else { throw SubtitleServiceError.endpointNotConfigured }
            let model = aiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpt-4o-mini" : aiModel
            return try await translateViaAI(text, target: target, baseURL: base, model: model, key: KeychainStore.readSecret(forAccount: KeychainStore.translateAIKeyAccount))
        }
    }

    // CI-verification item (same precedent as KSOptions spellings):
    // the Translation framework's programmatic session API shape
    // (TranslationSession.Configuration + translate(_:).targetText)
    // is written from the iOS 18 Translation API surface and cannot
    // be verified without Xcode; if CI rejects it, fix the session
    // construction here first.
    private static func translateViaSystem(_ text: String, target: String) async throws -> String {
        // Dev round 10 (D-02/D-03): the iOS-only gate would not
        // satisfy the macOS target (Translation needs macOS 15+);
        // list both platforms so the macOS build stays valid.
        guard #available(iOS 18.0, macOS 15.0, *) else { throw SubtitleServiceError.systemUnavailable }
        #if canImport(Translation)
        do {
            let configuration = TranslationSession.Configuration(
                source: nil,
                target: Locale.Language(identifier: target)
            )
            let session = TranslationSession(configuration: configuration)
            let response = try await session.translate(text)
            return response.targetText
        } catch {
            throw SubtitleServiceError.systemUnavailable
        }
        #else
        throw SubtitleServiceError.systemUnavailable
        #endif
    }

    private static func translateViaAPI(_ text: String, target: String, url: URL, key: String?) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "target": target])
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { throw SubtitleServiceError.requestFailed }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SubtitleServiceError.badResponse }
        if let value = json["translatedText"] as? String, !value.isEmpty { return value }
        if let value = json["translation"] as? String, !value.isEmpty { return value }
        if let value = json["translated_text"] as? String, !value.isEmpty { return value }
        throw SubtitleServiceError.badResponse
    }

    private static func translateViaAI(_ text: String, target: String, baseURL: String, model: String, key: String?) async throws -> String {
        let endpoint = baseURL.hasSuffix("/chat/completions") ? baseURL : baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"
        guard let url = URL(string: endpoint) else { throw SubtitleServiceError.endpointNotConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let prompt = "You are a subtitle translator. Translate the following subtitle text to \(target). Reply with only the translation, no explanation."
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": text],
            ],
        ])
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { throw SubtitleServiceError.requestFailed }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SubtitleServiceError.badResponse }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Translated subtitle view model

/// Loads an HLS subtitle track's cues and translates them on demand
/// near the playhead. Translation results cache per cue id, so the
/// same cue is never requested twice. A failed translation keeps the
/// original text and marks it untranslated; it never invents text.
@MainActor
final class TranslatedSubtitleModel: ObservableObject {
    @Published private(set) var displayText: String?
    @Published private(set) var isUntranslated = false
    @Published private(set) var hasTrack = false

    private var cues: [SubtitleCue] = []
    private var cache: [String: String] = [:]
    private var translating: Set<String> = []
    private var loadTask: Task<Void, Never>?

    func load(masterURL: URL) {
        loadTask?.cancel()
        loadTask = Task {
            let tracks = await HLSMediaLoader.mediaTracks(of: masterURL, type: "SUBTITLES")
            guard let first = tracks.first else { return }
            let loaded = await HLSMediaLoader.cues(of: first.url)
            guard !Task.isCancelled, !loaded.isEmpty else { return }
            self.cues = loaded
            self.hasTrack = true
        }
    }

    func update(position: Double, engine: TranslationEngine, target: String, apiBaseURL: String, aiBaseURL: String, aiModel: String, enabled: Bool) {
        guard enabled, hasTrack else { displayText = nil; isUntranslated = false; return }
        guard let cue = cues.first(where: { position >= $0.start && position < $0.end }) else { displayText = nil; isUntranslated = false; return }
        if let translated = cache[cue.id] {
            displayText = translated; isUntranslated = false
            return
        }
        displayText = cue.text; isUntranslated = true
        guard !translating.contains(cue.id) else { return }
        translating.insert(cue.id)
        Task {
            do {
                let translated = try await TranslationService.translate(cue.text, target: target, engine: engine, apiBaseURL: apiBaseURL, aiBaseURL: aiBaseURL, aiModel: aiModel)
                self.cache[cue.id] = translated
                if self.cues.first(where: { $0.id == cue.id }) != nil { self.displayText = translated; self.isUntranslated = false }
            } catch {
                // Original text stays on screen with the
                // untranslated mark; no fallback source is tried
                // silently, and no text is invented.
            }
            self.translating.remove(cue.id)
        }
    }

    func reset() {
        loadTask?.cancel()
        cues = []
        cache = [:]
        translating = []
        displayText = nil
        isUntranslated = false
        hasTrack = false
    }
}

// MARK: - Listen translation (recognise -> translate -> caption)

// Dev round 19 (T-02/T-03): listen translation. This is NOT dubbing:
// no TTS ever replaces the original audio. It reuses the
// live-subtitle recognition pipeline (audio segments -> recognised
// text, same three recognition lines, same authorization chain,
// same no-audio-track unsupported rule) and then runs each
// recognised segment through the shared TranslationService — the
// same three translation sources and the same AI base URL / key /
// model settings as subtitle translation (T-03), never a second
// set of stored settings. The translated text shows as a caption
// bar; a failed translation keeps the original with an
// untranslated mark; no recognised text means no caption at all.
// Segment dedup and the 15-second hide rule mirror
// LiveSubtitleModel. Recognition + translation delays stack, so
// listen captions lag the picture more than raw live captions;
// that lag is experimental and can only be judged on a real device.
@MainActor
final class ListenTranslatedSubtitleModel: ObservableObject {
    @Published private(set) var displayText: String?
    @Published private(set) var isUntranslated = false
    @Published private(set) var unsupported = false
    @Published private(set) var engineUnavailable = false

    private var pollTask: Task<Void, Never>?
    private var seenSegments: Set<String> = []
    private var lastTextDate: Date?

    func start(
        masterURL: URL,
        recognitionEngine: LiveSubtitleEngine,
        recognitionAPIBaseURL: String,
        recognitionAIBaseURL: String,
        recognitionAIModel: String,
        translationEngine: TranslationEngine,
        translationTarget: String,
        translateAPIBaseURL: String,
        translateAIBaseURL: String,
        translateAIModel: String
    ) {
        stop()
        // Recognition-engine gates mirror LiveSubtitleModel.start():
        // an unconfigured endpoint engine is unusable up front, and
        // the system line requests authorization before polling.
        if recognitionEngine == .api && recognitionAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { engineUnavailable = true; return }
        if recognitionEngine == .ai && recognitionAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { engineUnavailable = true; return }
        pollTask = Task {
            if recognitionEngine == .system {
                guard await LiveSubtitleRecognizer.ensureSystemAuthorization(),
                      LiveSubtitleRecognizer.systemAvailable() else {
                    if !Task.isCancelled { self.engineUnavailable = true }
                    return
                }
            }
            await self.runPollLoop(
                masterURL: masterURL,
                recognitionEngine: recognitionEngine,
                recognitionAPIBaseURL: recognitionAPIBaseURL,
                recognitionAIBaseURL: recognitionAIBaseURL,
                recognitionAIModel: recognitionAIModel,
                translationEngine: translationEngine,
                translationTarget: translationTarget,
                translateAPIBaseURL: translateAPIBaseURL,
                translateAIBaseURL: translateAIBaseURL,
                translateAIModel: translateAIModel
            )
        }
    }

    private func runPollLoop(
        masterURL: URL,
        recognitionEngine: LiveSubtitleEngine,
        recognitionAPIBaseURL: String,
        recognitionAIBaseURL: String,
        recognitionAIModel: String,
        translationEngine: TranslationEngine,
        translationTarget: String,
        translateAPIBaseURL: String,
        translateAIBaseURL: String,
        translateAIModel: String
    ) async {
        let tracks = await HLSMediaLoader.mediaTracks(of: masterURL, type: "AUDIO")
        guard let first = tracks.first else {
            self.unsupported = true
            return
        }
        while !Task.isCancelled {
            let segments = await HLSMediaLoader.audioSegments(of: first.url)
            let fresh = segments.suffix(3).filter { !seenSegments.contains($0.url.absoluteString) }
            for segment in fresh {
                seenSegments.insert(segment.url.absoluteString)
                guard let data = await HLSMediaLoader.fetchData(segment.url) else { continue }
                guard let recognised = await LiveSubtitleRecognizer.recognize(segmentData: data, engine: recognitionEngine, apiBaseURL: recognitionAPIBaseURL, aiBaseURL: recognitionAIBaseURL, aiModel: recognitionAIModel) else { continue }
                // A failed translation keeps the original with the
                // untranslated mark, the same convention as
                // TranslatedSubtitleModel; no source is silently
                // retried and no text is invented. An empty AI base
                // URL throws endpointNotConfigured here, so the AI
                // source is visibly unusable rather than silently
                // falling back.
                var text = recognised
                var untranslated = false
                do {
                    text = try await TranslationService.translate(recognised, target: translationTarget, engine: translationEngine, apiBaseURL: translateAPIBaseURL, aiBaseURL: translateAIBaseURL, aiModel: translateAIModel)
                } catch {
                    untranslated = true
                }
                if !Task.isCancelled {
                    self.displayText = text
                    self.isUntranslated = untranslated
                    self.lastTextDate = Date()
                }
            }
            if let last = lastTextDate, Date().timeIntervalSince(last) > 15 {
                self.displayText = nil
                self.isUntranslated = false
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        seenSegments = []
        displayText = nil
        isUntranslated = false
        unsupported = false
        engineUnavailable = false
        lastTextDate = nil
    }
}

// MARK: - Live subtitle recognition

/// Dev round 10 (D-07): three recognition lines for HLS audio
/// segments. All three are experimental: segment boundaries and
/// recognition delay mean live captions lag the picture and may
/// skip segments; the overlay never shows text that was not
/// recognised from an actual segment.
/// - system: on-device Speech recognition (SFSpeechRecognizer) over
///   a downloaded segment file. Segment files are usually MPEG-TS,
///   which the recognizer may refuse; a refusal yields no text,
///   never a fallback sentence.
/// - api: a generic speech-to-text endpoint. POST {baseURL} with
///   JSON {"audio": <base64>, "format": "ts"} and an Authorization:
///   Bearer key when stored. Response {"text": ...} (fallback
///   "transcript").
/// - ai: an OpenAI-compatible /audio/transcriptions endpoint. POST
///   {baseURL}/audio/transcriptions as multipart/form-data with
///   fields file (the segment, filename "segment.ts") and model.
///   Response {"text": ...}. A base URL already ending in
///   /audio/transcriptions is used as-is.
enum LiveSubtitleRecognizer {
    /// Whether the on-device recognizer can run at all: a recognizer
    /// instance exists, is available, and is not denied/restricted.
    /// This is the post-authorization gate: LiveSubtitleModel.start()
    /// requests authorization first (dev round 12, R12-02), so by the
    /// time this runs an undetermined status has already been
    /// resolved; denied/restricted does not pass.
    static func systemAvailable() -> Bool {
        #if canImport(Speech)
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return false }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized, .notDetermined: return true
        default: return false
        }
        #else
        return false
        #endif
    }

    /// Dev round 12 (R12-02): request speech-recognition authorization
    /// before the first system-line recognition. Previously no code
    /// called requestAuthorization at all, so the system line silently
    /// produced nothing on a real device. Returns false when denied
    /// or restricted, so the caller can show engineUnavailable instead
    /// of an empty caption area.
    static func ensureSystemAuthorization() async -> Bool {
        #if canImport(Speech)
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default: return false
        }
        #else
        return false
        #endif
    }

    static func recognize(
        segmentData: Data,
        engine: LiveSubtitleEngine,
        apiBaseURL: String,
        aiBaseURL: String,
        aiModel: String
    ) async -> String? {
        switch engine {
        case .system:
            return await recognizeViaSystem(segmentData)
        case .api:
            let base = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty, let url = URL(string: base) else { return nil }
            return await recognizeViaAPI(segmentData, url: url, key: KeychainStore.readSecret(forAccount: KeychainStore.liveSubAPIKeyAccount))
        case .ai:
            let base = aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else { return nil }
            let model = aiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "whisper-1" : aiModel
            return await recognizeViaAI(segmentData, baseURL: base, model: model, key: KeychainStore.readSecret(forAccount: KeychainStore.liveSubAIKeyAccount))
        }
    }

    private static func recognizeViaSystem(_ data: Data) async -> String? {
        #if canImport(Speech)
        // Dev round 10 (D-03/D-07): the iOS-only gate silently
        // disabled system recognition on macOS. The Speech APIs
        // used here date to iOS 10 / macOS 10.15, so keep the iOS
        // 17 floor from the original implementation and add the
        // macOS floor instead of leaving macOS gated out.
        guard #available(iOS 17.0, macOS 10.15, *) else { return nil }
        do {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("nano-livesub-\(UUID().uuidString).ts")
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return nil }
            let request = SFSpeechURLRecognitionRequest(url: tempURL)
            request.shouldReportPartialResults = false
            return try await withCheckedThrowingContinuation { continuation in
                recognizer.recognitionTask(with: request) { result, error in
                    if let text = result?.bestTranscription.formattedString, result?.isFinal == true, !text.isEmpty {
                        continuation.resume(returning: text)
                    } else if error != nil {
                        continuation.resume(returning: nil)
                    } else if result?.isFinal == true {
                        continuation.resume(returning: nil)
                    }
                }
            }
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    private static func recognizeViaAPI(_ data: Data, url: URL, key: String?) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["audio": data.base64EncodedString(), "format": "ts"])
        request.timeoutInterval = 30
        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 0 < 400,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else { return nil }
        if let text = json["text"] as? String, !text.isEmpty { return text }
        if let text = json["transcript"] as? String, !text.isEmpty { return text }
        return nil
    }

    private static func recognizeViaAI(_ data: Data, baseURL: String, model: String, key: String?) async -> String? {
        let endpoint = baseURL.hasSuffix("/audio/transcriptions") ? baseURL : baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/audio/transcriptions"
        guard let url = URL(string: endpoint) else { return nil }
        let boundary = "nano-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"segment.ts\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: video/mp2t\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        request.timeoutInterval = 60
        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 0 < 400,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let text = json["text"] as? String, !text.isEmpty else { return nil }
        return text
    }
}

/// Background engine for live subtitles: polls the audio media
/// playlist, downloads unseen segments (newest 3 per poll), feeds
/// each once to the recognizer, and publishes the latest recognised
/// text. The overlay shows the text for 15 seconds after it
/// arrives, then hides it; a segment with no recognised text shows
/// nothing. The microphone is NEVER used: only segments from the
/// stream's own audio track feed recognition, and a stream without
/// an audio track reports "unsupported" instead of faking captions.
@MainActor
final class LiveSubtitleModel: ObservableObject {
    @Published private(set) var currentText: String?
    @Published private(set) var unsupported = false
    /// Set when the chosen engine itself is unusable (system
    /// recognizer missing/unavailable/denied, or an API/AI endpoint
    /// left unconfigured), so the UI can say so instead of showing
    /// a permanently empty caption area.
    @Published private(set) var engineUnavailable = false

    private var pollTask: Task<Void, Never>?
    private var seenSegments: Set<String> = []
    private var lastTextDate: Date?

    func start(masterURL: URL, engine: LiveSubtitleEngine, apiBaseURL: String, aiBaseURL: String, aiModel: String) {
        stop()
        // Endpoint engines with no configured base URL are unusable
        // up front; the system engine is checked for recognizer
        // availability and authorization before polling starts.
        if engine == .api && apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { engineUnavailable = true; return }
        if engine == .ai && aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { engineUnavailable = true; return }
        pollTask = Task {
            // Dev round 12 (R12-02): the system line requests
            // authorization before polling; denied/restricted sets
            // engineUnavailable so the UI says so instead of showing
            // a permanently empty caption area. The cancellation check
            // keeps a late prompt answer from reviving a stopped model.
            if engine == .system {
                guard await LiveSubtitleRecognizer.ensureSystemAuthorization(),
                      LiveSubtitleRecognizer.systemAvailable() else {
                    if !Task.isCancelled { self.engineUnavailable = true }
                    return
                }
            }
            await self.runPollLoop(masterURL: masterURL, engine: engine, apiBaseURL: apiBaseURL, aiBaseURL: aiBaseURL, aiModel: aiModel)
        }
    }

    // Dev round 12 (R12-02): polling loop extracted from start() so
    // the system line can request authorization first, then poll.
    private func runPollLoop(masterURL: URL, engine: LiveSubtitleEngine, apiBaseURL: String, aiBaseURL: String, aiModel: String) async {
        let tracks = await HLSMediaLoader.mediaTracks(of: masterURL, type: "AUDIO")
        guard let first = tracks.first else {
            self.unsupported = true
            return
        }
        while !Task.isCancelled {
            let segments = await HLSMediaLoader.audioSegments(of: first.url)
            let fresh = segments.suffix(3).filter { !seenSegments.contains($0.url.absoluteString) }
            for segment in fresh {
                seenSegments.insert(segment.url.absoluteString)
                guard let data = await HLSMediaLoader.fetchData(segment.url) else { continue }
                if let text = await LiveSubtitleRecognizer.recognize(segmentData: data, engine: engine, apiBaseURL: apiBaseURL, aiBaseURL: aiBaseURL, aiModel: aiModel) {
                    self.currentText = text
                    self.lastTextDate = Date()
                }
            }
            if let last = lastTextDate, Date().timeIntervalSince(last) > 15 {
                self.currentText = nil
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        seenSegments = []
        currentText = nil
        unsupported = false
        engineUnavailable = false
        lastTextDate = nil
    }
}
