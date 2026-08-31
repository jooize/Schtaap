#!/usr/bin/env python3
"""Check librespot-metadata the way owntone's src/inputs/pipe.c reads it.

No engine needed: this mirrors OwnTone's own parsing rules and drives the real
script, including a live FIFO and the race where OwnTone is not yet watching.

    python3 bridge/test-librespot-metadata.py
"""
import base64, os, re, subprocess, sys, tempfile, threading, time

BRIDGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "librespot-metadata")
RATE = 44100
fails = []


def check(label, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + label + ("" if cond else "  <- " + str(detail)[:120]))
    if not cond:
        fails.append(label)


def run(env_extra, *args, state=None):
    env = dict(os.environ)
    env.update(env_extra)
    env["TUTTI_STATE_DIR"] = state or STATE
    return subprocess.run([BRIDGE, *args], env=env, capture_output=True, text=True)


def parse(blob):
    """owntone: split on </item>, read hex type/code, base64-decode data."""
    out = []
    for chunk in re.findall(r"<item>.*?</item>", blob, re.S):
        t = re.search(r"<type>([0-9a-f]{8})</type>", chunk).group(1)
        c = re.search(r"<code>([0-9a-f]{8})</code>", chunk).group(1)
        d = re.search(r'<data encoding="base64">\s*(.*?)</data>', chunk, re.S)
        payload = base64.b64decode(d.group(1)) if d else None
        length = int(re.search(r"<length>(\d+)</length>", chunk).group(1))
        out.append((bytes.fromhex(t).decode(), bytes.fromhex(c).decode(), payload, length))
    return out


def codes(blob):
    return [c for _, c, _, _ in parse(blob)]


def payloads(blob):
    return {c: p for _, c, p, _ in parse(blob)}


def ms(payload):
    start, pos, end = (int(x) for x in payload.split(b"/"))
    return (pos - start) * 1000 // RATE, (end - start) * 1000 // RATE


TRACK = {"PLAYER_EVENT": "track_changed", "NAME": "Sultans of Swing",
         "ARTISTS": "Dire Straits\nEric Clapton", "ALBUM": "Alchemy",
         "DURATION_MS": "348920", "ITEM_TYPE": "Track", "TRACK_ID": "abc"}

STATE = tempfile.mkdtemp()

print("\n1. track_changed emits flush + title/artist/album + progress")
r = run(TRACK, "--audio-pipe", "/tmp/x.fifo", "--no-artwork", "--dry-run")
check("order is pfls,minm,asar,asal,prgr", codes(r.stdout) == ["pfls", "minm", "asar", "asal", "prgr"], codes(r.stdout))
by = payloads(r.stdout)
check("title round-trips", by["minm"] == b"Sultans of Swing", by.get("minm"))
check("multiple artists joined", by["asar"] == "Dire Straits, Eric Clapton".encode(), by.get("asar"))
check("album round-trips", by["asal"] == b"Alchemy", by.get("asal"))
check("length matches payload", all(p is None or l == len(p) for _, _, p, l in parse(r.stdout)))
check("types are core/ssnc", set(t for t, _, _, _ in parse(r.stdout)) == {"core", "ssnc"})
start, pos, end = (int(x) for x in by["prgr"].split(b"/"))
check("no zero component (owntone rejects those)", 0 not in (start, pos, end), by["prgr"])
check("owntone would compute len_ms=348920", ms(by["prgr"])[1] == 348920)
check("owntone would compute pos_ms=0", ms(by["prgr"])[0] == 0)

print("\n2. undelivered metadata is re-sent on the next position event")
r = run({"PLAYER_EVENT": "playing", "POSITION_MS": "60000", "TRACK_ID": "abc"},
        "--audio-pipe", "/tmp/x.fifo", "--no-artwork", "--dry-run")
check("re-sends the whole description", codes(r.stdout) == ["pfls", "minm", "asar", "asal", "prgr"], codes(r.stdout))
by = payloads(r.stdout)
check("title survived across invocations", by["minm"] == b"Sultans of Swing", by.get("minm"))
check("artist survived", by["asar"] == "Dire Straits, Eric Clapton".encode(), by.get("asar"))
check("progress uses the live position", ms(by["prgr"]) == (60000, 348920), ms(by["prgr"]))

print("\n3. podcasts fall back to the show name")
S = tempfile.mkdtemp()
r = run({"PLAYER_EVENT": "track_changed", "NAME": "Ep. 1", "ITEM_TYPE": "Episode",
         "SHOW_NAME": "A Show", "DURATION_MS": "1000", "TRACK_ID": "z"},
        "--audio-pipe", "/tmp/x.fifo", "--no-artwork", "--dry-run", state=S)
by = payloads(r.stdout)
check("artist falls back to show", by.get("asar") == b"A Show", by.get("asar"))
check("album falls back to show", by.get("asal") == b"A Show", by.get("asal"))

print("\n4. stopped flushes and forgets")
r = run({"PLAYER_EVENT": "stopped", "TRACK_ID": "z"}, "--audio-pipe", "/tmp/x.fifo", "--dry-run", state=S)
check("emits a lone pfls", codes(r.stdout) == ["pfls"], r.stdout[:80])
r = run({"PLAYER_EVENT": "playing", "POSITION_MS": "5000"}, "--audio-pipe", "/tmp/x.fifo", "--dry-run", state=S)
check("nothing left to say after stop", parse(r.stdout) == [], r.stdout[:80])

print("\n5. unknown events and zero durations stay silent")
r = run({"PLAYER_EVENT": "volume_changed", "VOLUME": "32768"}, "--audio-pipe", "/tmp/x.fifo", "--dry-run", state=S)
check("volume is not forwarded", r.stdout.strip() == "", r.stdout[:80])
r = run({"PLAYER_EVENT": "track_changed", "NAME": "Live", "DURATION_MS": "0", "TRACK_ID": "q"},
        "--audio-pipe", "/tmp/x.fifo", "--no-artwork", "--dry-run", state=S)
check("no prgr when duration is 0", "prgr" not in codes(r.stdout), codes(r.stdout))

print("\n6. FIFO writing")
d = tempfile.mkdtemp(); audio = os.path.join(d, "spotify.fifo"); meta = audio + ".metadata"
S2 = tempfile.mkdtemp()
r = run({}, "--audio-pipe", audio, "--setup", state=S2)
check("--setup creates the metadata pipe", os.path.exists(meta) and r.returncode == 0)

got = []
def reader(path, sink):
    with open(path, "rb") as fh:
        sink.append(fh.read())
t = threading.Thread(target=reader, args=(meta, got), daemon=True); t.start(); time.sleep(0.3)
r = run(dict(TRACK, TRACK_ID="w"), "--audio-pipe", audio, "--no-artwork", state=S2)
time.sleep(0.4); t.join(timeout=1.5)
check("bytes reached a live reader", got and b"Sultans of Swing" in payloads(got[0].decode()).get("minm", b""))

print("\n7. no reader: returns fast, does not hang, does not fail librespot")
d2 = tempfile.mkdtemp(); a2 = os.path.join(d2, "s.fifo"); S3 = tempfile.mkdtemp()
run({}, "--audio-pipe", a2, "--setup", state=S3)
t0 = time.monotonic()
r = run(dict(TRACK, TRACK_ID="n"), "--audio-pipe", a2, "--no-artwork", "--verbose", state=S3)
check("returns in well under the write timeout", time.monotonic() - t0 < 1.5)
check("exits 0 so librespot sees no error", r.returncode == 0, r.returncode)
check("says why on stderr", "nothing reading" in r.stderr, r.stderr.strip()[:90])

print("\n8. THE RACE: track_changed dropped, then recovered once owntone reads")
# Exactly the real sequence: owntone is not watching when the track starts.
check("nothing was delivered", "nothing reading" in r.stderr)
got2 = []
t = threading.Thread(target=reader, args=(a2 + ".metadata", got2), daemon=True); t.start(); time.sleep(0.3)
r = run({"PLAYER_EVENT": "playing", "POSITION_MS": "1500", "TRACK_ID": "n"},
        "--audio-pipe", a2, "--no-artwork", "--verbose", state=S3)
time.sleep(0.4); t.join(timeout=1.5)
check("bridge noticed it had to retry", "never reached owntone" in r.stderr, r.stderr.strip()[:90])
recovered = payloads(got2[0].decode()) if got2 else {}
check("the lost title arrived on retry", recovered.get("minm") == b"Sultans of Swing", recovered.get("minm"))
check("artist arrived too", recovered.get("asar") == "Dire Straits, Eric Clapton".encode(), recovered.get("asar"))
check("progress reflects the later position", recovered.get("prgr") and ms(recovered["prgr"])[0] == 1500,
      recovered.get("prgr"))

print("\n9. once delivered, later events are progress only")
got3 = []
t = threading.Thread(target=reader, args=(a2 + ".metadata", got3), daemon=True); t.start(); time.sleep(0.3)
r = run({"PLAYER_EVENT": "playing", "POSITION_MS": "9000", "TRACK_ID": "n"},
        "--audio-pipe", a2, "--no-artwork", "--verbose", state=S3)
time.sleep(0.4); t.join(timeout=1.5)
check("no redundant re-send", "never reached owntone" not in r.stderr, r.stderr.strip()[:90])
check("just a prgr on the wire", got3 and codes(got3[0].decode()) == ["prgr"],
      codes(got3[0].decode()) if got3 else "nothing")

print("\n10. missing pipe is reported, not fatal")
r = run(dict(TRACK, TRACK_ID="m"), "--audio-pipe", "/nonexistent/dir/s.fifo",
        "--no-artwork", "--verbose", state=tempfile.mkdtemp())
check("exits 0", r.returncode == 0, r.returncode)
check("mentions --setup", "--setup" in r.stderr, r.stderr.strip()[:90])

print("\n" + ("ALL CHECKS PASSED" if not fails else "FAILED: %s" % fails))
sys.exit(1 if fails else 0)
