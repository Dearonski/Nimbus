import Foundation

extension SCWrite {
    /// Only what changed, as plain JSON without a wrapper: the site's `me` model saves with
    /// `saveFormat: "json"` and `saveWithWrapper: false` to `PUT me`. VERIFIED 13.09.2026 with an
    /// unchanged first name — 200 and an empty `{}` back.
    static func updateProfile(json: String) -> Self {
        .put("/me", json: json, verified: "2026-09-13")
    }

    /// The image rides as base64 with the data URI's prefix cut off: the site's image mixin reads
    /// the file as a data URL and sends `{image_data: dataURL.split(",")[1]}`.
    static func uploadAvatar(json: String) -> Self {
        .put("/me/profile/avatar", json: json)
    }

    /// The header modal ends in `new Visual({image_url: url}).save()` — a POST carrying only that
    /// URL. A body shaped like the user object's own `visuals` (urn, enabled, entry_time) got a 503.
    static func setProfileHeader(json: String) -> Self {
        .post("/visuals", json: json)
    }

    /// The site's header delete modal ends in `new UserVisual({id: me.id}).destroy()`, and the base
    /// model's destroy URL is its bare base URL — no id appended.
    static func removeProfileHeader() -> Self {
        .delete("/visuals")
    }
}

extension SCEndpoint where Response == SCVisualTicket {
    /// Signs an upload for a profile header. The parameter really is camelCase: api-v2 answers
    /// "missing contentType parameter" to every other spelling.
    static func presignVisual(contentType: String) -> Self {
        .get("/presign/visuals", ["contentType": contentType], verified: "2026-09-13")
    }
}

/// Editing your own profile, each call shaped the way the web player's own edit flow sends it —
/// read off its bundle, since none of this is in any public documentation.
extension SoundCloudAPI {
    /// The fields the site's "Edit your Profile" form changes, keyed as api-v2 spells them on `/me`.
    enum ProfileField: String, CaseIterable, Sendable {
        case username, permalink, city, description
        case firstName = "first_name"
        case lastName = "last_name"
        case countryCode = "country_code"
    }

    func updateProfile(_ changes: [ProfileField: String]) async throws {
        guard !changes.isEmpty else { return }
        let body = Dictionary(uniqueKeysWithValues: changes.map { ($0.key.rawValue, $0.value) })
        let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        try await send(.updateProfile(json: json))
    }

    /// `PUT me/profile/avatar` with the image as base64, the data URI's prefix cut off: the site's
    /// image mixin reads the file as a data URL and sends `{image_data: dataURL.split(",")[1]}`.
    func uploadAvatar(_ fileURL: URL) async throws {
        let jpeg = try PreparedImage.jpeg(from: fileURL, aspect: 1, maxWidth: 1000)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: [
            "image_data": jpeg.base64EncodedString(),
        ]), as: UTF8.self)
        try await send(.uploadAvatar(json: json))
    }

    /// The profile header, in the three steps the site's header modal takes: api-v2 signs an upload,
    /// the bytes go straight to storage, and the finished URL is handed back. The modal ends in
    /// `new Visual({image_url: url}).save()` — a `POST /visuals` carrying only that URL. A body shaped
    /// like the user object's own `visuals` (urn, enabled, entry_time) was answered with 503.
    func uploadProfileHeader(_ fileURL: URL) async throws {
        // The site crops the header to 1240 by 260 before it uploads; sent whole, a photo was shown
        // as whatever strip of its middle happened to fit.
        let jpeg = try PreparedImage.jpeg(from: fileURL, aspect: 1240 / 260, maxWidth: 2480)
        let ticket = try await presignVisual(contentType: "image/jpeg")
        let imageURL = try await store(jpeg, contentType: "image/jpeg", in: ticket)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["image_url": imageURL]),
                          as: UTF8.self)
        try await send(.setProfileHeader(json: json))
    }

    /// The site's header delete modal ends in `new UserVisual({id: me.id}).destroy()`, and the base
    /// model's destroy URL is its bare base URL — the `visuals` endpoint, no id appended. The id only
    /// keeps the model from counting as new, which would skip the request altogether.
    func removeProfileHeader() async throws {
        try await send(.removeProfileHeader())
    }

    /// A browser-style form post to S3. The signed fields have to come before the file — S3 ignores
    /// anything after it — and the object lands at the bucket URL plus the signed key.
    private func store(_ image: Data, contentType: String, in ticket: SCVisualTicket) async throws -> String {
        guard let bucket = URL(string: ticket.url), let key = ticket.fields["key"] else {
            throw SCError.http(-1)
        }
        let boundary = "nimbus-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }

        for (name, value) in ticket.fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"header.jpg\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(image)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: bucket)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            print("[visuals] storage upload -> \(code): \(String(decoding: data.prefix(300), as: UTF8.self))")
            throw SCError.http(code)
        }
        return bucket.absoluteString.hasSuffix("/") ? bucket.absoluteString + key : bucket.absoluteString + "/" + key
    }

    /// Signs an upload for a profile header. The parameter really is camelCase: api-v2 answers
    /// "missing contentType parameter" to every other spelling. VERIFIED 13.09.2026.
    func presignVisual(contentType: String) async throws -> SCVisualTicket {
        try await get(.presignVisual(contentType: contentType))
    }
}
