# ky.navidrome-remote — design

Shows what is playing on your Navidrome server from *any* client — Kodi, a
phone, a tablet, cliamp — and controls it where the client allows control.

Verified against Navidrome **0.63.2** and Kodi JSON-RPC **13.10** on 2026-08-11.

## The split that defines this plugin

**Display is universal. Control is not.**

Subsonic is a streaming protocol. It will tell you what is playing, but it has
no transport endpoints — there is no `pause` in the API, because the server does
not own playback, the client does. Anything that pauses music has to talk to the
client directly.

- **Kodi** exposes JSON-RPC (`Player.PlayPause`, `Player.GoTo`, `Player.Stop`).
- **Phone and tablet Subsonic apps** expose nothing. There is no remote API to
  call, and no amount of design work creates one.

So the widget shows every session and lights the transport buttons only for
sessions it can actually reach. A disabled button that says why beats a button
that looks alive and silently does nothing.

## What Navidrome gives us

Navidrome's `getNowPlaying` carries fields beyond stock Subsonic:

```json
{"username":"you","playerName":"KodiNavidrome","title":"Scheherazade",
 "artist":"Rimsky-Korsakov","album":"Scheherazade","duration":727,
 "positionMs":76565,"state":"playing","coverArt":"mf-A2go1...","id":"A2go1..."}
```

`positionMs` advances in real time and `state` reports `playing`/`paused`, so a
live progress bar works for **every** client, not just the controllable ones.
`playerName` is what maps a session to a controller.

Auth is Subsonic token auth: a fresh random salt per request and
`md5(password + salt)`, so the password itself never crosses the wire.

## Two endpoints, and why the order matters

```json
{
  "url": "http://192.168.1.10:4533",
  "public_url": "https://navidrome.example.com",
  "user": "...",
  "password": "...",
  "controllers": [
    { "player": "KodiNavidrome", "type": "kodi",
      "url": "http://192.168.1.20:8080", "user": "...", "password": "..." }
  ]
}
```

At a 5s poll this widget makes **17,280 requests a day**. Sent through a public
edge running Traefik + geoblock + CrowdSec + rate limiting, that is a steady
drum on your own defences, and the reward for tripping them is your own IP
getting banned. The LAN path is therefore the default, not merely the fast one.

`public_url` exists so the widget keeps working away from home, where it backs
off to a 20s poll — still responsive enough to track song changes, far below any
sane rate limit. The **retry** cadence follows the endpoint too: a failing poll
normally retries every 5s, but on the public path it retries at the backed-off
20s instead. Being rate-limited is one of the ways that path fails, and answering
a rate limit by quadrupling the request rate is how a temporary block becomes a
ban.

### Endpoint selection is persisted, because the backend is not a daemon

`backend.sh` runs as a fresh process on every poll, so it cannot remember which
endpoint worked. Without persistence, every poll away from home would pay a LAN
timeout before falling back.

`~/.local/state/omarchy-navidrome/endpoint.json` records the choice with a
timestamp. LAN is tried first; on failure the plugin switches to public and
stays there for 10 minutes before re-probing LAN, so walking back through the
front door restores the fast path on its own.

## Controllability, and telling apart two different failures

A session is controllable only when its `playerName` matches a configured
controller. But "no controller" and "controller unreachable" are different
problems and get different messages:

| Situation | Buttons | Message |
|-----------|---------|---------|
| Player matches a controller, LAN endpoint in use | enabled | — |
| Player has no controller (phone, tablet) | disabled | "No remote control for `<player>`" |
| Player has a controller but we are on the public endpoint | disabled | "Kodi is LAN-only — not reachable from here" |

The third row is inferred rather than probed: if the poll itself had to fall
back to the public endpoint, a controller on a private address is unreachable by
definition. That costs no extra request and cannot be wrong in the direction
that matters.

## Cover art

Fetched by the backend, not by QML. `poll.py` downloads each `coverArt` id once
into `~/.local/state/omarchy-navidrome/covers/` and hands QML a plain file path.

This keeps Subsonic credentials out of QML entirely — the alternative is
embedding an auth token in an `Image.source` URL — and means the art is not
re-fetched on every poll. The cache is capped at 100 files, evicted oldest-first.

## Bar states

| State | Bar shows |
|-------|-----------|
| Nothing playing anywhere | hidden |
| One session playing | vinyl icon |
| One session paused | vinyl icon, dimmed |
| More than one session | vinyl icon + count badge |
| Failing < 45s, nothing known yet | hidden — the boot case, before the first poll lands |
| Failing < 45s, sessions known | unchanged: last known session, popup marks it last-known |
| not configured / unreachable / auth failed for 45s | dimmed icon + red `!` |

A fault keeps its width instead of collapsing, so "broken" and "nothing playing"
never look the same. The undecided window is the one case that hides rather than
keeping its width, and only when there is nothing to show — a widget that has a
session keeps showing it rather than blinking out of the bar mid-session.

## The grace window

The bar starts about ten seconds before WiFi associates, so the first poll of
every boot fails. Rendering that is a lie with a red badge on it.

`Readiness.qml` (logic in `Readiness.js`, tested with `node Readiness.test.js`)
holds the rule, and it is uniform — there is no startup special case. **A failure
is silent until it has lasted 45 seconds of continuous failing.** It retries at
5s meanwhile (20s on the public endpoint, as above), and one success anywhere in
that window resets the clock. So a boot is quiet, a blip is quiet, and a
genuinely dead server still speaks up within a minute or so.

That 45s is real elapsed time, accumulated one poll at a time with each interval
sanity-checked against the delay actually scheduled. It has to be:
`systemd-timesyncd` makes its first correction inside this very window, and a
suspend moves the clock by hours. A step in either direction is credited as one
scheduled interval, so it can neither manufacture a fault nor hide one.

## Popup

Every active session is listed — you may genuinely have Kodi and a phone going
at once — each with cover art, title/artist/album, a live progress bar, and its
own transport row.

Position comes from `positionMs` plus a 1 Hz local tick between polls, so the
bar creeps rather than jumping every 5s. The poll stays authoritative and resets
the tick, so drift cannot accumulate past one interval.

## Knowing when playback has actually stopped

`getNowPlaying` is a registry of recently **reported** playback, and Navidrome
**extrapolates** position from the last report plus elapsed time. Stop a client
and the entry keeps reading `state: playing` with a position that climbs on
forever, until it ages out. Observed directly: Kodi returning
`Player.GetActivePlayers: []` while Navidrome still reported
`state='playing', minutesAgo=4` with `positionMs` advancing 265411 → 271421 over
six seconds.

The server does not know playback ended. Only the client does. So each poll asks
the client:

| Client answer | Session |
|---------------|---------|
| `Player.GetActivePlayers` non-empty | live, shown |
| empty | dropped — it really has stopped |
| unreachable (Kodi off, network blip) | *unknown*, see below |

Unreachable must not be read as "stopped", or a momentary blip would make a live
session vanish from the bar. For unknown — and for clients with no controller at
all, like a phone — the fallback is the one thing the server data can still
prove: a position extrapolated more than 15s past the end of the track is a
leftover entry, not playback.

The liveness check costs one extra JSON-RPC per poll per controllable session,
on a 2s timeout so a sleeping Kodi cannot stall the widget. Measured poll time
with the check in place: 0.23s.

### The uncontrollable case is weaker, and that is genuinely not fixable here

A phone has no API to ask. What Navidrome actually does, observed over a 5-minute
capture of a `play:Sub` session on iOS:

```
 108s  state='playing'  minutesAgo=3  pos=189967  dur=192
 111s  state='playing'  minutesAgo=3  pos=192200  dur=192   <- capped at duration
 117s  (no entries)                                          <- server deletes it
 178s  state='playing'  minutesAgo=0  pos=2107    dur=248   <- next track: fresh report
```

Two behaviours combine badly:

1. **The client reports once, at track start.** `minutesAgo` climbed 1 → 3 and
   never reset. Pause and resume were never reported at all — `state` stayed
   `playing` throughout.
2. **Navidrome caps the extrapolated position at the track duration, then
   removes the entry.** The disappearance is the server's doing, not this
   plugin's.

So **resuming a paused track cannot bring the widget back**: once the entry is
gone, the fact that playback resumed exists only on the phone. The client never
tells the server, so the server cannot tell the widget. Skipping to the next
track works only because a new track triggers the client's one report.

The `position > duration + 15s` fallback below therefore almost never fires
against Navidrome, which caps position at exactly the duration. It is retained
as a guard for servers that extrapolate without capping, not as the mechanism
that makes this work.

Tightening this by treating a rising `minutesAgo` as "stopped" was considered and
rejected: Subsonic clients differ wildly in how often they re-report, some only
at track start, and a widget that hides while music is still playing is a worse
failure than a row that lingers briefly after it stops.

### What `minutesAgo` is not

It looks like the age of the last client report. It is not — it is the age of the
*entry*, a plain minute counter from when Navidrome created it.

Measured over 81 samples across four minutes, it went `0 → 1 → 2 → 3 → 4`,
incrementing every 60s and never once resetting — including straight through a
resume where `positionMs` dropped from 84403 to 1900. Early on it appears to
track `floor(positionMs / 60000)`, but that is coincidence: these clients report
at track start, so entry age and playback position advance together until
something disturbs one of them.

There is no field in this API that separates an extrapolated position from a
measured one. So `confirmed` means one thing only: the client was asked and said
yes. A session with no controller is never confirmed, and its row says why the
displayed state may be wrong rather than only why its buttons are dead.

### Client behaviour differs, and it is worth knowing which you have

| | `play:Sub` (iOS) | Amperfy (iOS) | Kodi |
|---|---|---|---|
| Reports at track start | yes | yes | yes |
| Re-reports mid-track | no | no | n/a — asked directly |
| Reports on resume | **no** | **yes** | n/a |
| Pause visible to the server | no | no | yes |

The resume column is the one that bites: with `play:Sub`, once the entry is gone
it cannot come back until you skip to another track. Amperfy re-reports on
resume, though it does so with the position reset near zero, so the elapsed time
reads from the start of the track rather than from where you resumed.

## Opening the track in Navidrome

Clicking the title opens the album that contains it. Navidrome's web UI is
react-admin behind hash routing and has no per-song page, so the album view is
the closest thing to "show me this track":

```
<public_url or url>/app/#/album/<albumId>/show
```

The link is built against `public_url` when set, even while polling over the
LAN. A LAN link would simply fail to load from anywhere else, and a link is far
more likely than a poll to be followed from outside the house.

## Starring

The heart is Subsonic `star`/`unstar` — the same flag Navidrome's own web UI
shows and `getStarred2` reports, so a track favourited here appears everywhere
else. It is deliberately *not* the "Favourites playlist" approach used by the
cliamp hook: two divergent notions of favourite is worse than one.

**The heart is enabled even for sessions that cannot be controlled.** Starring
is server-side library metadata, not playback, so a track playing on a phone can
be favourited even though nothing can pause it.

### Knowing whether a track is already starred

`getNowPlaying` does not report starred state, so it takes a second call.
Subsonic omits the `starred` key entirely unless the item *is* starred — its
presence is the flag and its value is the timestamp, verified against a
known-starred track.

Calling `getSong` on every poll would double the widget's request rate for one
boolean, so results are cached per song id with a 30s TTL: fresh enough to
notice a track starred from the web UI, cheap enough to be a rounding error.
`star.py` writes the new value into that cache immediately, so the heart flips
on the next poll rather than waiting out a staleness window it just invalidated.

If the `getSong` lookup fails, the last known value is kept rather than
defaulting to unstarred — a hollow heart that silently unstars on click is worse
than one that briefly reads stale.

## Control actions

`backend.sh control <player> <action>` with `playpause`, `next`, `previous`, or
`stop`. For a Kodi controller that resolves to `Player.GetActivePlayers` for the
player id, then the matching JSON-RPC call.

The row shows the action in flight and surfaces failures inline rather than
optimistically redrawing — the poll is what confirms the new state.

## Out of scope

- Browsing or queueing music. cliamp already does that, and does it better.
- Local MPRIS playback. That is `omarchy.media`.
- Library management and scans.
