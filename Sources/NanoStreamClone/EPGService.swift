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

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "节目单地址无效。"
        case .httpStatus(let status): return "节目单服务器返回 HTTP \(status)。"
        case .invalidFormat: return "返回内容不是有效的 XMLTV 节目单。"
        case .empty: return "节目单中没有找到有效节目。"
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
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: EPGLoadError.invalidFormat)
                }
            }.resume()
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw EPGLoadError.httpStatus(http.statusCode)
        }
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
    private var channelIDByNormalizedName: [String: String] = [:]
    private var currentChannelID: String?
    private var pendingProgram: PendingProgram?
    private var currentElement = ""
    private var textBuffer = ""
    fileprivate var didSeeTVRoot = false

    fileprivate var guide: EPGGuide {
        let sorted = programsByChannelID.mapValues { $0.sorted { $0.start < $1.start } }
        return EPGGuide(programsByChannelID: sorted, channelIDByNormalizedName: channelIDByNormalizedName)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        textBuffer = ""
        switch currentElement {
        case "tv":
            didSeeTVRoot = true
        case "channel":
            currentChannelID = attributeDict["id"]?.trimmedNonEmpty
        case "programme":
            guard let channelID = attributeDict["channel"]?.trimmedNonEmpty,
                  let start = Self.xmlTVDate(attributeDict["start"]),
                  let end = Self.xmlTVDate(attributeDict["stop"]), end > start else {
                pendingProgram = nil
                return
            }
            pendingProgram = PendingProgram(channelID: channelID, start: start, end: end)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = elementName.lowercased()
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "display-name":
            if let channelID = currentChannelID, !value.isEmpty {
                channelIDByNormalizedName[Self.normalized(value)] = channelID
            }
        case "channel":
            currentChannelID = nil
        case "title":
            if pendingProgram != nil, !value.isEmpty { pendingProgram?.title = value }
        case "sub-title":
            if pendingProgram != nil { pendingProgram?.subtitle = value.trimmedNonEmpty }
        case "desc":
            if pendingProgram != nil { pendingProgram?.programDescription = value.trimmedNonEmpty }
        case "programme":
            if let pending = pendingProgram, !pending.title.isEmpty {
                let program = EPGProgram(
                    channelID: pending.channelID,
                    title: pending.title,
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
        textBuffer = ""
        currentElement = ""
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func xmlTVDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let parts = raw.split(whereSeparator: \.isWhitespace)
        guard let timestamp = parts.first else { return nil }
        let value = String(timestamp)
        let formats = ["yyyyMMddHHmmss", "yyyyMMddHHmm", "yyyyMMddHH"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        if parts.count > 1 {
            let zone = String(parts[1])
            formatter.timeZone = Self.timeZone(from: zone) ?? .current
        } else {
            formatter.timeZone = .current
        }
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func timeZone(from value: String) -> TimeZone? {
        if value.uppercased() == "Z" { return TimeZone(secondsFromGMT: 0) }
        let sign = value.hasPrefix("-") ? -1 : 1
        let digits = value.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        guard digits.count == 4,
              let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.suffix(2)) else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
