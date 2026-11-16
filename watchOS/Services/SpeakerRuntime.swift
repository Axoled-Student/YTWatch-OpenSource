//
//  SpeakerRuntime.swift
//  YTWatch
//
//  Keeps the app running while it plays through the Watch's built-in speaker.
//
//  watchOS only lets third-party apps play long-form audio in the background over
//  Bluetooth. Speaker audio uses the default (short-form) session policy, which watchOS
//  stops as soon as the app is suspended — i.e. when the screen sleeps. A
//  WKExtendedRuntimeSession of the "physical-therapy" type (declared in WKBackgroundModes)
//  keeps the app running in the background, screen off, for up to an hour per session.
//
//  Limits that come from watchOS, not from this code:
//  - A session can only be started while the app is on screen. When one ends (about an
//    hour), raising the wrist and opening the app starts a fresh one.
//  - watchOS may end a session early (low battery, another runtime session, etc.).
//

import Foundation
import WatchKit

@MainActor
final class SpeakerRuntime: NSObject, ObservableObject {

    static let shared = SpeakerRuntime()

    /// True while a session is keeping the app alive in the background.
    @Published private(set) var isRunning = false
    /// When the running session will end, if watchOS told us.
    @Published private(set) var expiresAt: Date?
    /// Why the last session ended early, for display and diagnostics.
    @Published private(set) var lastEndReason: String?

    private var session: WKExtendedRuntimeSession?
    private var idleStop: Task<Void, Never>?

    /// How long a paused speaker session is kept alive so Play still works from the
    /// lock screen / Now Playing before we let watchOS suspend the app.
    private static let pausedGrace: UInt64 = 10 * 60

    /// Start (or keep) a session. Safe to call often; does nothing if one is running or
    /// if the app isn't in the foreground (watchOS refuses to start one then).
    func ensureRunning() {
        idleStop?.cancel()
        idleStop = nil
        if let s = session, s.state == .running || s.state == .scheduled { return }
        guard WKApplication.shared().applicationState == .active else {
            WatchDiagnostics.shared.log("speaker runtime: can't start while not in foreground")
            return
        }
        let s = WKExtendedRuntimeSession()
        s.delegate = self
        session = s
        s.start()
        WatchDiagnostics.shared.log("speaker runtime: starting session")
    }

    /// Paused: keep the app alive a little longer, then let it suspend.
    func scheduleStopAfterPause() {
        idleStop?.cancel()
        idleStop = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.pausedGrace * 1_000_000_000)
            guard !Task.isCancelled, let self, !WatchPlayer.shared.isPlaying else { return }
            self.stop()
        }
    }

    func stop() {
        idleStop?.cancel()
        idleStop = nil
        if let s = session, s.state == .running || s.state == .scheduled {
            s.invalidate()
        }
        session = nil
        isRunning = false
        expiresAt = nil
    }

    fileprivate func didStart(_ s: WKExtendedRuntimeSession) {
        guard s === session else { return }
        isRunning = true
        expiresAt = s.expirationDate
        lastEndReason = nil
        WatchDiagnostics.shared.log("speaker runtime: running until \(s.expirationDate.map { "\($0)" } ?? "unknown")")
    }

    fileprivate func willExpire(_ s: WKExtendedRuntimeSession) {
        guard s === session else { return }
        WatchDiagnostics.shared.log("speaker runtime: about to expire")
        // One gentle tap so the wearer knows to raise their wrist to keep the music going.
        WKInterfaceDevice.current().play(.notification)
    }

    fileprivate func didInvalidate(_ s: WKExtendedRuntimeSession, reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        guard s === session else { return }
        session = nil
        isRunning = false
        expiresAt = nil
        let text: String
        switch reason {
        case .none: text = "stopped"
        case .sessionInProgress: text = "another app's session is running"
        case .expired: text = "time limit reached — open YTWatch to continue"
        case .resignedFrontmost: text = "app left the screen before the session started"
        case .suppressedBySystem: text = "watchOS suppressed it (low power?)"
        case .error: text = "error: \(error?.localizedDescription ?? "unknown")"
        @unknown default: text = "ended"
        }
        if reason != .none { lastEndReason = text }
        WatchDiagnostics.shared.log("speaker runtime ended: \(text)")
    }
}

extension SpeakerRuntime: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        nonisolated(unsafe) let s = extendedRuntimeSession
        Task { @MainActor in SpeakerRuntime.shared.didStart(s) }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        nonisolated(unsafe) let s = extendedRuntimeSession
        Task { @MainActor in SpeakerRuntime.shared.willExpire(s) }
    }

    nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                            error: Error?) {
        nonisolated(unsafe) let s = extendedRuntimeSession
        Task { @MainActor in SpeakerRuntime.shared.didInvalidate(s, reason: reason, error: error) }
    }
}
