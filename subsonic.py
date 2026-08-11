#!/usr/bin/env python3
"""Shared Subsonic plumbing: config, endpoint selection, authenticated calls.

Imported by poll.py and star.py. control.py does NOT use this — it talks to a
media client over that client's own protocol, not to Navidrome.
"""

import hashlib
import json
import os
import random
import time
import urllib.parse
import urllib.request

CONFIG = os.environ.get("OMARCHY_NAVIDROME_CONFIG") or os.path.expanduser(
    "~/.config/omarchy-navidrome/config.json"
)
STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
    "omarchy-navidrome",
)
ENDPOINT_FILE = os.path.join(STATE_DIR, "endpoint.json")

# Long enough that moving around the house does not thrash the endpoint choice,
# short enough that coming home restores the fast path without intervention.
PUBLIC_STICKY_SEC = 600
LAN_TIMEOUT = 2.5
PUBLIC_TIMEOUT = 10


class AuthError(Exception):
    """Bad credentials. Deliberately never triggers endpoint failover: retrying a
    wrong password against a public edge is how you get banned by your own
    rate limiter."""


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def save_json(path, data):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
    except Exception:
        pass  # state is a convenience; losing it must never break a call


def load_config():
    cfg = load_json(CONFIG, None)
    if cfg is None:
        raise FileNotFoundError("not configured")
    if not cfg.get("user") or not cfg.get("password") or not (cfg.get("url") or cfg.get("public_url")):
        raise ValueError("bad config")
    return cfg


def build_url(base, user, password, endpoint, extra=""):
    """Subsonic token auth: fresh salt per request, md5(password + salt).

    The password never crosses the wire, and a captured token is bound to its
    salt rather than being a reusable credential.
    """
    salt = "%08x%08x" % (random.getrandbits(32), random.getrandbits(32))
    token = hashlib.md5((password + salt).encode()).hexdigest()
    q = urllib.parse.urlencode(
        {"u": user, "t": token, "s": salt, "v": "1.16.1", "c": "omarchy-navidrome", "f": "json"}
    )
    return "%s/rest/%s?%s%s" % (base.rstrip("/"), endpoint, q, ("&" + extra) if extra else "")


def raw(url, timeout):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read()


def call(base, cfg, endpoint, extra="", timeout=10):
    body = json.loads(raw(build_url(base, cfg["user"], cfg["password"], endpoint, extra), timeout))
    body = body["subsonic-response"]
    if body.get("status") != "ok":
        err = body.get("error") or {}
        if err.get("code") in (40, 41, 42, 43, 44):
            raise AuthError(err.get("message", "auth failed"))
        raise RuntimeError(err.get("message", "rejected"))
    return body


def pick_endpoint(cfg, probe="getNowPlaying"):
    """Choose LAN or public, honouring a sticky window.

    Returns (which, base, timeout, body-of-probe-call).

    The stickiness matters because these scripts run as fresh processes per poll:
    with no memory, every poll away from home would pay the LAN timeout first.
    """
    lan, public = cfg.get("url"), cfg.get("public_url")
    state = load_json(ENDPOINT_FILE, {})
    on_public = state.get("which") == "public"
    fresh = (time.time() - float(state.get("since") or 0)) < PUBLIC_STICKY_SEC

    if on_public and fresh and public:
        order = [("public", public, PUBLIC_TIMEOUT)]
    else:
        order = ([("lan", lan, LAN_TIMEOUT)] if lan else []) + \
                ([("public", public, PUBLIC_TIMEOUT)] if public else [])

    last = None
    for which, base, timeout in order:
        try:
            body = call(base, cfg, probe, timeout=timeout)
            if which != state.get("which") or which == "public":
                # Refresh while on public so the sticky window measures from last
                # confirmed use rather than from the first failure.
                save_json(ENDPOINT_FILE, {"which": which, "since": time.time()})
            return which, base, timeout, body
        except AuthError:
            raise
        except Exception as e:
            last = e

    # A sticky public choice can go stale (came home, wifi changed). One retry of
    # the full order beats staying wedged on an endpoint that is gone.
    if on_public and fresh and lan:
        save_json(ENDPOINT_FILE, {})
        return pick_endpoint(cfg, probe)

    raise last or RuntimeError("no endpoint configured")


def link_base(cfg):
    """Base URL for links opened in a BROWSER.

    Prefers the public address so a click still works away from home, where a
    LAN address would simply fail to load.
    """
    return (cfg.get("public_url") or cfg.get("url") or "").rstrip("/")
