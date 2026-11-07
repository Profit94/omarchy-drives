import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons

// Used space as a small radar scope: an outer ring, a faint inner ring and
// four cardinal ticks, all one screen pixel wide. The used share is a sweep
// that starts at twelve o'clock, fades in towards its leading edge, and ends
// on a crisp line and a blip, like the last contact on a scope. The
// percentage sits in the middle. While busy, the sweep circles.
//
// Lines are laid out on the monitor's real pixel grid (`outputScale`): the
// size is an odd number of pixels so the centre and the ticks fall on a
// whole pixel column and row, and ring radii sit half a pixel in so a
// 1-pixel stroke covers exactly one ring of pixels.
Item {
  id: root

  property real value: 0
  property bool busy: false
  property bool mounted: true
  property color color: "white"
  property color trackColor: Qt.rgba(1, 1, 1, 0.15)
  property color textColor: color
  property string fontFamily: Style.font.family
  property real outputScale: 0
  property bool showText: true

  property real shown: value
  Behavior on shown { NumberAnimation { duration: Style.duration(420); easing.type: Easing.OutCubic } }

  readonly property real grid: outputScale > 0 ? outputScale : 1
  readonly property real p: 1 / grid                       // one screen pixel
  readonly property int npx: { var n = Math.floor(Math.min(width, height) * grid); return n % 2 ? n : n - 1 }
  readonly property real c: (Math.floor(npx / 2) + 0.5) * p // centre of the middle pixel
  readonly property int outerPx: Math.floor(npx / 2)
  readonly property int innerPx: Math.round(outerPx * 0.58)
  readonly property real rOut: (outerPx - 0.5) * p
  readonly property real rIn: (innerPx - 0.5) * p
  // The sweep fills the band between the rings, so the number stays clear.
  readonly property real rBand: rIn + p

  readonly property real sweep: busy ? 110 : Math.max(0, Math.min(1, shown)) * 360
  readonly property real lead: -90 + sweep                  // leading edge, clockwise from 3 o'clock
  readonly property color ink: color

  function ux(a, r) { return c + r * Math.cos(a * Math.PI / 180) }
  function uy(a, r) { return c + r * Math.sin(a * Math.PI / 180) }

  // Rings and ticks never move.
  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: "transparent"
      strokeColor: root.trackColor
      strokeWidth: root.p
      PathAngleArc { centerX: root.c; centerY: root.c; radiusX: root.rOut; radiusY: root.rOut; startAngle: 0; sweepAngle: 360 }
    }
    ShapePath {
      fillColor: "transparent"
      strokeColor: Qt.rgba(root.trackColor.r, root.trackColor.g, root.trackColor.b, root.trackColor.a * 0.6)
      strokeWidth: root.p
      PathAngleArc { centerX: root.c; centerY: root.c; radiusX: root.rIn; radiusY: root.rIn; startAngle: 0; sweepAngle: 360 }
    }
  }

  // Cardinal ticks, as whole-pixel rectangles between the two rings.
  Repeater {
    model: 4
    Rectangle {
      required property int index
      readonly property bool vertical: index % 2 === 0
      readonly property int len: Math.max(1, root.outerPx - root.innerPx - 2)
      color: root.trackColor
      width: vertical ? root.p : len * root.p
      height: vertical ? len * root.p : root.p
      x: vertical ? Math.floor(root.npx / 2) * root.p
         : index === 1 ? (root.npx - 1 - len) * root.p : root.p
      y: !vertical ? Math.floor(root.npx / 2) * root.p
         : index === 2 ? (root.npx - 1 - len) * root.p : root.p
    }
  }

  // The sweep: a band from twelve o'clock to the leading edge, fading in
  // towards the edge, then the edge line and the blip.
  Item {
    id: sweepLayer
    anchors.fill: parent
    visible: root.busy || (root.mounted && root.sweep > 0.5)

    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeColor: "transparent"
        fillGradient: ConicalGradient {
          centerX: root.c; centerY: root.c
          // Conical angles run counter-clockwise from 3 o'clock, so the
          // gradient starts at the leading edge and fades back over the sweep.
          angle: -root.lead
          GradientStop { position: 0.0; color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.55) }
          GradientStop { position: Math.max(0.002, root.sweep / 360); color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.06) }
          GradientStop { position: 1.0; color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.06) }
        }
        startX: root.ux(-90, root.rBand); startY: root.uy(-90, root.rBand)
        PathLine { x: root.ux(-90, root.rOut); y: root.uy(-90, root.rOut) }
        PathAngleArc { centerX: root.c; centerY: root.c; radiusX: root.rOut; radiusY: root.rOut; startAngle: -90; sweepAngle: root.sweep; moveToStart: false }
        PathLine { x: root.ux(root.lead, root.rBand); y: root.uy(root.lead, root.rBand) }
        PathAngleArc { centerX: root.c; centerY: root.c; radiusX: root.rBand; radiusY: root.rBand; startAngle: root.lead; sweepAngle: -root.sweep; moveToStart: false }
      }

      // Used arc on the outer ring, one pixel, in full colour.
      ShapePath {
        fillColor: "transparent"
        strokeColor: root.ink
        strokeWidth: root.p
        PathAngleArc { centerX: root.c; centerY: root.c; radiusX: root.rOut; radiusY: root.rOut; startAngle: -90; sweepAngle: root.sweep }
      }

      // Leading edge.
      ShapePath {
        strokeColor: root.ink
        strokeWidth: root.p
        capStyle: ShapePath.FlatCap
        startX: root.ux(root.lead, root.rBand); startY: root.uy(root.lead, root.rBand)
        PathLine { x: root.ux(root.lead, root.rOut); y: root.uy(root.lead, root.rOut) }
      }
    }

    // Blip: a 3-pixel dot where the edge meets the ring.
    Rectangle {
      width: 3 * root.p; height: width; radius: width / 2
      color: root.ink
      x: Math.round(root.ux(root.lead, root.rOut) * root.grid - 1.5) * root.p
      y: Math.round(root.uy(root.lead, root.rOut) * root.grid - 1.5) * root.p
    }

    RotationAnimation on rotation {
      running: root.busy && !Style.reduceMotion
      loops: Animation.Infinite
      from: 0; to: 360
      duration: 1400
      onRunningChanged: if (!running) sweepLayer.rotation = 0
    }
  }

  SnapText {
    visible: root.showText
    anchors.centerIn: parent
    outputScale: root.outputScale
    text: root.busy ? "…" : root.mounted ? Commons.I18n.formatNumber(Math.round(root.value * 100), 0) + "%" : "—"
    color: root.textColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }
}
