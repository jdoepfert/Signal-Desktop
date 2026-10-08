// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore

// Manual provisioning run (not CI): `swift run SpikeHarness link`.
// Opens a staging provisioning session, prints the address to scan with a
// staging-registered Signal app, then decrypts the envelope and prints the
// ACI. The device id is server-assigned during code verification (Phase 1),
// so no credentials are minted here.
func runLinkMode() async -> Int32 {
    do {
        let transport = try StagingTransport(host: StagingTransport.stagingHost)
        let ours = PrivateKey.generate()
        let session = try await transport.connect()
        session.start()
        print("Waiting for provisioning address...")
        for await event in session.events {
            switch event {
            case .address(let address):
                print("ADDRESS \(address)")
                print("Scan the QR for this address, then approve on the primary device.")
            case .envelope(let envelope):
                let privateBytes = ours.serialize()
                let aci = try Provisioning.decryptEnvelope(
                    envelope,
                    ourPrivateKeyBytes: privateBytes
                )
                print("LINKED aci=\(aci)")
                try? await session.disconnect()
                return 0
            }
        }
        print("Session closed before an envelope arrived.")
        print("Addresses expire within minutes — re-run for a fresh one, then re-scan.")
        return 1
    } catch {
        print("link failed: \(error)")
        return 1
    }
}
