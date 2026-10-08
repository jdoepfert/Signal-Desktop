// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore

// Manual provisioning run (not CI): `swift run SpikeHarness link` for
// staging, `swift run SpikeHarness link --production` to link as a
// secondary device with a normal Signal phone (up to 5 linked devices per
// account — no second phone or number needed).
// Opens a provisioning session, prints the address to scan with the phone,
// then decrypts the envelope and prints the ACI. The device id is
// server-assigned during code verification (Phase 1), so no credentials
// are minted here. Nothing is stored or sent.
func runLinkMode() async -> Int32 {
    do {
        return try await withTimeout(seconds: 600) {
            try await runLinkSession()
        }
    } catch let error as ProvisioningError where error == .timedOut {
        print("Timed out waiting — addresses expire within minutes.")
        print("Re-run for a fresh address, then re-scan.")
        return 1
    } catch {
        print("link failed: \(error)")
        return 1
    }
}

private func runLinkSession() async throws -> Int32 {
    let production = CommandLine.arguments.contains("--production")
    let host = production
        ? ChatTransport.productionHost
        : ChatTransport.stagingHost
    let transport = try ChatTransport(host: host)
    let ours = PrivateKey.generate()
    let session = try await transport.connect()
    session.start()
    print("Waiting for provisioning address...")
    for await event in session.events {
        switch event {
        case .address(let address):
            print("ADDRESS \(address)")
            print("LINK \(Provisioning.linkURL(address: address, publicKey: ours.publicKey))")
            print("Scan the QR for this address, then approve on the primary device.")
        case .envelope(let envelope):
            let account = try Provisioning(ourPrivateKey: ours).decrypt(envelope: envelope)
            print("LINKED aci=\(account.aci)")
            try? await session.disconnect()
            return 0
        }
    }
    print("Session closed before an envelope arrived.")
    print("Addresses expire within minutes — re-run for a fresh one, then re-scan.")
    return 1
}
