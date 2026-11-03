import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

enum EPGLoadError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case invalidFormat
    case empty
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "节目单地址无效。"
        case .httpStatus(let status): return "节目单服务器返回 HTTP \(status)。"
        case .invalidFormat: return "返回内容不是有效的 XMLTV 节目单。"
        case .empty: return "节目单中没有找到有效节目。"
        case .tooLarge: return "节目单过大，超过 32MB 上限。"
        }
    }
}

enum EPGService {
    static func fetch(endpoint: String) async throws -> EPGGuide {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw EPGLoadError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.cachePolicy = .reloadRevalidatingCacheData
        var lastError: Error?
        var fetched: Data?
        for attempt in 0..<2 {
            do {
                // Round-3 fix (C23): size-capped streaming fetch — the old
                // data(for:) path downloaded the whole guide before the
                // 32MB check, so a 100MB guide peaked at 100MB in memory.
                // The status check now also happens before any body byte.
                let (data, _) = try await M3UParser.fetchData(for: request, tooLargeError: EPGLoadError.tooLarge, statusError: { EPGLoadError.httpStatus($0) })
                fetched = data
                break
            } catch {
                lastError = error
                if attempt == 0, (error as? URLError) != nil { try? await Task.sleep(nanoseconds: 500_000_000); continue }
                throw error
            }
        }
        guard let data = fetched else { throw lastError ?? EPGLoadError.invalidFormat }
        let guide = try XMLTVParser.parse(data: data)
        guard !guide.programsByChannelID.isEmpty else { throw EPGLoadError.empty }
        return guide
    }
}

enum XMLTVParser {
    static func parse(data: Data) throws -> EPGGuide {
        let delegate = XMLTVParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        guard parser.parse() else { throw parser.parserError ?? EPGLoadError.invalidFormat }
        guard delegate.didSeeTVRoot else { throw EPGLoadError.invalidFormat }
        return delegate.guide
    }
}

private final class XMLTVParserDelegate: NSObject, XMLParserDelegate {
    private struct PendingProgram {
        var channelID: String
        var start: Date
        var end: Date
        var title = ""
        var subtitle: String?
        var programDescription: String?
    }

    private var programsByChannelID: [String: [EPGProgram]] = [:]
    // One name can belong to several XML channels (e.g. HD/SD variants):
    // keep all of them instead of letting the last one silently win.
    private var channelIDsByNormalizedName: [String: [String]] = [:]
    // Round-6 fix (C03): raw display names per channel id, persisted on
    // the guide so the decoder can rebuild the name map under the current
    // locale (folding is locale-sensitive). Without them, a cache written
    // under another locale silently lost name matching.
    private var channelDisplayNames: [String: [String]] = [:]
    private var currentChannelID: String?
    private var pendingProgram: PendingProgram?
    // Element stack: nested markup inside <title> used to clear the outer
    // text buffer on every end tag, losing the first half of the title.
    private var elementStack: [String] = []
    private var textStack: [String] = []
    private var isFirstElement = true
    fileprivate var didSeeTVRoot = false
    // Reused formatters: previously one DateFormatter was built per programme.
    private let formatters: [DateFormatter] = {
        ["yyyyMMddHHmmss", "yyyyMMddHHmm", "yyyyMMddHH"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: "gregorian")
            formatter.dateFormat = format
            return formatter
        }
    }()

    fileprivate var guide: EPGGuide {
        var sorted = programsByChannelID.mapValues { $0.sorted { $0.start < $1.start } }
        // Fill open-ended programmes from the next programme's start.
        for (channelID, programs) in sorted {
            var fixed = programs
            for index in fixed.indices where fixed[index].end <= fixed[index].start {
                if index + 1 < fixed.count {
                    fixed[index].end = fixed[index + 1].start
                }
            }
            if var last = fixed.last, last.end <= last.start {
                last.end = last.start.addingTimeInterval(3600)
                fixed[fixed.count - 1] = last
            }
            // Round-3 fix (C28): when the next programme starts at the
            // same instant (duplicate/overlapping entries), the fill
            // above still leaves end == start, and the overlap truncation
            // below (end > next.start) never touches it. Drop zero-length
            // programmes instead of showing a programme stuck at 0%.
            fixed = fixed.filter { $0.end > $0.start }
            sorted[channelID] = fixed
        }
        // Truncate overlaps: a programme never runs past the next one's start.
        for (channelID, programs) in sorted {
            var fixed = programs
            for index in fixed.indices.dropLast() where fixed[index].end > fixed[index + 1].start {
                fixed[index].end = fixed[index + 1].start
            }
            // Round-4 fix (C06): truncating two same-start programmes
            // sets the first one's end equal to its start, recreating a
            // zero-length programme AFTER the earlier zero-length filter.
            // Filter again here, after truncation (the round-3 verify
            // note's "filter after truncation" order was aspirational,
            // not what the code did).
            fixed = fixed.filter { $0.end > $0.start }
            sorted[channelID] = fixed
        }
        // Round-4 fix (C09): precompute the normalized-id map so
        // programs(for:) does a lookup instead of scanning all guide keys.
        var idsByNormalizedID: [String: [String]] = [:]
        for id in sorted.keys {
            idsByNormalizedID[EPGGuide.normalizedID(id), default: []].append(id)
        }
        return EPGGuide(programsByChannelID: sorted, channelIDsByNormalizedName: channelIDsByNormalizedName, channelIDsByNormalizedID: idsByNormalizedID, channelDisplayNames: channelDisplayNames)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let element = elementName.lowercased()
        if isFirstElement {
            // The root element itself must be <tv>; a <tv> nested anywhere
            // else previously passed the root check.
            didSeeTVRoot = (element == "tv")
            isFirstElement = false
        }
        elementStack.append(element)
        textStack.append("")
        switch element {
        case "channel":
            currentChannelID = attributeDict["id"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        case "programme":
            guard let channelID = attributeDict["channel"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                  let start = Self.xmlTVDate(attributeDict["start"], formatters: formatters) else {
                pendingProgram = nil
                return
            }
            // Missing stop is not a drop: end is a marker (== start) that
            // the guide builder replaces with the next programme's start.
            let end = Self.xmlTVDate(attributeDict["stop"], formatters: formatters) ?? start
            pendingProgram = PendingProgram(channelID: channelID, start: start, end: end)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !textStack.isEmpty else { return }
        textStack[textStack.count - 1] += string
    }

    // Round-3 fix (C21): titles/descriptions wrapped in CDATA (common
    // for Chinese XMLTV sources) used to vanish entirely, because only
    // foundCharacters was implemented. CDATA appends to the same buffer.
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !textStack.isEmpty else { return }
        if let string = String(data: CDATABlock, encoding: .utf8) {
            textStack[textStack.count - 1] += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = elementName.lowercased()
        let rawText = textStack.popLast() ?? ""
        _ = elementStack.popLast()
        let value = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Append this element's text to its parent's buffer so nested markup
        // inside <title>/<desc> does not lose the outer text.
        if !textStack.isEmpty, !value.isEmpty {
            textStack[textStack.count - 1] += value
        }
        switch element {
        case "display-name":
            if let channelID = currentChannelID, !value.isEmpty {
                let key = Self.normalized(value)
                if !(channelIDsByNormalizedName[key]?.contains(channelID) ?? false) {
                    channelIDsByNormalizedName[key, default: []].append(channelID)
                }
                if !(channelDisplayNames[channelID]?.contains(value) ?? false) {
                    channelDisplayNames[channelID, default: []].append(value)
                }
            }
        case "channel":
            currentChannelID = nil
        case "title":
            if pendingProgram != nil, !value.isEmpty { pendingProgram?.title = value }
        case "sub-title":
            if pendingProgram != nil { pendingProgram?.subtitle = value.isEmpty ? nil : value }
        case "desc":
            if pendingProgram != nil { pendingProgram?.programDescription = value.isEmpty ? nil : value }
        case "programme":
            if let pending = pendingProgram, !pending.title.isEmpty || pending.programDescription != nil {
                // Programmes with a description but no title are shown with
                // the description as their title instead of being dropped.
                let program = EPGProgram(
                    channelID: pending.channelID,
                    title: pending.title.isEmpty ? (pending.programDescription ?? "") : pending.title,
                    subtitle: pending.subtitle,
                    programDescription: pending.programDescription,
                    start: pending.start,
                    end: pending.end
                )
                programsByChannelID[pending.channelID, default: []].append(program)
            }
            pendingProgram = nil
        default:
            break
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func xmlTVDate(_ raw: String?, formatters: [DateFormatter]) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        // Split off a trailing zone in any common spelling: "+0800",
        // "+08:00", "Z", "UTC", "GMT" — including when it is glued to the
        // timestamp with no space ("20261025200000+0800").
        var timestamp = raw
        var zoneText: String?
        let zoneSuffixes = ["Z", "UTC", "GMT"]
        for suffix in zoneSuffixes where timestamp.uppercased().hasSuffix(suffix) && timestamp.count > suffix.count {
            zoneText = suffix
            timestamp = String(timestamp.dropLast(suffix.count))
            break
        }
        if zoneText == nil {
            // Trailing ±HHMM or ±HH:MM at the end of the token.
            let pattern = "([+-]\\d{2}:?\\d{2})$"
            if let range = timestamp.range(of: pattern, options: .regularExpression) {
                zoneText = String(timestamp[range])
                timestamp = String(timestamp[..<range.lowerBound])
            }
        }
        if zoneText == nil {
            let parts = timestamp.split(whereSeparator: \.isWhitespace)
            if parts.count > 1 {
                timestamp = String(parts[0])
                zoneText = String(parts[1])
            }
        }
        let value = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        // Missing zone: XMLTV times are UTC by convention. Previously the
        // device time zone was silently substituted, shifting every programme
        // when the source and the device disagreed.
        let timeZone = zoneText.flatMap { timeZone(from: $0) } ?? TimeZone(secondsFromGMT: 0)
        for formatter in formatters {
            formatter.timeZone = timeZone
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func timeZone(from value: String) -> TimeZone? {
        let upper = value.uppercased()
        if upper == "Z" || upper == "UTC" || upper == "GMT" { return TimeZone(secondsFromGMT: 0) }
        let sign = value.hasPrefix("-") ? -1 : 1
        let digits = value.trimmingCharacters(in: CharacterSet(charactersIn: "+-:"))
        guard digits.count == 4,
              let hours = Int(digits.prefix(2)), hours <= 23,
              let minutes = Int(digits.suffix(2)), minutes <= 59 else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
