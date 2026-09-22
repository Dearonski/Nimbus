import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The site's "Edit your Profile", in the app: picture, display name, profile URL, name, city,
/// country and bio. Links are left to the site for now — their editor has an order and a network per
/// entry, and the format of that request hasn't been read yet.
struct EditProfileView: View {
    let model: AppModel
    let onSaved: () -> Void
    /// Lets a #Preview start from a profile instead of fetching one.
    var previewProfile: SCEditableProfile?

    @Environment(\.dismiss) private var dismiss

    @State private var original: SCEditableProfile?
    @State private var username = ""
    @State private var permalink = ""
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var city = ""
    @State private var countryCode = ""
    @State private var bio = ""
    @State private var avatarFile: URL?
    @State private var avatarPreview: NSImage?
    @State private var isSaving = false
    @State private var failure: String?

    private static let countries: [(code: String, name: String)] = Locale.Region.isoRegions
        .map(\.identifier)
        .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        .compactMap { code in Locale.current.localizedString(forRegionCode: code).map { (code, $0) } }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

    /// SoundCloud's own rule for the last part of a profile URL.
    private var permalinkIsValid: Bool {
        !permalink.isEmpty && permalink.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private var changes: [SoundCloudAPI.ProfileField: String] {
        guard let original else { return [:] }
        var changed: [SoundCloudAPI.ProfileField: String] = [:]
        func compare(_ field: SoundCloudAPI.ProfileField, _ value: String, _ was: String?) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != (was ?? "") { changed[field] = trimmed }
        }
        compare(.username, username, original.username)
        compare(.permalink, permalink, original.permalink)
        compare(.firstName, firstName, original.firstName)
        compare(.lastName, lastName, original.lastName)
        compare(.city, city, original.city)
        compare(.countryCode, countryCode, original.countryCode)
        compare(.description, bio, original.description)
        return changed
    }

    private var canSave: Bool {
        original != nil && !isSaving && permalinkIsValid
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (!changes.isEmpty || avatarFile != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit your profile")
                .font(.system(size: 20, weight: .bold))
                .padding(.bottom, 20)

            if original == nil {
                FaderLoader(size: 26)
                    .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                HStack(alignment: .top, spacing: 28) {
                    avatar
                    form
                }
            }

            Spacer(minLength: 20)
            footer
        }
        .padding(28)
        .frame(width: 680, height: 560)
        .task { await loadProfile() }
        // Typing a space in these fields must not reach the shell's play/pause shortcut.
        .reportsTyping(true, to: model)
    }

    private var avatar: some View {
        VStack(spacing: 14) {
            Group {
                if let avatarPreview {
                    Image(nsImage: avatarPreview).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Artwork(url: original?.avatarURL.liveArtwork.scArtwork(.hero))
                }
            }
            .frame(width: 180, height: 180)
            .clipShape(Circle())

            Button("Update image", action: pickAvatar)
                .glassButton()
                .controlSize(.regular)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Display name", required: true) {
                TextField("", text: $username)
            }

            field("Profile URL", required: true) {
                HStack(spacing: 2) {
                    Text("soundcloud.com/").foregroundStyle(.secondary)
                    TextField("", text: $permalink)
                }
            }
            if let was = original?.permalink, permalink != was, permalinkIsValid {
                Text("Links to soundcloud.com/\(was) will stop working.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else if !permalinkIsValid {
                Text("Lowercase letters, numbers, hyphens and underscores only.")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                field("First name") { TextField("", text: $firstName) }
                field("Last name") { TextField("", text: $lastName) }
            }
            HStack(spacing: 12) {
                field("City") { TextField("", text: $city) }
                field("Country") {
                    Picker("", selection: $countryCode) {
                        Text("None").tag("")
                        ForEach(Self.countries, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden()
                }
            }

            field("Bio") {
                TextEditor(text: $bio)
                    .font(.system(size: 13))
                    .frame(height: 96)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func field<Content: View>(_ label: String, required: Bool = false,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 2) {
                Text(label).font(.system(size: 12, weight: .semibold))
                if required { Text("*").foregroundStyle(.tint) }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button("Cancel") { dismiss() }
                .glassButton()
                .keyboardShortcut(.cancelAction)
            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 6) {
                    if isSaving { ProgressView().controlSize(.small) }
                    Text("Save changes")
                }
            }
            .glassButton(.prominent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .controlSize(.large)
    }

    private func loadProfile() async {
        guard original == nil else { return }
        do {
            let profile: SCEditableProfile
            if let previewProfile {
                profile = previewProfile
            } else {
                profile = try await model.api.editableProfile()
            }
            username = profile.username
            permalink = profile.permalink ?? ""
            firstName = profile.firstName ?? ""
            lastName = profile.lastName ?? ""
            city = profile.city ?? ""
            countryCode = profile.countryCode ?? ""
            bio = profile.description ?? ""
            original = profile
        } catch {
            failure = "Couldn't load your profile"
        }
    }

    private func pickAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        avatarFile = file
        avatarPreview = NSImage(contentsOf: file)
    }

    private func save() async {
        isSaving = true
        failure = nil
        defer { isSaving = false }
        do {
            try await model.api.updateProfile(changes)
            if let avatarFile { try await model.api.uploadAvatar(avatarFile) }
            model.library.reloadMe()
            onSaved()
            dismiss()
        } catch SCError.http(let code) {
            failure = code == -1 ? "SoundCloud refused the change" : "SoundCloud answered \(code)"
        } catch {
            failure = "Couldn't save your profile"
        }
    }
}

#if DEBUG
#Preview("Edit profile") {
    let model = AppModel()
    let profile = try! JSONDecoder().decode(SCEditableProfile.self, from: Data("""
    {"username":"dearonski","permalink":"dearonski","first_name":"Kirill","last_name":"bebrov",
     "city":"","country_code":"US","description":"","avatar_url":null}
    """.utf8))
    return EditProfileView(model: model, onSaved: {}, previewProfile: profile)
        .environment(model.library)
        .tint(.scOrange)
}
#endif
