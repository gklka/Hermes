# Labyrinth: native encrypted history restore (notes)

Goal: restore encrypted chats' history natively (Go core), without the hidden Messenger web view.
Status: step 1 (reading the public specification) done, 2026-10-17. Nothing is implemented yet.

Sources:
- *The Labyrinth Encrypted Message Storage Protocol*, v1 (2023-12-06): https://engineering.fb.com/wp-content/uploads/2023/12/theLabyrintHencryptedMessagestorageProtocol_12-6-2023.pdf
- Same title, v1.1 (2026-05, file named "Minos"): https://engineering.fb.com/wp-content/uploads/2026/05/Minos-Updates-2026-Encrypted-Backups-White-Paper.pdf
- Message payloads (protobuf): https://github.com/facebook/messaging_schemas
- Backup Key Vault (PIN → HSM): https://engineering.fb.com/2021/09/10/security/whatsapp-e2ee-backups/
- ORF security proofs: https://eprint.iacr.org/2022/1044

## What the web app does when you enter the PIN

The web app is a new Labyrinth **device**. The PIN doesn't decrypt anything. It goes:

1. **PIN → recovery code.** The Backup Key Vault (HSMs, 10 wrong guesses max) checks the PIN
   and returns a 40-character recovery code. The papers only point to the WhatsApp backup post
   for this; the exact exchange (an OPAQUE-style PAKE in WhatsApp's case) is **not specified**.
2. **Recovery code → virtual device.** `(vdeviceId[16], vdeviceDecryptionKey[32]) =
   HKDF(entropy, salt=NULL, info="BackupRecoveryCode_v" + version + "_" + identifier + "_" + userID)`.
   The server returns the virtual device's encrypted secrets, looked up by `vdeviceId`.
3. **Decrypt the virtual device** with `vdeviceDecryptionKey` (AAD strings in quotes):
   - `deviceKeyPriv` ("virtual_device:virtual_device_private_key")
   - `epochStorageKeyPriv` ("virtual_device:epoch_storage_private_key")
   - ORF client state ("virtual_device:ocmf_client_state")
   - `mailboxRootSalt` ("virtual_device:mailbox_root_key")
   - `epochRootKey` ("virtual_device:epoch_root_key")
   - `base64(epochSequenceID)` ("virtual_device:epoch_anon_id")
4. **Enroll as a device** (writes to the account): new device, epoch storage and auth keypairs
   (signed with use-case bytes 0x30 / 0x31), `orf_client_evolve`, and
   `epochDeviceMac = HMAC(epochDeviceMacKey, deviceKeyPub)`, all uploaded.
   *Open question:* whether reading alone works without enrolling (the virtual device's keys
   already decrypt everything).
5. **Walk the epochs.**
   - Backward: each epoch stores the previous one's sequence ID and root key, encrypted under
     `epochDataStorageKey = HKDF(epochRootKey, NULL, "epoch_data_storage_" + b64(seqID))` with
     AAD "epoch_data_metadata". The decrypted sequence ID must be a decimal string of at most 11 digits.
   - Forward: `epochEntropyEncrypted` (Labyrinth HPKE to the virtual device's epoch storage key,
     PSK = `epochDistributionPreSharedKey`, AAD "epoch__" + seqID); then
     `(chainingKey, distributionPSK) = HKDF(prevRootKey, NULL, "epoch_chaining_" + prevSeqID + "_" + prevEpochID)`
     and `rootKey = HKDF(newEntropy, salt=chainingKey, "epoch_root_key")`.
6. **Read messages** by thread and time range. Each record has `epoch_id` and `version`.

## Message decryption

Owner-uploaded records (v1.0 style), by cipher version:

| Version | messageKey = HKDF(ikm, salt, info) |
|---|---|
| 0 | `HKDF(epochRootKey, salt=threadId, "message_key_in_epoch_" + seqID)` |
| 2 | `HKDF(epochRootKey, salt=threadId, "message_key_in_epoch_" + seqID + "cipher_version_2")` |
| 3, 4 | `HKDF(epochRootKey, NULL, "message_key_in_epoch_" + seqID + "_cipher_version_N_thread_" + threadId)` |

Then `decrypt(messageKey, AAD = "message_thread_" + threadId, data)`.
Thread IDs: in 1:1 chats, the other person's user ID; in groups, the group's ID.

Sender-uploaded records (v1.1 "sender backups"): the record starts with a 64-byte XEdDSA
signature (by the sender's Signal identity key) over `"minos.unstructured_signature.message:" + ciphertext`.
- The key comes from the thread's **MEK**, a 32-byte secret encrypted to the mailbox's Hawk keypair:
  `messageKey = HKDF(mek, MINOS_SALT, "minos.kdf.mek.single_message_key:;message_id=<id>;thread_id=<hex>;timestamp=<dec>")`.
- AAD = `"minos.symmetric_enc.message_v2:mek_id=<hex>;message_id=<id>;sender_transport_pk=<hex>;thread_id=<hex>;timestamp=<dec>"`.
- `MINOS_SALT = SHA256("minos encrypted backup protocol\n")`.
- The mailbox keypairs are derived from the epoch root key with MINOS_SALT and the info strings
  `minos.kdf.export_root_key.{auth_keypair,encryption_keypair,signing_keypair}:epoch_number=<seq>`.
- MEKs are opened with `hawk_decrypt`, whose AAD is `minos.hpke.mek_distribution_from_{minos,transport}_v2:...`.

Plaintext: a 4-byte big-endian length, then the message, then PADMÉ padding (at least 10
bytes). The message is a protobuf from facebook/messaging_schemas; older records used a MIME-style
encoding.

## Primitives (Go)

| Primitive | Implementation | Go |
|---|---|---|
| Symmetric (v1.0) | AES-GCM-Extended: `subkey = HChaCha20(key, nonce[0:16])`, AES-256-GCM with `nonce[16:28]`; the 28-byte nonce is prepended | `x/crypto/chacha20.HChaCha20` + `crypto/aes` |
| Symmetric (v1.1) | AES-256-DNDK-GCM, KC_Choice=1, LN=24 (draft-gueron-cfrg-dndkgcm) | needs writing from the draft |
| Labyrinth HPKE | X25519 ×2 → HKDF(id‖ephem, psk, 0x01‖senderAuthPub‖recipEncPub‖ephemPub‖aad) → AES-GCM, zero nonce; output `0x01‖ephemPub‖ct` | `crypto/ecdh` |
| Hawk HPKE | X25519 ×2 + ML-KEM-768, combined with HKDF; the exact combiner isn't specified | `crypto/mlkem` (Go 1.24+); the combiner needs the web code |
| Signatures | XEdDSA | whatsmeow's libsignal already has it |
| ORF | Ristretto255 (attachments only) | `filippo.io/edwards25519` / gtank/ristretto255 |
| MAC, KDF | HMAC-SHA256, HKDF-SHA256 | standard library |

## What the papers don't say (steps 2 and 3)

- The Backup Key Vault exchange: PIN → recovery code. This is the hardest part.
- Every network call: GraphQL or LightSpeed names, and the request and response formats for the
  virtual device, epochs, entropy, MEKs, message ranges and attachments.
- The Hawk HPKE combiner details, and the exact HKDF output splits (key lengths, order).
- How `version` and `epoch_id` appear in fetched records, and the record framing.
- The recovery code's GF(32) generator matrix (only needed for correcting typos).

## What the web app's code shows (step 2, 2026-10-17)

Captured with `WebCapture` (App/WebSync/WebCapture.swift) and from the page's JS bundles:
- The E2EE code runs in a module **SharedWorker** (`/static_resources/webworker/init_script/`).
  The page's CSP (`worker-src`) only allows Meta's worker URLs, so page hooks can't reach inside it.
- The crypto is a **WebAssembly** module (`EBGetCryptoWasm`, `EBLabyrinthWasmReactorSingleton`,
  `EBMinosWasm*`), called with protobuf messages (`EBWasm.pb`).
- PIN → secret goes through **Vesta** GraphQL mutations (`VestaServerGraphQLLoginProviderBeginLogin` /
  `FinishLogin`, `mwEBGetPINSecretFromVesta`), an OPAQUE-style login.
- Adding the device: `EBFetchVirtualDeviceInfoQuery`, `LSDecryptVirtualDeviceSecretsForDeviceAdditionV2`,
  `EBAddDeviceMutation`, `EBSyncEpochs`.
- Main-thread GraphQL seen without a restore: `useMWEncryptedBackupsFetchBackupIdsV2Query`
  (`xfb_backup`: backup ID, the virtual devices) and `EBMessageMetadataQueryQuery`
  (`encrypted_backup.mailbox.deanon_messages_metadata`).
- The web app's IndexedDB (per user ID): `recovery_code_v1`, `messenger_web_ebdb_v1`,
  `messenger_web_eb_minos_db_v11`.

## Plan

1. ~~Read the specification~~ (this file).
2. Capture one web restore with network logging (the `WebNetLog` setting), with the user entering the PIN.
3. Read the web app's JavaScript only where steps 1 and 2 leave gaps.
4. Implement it in the Go core: primitives, vault, enrollment or read-only access, epoch walk, decryption.
5. Replace the web view importers, keeping them as a fallback.

Calls aren't covered: they would still need the web view.
