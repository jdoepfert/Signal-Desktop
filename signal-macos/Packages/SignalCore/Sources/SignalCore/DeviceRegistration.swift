// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient

/// Result of provisioning-code verification: the server-assigned device id
/// plus the client-minted password. The caller merges these with the
/// envelope-decrypted ACI into `DeviceCredentials`.
public struct RegisteredDevice: Sendable, Equatable {
    public let deviceId: UInt32
    public let password: String

    public init(deviceId: UInt32, password: String) {
        self.deviceId = deviceId
        self.password = password
    }
}

/// Service-call boundary for code verification. The real implementation
/// calls the chat service (Phase 1+); tests use a scripted fake.
public protocol DeviceVerificationService: Sendable {
    func verifyProvisioningCode(_ code: String, deviceName: String) async throws -> RegisteredDevice
}

public enum DeviceRegistration {
    public static func register(
        provisioningCode: String,
        deviceName: String,
        via service: any DeviceVerificationService,
        timeoutSeconds: Double = 300
    ) async throws -> RegisteredDevice {
        let code = provisioningCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            throw ProvisioningError.invalidCode
        }
        return try await withTimeout(seconds: timeoutSeconds) {
            try await service.verifyProvisioningCode(code, deviceName: deviceName)
        }
    }
}

/// Runs `operation` with a deadline. On expiry throws
/// `ProvisioningError.timedOut` and cancels the operation.
///
/// Cooperative cancellation only: `withThrowingTaskGroup` waits for
/// children on scope exit, so an operation that ignores cancellation still
/// blocks past the deadline. Every real wait underneath this helper must
/// be cancellation-aware (libsignal's async fns are; `Task.sleep` is).
public func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ProvisioningError.timedOut
        }
        guard let first = try await group.next() else {
            throw ProvisioningError.timedOut
        }
        group.cancelAll()
        return first
    }
}
