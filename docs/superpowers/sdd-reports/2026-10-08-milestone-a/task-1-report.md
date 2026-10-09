# Task 1 report
Status: DONE_WITH_CONCERNS.
- Generator: signal-macos/Tools/vectors (own package.json/lock, libsignal-client 0.103.0, protobufjs 7.4.0, version asserted vs root package.json; node_modules gitignored). Node 22 works.
- Vectors in Packages/SignalCore/Harness/Vectors. padding/access-key/content/provisioning deterministic (verified: second run, md5 identical). envelopes.json is non-deterministic (libsignal RNG, Kyber keygen); embeds full recipient store records, trust root, sender certs; generator self-decrypts both envelopes before writing.
- RED: `linux-lane.sh VectorTests` -> "cannot find 'Vectors' in scope". GREEN: "PASS VectorTests.testLoadsAll / ALL CHECKS PASSED". Full lane: 62 PASS, 0 FAIL (61 baseline + 1).
- Package.swift: added exclude: ["Vectors"] to SpikeHarness target.
- Net probe: Net.Environment closed enum staging/production (Net.swift:15-24), no host/cert param (Net.swift:61-66); decision: no mock-server lane. Recorded in GO-NO-GO.md.
Concerns: PADDING_BLOCK in Desktop is 80, not 160 (brief's lengths 158-160 retained; vectors record paddingBlock 80). Sealed-sender/prekey sessions use the real clock in processPreKeyBundle (session expiry), hence envelopes non-deterministic. Provisioning PNI binary is raw 16-byte UUID.
