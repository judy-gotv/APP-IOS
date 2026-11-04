import Foundation

// Dev round 10 (D-01): lab-experiment helpers. Every switch on the
// lab page routes through one of these, so a switch that only stores
// a value cannot pass review: the behaviour change lives here.

enum LabServices {
    /// Whether a URL is a multicast source (udp / rtp group address).
    /// Only these get the fast-start path; ordinary http(s) streams
    /// never take it, so the switch cannot change their behaviour.
    static func isMulticast(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "udp" || scheme == "rtp" || scheme == "multicast"
    }

    /// Player-side fast start for multicast sources. This only
    /// shortens probe time and the initial buffer on the player side.
    /// A complete operator-side FCC (fast channel change) needs
    /// server cooperation (unicast burst at tune-in); without a
    /// cooperating server this switch does NOT provide server FCC,
    /// and the lab caption says exactly that.
    static func effectiveBufferMilliseconds(base: Double, url: URL, fastStartEnabled: Bool) -> Double {
        guard fastStartEnabled, isMulticast(url) else { return base }
        return min(base, 800)
    }

    /// Catchup-only PLTV -> TVOD path rewrite. Only the path segment
    /// exactly equal to "PLTV" is replaced, and only for catchup
    /// URLs: live URLs never pass through here (the detail page
    /// applies this inside playProgram only).
    static func applyReplayTransform(_ url: URL, enabled: Bool) -> URL {
        guard enabled else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard var parts = components?.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init) else { return url }
        var changed = false
        for index in parts.indices where parts[index] == "PLTV" {
            parts[index] = "TVOD"
            changed = true
        }
        guard changed else { return url }
        components?.path = "/" + parts.joined(separator: "/")
        return components?.url ?? url
    }
}

/// Dev round 10 (D-01): multi-bitrate HLS start-up preselection.
/// When enabled, a master playlist is fetched and parsed before
/// playback; the player then starts from one chosen variant URL
/// instead of the master, so FFmpeg never probes every rendition.
/// Disabled (or a non-multi-variant master, or any fetch/parse
/// failure) returns nil and the caller plays the master unchanged —
/// preselection never fabricates a URL and never blocks playback.
enum HLSPreselector {
    struct Variant {
        var bandwidth: Int
        var url: URL
    }

    /// Fetches and parses a master playlist through the same
    /// proxy/UA-configured session as playlist fetching. Returns the
    /// variants in playlist order, or [] when the playlist is not a
    /// multi-variant master (single media playlist, fetch failure,
    /// unparsable). Any failure returns [] so the caller plays the
    /// master unchanged.
    static func variants(of masterURL: URL) async -> [Variant] {
        var request = URLRequest(url: masterURL)
        request.timeoutInterval = 15
        do {
            let (bytes, _) = try await M3UParser.configuredSession().bytes(for: request)
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return parseVariants(text, baseURL: masterURL)
        } catch {
            return []
        }
    }

    /// Picks one variant: the highest bandwidth at or under the
    /// global cap when a cap is set; otherwise the middle tier
    /// (median by bandwidth), which avoids both the lowest-quality
    /// and the stall-prone top tier on first start.
    static func pick(from variants: [Variant], globalCapBitsPerSecond: Double) -> URL? {
        guard !variants.isEmpty else { return nil }
        let sorted = variants.sorted { $0.bandwidth < $1.bandwidth }
        if globalCapBitsPerSecond > 0 {
            let under = sorted.filter { Double($0.bandwidth) <= globalCapBitsPerSecond }
            return (under.last ?? sorted.first)?.url
        }
        return sorted[sorted.count / 2].url
    }

    /// Parses #EXT-X-STREAM-INF lines. Only absolute or master-relative
    /// variant URIs are resolved; anything else is dropped, never
    /// guessed.
    static func parseVariants(_ text: String, baseURL: URL) -> [Variant] {
        var result: [Variant] = []
        let lines = text.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                let bandwidth = line.components(separatedBy: ",").first(where: { $0.contains("BANDWIDTH=") })
                    .flatMap { part in
                        part.split(separator: "=").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    } ?? 0
                if index + 1 < lines.count {
                    let uri = lines[index + 1].trimmingCharacters(in: .whitespaces)
                    if !uri.isEmpty, !uri.hasPrefix("#"), let resolved = URL(string: uri, relativeTo: baseURL)?.absoluteURL {
                        result.append(Variant(bandwidth: bandwidth, url: resolved))
                    }
                }
            }
            index += 1
        }
        return result
    }
}

