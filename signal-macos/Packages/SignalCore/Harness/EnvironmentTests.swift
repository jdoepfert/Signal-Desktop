// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

private func toolsURL(_ name: String) -> URL {
    // Harness/EnvironmentTests.swift -> Harness -> SignalCore -> Packages
    //   -> signal-macos, then down into Tools/.
    URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Tools")
        .appending(path: name)
}

func runPinVersionsFormatTests() {
    do {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [toolsURL("pin-versions.sh").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PinVersionsError.scriptFailed(process.terminationStatus)
        }
        let output =
            String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        var pins = [String: String]()
        for part in output.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                pins[String(kv[0])] = String(kv[1])
            }
        }
        check(
            "EnvironmentTests.testPinVersionsFormat",
            !(pins["libsignal"] ?? "").isEmpty
                && !(pins["ringrtc"] ?? "").isEmpty
                && !(pins["webrtc"] ?? "").isEmpty,
            output
        )
    } catch {
        check("EnvironmentTests.testPinVersionsFormat", false, "\(error)")
    }
}

private enum PinVersionsError: Error {
    case scriptFailed(Int32)
}
