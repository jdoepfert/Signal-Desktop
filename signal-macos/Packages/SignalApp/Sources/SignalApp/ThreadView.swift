// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SwiftUI

/// Message thread: incoming bubbles left, outgoing bubbles right (like the
/// normal Signal client). Timestamps render under each bubble; the sender id
/// label shows only for incoming rows — outgoing rows are the local user.
public struct ThreadView: View {
    public let messages: [ThreadMessage]
    public let displayName: (String) -> String

    public init(messages: [ThreadMessage], displayName: @escaping (String) -> String) {
        self.messages = messages
        self.displayName = displayName
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(messages, id: \.rowId) { message in
                    HStack {
                        if message.isOutgoing {
                            Spacer(minLength: 60)
                        }
                        VStack(
                            alignment: message.isOutgoing ? .trailing : .leading,
                            spacing: 2
                        ) {
                            if !message.isOutgoing {
                                Text(displayName(message.senderAci))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(message.body)
                                .padding(8)
                                .background(
                                    message.isOutgoing
                                        ? Color.accentColor
                                        : Color(nsColor: .controlBackgroundColor)
                                )
                                .foregroundColor(
                                    message.isOutgoing ? .white : .primary
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(Self.timestampText(message.timestamp))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if !message.isOutgoing {
                            Spacer(minLength: 60)
                        }
                    }
                    .id(message.rowId)
                }
            }
            .padding()
        }
    }

    /// `sent_timestamp` is millis since epoch; shows time-only for today's
    /// messages, date + time otherwise.
    static func timestampText(_ millis: UInt64) -> String {
        let date = Date(timeIntervalSince1970: Double(millis) / 1000.0)
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        } else {
            return Self.dateTimeFormatter.string(from: date)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .short
        return formatter
    }()
}
