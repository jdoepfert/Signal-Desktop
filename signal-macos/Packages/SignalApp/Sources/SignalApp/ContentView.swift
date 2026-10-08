// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// Root view: onboarding until linked, then the conversation split view.
public struct ContentView: View {
    @ObservedObject var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        if state.isLinked {
            NavigationSplitView {
                ConversationListView(
                    conversations: state.conversations,
                    selection: $state.selection,
                    displayName: { state.conversationTitle(for: $0) },
                    onToggleMute: { state.toggleMute($0) }
                )
            } detail: {
                VStack(spacing: 0) {
                    ThreadView(
                        messages: state.thread.messages,
                        displayName: { state.cachedName(for: $0) }
                    )
                    Divider()
                    ComposerView(state: state.composer)
                }
            }
            .onAppear {
                state.refreshConversations()
            }
            .alert(
                "Safety number changed",
                isPresented: Binding(
                    get: { state.identityPrompt != nil },
                    set: { if !$0 { state.dismissIdentityChange() } }
                ),
                presenting: state.identityPrompt
            ) { prompt in
                Button("Send anyway") {
                    // The prompt is captured: dismissing the alert clears
                    // `state.identityPrompt` before this task runs.
                    Task {
                        await state.acceptIdentityChange(prompt)
                    }
                }
                Button("Cancel", role: .cancel) {
                    state.dismissIdentityChange()
                }
            } message: { prompt in
                Text("Safety number changed for \(state.cachedName(for: prompt.aci)). Send anyway?")
            }
        } else {
            OnboardingWindow(
                address: state.address,
                linkedAci: nil,
                clockSkewed: state.clockSkewed
            )
            .onAppear {
                Task {
                    await state.link()
                }
            }
        }
    }
}
