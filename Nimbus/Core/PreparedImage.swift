import Foundation
import ImageIO
import UniformTypeIdentifiers

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
