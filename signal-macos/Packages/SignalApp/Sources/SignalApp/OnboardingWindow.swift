// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreImage
import SwiftUI

/// Onboarding link flow: waiting → address shown (as QR) → linked.
/// Type-checked here; QR rendering needs a display server (verified in
/// dogfood, not in headless CI).
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
                if let qr = Self.qrImage(string: address) {
                    Image(nsImage: qr)
                } else {
                    Text(address)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            } else {
                Text("Starting…")
            }
            if clockSkewed {
                Text("Warning: your clock disagrees with the server by over 5 minutes. Calls and sending may fail until it is fixed.")
                    .foregroundColor(.red)
            }
        }
        .padding()
        .frame(minWidth: 320, minHeight: 240)
    }

    static func qrImage(string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator")
        else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else {
            return nil
        }
        // Integer-scale first: fractional display scaling would blur
        // modules into an unscannable image.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: 290, height: 290))
        image.addRepresentation(rep)
        return image
    }
}
