// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// One-line, payload-free description of an error for log lines: the type
/// name, and for enums the case name plus any NUMERIC payload (HTTP status
/// codes, counts). Strings and other payloads are dropped because they can
/// carry identifiers, server text or key material.
///
///     SendError.server(status: 500)        -> "SendError.server(500)"
///     SignalError.invalidMessage("...")    -> "SignalError.invalidMessage"
///     DatabaseOpenError.needsReLink        -> "DatabaseOpenError.needsReLink"
///     URLError / structs / classes         -> "URLError"
public enum ErrorReason {
    public static func describe(_ error: Error) -> String {
        let typeName = String(describing: Swift.type(of: error))
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else {
            return typeName
        }
        guard let payload = mirror.children.first else {
            // A case without payload prints as just its name.
            return "\(typeName).\(String(describing: error))"
        }
        let caseName = payload.label ?? "?"
        let numbers = numericValues(in: payload.value)
        if numbers.isEmpty {
            return "\(typeName).\(caseName)"
        }
        return "\(typeName).\(caseName)(\(numbers.joined(separator: ",")))"
    }

    private static func numericValues(in value: Any) -> [String] {
        if let integer = value as? any BinaryInteger {
            return [String(describing: integer)]
        }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .tuple else {
            return []
        }
        return mirror.children.compactMap { child in
            (child.value as? any BinaryInteger).map { String(describing: $0) }
        }
    }
}
