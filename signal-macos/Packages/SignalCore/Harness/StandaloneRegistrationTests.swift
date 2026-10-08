// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalCore
import SignalMessaging
import SignalStorage

final class FakeStandaloneService: StandaloneService, @unchecked Sendable {
    nonisolated(unsafe) var requested: [String] = []
    nonisolated(unsafe) var confirmed: [String] = []
    nonisolated(unsafe) var completions = 0

    func requestCode(phoneNumber: String) async throws {
        requested.append(phoneNumber)
    }

    func confirmCode(_ code: String) async throws {
        confirmed.append(code)
        if code != "123456" {
            throw StandaloneTestError.wrongCode
        }
    }

    func completeRegistration() async throws -> RegisteredDevice {
        completions += 1
        return RegisteredDevice(deviceId: 1, password: "standalone-pw")
    }
}

enum StandaloneTestError: Error {
    case wrongCode
}

func runStandaloneRegistrationTests() async {
    // Full flow: request -> confirm -> complete returns credentials.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        let service = FakeStandaloneService()
        let registration = StandaloneRegistration(
            service: service,
            store: KeyValueStore(queue: db.queue)
        )
        try await registration.requestCode(phoneNumber: "+14155550132")
        try await registration.confirmCode("123456")
        let device = try await registration.completeRegistration()
        check(
            "MessagingTests.testStandaloneFlow",
            device == RegisteredDevice(deviceId: 1, password: "standalone-pw")
                && service.requested == ["+14155550132"]
        )
    } catch {
        check("MessagingTests.testStandaloneFlow", false, "\(error)")
    }

    // Wrong code throws without advancing; the flow resumes afterwards.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        let service = FakeStandaloneService()
        let registration = StandaloneRegistration(
            service: service,
            store: KeyValueStore(queue: db.queue)
        )
        try await registration.requestCode(phoneNumber: "+14155550132")
        do {
            try await registration.confirmCode("000000")
            check("MessagingTests.testStandaloneWrongCode", false, "no error thrown")
        } catch {
            let stepAfterReject = try await registration.currentStep()
            try await registration.confirmCode("123456")
            let device = try await registration.completeRegistration()
            check(
                "MessagingTests.testStandaloneWrongCode",
                stepAfterReject == .codeRequested && device.deviceId == 1
            )
        }
    } catch {
        check("MessagingTests.testStandaloneWrongCode", false, "\(error)")
    }

    // Interrupted flow resumes from the persisted step.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        let store = KeyValueStore(queue: db.queue)
        let first = StandaloneRegistration(service: FakeStandaloneService(), store: store)
        try await first.requestCode(phoneNumber: "+14155550132")
        let second = StandaloneRegistration(service: FakeStandaloneService(), store: store)
        let step = try await second.currentStep()
        check("MessagingTests.testStandaloneResume", step == .codeRequested)
    } catch {
        check("MessagingTests.testStandaloneResume", false, "\(error)")
    }
}
