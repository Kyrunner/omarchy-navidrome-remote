// Bar button + popout. Presentation only: every value comes from NavidromeService.qml.
// Structure follows ky.seerr-requests / ky.jellyfin-nowplaying, the working
// references for Omarchy's bar-widget contract on this machine.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "ky.navidrome-remote"
  ipcTarget: "ky.navidrome-remote"
  manageIpc: false

  // ⛔ WITHOUT THESE THE WIDGET IS INVISIBLE. A Panel with no implicit size gets
  // allocated zero width by the bar: it loads, runs, logs nothing fatal, and
  // never appears. Nothing playing -> zero width; a FAULT keeps its width, so
  // broken and silent never look the same.
  implicitWidth: (nd.ok && nd.count === 0 && root.hideWhenIdle)
                 || (!nd.ok && !nd.faulted)
                 ? 0 : button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  // The `bar` object carries foreground/urgent/fontFamily but NOT background or
  // accent; reading those off it yields undefined, which QML paints black and
  // only reports as a runtime warning.
  readonly property color background: Color.bar.background
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool hideWhenIdle: (root.settings && root.settings.hideWhenIdle !== undefined)
                                       ? root.settings.hideWhenIdle : true

  // Polled position plus seconds elapsed since that poll. Reads `nd.tick` so the
  // binding re-evaluates every second; frozen while paused, and never allowed
  // past the duration (a track that ends between polls would otherwise run on).
  function livePos(s) {
    if (!s) return 0
    var p = Math.floor(s.position_ms / 1000) + (s.paused ? 0 : nd.tick)
    return (s.duration_sec > 0 && p > s.duration_sec) ? s.duration_sec : p
  }

  function fmtTime(sec) {
    if (sec < 0) sec = 0
    var m = Math.floor(sec / 60), x = Math.floor(sec % 60)
    return m + ":" + (x < 10 ? "0" : "") + x
  }

  NavidromeService {
    id: nd
    refreshIntervalSec: (root.settings && root.settings.refreshIntervalSec) ? root.settings.refreshIntervalSec : 5
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // iconComponent hides the glyph Text (BarIconButton.qml:32), so `text` stays
    // empty or both would count as content.
    text: ""
    iconComponent: Component {
      Item {
        anchors.fill: parent

        Image {
          anchors.fill: parent
          source: Qt.resolvedUrl("navidrome.svg")
          // Rasterise at 2x the slot: scaling the SVG at its intrinsic size
          // leaves it soft on a HiDPI bar.
          sourceSize.width: 64
          sourceSize.height: 64
          fillMode: Image.PreserveAspectFit
          smooth: true
          opacity: nd.faulted ? 0.55 : (nd.anyPlaying ? 1.0 : 0.6)
        }

        // Count when more than one device is going, "!" on a fault. A fault takes
        // the urgent colour AND its own glyph, so a dead server can never be read
        // as a quiet one.
        Rectangle {
          id: badge
          visible: nd.faulted || nd.count > 1
          anchors.right: parent.right
          anchors.top: parent.top
          height: Math.round(parent.height * 0.46)
          width: Math.max(height, badgeText.implicitWidth + Style.space(4))
          radius: height / 2
          color: nd.ok ? root.accent : root.urgent
          border.width: 1
          border.color: root.background

          Text {
            id: badgeText
            anchors.centerIn: parent
            text: nd.ok ? String(nd.count) : "!"
            color: root.background
            font.family: root.fontFamily
            font.pixelSize: Math.round(badge.height * 0.7)
            font.bold: true
          }
        }
      }
    }
    dimmed: nd.ok && !nd.anyPlaying
    tooltipText: "Navidrome: " + nd.barSummary
                 + (nd.endpoint === "public" ? " (remote)" : "")
                 + (nd.stale ? " (showing last known)" : "")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) nd.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "r" || t === "R") nd.refresh()
        // Space toggles the first controllable session — the common case is one
        // device, and reaching for the mouse to pause is the thing this widget
        // exists to avoid.
        if (t === " " && nd.count > 0 && nd.sessions[0].controllable)
          nd.control(nd.sessions[0].player, "playpause")
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true

        ColumnLayout {
          id: column
          width: parent.width
          spacing: Style.space(12)

          RowLayout {
            Layout.fillWidth: true
            Text {
              Layout.fillWidth: true
              text: "Navidrome"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            // Worth surfacing: on the public endpoint the poll is slower and
            // LAN-only clients cannot be controlled, so the UI should say where
            // it is talking rather than leave that a mystery.
            Text {
              visible: nd.endpoint === "public"
              text: "remote"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            Layout.fillWidth: true
            visible: nd.faulted
            text: "Not available — " + nd.error + (nd.stale ? " (showing last known)" : "")
            color: root.urgent
            font.family: root.fontFamily
            wrapMode: Text.WordWrap
          }

          Text {
            Layout.fillWidth: true
            visible: nd.faulted && nd.error === "not configured"
            text: "Create ~/.config/omarchy-navidrome/config.json with url, user and password."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            Layout.fillWidth: true
            visible: nd.ok && nd.count === 0
            text: "Nothing playing on any device."
            color: root.dim
            font.family: root.fontFamily
          }

          Text {
            Layout.fillWidth: true
            visible: nd.actionError !== ""
            text: "Command failed — " + nd.actionError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: nd.sessions
            delegate: ColumnLayout {
              required property var modelData
              Layout.fillWidth: true
              spacing: Style.space(6)

              readonly property bool busy: nd.busyKey.indexOf(modelData.player + "/") === 0

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(10)

                Image {
                  visible: !!modelData.cover
                  source: modelData.cover ? "file://" + modelData.cover : ""
                  Layout.alignment: Qt.AlignTop
                  Layout.preferredWidth: Style.space(64)
                  Layout.preferredHeight: Style.space(64)
                  sourceSize.width: Style.space(128)
                  fillMode: Image.PreserveAspectFit
                  smooth: true
                  asynchronous: true
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(2)

                  // Click the title to open the album in Navidrome. The URL is
                  // built by the backend against the PUBLIC address, so a click
                  // still works away from home where a LAN link would not load.
                  Text {
                    Layout.fillWidth: true
                    text: modelData.title
                    color: titleMouse.containsMouse && modelData.web_url ? root.accent : root.foreground
                    font.family: root.fontFamily
                    font.bold: true
                    font.underline: titleMouse.containsMouse && !!modelData.web_url
                    elide: Text.ElideRight

                    MouseArea {
                      id: titleMouse
                      anchors.fill: parent
                      hoverEnabled: !!modelData.web_url
                      enabled: !!modelData.web_url
                      cursorShape: modelData.web_url ? Qt.PointingHandCursor : Qt.ArrowCursor
                      onClicked: {
                        Qt.openUrlExternally(modelData.web_url)
                        root.close()   // opening a browser over the panel leaves it stranded
                      }
                    }
                  }
                  Text {
                    Layout.fillWidth: true
                    visible: !!modelData.artist
                    text: modelData.artist + (modelData.album ? " · " + modelData.album : "")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                  Text {
                    Layout.fillWidth: true
                    text: modelData.player + (modelData.paused ? " · paused" : "")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              // progress
              Rectangle {
                Layout.fillWidth: true
                height: Style.space(4)
                radius: height / 2
                color: Qt.darker(root.foreground, 3.0)
                Rectangle {
                  height: parent.height
                  radius: parent.radius
                  // Dimmed when the position is extrapolated rather than measured:
                  // a bar that looks identical whether or not anyone checked is a
                  // bar that quietly overstates what is known.
                  color: modelData.paused ? root.dim
                         : (modelData.confirmed ? root.accent : Qt.darker(root.accent, 1.7))
                  width: modelData.duration_sec > 0
                         ? parent.width * Math.min(1, root.livePos(modelData) / modelData.duration_sec)
                         : 0
                  // Match the 1 Hz tick so the bar creeps instead of stepping.
                  Behavior on width { NumberAnimation { duration: 900; easing.type: Easing.Linear } }
                }
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Text {
                  text: root.fmtTime(root.livePos(modelData)) + " / " + root.fmtTime(modelData.duration_sec)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Item { Layout.fillWidth: true }

                // Enabled even when the session cannot be controlled: starring
                // goes to the server, so a track playing on a phone can still be
                // favourited even though nothing can pause it.
                PanelActionButton {
                  iconText: modelData.starred ? "󰋑" : "󰋕"
                  tooltipText: modelData.starred ? "Remove from favourites" : "Add to favourites"
                  foreground: modelData.starred ? root.urgent : root.dim
                  hoverColor: root.urgent
                  enabled: !!modelData.song_id && nd.busyKey === ""
                  onClicked: nd.toggleStar(modelData.song_id, modelData.starred)
                }

                PanelActionButton {
                  iconText: "󰒮"
                  tooltipText: modelData.controllable ? "Previous" : modelData.control_error
                  foreground: modelData.controllable ? root.dim : Qt.darker(root.dim, 1.6)
                  hoverColor: root.accent
                  enabled: modelData.controllable && nd.busyKey === ""
                  onClicked: nd.control(modelData.player, "previous")
                }
                PanelActionButton {
                  iconText: modelData.paused ? "󰐊" : "󰏤"
                  tooltipText: modelData.controllable ? (modelData.paused ? "Play" : "Pause") : modelData.control_error
                  foreground: modelData.controllable ? root.foreground : Qt.darker(root.dim, 1.6)
                  hoverColor: root.accent
                  enabled: modelData.controllable && nd.busyKey === ""
                  onClicked: nd.control(modelData.player, "playpause")
                }
                PanelActionButton {
                  iconText: "󰒭"
                  tooltipText: modelData.controllable ? "Next" : modelData.control_error
                  foreground: modelData.controllable ? root.dim : Qt.darker(root.dim, 1.6)
                  hoverColor: root.accent
                  enabled: modelData.controllable && nd.busyKey === ""
                  onClicked: nd.control(modelData.player, "next")
                }
                PanelActionButton {
                  iconText: "󰓛"
                  tooltipText: modelData.controllable ? "Stop" : modelData.control_error
                  foreground: modelData.controllable ? root.dim : Qt.darker(root.dim, 1.6)
                  hoverColor: root.urgent
                  enabled: modelData.controllable && nd.busyKey === ""
                  onClicked: nd.control(modelData.player, "stop")
                }
              }

              // Why the buttons are dead, stated rather than left to be guessed.
              Text {
                Layout.fillWidth: true
                visible: !modelData.controllable
                text: modelData.control_error || ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Text {
                Layout.fillWidth: true
                visible: parent.busy
                text: "working…"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }
}
