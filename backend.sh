#!/usr/bin/env bash
# Navidrome "what is playing anywhere" -> one compact JSON line on stdout.
#
# The ONLY entry point into this plugin's network surface. Kept as scripts, not
# QML, so the whole thing can be run and diffed over SSH — the widget itself can
# only be checked by eye on the owner's screen.
#
#   backend.sh                          poll; print every active session
#   backend.sh control <player> <act>   playpause | next | previous | stop
#
#   {"ok":true,"endpoint":"lan","sessions":[{...}]}
#   {"ok":false,"error":"not configured","sessions":[]}   and a non-zero exit
#
# Config: ~/.config/omarchy-navidrome/config.json
#   {"url":"http://host:4533","public_url":"https://navidrome.example.com",
#    "user":"...","password":"...",
#    "controllers":[{"player":"KodiNavidrome","type":"kodi",
#                    "url":"http://host:8080","user":"...","password":"..."}]}
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${OMARCHY_NAVIDROME_CONFIG:-$HOME/.config/omarchy-navidrome/config.json}"

[ -r "$CFG" ] || { printf '{"ok":false,"error":"not configured","sessions":[]}\n'; exit 1; }

# Credentials are passed to the helpers through the config file path rather than
# argv, so they never appear in `ps` for every other user on the box.
export OMARCHY_NAVIDROME_CONFIG="$CFG"

case "${1:-poll}" in
  poll)
    exec python3 "$DIR/poll.py"
    ;;
  control)
    # Transport goes to the CLIENT: Subsonic has no pause endpoint.
    [ $# -eq 3 ] || { printf '{"ok":false,"error":"usage: control <player> <action>"}\n'; exit 1; }
    exec python3 "$DIR/control.py" "$2" "$3"
    ;;
  star|unstar)
    # Starring goes to the SERVER: it is library metadata, not playback, so it
    # works regardless of which client is playing and works from outside.
    [ $# -eq 2 ] || { printf '{"ok":false,"error":"usage: star|unstar <songId>"}\n'; exit 1; }
    exec python3 "$DIR/star.py" "$1" "$2"
    ;;
  *)
    printf '{"ok":false,"error":"unknown command","sessions":[]}\n'
    exit 1
    ;;
esac
