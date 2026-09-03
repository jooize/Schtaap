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
  patches = [
    ./owntone-evrtsp-connect-failure.patch
    ./owntone-websocket-vhost-init.patch
  ];

  configureFlags = [ "--without-avahi" ];

  enableParallelBuilding = true;

  meta = {
    description = "Media server that streams audio to AirPlay 2 receivers";
    homepage = "https://github.com/owntone/owntone-server";
    license = lib.licenses.gpl2Plus;
    mainProgram = "owntone";
    platforms = lib.platforms.darwin;
  };
})
