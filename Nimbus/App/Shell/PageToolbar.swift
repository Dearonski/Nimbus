import AppKit
import Observation

// What a page puts in the window's toolbar while it is shown; the shell adds and removes them.
@MainActor
protocol PageToolbar: AnyObject {
    var identifiers: [NSToolbarItem.Identifier] { get }
    func item(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem?
    func focusField()
}

// The shell's own search fields, told apart from SwiftUI's so Space can be left to them.
class ShellSearchField: NSSearchField {
    // While it edits, the window's field editor is first responder with this field as its delegate.
    static func isEditing(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? NSTextView)?.delegate is ShellSearchField
    }

    // A list of custom cards takes no focus when clicked, so it hands the keyboard back itself.
    static func endEditing() {
        guard let window = NSApp.keyWindow, isEditing(in: window) else { return }
        window.makeFirstResponder(nil)
    }
}

// A search field bound to a query; Return leaves it with the text kept.
@MainActor
final class QueryField: NSObject, NSSearchFieldDelegate {
    let field: ShellSearchField
    // Asked first, so a list shown under the field can take the arrows, Return and Esc.
    var interceptCommand: (Selector) -> Bool = { _ in false }
    var onEndEditing: () -> Void = {}
    private let onChange: (String) -> Void
    private let onSubmit: (String) -> Void

    private static let toolbarWidth: CGFloat = 180

    init(_ field: ShellSearchField = ShellSearchField(), placeholder: String, text: String,
         onChange: @escaping (String) -> Void, onSubmit: @escaping (String) -> Void = { _ in }) {
        self.field = field
        self.onChange = onChange
        self.onSubmit = onSubmit
        super.init()
        field.placeholderString = placeholder
        field.stringValue = text
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(changed(_:))
        field.delegate = self
    }

    func toolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSSearchToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: identifier)
        // Left alone, the field took every point the toolbar had spare.
        field.widthAnchor.constraint(lessThanOrEqualToConstant: Self.toolbarWidth).isActive = true
        item.searchField = field
        item.preferredWidthForSearchField = Self.toolbarWidth
        item.label = field.placeholderString ?? ""
        return item
    }

    func show(_ text: String) {
        if field.stringValue != text { field.stringValue = text }
    }

    @objc private func changed(_ field: NSSearchField) {
        onChange(field.stringValue)
    }

    // Space types here rather than playing, so leaving the field must not need the mouse.
    func controlTextDidEndEditing(_ notification: Notification) {
        onEndEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if interceptCommand(selector) { return true }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit(field.stringValue)
            control.window?.makeFirstResponder(nil)
            return true
        // As every search field does: the first Esc clears, the next one leaves.
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty {
                control.window?.makeFirstResponder(nil)
            } else {
                field.stringValue = ""
                onChange("")
            }
            return true
        default:
            return false
        }
    }
}

// A pull-down of choices with a checkmark on the current one, built afresh each time it opens.
@MainActor
final class ChoiceMenu: NSObject, NSMenuDelegate {
    struct Choice {
        let title: String
        let isOn: Bool
        let pick: () -> Void
    }

    let item: NSMenuToolbarItem
    private let choices: () -> [Choice]
    private var picks: [() -> Void] = []

    init(identifier: NSToolbarItem.Identifier, label: String, symbol: String, choices: @escaping () -> [Choice]) {
        item = NSMenuToolbarItem(itemIdentifier: identifier)
        self.choices = choices
        super.init()
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        let menu = NSMenu(title: label)
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // The item shows its menu as a pull-down, which takes the first entry for its title and never lists it.
        let title = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        title.isHidden = true
        menu.addItem(title)
        let current = choices()
        picks = current.map(\.pick)
        for (index, choice) in current.enumerated() {
            let entry = NSMenuItem(title: choice.title, action: #selector(pick(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.state = choice.isOn ? .on : .off
            menu.addItem(entry)
        }
    }

    @objc private func pick(_ entry: NSMenuItem) {
        if picks.indices.contains(entry.tag) { picks[entry.tag]() }
    }
}

// MARK: - Likes

nonisolated let likesLayoutItem = NSToolbarItem.Identifier("nimbus.likes.layout")
nonisolated let likesSortItem = NSToolbarItem.Identifier("nimbus.likes.sort")
nonisolated let likesFilterItem = NSToolbarItem.Identifier("nimbus.likes.filter")

nonisolated let playlistsNewItem = NSToolbarItem.Identifier("nimbus.playlists.new")
nonisolated let searchScopeItem = NSToolbarItem.Identifier("nimbus.search.scope")
nonisolated let searchSortItem = NSToolbarItem.Identifier("nimbus.search.sort")

nonisolated let pageToolbarItems = [likesLayoutItem, likesSortItem, likesFilterItem, searchScopeItem, searchSortItem,
                                    playlistsNewItem]

@MainActor
final class LikesToolbar: PageToolbar {
    private let controls: LikesControls
    private weak var layout: NSToolbarItemGroup?
    private var sort: ChoiceMenu?
    private var filter: QueryField?
    private weak var filterSearch: NSSearchToolbarItem?

    let identifiers = [likesLayoutItem, likesSortItem, likesFilterItem]

    init(controls: LikesControls) {
        self.controls = controls
        follow()
    }

    func item(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case likesLayoutItem: layoutItem()
        case likesSortItem: sortItem()
        case likesFilterItem: filterItem()
        default: nil
        }
    }

    func focusField() {
        filterSearch?.beginSearchInteraction()
    }

    private func layoutItem() -> NSToolbarItem {
        let layouts = LibraryLayout.allCases
        let group = NSToolbarItemGroup(
            itemIdentifier: likesLayoutItem,
            images: layouts.map { NSImage(systemSymbolName: $0.systemImage, accessibilityDescription: $0.title)! },
            selectionMode: .selectOne, labels: layouts.map(\.title),
            target: self, action: #selector(pickLayout(_:)))
        group.label = "View"
        group.selectedIndex = layouts.firstIndex(of: controls.layout) ?? 0
        layout = group
        return group
    }

    @objc private func pickLayout(_ group: NSToolbarItemGroup) {
        let layouts = LibraryLayout.allCases
        if layouts.indices.contains(group.selectedIndex) { controls.layout = layouts[group.selectedIndex] }
    }

    private func sortItem() -> NSToolbarItem {
        let controls = controls
        let menu = ChoiceMenu(identifier: likesSortItem, label: "Sort By", symbol: "arrow.up.arrow.down") {
            LikesSort.allCases.map { option in
                .init(title: option.rawValue, isOn: controls.sort == option) { controls.sort = option }
            }
        }
        sort = menu
        return menu.item
    }

    private func filterItem() -> NSToolbarItem {
        let controls = controls
        let field = QueryField(placeholder: "Filter", text: controls.query) {
            controls.query = $0
        }
        filter = field
        let item = field.toolbarItem(likesFilterItem)
        filterSearch = item
        return item
    }

    // The View menu changes the same values; the controls follow it.
    private func follow() {
        withObservationTracking {
            let index = LibraryLayout.allCases.firstIndex(of: controls.layout) ?? 0
            let query = controls.query
            if let layout, layout.selectedIndex != index { layout.selectedIndex = index }
            filter?.show(query)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }
}

// MARK: - Playlists

@MainActor
final class PlaylistsToolbar: PageToolbar {
    private let create: () -> Void

    let identifiers = [playlistsNewItem]

    init(create: @escaping () -> Void) {
        self.create = create
    }

    func item(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard identifier == playlistsNewItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Playlist")
        item.label = "New Playlist"
        item.toolTip = "New Playlist"
        item.target = self
        item.action = #selector(newPlaylist)
        return item
    }

    func focusField() {}

    @objc private func newPlaylist() {
        create()
    }
}

// MARK: - Search

// The field itself is the sidebar's, on every page; the scope and the sort are the results page's own.
@MainActor
final class SearchToolbar: PageToolbar {
    private let controls: SearchControls
    private weak var scope: NSToolbarItemGroup?
    private var sort: ChoiceMenu?

    let identifiers = [searchScopeItem, searchSortItem]

    init(controls: SearchControls) {
        self.controls = controls
        follow()
    }

    func item(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case searchScopeItem: scopeItem()
        case searchSortItem: sortItem()
        default: nil
        }
    }

    func focusField() {}

    private func scopeItem() -> NSToolbarItem {
        let scopes = SearchScope.allCases
        let group = NSToolbarItemGroup(
            itemIdentifier: searchScopeItem, titles: scopes.map(\.rawValue), selectionMode: .selectOne,
            labels: scopes.map(\.rawValue), target: self, action: #selector(pickScope(_:)))
        group.label = "Show"
        group.controlRepresentation = .expanded
        group.autovalidates = false
        group.subitems.forEach { $0.autovalidates = false }
        group.selectedIndex = scopes.firstIndex(of: controls.scope) ?? 0
        Self.enable(group, !controls.isBlank)
        scope = group
        return group
    }

    // The group draws its segments from the subitems, so they are switched off one by one.
    private static func enable(_ group: NSToolbarItemGroup, _ enabled: Bool) {
        group.isEnabled = enabled
        group.subitems.forEach { $0.isEnabled = enabled }
    }

    @objc private func pickScope(_ group: NSToolbarItemGroup) {
        let scopes = SearchScope.allCases
        if scopes.indices.contains(group.selectedIndex) { controls.scope = scopes[group.selectedIndex] }
    }

    private func sortItem() -> NSToolbarItem {
        let controls = controls
        let menu = ChoiceMenu(identifier: searchSortItem, label: "Sort By", symbol: "arrow.up.arrow.down") {
            controls.sortOptions.map { option in
                .init(title: option.rawValue, isOn: controls.sort == option) { controls.sort = option }
            }
        }
        menu.item.autovalidates = false
        menu.item.isEnabled = !controls.isBlank
        sort = menu
        return menu.item
    }

    // Nothing to scope or sort before there is a query; See All and the View menu move the scope too.
    private func follow() {
        withObservationTracking {
            let enabled = !controls.isBlank
            let index = SearchScope.allCases.firstIndex(of: controls.scope) ?? 0
            if let item = sort?.item, item.isEnabled != enabled { item.isEnabled = enabled }
            if let scope {
                if scope.isEnabled != enabled { Self.enable(scope, enabled) }
                if scope.selectedIndex != index { scope.selectedIndex = index }
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }
}
