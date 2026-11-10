# Apple Watch pairing between VMs: what we found

Research notes, 2026-11-10. Guests: watchOS 26.4 (23T240, Watch7,18) and iOS 26.4 (23E246, iPhone17,3), both in vphone-cli on one Mac. Goal: let the Monolith app itself act as the watch's iPhone, with no second VM.

## How the two VMs pair

1. **Discovery: BTVC, Apple's virtual Bluetooth controller in `bluetoothd`.**
   - Bonjour service `_btvc._tcp` (TXT `model=…`).
   - The peer connects to the advertised TCP port with an HTTP `GET /` WebSocket upgrade. Header `BTVCBonjourEndpointClientUUIDHeader: <uuid>`, answered by `BTVCBonjourEndpointServerUUIDHeader`.
   - Messages are binary frames, each a bplist dict: `{BTVCBonjourServiceMessageType, BTVCBonjourServiceMessageValue}`. Types: `Connect`, `DataPacket`, `Disconnect`, `StartAdvertiseData`, `StopAdvertiseData`.
   - Only `StartAdvertiseData` was seen, an array of LE advertisements: `{et, dtl, da, sPHY, tp, pPHY, pai, pa (address), dat, at, aSID, data (raw AD: Apple 0x4C, type 0x10 Nearby Info), rssi}` plus `BTVCBonjourLinkType: 1`.
   - **Between VMs, BTVC carries only advertising: no `Connect` or `DataPacket` was sent during pairing.**
   - bluetoothd classes: `BTVCBonjourLink`, `BTVCBonjourService`, `BTVCBonjourEndpoint`, `BTVCConnectionManager` (fake HCI LE).
2. **NanoRegistry: the watch advertises `_nrd._tcp`**, instance `<uuid>._nrd._tcp`, host `Apple-Watch.local`. Its TXT keys `nrAT`, `nrD` and `nrN` are binary: an auth tag, data and a nonce.
3. **Pairing itself: IKEv2 over UDP, and the watch initiates.**
   - Packets carry a non-ESP marker. `IKE_SA_INIT` goes from the watch's ephemeral ports to the iPhone's IKE port (62743 in the capture). That same port then carries ESP.
   - Proposal: ENCR AES-GCM-16 with 256-bit keys, PRF HMAC-SHA2-256, DH group 31 (Curve25519).
   - Notifies: NAT_DETECTION_SOURCE_IP and NAT_DETECTION_DESTINATION_IP, IKEV2_FRAGMENTATION_SUPPORTED (0x402e), SIGNATURE_HASH_ALGORITHMS (0x402f), and 0x4036.
   - No PIN was shown for "pair manually".
4. **Once paired, all companion traffic is IPsec (ESP in UDP 4500)** between the two.

## From the iPhone's unified log (terminusd)

- The pairing link is `terminusd`, with `IKEv2Session[n, SPIi-SPIr]` objects.
- IKE authentication is `Protocol = DigitalSignatureED25519`: each side has an Ed25519 key and checks the other's signature.
- Related names: `LocalAuth`, `RemotePublicKey`, `SharedSecret`, `NRPairing`, `networkrelay-pairing`, `WatchPairing`, `IDSPinnedIdentity`.
- **Open question: how a fresh pairing first exchanges the Ed25519 keys.** Probably a `SharedSecret` bootstrap, from the BTVC or `_nrd` data or set up by NanoRegistry. Next step: read `terminusd`'s first-pairing path, or answer the watch's IKE ourselves and see where it stops.

## Reference project

https://github.com/LordixDemon/apple_watch_connector reverse-engineered pairing over real BLE on watchOS 26.2: BT_CL on CID 0x3a, SPAKE2+ PIN, uIKE, SMP, and IKE/ESP inside NetworkRelay over L2CAP. It has no license, so use it as a protocol description only and do not copy its code. In VMs the path is different: IKE runs directly over UDP.

## How to reproduce

- **Capture:** guest-to-guest traffic is not seen on `bridge100`. Use `sudo tcpdump -i pktap,vmenet0,vmenet1 'host <watch> and host <phone> and not udp port 4500'`. VM addresses change between installs, so check `vphone-cli vm leases`.
- **Decode:** a scratch script reassembled TCP, stripped the WebSocket framing and printed the bplists.
- **Logs:** neither guest has `/usr/bin/log`. Copy `/private/var/db/diagnostics` and `/private/var/db/uuidtext` out through vphoned's files API and run `strings` on `Persist/*.tracev3`. macOS `log show --archive` printed nothing for the archive.
- **Do not unpair a VM watch.** Its erase fails (`obliteration … Err:89`) and leaves `auto-boot=false` in `nvram.bin` (offsets 0xa04030 and 0xa84030), so the watch then boots to recovery. Keep `Disk.fresh.img`, `nvram.fresh.bin` and `SEPStorage.fresh` (APFS clones) and restore from them.
