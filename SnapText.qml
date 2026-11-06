import QtQuick

// Plain text whose top-left corner sits on a whole screen pixel, so glyphs
// rasterise the same everywhere instead of blurring at fractional positions.
// Plain text by default: card text comes from drive labels. See PixelSnap.qml.
Text {
  id: t
  property real outputScale: 0
  textFormat: Text.PlainText
  transform: Translate { id: shift }
  PixelSnap { target: t; shift: shift; outputScale: t.outputScale }
}
