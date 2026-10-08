// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalStorage

public enum RegistrationStep: String, Sendable {
    case idle
    case codeRequested
    case codeConfirmed
    case registered
}

public enum StandaloneRegistrationError: Error, Equatable {
    case invalidTransition
}

/// Service seam for primary registration. The live implementation drives
/// libsignal's `RegistrationService` (session + SMS code + register); tests
/// use a scripted fake.
public protocol StandaloneService: Sendable {
    func requestCode(phoneNumber: String) async throws
    func confirmCode(_ code: String) async throws
    func completeRegistration() async throws -> RegisteredDevice
}

/// Standalone (primary-device) registration as a persisted state machine:
/// every transition lands in the key-value store first, so a killed app
/// resumes where it left off. May slip to Phase 3 without blocking the
/// dogfood gate (linking covers dogfood).
public final class StandaloneRegistration: Sendable {
    private static let stepKey = "standaloneRegistration.step"
    private static let phoneKey = "standaloneRegistration.phone"

    private let service: any StandaloneService
    private let store: KeyValueStore

    public init(service: any StandaloneService, store: KeyValueStore) {
        self.service = service
        self.store = store
    }

    public func currentStep() async throws -> RegistrationStep {
        guard let raw = try await store.get(Self.stepKey),
              let step = RegistrationStep(rawValue: String(data: raw, encoding: .utf8) ?? "")
        else {
            return .idle
        }
        return step
    }

    public func requestCode(phoneNumber: String) async throws {
        guard try await currentStep() == .idle else {
            throw StandaloneRegistrationError.invalidTransition
        }
        try await service.requestCode(phoneNumber: phoneNumber)
        try await store.set(Data(phoneNumber.utf8), for: Self.phoneKey)
        try await store.set(Data(RegistrationStep.codeRequested.rawValue.utf8), for: Self.stepKey)
    }

    public func confirmCode(_ code: String) async throws {
        guard try await currentStep() == .codeRequested else {
            throw StandaloneRegistrationError.invalidTransition
        }
        try await service.confirmCode(code)
        try await store.set(Data(RegistrationStep.codeConfirmed.rawValue.utf8), for: Self.stepKey)
    }

    public func completeRegistration() async throws -> RegisteredDevice {
        guard try await currentStep() == .codeConfirmed else {
            throw StandaloneRegistrationError.invalidTransition
        }
        let device = try await service.completeRegistration()
        try await store.set(Data(RegistrationStep.registered.rawValue.utf8), for: Self.stepKey)
        return device
    }
}
