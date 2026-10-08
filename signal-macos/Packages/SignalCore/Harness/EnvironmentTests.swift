// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalApp

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

func runBootstrapTests() {
    do {
        let def = try AppEnvironment.resolve(arguments: [], environment: [:])
        let prod = try AppEnvironment.resolve(arguments: ["--production"], environment: [:])
        let viaEnv = try AppEnvironment.resolve(arguments: [], environment: ["SIGNAL_ENV": "production"])
        check(
            "EnvironmentTests.testResolve",
            def == .staging && prod == .production && viaEnv == .production
        )
    } catch {
        check("EnvironmentTests.testResolve", false, "\(error)")
    }

    do {
        _ = try AppEnvironment.resolve(arguments: [], environment: ["SIGNAL_ENV": "canary"])
        check("EnvironmentTests.testResolveUnknown", false, "no error thrown")
    } catch {
        check("EnvironmentTests.testResolveUnknown", true)
    }
}
