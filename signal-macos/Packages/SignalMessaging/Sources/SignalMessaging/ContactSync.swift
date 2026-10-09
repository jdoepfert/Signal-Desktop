// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalCore
import SignalLogging
import SignalStorage

/// Contact sync from the phone (Desktop `MessageReceiver.#handleContacts` +
/// `ContactsParser`): the sync blob is a stream of varint-length-prefixed
/// `ContactDetails` protos, each followed by its avatar bytes. Names and
/// phones merge into the contacts table by ACI (never duplicating);
/// avatars are consumed from the stream but not stored (no avatar column
/// yet). Entries without a usable ACI are skipped, as are undecodable
/// entries — neighbors still import.
public enum ContactSync {
    private static let logger = Logger(subsystem: "contacts", category: "sync")

    /// KeyValue flag marking that we already asked the phone for its
    /// contacts. The request gate must not use the contacts row count: link
    /// stores our own profile key first, so the table is never empty after
    /// link and the request would never fire.
    public static let syncRequestedKey = "contact-sync-requested"

    /// True until we have asked once. Ingest is idempotent, so one extra
    /// request for accounts linked before this flag existed is harmless.
    public static func shouldRequestSync(syncRequested: Bool) -> Bool {
        !syncRequested
    }

    public struct Entry: Sendable, Equatable {
        public var aci: String
        public var name: String?
        public var phone: String?
    }

    /// Parses the blob into entries, skipping bad ones.
    public static func parse(_ blob: Data) -> [Entry] {
        var entries = [Entry]()
        var cursor = blob.startIndex
        while cursor < blob.endIndex {
            guard let (length, next) = readVarint(blob, from: cursor) else {
                break
            }
            cursor = next
            guard length >= 0, blob.distance(from: cursor, to: blob.endIndex) >= length else {
                break
            }
            let slice = blob[cursor..<blob.index(cursor, offsetBy: length)]
            cursor = blob.index(cursor, offsetBy: length)
            do {
                let details = try SignalServiceProtos_ContactDetails(serializedBytes: slice)
                var avatarLength = 0
                if details.hasAvatar {
                    avatarLength = Int(details.avatar.length)
                }
                guard blob.distance(from: cursor, to: blob.endIndex) >= avatarLength else {
                    break
                }
                cursor = blob.index(cursor, offsetBy: avatarLength)
                if let entry = entry(from: details) {
                    entries.append(entry)
                }
            } catch {
                // Undecodable entry: boundary-safe skip (length prefix
                // already consumed), neighbors still import.
                continue
            }
        }
        return entries
    }

    /// Merges parsed entries into the contacts table (merge by ACI, never
    /// duplicating).
    public static func ingest(blob: Data, into store: ContactStore) throws {
        let entries = parse(blob)
        Self.logger.info("contact sync: importing \(entries.count) entries")
        try store.importAddressBook(
            entries.map { (aci: $0.aci, name: $0.name, phone: $0.phone) }
        )
    }

    private static func entry(from details: SignalServiceProtos_ContactDetails) -> Entry? {
        let aci: String
        if details.aciBinary.count == 16 {
            let bytes = [UInt8](details.aciBinary)
            aci = UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            )).uuidString.lowercased()
        } else if !details.aci.isEmpty, UUID(uuidString: details.aci) != nil {
            aci = details.aci.lowercased()
        } else {
            return nil
        }
        let name = details.name.isEmpty ? nil : details.name
        let phone = details.number.isEmpty ? nil : details.number
        return Entry(aci: aci, name: name, phone: phone)
    }

    /// Reads a varint32; nil on truncation or overflow.
    private static func readVarint(_ data: Data, from index: Data.Index) -> (Int, Data.Index)? {
        var result = 0
        var shift = 0
        var cursor = index
        while cursor < data.endIndex, shift < 35 {
            let byte = data[cursor]
            cursor = data.index(after: cursor)
            result |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return (result, cursor)
            }
            shift += 7
        }
        return nil
    }
}
