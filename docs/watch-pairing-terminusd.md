# terminusd: bootstrap and long-term pairing keys

Offline analysis, 2026-11-10. This advances the investigation in
[watch-pairing-notes.md](watch-pairing-notes.md); it does not yet implement a companion.

## Artifact and method

Extracted `/usr/libexec/terminusd` from the existing iPhone VM through the guest
files API after the agent finished booting. The VM is now stopped; the watch VM
was not altered. No unpair or erase was performed.

- Local artifact: `/Users/makr/Documents/Coding/vphone/re/terminusd/terminusd`
- Size: 2,431,056 bytes; Mach-O arm64e.
- SHA-256: `4e54badf30142cfa09b5f7799944208c301e637c947c07114d001be2dab3e9de`
- Addresses below are unslid virtual addresses in this exact image.
- Evidence is static ARM64 disassembly from Apple's `llvm-objdump`, Objective-C
  metadata from `otool -ov`, and selector annotations using the already installed
  Python Capstone. These are ordinary tool observations, not REA Evidence IDs or
  observations of executed branches.
- Hopper is excluded at the user's request. REA did not produce a successful
  native analysis. The initial pass used the existing tools only; Ghidra was
  subsequently installed at the user's request (details below).

Derived files beside the binary: `disassembly.txt`, `objc.txt`, `annotated.txt`,
`methods.tsv`, and `annotate.py`. The annotation helper is specific to this image:
it assumes file offset = VA - `0x100000000` for file-backed data and uses low
32-bit rebase targets for selector pointers. Cross-check critical conclusions
against raw bytes and disassembly rather than treating annotations as a generic
Mach-O parser.

## Main correction: there are multiple secrets and stages

The original log observation of `DigitalSignatureED25519` does not establish
the authentication method of the very first pairing session. The binary has an
OOBK bootstrap path, an IDS path, and a newer pairing mechanism.

In the OOBK path, an initial IKE session is configured with authentication method
2 and an externally supplied secret. Public keys are exchanged in private
IKE_AUTH notifications. Subsequent configurations use signature authentication
and the ingested remote public key. Per-class shared secrets are separately
computed by X25519 key agreement.

Thus at least these concepts must remain separate:

1. The initial out-of-band key (OOBK), received from a local client.
2. The X25519 shared secrets associated with Class D/C/A key material.
3. The transient Curve25519 DH result negotiated by IKE_SA_INIT.
4. The modern pairing derived secret and PPK, on a separate code path.

## OOBK reaches terminusd over XPC

At `0x100069aa8`, code loads `_nrXPCKeyOutOfBandKey`, calls
`xpc_dictionary_get_data` at `0x100069ab8`, and copies the bytes into zeroing
NSData at `0x100069ad8`. Nearby fields include pairing protocol version,
`wasInitiallySetupUsingIDSPairing`, and `pairWithSPPLink`.

The registration routine explicitly accepts `outOfBandKey:` alongside
`isModernPairing:` and `authMethodUsedForModernPairing:`; its diagnostic string is
referenced at `0x10016c778` and following sites.

In the responder OOBK branch, `0x10000e288` selects authentication method 2;
`0x10000e2ec` sets the shared secret from a stored key object. A nearby diagnostic
identifies this as receiving a session for pairing with OOBK. The initiator
counterpart selects method 2 at `0x100016338` and sets the stored secret at
`0x10001639c`.

**Established:** this path consumes externally provisioned bootstrap material.
**Not established:** the identity of the client producing it, the generation
algorithm, or whether this is the branch used in the retained VM capture.

## Public keys are inside IKE_AUTH private notifications

A pairing callback beginning at `0x10000f7f4` constructs the following
`NEIKEv2PrivateNotify` objects and installs them using
`setCustomIKEAuthPrivateNotifies:` at `0x10000f930`:

| Notify | Data source |
| --- | --- |
| `0xc4af` | Device identity payload from `copyDeviceIdentityPayloadForNRUUID:` (`0x10016fadc`) |
| `0xc4eb` | First queried pairing-key payload |
| `0xc4ec` | Second queried pairing-key payload |
| `0xc4ed` | Third queried pairing-key payload |

The query routine `0x10016fe8c` builds Class D, C and A payloads in that order;
it selects legacy or modern encoding through its `modernFormat` argument.
The query callback at `0x1000161e8` retains the three returned payloads in the
pairing client. The exact notification-to-class mapping should still be checked
at both send and receive callback sites before implementing the wire protocol.

Legacy payload construction at `0x10016fb94` appends Ed25519 public key data
followed by X25519 public key data. The corresponding ingest routine at
`0x1001712dc` requires exactly 64 bytes: the first 32 become the remote signature
key; the second 32 are passed to the key-agreement routine at `0x100171390`.

Modern construction at `0x10016fd0c` uses `_NRTLVAddData` with type 1 and type 2.
The ingest callback at `0x10017176c` reads a one-byte type, a big-endian two-byte
length, and value bytes starting at offset 3. Types 1 and 2 each require length
32, with diagnostics identifying Ed25519 and X25519 respectively.

These notifications are configured for IKE_AUTH, not placed in cleartext in
IKE_SA_INIT. Their existence does not make the retained encrypted capture
decryptable without the necessary session secrets.

## Per-class SharedSecret is X25519

`-[NRDLDKeychainItemSecKey createSharedSecretUsingPublicKeyData:]` begins at
`0x100163560`. It creates a public SecKey with `kSecAttrKeyTypeX25519` and
`kSecAttrKeyClassPublic`, then calls `SecKeyCopyKeyExchangeResult` with
`kSecKeyAlgorithmECDHKeyExchangeStandard` at `0x100163650`.

The legacy ingest path stores its result in the keychain-items object's shared
secret slot at `0x100171398`. This is direct evidence that this SharedSecret is
derived from local private / received X25519 public material, rather than from
Ed25519 signing keys.

A later session configuration at `0x100149fdc` calls
`initWithNonStandardDigitalSignature:3`; it installs the remote public key at
`0x10014a010` and the local private key at `0x10014a02c`. This is consistent with
the previously observed Ed25519 runtime logs, but this offline pass has not
matched the exact captured session to this branch.

## Modern pairing is an additional mechanism

`NRDevicePairingCandidateContext` contains `establishPairingSessionIfNeeded` and
`deriveSharedSecretForPairingWithDispatchGroup:` paths. Observed configuration:

- At `0x10012d864` onward, auth method values 1, 2 and 3 select different branches.
- Value 2 creates `initWithSecurePassword:0x2af9` at `0x10012d9ac`.
- Other accepted branches create method 2 authentication at `0x10012da2c`.
- `setSharedSecret:` is called at `0x10012da50`.
- A separate helper `0x10012e038` converts the UTF-8 label
  `Derived IKEv2 PPK for terminus device pairing` and invokes `0x10014135c`.
- That helper uses `CCKDFParametersCreateHkdf` and `CCDeriveKey`, producing
  64 output bytes. Full input ordering and digest interpretation remain to be
  verified before reproducing this derivation.
- The result is installed using `setPpk:`, `setPpkMandatory:YES`, and
  `setPpkIDType:1` at `0x10012da74`–`0x10012da8c`.
- The derivation code includes a salted PIN/PBKDF2 branch, but this alone does
  not establish its parameters or show that a PIN was used by these VMs.

Do not merge this mechanism with the older OOBK path based only on similar names.

## Capture limitations and next investigation

In `btvc-pair.pcap`, the first retained IKE packets occur at Unix timestamp
`1794326627.765130`. The retained unicast `_nrd` response is later, at
`1794326632.569081`. This does **not** exclude earlier discovery: the original
host-to-host filter misses multicast mDNS. Likewise, the capture excludes UDP
4500, and its BTVC stream alone does not cover every possible bootstrap channel.

Next useful work, in order:

1. Trace the XPC registration handler's caller, especially NanoRegistry's
   `outOfBandKey:` provisioning. This may require extracting its daemon and
   framework from the iPhone; keep the VM off until extraction is needed.
2. Correlate retained logs with OOBK / IDS / modern branch diagnostics. This is
   needed before choosing an authentication implementation for the VM path.
3. Verify notification-to-class mapping on receive and identify initial IKE
   identifiers and authentication inputs.
4. Only then implement a minimal IKE responder and test with the watch while
   capturing unicast plus multicast discovery. Preserve the existing pairing
   and fresh-image backups.

## Follow-up: NanoRegistry → IDS → NetworkRelay

The stopped iPhone's System APFS volume can be mounted read-only, without booting
the VM. Extracted two more small executables, not the multi-GB dyld cache:

| Artifact | SHA-256 |
| --- | --- |
| `/usr/libexec/nanoregistryd` | `045798421b6d8d49240be52d04e314db2c7af238b8374f87433b9d8df2916bfb` |
| `/System/Library/PrivateFrameworks/IDS.framework/identityservicesd.app/identityservicesd` | `b8f9e39a92b6b0208d0352e58cc520d8f7ed2ad84b97a0bcf7c06978b507a041` |

Copies and analysis files are under sibling `re/nanoregistryd` and
`re/identityservicesd` directories beside the original `re/terminusd` directory.

### Bluetooth OOB data is one path, but VM pairing has an explicit alternative

`-[EPOOBKeyGeneratorManager update]` at `0x10009879c` in `nanoregistryd` checks
agent availability. If available and no key exists, it calls CoreBluetooth
`retrieveOOBDataForPeer:nil` at `0x100098880` and stores the returned value with
`setKey:` at `0x100098898`. This locates the provider of this generator's data;
it does not establish how CoreBluetooth generates it internally.

More relevant to VMs: `EPSagaTransactionExtensiblePairing` explicitly tests
`isVirtualDevice` at `0x100101bc4` and selects
`_beginNetworkRelayBluetoothPairingTransaction` at `0x100101c4c` when true.

`EPSagaTransactionPairIDSDevice beginTransactionWithRoutingSlipEntry:serviceRegistry:`
at `0x10001c188` reads the `useNetworkRelayPairing` operand (global string pointer
at `0x100189be8`) and stores it as a Boolean. At `0x10001c3a0`–`0x10001c3c0`, a
true value selects `[NSData data]` in place of the stored OOB key. This object is
passed to `IDSLocalPairingAddPairedDeviceInfo` as `BTOutOfBandKey:` at
`0x10001c3fc`. The `supportsDirectIPSecPairing` operand (pointer at
`0x100189cd8`) separately controls `setShouldPairDirectlyOverIPsec:` at
`0x10001c42c`.

**Important inference boundary:** this demonstrates an intentional empty-data
bootstrap input in one NetworkRelay registration path, not yet a runtime proof
that the captured VM's IKE uses an empty PSK.

### IDS forwards the OOB input without deriving a new key in the inspected helper

Craft Anything's CLI successfully analyzed `identityservicesd`. Its disassembly
record for the registration-property helper is
`ev_24d872b661e2b3cada658e60b47fd88d4ee16bd647372142412e55341c72cd85`;
the local copy is `re/identityservicesd/craft-registration-asm.json`.

`-[IDSPairingManager _createRegistrationProperties:maxCompatibilityVersion:BTOutOfBandKey:supportsIPsecWithSPPLink:bluetoothMACAddress:]`
at `0x10046ee9c` sets the pairing protocol version, the IDS-pairing Boolean, the
OOB key, Bluetooth MAC, and SPP flag. At `0x10046ef10`, it selects **nil if
wasInitiallySetupUsingIDSPairing is true, otherwise the caller's BTOutOfBandKey**,
and calls `setOutOfBandKey:` at `0x10046ef18`. There is no key derivation in this
small helper.

`addLocalPairedDevice:BTOutOfBandKey:shouldPairDirectlyOverIPsec:pairingType:bluetoothMACAddress:`
at `0x10046c5c4` preserves its OOB argument in x20 and direct-IPsec Boolean in
x23. The direct-IPsec branch at `0x10046c7e8` passes false as the IDS-pairing
Boolean and the unchanged OOB object to the property helper at `0x10046c81c`.
It then calls the NetworkRelay registration wrapper at `0x10046c848`.

The wrapper `0x10046f018` calls `NRDeviceManager registerDevice:properties:queue:completionBlock:`
at `0x10046f17c`. Combined with the terminusd XPC handler, this narrows the chain:

`NanoRegistry transaction → IDS registration properties → NRDeviceManager → terminusd`.

The observed functions do not insert a new secret between the inspected IDS
entry point and registration call. The serialization in NetworkRelay.framework,
the empty-key handling in the IKE implementation, and correlation with the actual
watch run are still open.

At the terminusd storage boundary, `NRDLDKeychainItemData`'s initializer at
`0x10016098c` rejects nil data but stores a non-nil NSData at offset `0x10`
without checking its length on the successful path (`0x1001609c4`–`0x100160a04`).
Thus an empty NSData is not rejected by this constructor. Whether NEIKEv2 accepts
it as authentication material still needs independent evidence.

### Craft Anything tooling and caveats

CLI: `/Applications/Craft Anything.app/Contents/MacOS/craft-anything-cli`.
Its `mcp` command also exists, but no Craft Anything MCP tools were attached to
this chat; the CLI sufficed. Investigation project:
`/Users/makr/Documents/Coding/vphone/re/watch-pairing.cany`.

Built-in packet analysis of the retained capture produced
`ev_d507398ed933f9f7146389e1bffb63d82dab17aa7ed48225f9ffe829f110d044`:
198 packets, 33 flows, 633.9 seconds. Its decoder is per packet and does not
reassemble TCP or decrypt IKE.

Do **not** trust the built-in register-level pseudocode for argument values in
this image: it rendered real `mov x22,x6` / `mov x20,x4` instructions as assignments
from `xzr`. Its disassembly preserved those instructions correctly and was
cross-checked against Capstone and the binary. Selector-stub annotations were
added separately using Objective-C metadata.

The user supplied Ghidra 12.2's release ZIP; CRC verification passed and it was
extracted to `/Users/makr/Applications/ghidra_12.2_PUBLIC`. This release requires
JDK 25, per its `Ghidra/application.properties`. Ordinary Homebrew JVMs crash on
this host in `CodeHeap::allocate`; the existing
`/Users/makr/Java/zulu25-jdk-jitfix/bin/java` works. The native decompiler was built
from the shipped C++ sources using `make -j2 ghidra_opt`, overriding `CXX` with
`clang++ -std=c++11`, `ARCH_TYPE=-arch arm64`, and
`ADDITIONAL_FLAGS=-mmacosx-version-min=13.0`. It was installed as
`Ghidra/Features/Decompiler/os/mac_arm_64/decompile`.

Craft Anything changes HOME to a temporary directory. The user's existing
`jitfix` wrapper uses `$HOME/Java/...`, so it fails in that environment. A separate
wrapper JDK at `/Users/makr/Applications/ghidra-java25-jitfix` uses absolute paths
to the same Java and fix library, without modifying the user's original wrapper.
Craft Anything's `engines.ghidra.java_home` points there, `install_dir` points to
Ghidra 12.2, and `memory_gb` is 1. Run with `--deep`; the user's global mode is
unchanged. Do not describe fallback built-in output as Ghidra output.

Validation: direct headless Ghidra successfully produced C-like pseudocode for
`0x10016098c`, `0x10012e038`, `0x10016fb94`, `0x10014135c`, `0x10016fd0c`,
`0x1001712dc`, and `0x100163560`; files are in `re/terminusd/ghidra-c/`.
The standalone project is `re/ghidra-projects/terminusd`; its initial automatic
analysis was capped at 90 seconds and is **partial**. Subsequent requests used
`-noanalysis` and the focused `re/ghidra-scripts/PairingFunctions.java` script.

Craft Anything's full initial analysis exposed a Ghidra 12.2
`ObjcMessageAnalyzer.getAddressFromVarnode` recursion problem (and an
ArrayIndexOutOfBoundsException). A backed-up launcher wrapper applies
`DisableObjcMessage.java` only to the Craft cache path for this terminusd digest.
It disables `Objective-C Message Analyzer`; other analysis remains enabled.
The original launcher is preserved as `support/analyzeHeadless.original`.
Selector identities must therefore continue to be cross-checked against the
separately recovered metadata. The direct pseudocode confirms that the
`NRDLDKeychainItemData` initializer checks nil but not NSData length.

End-to-end Craft Anything validation also succeeded: the CLI returned
`environment.engine = ghidra`, `engine_version = 12.2` for `0x10016098c`, with
Evidence ID `ev_74f4c321181cd5e2d395ba3e712bb0e6778634fa0d5ea1af01854caf208ce9ea`.
The complete response is `re/terminusd/ghidra-working-test.json`. The corrected
initial automatic analysis completed in 186 seconds and its database was saved
in Craft Anything's Ghidra cache. Future rebuilds of this target's cache are capped
at 90 seconds / two CPUs by the launcher wrapper; a capped analysis must be
reported as partial. Existing cached function requests do not need a full rebuild.
