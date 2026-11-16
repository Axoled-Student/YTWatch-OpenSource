import SwiftUI
import WatchKit

/// Now Playing, in three states:
/// - Normal: artwork backdrop, big transport controls; swipe up for options.
/// - Dimmed: shown automatically when the wrist is down (Always On) and on demand via the
///   moon button. Black, low-contrast, nothing animating, so it costs little battery and
///   watchOS keeps the app frontmost instead of returning to the watch face.
struct NowPlayingScreen: View {
    @ObservedObject private var player = WatchPlayer.shared
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var darkScreen = false

    var body: some View {
        Group {
            if isLuminanceReduced || darkScreen {
                DimNowPlaying()
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { darkScreen = false } }
            } else {
                TabView {
                    NowPlayingMainPage(darkScreen: $darkScreen)
                    NowPlayingOptionsPage()
                }
                .tabViewStyle(.verticalPage)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(darkScreen ? .hidden : .automatic, for: .navigationBar)
        .persistentSystemOverlays(darkScreen ? .hidden : .automatic)
    }
}

// MARK: - Main page

private struct NowPlayingMainPage: View {
    @ObservedObject private var player = WatchPlayer.shared
    @Binding var darkScreen: Bool

    var body: some View {
        // The backdrop goes in .background so its ignoresSafeArea() can't widen the
        // controls past the rounded screen edges (it did when it was a ZStack sibling).
        Group {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ArtworkThumb(videoId: player.currentTrack?.videoId, size: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(player.currentTrack?.title ?? "Nothing playing")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let artist = player.currentTrack?.artist {
                            Text(artist)
                                .font(.system(size: 11))
                                .foregroundStyle(Color(white: 0.65))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }

                PlaybackProgress()

                HStack(spacing: 0) {
                    TransportButton(symbol: "backward.fill", size: 18) { player.previous() }
                        .accessibilityLabel("Previous track")
                    Spacer(minLength: 0)
                    Button { player.togglePlayPause() } label: {
                        ZStack {
                            Circle().fill(Color.ytRed)
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: player.isPlaying ? 0 : 2)
                        }
                        .frame(width: 54, height: 54)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    Spacer(minLength: 0)
                    TransportButton(symbol: "forward.fill", size: 18) { player.next() }
                        .accessibilityLabel("Next track")
                }
                .padding(.horizontal, 6)

                HStack(spacing: 6) {
                    OutputChip()
                    Spacer(minLength: 0)
                    // Tap, then turn the Digital Crown.
                    SystemVolumeControl()
                        .frame(width: 30, height: 30)
                        .accessibilityLabel("Volume")
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { darkScreen = true }
                    } label: {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(white: 0.75))
                            .frame(width: 32, height: 26)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dark screen")
                }

                if let error = player.error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.leading, 6)
            // Room for the vertical page indicator on the trailing edge.
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ArtworkBackdrop(videoId: player.currentTrack?.videoId)
        }
    }
}

private struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Tap to flip between headphones and the built-in speaker.
private struct OutputChip: View {
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        Button {
            player.setOutputMode(player.outputMode == .speaker ? .headphones : .speaker)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: player.outputMode.sfSymbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(player.outputMode == .speaker ? "Speaker" : "Headphones")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(player.outputMode == .speaker ? Color.ytRed : Color(white: 0.8))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                (player.outputMode == .speaker ? Color.ytRed.opacity(0.18) : Color.white.opacity(0.12)),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Audio output: \(player.outputMode.label). Tap to switch.")
    }
}

// MARK: - Options page

private struct NowPlayingOptionsPage: View {
    @ObservedObject private var player = WatchPlayer.shared
    @ObservedObject private var runtime = SpeakerRuntime.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // The back button floats over the top of this page.
                Color.clear.frame(height: 22)
                OptionLabel("Output")
                HStack(spacing: 6) {
                    OutputOption(mode: .headphones)
                    OutputOption(mode: .speaker)
                }

                if player.outputMode == .speaker {
                    Text(speakerStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }

                OptionLabel("Volume")
                HStack(spacing: 10) {
                    SystemVolumeControl()
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(player.outputMode == .speaker ? "Watch speaker" : "Headphones")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Tap, then turn the Digital Crown")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                OptionLabel("Playback")
                HStack(spacing: 6) {
                    ToggleTile(symbol: "shuffle", title: "Shuffle", isOn: player.isShuffled) {
                        player.toggleShuffle()
                    }
                    ToggleTile(symbol: player.repeatMode.sfSymbol,
                               title: player.repeatMode == .one ? "Repeat One" : "Repeat",
                               isOn: player.repeatMode != .none) {
                        player.toggleRepeat()
                    }
                }

                NavigationLink(destination: SleepTimerView()) {
                    OptionRow(symbol: "moon.zzz.fill", title: "Sleep Timer")
                }
                .buttonStyle(.plain)

                NavigationLink(destination: WatchKit.NowPlayingView()) {
                    OptionRow(symbol: "dial.medium", title: "System Controls")
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12) // clear of the page indicator
        }
    }

    private var speakerStatus: String {
        if runtime.isRunning {
            if let end = runtime.expiresAt {
                return "Keeps playing with the screen off until \(end.formatted(date: .omitted, time: .shortened)). Open YTWatch to extend."
            }
            return "Keeps playing with the screen off."
        }
        if let reason = runtime.lastEndReason {
            return "Background play ended: \(reason)."
        }
        return "Press Play while the app is open to keep playing with the screen off (up to 1 hour)."
    }
}

private struct OptionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color(white: 0.45))
            .textCase(.uppercase)
            .padding(.top, 2)
    }
}

private struct OutputOption: View {
    @ObservedObject private var player = WatchPlayer.shared
    let mode: AudioOutputMode

    var body: some View {
        let selected = player.outputMode == mode
        Button { player.setOutputMode(mode) } label: {
            VStack(spacing: 3) {
                Image(systemName: mode.sfSymbol)
                    .font(.system(size: 15, weight: .semibold))
                Text(mode == .speaker ? "Speaker" : "Headphones")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? .white : Color(white: 0.55))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(selected ? Color.ytRed : Color(white: 0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ToggleTile: View {
    let symbol: String
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(isOn ? .white : Color(white: 0.55))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isOn ? Color.ytRed : Color(white: 0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct OptionRow: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ytRed)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(white: 0.3))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The system volume control for the current route — Watch speaker volume in Speaker
/// mode, headphone volume otherwise. Turn the Digital Crown while it's focused.
private struct SystemVolumeControl: WKInterfaceObjectRepresentable {
    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        WKInterfaceVolumeControl(origin: .local)
    }

    func updateWKInterfaceObject(_ wkInterfaceObject: WKInterfaceVolumeControl, context: Context) {}
}

// MARK: - Dimmed (Always On / dark screen)

private struct DimNowPlaying: View {
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 6) {
                Image(systemName: player.isPlaying ? player.outputMode.sfSymbol : "pause.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(white: 0.35))
                Text(player.currentTrack?.title ?? "Nothing playing")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(white: 0.55))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let artist = player.currentTrack?.artist {
                    Text(artist)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.35))
                        .lineLimit(1)
                }
                if player.duration > 0 {
                    Text("−" + clock(max(0, player.duration - player.currentTime)))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(white: 0.3))
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

// MARK: - Shared pieces

private struct PlaybackProgress: View {
    @ObservedObject private var player = WatchPlayer.shared

    private var duration: Double {
        player.duration.isFinite ? min(max(0, player.duration), 100_000_000) : 0
    }

    private var time: Double {
        player.currentTime.isFinite ? min(max(0, player.currentTime), duration) : 0
    }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(Color.ytRed)
                        .frame(width: duration > 0 ? geo.size.width * time / duration : 0)
                }
            }
            .frame(height: 4)
            HStack {
                Text(clock(time))
                Spacer()
                Text("−" + clock(max(0, duration - time)))
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(Color(white: 0.55))
        }
    }
}

private struct ArtworkThumb: View {
    let videoId: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let videoId, let img = WatchThumbnailCache.shared.image(for: videoId) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(white: 0.15)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.35, weight: .medium))
                        .foregroundStyle(Color(white: 0.4))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ArtworkBackdrop: View {
    let videoId: String?

    var body: some View {
        ZStack {
            Color.black
            if let videoId, let img = WatchThumbnailCache.shared.image(for: videoId) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 18)
                    .opacity(0.45)
            }
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

private func clock(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let whole = Int(seconds)
    return "\(whole / 60):\(String(format: "%02d", whole % 60))"
}
