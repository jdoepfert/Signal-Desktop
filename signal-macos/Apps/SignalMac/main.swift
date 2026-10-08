// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalApp
import SwiftUI

// GUI entry: resolves the environment (CLI `--production` or SIGNAL_ENV,
// default staging) and hosts the content view. Real store/net wiring
// happens in AppState after linking.
@main
struct SignalMacApp: App {
    @StateObject private var state: AppState = {
        let environment = (try? AppEnvironment.resolve(
            arguments: Array(CommandLine.arguments.dropFirst()),
            environment: ProcessInfo.processInfo.environment
        )) ?? .staging
        return AppState(environment: environment)
    }()

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
        }
        .commands {
            SidebarCommands()
        }
    }
}
