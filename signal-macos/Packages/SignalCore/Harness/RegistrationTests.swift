// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore

final class FakeVerificationService: DeviceVerificationService, @unchecked Sendable {
    nonisolated(unsafe) var calls = 0
    nonisolated(unsafe) var hang = false

    func verifyProvisioningCode(_ code: String, deviceName: String) async throws -> RegisteredDevice {
        calls += 1
        if hang {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        return RegisteredDevice(deviceId: 42, password: "fake-password")
    }
}

func runRegistrationTests() async {
    // Code verification returns the service's deviceId/password.
    do {
        let service = FakeVerificationService()
        let registered = try await DeviceRegistration.register(
            provisioningCode: "123-456",
            deviceName: "spike",
            via: service
        )
        check(
            "RegistrationTests.testCodeVerification",
            registered == RegisteredDevice(deviceId: 42, password: "fake-password")
                && service.calls == 1
        )
    } catch {
        check("RegistrationTests.testCodeVerification", false, "\(error)")
    }

    // Empty code throws before any network.
    do {
        let service = FakeVerificationService()
        do {
            _ = try await DeviceRegistration.register(
                provisioningCode: "",
                deviceName: "spike",
                via: service
            )
            check("RegistrationTests.testEmptyCode", false, "no error thrown")
        } catch {
            check(
                "RegistrationTests.testEmptyCode",
                error is ProvisioningError && service.calls == 0
            )
        }
    }

    // Whitespace-only codes are rejected; surrounding whitespace is trimmed.
    do {
        final class RecordingService: DeviceVerificationService, @unchecked Sendable {
            nonisolated(unsafe) var seen: [String] = []
            func verifyProvisioningCode(_ code: String, deviceName: String) async throws -> RegisteredDevice {
                seen.append(code)
                return RegisteredDevice(deviceId: 7, password: "pw")
            }
        }
        let service = RecordingService()
        do {
            _ = try await DeviceRegistration.register(
                provisioningCode: "   ",
                deviceName: "spike",
                via: service
            )
            check("RegistrationTests.testBlankCode", false, "no error thrown")
        } catch let error as ProvisioningError {
            check(
                "RegistrationTests.testBlankCode",
                error == .invalidCode && service.seen.isEmpty
            )
        }
        let registered = try await DeviceRegistration.register(
            provisioningCode: "  123-456\n",
            deviceName: "spike",
            via: service
        )
        check(
            "RegistrationTests.testCodeTrimmed",
            registered.deviceId == 7 && service.seen == ["123-456"]
        )
    } catch {
        check("RegistrationTests.testBlankCode", false, "\(error)")
    }

    // Hung service throws .timedOut within the deadline.
    do {
        let service = FakeVerificationService()
        service.hang = true
        do {
            _ = try await DeviceRegistration.register(
                provisioningCode: "123-456",
                deviceName: "spike",
                via: service,
                timeoutSeconds: 0.1
            )
            check("RegistrationTests.testTimeout", false, "no error thrown")
        } catch let error as ProvisioningError {
            check(
                "RegistrationTests.testTimeout",
                error == .timedOut,
                "got \(error)"
            )
        } catch {
            check("RegistrationTests.testTimeout", false, "\(error)")
        }
    }

    // Concurrent refreshers share one fetch (singleflight). The fetch is
    // slow so all callers overlap while it is in flight; afterwards the
    // cache serves without refetching.
    do {
        let fixture = try PipeFixture.make()
        final class Counter: @unchecked Sendable {
            var count = 0
        }
        let counter = Counter()
        let service = SenderCertService {
            counter.count += 1
            try await Task.sleep(nanoseconds: 200_000_000)
            return fixture.senderCert
        }
        let results = try await withThrowingTaskGroup(of: SenderCertificate.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await service.refreshCertificate()
                }
            }
            var collected = 0
            for try await _ in group {
                collected += 1
            }
            return collected
        }
        _ = try await service.currentCertificate()
        check(
            "RegistrationTests.testSingleflight",
            results == 10 && counter.count == 1
        )
    } catch {
        check("RegistrationTests.testSingleflight", false, "\(error)")
    }
}
