//
//  BoostRenderer.swift
//  YTWatch
//
//  Volume boost for the Watch speaker.
//
//  watchOS has no way to apply gain above 100% to AVPlayer's output (MediaToolbox audio
//  taps don't exist on watchOS), so the boost is rendered ahead of time instead: the song
//  is decoded, mixed to mono (the speaker is mono), amplified, run through a look-ahead
//  limiter so peaks are turned down smoothly instead of clipping, and written to a cache
//  file that AVPlayer then plays like any other. The next song is prepared while the
//  current one plays, so normally only the first boosted song waits a few seconds.
//

import Foundation
import AVFoundation

enum VolumeBoost: Int, CaseIterable, Identifiable {
    case off = 0, low = 3, medium = 6, high = 9, max = 12

    var id: Int { rawValue }
    var label: String { self == .off ? "Off" : "+\(rawValue) dB" }
    var shortLabel: String { self == .off ? "Off" : "+\(rawValue)" }
    var gain: Float { powf(10, Float(rawValue) / 20) }
}

@MainActor
final class BoostRenderer {

    static let shared = BoostRenderer()

    private var inflight: [String: Task<URL?, Never>] = [:]
    /// Renders run one at a time; each waits for the one before it.
    private var lastTask: Task<URL?, Never>?

    nonisolated static var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Boosted", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// "s2": speaker-tuned renders (high-pass + presence). Bump when the processing
    /// changes so old cached copies aren't reused.
    private static func key(_ videoId: String, _ boost: VolumeBoost) -> String {
        "\(videoId)_\(boost.rawValue)s2"
    }

    private static func fileURL(_ videoId: String, _ boost: VolumeBoost) -> URL {
        directory.appendingPathComponent(key(videoId, boost) + ".caf")
    }

    func cachedURL(videoId: String, boost: VolumeBoost) -> URL? {
        guard boost != .off else { return nil }
        let url = Self.fileURL(videoId, boost)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Render (or reuse) the boosted copy. `exclusive` cancels any other pending renders
    /// first — used for the song that has to play now, so skipping through several songs
    /// doesn't leave it queued behind renders nobody needs anymore.
    func render(videoId: String, source: URL, boost: VolumeBoost, exclusive: Bool = false) async -> URL? {
        guard boost != .off else { return source }
        if let url = cachedURL(videoId: videoId, boost: boost) { return url }
        let key = Self.key(videoId, boost)
        if exclusive {
            for (other, task) in inflight where other != key { task.cancel() }
        }
        if let existing = inflight[key] { return await existing.value }

        let dest = Self.fileURL(videoId, boost)
        let previous = lastTask
        let gain = boost.gain
        let task = Task.detached(priority: .userInitiated) { () -> URL? in
            _ = await previous?.value
            guard !Task.isCancelled else { return nil }
            let started = Date()
            let ok = BoostRenderer.renderFile(source: source, dest: dest, gain: gain)
            let seconds = Date().timeIntervalSince(started)
            await MainActor.run {
                WatchDiagnostics.shared.log("boost render \(ok ? "done" : "failed/cancelled") in \(String(format: "%.1f", seconds))s")
            }
            return ok ? dest : nil
        }
        inflight[key] = task
        lastTask = task
        let result = await task.value
        if inflight[key] == task { inflight[key] = nil }
        return result
    }

    /// Delete boosted copies of songs that aren't current or next.
    func prune(keeping videoIds: Set<String>) {
        let dir = Self.directory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in files {
            let base = (name as NSString).deletingPathExtension
            let videoId = base.split(separator: "_").dropLast().joined(separator: "_")
            let busy = inflight.keys.contains { base.hasPrefix($0) }
            if !videoIds.contains(videoId) && !busy {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    func clearAll() {
        for task in inflight.values { task.cancel() }
        try? FileManager.default.removeItem(at: Self.directory)
    }

    // MARK: - Rendering

    /// Decode → mono → gain + look-ahead limiter → 16-bit CAF. Runs off the main actor.
    nonisolated static func renderFile(source: URL, dest: URL, gain: Float) -> Bool {
        let part = dest.deletingPathExtension().appendingPathExtension("part").appendingPathExtension("caf")
        let fm = FileManager.default
        try? fm.removeItem(at: part)
        guard writeBoosted(source: source, to: part, gain: gain) else {
            try? fm.removeItem(at: part)
            return false
        }
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: part, to: dest)
            return true
        } catch {
            try? fm.removeItem(at: part)
            return false
        }
    }

    /// Separate function so the output AVAudioFile is released (and closed) on return.
    private nonisolated static func writeBoosted(source: URL, to url: URL, gain: Float) -> Bool {
        guard let input = try? AVAudioFile(forReading: source) else { return false }
        let inFormat = input.processingFormat
        let sampleRate = inFormat.sampleRate
        let channels = Int(inFormat.channelCount)
        guard channels > 0,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                             channels: 1, interleaved: false) else { return false }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let output = try? AVAudioFile(forWriting: url, settings: settings,
                                            commonFormat: .pcmFormatFloat32, interleaved: false) else { return false }

        let chunk: AVAudioFrameCount = 16_384
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
              let outBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunk),
              let dst = outBuf.floatChannelData?[0] else { return false }

        // Speaker tuning before the gain: the Watch speaker can't reproduce bass, but bass
        // carries most of a song's peak energy, so it makes the limiter turn everything
        // down. Cutting it (and lifting the 2–4 kHz range the ear is most sensitive to)
        // leaves the limiter far more room — louder and cleaner on this speaker.
        var highPass = Biquad.highPass(frequency: 320, q: 0.707, sampleRate: sampleRate)
        var highPass2 = Biquad.highPass(frequency: 320, q: 0.707, sampleRate: sampleRate)
        var presence = Biquad.peaking(frequency: 3000, q: 0.9, gainDB: 4, sampleRate: sampleRate)
        var limiter = LookaheadLimiter(sampleRate: sampleRate, gain: gain)
        // The limiter delays audio by its look-ahead; drop that many leading samples and
        // flush the same number at the end, so the copy lines up with the original exactly.
        var toSkip = limiter.lookahead
        let scale = 1 / Float(channels)

        while input.framePosition < input.length {
            if Task.isCancelled { return false }
            do { try input.read(into: inBuf, frameCount: chunk) } catch { return false }
            let n = Int(inBuf.frameLength)
            guard n > 0, let src = inBuf.floatChannelData else { break }
            var w = 0
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<channels { s += src[c][i] }
                let tuned = presence.process(highPass2.process(highPass.process(s * scale)))
                let y = limiter.process(tuned)
                if toSkip > 0 { toSkip -= 1; continue }
                dst[w] = y
                w += 1
            }
            guard w > 0 else { continue }
            outBuf.frameLength = AVAudioFrameCount(w)
            do { try output.write(from: outBuf) } catch { return false }
        }

        var remaining = limiter.lookahead - toSkip
        while remaining > 0 {
            let n = min(Int(chunk), remaining)
            for i in 0..<n { dst[i] = limiter.process(0) }
            outBuf.frameLength = AVAudioFrameCount(n)
            do { try output.write(from: outBuf) } catch { return false }
            remaining -= n
        }
        return true
    }
}

/// RBJ-cookbook biquad filter (direct form I).
struct Biquad {
    private let b0, b1, b2, a1, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    private init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = Float(b0 / a0); self.b1 = Float(b1 / a0); self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0); self.a2 = Float(a2 / a0)
    }

    static func highPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q), c = cos(w0)
        return Biquad(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2,
                      a0: 1 + alpha, a1: -2 * c, a2: 1 - alpha)
    }

    static func peaking(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q), c = cos(w0)
        return Biquad(b0: 1 + alpha * a, b1: -2 * c, b2: 1 - alpha * a,
                      a0: 1 + alpha / a, a1: -2 * c, a2: 1 - alpha / a)
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// Brick-wall limiter with 5 ms look-ahead. Gain reduction starts before a peak arrives
/// and eases back over ~100 ms, which keeps boosted audio from crackling.
struct LookaheadLimiter {
    let gain: Float
    let lookahead: Int
    private let ceiling: Float = 0.94
    private let attack: Float
    private let release: Float

    private var delay: [Float]
    private var delayIndex = 0
    // Sliding-window minimum of the gain each sample needs, as a monotonic deque.
    private var dqValue: [Float]
    private var dqIndex: [Int]
    private let capacity: Int
    private var head = 0
    private var count = 0
    private var n = 0
    private var envelope: Float = 1

    init(sampleRate: Double, gain: Float) {
        self.gain = gain
        lookahead = max(1, Int(sampleRate * 0.005))
        capacity = lookahead + 2
        delay = Array(repeating: 0, count: lookahead)
        dqValue = Array(repeating: 1, count: capacity)
        dqIndex = Array(repeating: 0, count: capacity)
        attack = 1 - expf(-4 / Float(lookahead))
        release = expf(-1 / Float(sampleRate * 0.1))
    }

    mutating func process(_ x: Float) -> Float {
        let magnitude = abs(x * gain)
        let needed: Float = magnitude > ceiling ? ceiling / magnitude : 1

        while count > 0 && dqValue[(head + count - 1) % capacity] >= needed { count -= 1 }
        let slot = (head + count) % capacity
        dqValue[slot] = needed
        dqIndex[slot] = n
        count += 1
        while dqIndex[head] < n - lookahead {
            head = (head + 1) % capacity
            count -= 1
        }

        let target = dqValue[head]
        if target < envelope {
            envelope += (target - envelope) * attack
        } else {
            envelope = target + (envelope - target) * release
        }

        let delayed = delay[delayIndex]
        delay[delayIndex] = x
        delayIndex = (delayIndex + 1) % lookahead
        n += 1

        let out = delayed * gain * envelope
        return min(ceiling, max(-ceiling, out))
    }
}
