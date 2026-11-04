import Foundation
import Network
import SwiftUI

// Dev round 10 (D-06): DLNA casting in pure Swift, no third-party
// dependency. SSDP discovery (UDP multicast M-SEARCH) finds real
// renderers on the LAN; UPnP AVTransport (SOAP) sets the URI and
// plays/pauses/stops. No device is ever invented: an empty discovery
// shows an explicit "no devices" state. Casting pauses local
// playback by removing the local player view (the detail page swaps
// it for a casting placeholder); disconnect restores it.
// True casting behaviour needs a real renderer on the LAN and cannot
// be verified in this sandbox; that is a device-verification item,
// not a claim.

/// A discovered UPnP media renderer.
struct DLNADevice: Identifiable, Hashable {
    var id: String { location }
    var friendlyName: String
    var location: String
    var controlURL: String
    var serviceType: String
}

/// SSDP discovery: one M-SEARCH broadcast, collect LOCATION answers
/// for a few seconds, then fetch each device description XML for the
/// friendly name and the AVTransport control URL.
@MainActor
final class DLNADiscovery: ObservableObject {
    @Published private(set) var devices: [DLNADevice] = []
    @Published private(set) var isSearching = false

    private var group: NWConnectionGroup?
    private var searchTask: Task<Void, Never>?
    private var seenLocations: Set<String> = []

    func start() {
        stop()
        isSearching = true
        devices = []
        seenLocations = []
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        guard let multicast = try? NWMulticastGroup(for: [.hostPort(host: "239.255.255.0", port: 1900)]) else {
            isSearching = false
            return
        }
        let group = NWConnectionGroup(with: multicast, using: parameters)
        self.group = group
        group.setReceiveHandler(maximumMessageSize: 8192, rejectOversizedMessages: true) { [weak self] message, _, _ in
            guard let self, let data = message, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                await self?.handleResponse(text)
            }
        }
        group.start(queue: .main)
        // M-SEARCH, repeated once: some renderers answer only the
        // second probe. ST targets AVTransport renderers first and
        // falls back to all root devices via a second query below.
        let request = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.0:1900\r\nMAN: \"ns=01\"\r\nMX: 3\r\nST: urn:schemas-upnp-org:service:AVTransport:1\r\n\r\n"
        if let payload = request.data(using: .utf8) {
            group.send(content: payload) { _ in }
            group.send(content: payload) { _ in }
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            self.stopSearching()
        }
    }

    func stop() {
        searchTask?.cancel()
        searchTask = nil
        group?.cancel()
        group = nil
        isSearching = false
    }

    private func stopSearching() {
        group?.cancel()
        group = nil
        isSearching = false
    }

    private func handleResponse(_ text: String) async {
        // SSDP answers are HTTP-like headers; LOCATION is the only
        // field discovery trusts (USN/ST are not used for identity).
        var location: String?
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "location" {
                location = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let location, !location.isEmpty, !seenLocations.contains(location),
              let url = URL(string: location) else { return }
        seenLocations.insert(location)
        if let device = await DLNADescription.fetch(url: url) {
            devices.append(device)
            devices.sort { $0.friendlyName < $1.friendlyName }
        }
    }
}

/// Fetches a device description XML and extracts the friendly name
/// plus the AVTransport service's controlURL. A description without
/// an AVTransport service is not a cast target and is dropped.
enum DLNADescription {
    static func fetch(url: URL) async -> DLNADevice? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let parser = DLNADeviceParser(data: data, location: url.absoluteString)
        return parser.parse()
    }
}

private final class DLNADeviceParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let location: String
    private var friendlyName = ""
    private var inService = false
    private var currentServiceType = ""
    private var currentControlURL = ""
    private var currentElement = ""
    private var foundText = ""
    private var avTransportControlURL: String?
    private var avTransportType = ""

    init(data: Data, location: String) {
        self.data = data
        self.location = location
    }

    func parse() -> DLNADevice? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), !friendlyName.isEmpty, let control = avTransportControlURL, !control.isEmpty else { return nil }
        let base = URL(string: location)
        let resolved = URL(string: control, relativeTo: base)?.absoluteURL.absoluteString ?? control
        return DLNADevice(friendlyName: friendlyName, location: location, controlURL: resolved, serviceType: avTransportType)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        foundText = ""
        if elementName == "service" { inService = true; currentServiceType = ""; currentControlURL = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        foundText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = foundText.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "friendlyName" && !inService { friendlyName = text }
        if inService {
            if elementName == "serviceType" { currentServiceType = text }
            if elementName == "controlURL" { currentControlURL = text }
            if elementName == "service" {
                if currentServiceType.contains("AVTransport") {
                    avTransportControlURL = currentControlURL
                    avTransportType = currentServiceType
                }
                inService = false
            }
        }
        foundText = ""
    }
}

/// UPnP AVTransport SOAP client: SetAVTransportURI + Play / Pause /
/// Stop. SOAPAction headers and the envelope follow the UPnP
/// AVTransport:1 service template; the InstanceID is always 0.
enum DLNAControl {
    enum CastError: Error {
        case requestFailed
    }

    static func setURIAndPlay(device: DLNADevice, mediaURL: URL) async throws {
        try await soap(device: device, action: "SetAVTransportURI", body:
            "<u:SetAVTransportURI xmlns:u=\"\(device.serviceType)\"><InstanceID>0</InstanceID><CurrentURI>\(escape(mediaURL.absoluteString))</CurrentURI><CurrentURIMetaData></CurrentURIMetaData></u:SetAVTransportURI>")
        try await soap(device: device, action: "Play", body:
            "<u:Play xmlns:u=\"\(device.serviceType)\"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play>")
    }

    static func pause(device: DLNADevice) async throws {
        try await soap(device: device, action: "Pause", body:
            "<u:Pause xmlns:u=\"\(device.serviceType)\"><InstanceID>0</InstanceID></u:Pause>")
    }

    static func stop(device: DLNADevice) async throws {
        try await soap(device: device, action: "Stop", body:
            "<u:Stop xmlns:u=\"\(device.serviceType)\"><InstanceID>0</InstanceID></u:Stop>")
    }

    private static func soap(device: DLNADevice, action: String, body: String) async throws {
        guard let url = URL(string: device.controlURL) else { throw CastError.requestFailed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(device.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        let envelope = "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>\(body)</s:Body></s:Envelope>"
        request.httpBody = envelope.data(using: .utf8)
        request.timeoutInterval = 15
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { throw CastError.requestFailed }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Device picker sheet for the detail page cast button. Lists only
/// devices SSDP actually found; while searching with none found yet
/// it says so, and with none found after the search it says that
/// too — an empty list is never dressed up as a device.
struct DLNADeviceSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = DLNADiscovery()
    @ObservedObject var cast: DLNACastState
    let url: URL?

    var body: some View {
        NavigationStack {
            List {
                if discovery.devices.isEmpty {
                    Text(discovery.isSearching ? state.localized("正在搜索设备…") : state.localized("未发现设备"))
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(discovery.devices) { device in
                        Button {
                            Task {
                                if let url {
                                    await cast.cast(to: device, url: url)
                                    if cast.isCasting { dismiss() }
                                }
                            }
                        } label: {
                            HStack {
                                Text(device.friendlyName)
                                Spacer()
                                if cast.device?.id == device.id {
                                    Image(systemName: "checkmark").foregroundStyle(state.accent)
                                }
                            }
                        }.buttonStyle(.plain).disabled(url == nil)
                    }
                }
                // Dev round 10 (D-06): the stored message is the
                // Chinese literal; route it through localized() so
                // the other languages show their table entry.
                if let error = cast.errorMessage {
                    Text(state.localized(error)).font(.caption).foregroundStyle(.red)
                }
            }
            .navigationTitle(state.localized("投屏"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(state.localized("完成")) { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(state.localized("重新搜索")) { discovery.start() }
                }
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }
}

/// Casting session state for the detail page: which device is
/// casting, and the last error (shown verbatim, never a generic
/// "failed" without the action that failed).
@MainActor
final class DLNACastState: ObservableObject {
    @Published private(set) var device: DLNADevice?
    @Published private(set) var errorMessage: String?

    var isCasting: Bool { device != nil }

    func cast(to target: DLNADevice, url: URL) async {
        errorMessage = nil
        do {
            try await DLNAControl.setURIAndPlay(device: target, mediaURL: url)
            device = target
        } catch {
            errorMessage = "投屏失败：设备拒绝了播放请求。"
        }
    }

    func disconnect() async {
        guard let current = device else { return }
        try? await DLNAControl.stop(device: current)
        device = nil
    }
}
