import Foundation

/// The queue as data, free of playback and awaits, so every rule in it is a unit test away.
nonisolated struct QueueState: Sendable {
    static let refillSize = 50
    /// Played tracks kept behind the current one once autoplay runs on past the collection.
    static let historyLimit = 200

    private(set) var tracks: [SCTrack] = []
    var currentIndex = 0
    /// The same tracks as `tracks`, in the order unshuffling goes back to.
    private(set) var originalOrder: [SCTrack] = []
    /// The whole collection as ids, not just the resolved head, so shuffle covers everything.
    private(set) var canonicalIDs: [Int] = []
    private(set) var pendingIDs: [Int] = []
    /// Unresolved rows above the queue: Previous walks up into them and a lap under repeat starts from
    /// them, but the collection ending never wraps round to them.
    private(set) var leadingIDs: [Int] = []
    private(set) var isShuffled = false
    var repeatMode: RepeatMode = .off
    /// Tracks this queue has actually put on air. Turning shuffle on keeps only these behind the
    /// current track, so Previous walks what was heard rather than rows it never reached.
    private(set) var playedIDs: Set<Int> = []
    /// Bumped wherever a new collection is installed, so work resumed after an await can tell a
    /// skip inside the same queue from a different queue entirely.
    private(set) var epoch = 0

    var current: SCTrack? { tracks.indices.contains(currentIndex) ? tracks[currentIndex] : nil }

    /// A later row, an unresolved tail, or a lap under repeat — somewhere to go without leaving the collection.
    var hasTrackAhead: Bool {
        currentIndex + 1 < tracks.count || !pendingIDs.isEmpty || repeatMode == .all
    }

    var canGoBack: Bool {
        !tracks.isEmpty && (currentIndex > 0 || !leadingIDs.isEmpty || repeatMode == .all)
    }

    // MARK: - A new collection

    struct Install: Sendable {
        let ids: [Int]
        let order: [Int]
        let leading: Int
        let above: [Int]
        let shuffled: Bool
        /// Resolved before anything is committed; the rest waits as ids.
        let headIDs: [Int]
    }

    static func install(ids: [Int], startingAt trackID: Int?, shuffled: Bool, head: Int, lead: Int) -> Install? {
        // A set can list a track twice, and every lookup here, like the panel's rows, keys on the id.
        var listed = Set<Int>()
        let ids = ids.filter { listed.insert($0).inserted }
        guard !ids.isEmpty else { return nil }

        var order = ids
        if shuffled { order.shuffle() }
        var leading = 0
        var above: [Int] = []
        if let trackID, let index = order.firstIndex(of: trackID) {
            if shuffled {
                // A random order has no "above": whatever preceded the pick is still to come.
                order = Array(order[index...]) + Array(order[..<index])
            } else {
                // Rows above the clicked one stay ahead of it, or Previous on it had nowhere to go but its own start.
                leading = min(index, lead)
                above = Array(order[..<(index - leading)])
                order = Array(order[(index - leading)...])
            }
        }
        return Install(ids: ids, order: order, leading: leading, above: above, shuffled: shuffled,
                       headIDs: Array(order.prefix(leading + head)))
    }

    mutating func install(_ plan: Install, tracks: [SCTrack]) {
        epoch += 1
        canonicalIDs = plan.ids
        isShuffled = plan.shuffled
        pendingIDs = Array(plan.order.dropFirst(plan.headIDs.count))
        leadingIDs = plan.above
        playedIDs = []
        self.tracks = tracks
        originalOrder = tracks
        let resolved = Set(tracks.map(\.id))
        let startID = plan.headIDs.dropFirst(plan.leading).first { resolved.contains($0) }
        currentIndex = startID.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
    }

    /// Last session's queue, with only `window` resolved. False when nothing in it can play any more.
    mutating func restore(_ session: PlayerEngine.Session, window: Range<Int>, tracks resolved: [SCTrack]) -> Bool {
        // A subscription that has lapsed since the queue was saved drops its tracks; an id saved twice
        // by an older build keeps its first place.
        var seen = Set<Int>()
        let tracks = resolved.filter { $0.isPlayable && seen.insert($0.id).inserted }
        guard !tracks.isEmpty else { return false }
        let currentID = session.queue.indices.contains(session.index) ? session.queue[session.index] : nil
        epoch += 1
        self.tracks = tracks
        originalOrder = tracks
        pendingIDs = (Array(session.queue[window.upperBound...]) + session.pending).filter { seen.insert($0).inserted }
        leadingIDs = (session.leading + Array(session.queue[..<window.lowerBound])).filter { seen.insert($0).inserted }
        playedIDs = []
        var canonical = Set<Int>()
        canonicalIDs = session.canonical.filter { canonical.insert($0).inserted }
        isShuffled = session.isShuffled
        repeatMode = session.repeatMode
        // By id: a track that no longer resolves drops out and shifts every position after it.
        currentIndex = currentID.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
        return true
    }

    func session(position: Double) -> PlayerEngine.Session {
        PlayerEngine.Session(queue: tracks.map(\.id), index: currentIndex, leading: leadingIDs, pending: pendingIDs,
                             canonical: canonicalIDs, isShuffled: isShuffled, repeatMode: repeatMode,
                             position: position)
    }

    mutating func clear() {
        self = QueueState(repeatMode: repeatMode, epoch: epoch + 1)
    }

    private init(repeatMode: RepeatMode, epoch: Int) {
        self.repeatMode = repeatMode
        self.epoch = epoch
    }

    init() {}

    // MARK: - Edits

    mutating func markPlayed(_ id: Int) {
        playedIDs.insert(id)
    }

    /// Play Next or Play Later. False for the track on air, which stays where it is.
    @discardableResult
    mutating func insert(_ track: SCTrack, next: Bool, currentID: Int) -> Bool {
        guard track.id != currentID else { return false }
        tracks.removeAll { $0.id == track.id }
        currentIndex = tracks.firstIndex { $0.id == currentID } ?? currentIndex
        tracks.insert(track, at: next ? min(currentIndex + 1, tracks.count) : tracks.count)
        originalOrder.removeAll { $0.id == track.id }
        if next, let index = originalOrder.firstIndex(where: { $0.id == currentID }) {
            originalOrder.insert(track, at: min(index + 1, originalOrder.count))
        } else {
            originalOrder.append(track)
        }
        return true
    }

    mutating func move(from source: IndexSet, to destination: Int, currentID: Int?) {
        let moving = source.filter(tracks.indices.contains).map { tracks[$0] }
        var rest = tracks.indices.filter { !source.contains($0) }.map { tracks[$0] }
        rest.insert(contentsOf: moving, at: min(destination - source.count(in: 0..<destination), rest.count))
        tracks = rest
        // While shuffled the two orders legitimately differ, and a reorder inside the random one
        // must not overwrite the order unshuffling goes back to.
        if !isShuffled { originalOrder = tracks }
        if let currentID {
            currentIndex = tracks.firstIndex { $0.id == currentID } ?? currentIndex
        }
    }

    /// True when the track on air was among those removed.
    mutating func remove(atOffsets offsets: IndexSet, currentID: Int?) -> Bool {
        let removingCurrent = offsets.contains(currentIndex)
        let removed = Set(offsets.compactMap { tracks.indices.contains($0) ? tracks[$0].id : nil })
        tracks = tracks.indices.filter { !offsets.contains($0) }.map { tracks[$0] }
        // A removed track is gone for good, shuffled or not: both orders unshuffling rebuilds from shed it.
        originalOrder.removeAll { removed.contains($0.id) }
        canonicalIDs.removeAll { removed.contains($0) }
        if let currentID, let index = tracks.firstIndex(where: { $0.id == currentID }) {
            currentIndex = index
            return false
        }
        guard removingCurrent else { return false }
        currentIndex = max(0, min(currentIndex, tracks.count - 1))
        return true
    }

    /// Drops the unresolved tail too: leaving it made Clear empty the panel and refill it at the next track.
    mutating func clearUpcoming() {
        var dropped = Set(pendingIDs)
        pendingIDs = []
        if tracks.indices.contains(currentIndex), currentIndex + 1 < tracks.count {
            dropped.formUnion(tracks[(currentIndex + 1)...].map(\.id))
            tracks.removeSubrange((currentIndex + 1)...)
        }
        originalOrder.removeAll { dropped.contains($0.id) }
        canonicalIDs.removeAll { dropped.contains($0) }
    }

    /// True when an unresolved tail is left to mix into the upcoming order.
    mutating func toggleShuffle(currentID: Int?) -> Bool {
        isShuffled.toggle()
        guard let currentID else { return false }
        if isShuffled {
            guard tracks.indices.contains(currentIndex) else { return false }
            let above = tracks[..<currentIndex]
            let history = above.filter { playedIDs.contains($0.id) }
            let unheard = above.filter { !playedIDs.contains($0.id) }
            tracks = history + [tracks[currentIndex]] + (unheard + tracks[(currentIndex + 1)...]).shuffled()
            currentIndex = history.count
            pendingIDs = (leadingIDs + pendingIDs).shuffled()
            leadingIDs = []
            // Shuffling the two apart leaves the loaded slice ahead of the tail, so a shuffled
            // 2000-track collection would still open with the first 60 of it.
            return !pendingIDs.isEmpty
        }
        let rank = Dictionary(canonicalIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        tracks = originalOrder.sorted { rank[$0.id, default: .max] < rank[$1.id, default: .max] }
        originalOrder = tracks
        currentIndex = tracks.firstIndex { $0.id == currentID } ?? 0
        let resolved = Set(tracks.map(\.id))
        let unresolved = canonicalIDs.filter { !resolved.contains($0) }
        // Split around the current track, or the collection's top would play again after its end.
        let here = rank[currentID, default: .max]
        leadingIDs = unresolved.filter { rank[$0, default: .max] < here }
        pendingIDs = unresolved.filter { rank[$0, default: .max] > here }
        return false
    }

    /// A fresh lap under repeat gets a fresh order; repeating the same random sequence isn't shuffle.
    mutating func startLapInPlace() {
        if isShuffled { tracks.shuffle() }
        currentIndex = 0
    }

    /// Autoplay runs on without end, so the played part behind it is kept to a bounded history.
    mutating func appendRelated(_ fresh: [SCTrack]) {
        tracks.append(contentsOf: fresh)
        originalOrder.append(contentsOf: fresh)
        canonicalIDs.append(contentsOf: fresh.map(\.id))
        let excess = currentIndex - Self.historyLimit
        guard excess > 0 else { return }
        let dropped = Set(tracks[..<excess].map(\.id))
        tracks.removeFirst(excess)
        currentIndex -= excess
        originalOrder.removeAll { dropped.contains($0.id) }
        canonicalIDs.removeAll { dropped.contains($0) }
        playedIDs.subtract(dropped)
        leadingIDs = []
    }

    #if DEBUG
    mutating func seedForPreview(_ tracks: [SCTrack], at index: Int, pending: Int) {
        self.tracks = tracks
        originalOrder = tracks
        currentIndex = min(max(index, 0), max(tracks.count - 1, 0))
        pendingIDs = Array(0..<pending).map { -($0 + 1) }
    }
    #endif

    // MARK: - Slices resolved on the way

    /// Work that needs some ids turned into tracks first: the engine resolves `missing(for:)`, then applies.
    enum Step: Sendable {
        case refill(slice: [Int])
        /// Previous on the first track: the rows above it, or under repeat the end of the tail.
        case front(fromLeading: Bool, slice: [Int])
        /// A lap under repeat that starts at an unresolved row above the queue.
        case lapFromTop(head: [Int])
        /// A whole-collection shuffle reaching past the slice that happens to be loaded.
        case mixTail(head: [Int], tail: [Int])

        var ids: [Int] {
            switch self {
            case .refill(let slice), .front(_, let slice): slice
            case .lapFromTop(let head), .mixTail(let head, _): head
            }
        }
    }

    enum Outcome: Equatable {
        case applied
        /// The slice was taken, but none of it could be played or all of it was already queued.
        case nothingNew
        /// The queue moved while the slice resolved; nothing was changed.
        case stale
    }

    var refillStep: Step? {
        pendingIDs.isEmpty ? nil : .refill(slice: Array(pendingIDs.prefix(Self.refillSize)))
    }

    var frontStep: Step? {
        let fromLeading = !leadingIDs.isEmpty
        let source = fromLeading ? leadingIDs : pendingIDs
        return source.isEmpty ? nil : .front(fromLeading: fromLeading, slice: Array(source.suffix(Self.refillSize)))
    }

    var lapStep: Step? {
        leadingIDs.isEmpty ? nil : .lapFromTop(head: Array(leadingIDs.prefix(Self.refillSize)))
    }

    var mixStep: Step? {
        guard !pendingIDs.isEmpty, tracks.indices.contains(currentIndex) else { return nil }
        let mixed = (tracks[(currentIndex + 1)...].map(\.id) + pendingIDs).shuffled()
        let head = Array(mixed.prefix(Self.refillSize))
        return .mixTail(head: head, tail: Array(mixed.dropFirst(head.count)))
    }

    /// Ids of the step not already among the tracks ever resolved — a shuffle demotes resolved tracks
    /// back into the tail, and refetching them would also add them to `originalOrder` twice.
    func missing(for step: Step) -> [Int] {
        let known = Set(originalOrder.map(\.id))
        return step.ids.filter { !known.contains($0) }
    }

    mutating func apply(_ step: Step, resolved: [SCTrack]) -> Outcome {
        var known = Dictionary(originalOrder.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Go+ and region-locked tracks never enter the queue; their ids are spent like a deleted track's.
        for track in resolved where track.isPlayable { known[track.id] = track }
        let inQueue = Set(tracks.map(\.id))

        switch step {
        case .refill(let slice):
            // Spent only if the tail is still the one it was taken from: counting it as gone mid-flight
            // made the panel's total dip by fifty and come back.
            guard pendingIDs.starts(with: slice) else { return .stale }
            pendingIDs.removeFirst(slice.count)
            let fresh = slice.compactMap { known[$0] }.filter { !inQueue.contains($0.id) }
            guard !fresh.isEmpty else { return .nothingNew }
            tracks.append(contentsOf: fresh)
            remember(fresh)
            return .applied

        case .front(let fromLeading, let slice):
            // Next pressed or a refill taken from the same ids while this resolved: the front has moved.
            let source = fromLeading ? leadingIDs : pendingIDs
            guard currentIndex == 0, source.suffix(slice.count).elementsEqual(slice) else { return .stale }
            let front = slice.compactMap { known[$0] }.filter { !inQueue.contains($0.id) }
            guard !front.isEmpty else { return .nothingNew }
            if fromLeading { leadingIDs.removeLast(slice.count) } else { pendingIDs.removeLast(slice.count) }
            tracks.insert(contentsOf: front, at: 0)
            let seen = Set(originalOrder.map(\.id))
            originalOrder.insert(contentsOf: front.filter { !seen.contains($0.id) }, at: 0)
            currentIndex = front.count - 1
            return .applied

        case .lapFromTop(let head):
            guard leadingIDs.starts(with: head) else { return .stale }
            let lap = head.compactMap { known[$0] }
            guard !lap.isEmpty else { return .nothingNew }
            pendingIDs = Array(leadingIDs.dropFirst(head.count)) + tracks.map(\.id) + pendingIDs
            leadingIDs = []
            tracks = lap
            remember(lap)
            currentIndex = 0
            return .applied

        case .mixTail(let head, let tail):
            // Anchored on the live position, not the track it started from: Shuffle and then Next is
            // one gesture, and keying on the old track threw the whole new order away.
            guard isShuffled, let current else { return .stale }
            let mixed = head.compactMap { known[$0] }.filter { $0.id != current.id }
            guard !mixed.isEmpty else { return .nothingNew }
            tracks = Array(tracks[...currentIndex]) + mixed
            pendingIDs = tail
            remember(mixed)
            return .applied
        }
    }

    // Unshuffling rebuilds from `originalOrder`, so it has to keep every track ever resolved.
    private mutating func remember(_ fresh: [SCTrack]) {
        let seen = Set(originalOrder.map(\.id))
        originalOrder.append(contentsOf: fresh.filter { !seen.contains($0.id) })
    }
}
