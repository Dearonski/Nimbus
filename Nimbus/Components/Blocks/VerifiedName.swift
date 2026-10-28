import SwiftUI

/// A name with the site's verified seal after it, for an account that has one.
struct VerifiedName: View {
    let name: String
    let verified: Bool
    /// Nil sets the seal in the name's own font.
    var seal: Font?
    var spacing: CGFloat = 5

    init(_ user: SCUser, name: String? = nil, seal: Font? = nil, spacing: CGFloat = 5) {
        self.name = name ?? user.username
        verified = user.verified == true
        self.seal = seal
        self.spacing = spacing
    }

    var body: some View {
        HStack(spacing: spacing) {
            Text(name).lineLimit(1)
            if verified {
                Image(systemName: "checkmark.seal.fill")
                    .font(seal)
                    .foregroundStyle(.tint)
            }
        }
    }
}
