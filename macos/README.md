# macOS app

SwiftUI menu bar app over the bundled engine's JSON API. The engine itself
(owntone + librespot) is two separate processes; this app never links it.
The app ships them, configures them, and registers them with launchd.

## Build

    ./build-engine             # build owntone + librespot from the flake
    ./generate                 # regenerate Tutti.xcodeproj from project.yml
    open Tutti.xcodeproj

Or from the command line:

    xcodebuild -project Tutti.xcodeproj -scheme Tutti -configuration Debug \
      -derivedDataPath .build build

`build-engine` needs Nix and takes a while the first time; after that the
payload sits in `Engine/`, which is gitignored, and only has to be rebuilt
when the engine changes. Skipping it still builds a working app: the engine
sources are optional, and the popover says so rather than pretending.

`Tutti.xcodeproj` and `Info.plist` are generated but committed, so a fresh
clone builds in Xcode without XcodeGen. `project.yml` is the source of truth;
never hand-edit the project file.

## Running without the engine

    open .build/Build/Products/Debug/Tutti.app --args -UseFixtures YES

Loads `Fixtures.swift` instead of the network, so the whole UI is reachable
with nothing else running. Fixture mode also blocks engine registration, which
matters more than it sounds: registering the agents advertises this Mac on the
LAN and starts discovering the household's speakers.

## The engine

Two LaunchAgents, registered through `SMAppService` and visible in System
Settings under Login Items as "Tutti, 2 items". launchd owns the processes, so
they start at login and restart on crash whether or not the popover is open --
which is the point, since a phone can only cast to a Connect target that
already exists.

Both plists run one program, `EngineHelper`, with one argument. A plist is a
static file and every path the engine needs is known only at runtime, so the
helper resolves them from the bundle it finds itself in. It spawns the engine
and waits rather than exec'ing into it, because macOS attributes local network
access to the responsible process: exec'ing left librespot with no responsible
ancestor and the permission prompt read "Allow librespot ...". Staying alive as
the parent, with an embedded Info.plist carrying the app's name, makes it read
"Tutti".

The helper has a third mode, `metadata`, that librespot itself runs on every
player event (`--onevent`). It turns the event in the environment into the
Shairport-format items OwnTone reads from `<pipe>.metadata`: title, artist,
album, progress in frames, and the cover, fetched from the URL librespot
supplies. That is the only way a pipe input ever gets a title. OwnTone opens
the metadata pipe only once playback starts, so the first send of a track is
usually dropped; the helper remembers the track and resends it on the next
event until a write succeeds. See `Helper/Metadata.swift` for the format's
traps, all read out of OwnTone's `src/inputs/pipe.c`.

State lives in `~/Library/Application Support/Tutti`:

    owntone.conf            generated each launch; hand edits are overwritten
    engine.json             connect name, pipe path, bitrate, app build; read by
                            the helper, and diffed to decide whether to restart
                            the agents
    intended-outputs.json   the speakers the user asked for, which the app wins
                            back when another sender takes one
    Library/                owntone's media library: the audio pipe and its
                            .metadata companion
    Logs/                   owntone.log, librespot.log, owntone-server.log
    songs3.db, Cache/       owntone's database and caches; Cache/Metadata holds
                            the current track and its cover for the bridge

The app's own build number is written into `engine.json` so that any new
build restarts the agents. launchd keeps a running job on whatever binary it
started, so without that an update touching only the helper would never take
effect until the next login.

### Ad-hoc signing and stale registrations

A registration records a code requirement taken from the app's signature, and
an ad-hoc signature changes on every build. After a rebuild launchd holds a
job it will not spawn -- "Could not find and/or execute program" in the log,
`EX_CONFIG`, crash-looping -- while `SMAppService.status` still reports
`.enabled`. `EngineService` detects this by asking launchctl what state the
job is actually in, and re-registers -- both before deciding whether to
register at launch and again after a restart, since the check at launch runs
while the old processes are still up and passes. If you are debugging it by
hand:

    launchctl print gui/$(id -u)/bar.esko.Tutti.owntone
    launchctl bootout gui/$(id -u)/bar.esko.Tutti.owntone

launchd throttles respawns to one per 10 seconds, so give it a moment before
concluding anything.

## Renaming the app

The product name is confined to:

- `project.yml` -- `APP_PRODUCT_NAME`, `name:`, `PRODUCT_BUNDLE_IDENTIFIER`
- `Sources/Support/Branding.swift` -- only the fallback string; the real
  value is read from `CFBundleName` at runtime
- `LaunchAgents/*.plist` -- the file names and their `Label` keys

The plists are the exception the rule cannot reach: launchd labels must be
unique across the system, so they carry the reverse-DNS identifier, and
`SMAppService` requires the file name to equal the Label. No Swift type
carries the name. Change those, run `./generate`, done.

## Layout

    Sources/App/         app entry
    Sources/Engine/      API client, websocket, store, fixtures, engine
                         installation and SMAppService registration
    Sources/UI/          popover, rows, pages
    Sources/Support/     branding, preferences, login item
    Helper/              EngineHelper: the program launchd runs
    LaunchAgents/        the two agent plists, copied into the bundle
    Engine/              gitignored payload from ./build-engine

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

Ordered by what blocks playback first.

- **The engine segfaults when an AirPlay session tears down.** Reproduced
  every time a second speaker is selected while one is already playing, and
  again when a selected speaker is dropped. Always the same stack:
  `evrtsp_connection_free` from `session_free`, on the player thread, out of
  a libevent callback. launchd restarts the agent, so the symptom a user sees
  is a speaker that will not switch and a list that resets. This is upstream,
  not our packaging -- see owntone-server issues #1509 and #1760 -- and it is
  the single largest obstacle to shipping. Crash reports land in
  `~/Library/Logs/DiagnosticReports/owntone-*.ips`.
- **Device probes fail intermittently.** `airplay: device_probe: Error
  sending GET /info (probe)` while a plain `curl` to the same speaker's
  port 7000 answers 200 in tens of milliseconds. Suspected cause is a second
  IPv4 interface on the machine -- a VM bridge alongside the LAN -- and
  OwnTone choosing the wrong one. `bind_address` does not fix it: the option
  also moves the HTTP API off localhost, where the app expects it. Needs a
  read of how the AirPlay session picks its local address.
- **AirPlay 2 runs without PTP.** Ports 319 and 320 are privileged and an
  unprivileged agent cannot bind them, so the engine logs "AirPlay PTP daemon
  unavailable, only NTP will be available" at every launch. Consequences for
  multi-speaker sync are unmeasured.
- **librespot's mDNS complains.** `libmdns: error sending packet ...
  HostUnreachable` on every launch, almost certainly the same second
  interface as above. It advertises successfully anyway.
- **Playback is unverified.** Device activation now works and sticks; no
  audio has been confirmed coming out of a speaker.
- **No transport buttons in the popover.** The media keys and a HomePod's
  top pause and resume Spotify through librespot's control socket; the
  popover itself only offers a mute. Pausing the engine is never an option:
  it stalls librespot's writes and resumes into stale audio.
- **Track metadata and rejoin are unverified against real playback.** Both
  are wired and tested offline (the bridge byte-for-byte against the Python
  original, the state machine through every event), but playback itself has
  never run here, so neither has been seen end to end.
- **Logs grow without bound.** Nothing rotates them.
- **The default Connect name collides with the hardware.** Shipping
  "HomePods" as `Branding.defaultConnectName` puts a receiver named after
  HomePods directly above a list of actual HomePods. The computer's name, or
  the app's, would not.
