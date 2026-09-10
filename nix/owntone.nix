# OwnTone for macOS.
#
# nixpkgs ships owntone as Linux-only: its expression pulls in Avahi and
# autoPatchelfHook, and its meta.platforms excludes darwin. macOS has its own
# mDNS responder, and owntone's src/mdns_dnssd.c speaks to it directly, so
# `--without-avahi` is the whole port. Everything else is a stock autotools
# build.
#
# The release tarball ships a generated `configure`, so there is no
# autoreconfHook here and no gettext-0.25 patch to carry: both exist in
# nixpkgs only to cope with building from a git checkout.
{
  lib,
  stdenv,
  fetchurl,

  bison,
  curl,
  ffmpeg,
  flex,
  gettext,
  gperf,
  json_c,
  libconfuse,
  libevent,
  libgcrypt,
  libgpg-error,
  libinotify-kqueue,
  libplist,
  libsodium,
  libunistring,
  libwebsockets,
  libxml2,
  openssl,
  pkg-config,
  protobufc,
  sqlite,
  zlib,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "owntone";
  version = "29.3";

  src = fetchurl {
    url =
      "https://github.com/owntone/owntone-server/releases/download/"
      + "${finalAttrs.version}/owntone-${finalAttrs.version}.tar.xz";
    hash = "sha256-qgy/xWUapld2qL0hEsngqQSyGFyDeQDT9klLnsboxUc=";
  };

  nativeBuildInputs = [
    bison
    flex
    gettext
    gperf
    pkg-config
  ];

  buildInputs = [
    curl
    ffmpeg
    json_c
    libconfuse
    libevent
    libgcrypt
    libgpg-error
    libinotify-kqueue
    libplist
    libsodium
    libunistring
    libwebsockets
    libxml2
    # 29.3's websocket.c reaches libwebsockets.h, which includes
    # openssl/ssl.h. libssl arrives anyway as a libwebsockets dependency;
    # only the headers are missing.
    openssl
    protobufc
    sqlite
    zlib
  ];

  # A connect() that fails synchronously left a freed request queued on
  # the RTSP connection and crashed the player thread on the next cleanup.
  # macOS produces exactly that failure when it denies local network
  # access, so without this the engine died on every attempt to reach a
  # speaker while the permission was missing -- before the permission
  # prompt could even be drawn.
  #
  # And libwebsockets 4.4 never sends the notify protocol its PROTOCOL_INIT
  # callback, which is the only place owntone allocated the list of
  # connected clients: without it not one push notification was ever
  # written, and the app only ever saw what it fetched at launch.
  #
  # And a speaker's own volume buttons come back over DACP, which the
  # server only accepts from a trusted peer: with trusted_networks kept to
  # localhost, every such request was refused. Requests carrying a known
  # output's Active-Remote from that output's address are accepted now,
  # so the speaker needs no entry in trusted_networks.
  #
  # And a HomePod's touch surface sends play/pause/next/previous over the
  # AirPlay event channel, which owntone applied to its player: a pause
  # closes and reopens the pipe, librespot dies of EPIPE, and play restarts
  # the item at 0. Pause and play go out as websocket notifications
  # ("remote_pause", "remote_play") for the app to act on; next and
  # previous are dropped.
  #
  # And a HomePod sends those DACP reports from its IPv6 link-local
  # address, which the mDNS layer threw away. It is kept now as a
  # secondary address the device is recognised by, never connected to.
  #
  # And the input thread reads 2.2 s ahead, which is 2.2 s between a seek
  # or a pause on the phone and the speakers, on top of what AirPlay
  # buffers. A quarter of a second now.
  #
  # And ten seconds into a pause the AirPlay sessions were torn down, after
  # which a HomePod's tap plays its own library instead of resuming ours.
  # A pause keeps them now; only a stop lets them go. The same patch makes
  # a paused pipe report the position it was paused at instead of 0.
  #
  # And a pause, which stops and restarts the pipe input, left a third of
  # a second of pre-pause audio queued in the pipe to be heard first on
  # resume, and deleted the cover art the metadata pipe had delivered.
  # The input now empties the pipe when it stops, and the cover stays.
  #
  # And a pipe item is titled by `library { pipe_title }` rather than its
  # file name, which is what the speakers showed until the track arrived.
  #
  # And an AirPlay flush left the master session's partial packet in place,
  # ten milliseconds from ahead of the pause that went out first on resume,
  # spliced onto the resumed audio as a click. The flush drops it now.
  #
  # And a resume re-anchored the stream's clock while its rtptime stood
  # still, so a device reading the first packet before the sync played
  # a moment of the song at once. The rtptime moves on by the pause now.
  #
  # And an empty `logfile` means none. In the foreground owntone logs to
  # the console as well, and the helper captures that into a file it
  # rotates, so the logfile was the same log twice.
  patches = [
    ../patches/owntone/owntone-evrtsp-connect-failure.patch
    ../patches/owntone/owntone-websocket-vhost-init.patch
    ../patches/owntone/owntone-dacp-speaker-authorize.patch
    ../patches/owntone/owntone-airplay-events-to-listener.patch
    ../patches/owntone/owntone-mdns-linklocal-address.patch
    ../patches/owntone/owntone-input-readahead.patch
    ../patches/owntone/owntone-pause-keeps-sessions.patch
    ../patches/owntone/owntone-pipe-drain-on-stop.patch
    ../patches/owntone/owntone-pipe-artwork-survives-pause.patch
    ../patches/owntone/owntone-pipe-title.patch
    ../patches/owntone/owntone-airplay-flush-drops-partial-packet.patch
    ../patches/owntone/owntone-airplay-resume-continues-timeline.patch
    ../patches/owntone/owntone-logfile-empty-means-none.patch
  ];

  configureFlags = [ "--without-avahi" ];

  # ld64 derives LC_UUID from a hash of its output that skips the symbol and
  # string tables but not the load command recording the string table's
  # size. With -g the stabs (N_OSO, N_SO) name the build directory, which
  # on macOS is random per build and of a different length under Nix
  # (/nix/var/nix/builds/nix-<pid>-<n>) than under Lix (/nix/var/nix/b/<n>),
  # so two machines got two UUIDs for otherwise identical binaries. Nix
  # strips the stabs anyway; -S keeps them out of the link output, and the
  # UUID then depends on the code alone. Found 2026-09-08 comparing a local
  # build with a GitHub runner's: 16 bytes apart, all of them the UUID.
  env.NIX_LDFLAGS = "-S";

  enableParallelBuilding = true;

  meta = {
    description = "Media server that streams audio to AirPlay 2 receivers";
    homepage = "https://github.com/owntone/owntone-server";
    license = lib.licenses.gpl2Plus;
    mainProgram = "owntone";
    platforms = lib.platforms.darwin;
  };
})
