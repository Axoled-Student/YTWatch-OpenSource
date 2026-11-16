//
//  NowPlayingSnapshot.swift
//  YTWatch
//
//  What the Watch app tells its widget: the current track, whether it's playing, where
//  it is, and what plays next (so the widget can show the following songs on its own,
//  without the app having to wake it for every track change).
//
//  Compiled into both the Watch app and the widget extension. The two share a file in
//  their App Group container.
//

import Foundation

struct NowPlayingSnapshot: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Hashable {
        var videoId: String
        var title: String
        var artist: String
        /// Seconds; 0 when unknown.
        var duration: Double
    }

    var current: Item?
    var isPlaying: Bool
    /// Playback position, in seconds, at `updatedAt`.
    var elapsed: Double
    var updatedAt: Date
    /// Tracks that will play after `current`, in order (a prediction: skipping or
    /// pausing makes the app write a fresh snapshot).
    var upNext: [Item]
    /// "speaker" or "headphones".
    var outputMode: String
    var playlistTitle: String?

    /// When position 0 of the current track was (or would have been) while playing.
    var trackStartDate: Date { updatedAt.addingTimeInterval(-elapsed) }

    /// Same content, ignoring the clock drifting forward while playing.
    func isEquivalent(to other: NowPlayingSnapshot) -> Bool {
        guard current == other.current, isPlaying == other.isPlaying,
              upNext == other.upNext, outputMode == other.outputMode,
              playlistTitle == other.playlistTitle else { return false }
        let expected = isPlaying
            ? elapsed + other.updatedAt.timeIntervalSince(updatedAt)
            : elapsed
        return abs(expected - other.elapsed) < 2
    }
}

/// The App Group container shared by the Watch app and its widget.
///
/// The group's name depends on how the app was signed. WatchBridge (isideload) appends
/// the team ID to every bundle ID and creates `group.<rewritten iPhone app ID>`, e.g.
/// `group.com.andre.ytwatch.app.ABCDE12345`; an Xcode build uses APP_GROUP_ID from
/// project.yml. Try each and use the first one this process is entitled to.
enum SharedContainer {
    static let groupIdentifier: String? = {
        var candidates: [String] = []
        if let id = Bundle.main.bundleIdentifier, let range = id.range(of: ".watchkitapp") {
            candidates.append("group." + id[..<range.lowerBound])
        }
        if let configured = Bundle.main.object(forInfoDictionaryKey: "YTAppGroupID") as? String,
           !configured.isEmpty, !configured.contains("$(") {
            candidates.append(configured)
        }
        return candidates.first {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
        }
    }()

    static var isAvailable: Bool { groupIdentifier != nil }

    private static var containerURL: URL? {
        guard let id = groupIdentifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    private static var snapshotURL: URL? {
        containerURL?.appendingPathComponent("nowplaying.json")
    }

    static var artworkDirectory: URL? {
        guard let dir = containerURL?.appendingPathComponent("Artwork", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func artworkURL(for videoId: String) -> URL? {
        artworkDirectory?.appendingPathComponent("\(videoId).jpg")
    }

    static func read() -> NowPlayingSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
    }

    static func write(_ snapshot: NowPlayingSnapshot) {
        guard let url = snapshotURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
