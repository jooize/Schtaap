# macOS app

SwiftUI menu bar app over the bundled engine's JSON API. The engine itself
(owntone + librespot) is two separate processes; this app never links it.
The app ships them, configures them, and registers them with launchd.

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
with nothing else running. Fixture mode also blocks engine registration, which
matters more than it sounds: registering the agents advertises this Mac on the
LAN and starts discovering the household's speakers.

## The engine

Two LaunchAgents, registered through `SMAppService` and visible in System
Settings under Login Items as "Schtaap, 2 items". launchd runs the processes and
brings a crashed one back; the app decides when they run. It starts them when
it launches (`launchctl kickstart`) and stops them when it quits (`launchctl
kill TERM`, from `applicationShouldTerminate`), so a quit frees the speakers
and leaves nothing advertised, and "Start at Login" is the one switch for the
whole thing. The plists carry no `RunAtLoad` and a `KeepAlive` for crashes
only; the helper exits clean when asked to stop, re-raises the engine's signal
when it crashed, and passes a plain failure through, which is how launchd tells
the three apart.

Both plists run one program, `EngineHelper`, with one argument. A plist is a
static file and every path the engine needs is known only at runtime, so the
helper resolves them from the app bundle it finds itself in. It spawns the
engine and waits rather than exec'ing into it, because macOS attributes local
network access to the responsible process: exec'ing left librespot with no
responsible ancestor and the permission prompt read "Allow librespot ...".
Staying alive as the parent makes the prompt name the helper, and the helper
ships as an app bundle of its own, `Contents/Helpers/Schtaap Engine.app`, so
that the prompt and the Local Network list read "Schtaap Engine", beside the
app's own "Schtaap" row (the app browses for AirPlay speakers itself). macOS
shows a process by its bundle's file name and reads the usage description from
the bundle's Info.plist; a bare executable with an embedded Info.plist
(2026-09-08) and a bundle whose `CFBundleName` differed from its file name
(2026-09-10) were both tried and both showed "EngineHelper". The helper bundle
has no UI (`LSBackgroundOnly`), its name is one setting in `project.yml`
(`ENGINE_PRODUCT_NAME`), and `Branding.engineName` reads it back from the
bundle.

The helper also probes Local Network access for itself, by sending one
datagram to an unused multicast group from a fresh child process (a grant
reaches a running process, a revocation only a new one). A grant that arrives
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
    engine.json             connect name, pipe path, bitrate, app build; read by
                            the helper, and diffed to decide whether to restart
                            the agents
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

The helper's code hash and the payload's store paths are written into
`engine.json` so that a build which changes either restarts the agents, and
one which changes neither leaves a running engine alone. Debug builds are
signed with the Apple Development identity for the same reason: an ad-hoc
signature changes on every build, and launchd refuses a job whose code no
longer matches the requirement it recorded.

`defaults write bar.esko.Schtaap EngineLogLevel debug` sets owntone's log level
at the next launch; `defaults delete` puts it back. The log grows fast at
debug.

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

    launchctl print gui/$(id -u)/bar.esko.Schtaap.owntone
    launchctl bootout gui/$(id -u)/bar.esko.Schtaap.owntone

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
    Helper/              the engine helper launchd runs, built as
                         "Schtaap Engine.app" so the Local Network prompt
                         has a name
    LaunchAgents/        the two agent plists, copied into the bundle
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
  a list of actual HomePods. Editable in the popover.
- **The controlling phone cannot be named.** librespot 0.8 never fills
  the client name, brand or model, so the receiver row says "Connected".
- **No groups editor, no first-run explanation.** Both wanted, neither
  specified.
