import QtQuick
import qs.Ui

// A PanelActionButton (the card's icon buttons) whose edges land on whole
// screen pixels. See PixelSnap.qml.
PanelActionButton {
  id: b
  property real outputScale: 0

  width: snapper.px(implicitWidth)
  height: snapper.px(implicitHeight)
  transform: Translate { id: shift }

  PixelSnap { id: snapper; target: b; shift: shift; outputScale: b.outputScale }
}
