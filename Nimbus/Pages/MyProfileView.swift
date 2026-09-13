import SwiftUI

/// Your own page is the artist page — the site draws the two identically, down to the banner and
/// the tabs, and so does this. What changes sits inside `ArtistView`: Share and Edit where a
/// visitor gets Follow, and a rail of who you follow and what you have been saying.
struct MyProfileView: View {
    let model: AppModel

    var body: some View {
        Group {
            if let me = model.library.meUser {
                ArtistView(user: me, model: model, isMe: true)
            } else {
                FaderLoader(size: 30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { model.library.loadMe() }
    }
}
