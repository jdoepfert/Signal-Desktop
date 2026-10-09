// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import SwiftUI

/// Composer text state. A separate object (rather than `@State`) because
/// the SwiftUI macro plugin is unavailable without full Xcode.
public final class ComposerState: ObservableObject {
    @Published public var text = ""
    public var onSend: (String) -> Void = { _ in }
    public var onAttach: () -> Void = {}

    public init() {}

    public func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        text = ""
        onSend(trimmed)
    }

    public func attach() {
        onAttach()
    }
}

/// Message composer: text field + send. Presentational; sending lives with
/// the caller (wired to `MessagePipe.sendText` in the app assembly).
public struct ComposerView: View {
    @ObservedObject public var state: ComposerState

    public init(state: ComposerState) {
        self.state = state
    }

    public var body: some View {
        HStack {
            TextField("Message", text: $state.text)
                .textFieldStyle(.roundedBorder)
            Button("Attach") {
                state.attach()
            }
            Button("Send") {
                state.send()
            }
            .disabled(state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }
}
