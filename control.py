#!/usr/bin/env python3
"""Send one transport command to the client that is playing.

Navidrome cannot do this. Subsonic has no pause endpoint, because the server
does not own playback -- so control talks to the *client*, and each client type
needs its own adapter.

    control.py <player-name> <playpause|next|previous|stop>
"""

import json
import os
import sys
import urllib.error

import kodi

CONFIG = os.environ.get("OMARCHY_NAVIDROME_CONFIG") or os.path.expanduser(
    "~/.config/omarchy-navidrome/config.json"
)
ACTIONS = ("playpause", "next", "previous", "stop")


def out(ok, **kw):
    print(json.dumps({"ok": ok, **kw}))
    sys.exit(0 if ok else 1)


def main():
    if len(sys.argv) != 3:
        out(False, error="usage: control.py <player> <%s>" % "|".join(ACTIONS))
    player, action = sys.argv[1], sys.argv[2]
    if action not in ACTIONS:
        out(False, error="unknown action %r" % action)

    try:
        cfg = json.load(open(CONFIG))
    except Exception:
        out(False, error="not configured")

    ctl = next((c for c in (cfg.get("controllers") or []) if c.get("player") == player), None)
    if not ctl:
        out(False, error="no controller configured for %s" % player)
    if ctl.get("type") != "kodi":
        out(False, error="unsupported controller type %r" % ctl.get("type"))

    try:
        kodi.control(ctl, action)
    except urllib.error.HTTPError as e:
        out(False, error="auth failed" if e.code in (401, 403) else "http %d" % e.code)
    except RuntimeError as e:
        out(False, error=str(e))
    except Exception:
        out(False, error="controller unreachable")

    out(True, player=player, action=action)


if __name__ == "__main__":
    main()
