# Golden vector generator

Produces the JSON vectors in `Packages/SignalCore/Harness/Vectors/` using
Signal Desktop's own stack: `@signalapp/libsignal-client` (same pinned
version as the repo root `package.json`, asserted at startup) and Desktop's
`protos/*.proto` loaded through `protobufjs`. This directory is a
self-contained npm package; it does not use the repo root `node_modules`.

```sh
cd signal-macos/Tools/vectors
npm install
node generate.mjs
```

All byte fields are lowercase hex. `padding`, `access-key`, `device-name` (Desktop's
`encryptDeviceName` with a seeded ephemeral key), `content` and
`provisioning` are deterministic (fixed seeds), so a second run leaves
`git diff` empty. `envelopes.json` is NOT deterministic: libsignal draws
ephemeral keys and the Kyber key pair from the OS RNG, so every run rewrites
it. It embeds the full recipient store state (identity, signed, Kyber and
one-time prekey records), the trust root and sender certificates so Swift
decrypts the recorded bytes rather than re-deriving anything. Only
regenerate it deliberately, and update the Swift tests with it.

Besides `cases`, `envelopes.json` carries `sequence` (21 consecutive
PREKEY_MESSAGEs from one sender on one session: 20 for the concurrent
decrypt test plus a 21st follow-up) and `retryPair` (two different
ciphertexts of the same logical message: same sender and sent timestamp).
The recipient owns one-time prekeys 101-110; 101-104 are consumed by the
vectors, the rest are spare.

The generator self-checks the envelopes by decrypting them with fresh
stores built from the same records before writing.

Padding uses Desktop's block size of 80 (`OutgoingMessage.preload.ts`).
