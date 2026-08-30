# macOS app

SwiftUI menu bar app over the bundled engine's JSON API. The engine itself
(owntone + librespot, see `../.agents-work/20260829-owntone-macos-spike/`)
is a separate process; this app never links it.

## Build

    ./generate                 # regenerate Tutti.xcodeproj from project.yml
    open Tutti.xcodeproj

Or from the command line:

    xcodebuild -project Tutti.xcodeproj -scheme Tutti -configuration Debug \
      -derivedDataPath .build build

`Tutti.xcodeproj` and `Info.plist` are generated but committed, so a fresh
clone builds in Xcode without XcodeGen. `project.yml` is the source of truth;
never hand-edit the project file.

## Running without the engine

    open .build/Build/Products/Debug/Tutti.app --args -UseFixtures YES

Loads `Fixtures.swift` instead of the network, so the whole UI is reachable
with nothing else running.

## Renaming the app

The product name is confined to two places:

- `project.yml` -- `name:` and `PRODUCT_BUNDLE_IDENTIFIER`
- `Sources/Support/Branding.swift` -- only the fallback string; the real
  value is read from `CFBundleName` at runtime

No Swift type carries the name. Change those, run `./generate`, done.

## Layout

    Sources/App/         app entry, activation policy
    Sources/Engine/      API client, websocket, observable store, fixtures
    Sources/UI/          popover, rows, settings
    Sources/Support/     branding, presence mode, login item

## Design

The popover follows the system Sound menu: material background, an "Output"
section of icon-well rows where selection is carried by an accent tint, native
`Slider` controls, and a footer of menu rows. No status badge -- activity is
signalled by the menu bar icon, which is where the system does it.

## Known gaps

- **No transport controls.** librespot streams into a fifo the engine drains,
  so pausing the engine stalls librespot's writes rather than pausing Spotify.
  Pause semantics need a spike before any play/pause button is honest.
- **Track metadata is always nil against a live engine.** It has to arrive via
  a Shairport-format `<fifo>.metadata` companion pipe fed from librespot's
  `--onevent` hook. That bridge does not exist yet.
- **Engine lifecycle is not wired.** The app assumes something is already
  listening on 3689/3688; `SMAppService` registration of the bundled engine
  comes next.
- **Rejoin-on-free is not implemented.** The store has no notion of an
  intended speaker set yet.
