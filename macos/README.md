# macOS app

SwiftUI menu bar app over the bundled engine's JSON API. The engine itself
(owntone + librespot) is two separate processes; this app never links it.
The app ships them, configures them, and runs them as its own children.

## Build

    ./build-engine             # build owntone + librespot from the flake
    ./generate                 # regenerate Schtaap.xcodeproj from project.yml
    open Schtaap.xcodeproj

Or from the command line:

    xcodebuild -project Schtaap.xcodeproj -scheme Schtaap -configuration Debug \
      -derivedDataPath DerivedData build

`build-engine` needs Nix and takes a while the first time; after that the
payload sits in `Engine/`, which is gitignored, and only has to be rebuilt
when the engine changes. Skipping it still builds a working app: the engine
sources are optional, and the popover says so rather than pretending.

`Schtaap.xcodeproj` and `Info.plist` are generated but committed, so a fresh
clone builds in Xcode without XcodeGen. `project.yml` is the source of truth;
never hand-edit the project file.

## Running without the engine

    open DerivedData/Build/Products/Debug/Schtaap.app --args -UseFixtures YES

Loads `Fixtures.swift` instead of the network, so the whole UI is reachable
with nothing else running. Fixture mode also blocks the engine from starting,
which matters more than it sounds: starting it advertises this Mac on the LAN
and starts discovering the household's speakers.

## The engine

Two child processes of the app, spawned with `Process` and supervised by
`EngineService`. The app starts them when it launches and stops them when it
quits (SIGTERM from `applicationShouldTerminate`), so a quit frees the
speakers and leaves nothing advertised, and "Start at Login" is the one switch
for the whole thing. Nothing is registered with launchd, nothing appears under
Login Items but the app, and the engine cannot outlive the app: each helper
watches for its parent's exit and stops its engine, which covers a crash or a
Force Quit as well as a quit.

`EngineService` supervises them the way launchd's `KeepAlive { Crashed }` did,
from the same signal the helper already sends: a helper that dies by a signal
crashed and is started again, at most one start per engine per ten seconds; a
helper that exits 0 was asked to stop, or had nothing to run, and stays down;
any other exit status is a failure the popover shows. Restarts are unlimited.
Every start, exit and restart is logged:

    log stream --info --predicate 'subsystem == "bar.esko.Schtaap"'

Both halves run one program, `EngineHelper`, with one argument. Every path the
engine needs is only known at runtime, so the helper resolves them from the app
bundle it finds itself in. It spawns the engine and waits rather than exec'ing
into it, for two reasons. The engine's fate lands in the helper's exit status,
which is what the app reads. And macOS names a process to the user from the
bundle it belongs to, so the helper ships as an app bundle of its own,
`Contents/Helpers/Schtaap Engine.app`, and Activity Monitor shows "Schtaap
Engine" rather than "owntone" and "librespot". Its name is one setting in
`project.yml` (`ENGINE_PRODUCT_NAME`) and no Swift type carries it. The bundle
has no UI (`LSBackgroundOnly`).

Being children is what settles the Local Network permission. macOS grants it to
the responsible process, and a child inherits its parent's responsibility, so
the app's single grant covers the helper, owntone, librespot and the metadata
hook below them, and the user answers one prompt, named Schtaap. As LaunchAgents
the two helpers were responsible for themselves and asked under a name of their
own, beside the app's.

The helper also reads that grant, by sending one datagram to an unused
multicast group from a fresh child process (a grant reaches a running process,
a revocation only a new one). A grant that arrives
after librespot opened its mDNS socket never reaches that socket, so the helper
starts librespot again; the reading goes into `spotify-session.json` for the
receiver row. See `Helper/LocalNetworkProbe.swift`.

The helper has a third mode, `metadata`, that librespot itself runs on every
player event (`--onevent`). It turns the event in the environment into the
Shairport-format items OwnTone reads from `<pipe>.metadata`: title, artist,
album, progress in frames, and the cover, fetched from the URL librespot
supplies. That is the only way a pipe input ever gets a title. OwnTone opens
the metadata pipe only once playback starts, so the first send of a track is
usually dropped; the helper remembers the track and resends it on the next
event until a write succeeds. See `Helper/Metadata.swift` for the format's
traps, all read out of OwnTone's `src/inputs/pipe.c`.

State lives in `~/Library/Application Support/bar.esko.Schtaap`:

    owntone.conf            generated each launch; hand edits are overwritten
    engine.json             connect name, pipe path, bitrate; read by the
                            librespot helper alone, and diffed to decide
                            whether to restart that half
    intended-outputs.json   the speakers the user asked for, which the app wins
                            back when another sender takes one
    Library/                owntone's media library: the audio pipe and its
                            .metadata companion
    Logs/                   owntone.log and librespot.log, each started anew
                            at 10 MB with the two previous files kept beside
                            it, named for when they were closed
                            (owntone.20260910T133912Z.log)
    songs3.db, Cache/       owntone's database and caches; Cache/Metadata holds
                            the current track and its cover for the bridge

Debug builds are signed with the Apple Development identity rather than ad hoc,
so that every build is the same identity to macOS and a grant keyed to that
identity survives a rebuild. Whether an ad-hoc rebuild is asked for Local
Network again has not been tested since the engine moved into the app's
process tree; under launchd it was the registration that broke on every
rebuild, and that reason is gone.

`defaults write bar.esko.Schtaap EngineLogLevel debug` sets owntone's log level
at the next launch; `defaults delete` puts it back. The log grows fast at
debug.

## Renaming the app

The product name is confined to:

- `project.yml` -- `APP_PRODUCT_NAME`, `name:`, `PRODUCT_BUNDLE_IDENTIFIER`
- `Sources/Support/Branding.swift` -- only the fallback string; the real
  value is read from `CFBundleName` at runtime

No Swift type carries the name, and the engine helper takes its own from
`ENGINE_PRODUCT_NAME`, which is derived from the app's. Change those two, run
`./generate`, done.

## Layout

    Sources/App/         app entry
    Sources/Engine/      API client, websocket, store, fixtures, engine
                         installation and the child-process supervisor
    Sources/UI/          popover, rows, pages
    Sources/Support/     branding, preferences, login item
    Helper/              the engine helper the app spawns, built as
                         "Schtaap Engine.app" so the engine's processes
                         have a name the user recognises
    Engine/              gitignored payload from ./build-engine, with its
                         NOTICES.txt of bundled packages and licenses

## Design

The popover follows the system Sound menu: material background, an "Output"
section of icon-well rows where selection is carried by an accent tint, native
`Slider` controls, and a footer of menu rows. No status badge -- activity is
signalled by the menu bar icon, which is where the system does it.

The current track is also handed to the system's Now Playing slot, so it shows
in Control Center and the menu bar's Now Playing item with its cover. The slot
is one per Mac and last-writer-wins, so "Show in Now Playing" in the footer
lets go of it. Its play and pause commands, and a tap on a HomePod's top,
pause and resume Spotify itself: librespot carries a patch that adds
`--control-socket`, a Unix socket under Application Support that takes play,
pause, next, prev and volume and routes them through Spotify Connect, so the
phone shows the same state. The master slider is pushed through the same
socket, which is what keeps the phone's slider in step with the popover and
with a HomePod's own volume buttons.

A speaker the user selected that stops playing without the user switching it
off -- Siri or an Apple TV took it -- shows "Rejoining..." and is retried with
backoff (5, 10, 20, 30, then every 60 seconds) until the engine accepts it
again. Nothing on the network says whether a speaker is busy, so the refusal is
the probe. Switching the speaker off calls it off. The intended set is seeded
from whatever was playing the first time the app sees a live engine.

## Known gaps

- **Unsigned for distribution, not notarized, no updater.** Debug builds
  only, on the developer's certificate.
- **A moved app re-prompts for Local Network**, once for the app and once
  for the engine: a Debug build's grant follows the bundle's path.
- **A resume is heard ~2 s after the press.** That is the AirPlay 2 buffer
  OwnTone streams into (`event_play_start` two seconds after the sync
  packet). Apple's own senders resume faster with SETRATEANCHORTIME, which
  OwnTone 29.3 does not speak.
- **AirPlay 2 runs without PTP.** Ports 319 and 320 are privileged and an
  unprivileged agent cannot bind them, so the engine logs "AirPlay PTP
  daemon unavailable, only NTP will be available" at every launch. Fine
  for one stereo pair; unmeasured beyond it.
- **librespot's mDNS complains.** `libmdns: error sending packet ...
  HostUnreachable`, seven then one a minute, is libmdns sending on an
  interface without a route. It advertises anyway; the lines are noise,
  not the Local Network permission.
- **The default Connect name collides with the hardware.** "HomePods" as
  `Branding.defaultConnectName` puts a receiver named after HomePods above
  a list of actual HomePods. Editable in the popover: a rename restarts the
  Spotify receiver alone, owntone keeps playing, and while a Spotify client
  is connected the new name waits for a click on Rename, since the restart
  is a new device to Spotify and drops that client.
- **The controlling phone cannot be named.** librespot 0.8 never fills
  the client name, brand or model, so the receiver row says "Connected".
- **No groups editor, no first-run explanation.** Both wanted, neither
  specified.
