import Nuke
import SwiftUI

// Read where the choice applies, so a change in Settings takes effect without passing values around.
nonisolated enum Preference {
    static let opensHomeKey = "opensHome"
    static let keepsRecentSearchesKey = "keepsRecentSearches"
    static let savesDataKey = "savesData"
    static let reportsPlaysKey = "reportsPlays"
    static let notifiesActivityKey = "notifiesActivity"

    static var opensHome: Bool { UserDefaults.standard.bool(forKey: opensHomeKey) }
    static var keepsRecentSearches: Bool {
        UserDefaults.standard.object(forKey: keepsRecentSearchesKey) as? Bool ?? true
    }
    static var savesData: Bool { UserDefaults.standard.bool(forKey: savesDataKey) }
    static var reportsPlays: Bool { UserDefaults.standard.object(forKey: reportsPlaysKey) as? Bool ?? true }
    static var notifiesActivity: Bool { UserDefaults.standard.bool(forKey: notifiesActivityKey) }
}

struct SettingsView: View {
    let model: AppModel
    let updates: Updates
    let showWindow: () -> Void

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralPane(model: model, updates: updates) }
            Tab("Playback", systemImage: "play.circle") { PlaybackPane(player: model.player) }
            Tab("Account", systemImage: "person.crop.circle") { AccountPane(model: model, showWindow: showWindow) }
            Tab("Advanced", systemImage: "gearshape.2") { AdvancedPane() }
        }
        .frame(width: 520)
    }
}

// The accent marks a setting that is on; buttons and pickers keep the system's look, as in Apple's own panes.
private struct SettingsToggle<Label: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder var label: Label

    var body: some View {
        Toggle(isOn: $isOn) { label }.tint(.scOrange)
    }
}

private struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralPane: View {
    let model: AppModel
    @Bindable var updates: Updates

    @AppStorage(Preference.opensHomeKey) private var opensHome = false
    @AppStorage(Preference.keepsRecentSearchesKey) private var keepsRecents = true
    @AppStorage(Preference.notifiesActivityKey) private var notifiesActivity = false
    @State private var notificationsDenied = false

    private var recents: [String] { model.searchControls.recents }

    var body: some View {
        SettingsForm {
            Section {
                Picker("Open at launch", selection: $opensHome) {
                    Text("Last Page").tag(false)
                    Text("Home").tag(true)
                }
            }
            Section("Search") {
                SettingsToggle(isOn: $keepsRecents) { Text("Remember recent searches") }
                LabeledContent(recents.isEmpty ? LocalizedStringKey("No recent searches")
                                                  : "^[\(recents.count) recent search](inflect: true)") {
                    Button("Clear Recent Searches") { model.searchControls.clearRecents() }
                        .disabled(recents.isEmpty)
                }
            }
            Section("Notifications") {
                SettingsToggle(isOn: $notifiesActivity) { Text("Notify about new follows, likes and comments") }
                    .onChange(of: notifiesActivity) { _, on in
                        guard on else { return }
                        Task {
                            notificationsDenied = await !ActivityStore.requestPermission()
                            if notificationsDenied { notifiesActivity = false }
                        }
                    }
                if notificationsDenied {
                    Text("Allow Nimbus in System Settings → Notifications first.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Updates") {
                SettingsToggle(isOn: $updates.checksAutomatically) { Text("Check for updates automatically") }
                SettingsToggle(isOn: $updates.downloadsAutomatically) { Text("Download updates in the background") }
                    .disabled(!updates.checksAutomatically)
                LabeledContent("Nimbus \(Self.version)") {
                    Button("Check Now") { updates.check() }
                        .disabled(!updates.canCheck)
                }
            }
            .disabled(!updates.isActive)
        }
    }

    private static let version: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }()
}

private struct PlaybackPane: View {
    @Bindable var player: PlayerEngine

    @AppStorage(Preference.savesDataKey) private var savesData = false
    @AppStorage(Preference.reportsPlaysKey) private var reportsPlays = true

    var body: some View {
        SettingsForm {
            Section {
                SettingsToggle(isOn: $player.autoplayRelated) {
                    Text("Autoplay related tracks")
                    Text("When the queue runs out, keep playing tracks like the last one.")
                }
                SettingsToggle(isOn: $player.keepsPitch) {
                    Text("Keep pitch when changing speed")
                    Text("Off, faster playback sounds higher, like a sped-up record.")
                }
            }
            Section("Streaming") {
                Picker(selection: $savesData) {
                    Text("High — AAC 160 kbps").tag(false)
                    Text("Data Saver — AAC 96 kbps").tag(true)
                } label: {
                    Text("Quality")
                    Text("Applies from the next track.")
                }
            }
            Section("Privacy") {
                SettingsToggle(isOn: $reportsPlays) {
                    Text("Add plays to my SoundCloud history")
                    Text("""
                        Tracks you play appear in History here and on soundcloud.com, \
                        and count as plays for the artist.
                        """)
                }
            }
        }
    }
}

private struct AccountPane: View {
    let model: AppModel
    let showWindow: () -> Void

    private var me: SCUser? { model.library.meUser }

    var body: some View {
        SettingsForm {
            if model.isAuthenticated {
                Section {
                    HStack(spacing: 12) {
                        Artwork(me, size: .thumb, placeholderOpacity: 0.2)
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(me?.username ?? "SoundCloud").font(.headline)
                            Text("Signed in with SoundCloud").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("View Profile") {
                            showWindow()
                            model.shell?.select(.profile)
                        }
                    }
                }
                Section {
                    LabeledContent("Your queue and history stay on this Mac.") {
                        Button("Sign Out…") { confirmSignOut(model) }
                    }
                }
            } else {
                Section {
                    Text("Not signed in. Sign in from the Nimbus window.").foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AdvancedPane: View {
    @State private var cacheSize = Self.diskUsage

    private static var diskUsage: Int { DataLoader.sharedUrlCache.currentDiskUsage }

    var body: some View {
        SettingsForm {
            Section("Cache") {
                LabeledContent("Artwork", value: cacheSize.formatted(.byteCount(style: .file)))
                LabeledContent("Covers load again from SoundCloud as you browse.") {
                    Button("Clear Cache") {
                        DataLoader.sharedUrlCache.removeAllCachedResponses()
                        ImageCache.shared.removeAll()
                        cacheSize = Self.diskUsage
                    }
                    .disabled(cacheSize == 0)
                }
            }
            Section("Troubleshooting") {
                LabeledContent("Opens a GitHub issue with your Mac and Nimbus versions and the recent log.") {
                    Button("Report an Issue…") { Diagnostics.reportIssue() }
                }
            }
        }
        .onAppear { cacheSize = Self.diskUsage }
    }
}

private func confirmSignOut(_ model: AppModel) {
    let alert = NSAlert()
    alert.messageText = "Sign out of SoundCloud?"
    alert.informativeText = "Your queue and history stay on this Mac. Signing in again brings everything back."
    alert.addButton(withTitle: "Sign Out")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    model.signOut()
}

#if DEBUG
#Preview("Settings") {
    SettingsView(model: AppModel(), updates: Updates(), showWindow: {})
}
#endif
