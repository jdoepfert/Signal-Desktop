// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// Message thread: chronological bubbles with sender labels. Presentational;
/// ordering logic lives in `ConversationViewModel`.
public struct ThreadView: View {
    public let messages: [ThreadMessage]
    public let displayName: (String) -> String

    public init(messages: [ThreadMessage], displayName: @escaping (String) -> String) {
        self.messages = messages
        self.displayName = displayName
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(messages, id: \.rowId) { message in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(message.senderAci))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(message.body)
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .id(message.rowId)
                }
            }
            .padding()
        }
    }
}
