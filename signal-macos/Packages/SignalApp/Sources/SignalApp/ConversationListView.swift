// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import SignalStorage
import SwiftUI

/// Sidebar conversation list. Presentational: data in, selection and mute
/// actions out. Type-checked here; behavior lives in the view-model and
/// stores; visuals verified in dogfood.
public struct ConversationListView: View {
    public let conversations: [StoredConversation]
    public let selection: Binding<String?>
    public let displayName: (StoredConversation) -> String
    public let onToggleMute: (StoredConversation) -> Void

    public init(
        conversations: [StoredConversation],
        selection: Binding<String?>,
        displayName: @escaping (StoredConversation) -> String,
        onToggleMute: @escaping (StoredConversation) -> Void
    ) {
        self.conversations = conversations
        self.selection = selection
        self.displayName = displayName
        self.onToggleMute = onToggleMute
    }

    public var body: some View {
        List(conversations, id: \.id, selection: selection) { conversation in
            HStack {
                VStack(alignment: .leading) {
                    Text(displayName(conversation))
                        .font(.headline)
                    if conversation.muted {
                        Text("Muted")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if conversation.unread > 0 {
                    Text("\(conversation.unread)")
                        .font(.caption)
                        .padding(4)
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(Circle())
                }
            }
            .tag(conversation.id)
            .contextMenu {
                Button(conversation.muted ? "Unmute" : "Mute") {
                    onToggleMute(conversation)
                }
            }
        }
    }
}
