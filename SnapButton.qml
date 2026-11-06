import QtQuick
import qs.Ui

// A Button whose edges land on whole screen pixels. See PixelSnap.qml.
Button {
  id: b
  property real outputScale: 0
  function px(v) { return snapper.px(v) }

  width: px(implicitWidth)
  height: px(implicitHeight)
  transform: Translate { id: shift }

  PixelSnap { id: snapper; target: b; shift: shift; outputScale: b.outputScale }
}
