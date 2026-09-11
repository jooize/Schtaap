# librespot, the Spotify Connect receiver the app runs beside owntone, with
# one addition: a local control socket.
#
# Stock librespot is driven by the phone alone and only reports back, through
# `--onevent`. The app has its own transport controls and volume slider, and
# a HomePod's buttons come in through the engine, none of which the phone
# would ever learn about. `--control-socket PATH` accepts play, pause, next,
# prev and volume on a Unix socket and routes them through Spirc, so the
# phone's slider and play state follow. See the patch for the wire format.
#
# The second patch makes the main loop reconnect when the session to
# Spotify's servers is lost, which stock 0.8 leaves dead until the Spirc
# happens to shut down, and teaches `status` to report that session.
# The third makes a plain play while stopped (the end of a playlist with
# autoplay off) start the context again, as Spotify's own button does.
# The fourth keeps a pause at the position the phone was showing, rather
# than stepping it forward to the player's own, which runs ahead of the
# pipe by whatever the engine has buffered.
# The fifth raises volume_changed only for a remote's change: not for a
# volume sent on the socket, which the app would apply to its own master a
# second time, late, and not at activation, which would put the speakers
# at librespot's own level on every connect.
#
# Only librespot's own crates are touched, and no dependency is added, so
# the vendored Cargo hash stays nixpkgs' own.
{ librespot }:

librespot.overrideAttrs (previous: {
  patches = (previous.patches or [ ]) ++ [
    ../patches/librespot/librespot-control-socket.patch
    ../patches/librespot/librespot-session-loss-reconnect.patch
    ../patches/librespot/librespot-play-from-stopped.patch
    ../patches/librespot/librespot-pause-keeps-position.patch
    ../patches/librespot/librespot-volume-events-only-from-remotes.patch
  ];

  # rustc records a source path for every panic location, and the vendored
  # crates are compiled from under the build directory. On macOS Nix has no
  # chroot, so that directory has a fresh random name per build
  # (/nix/var/nix/builds/nix-<pid>-<n>/ under Nix, /nix/var/nix/b/<n>/ under
  # Lix) and two builds of this derivation differed in ~950 embedded paths
  # plus the content-derived LC_UUID. Mapped to /build, which is what the
  # Linux sandbox would have made it, the same commit gives the same bytes.
  # buildRustPackage sets no RUSTFLAGS of its own for a release build, so
  # this is appended rather than replacing anything.
  preBuild = (previous.preBuild or "") + ''
    export RUSTFLAGS="''${RUSTFLAGS-} --remap-path-prefix $NIX_BUILD_TOP=/build"
  '';
})
