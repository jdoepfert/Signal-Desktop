// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// Minimal onboarding UI: shows the provisioning address (rendered as QR by
/// the host), link status, and the clock-skew warning. Type-checked here;
/// hosted by a real window with the Xcode project (Phase 2).
public struct OnboardingWindow: View {
    public let address: String?
    public let linkedAci: String?
    public let clockSkewed: Bool

    public init(address: String?, linkedAci: String?, clockSkewed: Bool) {
        self.address = address
        self.linkedAci = linkedAci
        self.clockSkewed = clockSkewed
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let linkedAci {
                Text("Linked as \(linkedAci)")
            } else if let address {
                Text("Scan to link")
                    .font(.headline)
                Text(address)
                    .font(.caption)
                    .textSelection(.enabled)
            } else {
                Text("Starting…")
            }
            if clockSkewed {
                Text("Warning: your clock disagrees with the server by over 5 minutes. Calls and sending may fail until it is fixed.")
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(minWidth: 320, minHeight: 200)
    }
}
