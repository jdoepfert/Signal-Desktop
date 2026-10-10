// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalCore

func runVoiceTests() {
    // Empty input collects nothing.
    do {
        let builder = VoiceWaveform()
        check(
            "VoiceTests.testVoiceWaveformEmpty",
            builder.collect().isEmpty
        )
    }

    // Short input matches Desktop exactly (waveformBuilder_test.std.ts).
    do {
        var builder = VoiceWaveform()
        for i in 0..<10 {
            builder.push(Float(i) / 10)
        }
        check(
            "VoiceTests.testVoiceWaveformShortMatchesDesktop",
            builder.collect() == [0, 170, 196, 211, 221, 229, 236, 242, 247, 251]
        )
    }

    // 199 samples compact exactly like Desktop (same test file, lines 29-47).
    do {
        var builder = VoiceWaveform()
        for i in 0..<199 {
            builder.push(Float(i % 10) / 10)
        }
        let collected = builder.collect()
        let expected: [UInt8] = [
            157, 205, 226, 239, 249, 157, 205, 226, 239, 249,
            157, 205, 226, 239, 249, 157, 205, 226, 239, 249,
            157, 205, 226, 239, 249, 157, 205, 226, 239, 249,
            157, 205, 226, 239, 249, 157, 205, 226, 239, 249,
            157, 205, 226, 239, 249, 157, 205, 226, 239, 249,
            157, 205, 226, 239, 249, 157, 205, 226, 239, 249,
            157, 205, 226, 239, 249, 157, 205, 226, 239, 249,
            157, 205, 226, 239, 249, 157, 205, 226, 239, 249,
            157, 205, 226, 239, 249, 157, 205, 226, 239, 249,
            157, 205, 226, 239, 249, 157, 205, 226, 239, 247,
        ]
        check(
            "VoiceTests.testVoiceWaveformCompactionMatchesDesktop",
            collected == expected && collected.count <= VoiceWaveform.maxEntries,
            "count=\(collected.count)"
        )
    }

    // Peak mapping endpoints and monotonicity.
    do {
        let zero = voicePeak(meanSquare: 0)
        let one = voicePeak(meanSquare: 1)
        let small = voicePeak(meanSquare: 0.01)
        let mid = voicePeak(meanSquare: 0.1)
        check(
            "VoiceTests.testVoicePeakMapping",
            zero == 0 && one == 255 && small < mid && mid < one,
            "zero=\(zero) small=\(small) mid=\(mid) one=\(one)"
        )
    }
}
