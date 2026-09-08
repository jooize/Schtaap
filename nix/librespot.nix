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
#
# Only the binary crate is touched, and no dependency is added, so the
# vendored Cargo hash stays nixpkgs' own.
{ librespot }:

librespot.overrideAttrs (previous: {
  patches = (previous.patches or [ ]) ++ [
    ./librespot-control-socket.patch
    ./librespot-session-loss-reconnect.patch
    ./librespot-play-from-stopped.patch
    ./librespot-pause-keeps-position.patch
  ];
})
