// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI

/// Root view: onboarding until linked, then the conversation split view.
public struct ContentView: View {
    @ObservedObject var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        switch state.phase {
        case .starting:
            Text("Starting\u{2026}")
                .padding()
                .frame(minWidth: 320, minHeight: 240)
                .onAppear {
                    // Unstructured: the launch must outlive this view,
                    // which disappears as soon as the phase changes.
                    state.begin()
                }
        case .needsLink:
            VStack(spacing: 8) {
                OnboardingWindow(
                    address: state.address,
                    linkedAci: nil,
                    clockSkewed: state.clockSkewed
                )
                if let message = state.error {
                    Text(message)
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                }
                StartOverButton(state: state)
            }
        case .needsReLink(let reason):
            RecoveryView(
                title: "Signal data on this Mac can't be used",
                detail: "\(reason) Start over to link this Mac again.",
                state: state
            )
        case .unlinked:
            RecoveryView(
                title: "This Mac was unlinked from your phone",
                detail: "Start over to link it again.",
                state: state
            )
        case .couldNotStart(let message):
            CouldNotStartView(message: message, state: state)
        case .linked:
            linkedView
        }
    }

    @ViewBuilder
    private var linkedView: some View {
        VStack(spacing: 0) {
            if let message = state.error {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .textSelection(.enabled)
                    .padding(4)
            }
            conversationsView
            Divider()
            BuildFooter()
        }
    }

    @ViewBuilder
    private var conversationsView: some View {
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
                    displayName: { state.cachedName(for: $0) },
                    attachments: state.attachmentBytes
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
    }
}

/// Confirmed reset to a clean slate: deletes this Mac's local Signal data
/// and returns to the QR link flow.
/// Confirmation flags as observable objects rather than `@State`: the
/// SwiftUI `@State` macro plugin only ships with full Xcode, and this builds
/// with the Command Line Tools too.
final class StartOverConfirmation: ObservableObject {
    @Published var isPresented = false
}

/// Build identity footer: which commit this bundle was built from, with
/// the full stamp one tap away (for manual-test provenance).
struct BuildFooter: View {
    private let info = BuildInfo.live
    @StateObject private var about = AboutConfirmation()

    var body: some View {
        Button(info.summary) {
            about.isPresented = true
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .padding(4)
        .alert("This build", isPresented: $about.isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(info.detail)
        }
    }
}

final class AboutConfirmation: ObservableObject {
    @Published var isPresented = false
}

struct StartOverButton: View {
    @ObservedObject var state: AppState
    @StateObject private var confirmation = StartOverConfirmation()

    var body: some View {
        Button("Start over") {
            confirmation.isPresented = true
        }
        .confirmationDialog(
            "Start over?",
            isPresented: $confirmation.isPresented,
            titleVisibility: .visible
        ) {
            Button("Delete local data and start over", role: .destructive) {
                Task {
                    await state.startOver()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This deletes the Signal data stored on this Mac and shows a new link code. Your phone is not changed; remove this Mac under Linked devices there if it is still listed."
            )
        }
        .padding(.bottom)
    }
}

/// Full-window explanation (unlinked, unusable local data) with the reset.
struct RecoveryView: View {
    let title: String
    let detail: String
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
            Text(detail)
                .multilineTextAlignment(.center)
            StartOverButton(state: state)
        }
        .padding()
        .frame(minWidth: 320, minHeight: 240)
    }
}

/// Launch hit a retryable problem (keychain prompt refused, database busy):
/// Retry changes nothing on disk. There is deliberately no "Start over"
/// here.
struct CouldNotStartView: View {
    let message: String
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            Text("Couldn't start Signal")
                .font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
            Text("Your data has not been changed.")
                .font(.caption)
            HStack {
                Button("Retry") {
                    Task {
                        await state.retry()
                    }
                }
                .keyboardShortcut(.defaultAction)
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding()
        .frame(minWidth: 320, minHeight: 240)
    }
}
