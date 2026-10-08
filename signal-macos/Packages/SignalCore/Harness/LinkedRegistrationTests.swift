// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalMessaging
import SignalStorage

final class FakeRegistrationTransport: RegistrationTransport, @unchecked Sendable {
    struct RecordedPut: Sendable {
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private let lock = NSLock()
    private var puts: [RecordedPut] = []
    nonisolated(unsafe) var status: UInt16 = 200
    nonisolated(unsafe) var body: Data?

    var recorded: [RecordedPut] {
        lock.withLock { puts }
    }

    init(uuid: String = "9d0652a3-dcc3-4d11-975f-74d61598733f", deviceId: UInt32 = 2) {
        let json = "{\"uuid\":\"\(uuid)\",\"deviceId\":\(deviceId)}"
        body = json.data(using: .utf8)
    }

    func put(path: String, headers: [String: String], body: Data) async throws -> (
        status: UInt16, body: Data
    ) {
        lock.withLock { puts.append(RecordedPut(path: path, headers: headers, body: body)) }
        return (status, self.body ?? Data())
    }
}

func runLinkedRegistrationTests() async {
    // Happy path: request shape pinned, credentials returned + persisted,
    // key material stored for future sessions.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        let store = InMemorySignalProtocolStore()
        let accounts = AccountTable(queue: db.queue)
        let transport = FakeRegistrationTransport()
        let registration = LinkedDeviceRegistration(
            transport: transport,
            store: store,
            accounts: accounts
        )
        let creds = try await registration.register(
            provisioningCode: "123-456",
            aci: "9d0652a3-dcc3-4d11-975f-74d61598733f",
            environment: .staging
        )
        let put = transport.recorded.first!
        let auth = put.headers["Authorization"] ?? ""
        let authPayload = String(
            data: Data(base64Encoded: String(auth.dropFirst("Basic ".count))) ?? Data(),
            encoding: .utf8
        ) ?? ""
        let body = try JSONSerialization.jsonObject(with: put.body) as? [String: Any]
        let attrs = body?["accountAttributes"] as? [String: Any]
        let stored = try accounts.load(aci: creds.aci)
        let context = NullContext()
        let signedStored = try? store.loadSignedPreKey(id: 1, context: context)
        let kyberStored = try? store.loadKyberPreKey(id: 1, context: context)
        check(
            "MessagingTests.testLinkedRegistration",
            put.path == "v1/devices/link"
                && authPayload.hasPrefix("9d0652a3-dcc3-4d11-975f-74d61598733f:")
                && (body?["verificationCode"] as? String) == "123-456"
                && ((body?["aciSignedPreKey"] as? [String: Any])?["keyId"] as? Int) == 1
                && (attrs?["fetchesMessages"] as? Bool) == true
                && creds.deviceId == 2
                && !creds.password.isEmpty
                && stored == StoredAccount(
                    aci: creds.aci,
                    deviceId: 2,
                    password: creds.password,
                    environment: "staging"
                )
                && signedStored != nil
                && kyberStored != nil
        )
    } catch {
        check("MessagingTests.testLinkedRegistration", false, "\(error)")
    }

    // Rejection surfaces the status; garbage body surfaces invalidResponse.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        let store = InMemorySignalProtocolStore()
        let accounts = AccountTable(queue: db.queue)
        let denied = FakeRegistrationTransport()
        denied.status = 403
        let registration = LinkedDeviceRegistration(
            transport: denied,
            store: store,
            accounts: accounts
        )
        do {
            _ = try await registration.register(
                provisioningCode: "123-456",
                aci: "9d0652a3-dcc3-4d11-975f-74d61598733f",
                environment: .staging
            )
            check("MessagingTests.testRegistrationRejected", false, "no error thrown")
        } catch let error as LinkRegistrationError {
            check(
                "MessagingTests.testRegistrationRejected",
                error == .rejected(status: 403)
            )
        }

        let garbage = FakeRegistrationTransport()
        garbage.body = Data("not json".utf8)
        let badJson = LinkedDeviceRegistration(
            transport: garbage,
            store: store,
            accounts: accounts
        )
        do {
            _ = try await badJson.register(
                provisioningCode: "123-456",
                aci: "9d0652a3-dcc3-4d11-975f-74d61598733f",
                environment: .staging
            )
            check("MessagingTests.testRegistrationBadJson", false, "no error thrown")
        } catch let error as LinkRegistrationError {
            check("MessagingTests.testRegistrationBadJson", error == .invalidResponse)
        }
    } catch {
        check("MessagingTests.testRegistrationRejected", false, "\(error)")
    }
}
