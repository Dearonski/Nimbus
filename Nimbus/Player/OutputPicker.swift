import AVKit
import Network
import IOKit.ps
import SwiftUI

struct OutputButton: View {
    let player: PlayerEngine
    var idle = AnyShapeStyle(.primary)
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "airplay.audio")
        }
        .foregroundStyle(player.cast != nil ? AnyShapeStyle(.tint) : idle)
        .help(player.cast.map { "Playing on \($0.device.name)" } ?? "Play On")
        .popover(isPresented: $showing, arrowEdge: .top) {
            OutputPanel(player: player, discovery: player.castDiscovery) { showing = false }
        }
    }
}

struct OutputPanel: View {
    let player: PlayerEngine
    let discovery: CastDiscovery
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Play On")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            OutputRow(symbol: Self.macSymbol, name: "This Mac",
                      isSelected: player.cast == nil && player.castConnecting == nil) {
                player.stopCasting()
                dismiss()
            }
            ForEach(discovery.devices) { device in
                OutputRow(symbol: device.symbol, name: device.name,
                          isSelected: player.cast?.device.id == device.id,
                          isBusy: player.castConnecting?.id == device.id) {
                    Task { await player.cast(to: device) }
                }
            }
            if discovery.isDenied {
                note("To find Chromecast devices, allow Nimbus in System Settings › Privacy & Security › Local Network.")
            } else if discovery.devices.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Chromecast devices…")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            Divider().padding(.vertical, 4)
            AirPlayRow { player.stopCasting() }
        }
        .padding(8)
        .frame(width: 270)
        .onAppear { discovery.start() }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }

    private static let macSymbol: String = {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        return sources.isEmpty ? "desktopcomputer" : "laptopcomputer"
    }()
}

private struct OutputRow: View {
    let symbol: String
    let name: String
    var isSelected = false
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .frame(width: 22)
                Text(name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isBusy {
                    ProgressView().controlSize(.small)
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(OutputRowStyle())
    }
}

private struct OutputRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct HoverRow<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @State private var hovering = false

    var body: some View {
        label
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isPressed ? 0.14 : hovering ? 0.08 : 0)))
            .onHover { hovering = $0 }
    }
}

// The system's AirPlay list can't take our Chromecasts, so it sits here as one row of ours.
private struct AirPlayRow: View {
    let onOpen: () -> Void
    @State private var host = RoutePickerHost()

    var body: some View {
        Button { host.open() } label: {
            HStack(spacing: 10) {
                RoutePicker(host: host).frame(width: 22, height: 22)
                Text("AirPlay")
                    .font(.system(size: 13))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(OutputRowStyle())
        .onAppear { host.onOpen = onOpen }
    }
}

@MainActor
private final class RoutePickerHost: NSObject, AVRoutePickerViewDelegate {
    // No player: the system output moves, and both decks follow it.
    let view = AVRoutePickerView()
    var onOpen: () -> Void = {}

    override init() {
        super.init()
        view.isRoutePickerButtonBordered = false
        view.delegate = self
    }

    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        onOpen()
    }

    func open() {
        func button(in view: NSView) -> NSButton? {
            if let button = view as? NSButton { return button }
            return view.subviews.lazy.compactMap(button(in:)).first
        }
        button(in: view)?.performClick(nil)
    }
}

private struct RoutePicker: NSViewRepresentable {
    let host: RoutePickerHost

    func makeNSView(context: Context) -> AVRoutePickerView { host.view }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

#if DEBUG
#Preview("Play On") {
    let player = PlayerEngine(api: SoundCloudAPI())
    let endpoint = NWEndpoint.service(name: "preview", type: "_googlecast._tcp", domain: "local.", interface: nil)
    player.castDiscovery.seedForPreview([
        CastDevice(id: "1", name: "Living Room TV", model: "Chromecast", endpoint: endpoint),
        CastDevice(id: "2", name: "Kitchen", model: "Google Nest Mini", endpoint: endpoint),
    ])
    return HStack(alignment: .top, spacing: 24) {
        OutputPanel(player: player, discovery: player.castDiscovery) {}
        OutputPanel(player: PlayerEngine(api: SoundCloudAPI()), discovery: CastDiscovery()) {}
    }
    .padding(24)
    .background(Color(nsColor: .windowBackgroundColor))
    .tint(.scOrange)
}
#endif

#if DEBUG
#Preview("Volume while casting") {
    let device = CastDevice(id: "tv", name: "Living Room TV", model: "Chromecast",
                            endpoint: .hostPort(host: "192.168.1.20", port: 8009))
    VStack(alignment: .trailing, spacing: 24) {
        VolumeButton(volume: .constant(0.6), forceExpanded: true)
        VolumeButton(volume: .constant(0.6), device: device, forceExpanded: true)
        VolumeButton(volume: .constant(0.6), device: device)
    }
    .font(.system(size: 17))
    .padding(.leading, 160)
    .padding(24)
    .background(Color(nsColor: .windowBackgroundColor))
    .tint(.scOrange)
}
#endif
