import SwiftUI

/// Pushing onto the detail column's path from anywhere below it.
///
/// `NavigationLink` would be the obvious way, but every link registers a navigation request as it
/// appears, and the library screens materialise a whole page of cards in one frame — three links
/// per card. A button that appends on tap costs nothing until it is pressed.
@MainActor
struct Navigator {
    /// Kept as an existential so one closure serves every destination type; Swift opens it back
    /// into the concrete type at the call, which is what `navigationDestination(for:)` matches on.
    private let push: (any Hashable) -> Void

    init(push: @escaping (any Hashable) -> Void = { _ in }) {
        self.push = push
    }

    func open(_ value: some Hashable) {
        push(value)
    }
}

// Every navigator pushes onto the shell's one path, so a fresh instance must not read as a change.
extension Navigator: Equatable {
    nonisolated static func == (lhs: Navigator, rhs: Navigator) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var navigator = Navigator()
    /// A page that names itself in its hero tells the shell when that name has scrolled out of
    /// sight, and the toolbar takes over saying it.
    @Entry var onTitleCollapse: @MainActor (Bool) -> Void = { _ in }
}

/// A `NavigationLink` in everything but the registration cost.
struct NavButton<Label: View>: View {
    @Environment(\.navigator) private var navigator

    let value: any Hashable
    @ViewBuilder let label: Label

    var body: some View {
        Button { navigator.open(value) } label: { label }
            .buttonStyle(.plain)
    }
}
