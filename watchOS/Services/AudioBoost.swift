//
//  AudioBoost.swift
//  YTWatch
//
//  Software volume boost beyond what AVPlayer.volume (max 1.0) allows.
//
//  An MTAudioProcessingTap sits in the AVPlayerItem's audio mix and multiplies every
//  sample by `gain`. Plain multiplication would clip loud passages harshly, so samples
//  above a knee are squeezed with tanh instead: quiet and normal parts get the full
//  boost, peaks are rounded off rather than flattened.
//
//  The tap is only attached while a boost is selected; at 1x the item plays untouched.
//

import Foundation
import AVFoundation
import MediaToolbox

enum VolumeBoost: Double, CaseIterable, Identifiable {
    case off = 1.0
    case low = 1.5
    case medium = 2.0
    case high = 3.0

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .low: return "1.5×"
        case .medium: return "2×"
        case .high: return "3×"
        }
    }
}

/// State shared with the real-time audio thread. Only plain values, read once per buffer;
/// a stale read for one buffer (~10 ms) after a change is harmless.
final class AudioBoostState: @unchecked Sendable {
    static let shared = AudioBoostState()
    var gain: Float = 1.0
    var isFloat32 = false
}

enum AudioBoost {

    /// Attach (or detach) the boost tap on `item` for the current gain.
    @MainActor
    static func apply(to item: AVPlayerItem, boost: VolumeBoost) {
        AudioBoostState.shared.gain = Float(boost.rawValue)
        guard boost != .off else {
            item.audioMix = nil
            return
        }
        if item.audioMix != nil { return } // already tapped; the gain change is live

        // Local files: the track list is already loaded, so this doesn't block on I/O
        // worth mentioning. (The async loader needs a non-Sendable hop under Swift 6.)
        guard let track = item.asset.tracks(withMediaType: .audio).first,
              let tap = makeTap() else {
            WatchDiagnostics.shared.log("volume boost: couldn't attach tap")
            return
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
        WatchDiagnostics.shared.log("volume boost: \(boost.label)")
    }

    // nonisolated: the callbacks become C function pointers and must not inherit an actor.
    private nonisolated static func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: nil,
            init: { _, _, tapStorageOut in
                tapStorageOut.pointee = nil
            },
            finalize: { _ in },
            prepare: { _, _, format in
                let asbd = format.pointee
                AudioBoostState.shared.isFloat32 =
                    asbd.mFormatID == kAudioFormatLinearPCM
                    && (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                    && asbd.mBitsPerChannel == 32
            },
            unprepare: { _ in },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }
                let state = AudioBoostState.shared
                let gain = state.gain
                guard state.isFloat32, gain > 1.001 else { return }

                // Below the knee: linear gain. Above it: tanh rounds the peak off so the
                // result never exceeds 1.0 and never clips with a hard edge.
                let knee: Float = 0.7
                let headroom: Float = 1.0 - knee
                for buffer in UnsafeMutableAudioBufferListPointer(bufferListInOut) {
                    guard let data = buffer.mData else { continue }
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<count {
                        let x = samples[i] * gain
                        let mag = abs(x)
                        if mag > knee {
                            let squeezed = knee + headroom * tanhf((mag - knee) / headroom)
                            samples[i] = x < 0 ? -squeezed : squeezed
                        } else {
                            samples[i] = x
                        }
                    }
                }
            }
        )
        var tap: MTAudioProcessingTap?
        let err = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard err == noErr else { return nil }
        return tap
    }
}
