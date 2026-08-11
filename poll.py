#!/usr/bin/env python3
"""Ask Navidrome what is playing anywhere; emit one JSON line.

Invoked only by backend.sh. Everything that talks to Navidrome lives here, in
star.py, or in subsonic.py -- never in QML -- so the whole network surface can be
read and run over SSH without launching the shell.

Subsonic is a streaming protocol with no transport endpoints, so this half only
ever reads. Control lives in control.py and talks to the *client*, not the server.
"""

import json
import os
import sys
import time
import urllib.parse

import kodi
import subsonic

COVER_DIR = os.path.join(subsonic.STATE_DIR, "covers")
STARRED_FILE = os.path.join(subsonic.STATE_DIR, "starred.json")

COVER_CACHE_MAX = 100
# getNowPlaying does not report starred state, so it needs a second call per
# track. Re-checking at most this often keeps the heart honest when a track is
# starred elsewhere, without doubling the request rate of the whole widget.
STARRED_TTL_SEC = 30
STARRED_CACHE_MAX = 500


def die(msg):
    print(json.dumps({"ok": False, "error": msg, "sessions": [], "endpoint": None}))
    sys.exit(1)


def cover_path(base, cfg, cover_id, timeout):
    """Download cover art once and hand QML a file path.

    Keeps Subsonic credentials out of QML entirely -- the alternative is baking
    an auth token into an Image.source URL -- and stops the art being refetched
    on every single poll.
    """
    if not cover_id:
        return ""
    safe = "".join(c for c in cover_id if c.isalnum() or c in "-_")[:120]
    if not safe:
        return ""
    path = os.path.join(COVER_DIR, safe + ".img")
    if os.path.exists(path):
        return path
    try:
        os.makedirs(COVER_DIR, exist_ok=True)
        data = subsonic.raw(
            subsonic.build_url(base, cfg["user"], cfg["password"], "getCoverArt",
                               "id=%s&size=300" % urllib.parse.quote(cover_id)),
            timeout,
        )
        tmp = path + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
        prune(COVER_DIR, ".img", COVER_CACHE_MAX)
        return path
    except Exception:
        return ""  # art is decoration; never let it sink the poll


def prune(directory, suffix, keep):
    try:
        files = [os.path.join(directory, f) for f in os.listdir(directory) if f.endswith(suffix)]
        if len(files) <= keep:
            return
        files.sort(key=lambda p: os.path.getmtime(p))
        for p in files[: len(files) - keep]:
            os.unlink(p)
    except Exception:
        pass


def starred_state(base, cfg, song_id, timeout, cache):
    """True when the track is starred.

    Subsonic omits the `starred` key entirely unless the item IS starred -- its
    presence is the flag, and its value is the timestamp. Verified against a
    known-starred track.
    """
    if not song_id:
        return False
    hit = cache.get(song_id)
    if hit and (time.time() - hit.get("ts", 0)) < STARRED_TTL_SEC:
        return bool(hit.get("starred"))
    try:
        song = subsonic.call(base, cfg, "getSong", "id=%s" % urllib.parse.quote(song_id),
                             timeout=timeout).get("song", {})
        val = "starred" in song
    except Exception:
        # Unknown beats guessing: an unstarred-looking heart that silently
        # unstars on click is worse than one that briefly reads stale.
        return bool(hit.get("starred")) if hit else False
    cache[song_id] = {"starred": val, "ts": time.time()}
    return val


def main():
    try:
        cfg = subsonic.load_config()
    except FileNotFoundError:
        die("not configured")
    except ValueError:
        die("bad config")

    try:
        which, base, timeout, body = subsonic.pick_endpoint(cfg)
    except subsonic.AuthError:
        die("auth failed")
    except Exception:
        die("unreachable")

    entries = (body.get("nowPlaying") or {}).get("entry") or []
    controllers = {c.get("player"): c for c in (cfg.get("controllers") or []) if c.get("player")}
    web = subsonic.link_base(cfg)
    cache = subsonic.load_json(STARRED_FILE, {})

    sessions = []
    for e in entries:
        player = e.get("playerName") or "unknown"
        ctl = controllers.get(player)

        control_error = None
        if not ctl:
            # Say why the state may also be wrong, not just why the buttons are
            # dead. Most Subsonic clients report once at track start and never
            # mention pausing, so a paused phone keeps reading as playing -- the
            # single most confusing thing this widget does.
            control_error = ("No remote control for %s — its state comes from the "
                             "client's last report, so a pause may still show as playing" % player)
        elif which == "public" and is_private_host(ctl.get("url", "")):
            # Inferred, not probed: if the poll itself had to leave the LAN, a
            # controller on a private address is unreachable by definition. Costs
            # no request and cannot be wrong in the direction that matters.
            control_error = "%s is LAN-only — not reachable from here" % player

        artist = e.get("artist") or e.get("displayArtist") or ""
        if isinstance(artist, list):
            artist = ", ".join(artist)

        duration = int(e.get("duration") or 0)
        position_ms = int(e.get("positionMs") or 0)

        # ---- is this session actually still alive? ----
        # getNowPlaying is a registry of recently *reported* playback, and
        # Navidrome extrapolates position from the last report plus elapsed
        # time. A client that stopped therefore keeps reading as `playing` with
        # a climbing position until the entry ages out. The server does not know
        # playback ended -- only the client does, so ask the client.
        alive = None
        if ctl and ctl.get("type") == "kodi" and control_error is None:
            alive = kodi.is_playing(ctl)   # True / False / None ("could not ask")
        if alive is False:
            continue
        # No controller, or the controller could not be reached: fall back to the
        # one thing the server data can still prove. Extrapolation past the end
        # of the track means the entry is a leftover, not playback.
        if alive is None and duration > 0 and position_ms > (duration + 15) * 1000:
            continue

        # Confirmed means "we asked the client and it said yes", and nothing else.
        #
        # `minutesAgo` looks like report-age and is not: it is the age of the
        # ENTRY. Measured across a resume it stayed at 1 while positionMs reset
        # from 84403 to 1900, and before that it exactly tracked
        # floor(positionMs/60000) -- an artefact of these clients reporting once
        # at track start, not a freshness signal. There is no field in this API
        # that distinguishes an extrapolated position from a measured one, so the
        # only real confirmation is asking the client directly.
        minutes_ago = int(e.get("minutesAgo") or 0)
        confirmed = alive is True

        song_id = e.get("id") or ""
        album_id = e.get("albumId") or ""
        # Navidrome's web UI is react-admin behind hash routing. There is no
        # per-song page, so a click lands on the album that contains it.
        web_url = ("%s/app/#/album/%s/show" % (web, album_id)) if (web and album_id) else ""

        sessions.append({
            "player": player,
            "user": e.get("username") or "",
            "song_id": song_id,
            "title": e.get("title") or "Unknown",
            "artist": artist,
            "album": e.get("album") or "",
            "duration_sec": duration,
            "position_ms": position_ms,
            "paused": (e.get("state") or "playing") != "playing",
            "confirmed": confirmed,
            "minutes_ago": minutes_ago,
            "cover": cover_path(base, cfg, e.get("coverArt"), timeout),
            "starred": starred_state(base, cfg, song_id, timeout, cache),
            "web_url": web_url,
            "controllable": control_error is None,
            "control_error": control_error,
        })

    if len(cache) > STARRED_CACHE_MAX:
        newest = sorted(cache.items(), key=lambda kv: kv[1].get("ts", 0), reverse=True)
        cache = dict(newest[:STARRED_CACHE_MAX])
    subsonic.save_json(STARRED_FILE, cache)

    # Most recently active first: with several devices going, the one you just
    # touched is the one you are most likely reaching for.
    sessions.sort(key=lambda s: (s["paused"], -s["position_ms"]))

    print(json.dumps({"ok": True, "endpoint": which, "sessions": sessions}))


def is_private_host(url):
    host = urllib.parse.urlparse(url).hostname or ""
    if host in ("localhost", "127.0.0.1", "::1"):
        return True
    parts = host.split(".")
    if len(parts) == 4 and all(p.isdigit() for p in parts):
        a, b = int(parts[0]), int(parts[1])
        return a == 10 or (a == 172 and 16 <= b <= 31) or (a == 192 and b == 168)
    return host.endswith(".local")


if __name__ == "__main__":
    main()
