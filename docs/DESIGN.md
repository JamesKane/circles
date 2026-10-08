# Circles — Design Document

**Status:** Draft 0.1 · **Started:** 2026-10-08 · **Author:** James Kane · **License:** BSD 3-Clause (see `LICENSE`)

A reimplementation of the Google+ social model on a peer-to-peer backbone, written in Swift 6.4+ and targeting every platform Swift supports.

---

## 1. Summary

Google+ got one idea right that most networks still lack: **Circles**. With Circles you share with the specific people a post is for, not with "followers" or "everyone". Google+ failed for reasons unrelated to that idea. It also relied entirely on a central operator, which could (and did, in April 2019) shut it down.

Circles keeps the Google+ social model (Circles, the Stream, posts, +1s, comments, reshares, Communities, Collections, Events) and removes the central operator. Each user holds their own identity keys and data. Content goes straight to the people it is meant for, encrypted to that audience. A "server" is just another peer that happens to stay online.

## 2. Goals

1. **Circles as the access-control primitive.** Every piece of content has an explicit audience. "Public" is one audience among others, not the default.
2. **No required central infrastructure.** Two devices on a LAN with no internet can still exchange posts. Bootstrap nodes and relays are optional conveniences anyone can run.
3. **User-owned identity.** Identity is a keypair, not an account on someone's server. Users can move devices, hosts, or relays without losing their social graph.
4. **End-to-end confidentiality for non-public content.** Relays and always-on peers store and forward ciphertext they cannot read.
5. **Runs everywhere Swift does:** Apple platforms, Linux, Windows, Android, and (for limited roles) WebAssembly.
6. **Offline-first.** Reading, composing, and organizing Circles all work offline. Sync is eventual.
7. **Modern Swift throughout:** strict concurrency, `Sendable`-clean, actor-isolated state, typed throws where useful.

## 3. Non-Goals (for v1)

- Real-time video/voice (Hangouts). Section 13 covers it as a future extension.
- Global search and trending across the whole network. Discovery is social and opt-in.
- Algorithmic ranking or ads.
- Compatibility with ActivityPub, AT Protocol, or Nostr. Bridges may come later (§13), but the core protocol must not be shaped by them.
- Perfect deletion guarantees. Once a peer has received content, it cannot be forced to forget it. We provide deletion *requests* and tombstones (§9.4).

## 4. Google+ Feature Map

| Google+ feature | Circles equivalent | Notes |
|---|---|---|
| Profile | Signed `Profile` document, with per-field audiences | e.g. phone number visible only to "Family" |
| Circles | Private, local labels on contacts, plus per-circle group keys for encryption | Circle names and membership never leave the owner's devices |
| Stream | Local merge of all authors' feeds the user can decrypt | Ordered chronologically, filterable by circle |
| Posts | Signed, content-addressed `Post` objects | Text, links, media, polls |
| +1 | Signed `Reaction` object addressed to a post | Visible only to the post's audience |
| Comments | Signed `Comment` objects, replicated through the post author | The author is the moderator of their own thread |
| Reshare | A new `Post` that references the original | Only allowed if the original's audience permits resharing |
| Communities | Multi-writer group with its own key schedule and moderators | §8.3 |
| Collections | Author-curated, topic-scoped feeds that others can follow | Effectively a named, public-or-circled sub-feed |
| Events | `Event` object with RSVPs as reactions | Calendar export via iCalendar |
| Notifications | Computed locally from incoming objects | No push server required, but optional push relay (§7.6) |
| Photos | Content-addressed blobs, chunked and encrypted | §9.3 |
| Hangouts | Out of scope for v1 | §13 |

## 5. Architecture Overview

```
┌───────────────────────────────────────────────────────────────┐
│  Apps: SwiftUI (Apple) · Android (Swift core + Kotlin UI)     │
│        Windows/Linux desktop · CLI · headless "pod" daemon    │
├───────────────────────────────────────────────────────────────┤
│  CirclesKit (public API)                                      │
│   Stream · Composer · CircleManager · Communities · Search    │
├───────────────────────────────────────────────────────────────┤
│  Domain         │  Sync engine        │  Audience crypto       │
│  Post, Comment, │  per-author logs,   │  circle group keys,    │
│  Reaction,      │  vector frontiers,  │  MLS for communities,  │
│  Profile, Event │  CRDT merge         │  envelope encryption   │
├───────────────────────────────────────────────────────────────┤
│  Storage: SQLite (metadata + index) · blob store (chunks)     │
├───────────────────────────────────────────────────────────────┤
│  Networking: peer sessions (Noise/QUIC) · DHT · mDNS ·        │
│              relays · NAT traversal                           │
├───────────────────────────────────────────────────────────────┤
│  Platform shims: sockets, keychain, background execution      │
└───────────────────────────────────────────────────────────────┘
```

### 5.1 Node roles

Every node runs the same codebase. A node's role depends only on configuration and uptime:

- **Device node:** a phone or laptop. Intermittently online, holds the user's keys, and does all decryption and rendering.
- **Pod:** an always-on node (home server, VPS, Raspberry Pi) that a user authorizes to store and forward on their behalf. It holds *ciphertext only* for non-public content. It is roughly what a Google account's server-side presence used to provide, except you own it, and several friends can share one.
- **Relay:** a public node that helps with NAT traversal and short-term store-and-forward. It is untrusted and rate-limited.
- **Bootstrap node:** a well-known entry point into the DHT. It is untrusted and replaceable.

#### Pods as implemented (M3, `CirclesKit.PodNode`, `circles-pod`)

- **Pairing:**
  1. `circles-pod init` creates the pod's device keys and prints a pairing code (device ID, X25519 key, host, port).
  2. The owner runs `circles pod add <code>`. This issues a `.storeAndForward` certificate and publishes a new identity-document version listing the pod in `endpoints.pods`. It prints a bundle (that identity document).
  3. `circles-pod pair <bundle>` checks that the document certifies this pod.
- **The pod speaks for its owner.** In sync it presents the owner's identity document. Its Noise key is certified, but only as `.storeAndForward`, so it can't author content or key grants, and it holds no audience keys.
- **Configuration:** every sync between an owner's author device and its pod carries a signed `PodConfig` (the owner's contact list, versioned) as a control message. The pod accepts configuration only from the owner's `.author` devices. It serves, and keeps logs for, exactly the owner and those contacts.
- **Privacy cost:** the pod operator learns the owner's contacts' user IDs (not names). That's acceptable for a pod you run yourself; it needs revisiting for shared pods.
- **Single owner per pod for now.** Multi-user pods need the pod to choose which identity to present per connection. The endpoint record already names the pod device, so that's an additive change.

## 6. Identity

### 6.1 Keys

- **Identity key** (Ed25519): the user's long-term root. Its public key *is* the user's ID. Ideally it is kept offline or in a secure enclave and used only to certify device keys.
- **Device keys** (Ed25519 for signing, X25519 for key agreement): one pair per device or pod, certified by the identity key with a signed `DeviceCertificate` that has an expiry and capabilities (e.g. `post`, `storeOnly`).
- **Identity document:** a signed, versioned record listing current device certificates, revocations, preferred pods and relays, and the user's profile pointer. It is published to the DHT and to every contact.

User ID encoding: `circles:` + multibase(base32) of the multicodec-tagged public key. Human-friendly handles (`@alice`) are local petnames, optionally backed by DNS TXT records or `.well-known` lookup for verification. There is no global name registry.

### 6.2 Recovery

Losing the identity key loses the identity, so recovery has to be designed in from day one:
- An encrypted backup of the identity key protected by a passphrase (Argon2id), stored on the user's pods.
- Optional **social recovery** with Shamir secret sharing across N chosen contacts, k-of-N threshold.
- Key rotation: a new identity key signed by the old one, plus a "successor" record. Contacts follow the chain automatically.

### 6.3 Contact establishment

Adding someone needs their ID and at least one reachable address. Ways to get both:
- QR code or link containing ID, device keys, and pod/relay hints (the primary in-person flow)
- A DNS/`.well-known` handle lookup
- A DHT lookup by ID
- An introduction through a mutual contact (signed introduction message)

## 7. Networking

### 7.1 Transport

- **v1 baseline (all platforms):** TCP + Noise `XX` handshake (`Noise_XX_25519_ChaChaPoly_SHA256`) + a simple stream multiplexer. Noise authenticates both sides directly with device keys, so no certificates are involved.
- **Target (added once available per platform):** QUIC. It gives multiplexed streams, survives NAT rebinding and connection migration on mobile, and makes UDP hole punching easier. Peers authenticate with self-signed certificates whose key is the device key. This is the libp2p-TLS approach, and it works with any TLS stack that allows custom peer verification.
- **Implementation:** SwiftNIO everywhere, behind a `Transport` protocol. Network.framework is used on Apple platforms where it wins: path monitoring, background sessions, and its built-in QUIC (`NWProtocolQUIC`).
- **Negotiation:** a peer advertises its supported transports in its identity document and address records. Two peers use QUIC only when both support it, and otherwise fall back to TCP + Noise. The wire protocol above the transport (§7.4) is identical either way.

#### QUIC status (researched 2026-10-08)

| Option | Platforms | Status | Fit |
|---|---|---|---|
| [`apple/swift-nio-quic`](https://github.com/apple/swift-nio-quic) | macOS 26+, Linux (Ubuntu 22.04+) | Pre-1.0 (0.x). README: *"still in active development and does not offer a stable API yet."* Needs Swift 6.3+ and currently a beta swift-crypto. Under active development, with connection-migration groundwork merged in Oct 2026 (PR #116). | Best long-term fit (SwiftNIO-native, Apple-maintained). No Windows or Android yet. |
| Network.framework QUIC | Apple only | Stable | Good for Apple device nodes. Doesn't help other platforms. |
| [`1amageek/swift-quic`](https://swiftpackageregistry.com/1amageek/swift-quic) | Apple 26+, Wasm, Embedded (Linux in earlier releases) | v2.0.2 (Aug 2026), pure Swift, no NIO or BoringSSL. Pre-1.0 TLS dependencies, needs 6.4 dev snapshots, single maintainer. Earlier releases tested interop with go-libp2p and rust-libp2p. | Interesting for Wasm and libp2p interop, but too early to depend on. Watch it. |
| MsQuic / LSQUIC (C, via C interop) | Windows, Linux (+ Android, partly unsupported for MsQuic) | Mature | Would cover Windows and Android, but adds a C toolchain and BoringSSL/OpenSSL to every build. Last resort. |

**Decision:** QUIC is **not** ready across all of our targets, so v1 ships TCP + Noise as the universal transport. QUIC is added as an optional transport:
1. on Apple platforms through Network.framework (M3–M4),
2. on Linux and macOS pods through `swift-nio-quic` once it tags a release with a stable API,
3. on Windows and Android when `swift-nio-quic` supports them. MsQuic is a fallback only if UDP-dependent features (hole punching success rate) prove essential before then.

Re-check `swift-nio-quic` at each milestone boundary.

### 7.2 Peer discovery

1. **LAN:** mDNS/DNS-SD service `_circles._tcp` (TXT: `v=1`, `u=<UserID>`, `d=<DeviceID>`). This is our own minimal RFC 6762/6763 implementation on SwiftNIO, so it's identical on every platform.
   - The responder shares port 5353 with the system responder (address and port reuse), announces on start, answers queries, and sends **goodbye** records (TTL 0) on shutdown.
   - The browser queries from an ephemeral port, so responders reply to it directly by unicast (RFC 6762 §6.7). Browsing therefore works even where 5353 can't be bound.
   - Verified against Avahi, which fully resolves our advertisement. IPv4 only for now.
2. **Known peers:** addresses from identity documents, cached per contact.
3. **DHT:** Kademlia over the same transport, keyed by user ID. It stores signed identity documents and "where to find me" records, never content. Records are signed and have a TTL.
   - *As built (M6, `CirclesDHT`):* the only record type is the signed identity document, whose endpoints already say where to find someone. Records verify themselves, a higher version replaces a lower, and they expire after 24 hours unless republished (every 30 minutes by `circles serve`, pods and the GNOME app's node).
   - Node IDs are hashes of Noise static keys, so a contact's ID is proven by the handshake that reaches it. Nodes record contacts at the address they connected from, never one they claim, and only nodes that say they listen are added to routing tables. Buckets of k=20 keep long-lived contacts over newcomers; lookups ask alpha=3 at a time.
   - Value lookups collect records from every responder and keep the newest version, so a stale or lying node can't hide an update.
   - DHT requests share each device's sync port: the first frame's tag (64 and up) tells them apart.
   - Who listens: pods (at their configured address) and relays run with `--dht-port`, which act as bootstrap nodes. A user's device offers itself only while router port mapping is active, using the mapped port; otherwise it only asks, so unreachable devices don't fill routing tables.
   - Devices join through configured bootstrap nodes, nodes remembered from last time, their own pods and their contacts' pods. Pods keep their owner's identity document (and the owner's communities') published while the owner is away.
   - Uses: adding a contact by user ID alone (`circles contact add circles:…`), and in `syncAll`, when every known route to a contact or community fails, looking up a newer document and trying its addresses once.
   - Not yet: S/Kademlia disjoint lookups and per-peer rate limits (M7); records are kept in memory only, so a restarted node relies on owners republishing.
4. **Pods and relays:** listed in the identity document as stable rendezvous points.

### 7.3 NAT traversal

- Address observation through peers (STUN-like "what's my address" exchange).
- Coordinated UDP hole punching using a relay as signaling. **Deferred to the QUIC milestone (decided 2026-10-08):** v1 is TCP-only, and TCP simultaneous-open punching has poor success rates. Relays guarantee connectivity meanwhile.
- Relayed connections as the fallback, end-to-end encrypted so relays only see ciphertext.
- UPnP-IGD / NAT-PMP / PCP when available.

#### As implemented in M3

- **Relays** (`CirclesNet.RelayServer`, `circles-relay`), similar to libp2p circuit relay v2:
  - A device opens a control connection, authenticates with its device key over Noise, and sends `reserve`.
  - A peer opens a data connection and sends `connect(target key)`. The relay sends `incoming(token)` to the reserved device, which opens its own data connection and sends `accept(token)`.
  - The relay then answers `ok` on both and **forwards frames unchanged**. The two peers run their own Noise XX session end to end, and each checks the other's static key. The relay sees only ciphertext and can't impersonate either side.
  - The relay authenticates clients only by key: anyone may reserve, but only for a key they hold.
  - Limits per relay: reservations (1024), circuit duration (10 min) and bytes (64 MiB).
  - Users list relays in `endpoints.relays` together with the relay's key, so clients pin it. `circles serve` keeps a reservation on each listed relay and reconnects after failures.
- **Router port mapping** (`CirclesNet.PortMapper`): tries PCP (RFC 6887), then NAT-PMP (RFC 6886), then **UPnP-IGD**.
  - UPnP was added because the test network's router, like most consumer routers, speaks only UPnP.
  - Mappings are renewed at half their lifetime and removed on shutdown.
  - `circles serve --map-port` maps the listening port. `--publish-direct` also lists the public address in `endpoints.direct`. That's opt-in, because it reveals the address to everyone who receives the identity document.
  - Gateway discovery for NAT-PMP and PCP reads `/proc/net/route` on Linux and the routing table (`sysctl` `NET_RT_FLAGS`) on Apple platforms, preferring the unscoped default route. Windows has none yet. UPnP finds the router by multicast, so it works everywhere.
  - Router quirk seen in testing: some routers store the wildcard remote host as `0.0.0.0` and answer `GetSpecificPortMappingEntry` only in that form (deleting works with the empty string). Lookups try both.
- **Route order** (`Account.syncAll`):
  1. peers found by mDNS
  2. our own pods, always
  3. for each contact not yet reached: their pods, then their direct endpoints, then each of their author devices through each of their relays

  Verified with separate processes: store-and-forward through a pod while the owner was offline, and data delivered when the only route was a relay.

### 7.4 Wire protocol

- Messages are length-prefixed **deterministic CBOR** (RFC 8949 §4.2.1, core deterministic encoding). Swift `Codable` types use our own encoder (`CirclesCore/CBOR`) so that signatures are stable.
  - **Restricted data model:** unsigned and negative integers, byte strings, UTF-8 text, arrays, maps, booleans, null. **No floating point** (the encoder throws on it), no tags, no `undefined`, no indefinite lengths. Anything numeric in a signed object is an integer in fixed units (milliseconds, pixels, bytes).
  - **Strict decoding:** the decoder rejects any input that isn't already in deterministic form (overlong arguments, unsorted or duplicate map keys, and so on). If something decodes, its encoding is unique.
  - **Forward compatibility:** unknown map keys are ignored when decoding, so **signatures and ContentIDs are always checked against the received bytes, never a re-encoding**.
  - Absent optionals are omitted rather than encoded as null, so adding an optional field doesn't change the encoding of objects that don't use it.
  - A golden test pins the encoding of a sample `Post`. Any change to it is a wire-format break.
  - **Tagged unions** (`RichText.Run`, `LogBody`, `SyncMessage`) are encoded by hand as `[tag, fields…]` with permanent tag numbers. Swift's synthesized enum encoding (verbose `_0` keys) is never used on the wire. Unknown tags are rejected, so a new tag needs a format version bump. (Done in M2.)
- The protocol is versioned. Peers negotiate a version range during the handshake.
- Core RPCs: `Hello`, `GetIdentity`, `GetFrontier`, `GetLog(range)`, `GetObjects([cid])`, `GetBlob(cid, range)`, `Push(objects)`, `Subscribe(feed)`.

### 7.5 Anti-abuse at the network layer

- Rate limiting per peer and per ID.
- Unsolicited messages are accepted only from contacts or carry a proof-of-work/postage token. This governs first-contact requests.
- Allowlist mode for pods: they serve only their owners and the owners' contacts.

### 7.6 Mobile push

iOS and Android kill background sockets. An optional **push relay** (self-hostable) receives a minimal, content-free "you have something" ping from a pod and forwards it through APNs or FCM. The device then wakes and syncs directly. The push relay only learns that a ping happened, never what it was about.

## 8. Audience and Encryption Model

This is the heart of the design.

### 8.1 Circles

- A circle is a **local, private** label: `Circle { id, name, members: Set<UserID> }`. Like on Google+, members never learn which of your circles they are in, or what those circles are called.
- For each circle, the owner keeps a **circle key epoch**: a symmetric key that rotates whenever membership shrinks (it may also rotate on growth, for forward secrecy toward new members).
- Circle keys are delivered to each member with pairwise-encrypted `KeyGrant` messages (X25519 + HKDF + ChaCha20-Poly1305 to each of the member's devices). Grants are labeled with an opaque random audience ID, not the circle name.

### 8.2 Posting to an audience

A post's audience is a set of circles, individuals, or `public`.

1. Serialize and sign the post with the device key.
2. Generate a random content key (CEK) and encrypt the post body with it.
3. Wrap the CEK for each target: once per circle (under the current circle key epoch) and once per individually named recipient (pairwise).
4. Publish an `Envelope { cid, authorID, wrappedKeys[], ciphertext }`. The audience IDs in `wrappedKeys` are opaque.

Public posts skip encryption and are signed only.

Leaving a circle: the next post uses a new epoch the removed member doesn't have. They keep posts they already received. This matches Google+ semantics, where removing someone hid future posts but couldn't erase what they had seen.

#### Construction (implemented in M1, `CirclesCrypto`)

- **Signatures** are Ed25519 over `label || 0x00 || payload`, where the label names the purpose (`circles/v1/post`, `…/comment`, `…/device-certificate`, `…/key-grant`, …). A signature made for one purpose can never be accepted for another. The label is supplied by the verifier and isn't transmitted. A `SignedObject` carries the exact payload bytes, and verification never re-encodes them (§7.4).
- **Sign, then encrypt.** The envelope plaintext is an encoded `SignedObject`, so which of the author's devices signed it is visible only to the audience.
- **Envelope body:** ChaCha20-Poly1305 under a fresh 256-bit content key, with associated data binding the format version and author. The plaintext is padded with **Padmé** first (it leaks only O(log log n) bits of length, with at most ~12% overhead). This implements the size-bucket mitigation from §8.4.
- **Circle wraps:** the content key is sealed with ChaCha20-Poly1305 under each circle-epoch key. Each epoch key has an opaque random 16-byte `AudienceKeyID`, with no link between epochs. Keyrings index keys by **(owner, key ID)**, so a circle member can't reuse the owner's key to forge envelopes under the owner's name.
- **Device wraps** (individually named people): HPKE base mode, `DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / ChaCha20-Poly1305` (RFC 9180). These carry **no recipient hint**: a device finds its wrap by trial decryption, at one X25519 operation per device wrap. Circle wraps cover the common case, so this stays cheap.
- Each wrap's associated data includes the body nonce, binding it to its envelope. Wraps are sorted by their random bytes, so their order reveals nothing.
- **Wraps aren't authenticated as a set.** Someone who can modify an envelope in transit can strip or corrupt other recipients' wraps (denial of access), but can't change what anyone decrypts. The inner signature guarantees that. A property test checks exactly this.
- **Key grants:** a `KeyGrant` (owner, recipient, key ID, epoch, key) is signed by an `.author` device of the owner, then sealed with HPKE to each of the recipient's devices. On opening, the recipient checks the signature against the owner's verified identity document, and checks that it names them as recipient.
- **When signatures count:** content is checked at its claimed creation time, so old posts stay valid after a device is revoked. Key grants are checked at **receive** time, so a revoked device can't backdate new grants. Content backdating by a compromised device remains possible until revocation propagates. That's an accepted limitation, bounded by the HLC drift check (§9.5).
- **Key material:** identity and device private keys are `~Copyable` types, which can't be duplicated by accident. Audience keys use swift-crypto's `SymmetricKey`, which zeroizes its own storage. They're copyable, because keyrings hold many of them.
- **Deferred:** passphrase backup with Argon2id and social recovery (§6.2), identity-key rotation chains, decoy wraps to hide the recipient count (§8.4), and the platform key store (§10).

### 8.3 Communities (multi-writer groups)

Communities need many writers, moderators, and membership changes made by people other than a single owner. Circle keys don't fit that model, so communities use **MLS (RFC 9420)**:

- The MLS group is the community's membership. Commits are signed by moderators according to the community's policy.
- Posts are encrypted with the current epoch's application secret.
- A *public* community is a signed, unencrypted feed plus a moderator set.

`CirclesMLS` exposes a small `GroupCrypto` protocol (create group, add/remove, commit, process, encrypt/decrypt, export state). The rest of the codebase never touches an MLS library directly, so the implementation behind it can be swapped.

#### MLS implementation status (researched 2026-10-08)

| Option | Language / integration | Status | Fit |
|---|---|---|---|
| [`germ-network/swift-mls`](https://github.com/germ-network/swift-mls) | Pure Swift on `swift-crypto`, MIT | Pre-release (0.1.x). Its `MLS.RFC9420` profile is described as *"conformant — core group lifecycle"*, verified against the official RFC 9420 test vectors and run against mls-rs in the mlswg interop harness. **Not yet supported:** ReInit, branching, external join/commit, external senders. Persistence is outside its conformance claim. No third-party audit. `Package.swift` declares Apple minimums only (macOS 15 / iOS 18), but **Linux is verified** (see spike result below). Windows and Android are still unverified. Effective toolchain floor is Swift 6.2.3. | **Preferred.** No FFI, the same crypto stack as the rest of the app, and a modular design (tree / key schedule / framing are separate products). Young and has very little adoption yet. |
| [`awslabs/mls-rs`](https://github.com/awslabs/mls-rs) | Rust; `mls-rs-ffi` and `mls-rs-uniffi` crates in the repo; Apache-2.0 / MIT | Mature and broad. Crypto providers include OpenSSL, AWS-LC, and CryptoKit, plus a WASM build. README: *"has not yet received a full security audit by a 3rd party."* The UniFFI crate has no README, so Swift/Kotlin binding quality is undocumented. | **Fallback.** Interop with swift-mls has been tested, so a mixed network would still work. Costs a Rust toolchain and cross-compiled static libraries for every target. |
| [`openmls/openmls`](https://github.com/openmls/openmls) | Rust, MIT | The most widely used option. CI tests Linux, Windows, and macOS, and builds Android, iOS, and wasm32. It ships only WASM bindings, with no Swift or Kotlin ones. | Viable only if we write and maintain our own C/UniFFI wrapper. No advantage over mls-rs for us. |
| Write our own | Swift | Large but well-specified job | Not justified while swift-mls exists. We'd contribute upstream instead. |

**Decision:** Communities ship at M5, so there is time for swift-mls to mature. We start with **swift-mls** behind `GroupCrypto`, with **mls-rs via FFI** as the documented fallback. Before M5 we must:
1. **Spike (during M1):** build swift-mls and run its test suite on Linux, Windows, and Android. Anything that fails gets fixed upstream, or it becomes a reason to switch.
   - ✅ **Linux, 2026-10-08:** commit `e6e0350` (2026-09-28), Swift 6.3.1, Fedora 44 x86_64. `swift build` succeeded (~150 s cold, including the gRPC interop server). `swift test` ran **492 tests in 79 suites, all passing, none skipped**, including the official mlswg vector corpus and the differential fuzzing over it. No source changes were needed.
   - ⏳ Windows, Android: still to do.
2. **Design around external commits being missing.** Without them, people can't join a community unless a moderator approves them while online. For now, public and open communities let a moderator's pod issue `Add` commits automatically on request. Switch to external commits when swift-mls supports them.
3. **Own persistence.** Serialize group state into `CirclesStorage` ourselves, with crash-safe epoch transitions: never lose an epoch secret between committing and storing it.
4. **Track audit status** for both libraries. A community feature labelled "secure" needs an audited (or at least independently reviewed) MLS stack before 1.0.

#### Community design for M5 (decided 2026-10-08)

**A community is an identity of its own.**
- It has its own Ed25519 key, the "community key", held by the owner's device.
- Its identity document certifies the community's *serving devices*: the owner's device as `.author`, and optionally pods as `.storeAndForward`. Its endpoints list pods and relays as usual.
- So sync, verification, pods, relays and mDNS all work for communities unchanged: following a community is following its identity.
- A device that serves a community presents the community's identity document, the way pods present their owner's. *As built:* rather than a second listener, the initiator's sync `hello` names a `target` identity (absent means the device's own user), and the responder reads that hello first and answers as the account or as a community it serves. One port, one mDNS advertisement and one relay reservation cover every identity on the device. Older peers never send a target, so they're unaffected.
- The community's document lists the owner's pods, the sequencer's direct address and the owner's relays, and certifies the owner's pods. The owner re-signs it whenever its own endpoints or pods change.

**One sequencer, one order.**
- MLS needs one agreed sequence of commits. The community's log is written by a single **sequencer device** (the owner's), and that device's hash-linked log *is* the order. Commits, Welcomes and posts take effect in log order.
- Only the sequencer commits. Members never commit; they ask the sequencer, which also handles leaving.
- Members process the community log strictly in order, keep their MLS state (sealed snapshots, §8.3 pre-M5 task 3), and store each post **decrypted when processed**. Old epochs' keys are deliberately discarded, so later decryption isn't possible.
- Pods certified for the community store and serve its log (ciphertext for private communities), so the community stays readable while the owner is offline. New posts and members wait for the sequencer.
  - *As built:* the owner's signed pod configuration lists each community's identity document and roster. The pod serves the community only to the listed members, and keeps their logs so their submissions reach the owner on its next sync with the pod. The pod learns a private community's roster, a trade-off accepted because the pod is the owner's own device.
  - Join requests aren't taken by pods: pending members must reach the owner (directly, on the local network or through a relay).
- *Limitations:* a single sequencer is a single point of control and availability; no moderator roles beyond the owner yet; no post-compromise updates initiated by members.

**Membership and joining.**
- The MLS credential is the member's `UserID`. A join request carries an MLS KeyPackage **signed by one of the user's certified devices**. The sequencer checks it against the user's identity document before adding them, so other members can trust the roster: the sequencer is the authority.
- Policies, all in M5:
  - **open:** requests are accepted automatically
  - **approval:** the owner approves or rejects
  - **invite-only:** a request must carry an invite token signed by the community key
- Requests travel as sync control messages to a serving device. Adds and removes are sequencer commits, and each new member's Welcome is published in the community log.

**Posting.**
- A member's post or comment goes into the member's own log, sealed (HPKE) to the sequencer device. The serving device wants members' logs, so it receives them whenever a member syncs with it.
- The sequencer verifies the item and republishes it as a `ThreadItem`-like record, signed by the member and carrying their identity document. For a private community, that record is encrypted as an **MLS application message**.
- Moderation is the same as for threads: only republished items appear, and the owner can remove them with deletions.

**Visibility (decided 2026-10-08):**
- **Public communities:** the log is signed but not encrypted, so anyone can follow it. There's no MLS group, and posting still requires membership.
- **Private communities:** content is MLS-encrypted. **New members see posts from when they join onward**: MLS forward secrecy hides earlier epochs, and re-sharing history was left for later. (Google+ showed history to new members.)

### 8.4 Metadata exposure

What leaks, and to whom:

| Observer | Learns |
|---|---|
| Relay / pod | Author ID, envelope sizes, timing, count of wrapped keys |
| DHT | That an ID exists and its current addresses |
| Audience member | Content, plus the identities of everyone who comments on or +1s the post (by design, matching Google+; §9.4) |
| Non-member contact | That a post exists (if they can see the log), not its content |

Mitigations to consider: padding envelopes to size buckets, and hiding the wrapped-key count by padding with decoys. Sealed sender is a stretch goal.

## 9. Data Model and Sync

### 9.1 Objects

Every object is immutable, signed, and content-addressed. The CID is a **SHA-256** multihash (`0x12`, 32-byte digest) of the object's canonical encoding, computed with `swift-crypto`, which uses hardware SHA extensions where the CPU has them. The multihash prefix leaves room to move to a different hash later without changing the CID format. Blob chunk CIDs (§9.3) use the same hash. For a signed object, the CID is the hash of the signed **payload**, not of the signature wrapper, so it doesn't depend on which of the author's devices signed it.

```swift
public struct Post: Sendable, Codable, Hashable {
    public var author: UserID
    public var created: Timestamp          // hybrid logical clock
    public var body: RichText               // limited markup, mentions, hashtags
    public var attachments: [BlobRef]
    public var reshareOf: ObjectRef?
    public var collection: CollectionID?
    public var replyPolicy: ReplyPolicy     // who may comment / reshare
}

public struct Comment: Sendable, Codable, Hashable {
    public var author: UserID
    public var parent: ObjectRef            // post or comment
    public var created: Timestamp
    public var body: RichText
}

public enum ReactionKind: String, Sendable, Codable { case plusOne, rsvpYes, rsvpNo, rsvpMaybe }
```

Edits are new objects that supersede earlier ones (`supersedes: CID`). Deletes are tombstones.

### 9.2 Per-author logs

- Each author maintains an append-only, hash-linked **log per device**: each entry carries its sequence number, the previous entry's hash, and the envelope CID.
- A peer's sync state with an author is a **frontier**: `[DeviceID: seq]`.
- Sync = exchange frontiers → request missing ranges → verify the hash chain and signatures → attempt decryption → index.
- Peers only serve log entries whose envelopes the requester is allowed to receive. A pod can't check this for encrypted content, so it serves all ciphertext to authorized contacts, and filtering happens by decryption.

> **Open question:** serving every envelope to every contact leaks post frequency and volume. The alternative is per-audience logs, which leak audience structure instead. Prototype both and measure.

#### As implemented in M2 (`CirclesSync`)

- **Log entry** (signed by the device under `circles/v1/log-entry`): author, device, sequence (1-based), previous entry ID, HLC timestamp, and a body. The body is one of: public content (a signed `ContentItem`); sealed content (an `Envelope` whose plaintext is the `ContentItem`, so even the content *kind* is hidden); or a **key grant**. Entry ID = hash of the signed payload.
- **Key grants travel in the owner's log** with no recipient hint, and each device finds its own by trial decryption. This keeps delivery asynchronous, so grants reach members through any peer, including relays. The cost: one HPKE attempt per grant per reader, and the number of grants hints at total circle sizes. Revisit when pods exist (a pod could deliver grants directly).
- **Sync protocol (one-shot, symmetric):** `hello` (identity document) → `control`* → `ready` → `want` (for each wanted author: frontier plus known identity-document version) → `identity`/`entries` replies → `done`. Each side builds its `want` only after the peer's `ready`, so control messages such as a pod configuration shape the same session's requests (added in M3). Each side answers in a separate task, so large transfers can't deadlock. Each side checks:
  - that the peer's identity document certifies the **Noise static key it connected with**
  - that the peer is a contact
  - each entry's signature, certificate and position in the hash chain
- **Relaying:** peers serve any author's entries they hold, not just their own, and supply missing identity documents. Bob gets Carol's posts through Alice, verified against Carol's identity.
- Unknown authors, unrequested entries, and the first bad entry per device (with everything after it) are rejected and reported; they don't abort the session.
- **Not yet:** live subscriptions (a session syncs once and ends; `serve` re-syncs on a timer), and backpressure on received messages (buffered unbounded in memory).

### 9.3 Media

- Blobs are chunked (content-defined chunking, ~256 KiB target), and each chunk is encrypted with a key derived from the blob's CEK. Chunk CIDs are computed over ciphertext.
- Blobs are fetched lazily from any peer that has them: the author, their pods, or other audience members who opted to cache.
- Thumbnails are generated by the author and shipped inline in the envelope.

#### As implemented in M4

- **Chunks:** fixed 256 KiB pieces, not content-defined (simpler; dedup across edits isn't a goal yet). Each attachment gets its own random key. Chunk *i* is sealed with ChaCha20-Poly1305 using nonce *i*, and associated data that binds the index and the total count, so chunks can't be reordered or dropped. A SHA-256 digest of the plaintext is checked after decryption.
- **`BlobRef`** (chunk IDs, key, digest, size, media type, dimensions) lives *inside* the post, so only the post's audience gets the key.
- **Fetching is eager, not lazy (for now).** A log entry lists its chunk IDs in an optional cleartext `blobs` field. Every node that stores the entry, pods included, asks for the chunks in the same sync session (`entriesDone` → `wantBlobs` → `blob` → `done`). This is what makes photos work through a pod while the author is offline. The list reveals no more than the entry's size already does. Lazy fetching and caching policies can come later.
- Thumbnails aren't generated yet.
- **Location is stripped before posting** (decided 2026-10-08). `Account.post` runs every attachment through `LocationScrubber`, pure Swift so every platform behaves the same. It finds the format from the bytes. In JPEG, PNG, WebP and TIFF it zeroes and unlinks the EXIF GPS directory in place, so the image data is untouched, and drops XMP that mentions GPS. GIF and non-image data pass through. HEIC, AVIF and MP4/MOV can carry location too but can't be edited yet, so they're **refused** rather than posted as they are; the Mac app converts HEIC to JPEG first.

### 9.4 Comments, +1s, and threads

- Commenters send comments **to the post author** (and their pods). The author re-publishes them as part of the thread, under the post's audience. As on Google+, the author can moderate (delete, disable comments, block).
- If the author is offline, the comment waits in the commenter's outbox and the author's pods.
- **Visibility follows Google+:** everyone who can read the post sees every comment, along with the commenter's name, avatar, and profile link. That includes people who aren't the commenter's contacts. The same goes for who +1'd. The author re-publishes the thread encrypted under the post's content key, so anyone who can decrypt the post can decrypt its comments, and nobody else can.
- The composer shows the post's audience above the comment box, as Google+ did, so commenters know who will see their reply (e.g. "Visible to: Alice's Family circle (14 people)", or "Public").
- A commenter's profile card in the thread shows only their public profile fields. Fields restricted to audiences are never exposed just because someone commented.
- Reaction counts are a grow-only set CRDT keyed by `(reactor, kind)`. Un-+1 is a tombstone.

#### As implemented in M4 (`CirclesKit/Social.swift`)

- **Contributing:** a comment or +1 is signed by the contributor's device, then sealed (HPKE device wraps) to the post author's author devices *and* the contributor's own devices, in the contributor's log. The contributor sees it at once, marked **pending**.
- **Republishing:** when the author's device reads its contacts' logs, it verifies each contribution to its posts and republishes it as a `ThreadItem`, which holds the contribution plus the contributor's identity document and is signed by the author. It's published **to the same audience as the post**: the same circle keys (found from the post's own envelope), or publicly for a public post. Readers check the author's signature and then the contributor's, so a commenter who isn't the reader's contact is still verified, and shown by the `displayName` in their identity document.
- **Moderation:** only republished items appear for others, so the author's device is the moderator. For now it approves everything from contacts automatically, except comments on posts with `commentsEnabled = false`. A manual moderation UI and deleting comments come later.
- **+1s:** the latest reaction per contributor wins, and `retracted` withdraws one.
- **Reshares:** only of public posts that allow resharing. The reshare embeds the original signed post and its author's identity document (`ContentItem.embedded`), so the resharer's audience can verify it without knowing the original author.
  - *Deviation from Google+:* resharing limited posts isn't supported. It would mean re-encrypting someone else's content to a new audience.
- **Deleting (added on the `gnome/polish` branch):**
  - An author withdraws a post, or removes a comment from one of their threads, with a signed `Deletion` (`ContentKind.deletion`, label `circles/v1/deletion`). It's published **to the post's own audience**, so outsiders don't learn the post existed.
  - Readers honor deletions **only from the post's author**, and hide the post or comment once they sync. A removed comment doesn't come back as "pending" for its writer either.
  - As §3 says, this is a request: anyone who already had the content may have kept it.
  - Commenters can't yet delete their own comments, which would need the author to republish the removal.
- **Limitation:** only the author's contacts can comment, because the author reads contributions from the logs it syncs. Comments from non-contacts on public posts need a delivery path, such as through the author's pod, that accepts strangers with anti-abuse measures (§7.5).

### 9.5 Ordering

Hybrid Logical Clocks provide timestamps. The Stream is ordered by HLC with a per-author causal tiebreak. There is no global order, and none is needed.

## 10. Storage

- **Done in M4:** `SQLiteLogStore` (the system SQLite through a `CSQLite` system-library target, with a small in-house wrapper) holds log entries exactly as received, identity documents, blobs, and the "needed blobs" list. It runs in WAL mode with a busy timeout, appends happen inside `BEGIN IMMEDIATE` transactions, and identity documents only ever move forward. That makes it safe for several processes on one database: a test races two store instances writing the same sequence number, and exactly one wins.
  - Opening an M2/M3 data directory imports the old files once and renames them `*.pre-m4`. Verified on the M3 demo data, for both an account and a pod.
  - Contacts, circles and keyring are still small CBOR files under `account/`; moving them into SQLite remains to do. SQLite is the operating system's own everywhere (decided 2026-10-08): `sqlite3` on Linux and Apple platforms, and on Windows the `winsqlite3` that has shipped with the OS since Windows 10 (header in the Windows SDK). `CSQLite` is a small C target that picks the header and library per platform. Android still needs a decision.
- **M2 interim (replaced in M4):** `FileLogStore` kept one file per log entry (`logs/<author>/<device>/<seq>.cbor`, exactly the received bytes) and one per identity document. Account state lives in small CBOR files, with key material at 0600.
  - Several processes can share a home directory (`circles serve` plus CLI commands): nothing is cached, writes are atomic, and appends create the file exclusively with a hard link, so two writers can't claim the same sequence number.
  - Private keys are stored **unencrypted** at 0600 until the platform secret stores below are implemented.
  - Directory scans are O(entries). SQLite replaces this at M4, when the Stream needs indexes and search.
- **SQLite** is the source of truth for objects, logs, indexes, contacts, circles, and keys metadata. It is accessed through a thin actor-isolated wrapper. (Candidates: GRDB if its Linux, Windows, and Android support is sufficient, otherwise a minimal in-house wrapper over the SQLite C API.)
- **Full-text search:** SQLite FTS5 over decrypted local content.
- **Blob store:** content-addressed files on disk, with per-blob refcount and LRU eviction for cached content from others.
- **Secrets:** Keychain on Apple, Android Keystore, DPAPI on Windows, libsecret on Linux. On headless pods: an encrypted file protected by a passphrase or TPM.
- At rest: the database is encrypted (SQLCipher or page-level encryption) on devices. Pods only ever hold ciphertext envelopes anyway.

## 11. Swift Implementation

### 11.1 Toolchain and language

- **Swift 6.4+**, Swift 6 language mode, complete strict concurrency checking.
- No `@unchecked Sendable` outside a small audited set of platform shims.
- Typed throws (`throws(SyncError)`) on internal module boundaries. Public API uses typed throws only where the error set is stable.
- `~Copyable` types for secret key material, so keys can't be accidentally duplicated. Key material is zeroized on `deinit`.
- Swift Testing (`@Test`) for all tests. Swift Benchmark for crypto and sync hot paths.

> Note: the local toolchain is currently 6.3.1. Bump to 6.4 once it is installed, or relax the floor to 6.3 if no 6.4-specific features turn out to be needed.

### 11.2 Concurrency model

- Each subsystem is an `actor`: `PeerManager`, `SyncEngine`, `KeyStore`, `ObjectStore`, `DHTNode`.
- Network I/O on SwiftNIO event loops, bridged to structured concurrency through `NIOAsyncChannel`.
- Every peer session is a child task in a `TaskGroup` owned by `PeerManager`. Cancelling the group shuts down cleanly.
- UI-facing state is exposed as `AsyncSequence`s and `@Observable` models on `@MainActor`.

### 11.3 Package layout

```
Package.swift
Sources/
  CirclesCore/        — IDs, CIDs, HLC, deterministic CBOR, domain types
  CirclesCrypto/      — signing, envelopes, circle keys, KeyGrant; wraps swift-crypto
  CirclesMLS/         — GroupCrypto protocol + swift-mls adapter (mls-rs FFI as fallback)
  CirclesStorage/     — SQLite, blob store, secret-store protocol + platform impls
  CirclesNet/         — transports, Noise, multiplexing, NAT traversal, mDNS
  CirclesDHT/         — Kademlia
  CirclesSync/        — logs, frontiers, replication
  CirclesKit/         — public façade used by apps
  CirclesPresentation/ — screen models, state, intents, navigation, l10n (no UI imports; §11.6)
  CirclesUITestHost/  — headless backend for end-to-end tests
  circles-pod/        — headless daemon (executable)
  circles-cli/        — developer CLI (executable)
Apps/
  Apple/              — CirclesUIApple: SwiftUI (+AppKit/UIKit) for iOS, iPadOS, macOS, visionOS
  Windows/            — CirclesUIWin: WinUI 3 via swift-winrt projections
  Gnome/              — CirclesUIGnome: GTK 4 + libadwaita
  Android/            — Compose UI over CirclesPresentation via swift-java
Tests/
  …mirrors Sources, plus an in-process multi-node simulation harness
```

### 11.4 Key dependencies (candidates)

| Need | Candidate | Cross-platform? |
|---|---|---|
| Crypto primitives | `swift-crypto` | Yes (CryptoKit API, BoringSSL elsewhere) |
| Networking | `swift-nio`, `swift-nio-ssl`, `swift-nio-transport-services` | Yes (NIOTS is Apple-only, optional) |
| MLS (communities) | `germ-network/swift-mls` (pre-release); fallback `mls-rs` | Linux ✅ verified; Windows/Android to verify (§8.3) |
| QUIC (later) | `swift-nio-quic` (pre-1.0), Network.framework on Apple | macOS + Linux only today (§7.1) |
| Logging / metrics | `swift-log`, `swift-metrics`, `swift-distributed-tracing` | Yes |
| CLI | `swift-argument-parser` | Yes |
| Collections | `swift-collections`, `swift-async-algorithms` | Yes |
| SQLite | GRDB or raw SQLite C | Verify per platform |
| Content hashing | SHA-256 from `swift-crypto` | Yes (no vendoring) |
| Argon2id (key backup, §6.2) | Vendored C reference impl in a C target | Yes. The only remaining vendored crypto, kept deliberately (2026-10-08): it resists GPU and ASIC passphrase guessing better than the scrypt and PBKDF2 options in swift-crypto. |
| Java interop (Android) | `swift-java` | Android/JVM |
| Windows UI | `swift-winrt` (generate our own WinUI 3 projections) | Windows; x64 confirmed, ARM64 to verify (§11.6) |
| Linux UI | Adwaita for Swift, or GTK 4 C interop | Linux (§11.6) |

Rule: no Foundation-only APIs in `CirclesCore`/`CirclesCrypto`/`CirclesSync`. Use `FoundationEssentials` (swift-foundation) where needed so the core stays portable and slim, including for Wasm.

### 11.5 Platform matrix

| Platform | Device node | Pod | Notes |
|---|---|---|---|
| macOS / iOS / iPadOS / visionOS | ✅ | macOS only | Background limits on iOS → push relay |
| Linux (x86_64, aarch64) | ✅ (desktop) | ✅ primary | Static Linux SDK for single-binary pods |
| Windows | ✅ | ✅ | Builds in CI (SQLite via the built-in `winsqlite3`); 137/138 tests pass. **Open:** relayed sessions end early on Windows (the relay end-to-end test is disabled there until debugged on a Windows machine). Plain TCP syncs also occasionally hit a handshake timeout on the Windows runner (seen once in the comments test, 2026-10-08, and it passed on rerun). Probably the same networking issue. DPAPI secret store not done. |
| Android | ✅ | — | Swift SDK for Android; Kotlin/Compose UI |
| WebAssembly | Read-only/light client | — | No raw sockets; WebSocket/WebTransport to a pod |

### 11.6 UI architecture

**Principle:** every platform gets a **native UI**, with its own toolkit, conventions, accessibility, menus, and keyboard handling. All UI talks to the application through **our own presentation layer**, `CirclesPresentation`. The layer sits at the level of *screens and meaning*, not widgets. It describes *what* the user sees and can do. Each platform decides *how* to show it.

We are deliberately **not** building a cross-platform widget toolkit or a declarative UI DSL. Abstractions at the widget level end up limited to what every toolkit has in common, and building a DSL is a project in its own right.

```
┌───────────────┬───────────────┬────────────────┬──────────────────┐
│ CirclesUIApple│ CirclesUIWin  │ CirclesUIGnome │ Android (Kotlin) │
│ SwiftUI (+    │ WinUI 3 via   │ GTK 4 +        │ Jetpack Compose  │
│ AppKit/UIKit) │ swift-winrt   │ libadwaita     │ via swift-java   │
├───────────────┴───────────────┴────────────────┴──────────────────┤
│ CirclesPresentation  (no UI-framework imports, builds everywhere) │
│  screen models · state · intents · navigation · rich-text AST ·   │
│  formatting/l10n · design tokens · PlatformServices protocols     │
├───────────────────────────────────────────────────────────────────┤
│ CirclesKit                                                        │
└───────────────────────────────────────────────────────────────────┘
```

#### The contract

Each screen (Stream, Post detail, Composer, Circle editor, Profile, Community, Settings, …) has a **screen model**:

```swift
@MainActor
public protocol ScreenModel: AnyObject, Observable {
    associatedtype State: Sendable, Equatable
    associatedtype Intent: Sendable
    var state: State { get }              // immutable value snapshot
    func send(_ intent: Intent)           // the only way UI changes anything
}

public struct StreamState: Sendable, Equatable {
    public var filter: StreamFilter        // all / a circle / a collection
    public var items: IdentifiedArray<PostID, PostCardState>
    public var phase: LoadPhase            // idle / loading / syncing(peers) / error
    public var unreadCount: Int
}

public enum StreamIntent: Sendable {
    case selectFilter(StreamFilter)
    case loadMore, refresh
    case plusOne(PostID), unPlusOne(PostID)
    case reshare(PostID), openPost(PostID), openAuthor(UserID)
}
```

Rules:
- **Data flows one way.** State is a value type, and changes come only from `send(_:)`. This makes imperative toolkits (WinUI, GTK) straightforward: they compare old and new state and update only the widgets that changed. SwiftUI and Compose just render the state.
- **Observation works on every platform.** Swift's Observation module (`@Observable`, `withObservationTracking`, the `Observations` async sequence) ships with the toolchain on every platform, so all backends observe changes the same way.
- **Lists carry stable IDs and diffs.** The Stream can be long, so list state uses identified collections, and backends get a `CollectionDifference` to drive native virtualized lists (`List`/`NSTableView`, `ItemsRepeater`, `GtkListView`, `LazyColumn`).
- **Navigation is data.** A `Route` enum and a navigation stack model live in the presentation layer. Each backend maps routes onto its own patterns: split view on desktop, stack on phone, `NavigationView` on WinUI, `AdwNavigationSplitView` on GNOME.
- **Rich text is an AST, not markup.** `RichText` runs (text, emphasis, mention, hashtag, link) are rendered by each backend to its native form: `AttributedString`, WinUI `RichTextBlock` inlines, Pango attributes, Compose `AnnotatedString`.
- **Media is referenced, not embedded.** State holds `ImageRef` (blob CID, dimensions, blurhash placeholder). A shared `MediaLoader` returns decoded pixels, and each backend wraps them in its native image type.
- **Formatting and localization live in the presentation layer:** relative dates, counts, audience descriptions ("Shared with Family and 2 others"). Backends show strings and never assemble them.
- **Design tokens are meaning, not pixels.** The layer defines semantic colors and styles (`.audiencePrivate`, `.plusOneActive`, `.spacing.m`). Each backend maps them onto platform styles, including dark mode and high contrast. Branding stays consistent while each platform still looks native.
- **Platform services are injected.** The presentation layer declares protocols that each backend implements: `PlatformServices` (file and photo picker, clipboard, share sheet, open URL, system notifications, QR scanning/display, keychain-backed confirmation prompts).

Enforcement:
- `CirclesPresentation` must build on headless Linux with no UI libraries installed (a CI job).
- No `import SwiftUI/AppKit/UIKit/WinRT/Gtk` in it, checked by a lint rule.
- Screen models are tested with Swift Testing by sending intents and checking the resulting states. No UI is involved.
- A **headless backend** (`CirclesUITestHost`) and the CLI both use the same screen models. This keeps the abstraction honest and gives us a way to script end-to-end tests.

#### Backends

| Platform | Toolkit | Swift binding | Status (checked 2026-10-08) |
|---|---|---|---|
| macOS / iOS / iPadOS / visionOS | SwiftUI, dropping to AppKit/UIKit where needed (e.g. text editing in the composer) | Native | Mature |
| Windows | WinUI 3 / Windows App SDK | [`thebrowsercompany/swift-winrt`](https://github.com/thebrowsercompany/swift-winrt): generates Swift projections of WinRT APIs | swift-winrt is **active** (last push 2026-10-02). The prebuilt [`swift-winui`](https://swiftpackageregistry.com/thebrowsercompany/swift-winui) and `swift-windowsappsdk` packages were **archived in Oct 2025**, so we generate and own our projections. The last published docs (Mar 2025) said x64 only, and that not all APIs can be generated because of DLL export limits. ARM64 must be verified. |
| Linux (GNOME-first) | GTK 4 + libadwaita | [Adwaita for Swift](https://swiftpackageregistry.com/AparokshaUI/adwaita-swift) (declarative, SwiftUI-like; repo moved to git.aparoksha.dev, commits as recent as Jul 2026), **or** direct C interop with GTK 4 through a module map | Adwaita for Swift is maintained by a small team, and its registry listing is stale. Direct C interop is the guaranteed fallback, since Swift imports the GTK C API natively. |
| Android | Jetpack Compose (Kotlin) | `swift-java` exposes screen models and state to Kotlin | Mobile, listed here because it uses the same presentation layer |
| Linux KDE / Qt | — | Not planned for v1 | GNOME's GTK app runs on KDE. A Qt backend could come later if there's demand. |

#### Status (M4)

`CirclesPresentation` exists, with screen models for the Stream (with circle filter), a post and its thread, the composer (audience, attachments, reply policy) and circles. It also has `PostCard`/`CommentRow` view state, navigation, formatting, strings, design tokens, `PlatformServices` and `MediaLoader`.
- It builds and is tested headless on Linux, and the tests drive full scenarios (compose → sync → comment → approve) through screen models alone.
- The `circles stream` command renders from `StreamScreenModel`, a first non-test backend.
- **No native UI yet (decided 2026-10-08):** this machine can't build SwiftUI, and GTK development packages aren't installed, so the SwiftUI and GNOME backends and the main-actor spikes move to a later milestone. *(GNOME done in M4.5, below.)*

#### GNOME backend (M4.5, `Apps/Gnome`)

- **Direct C interop, not Adwaita for Swift (decided 2026-10-08).** Adwaita for Swift pulls dependencies from unpinned `branch: "main"`, ships a module named `CSQLite` that clashes with ours, and brings its own declarative state system that would duplicate `CirclesPresentation`. Instead, a `CGtk` system-library target imports libadwaita/GTK 4, and **`GtkKit`** adds a thin layer:
  - closures for signals
  - `g(_:)`, a pointer conversion whose return type is inferred, covering GTK 4's mix of opaque types (`GtkLabel`) and defined ones (`GtkBox`)
  - `observe(_:)` over Swift Observation
  - widget builders
- **A separate package** (`Apps/Gnome/Package.swift`, depending on the root by path), so the core packages never need GTK. CI builds it on Ubuntu 24.04 (libadwaita 1.5).
- **Main-thread integration: solved.** libdispatch's main-queue hooks (`_dispatch_get_main_queue_handle_4CF` / `_dispatch_main_queue_callback_4CF`, the same ones CoreFoundation's run loop uses on Linux) become a GLib fd source, so `@MainActor` work runs inside GTK's main loop. The `MainActorSpike` executable verifies it runs on the main thread, and that the loop doesn't spin when idle (3 s idle ≈ 0 extra CPU).
- **The pattern** §11.6 describes, confirmed in practice:
  - each page observes its screen model and updates widgets in place
  - the Stream diffs rows by post ID
  - two-way controls (entries, switches, toggles) send an intent only when the widget's value differs from state, so rendering never echoes back
  - rich text becomes Pango markup, design tokens become libadwaita style classes, and `PlatformServices` uses GtkFileDialog, the clipboard and GNotification
- **Verification:** `CirclesGnome --snapshot DIR` drives the real app through Stream, post, Circles and composer, and renders each to PNG with GTK's own renderer (only this window, never the screen). It then **activates the real Post and +1 buttons** and checks the shared model state changed: GTK signal → intent → Account → SQLite → re-render.
- **Found through the GNOME work:** the presentation layer labelled a post with no audience chosen as "Public". It's fixed for every UI, with a test. Desktops using another icon theme (e.g. Breeze) lack some Adwaita icon names, so the app bundles its own icons.
- **Completed (2026-10-08):** the app now runs on its own, without the CLI.
  - **Staying online:** `CirclesKit.NodeService` (listener, mDNS, relay reservations, optional router port mapping, periodic sync) is shared by the app and `circles serve`. Network preferences are saved with the account.
  - **New screen models** in `CirclesPresentation`, which any UI can use:
    - `NetworkModel`: status line, activity log, and a `newContentCount` that UIs use to refresh the Stream after any sync
    - `OnboardingScreenModel`, `PeopleScreenModel` (invite exchange) and `SettingsScreenModel` (identity, pods, relays)
  - **New GNOME pages** for each, and quitting stops the network first, so the mDNS goodbye and port-mapping removal go out.
  - **The self-test** (`--snapshot` on an empty home) walks the first-run journey through real widgets: onboarding, adding a contact by pasting their invite, an **incoming sync updating the Stream on its own**, settings, posting, and +1.
- **Packaging (on `gnome/polish`):**
  - The desktop entry (`dev.circles.Circles.desktop`, matching the app ID so notifications work), AppStream metadata and app icons are validated with `desktop-file-validate` and `appstreamcli`.
  - `install.sh` makes a release build with the Swift runtime linked statically, so it needs only GTK 4, libadwaita and SQLite at run time. It was verified by installing into a scratch prefix and running the self-test through the installed launcher.
  - The Flatpak manifest targets GNOME 51 with the swift6 SDK extension but hasn't been built yet. Flathub will need vendored SwiftPM dependencies.
- **Wrapper lesson:** GObject `notify::` signals have an extra parameter. `GtkKit.onNotify` handles them, and the plain `connect` refuses them, after a mismatched handler crashed the Settings page.

#### Main-thread integration

Screen models are `@MainActor`. On Apple platforms, the main actor already runs on the app's main run loop. On **Windows and Linux**, the backend must make sure Swift's main-actor jobs run on the WinUI dispatcher or the GLib main loop respectively, either through the toolchain's main-executor support or by draining the main dispatch queue from a loop source. This needs proving early, in a spike in M4: a `@MainActor` timer updating a label on both platforms.

#### Risks

1. **The Swift WinUI path has the least support of all the backends.** If swift-winrt projection generation turns out to be too painful, the fallback is Win32 + Direct2D/DirectWrite through C interop. That gets uglier but has no projection problems. The presentation layer means this choice doesn't affect anything above the backend.
2. **Adwaita for Swift's maintenance.** Mitigation: keep the GNOME backend thin, and be ready to swap to raw GTK C interop.
3. **Three or four native UIs is real cost.** This is why the presentation layer has to absorb all logic. A backend should contain layout, styling, and platform conventions, and nothing else. If a backend needs an `if`, ask whether it belongs in the screen model.

## 12. Security and Threat Model (initial)

**Adversaries considered:**
1. A passive network observer
2. A malicious relay or DHT node
3. A compromised pod (sees ciphertext and metadata only)
4. A malicious contact (can leak what they're shown, which no system prevents)
5. Spammers and Sybils

**Key properties:**
- Content authenticity: every object is signed by a device key, which is certified by the identity key.
- Confidentiality of non-public content against everyone outside the audience, including pods and relays.
- Forward secrecy on transport sessions. Post-compromise security for communities (via MLS). Circle keys get it on rotation.
- Device revocation propagates through the identity document, and contacts reject objects signed by revoked keys after the revocation timestamp.

**Known weak spots to address:**
- Metadata (§8.4)
- DHT eclipse and Sybil attacks: mitigate with multiple bootstrap sets, S/Kademlia-style disjoint lookups, and preferring contact-provided addresses over the DHT.
- Spam on first contact: postage tokens, contact-of-contact allowances, and user-level allowlists.

The protocol will get an independent review before any "1.0" label.

## 13. Future Work

- **Hangouts:** WebRTC-style real-time media over the same peer sessions, with SFrame for end-to-end encryption in group calls.
- **Bridges:** read-only publishing of public posts to ActivityPub/AT Protocol, and following public accounts from those networks.
- **Takeout import:** import a Google+ Takeout archive (posts, circles, photos) so former users can recreate their history. The circles in the archive map directly.
- **Sealed sender** and envelope padding for stronger metadata privacy.
- **Shared pods** with quotas, for community-run hosting.

## 14. Milestones

| # | Milestone | Exit criteria |
|---|---|---|
| M0 | Skeleton | SwiftPM package, CI on macOS/Linux/Windows, Core types + deterministic CBOR + tests. **In progress (2026-10-08):** package, `CirclesCore` (CBOR, multiformats, `UserID`, `ContentID`, HLC, model types) and 42 tests are done and passing on Linux. The CI workflow is written but not yet run, because the repo has no remote. |
| M1 | Identity & crypto | Identity/device keys, certificates, envelopes, circle keys, KeyGrant; property tests. **Done (2026-10-08):** `CirclesCrypto` module (see §8.2 "Construction"). 76 tests in total pass on Linux, including seeded property tests for tampering, random audiences, signature bit-flips, and CBOR round-trips. |
| M2 | Two-peer sync over LAN | mDNS discovery, TCP+Noise sessions, per-author logs, CLI can post and read. **Done (2026-10-08):** `CirclesSync`, `CirclesNet` (Noise XX matching the cacophony test vector, NIO TCP, mDNS), `CirclesStorage`, `CirclesKit`, and the `circles` CLI. 107 tests pass. Verified with two separate processes on Linux: discovery without addresses, sync, circle-restricted reading, removal with key rotation, clean shutdown with mDNS goodbye. |
| M3 | Pods & relays | Headless pod daemon, store-and-forward, relayed connections, ~~NAT hole punching~~ port mapping (hole punching deferred to QUIC). **Done (2026-10-08):** `circles-pod`, `circles-relay`, endpoints in identity documents, sync control messages, PCP/NAT-PMP/UPnP-IGD mapping. 123 tests pass. Verified live with separate processes (pod store-and-forward, relay-only delivery). UPnP-IGD verified live against a real router: it mapped a port, the router listed it, and it was removed (opt-in test, `CIRCLES_LIVE_PORT_MAPPING=1`). |
| M4 | The Stream | Comments, +1s, reshares, media blobs; `CirclesPresentation` ~~+ SwiftUI app on macOS/iOS; main-actor spikes for WinUI and GTK~~ (native UIs deferred). **Done (2026-10-08):** SQLite store with migration; encrypted chunked media synced eagerly; comments/+1s through author republishing; reshares of public posts; presentation layer with headless tests; CLI commands. 138 tests pass. Verified live by migrating the M3 demo data and running photo, comment, +1, approval and reshare through a pod. |
| M4.5 | Native UIs | SwiftUI app (macOS/iOS) and GNOME app over `CirclesPresentation`; main-actor integration spikes for GTK and WinUI. **GNOME done (2026-10-08):** `Apps/Gnome` (libadwaita via direct C interop), main-actor integration solved, self-testing snapshot mode. **Remaining:** SwiftUI on the Mac Studio; WinUI spike on Windows. |
| M5 | Communities | MLS-backed groups, moderation tools. **Done on branch `communities` (2026-10-08):** `CirclesMLS` over swift-mls 0.1.7 (pinned; MIT, as is its dependency swift-secret-bytes); public and private communities with open, approval and invite-only joining; posting through the sequencer; owner moderation (remove members, posts, comments); one listener serving every identity on a device; pods carrying communities while the owner is offline; CLI, screen models and GNOME pages. 178 tests pass, and the GNOME self-test covers create, request, approval and an incoming post. Verified by hand with two CLI processes over mDNS. **Not yet:** SwiftUI pages; join requests through pods; moderator roles; a second sequencer. |
| M6 | Platform breadth | Windows (WinUI), Linux (GTK/libadwaita), and Android apps on the shared presentation layer; push relay, DHT |
| M7 | Hardening | Threat-model review, fuzzing (wire format, CBOR), simulation at 10k nodes |

## 15. Open Questions

1. ~~QUIC availability across all target platforms via SwiftNIO.~~ **Resolved (2026-10-08):** v1 uses TCP + Noise everywhere, and QUIC is added per platform as it matures. See §7.1.
2. ~~MLS: native Swift implementation vs. binding to OpenMLS.~~ **Resolved (2026-10-08):** swift-mls behind a `GroupCrypto` protocol, with mls-rs via FFI as the fallback. A cross-platform build spike happens during M1. See §8.3.
3. Per-device logs vs. per-audience logs: the metadata trade-off (§9.2).
4. ~~Desktop UI on Windows/Linux: a native toolkit per platform, a cross-platform Swift UI library, or a web UI served by the local node?~~ **Resolved (2026-10-08):** native UI per platform (SwiftUI, WinUI 3, GTK 4/libadwaita, Compose) over our own `CirclesPresentation` layer. See §11.6.
5. ~~Content addressing hash: BLAKE3 (fast, needs vendoring) vs. SHA-256 (in swift-crypto)?~~ **Resolved (2026-10-08):** SHA-256 via swift-crypto, on Armstrong's recommendation. It removes the BLAKE3 vendoring. See §9.1.
6. ~~How much of the social graph can a contact infer from comment threads, and should commenters on a post be visible to the whole audience (Google+ behavior) or only to the author?~~ **Resolved (2026-10-08):** keep the Google+ behavior, where commenters and +1ers are visible to the whole audience. We accept the social-graph leak and show commenters the audience before they reply. See §9.4.
7. ~~Licensing~~ and governance of the protocol spec vs. the reference implementation.
   - **Code license, resolved (2026-10-08):** all code in this project is **BSD 3-Clause**. Our planned dependencies are all permissive: swift-nio, swift-crypto, and swift-foundation are Apache-2.0; swift-mls is MIT; mls-rs is Apache-2.0/MIT; the Argon2 reference code is CC0/Apache-2.0. None of these conflict with BSD-3. Apache-2.0 dependencies require their license and NOTICE text to ship with binaries, so each app bundles a generated third-party notices file. Every new dependency needs a license check before adoption, with nothing copyleft in shipped binaries without an explicit decision.
   - **Protocol governance: TBD.** Still open: who controls changes to the wire protocol and object formats, how extensions are registered, and what license the specification text itself uses.
