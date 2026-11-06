import QtQuick
import QtQuick.Window

// Keeps an item's top-left corner on whole screen pixels. Give the target a
// `transform: Translate { id: t }`, add `PixelSnap { target: item; shift: t }`
// as a child, and size the target with `px()` so its far edges land on
// pixels too.
//
// With fractional scaling (1.25x) layout positions fall between pixels and
// thin outlines smear across two. `outputScale` must be the monitor's real
// scale from the compositor: Qt renders at a rounded-up ratio (2 for 1.25)
// and Hyprland scales it down, so Screen.devicePixelRatio is the wrong grid.
Item {
  id: snap
  visible: false
  width: 0
  height: 0

  property Item target: parent
  property var shift: null
  property real outputScale: 0
  readonly property real grid: outputScale > 0 ? outputScale : (Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1)

  function px(v) { return Math.round(v * grid) / grid }

  function resnap() {
    if (!target || !shift || !target.visible || !snap.Window.window) return
    var p = target.mapToItem(null, 0, 0)
    var bx = p.x - shift.x
    var by = p.y - shift.y
    shift.x = Math.round(bx * grid) / grid - bx
    shift.y = Math.round(by * grid) / grid - by
  }

  // Re-snap once layout settles: after creation, moves, resizes, and when
  // the panel window changes size (it grows open and fits its content).
  Timer { id: settle; interval: 280; onTriggered: snap.resnap() }
  Component.onCompleted: settle.restart()
  onGridChanged: settle.restart()
  Connections {
    target: snap.target
    ignoreUnknownSignals: true
    function onXChanged() { settle.restart() }
    function onYChanged() { settle.restart() }
    function onWidthChanged() { settle.restart() }
    function onVisibleChanged() { settle.restart() }
  }
  Connections {
    target: snap.Window.window
    ignoreUnknownSignals: true
    function onWidthChanged() { settle.restart() }
    function onHeightChanged() { settle.restart() }
  }
}
