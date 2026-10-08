# Circles

A reimplementation of the Google+ social model (Circles, the Stream, posts,
+1s, Communities) on a peer-to-peer backbone, in Swift.

**Status:** early development; milestones M0–M4. Post to circles with photos, comment, +1 and reshare; sync on the local network, through your own pod while you're offline, or through relays. A GNOME app is here; the SwiftUI app is next. See [docs/DESIGN.md](docs/DESIGN.md).

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
CIRCLES_HOME=$B circles stream           # shows each post's short ID

CIRCLES_HOME=$B circles comment <id> "Count me in"
CIRCLES_HOME=$B circles plusone <id>
CIRCLES_HOME=$A circles post --everyone --attach photo.jpg "Sunset"
```

### Pods and relays

```sh
# On an always-on machine:
circles-pod init --host pod.example.net --port 7465   # prints a pairing code
circles pod add <pairing code>                         # on your device; prints a bundle
circles-pod pair <bundle>                              # on the pod
circles-pod serve

# A relay (anyone can run one; it only sees ciphertext):
circles-relay --port 7466 --public-host relay.example.net   # prints its address
circles relay add <relay address>                            # on your device

circles serve --map-port   # also asks your router to forward the port
circles sync               # local network, pods, then relays
```

### GNOME app

Needs GTK 4 and libadwaita development files (`dnf install gtk4-devel libadwaita-devel`, or `apt install libadwaita-1-dev`):

```sh
swift build --package-path Apps/Gnome
Apps/Gnome/.build/debug/CirclesGnome   # uses $CIRCLES_HOME or ~/.circles
```

The app walks you through creating an identity, exchanging invites, circles, pods and relays, and stays online while it's open (no `circles serve` needed).

To install it for your user (desktop entry, icon, and a `circles-gnome` command; only GTK 4, libadwaita and SQLite are needed at run time):

```sh
Apps/Gnome/install.sh              # into ~/.local; --uninstall to remove
```

A Flatpak manifest is in `Apps/Gnome/dev.circles.Circles.yml` (not yet built; see the notes in it).

### macOS app

In progress. Needs Xcode 27 (Swift 6.4). Open `Apps/Apple/Circles.xcodeproj`, or:

```sh
xcodebuild -project Apps/Apple/Circles.xcodeproj -scheme Circles build
```

It builds signed to run locally. To sign with your own team, which macOS needs before it reliably grants the app Local Network access, copy `Apps/Apple/Config/Local.xcconfig.example` to `Local.xcconfig` and set your team ID.

The app is sandboxed and keeps its data in its container's Application Support folder. So far it has onboarding, the Stream, posts with comments, +1s and resharing, and the composer; People, Circles and Settings come next.

## Layout

- `Sources/CirclesCore`: identifiers, deterministic CBOR, hybrid logical
  clock, and the core object model (posts, comments, reactions).
- `Sources/CirclesCrypto`: identity and device keys, device certificates,
  identity documents, signed objects, circle key schedules, key grants,
  audience-encrypted envelopes, and the Noise XX handshake.
- `Sources/CirclesSync`: per-device hash-linked logs and the sync protocol.
- `Sources/CirclesNet`: Noise sessions over TCP (SwiftNIO) and mDNS discovery.
- `Sources/CirclesStorage`: the SQLite store (logs, identities, media chunks).
- `Sources/CirclesKit`: the `Account` and `PodNode` façades: posting, comments, +1s, reshares, media, sync.
- `Sources/CirclesPresentation`: platform-neutral screen models every UI renders.
- `Sources/circles-cli`, `circles-pod`, `circles-relay`: the command-line tools.
- `Apps/Gnome`: the GNOME app (GTK 4 + libadwaita), a separate package.
- `Apps/Apple`: the SwiftUI app (an Xcode project over the root package).

## License

BSD 3-Clause. See [LICENSE](LICENSE).
