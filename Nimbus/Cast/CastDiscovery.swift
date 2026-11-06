import Foundation
import Network
import Observation

nonisolated struct CastDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let model: String
    let endpoint: NWEndpoint

    var symbol: String { isSpeaker ? "hifispeaker.fill" : "tv" }

    var isSpeaker: Bool {
        let model = model.lowercased()
        return ["speaker", "home", "audio", "nest mini", "group"].contains { model.contains($0) }
            && !model.contains("hub")
    }
}

@MainActor
@Observable
final class CastDiscovery {
    private(set) var devices: [CastDevice] = []
    private(set) var isDenied = false
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil, !ProcessInfo.isRunningForPreviews else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.changed(to: state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

#if DEBUG
    func seedForPreview(_ devices: [CastDevice]) {
        self.devices = devices
    }
#endif

    private func changed(to state: NWBrowser.State) {
        switch state {
        case .waiting(let error), .failed(let error):
            if case .dns(let code) = error, code == kDNSServiceErr_PolicyDenied {
                isDenied = true
            }
            if case .failed = state {
                browser?.cancel()
                browser = nil
            }
        case .ready:
            isDenied = false
        default:
            break
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        devices = results.compactMap { result -> CastDevice? in
            guard case .service(let service, _, _, _) = result.endpoint else { return nil }
            var name = service
            var model = ""
            var id = service
            if case .bonjour(let record) = result.metadata {
                name = record["fn"] ?? service
                model = record["md"] ?? ""
                id = record["id"] ?? service
            }
            return CastDevice(id: id, name: name, model: model, endpoint: result.endpoint)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
