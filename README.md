# Circles

A reimplementation of the Google+ social model (Circles, the Stream, posts,
+1s, Communities) on a peer-to-peer backbone, in Swift.

**Status:** early development; milestones M0–M2. Two devices on a local network can discover each other, sync, and read posts restricted to circles. See [docs/DESIGN.md](docs/DESIGN.md).

## Building

Requires Swift 6.3 or later (the design targets 6.4+).

```sh
swift build
swift test
```

## Try it

Two identities on one machine, each with its own data directory:

```sh
swift build
alias circles=.build/debug/circles
export A=/tmp/alice B=/tmp/bob

CIRCLES_HOME=$A circles init --name Alice
CIRCLES_HOME=$B circles init --name Bob
CIRCLES_HOME=$A circles contact add "$(CIRCLES_HOME=$B circles invite)"
CIRCLES_HOME=$B circles contact add "$(CIRCLES_HOME=$A circles invite)"

CIRCLES_HOME=$A circles circle create Friends
CIRCLES_HOME=$A circles circle add Friends Bob
CIRCLES_HOME=$A circles post --circle Friends "Just for Friends"
CIRCLES_HOME=$A circles serve &          # listens and advertises over mDNS

CIRCLES_HOME=$B circles sync             # finds Alice on the LAN and syncs
CIRCLES_HOME=$B circles stream
```

## Layout

- `Sources/CirclesCore`: identifiers, deterministic CBOR, hybrid logical
  clock, and the core object model (posts, comments, reactions).
- `Sources/CirclesCrypto`: identity and device keys, device certificates,
  identity documents, signed objects, circle key schedules, key grants,
  audience-encrypted envelopes, and the Noise XX handshake.
- `Sources/CirclesSync`: per-device hash-linked logs and the sync protocol.
- `Sources/CirclesNet`: Noise sessions over TCP (SwiftNIO) and mDNS discovery.
- `Sources/CirclesStorage`: the file-backed log store.
- `Sources/CirclesKit`: the `Account` façade used by apps and the CLI.
- `Sources/circles-cli`: the `circles` command.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
