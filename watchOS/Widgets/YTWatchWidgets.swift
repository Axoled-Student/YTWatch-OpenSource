//
//  YTWatchWidgets.swift
//  YTWatch Watch Widgets
//
//  Now Playing widget for the Smart Stack and watch faces: song, artist, artwork and a
//  progress bar that moves on its own (WidgetKit animates timer-based progress views, so
//  the app doesn't have to wake the widget every second).
//
//  The app writes a NowPlayingSnapshot to the shared App Group container; see
//  WidgetPublisher. While playing, the snapshot includes the next few tracks, and the
//  timeline below schedules an entry for each predicted track change.
//

import SwiftUI
import WidgetKit

private let accent = Color(red: 1.0, green: 0.09, blue: 0.27) // matches Color.ytRed
private let nowPlayingURL = URL(string: "ytwatch://nowplaying")

// MARK: - Timeline

struct NowPlayingEntry: TimelineEntry {
    enum State { case playing, paused, empty }

    let date: Date
    let state: State
    let item: NowPlayingSnapshot.Item?
    /// Playing: when position 0 of the track was. Paused: unused.
    let trackStart: Date
    /// Paused: the position to show.
    let pausedElapsed: Double
    let outputMode: String
    let relevance: TimelineEntryRelevance?

    var duration: Double { item?.duration ?? 0 }

    var trackEnd: Date? {
        guard duration > 0 else { return nil }
        return trackStart.addingTimeInterval(duration)
    }

    static func empty(_ date: Date) -> NowPlayingEntry {
        NowPlayingEntry(date: date, state: .empty, item: nil, trackStart: date,
                        pausedElapsed: 0, outputMode: "headphones",
                        relevance: TimelineEntryRelevance(score: 0))
    }

    static func paused(_ date: Date, item: NowPlayingSnapshot.Item, elapsed: Double, mode: String) -> NowPlayingEntry {
        NowPlayingEntry(date: date, state: .paused, item: item, trackStart: date,
                        pausedElapsed: elapsed, outputMode: mode,
                        relevance: TimelineEntryRelevance(score: 5))
    }

    // Computed: TimelineEntryRelevance isn't Sendable, so a stored static would trip
    // Swift 6's global-state check.
    static var sample: NowPlayingEntry {
        NowPlayingEntry(
            date: .now, state: .playing,
            item: .init(videoId: "", title: "Song Title", artist: "Artist", duration: 200),
            trackStart: .now.addingTimeInterval(-70), pausedElapsed: 0, outputMode: "speaker",
            relevance: nil)
    }
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        let timeline = Self.timeline(from: SharedContainer.read(), now: .now)
        let first = timeline.entries.first
        completion(first?.state == .empty && context.isPreview ? .sample : (first ?? .sample))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(Self.timeline(from: SharedContainer.read(), now: .now))
    }

    /// One entry per (predicted) track, then a "stopped" entry when the prediction runs
    /// out — so a widget whose app was suspended doesn't show a full bar forever.
    static func timeline(from snap: NowPlayingSnapshot?, now: Date) -> Timeline<NowPlayingEntry> {
        guard let snap, let current = snap.current else {
            return Timeline(entries: [.empty(now)], policy: .never)
        }
        guard snap.isPlaying else {
            return Timeline(entries: [.paused(now, item: current, elapsed: snap.elapsed, mode: snap.outputMode)],
                            policy: .never)
        }

        let queue = [current] + snap.upNext
        var start = snap.trackStartDate
        var index = 0
        // Skip tracks the prediction says have already finished.
        while index < queue.count, queue[index].duration > 0,
              start.addingTimeInterval(queue[index].duration) <= now {
            start = start.addingTimeInterval(queue[index].duration)
            index += 1
        }
        guard index < queue.count else {
            let last = queue[queue.count - 1]
            return Timeline(entries: [.paused(now, item: last, elapsed: last.duration, mode: snap.outputMode)],
                            policy: .never)
        }

        var entries: [NowPlayingEntry] = []
        for i in index..<queue.count {
            let item = queue[i]
            let end = item.duration > 0 ? start.addingTimeInterval(item.duration) : nil
            entries.append(NowPlayingEntry(
                date: i == index ? now : start,
                state: .playing, item: item, trackStart: start, pausedElapsed: 0,
                outputMode: snap.outputMode,
                relevance: TimelineEntryRelevance(
                    score: 100, duration: end.map { $0.timeIntervalSince(max(now, start)) } ?? 600)))
            guard let end else { break } // can't predict past a track of unknown length
            start = end
            if entries.count >= 12 { break }
        }
        if let last = entries.last, let end = last.trackEnd, let item = last.item {
            entries.append(.paused(end, item: item, elapsed: item.duration, mode: snap.outputMode))
        }
        return Timeline(entries: entries, policy: .never)
    }
}

// MARK: - Views

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: CircularView(entry: entry)
            case .accessoryCorner: CornerView(entry: entry)
            case .accessoryInline: InlineView(entry: entry)
            default: RectangularView(entry: entry)
            }
        }
        .widgetURL(nowPlayingURL)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [accent.opacity(0.45), Color(white: 0.06)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

private struct RectangularView: View {
    let entry: NowPlayingEntry

    var body: some View {
        if let item = entry.item {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Artwork(videoId: item.videoId, size: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .widgetAccentable()
                        Text(item.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Progress(entry: entry)
                HStack(spacing: 4) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 9, weight: .bold))
                    Text(entry.state == .playing ? "Playing" : "Paused")
                    Spacer(minLength: 0)
                    Remaining(entry: entry)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(accent)
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text("YTWatch").font(.system(size: 14, weight: .semibold))
                    Text("Nothing playing")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var statusSymbol: String {
        guard entry.state == .playing else { return "pause.fill" }
        return entry.outputMode == "speaker" ? "speaker.wave.2.fill" : "headphones"
    }
}

private struct CircularView: View {
    let entry: NowPlayingEntry

    var body: some View {
        if entry.state == .playing, let end = entry.trackEnd {
            ProgressView(timerInterval: entry.trackStart...end, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                Image(systemName: "music.note").font(.system(size: 16, weight: .semibold))
            }
            .progressViewStyle(.circular)
            .tint(accent)
        } else {
            Gauge(value: fraction) {
                EmptyView()
            } currentValueLabel: {
                Image(systemName: entry.item == nil ? "music.note" : "pause.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(accent)
        }
    }

    private var fraction: Double {
        entry.duration > 0 ? min(1, entry.pausedElapsed / entry.duration) : 0
    }
}

private struct CornerView: View {
    let entry: NowPlayingEntry

    var body: some View {
        Image(systemName: entry.state == .playing ? "music.note" : "pause.fill")
            .font(.system(size: 20, weight: .semibold))
            .widgetAccentable()
            .widgetLabel {
                if entry.state == .playing, let end = entry.trackEnd {
                    ProgressView(timerInterval: entry.trackStart...end, countsDown: false)
                        .tint(accent)
                } else if let item = entry.item {
                    Text(item.title)
                } else {
                    Text("YTWatch")
                }
            }
    }
}

private struct InlineView: View {
    let entry: NowPlayingEntry

    var body: some View {
        if let item = entry.item {
            Label(item.title, systemImage: entry.state == .playing ? "music.note" : "pause.fill")
        } else {
            Label("YTWatch", systemImage: "music.note")
        }
    }
}

/// A progress bar the system animates by itself while playing.
private struct Progress: View {
    let entry: NowPlayingEntry

    var body: some View {
        Group {
            if entry.state == .playing, let end = entry.trackEnd {
                ProgressView(timerInterval: entry.trackStart...end, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: entry.duration > 0 ? min(entry.pausedElapsed, entry.duration) : 0,
                             total: max(entry.duration, 1))
            }
        }
        .progressViewStyle(.linear)
        .tint(accent)
    }
}

/// Time left, counting down by itself while playing.
private struct Remaining: View {
    let entry: NowPlayingEntry

    var body: some View {
        if entry.state == .playing, let end = entry.trackEnd {
            Text(end, style: .timer)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 52, alignment: .trailing)
        } else if entry.duration > 0 {
            Text("−" + clock(max(0, entry.duration - entry.pausedElapsed)))
                .monospacedDigit()
        }
    }
}

private struct Artwork: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let videoId: String
    let size: CGFloat

    var body: some View {
        if renderingMode == .fullColor,
           let url = SharedContainer.artworkURL(for: videoId),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: size * 0.45, weight: .semibold))
                .frame(width: size, height: size)
                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .widgetAccentable()
        }
    }
}

private func clock(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let whole = Int(seconds)
    return "\(whole / 60):\(String(format: "%02d", whole % 60))"
}

// MARK: - Widget

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("The song playing in YTWatch, with its progress.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

@main
struct YTWatchWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
    }
}
