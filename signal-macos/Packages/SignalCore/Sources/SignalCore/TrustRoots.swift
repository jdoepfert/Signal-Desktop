// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient

/// Server trust roots for sender-certificate validation, copied from
/// Desktop's public config: `config/default.json#serverTrustRoots`
/// (staging) and `config/production.json#serverTrustRoots`.
public enum TrustRoots {
    private static let staging = [
        "BbqY1DzohE4NUZoVF+L18oUPrK3kILllLEJh2UnPSsEx",
        "BYhU6tPjqP46KGZEzRs1OL4U39V5dlPJ/X09ha4rErkm",
    ]

    private static let production = [
        "BXu6QIKVz5MA8gstzfOgRQGqyLqOwNKHL6INkv3IHWMF",
        "BUkY0I+9+oPgDCn4+Ac6Iu813yvqkDr/ga8DzLxFxuk6",
    ]

    public static func forEnvironment(_ env: AppEnvironment) -> [PublicKey] {
        let encoded = env == .production ? production : staging
        return encoded.map { root in
            // Compile-time constants: a malformed one is a programmer error
            // (pinned by testStagingRootsParse), never a runtime condition.
            guard let bytes = Data(base64Encoded: root), let key = try? PublicKey(bytes) else {
                preconditionFailure("malformed built-in trust root")
            }
            return key
        }
    }
}
