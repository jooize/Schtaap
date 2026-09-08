# SpotifyConnectToAirPlay

A macOS menu bar app that makes a Mac appear as a speaker in Spotify and
plays what is sent to it on AirPlay 2 speakers, in sync. Pick "HomePods"
in Spotify's device list on a phone or a computer, and the music comes out
of the household's HomePods, with the track, artist, album and cover on
every speaker and in the Mac's Now Playing.

The phone is only a remote. The audio streams from Spotify's servers to
the Mac, so the phone can leave the house and the music carries on.

Working name in the app: **Tutti**. Not released; built and used on one
Mac. See [Status](#status).

## What it does

- Appears in Spotify as one Connect device, named in the popover.
  Needs Spotify Premium, which is what Spotify Connect requires.
- Plays to any set of AirPlay speakers the Mac can see, HomePods and
  stereo pairs included, in sync. Each speaker has its own volume, and a
  master slider carries them together.
- Pause, resume, seek and skip from the phone, the popover, the Mac's
  media keys and Control Center, or a HomePod's own top. All of them are
  one path, so the phone's slider, the popover and the speakers agree.
  A pause silences the speakers at once and a resume picks up where the
  sound stopped, not where Spotify's own clock had run ahead to.
- A HomePod's volume buttons move the phone's slider and the popover's.
- Shows the current track with its cover in the popover and in the Mac's
  Now Playing, and sends title, artist, album and cover to the speakers.
- Takes a speaker back when Siri or another sender borrows it.
- The popover says who is connected, warns when Spotify's servers are out
  of reach, and warns when macOS has not allowed the engine on the local
  network, which is the one fault that makes a running receiver invisible.

## How it works

    Spotify app (phone, computer)
      | Spotify Connect: discovery over mDNS, then control through Spotify
      v
    librespot        Spotify Connect receiver. Decodes the stream and
      |              writes PCM into a named pipe.
      v  spotify.fifo (+ spotify.fifo.metadata)
    OwnTone          Reads the pipe as a library item and streams it as
      |              AirPlay 2, synced across speakers.
      v
    HomePods, and any other AirPlay speaker

Both daemons are built from Nix with the patches in `nix/`, bundled into
the app, and run by launchd as LaunchAgents for as long as the app runs.
One helper binary in the bundle, `EngineHelper`, is the program launchd
runs for both: it resolves every path from the bundle it finds itself in,
supervises the daemon, and stays alive as its parent so that macOS
attributes the daemon's network access to it. The same binary is also
librespot's event hook: it turns librespot's track and playback events
into the metadata OwnTone reads beside the pipe, fetches the cover, and
keeps the two transports in step (a pause on either side pauses the
other, and seeks Spotify back to what the speakers actually played).

The app talks to OwnTone over its JSON API and websocket on localhost,
and to librespot over a Unix socket that one of the patches adds. All
state is under `~/Library/Application Support/Tutti`.

Details of the app, the helper and the engine's lifecycle are in
[macos/README.md](macos/README.md).

## Building

Needs a Mac with Xcode 16 or later, Nix (the flake builds the daemons),
and an Apple Development signing identity. Debug builds are signed with
it on purpose: under ad-hoc signing every rebuild changes the code
requirement launchd recorded, and the agents refuse to start. A machine
without that certificate can set `CODE_SIGN_IDENTITY: "-"` in
`macos/project.yml` and live with re-registering after each rebuild.

    cd macos
    ./build-engine      # owntone + librespot from the flake, staged in Engine/
    ./generate          # Tutti.xcodeproj from project.yml (XcodeGen via nix run)
    xcodebuild -project Tutti.xcodeproj -scheme Tutti -configuration Debug \
      -derivedDataPath .build build
    open .build/Build/Products/Debug/Tutti.app

The first launch registers the two agents with launchd (System Settings
lists them under Login Items as "Tutti, 2 items") and asks for Local
Network access twice, once for the app and once for the helper. Both are
needed: the helper's is what lets the engine advertise itself and reach
the speakers, the app's only fetches speaker models and stereo-pair
labels for the icons.

Without Nix the app still builds and runs, with no engine; the popover
says so. `open ... --args -UseFixtures YES` runs the whole UI against
fixtures, off the network.

Runs on macOS 15 and later.

## Releases

Every tag `vX.Y.Z` is built by GitHub Actions on a GitHub-hosted Mac,
from that commit alone: the engine from the flake, the app from Xcode
(`.github/workflows/release.yml`). The workflow records a build
provenance attestation, so a download can be checked against the commit
and the workflow that produced it:

    gh attestation verify Tutti-0.1.0-macos.zip --owner jooize

The zip is meant to be reproducible: the same commit, the same Xcode,
the same bytes. Every run builds twice, on two separate runners, and
refuses to publish unless the two zips are identical. What is not yet
reproducible is a build on another Mac: a local Lix build of owntone
differs from the runner's in the linker's UUID and nothing else, cause
not yet found.

Release builds are ad-hoc signed and not notarized. macOS refuses to
open the app the first time; allow it under System Settings > Privacy &
Security, then open it again. Developer ID signing and notarization come
with a paid developer account and change nothing else.

## Layout

    macos/          the app, the helper, the agent plists, the build scripts
    patches/        the changes to OwnTone and librespot, as plain patches
                    against their release sources; nothing in them is Nix
    nix/            owntone, librespot and an audio-only ffmpeg, plus the
                    generator for the bundle's third-party notices
    flake.nix       the three packages above, for macos/build-engine

## The patches

OwnTone 29.3 and librespot 0.8.0 are stock apart from these, in
`patches/owntone/` and `patches/librespot/`. They apply with `patch -p1`
to the release sources and owe nothing to Nix. Each patch file opens
with why it exists.

OwnTone:

- `owntone-evrtsp-connect-failure` survives a connect() that fails at
  once, which crashed the player thread on every second speaker.
- `owntone-websocket-vhost-init` makes the websocket's notifications
  exist at all under the libwebsockets in nixpkgs.
- `owntone-dacp-speaker-authorize` accepts a speaker's own DACP requests
  (its volume buttons) without widening `trusted_networks`.
- `owntone-airplay-events-to-listener` hands a speaker's play and pause
  (a HomePod's top) to the app instead of the player.
- `owntone-mdns-linklocal-address` keeps a speaker's IPv6 link-local
  address, which is where a HomePod's DACP requests come from.
- `owntone-input-readahead` cuts the input read-ahead from 2.2 s to
  0.25 s, most of the lag between a seek on the phone and the speakers.
- `owntone-pause-keeps-sessions` keeps the AirPlay sessions through a
  pause, so a resume is a restart of the stream and a HomePod's tap
  still reaches us; only a stop lets them go. A paused pipe reports its
  position instead of 0:00.
- `owntone-pipe-drain-on-stop` empties the pipe when the input stops,
  which was the crackle of stale audio on resume.
- `owntone-pipe-artwork-survives-pause` keeps the cover art through a
  pause.
- `owntone-pipe-title` titles a pipe item from the config rather than
  its file name, which is what the speakers showed until the track
  arrived.
- `owntone-airplay-flush-drops-partial-packet` drops the partial packet
  a flush left behind, which spliced onto the resumed audio as a click.
- `owntone-airplay-resume-continues-timeline` moves the RTP time on by
  the length of a pause, so the first packets after a resume are never
  due in the past under the speaker's old clock mapping.

librespot:

- `librespot-control-socket` adds `--control-socket PATH`: play, pause,
  next, prev, seek, volume and status on a Unix socket, routed through
  Spirc so the phone follows.
- `librespot-session-loss-reconnect` reconnects when the session to
  Spotify's servers dies, which stock 0.8 leaves dead for hours, and
  makes `status` report it.
- `librespot-play-from-stopped` makes a plain play after the end of a
  context start it again from the top, as Spotify's own button does.
- `librespot-pause-keeps-position` keeps a pause at the position the
  phone was showing rather than stepping it forward to the player's
  buffer-ahead one.

## Status

Works, daily, on one Mac with one HomePod pair. Not something to hand to
someone else yet:

- Unsigned for distribution and not notarized. No updater.
- The Local Network prompt for the engine reads "EngineHelper", not the
  app's name: macOS names a bare executable by its file name and ignores
  its embedded plist. The fix is to ship the helper as a bundle of its
  own.
- A resume is heard about two seconds after the press, which is the
  AirPlay 2 buffer OwnTone streams into. Apple's own senders do better
  with a protocol OwnTone does not speak.
- OwnTone runs without PTP (ports 319 and 320 are privileged), so the
  speakers sync over NTP. Fine for one stereo pair; unmeasured beyond it.
- Logs under Application Support grow without bound.
- The default receiver name is "HomePods", which sits oddly in a list of
  actual HomePods. Rename it in the popover.
- librespot 0.8 never learns which phone is connected, so the popover
  says "Connected" and cannot say from what.

## License

The app, the helper, the build scripts and the Nix expressions are under
the MIT License; see [LICENSE](LICENSE).

The patches are licensed like the programs they change. Those in
`patches/owntone/` are GPL-2.0-or-later, as OwnTone is, and the license
text is beside them in [patches/owntone/COPYING](patches/owntone/COPYING).
Those in `patches/librespot/` are MIT, as librespot is. Each patch says so
in its header.

A built app bundles OwnTone, librespot, FFmpeg and their libraries. Which
packages, under which licenses, and the full text of each, are in
`NOTICES.txt` in the bundle's Resources. `macos/build-engine` generates
it from the same Nix closure the binaries came from, so it cannot drift
from what ships.

Not affiliated with Spotify or Apple. Spotify is a trademark of Spotify
AB. AirPlay and HomePod are trademarks of Apple Inc. librespot is an
unofficial Spotify Connect client that Spotify does not support, so a
change on Spotify's side can stop it at any time.
