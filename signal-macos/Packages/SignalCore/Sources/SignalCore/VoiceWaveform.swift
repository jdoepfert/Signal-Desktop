// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Voice-note waveform accumulator, ported line for line from Desktop's
/// `ts/util/waveformBuilder.std.ts` (wire cap: `audioWaveform`, 100 bytes).
/// Pure Swift with no platform imports: Linux-safe.
public struct VoiceWaveform: Sendable {
    public static let maxEntries = 100
    private static let halfSize = maxEntries / 2

    private var waveform = [Double](repeating: 0, count: maxEntries)
    private var length = 0
    private var shift = 0

    public init() {}

    public mutating func push(_ sample: Float) {
        var index = length >> shift
        if index >= Self.maxEntries {
            for i in 0..<Self.halfSize {
                waveform[i] = (waveform[i * 2] + waveform[i * 2 + 1]) / 2
            }
            for i in Self.halfSize..<Self.maxEntries {
                waveform[i] = 0
            }
            shift += 1
            index = Self.halfSize
        }
        waveform[index] += Double(sample * sample) / Double(1 << shift)
        length += 1
    }

    /// Peaks oldest-first, at most `maxEntries`. Unlike Desktop (whose
    /// last-sample normalization writes back into the accumulator), this
    /// normalizes a copy, so repeated calls agree with each other.
    public func collect() -> [UInt8] {
        var entries = waveform
        var count = length >> shift
        let lastSamples = length % (1 << shift)
        if lastSamples != 0 {
            entries[count] = (entries[count] * Double(1 << shift)) / Double(lastSamples)
            count += 1
        }
        return (0..<count).map { voicePeak(meanSquare: entries[$0]) }
    }
}

/// Mean-square → 0–255 peak (Desktop `toPeak`: dB scale, −60 dB noise bed).
public func voicePeak(meanSquare: Double) -> UInt8 {
    let scaled = max(0, 10 * log10(meanSquare) + 60) / 60
    return UInt8(clamping: Int((scaled * 255).rounded()))
}
