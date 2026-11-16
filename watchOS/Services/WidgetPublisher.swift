//
//  WidgetPublisher.swift
//  YTWatch
//
//  Keeps the Smart Stack / complication widget in step with the player.
//
//  The player calls `schedule()` whenever its state changes. Calls are coalesced, and
//  nothing is written or reloaded unless what the widget shows actually changed — the
//  widget animates its own progress bar from the start time, so a playing track needs
//  no updates until it is paused, skipped or seeked.
//

import Foundation
import UIKit
import ImageIO
import WidgetKit

@MainActor
final class WidgetPublisher {

    static let shared = WidgetPublisher()

    private var pending: Task<Void, Never>?
    private var lastPublished: NowPlayingSnapshot?
    private var loggedUnavailable = false

    /// How many upcoming tracks to hand the widget, so it can show them on schedule.
    private static let upNextCount = 10
    private static let artworkPixels: CGFloat = 120

    func schedule() {
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self else { return }
            self.pending = nil
            self.publish()
        }
    }

    /// Write now, e.g. right before the app may be suspended.
    func publishNow() {
        pending?.cancel()
        pending = nil
        publish()
    }

    private func publish() {
        guard SharedContainer.isAvailable else {
            if !loggedUnavailable {
                loggedUnavailable = true
                WatchDiagnostics.shared.log("widget: no App Group container — widget can't show playback")
            }
            return
        }
        let snapshot = WatchPlayer.shared.widgetSnapshot(upNextCount: Self.upNextCount)
        if let last = lastPublished, last.isEquivalent(to: snapshot) { return }

        var ids: [String] = []
        if let current = snapshot.current { ids.append(current.videoId) }
        ids.append(contentsOf: snapshot.upNext.map(\.videoId))
        exportArtwork(for: ids)

        SharedContainer.write(snapshot)
        lastPublished = snapshot
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Small copies of the thumbnails, in the shared container the widget can read.
    private func exportArtwork(for videoIds: [String]) {
        guard let dir = SharedContainer.artworkDirectory else { return }
        let fm = FileManager.default
        let wanted = Set(videoIds)

        for id in videoIds {
            let dest = dir.appendingPathComponent("\(id).jpg")
            if fm.fileExists(atPath: dest.path) { continue }
            guard let source = WatchFileReceiver.shared.thumbnailURL(for: id),
                  let data = Self.smallJPEG(from: source) else { continue }
            try? data.write(to: dest, options: .atomic)
        }

        // Keep the folder small: drop artwork for tracks no longer current or upcoming.
        if let files = try? fm.contentsOfDirectory(atPath: dir.path), files.count > wanted.count + 20 {
            for name in files where !wanted.contains((name as NSString).deletingPathExtension) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    private static func smallJPEG(from url: URL) -> Data? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: artworkPixels
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.75)
    }
}

extension WatchPlayer {
    func widgetSnapshot(upNextCount: Int) -> NowPlayingSnapshot {
        func item(_ t: Track, duration: Double? = nil) -> NowPlayingSnapshot.Item {
            NowPlayingSnapshot.Item(
                videoId: t.videoId, title: t.title, artist: t.artist,
                duration: duration ?? Double(max(0, t.durationSeconds)))
        }
        let current = currentTrack.map { t in
            item(t, duration: duration.isFinite && duration > 0 ? duration : nil)
        }
        var next: [NowPlayingSnapshot.Item]
        if repeatMode == .one, let current {
            next = Array(repeating: current, count: 3)
        } else {
            next = upNextTracks.prefix(upNextCount).map { item($0) }
        }
        if !isPlaying { next = [] } // nothing plays on its own while paused
        return NowPlayingSnapshot(
            current: current,
            isPlaying: isPlaying && current != nil,
            elapsed: currentTime.isFinite ? max(0, currentTime) : 0,
            updatedAt: Date(),
            upNext: next,
            outputMode: outputMode.rawValue,
            playlistTitle: currentPlaylist?.title
        )
    }
}
