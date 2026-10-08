# Circles

A reimplementation of the Google+ social model (Circles, the Stream, posts,
+1s, Communities) on a peer-to-peer backbone, in Swift.

**Status:** early development; milestones M0–M1. See [docs/DESIGN.md](docs/DESIGN.md).

## Building

Requires Swift 6.3 or later (the design targets 6.4+).

```sh
swift build
swift test
```

## Layout

- `Sources/CirclesCore`: identifiers, deterministic CBOR, hybrid logical
  clock, and the core object model (posts, comments, reactions).
- `Sources/CirclesCrypto`: identity and device keys, device certificates,
  identity documents, signed objects, circle key schedules, key grants, and
  audience-encrypted envelopes.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
