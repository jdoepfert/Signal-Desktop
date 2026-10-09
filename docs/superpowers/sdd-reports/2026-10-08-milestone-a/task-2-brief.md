### Task 2: Generated protobuf and padding

**Files:**
- Create: `signal-macos/Tools/gen-protos.sh`, `signal-macos/Packages/SignalCore/Sources/SignalCore/Proto/`, `signal-macos/Packages/SignalCore/Sources/SignalCore/Padding.swift`
- Modify: all three manifests that list SignalCore dependencies (add `apple/swift-protobuf` at an exact version). Then migrate every `ContentCodec`/`decodeContentMessage` call site: `MessagePipe.swift`, `GroupManager.swift` and the harness tests.
- Delete: `signal-macos/Packages/SignalCore/Sources/SignalCore/ContentCodec.swift`
- Test: `signal-macos/Packages/SignalCore/Harness/PaddingTests.swift`

**Interfaces:**
- Produces:
  - Generated types `SignalServiceProtos_Envelope`, `SignalServiceProtos_Content`, `SignalServiceProtos_DataMessage`, `SignalServiceProtos_SyncMessage` and `SignalServiceProtos_ProvisionMessage` (the `swift_prefix` option in `gen-protos.sh` decides the names; keep it `SignalServiceProtos_`).
  - `enum Padding { static func pad(_ plain: Data) -> Data; static func unpad(_ padded: Data) throws -> Data }`. `unpad` throws `PaddingError.invalid` on a non-zero byte after the `0x80` terminator.
  - `DecryptedMessage` gains `content: SignalServiceProtos_Content` and keeps `senderAci`, `body` (from `dataMessage.body`, possibly empty) and `timestamp`.

- [ ] **Step 1: Write the failing tests**

  ```swift
  run("PaddingTests") {
      for c in try! Vectors.load("padding")["cases"] as! [[String: String]] {
          check("PaddingTests.pad.\(c["plain"]!.count / 2)",
                Padding.pad(Data(hex: c["plain"]!)) == Data(hex: c["padded"]!))
          check("PaddingTests.unpad.\(c["plain"]!.count / 2)",
                (try? Padding.unpad(Data(hex: c["padded"]!))) == Data(hex: c["plain"]!))
      }
      check("PaddingTests.rejectsGarbage", (try? Padding.unpad(Data([0x41, 0x80, 0x00, 0x07]))) == nil)
      // content.json: every vector decodes through the generated type; body/timestamp/expireTimer match
      // re-encoding the decoded message reproduces the vector bytes exactly
  }
  ```

- [ ] **Step 2: Run them to make sure they fail**

  Run: `cd signal-macos && swift run SpikeHarness PaddingTests`
  Expected: compile errors, `Padding` and the generated types not defined.

- [ ] **Step 3: Generate the protos**

  `gen-protos.sh` runs `protoc --swift_out=… --swift_opt=Visibility=Public` over `protos/SignalService.proto` and `protos/DeviceMessages.proto`. It requires `protoc-gen-swift` at the same version as the package dependency and fails loudly if they differ. Then implement `Padding`, porting `getPaddedMessageLength`/`padMessage` (block 80, `PADDING_BLOCK` at `OutgoingMessage.preload.ts:123`) and `#unpad` exactly. Replace `ContentCodec` and `ProtoFields` use in the message path with the generated types, and delete `ContentCodec.swift`.

- [ ] **Step 4: Run all the tests and make sure they pass**

  Run: `cd signal-macos && swift run SpikeHarness`
  Expected: `ALL CHECKS PASSED`. Also, `Tools/gen-protos.sh && git diff --exit-code Packages/SignalCore/Sources/SignalCore/Proto` exits 0.

- [ ] **Step 5: Commit**

  ```bash
  git add signal-macos
  git commit -m "milestone-a: generated protobuf and message padding"
  ```

---

