// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

/// Cryptographically secure random bytes on every platform.
/// `SystemRandomNumberGenerator` is documented as a CSPRNG: it uses
/// `arc4random_buf` on Apple platforms and `getrandom(2)` on Linux. It
/// cannot fail (it traps instead), so callers need no error path.
public enum SecureRandom {
    public static func bytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in generator.next() }
    }
}
