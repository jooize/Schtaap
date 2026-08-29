#!/bin/bash
# Guest provisioning (Ubuntu noble, arm64). Idempotent; runs as root.
# Mirrored into spotifytohomepod.yaml -- keep both in sync.
set -eux -o pipefail
export DEBIAN_FRONTEND=noninteractive

# --- librespot via raspotify (prebuilt deb + systemd service) ---
# raspotify's install.sh fails on noble: it asks for "libasound2" by
# name, which noble renamed to libasound2t64. Installing the deb
# directly lets apt satisfy the dependency via the t64 provider.
if ! dpkg -s raspotify >/dev/null 2>&1; then
  apt-get update -q
  apt-get install -y -q libasound2t64
  curl -fsSL -o /tmp/raspotify.deb \
    https://dtcooper.github.io/raspotify/raspotify-latest_arm64.deb
  apt-get install -y -q /tmp/raspotify.deb
fi

# Audio handoff: librespot writes raw PCM (44.1kHz/16-bit/stereo)
# into a fifo that OwnTone watches as library content.
install -d -m 755 /srv/music
[ -p /srv/music/spotify ] || mkfifo -m 666 /srv/music/spotify

cat > /etc/raspotify/conf <<'EOF'
LIBRESPOT_NAME="HomePods"
LIBRESPOT_BITRATE="320"
LIBRESPOT_BACKEND="pipe"
LIBRESPOT_DEVICE="/srv/music/spotify"
# Nothing persists on our machines: the sender's phone authorizes
# each session over zeroconf.
LIBRESPOT_DISABLE_AUDIO_CACHE=
LIBRESPOT_DISABLE_CREDENTIAL_CACHE=
EOF
systemctl enable raspotify
systemctl restart raspotify

# --- OwnTone (official container, host network for mDNS/AirPlay) ---
install -d -m 755 /etc/owntone
install -d -m 755 -o 1000 -g 1000 /var/cache/owntone
cat > /etc/owntone/owntone.conf <<'EOF'
general {
  uid = "owntone"
  db_path = "/var/cache/owntone/songs3.db"
  cache_dir = "/var/cache/owntone"
}
library {
  name = "SpotifyToHomePod"
  directories = { "/srv/music" }
  pipe_autostart = true
}
EOF

if ! docker inspect owntone >/dev/null 2>&1; then
  docker run -d --name owntone \
    --network host \
    -e UID=1000 -e GID=1000 \
    -v /etc/owntone:/etc/owntone \
    -v /srv/music:/srv/music \
    -v /var/cache/owntone:/var/cache/owntone \
    --restart unless-stopped \
    docker.io/owntone/owntone:latest
fi
