#if DEBUG
import Foundation
import os

/// Answers one question: does the HLS path trim AAC priming for us, or hand the timeline over
/// literally? Two independent readings — what the container declares (`elst` in the init segment)
/// and what AVFoundation reports (item duration against the sum of `#EXTINF`). Their difference is
/// the trim actually applied.
nonisolated enum PrimingProbe {
    private static let log = Logger(subsystem: "io.github.dearonski.Nimbus", category: "priming")

    static func note(_ text: String) {
        log.info("\(text, privacy: .public)")
    }

    /// Total media time the playlist claims, summed off its `#EXTINF` lines.
    static func playlistDuration(_ lines: [String]) -> Double {
        lines.reduce(into: 0.0) { total, line in
            guard line.hasPrefix("#EXTINF:") else { return }
            let value = line.dropFirst("#EXTINF:".count).prefix { $0 != "," }
            total += Double(value) ?? 0
        }
    }

    /// Fetches the init segment and reports its edit list. A `media_time` of 0 (or no `elst` at
    /// all) means the container says nothing about priming, and any trim must come from a decoder
    /// default rather than from the file.
    static func inspectInitSegment(_ url: URL) async {
        guard let data = try? await URLSession.shared.data(from: url).0 else {
            note("init segment: fetch failed")
            return
        }
        note("init segment: \(data.count) bytes")

        guard let moov = box(named: "moov", in: data, from: 0, to: data.count) else {
            note("init segment: no moov")
            return
        }
        if let mvhd = box(named: "mvhd", in: data, from: moov.start, to: moov.end) {
            note("mvhd timescale: \(timescale(in: data, at: mvhd.start))")
        }
        guard let trak = box(named: "trak", in: data, from: moov.start, to: moov.end) else {
            note("init segment: no trak")
            return
        }
        if let mdia = box(named: "mdia", in: data, from: trak.start, to: trak.end),
           let mdhd = box(named: "mdhd", in: data, from: mdia.start, to: mdia.end) {
            note("mdhd timescale: \(timescale(in: data, at: mdhd.start))")
        }
        guard let edts = box(named: "edts", in: data, from: trak.start, to: trak.end),
              let elst = box(named: "elst", in: data, from: edts.start, to: edts.end) else {
            note("elst: absent — the container declares no edit list at all")
            return
        }
        describeEditList(in: data, at: elst.start, end: elst.end)
    }

    // MARK: - Minimal ISO-BMFF walk

    private static func box(named name: String, in data: Data, from: Int, to: Int) -> (start: Int, end: Int)? {
        var cursor = from
        while cursor + 8 <= to {
            let size = Int(be32(data, cursor))
            let type = String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
            // 0 means "to the end of file"; 1 means a 64-bit size follows, which init segments
            // this small never use.
            let end = size == 0 ? to : cursor + size
            guard size >= 8, end <= to else { return nil }
            if type == name { return (cursor + 8, end) }
            cursor = end
        }
        return nil
    }

    /// `timescale` sits at the same offset in both mvhd and mdhd: after version/flags and two
    /// timestamps, whose width the version selects.
    private static func timescale(in data: Data, at start: Int) -> UInt32 {
        let version = data[start]
        let offset = start + 4 + (version == 1 ? 16 : 8)
        return be32(data, offset)
    }

    private static func describeEditList(in data: Data, at start: Int, end: Int) {
        let version = data[start]
        let count = Int(be32(data, start + 4))
        var cursor = start + 8
        note("elst: version \(version), \(count) entr\(count == 1 ? "y" : "ies")")
        for index in 0..<count {
            guard cursor + (version == 1 ? 20 : 12) <= end else { return }
            let duration: UInt64
            let mediaTime: Int64
            if version == 1 {
                duration = be64(data, cursor)
                mediaTime = Int64(bitPattern: be64(data, cursor + 8))
                cursor += 20
            } else {
                duration = UInt64(be32(data, cursor))
                mediaTime = Int64(Int32(bitPattern: be32(data, cursor + 4)))
                cursor += 12
            }
            note("elst[\(index)]: segment_duration \(duration), media_time \(mediaTime)")
        }
    }

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func be64(_ data: Data, _ offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        return data[offset..<(offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
#endif
