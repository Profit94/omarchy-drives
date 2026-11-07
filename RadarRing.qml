import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons

// Used space as a small radar scope: an outer ring, a faint inner ring with
// four short crosshair stubs pointing in, all one screen pixel wide. The used share is a sweep
// that starts at twelve o'clock, fades in towards its leading edge, and ends
// on a crisp line and a blip, like the last contact on a scope. The
// percentage sits in the middle. While busy, the sweep circles.
//
// Lines are laid out on the monitor's real pixel grid (`outputScale`): size
// it with `fit()` so it is an odd number of pixels, and the centre, the
// stubs and the number all fall on the same middle pixel column and row.
// Ring radii are whole pixels from that centre, and the picture is mirror-symmetric both ways.
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
  // The centre is the middle of a pixel, so whole-pixel radii put a
  // 1-pixel stroke squarely on one ring of pixels.
  readonly property real rOut: outerPx * p
  readonly property real rIn: innerPx * p
  // The sweep fills the band between the rings, so the number stays clear.
  readonly property real rBand: rIn + p / 2
  readonly property real rEdge: rOut - p / 2

  readonly property real sweep: busy ? 110 : Math.max(0, Math.min(1, shown)) * 360
  readonly property real lead: -90 + sweep                  // leading edge, clockwise from 3 o'clock
  readonly property color ink: color

  // The nearest odd number of screen pixels at or below `v`, in layout units.
  function fit(v) { var n = Math.floor(v * grid); if (n % 2 === 0) n -= 1; return Math.max(1, n) / grid }

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

  // Crosshair stubs: two pixels each, from the inner ring towards the
  // centre, so they frame the number without crossing the sweep.
  Repeater {
    model: 4
    Rectangle {
      required property int index
      readonly property bool vertical: index % 2 === 0
      readonly property int mid: Math.floor(root.npx / 2)
      readonly property int len: 2
      color: root.trackColor
      width: (vertical ? 1 : len) * root.p
      height: (vertical ? len : 1) * root.p
      x: (vertical ? mid : index === 1 ? mid + root.innerPx - len : mid - root.innerPx + 1) * root.p
      y: (!vertical ? mid : index === 2 ? mid + root.innerPx - len : mid - root.innerPx + 1) * root.p
    }
  }

  // The sweep: a band from twelve o'clock to the leading edge, fading in
  // towards the edge, then the edge line and the blip.
  Item {
    id: sweepLayer
    anchors.fill: parent
    visible: root.busy || (root.mounted && root.sweep > 0.5)

    // The trail: 15-degree steps of afterglow. Each layer runs from its step
    // to the leading edge, so they overlap rather than meet (no seams) and
    // stack up brightest at the edge, about 45% there.
    readonly property int slices: Math.max(1, Math.ceil(root.sweep / 15))
    Repeater {
      model: sweepLayer.slices
      Shape {
        id: slice
        required property int index
        readonly property real a0: -90 + root.sweep * index / sweepLayer.slices
        readonly property real a1: root.lead
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          strokeColor: "transparent"
          fillColor: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 1 - Math.pow(0.55, 1 / sweepLayer.slices))
          startX: root.ux(slice.a0, root.rBand); startY: root.uy(slice.a0, root.rBand)
          PathLine { x: root.ux(slice.a0, root.rEdge); y: root.uy(slice.a0, root.rEdge) }
          PathAngleArc { centerX: root.c; centerY: root.c; radiusX: root.rEdge; radiusY: root.rEdge; startAngle: slice.a0; sweepAngle: slice.a1 - slice.a0; moveToStart: false }
          PathLine { x: root.ux(slice.a1, root.rBand); y: root.uy(slice.a1, root.rBand) }
          PathAngleArc { centerX: root.c; centerY: root.c; radiusX: root.rBand; radiusY: root.rBand; startAngle: slice.a1; sweepAngle: slice.a0 - slice.a1; moveToStart: false }
        }
      }
    }

    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

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
        PathLine { x: root.ux(root.lead, root.rEdge); y: root.uy(root.lead, root.rEdge) }
      }
    }

    // Blip: a 3-pixel dot where the edge meets the ring.
    Rectangle {
      width: 3 * root.p; height: width; radius: width / 2
      color: root.ink
      x: Math.round(root.ux(root.lead, root.rOut) * root.grid - 1.5) * root.p
      y: Math.round(root.uy(root.lead, root.rOut) * root.grid - 1.5) * root.p
    }

    // Busy: the sweep steps round 30 degrees at a time, 10 times a second,
    // instead of redrawing every frame. Easier on a laptop GPU.
    Timer {
      interval: 100
      repeat: true
      running: root.busy && root.visible && !Style.reduceMotion
      onTriggered: sweepLayer.rotation = (sweepLayer.rotation + 30) % 360
      onRunningChanged: if (!running) sweepLayer.rotation = 0
    }
  }

  SnapText {
    visible: root.showText
    // Centred on the middle pixel, not the box, then snapped.
    x: root.c - implicitWidth / 2
    y: root.c - implicitHeight / 2
    outputScale: root.outputScale
    text: root.busy ? "…" : root.mounted ? Commons.I18n.formatNumber(Math.round(root.value * 100), 0) + "%" : "—"
    color: root.textColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }
}
