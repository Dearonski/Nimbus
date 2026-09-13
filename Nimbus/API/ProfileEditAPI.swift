import Foundation
import ImageIO
import UniformTypeIdentifiers

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

    /// Only what changed, as plain JSON without a wrapper: the site's `me` model saves with
    /// `saveFormat: "json"` and `saveWithWrapper: false` to `PUT me`. VERIFIED 13.09.2026 with an
    /// unchanged first name — 200 and an empty `{}` back.
    func updateProfile(_ changes: [ProfileField: String]) async throws {
        guard !changes.isEmpty else { return }
        let body = Dictionary(uniqueKeysWithValues: changes.map { ($0.key.rawValue, $0.value) })
        let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        try await mutate(method: "PUT", path: "/me", json: json)
    }

    /// `PUT me/profile/avatar` with the image as base64, the data URI's prefix cut off: the site's
    /// image mixin reads the file as a data URL and sends `{image_data: dataURL.split(",")[1]}`.
    func uploadAvatar(_ fileURL: URL) async throws {
        let jpeg = try PreparedImage.jpeg(from: fileURL, aspect: 1, maxWidth: 1000)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: [
            "image_data": jpeg.base64EncodedString(),
        ]), as: UTF8.self)
        try await mutate(method: "PUT", path: "/me/profile/avatar", json: json)
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
        try await mutate(method: "POST", path: "/visuals", json: json)
    }

    /// The site's header delete modal ends in `new UserVisual({id: me.id}).destroy()`, and the base
    /// model's destroy URL is its bare base URL — the `visuals` endpoint, no id appended. The id only
    /// keeps the model from counting as new, which would skip the request altogether.
    func removeProfileHeader() async throws {
        try await mutate(method: "DELETE", path: "/visuals")
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
}

/// What the edit form starts from, as `/me` spells it.
nonisolated struct SCEditableProfile: Decodable, Sendable {
    let username: String
    let permalink: String?
    let firstName: String?
    let lastName: String?
    let city: String?
    let countryCode: String?
    let description: String?
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case username, permalink, city, description
        case firstName = "first_name"
        case lastName = "last_name"
        case countryCode = "country_code"
        case avatarURL = "avatar_url"
    }
}

/// Cropped to shape and scaled down before upload, the way the site's crop step leaves a picture.
nonisolated enum PreparedImage {
    struct Unreadable: Error {}

    /// Centre-cropped to `aspect`, no wider than `maxWidth`, upright. Read through the thumbnail
    /// path on purpose: it applies the EXIF orientation, where decoding the image directly left
    /// phone photos lying on their side.
    static func jpeg(from url: URL, aspect: CGFloat, maxWidth: CGFloat) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 6000,
              ] as CFDictionary)
        else { throw Unreadable() }

        let width = CGFloat(upright.width), height = CGFloat(upright.height)
        var crop = CGRect(x: 0, y: 0, width: width, height: height)
        if width / height > aspect {
            crop.size.width = height * aspect
            crop.origin.x = (width - crop.width) / 2
        } else {
            crop.size.height = width / aspect
            crop.origin.y = (height - crop.height) / 2
        }
        guard let cropped = upright.cropping(to: crop.integral) else { throw Unreadable() }

        let scale = min(1, maxWidth / crop.width)
        let outWidth = max(Int(crop.width * scale), 1), outHeight = max(Int(crop.height * scale), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Unreadable() }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        guard let final = context.makeImage() else { throw Unreadable() }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Unreadable() }
        CGImageDestinationAddImage(destination, final, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Unreadable() }
        return data as Data
    }
}
