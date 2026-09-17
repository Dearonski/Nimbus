import SwiftUI

/// The full version of a block in an artist's rail. Kept as one route so the rail's "View all"
/// controls all push the same destination type.
enum ProfileList: Hashable {
    case followers(SCUser)
    case following(SCUser)
    case likes(SCUser)

    var user: SCUser {
        switch self {
        case .followers(let user), .following(let user), .likes(let user): user
        }
    }

    var title: String {
        switch self {
        case .followers: "Followers"
        case .following: "Following"
        case .likes: "Likes"
        }
    }
}
