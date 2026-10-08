// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB

public struct StoredAttachment: Sendable, Equatable {
    public let digest: Data
    public let cdnKey: String
    public let size: UInt64
    public let contentType: String
    public let key: Data
    public let messageId: Int64?

    public init(
        digest: Data,
        cdnKey: String,
        size: UInt64,
        contentType: String,
        key: Data,
        messageId: Int64? = nil
    ) {
        self.digest = digest
        self.cdnKey = cdnKey
        self.size = size
        self.contentType = contentType
        self.key = key
        self.messageId = messageId
    }
}

/// Attachment pointer + key bytes, digest-addressed. Uploads persist before
/// any message references them (message linkage arrives with the composer);
/// downloads resolve keys from here, so they survive restarts.
public final class AttachmentTable: Sendable {
    private let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func save(
        digest: Data,
        cdnKey: String,
        size: UInt64,
        contentType: String,
        key: Data
    ) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO attachments
                        (digest, cdn_key, size, content_type, key_bytes)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(digest) DO UPDATE SET
                        cdn_key = excluded.cdn_key,
                        size = excluded.size,
                        content_type = excluded.content_type,
                        key_bytes = excluded.key_bytes
                    """,
                arguments: [
                    digest,
                    cdnKey,
                    Int64(bitPattern: size),
                    contentType,
                    key,
                ]
            )
        }
    }

    public func load(digest: Data) throws -> StoredAttachment? {
        struct AttachmentRow: FetchableRecord {
            let digest: Data
            let cdnKey: String
            let size: Int64
            let contentType: String
            let keyBytes: Data
            let messageId: Int64?

            init(row: Row) {
                digest = row["digest"]
                cdnKey = row["cdn_key"]
                size = row["size"]
                contentType = row["content_type"]
                keyBytes = row["key_bytes"]
                messageId = row["message_id"]
            }
        }
        guard
            let row = try queue.read({ db in
                try AttachmentRow.fetchOne(
                    db,
                    sql: """
                        SELECT digest, cdn_key, size, content_type, key_bytes, message_id
                        FROM attachments WHERE digest = ?
                        """,
                    arguments: [digest]
                )
            })
        else {
            return nil
        }
        return StoredAttachment(
            digest: row.digest,
            cdnKey: row.cdnKey,
            size: UInt64(bitPattern: row.size),
            contentType: row.contentType,
            key: row.keyBytes,
            messageId: row.messageId
        )
    }
}
