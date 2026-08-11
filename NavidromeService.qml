// Owns the poll, the parsed state, and the transport commands.
// Knows nothing about how any of it is drawn.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: svc

  property int refreshIntervalSec: 5
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  // ---- state the panel reads ----
  property bool ok: false
  property string error: "starting"
  property string endpoint: ""        // "lan" | "public"
  property var sessions: []
  property bool stale: false

  // Seconds since the last authoritative poll. The panel adds this to a
  // session's position so the progress bar creeps every second instead of
  // jumping by refreshIntervalSec. The poll resets it, so drift can never
  // accumulate past one interval.
  property int tick: 0

  property string busyKey: ""         // "<player>/<action>" while in flight
  property string actionError: ""

  readonly property int count: sessions ? sessions.length : 0
  readonly property bool anyPlaying: {
    for (var i = 0; i < count; i++) if (!sessions[i].paused) return true
    return false
  }
  readonly property string barSummary: {
    if (!ok) return error
    if (count === 0) return "nothing playing"
    var s = sessions[0]
    var head = s.title + (s.artist ? " — " + s.artist : "")
    return count === 1 ? head : count + " devices playing"
  }

  Process {
    id: poll
    command: ["bash", svc.pluginDir + "/backend.sh"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = this.text ? this.text.trim() : ""
        if (raw === "") { svc.stale = svc.count > 0; svc.ok = false; svc.error = "no output"; return }
        try {
          var d = JSON.parse(raw)
          svc.ok = !!d.ok
          svc.error = d.error ? String(d.error) : ""
          if (d.ok) {
            svc.sessions = d.sessions || []
            svc.endpoint = d.endpoint || ""
            svc.stale = false
            svc.tick = 0
          } else {
            svc.stale = svc.count > 0
          }
        } catch (e) {
          svc.ok = false; svc.error = "unparseable"; svc.stale = svc.count > 0
        }
      }
    }
  }

  Process {
    id: action
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = this.text ? this.text.trim() : ""
        var good = false, msg = "failed"
        try { var d = JSON.parse(raw); good = !!d.ok; msg = d.error || "failed" } catch (e) {}
        svc.actionError = good ? "" : String(msg)
        svc.busyKey = ""
        // The client is the authority on what happened; re-poll rather than
        // guessing the new state locally.
        svc.refresh()
      }
    }
  }

  function refresh() { if (!poll.running) poll.running = true }

  function control(player, act) {
    if (action.running || busyKey !== "") return
    busyKey = player + "/" + act
    actionError = ""
    action.command = ["bash", pluginDir + "/backend.sh", "control", String(player), String(act)]
    action.running = true
  }

  // Starring is server-side library metadata, not playback, so it works for a
  // session that cannot be controlled at all -- you can favourite a track
  // playing on your phone even though nothing can pause it.
  function toggleStar(songId, currentlyStarred) {
    if (action.running || busyKey !== "" || !songId) return
    busyKey = songId + "/star"
    actionError = ""
    action.command = ["bash", pluginDir + "/backend.sh",
                      currentlyStarred ? "unstar" : "star", String(songId)]
    action.running = true
  }

  Timer {
    // On the public endpoint the poll backs off hard: 17k requests a day through
    // a rate-limited public edge is a good way to get your own IP banned.
    interval: (svc.endpoint === "public" ? Math.max(20, svc.refreshIntervalSec * 4)
                                         : Math.max(3, svc.refreshIntervalSec)) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: svc.refresh()
  }

  // 1 Hz clock for the live progress bar. Gated on something actually playing so
  // an idle server costs zero per-second wakeups on a laptop.
  Timer {
    interval: 1000
    running: svc.anyPlaying
    repeat: true
    onTriggered: svc.tick += 1
  }
}
