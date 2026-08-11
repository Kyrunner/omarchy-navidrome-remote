#!/usr/bin/env python3
"""Kodi JSON-RPC adapter.

The only client type with a remote API among the ones this plugin targets, and
therefore the only one that can be controlled *or* asked whether it is actually
playing.

That second job matters more than it sounds. Navidrome's getNowPlaying is a
registry of recently *reported* playback and it extrapolates position from the
last report plus elapsed time -- so a client that stopped still reads as
`state: playing` with a position that keeps climbing, until the entry ages out.
The server genuinely does not know playback ended. Only the client does.
"""

import base64
import json
import urllib.request

# Short on purpose: liveness is checked on every poll, and a sleeping Kodi must
# not stall the whole widget waiting to time out.
LIVENESS_TIMEOUT = 2.0
COMMAND_TIMEOUT = 8.0


def rpc(ctl, method, params=None, timeout=COMMAND_TIMEOUT):
    body = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params:
        body["params"] = params
    headers = {"Content-Type": "application/json"}
    if ctl.get("user") or ctl.get("password"):
        cred = "%s:%s" % (ctl.get("user", ""), ctl.get("password", ""))
        headers["Authorization"] = "Basic " + base64.b64encode(cred.encode()).decode()
    req = urllib.request.Request(
        ctl["url"].rstrip("/") + "/jsonrpc", data=json.dumps(body).encode(), headers=headers
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def active_audio_player(ctl, timeout=COMMAND_TIMEOUT):
    players = rpc(ctl, "Player.GetActivePlayers", timeout=timeout).get("result") or []
    return next((p for p in players if p.get("type") == "audio"), None) or (players[0] if players else None)


def is_playing(ctl):
    """True / False / None.

    None means "could not ask" -- a Kodi that is off or unreachable. The caller
    must not treat that as False, or a network blip would make a live session
    vanish from the bar.
    """
    try:
        return active_audio_player(ctl, timeout=LIVENESS_TIMEOUT) is not None
    except Exception:
        return None


def control(ctl, action):
    """Raises on failure. Returns nothing useful; the next poll is the truth."""
    player = active_audio_player(ctl)
    if player is None:
        raise RuntimeError("nothing is playing on that client")
    pid = player["playerid"]

    if action == "playpause":
        rpc(ctl, "Player.PlayPause", {"playerid": pid})
    elif action == "next":
        rpc(ctl, "Player.GoTo", {"playerid": pid, "to": "next"})
    elif action == "previous":
        # Kodi's "previous" restarts the current track first, matching every other
        # music player; a second press within a couple of seconds is what steps
        # back. That is Kodi's behaviour, not something to paper over here.
        rpc(ctl, "Player.GoTo", {"playerid": pid, "to": "previous"})
    elif action == "stop":
        rpc(ctl, "Player.Stop", {"playerid": pid})
    else:
        raise ValueError("unknown action %r" % action)
