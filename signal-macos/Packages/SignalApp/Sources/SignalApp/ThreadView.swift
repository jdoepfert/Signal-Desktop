// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Foundation
import SwiftUI

/// Message thread: incoming bubbles left, outgoing bubbles right (like the
/// normal Signal client). Timestamps render under each bubble; the sender id
/// label shows only for incoming rows — outgoing rows are the local user.
/// Attachments render from `attachments` (bytes by digest): images inline,
/// other files as rows; rows without bytes yet render as file placeholders.
public struct ThreadView: View {
    public let messages: [ThreadMessage]
    public let displayName: (String) -> String
    public let attachments: [Data: Data]

    public init(
        messages: [ThreadMessage],
        displayName: @escaping (String) -> String,
        attachments: [Data: Data] = [:]
    ) {
        self.messages = messages
        self.displayName = displayName
        self.attachments = attachments
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
                            if !message.body.isEmpty {
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
                            }
                            if let attachment = message.attachment {
                                attachmentView(attachment)
                            }
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

    @ViewBuilder
    private func attachmentView(_ attachment: ThreadAttachment) -> some View {
        if attachment.contentType.hasPrefix("image/"),
           let bytes = attachments[attachment.digest],
           let image = NSImage(data: bytes)
        {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 300, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            HStack(spacing: 6) {
                Image(systemName: "doc")
                VStack(alignment: .leading, spacing: 0) {
                    Text("File")
                        .font(.caption)
                    Text("\(attachment.contentType) · \(attachment.size / 1024) KB")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
