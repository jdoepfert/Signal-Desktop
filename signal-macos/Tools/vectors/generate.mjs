// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//
// Golden vector generator. Uses the same @signalapp/libsignal-client version
// as Signal Desktop plus Desktop's own .proto files, so the Swift client can
// check wire formats byte-for-byte. See README.md.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import protobuf from 'protobufjs';
import * as ls from '@signalapp/libsignal-client';
import { ProfileKey } from '@signalapp/libsignal-client/zkgroup.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '../../..');
const outDir = path.resolve(
  here,
  '../../Packages/SignalCore/Harness/Vectors'
);
const require = createRequire(import.meta.url);

// --- Version pin: must match Desktop's -------------------------------------
const rootPkg = JSON.parse(
  fs.readFileSync(path.join(repoRoot, 'package.json'), 'utf8')
);
const wanted = rootPkg.dependencies['@signalapp/libsignal-client'];
const have = require('@signalapp/libsignal-client/package.json').version;
if (wanted !== have) {
  throw new Error(`libsignal-client ${have} != Desktop's pinned ${wanted}`);
}

// --- Helpers ---------------------------------------------------------------
const hex = b => Buffer.from(b).toString('hex');
const fromHex = h => Buffer.from(h, 'hex');
// Deterministic bytes: SHA-256 counter expansion of a label.
function seeded(label, length) {
  const out = [];
  for (let i = 0; out.length * 32 < length; i += 1) {
    out.push(
      crypto.createHash('sha256').update(`${label}/${i}`).digest()
    );
  }
  return Buffer.concat(out).subarray(0, length);
}
const privKey = label => ls.PrivateKey.deserialize(seeded(label, 32));

function write(name, obj) {
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(
    path.join(outDir, `${name}.json`),
    `${JSON.stringify(obj, null, 2)}\n`
  );
  console.log(`wrote ${name}.json`);
}

const root = await protobuf.load([
  path.join(repoRoot, 'protos/SignalService.proto'),
  path.join(repoRoot, 'protos/DeviceMessages.proto'),
]);
const P = root.lookup('signalservice');
const encode = (type, obj) => {
  const T = P.lookupType(type);
  const err = T.verify(obj);
  if (err) throw new Error(`${type}: ${err}`);
  return Buffer.from(T.encode(T.create(obj)).finish());
};

// --- Padding (reimplements OutgoingMessage.preload.ts padMessage) ----------
const PADDING_BLOCK = 80;
function getPaddedMessageLength(messageLength) {
  const withTerminator = messageLength + 1;
  let parts = Math.floor(withTerminator / PADDING_BLOCK);
  if (withTerminator % PADDING_BLOCK !== 0) {
    parts += 1;
  }
  return parts * PADDING_BLOCK;
}
function padMessage(buf) {
  const plaintext = new Uint8Array(getPaddedMessageLength(buf.length + 1) - 1);
  plaintext.set(buf);
  plaintext[buf.length] = 0x80;
  return Buffer.from(plaintext);
}

{
  const cases = [0, 1, 158, 159, 160, 500].map(n => {
    const plain = seeded(`padding/${n}`, n);
    return { length: n, plain: hex(plain), padded: hex(padMessage(plain)) };
  });
  write('padding', { paddingBlock: PADDING_BLOCK, cases });
}

// --- Access key ------------------------------------------------------------
const profileKey = seeded('profile-key', 32);
{
  const accessKey = new ProfileKey(profileKey).deriveAccessKey();
  write('access-key', {
    profileKey: hex(profileKey),
    accessKey: hex(accessKey),
  });
}

// --- Provisioning (phone side, mirror of ProvisioningCipher.decrypt) -------
{
  const aci = '11111111-2222-4333-8444-555555555555';
  const pni = '66666666-7777-4888-9999-000000000000';
  const ourPriv = privKey('provisioning/our');
  const ourPub = ourPriv.getPublicKey();
  const ephemeral = privKey('provisioning/ephemeral');
  const aciIdentity = privKey('provisioning/aci-identity');
  const pniIdentity = privKey('provisioning/pni-identity');
  const provisioningCode = 'provisioning-code-0001';

  const messageBytes = encode('ProvisionMessage', {
    aciIdentityKeyPublic: aciIdentity.getPublicKey().serialize(),
    aciIdentityKeyPrivate: aciIdentity.serialize(),
    pniIdentityKeyPublic: pniIdentity.getPublicKey().serialize(),
    pniIdentityKeyPrivate: pniIdentity.serialize(),
    aci,
    pni,
    number: '+15555550100',
    provisioningCode,
    userAgent: 'OWI',
    profileKey,
    readReceipts: true,
    provisioningVersion: 1,
    aciBinary: fromHex(aci.replaceAll('-', '')),
    pniBinary: fromHex(`01${pni.replaceAll('-', '')}`).subarray(1),
  });

  const shared = ephemeral.agree(ourPub);
  const keys = ls.hkdf(
    96,
    shared,
    Buffer.from('TextSecure Provisioning Message'),
    Buffer.alloc(32)
  );
  const iv = seeded('provisioning/iv', 16);
  const cipher = crypto.createCipheriv(
    'aes-256-cbc',
    keys.subarray(0, 32),
    iv
  );
  const ciphertext = Buffer.concat([cipher.update(messageBytes), cipher.final()]);
  const ivAndCiphertext = Buffer.concat([Buffer.from([1]), iv, ciphertext]);
  const mac = crypto
    .createHmac('sha256', keys.subarray(32, 64))
    .update(ivAndCiphertext)
    .digest();
  const envelope = encode('ProvisionEnvelope', {
    publicKey: ephemeral.getPublicKey().serialize(),
    body: Buffer.concat([ivAndCiphertext, mac]),
  });

  write('provisioning', {
    ourPrivateKey: hex(ourPriv.serialize()),
    ourPublicKey: hex(ourPub.serialize()),
    envelope: hex(envelope),
    expected: {
      aci,
      pni,
      aciIdentityPublic: hex(aciIdentity.getPublicKey().serialize()),
      aciIdentityPrivate: hex(aciIdentity.serialize()),
      pniIdentityPublic: hex(pniIdentity.getPublicKey().serialize()),
      pniIdentityPrivate: hex(pniIdentity.serialize()),
      profileKey: hex(profileKey),
      provisioningCode,
      number: '+15555550100',
    },
  });
}

// --- Content (DataMessage encodings) ---------------------------------------
const DATA_TS = 1_700_000_000_123;
{
  const wrap = dataMessage => encode('Content', { dataMessage });
  const full = {
    body: 'Hello from Desktop',
    timestamp: DATA_TS,
    expireTimer: 3600,
    profileKey,
  };
  const fullBytes = encode('DataMessage', full);
  const reaction = {
    timestamp: DATA_TS + 1,
    reaction: {
      emoji: '\u{1F44D}',
      remove: false,
      targetAuthorAciBinary: fromHex('11111111222243338444555555555555'),
      targetSentTimestamp: DATA_TS,
    },
  };
  const reactionBytes = encode('DataMessage', reaction);
  write('content', {
    cases: [
      {
        name: 'body-timestamp-expire-profilekey',
        body: full.body,
        timestamp: DATA_TS,
        expireTimer: 3600,
        profileKey: hex(profileKey),
        dataMessage: hex(fullBytes),
        content: hex(wrap(full)),
      },
      {
        name: 'body-only',
        body: 'plain',
        timestamp: DATA_TS,
        dataMessage: hex(encode('DataMessage', { body: 'plain', timestamp: DATA_TS })),
        content: hex(wrap({ body: 'plain', timestamp: DATA_TS })),
      },
      {
        // Reactions are unsupported in Milestone A: Swift must not treat
        // this as a body message.
        name: 'reaction-unsupported',
        emoji: '\u{1F44D}',
        timestamp: DATA_TS + 1,
        targetSentTimestamp: DATA_TS,
        dataMessage: hex(reactionBytes),
        content: hex(wrap(reaction)),
      },
    ],
  });
}

// --- Envelopes (sealed sender + PREKEY_MESSAGE) ----------------------------
// Encrypting randomizes ephemeral keys, so this file changes on every run.
// It carries all store state so Swift decrypts instead of re-deriving.
{
  const ENVELOPE_TYPE = { PREKEY_MESSAGE: 3, UNIDENTIFIED_SENDER: 6 };
  const SERVER_TS = 1_700_000_005_000;
  const CERT_EXPIRY = 4_102_444_800_000; // 2100-01-01

  class MemSessions extends ls.SessionStore {
    m = new Map();
    async saveSession(a, r) { this.m.set(`${a.name()}.${a.deviceId()}`, r.serialize()); }
    async getSession(a) {
      const b = this.m.get(`${a.name()}.${a.deviceId()}`);
      return b ? ls.SessionRecord.deserialize(b) : null;
    }
    async getExistingSessions(as) {
      return as.map(a => ls.SessionRecord.deserialize(this.m.get(`${a.name()}.${a.deviceId()}`)));
    }
  }
  class MemIdentity extends ls.IdentityKeyStore {
    constructor(priv, regId) { super(); this.priv = priv; this.regId = regId; this.peers = new Map(); }
    async getIdentityKey() { return this.priv; }
    async getLocalRegistrationId() { return this.regId; }
    async saveIdentity(a, k) {
      const old = this.peers.get(`${a.name()}.${a.deviceId()}`);
      this.peers.set(`${a.name()}.${a.deviceId()}`, k);
      return old && !old.equals(k) ? ls.IdentityChange.ReplacedExisting : ls.IdentityChange.NewOrUnchanged;
    }
    async isTrustedIdentity() { return true; }
    async getIdentity(a) { return this.peers.get(`${a.name()}.${a.deviceId()}`) ?? null; }
  }
  class MemPreKeys extends ls.PreKeyStore {
    m = new Map();
    async savePreKey(id, r) { this.m.set(id, r); }
    async getPreKey(id) { return this.m.get(id); }
    async removePreKey(id) { this.m.delete(id); }
  }
  class MemSigned extends ls.SignedPreKeyStore {
    m = new Map();
    async saveSignedPreKey(id, r) { this.m.set(id, r); }
    async getSignedPreKey(id) { return this.m.get(id); }
  }
  class MemKyber extends ls.KyberPreKeyStore {
    m = new Map();
    async saveKyberPreKey(id, r) { this.m.set(id, r); }
    async getKyberPreKey(id) { return this.m.get(id); }
    async markKyberPreKeyUsed() {}
  }

  // Recipient: the "linked Swift device".
  const rcptAci = ls.Aci.fromUuid('11111111-2222-4333-8444-555555555555');
  const rcptDevice = 2;
  const rcptAddr = ls.ProtocolAddress.new(rcptAci, rcptDevice);
  const rcptRegId = 1234;
  const rcptIdentity = privKey('envelopes/recipient-identity');
  const signedPre = privKey('envelopes/recipient-signed');
  const signedRec = ls.SignedPreKeyRecord.new(
    7,
    DATA_TS,
    signedPre.getPublicKey(),
    signedPre,
    rcptIdentity.sign(signedPre.getPublicKey().serialize())
  );
  const kemPair = ls.KEMKeyPair.generate();
  const kyberRec = ls.KyberPreKeyRecord.new(
    8,
    DATA_TS,
    kemPair,
    rcptIdentity.sign(kemPair.getPublicKey().serialize())
  );
  const oneTime = [101, 102].map(id => {
    const k = privKey(`envelopes/recipient-onetime/${id}`);
    return ls.PreKeyRecord.new(id, k.getPublicKey(), k);
  });

  // Fake server: trust root + server cert (test-only keys).
  const trustRoot = privKey('envelopes/trust-root');
  const serverKey = privKey('envelopes/server-key');
  const serverCert = ls.ServerCertificate.new(1, serverKey.getPublicKey(), trustRoot);

  async function makeSender(label, aciStr, deviceId, regId, oneTimeRec) {
    const aci = ls.Aci.fromUuid(aciStr);
    const identity = privKey(`envelopes/${label}-identity`);
    const ids = new MemIdentity(identity, regId);
    const sessions = new MemSessions();
    const bundle = ls.PreKeyBundle.new(
      rcptRegId, rcptDevice, oneTimeRec.id(), oneTimeRec.publicKey(),
      signedRec.id(), signedRec.publicKey(), signedRec.signature(),
      rcptIdentity.getPublicKey(),
      kyberRec.id(), kyberRec.publicKey(), kyberRec.signature()
    );
    const sAddr = ls.ProtocolAddress.new(aci, deviceId);
    await ls.processPreKeyBundle(bundle, rcptAddr, sAddr, sessions, ids);
    const cert = ls.SenderCertificate.new(
      aci, null, deviceId, identity.getPublicKey(), CERT_EXPIRY, serverCert, serverKey
    );
    return { aci, aciStr, deviceId, identity, ids, sessions, sAddr, cert };
  }

  const bodyOf = n => ({ body: `golden ${n}`, timestamp: DATA_TS + n });
  const sealedContent = encode('Content', { dataMessage: bodyOf(1) });
  const prekeyContent = encode('Content', { dataMessage: bodyOf(2) });

  const s1 = await makeSender('sender-sealed', 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', 3, 4321, oneTime[0]);
  const sealedBytes = await ls.sealedSenderEncryptMessage(
    padMessage(sealedContent), rcptAddr, s1.cert, s1.sessions, s1.ids
  );
  const sealedEnvelope = encode('Envelope', {
    type: ENVELOPE_TYPE.UNIDENTIFIED_SENDER,
    destinationServiceId: rcptAci.getServiceIdString(),
    clientTimestamp: DATA_TS + 1,
    content: sealedBytes,
    serverGuid: '00000000-0000-4000-8000-000000000001',
    serverTimestamp: SERVER_TS,
  });

  const s2 = await makeSender('sender-prekey', 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff', 5, 8765, oneTime[1]);
  const prekeyMsg = await ls.signalEncrypt(
    padMessage(prekeyContent), rcptAddr, s2.sAddr, s2.sessions, s2.ids
  );
  if (prekeyMsg.type() !== ls.CiphertextMessageType.PreKey) {
    throw new Error('expected a PreKey ciphertext');
  }
  const prekeyEnvelope = encode('Envelope', {
    type: ENVELOPE_TYPE.PREKEY_MESSAGE,
    sourceServiceId: s2.aci.getServiceIdString(),
    sourceDeviceId: s2.deviceId,
    destinationServiceId: rcptAci.getServiceIdString(),
    clientTimestamp: DATA_TS + 2,
    content: prekeyMsg.serialize(),
    serverGuid: '00000000-0000-4000-8000-000000000002',
    serverTimestamp: SERVER_TS,
  });

  // Self-check: decrypt both with fresh recipient stores built only from
  // what is written to the JSON file.
  function recipientStores() {
    const ids = new MemIdentity(rcptIdentity, rcptRegId);
    const pre = new MemPreKeys();
    oneTime.forEach(r => pre.m.set(r.id(), ls.PreKeyRecord.deserialize(r.serialize())));
    const signed = new MemSigned();
    signed.m.set(signedRec.id(), ls.SignedPreKeyRecord.deserialize(signedRec.serialize()));
    const kyber = new MemKyber();
    kyber.m.set(kyberRec.id(), ls.KyberPreKeyRecord.deserialize(kyberRec.serialize()));
    return { ids, pre, signed, kyber, sessions: new MemSessions() };
  }
  {
    const r = recipientStores();
    const res = await ls.sealedSenderDecryptMessage(
      sealedBytes,
      trustRoot.getPublicKey(), DATA_TS, null, rcptAci.getRawUuid(), rcptDevice,
      r.sessions, r.ids, r.pre, r.signed, r.kyber
    );
    if (!Buffer.from(res.message()).equals(padMessage(sealedContent))) {
      throw new Error('sealed sender self-check failed');
    }
    const r2 = recipientStores();
    const plain = await ls.signalDecryptPreKey(
      ls.PreKeySignalMessage.deserialize(prekeyMsg.serialize()),
      s2.sAddr, rcptAddr, r2.sessions, r2.ids, r2.pre, r2.signed, r2.kyber
    );
    if (!Buffer.from(plain).equals(padMessage(prekeyContent))) {
      throw new Error('prekey self-check failed');
    }
  }

  write('envelopes', {
    note: 'Non-deterministic (libsignal ephemeral randomness); regenerate only on purpose.',
    recipient: {
      aci: rcptAci.getServiceIdString(),
      deviceId: rcptDevice,
      registrationId: rcptRegId,
      identityPrivate: hex(rcptIdentity.serialize()),
      identityPublic: hex(rcptIdentity.getPublicKey().serialize()),
      signedPreKeyRecord: hex(signedRec.serialize()),
      kyberPreKeyRecord: hex(kyberRec.serialize()),
      oneTimePreKeyRecords: oneTime.map(r => ({ id: r.id(), record: hex(r.serialize()) })),
    },
    trustRootPublic: hex(trustRoot.getPublicKey().serialize()),
    certificateExpiration: CERT_EXPIRY,
    decryptTimestamp: DATA_TS,
    cases: [
      {
        name: 'sealed-sender-prekey-inside',
        envelope: hex(sealedEnvelope),
        senderAci: s1.aci.getServiceIdString(),
        senderDeviceId: s1.deviceId,
        senderIdentityPublic: hex(s1.identity.getPublicKey().serialize()),
        senderCertificate: hex(s1.cert.serialize()),
        expectedContent: hex(sealedContent),
        expectedPaddedPlaintext: hex(padMessage(sealedContent)),
        expectedBody: bodyOf(1).body,
        sentTimestamp: DATA_TS + 1,
        serverTimestamp: SERVER_TS,
      },
      {
        name: 'prekey-message',
        envelope: hex(prekeyEnvelope),
        senderAci: s2.aci.getServiceIdString(),
        senderDeviceId: s2.deviceId,
        senderIdentityPublic: hex(s2.identity.getPublicKey().serialize()),
        expectedContent: hex(prekeyContent),
        expectedPaddedPlaintext: hex(padMessage(prekeyContent)),
        expectedBody: bodyOf(2).body,
        sentTimestamp: DATA_TS + 2,
        serverTimestamp: SERVER_TS,
      },
    ],
  });
}
