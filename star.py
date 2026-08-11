#!/usr/bin/env python3
"""Star or unstar one track on Navidrome.

    star.py <star|unstar> <songId>

This is the same heart Navidrome's own web UI shows, and the same flag
getStarred2 reports, so a track favourited here shows up everywhere else.

Unlike control.py, this talks to the *server* -- starring is library metadata,
not playback, so it works no matter which client is playing and works from
outside the house.
"""

import json
import sys
import time
import urllib.parse

import subsonic

STARRED_FILE = subsonic.STATE_DIR + "/starred.json"


def out(ok, **kw):
    print(json.dumps({"ok": ok, **kw}))
    sys.exit(0 if ok else 1)


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("star", "unstar"):
        out(False, error="usage: star.py <star|unstar> <songId>")
    action, song_id = sys.argv[1], sys.argv[2]
    if not song_id:
        out(False, error="missing song id")

    try:
        cfg = subsonic.load_config()
    except FileNotFoundError:
        out(False, error="not configured")
    except ValueError:
        out(False, error="bad config")

    try:
        which, base, timeout, _ = subsonic.pick_endpoint(cfg, probe="ping")
        subsonic.call(base, cfg, action, "id=%s" % urllib.parse.quote(song_id), timeout=timeout)
    except subsonic.AuthError:
        out(False, error="auth failed")
    except Exception:
        out(False, error="unreachable")

    # Update the cache immediately so the heart flips on the next poll rather
    # than waiting out the staleness window we just invalidated.
    cache = subsonic.load_json(STARRED_FILE, {})
    cache[song_id] = {"starred": action == "star", "ts": time.time()}
    subsonic.save_json(STARRED_FILE, cache)

    out(True, action=action, id=song_id)


if __name__ == "__main__":
    main()
