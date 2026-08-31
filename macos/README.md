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

State lives in `~/Library/Application Support/Tutti`:

    owntone.conf       generated each launch; hand edits are overwritten
    engine.json        connect name, pipe path, bitrate; read by the helper
    Library/           owntone's media library -- holds the named pipe
    Logs/              owntone.log, librespot.log, owntone-server.log
    songs3.db, Cache/  owntone's database and caches

### Ad-hoc signing and stale registrations

A registration records a code requirement taken from the app's signature, and
an ad-hoc signature changes on every build. After a rebuild launchd holds a
job it will not spawn -- "Could not find and/or execute program" in the log,
`EX_CONFIG`, crash-looping -- while `SMAppService.status` still reports
`.enabled`. `EngineService` detects this by asking launchctl what state the
job is actually in, and re-registers. If you are debugging it by hand:

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

## Known gaps

- **No transport controls.** librespot streams into a fifo the engine drains,
  so pausing the engine stalls librespot's writes rather than pausing Spotify.
  Pause semantics need a spike before any play/pause button is honest.
- **Track metadata is always nil against a live engine.** The bridge exists
  (`../bridge/librespot-metadata`) but is not wired into the helper's argv.
- **Playback is unverified.** Discovery works; no audio has ever reached a
  speaker from the native engine.
- **Logs grow without bound.** Nothing rotates them.
- **Rejoin-on-free is not implemented.** The store has no notion of an
  intended speaker set yet.
