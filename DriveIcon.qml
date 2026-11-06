import QtQuick
import QtQuick.Shapes
import QtQuick.Window
import qs.Commons

// "Slab": an external drive seen slightly from above, the way a desktop
// shows a disk, reduced to strokes. A tinted top face sits on a slim front
// face that carries a usage line and a status light.
//   attach  the slab settles down onto the bar, a gloss sweeps its top face
//           once, the usage line draws in and the light comes on
//   busy    the status light blinks
//   eject   the slab lifts away upward and fades
Item {
  id: root

  property real iconSize: 16
  property color color: "white"
  property real fill: 0          // 0..1 used space
  property bool lit: true        // mounted
  property bool busy: false
  property int insertTick: 0
  property int ejectTick: 0

  readonly property real u: iconSize / 16

  // ------------------------------------------------------------ pixel grid
  // The bar scales icons and places them at fractional offsets, so the icon
  // measures where it really lands (scene = origin + local * k) and puts its
  // straight edges on whole screen pixels itself. `outputScale` is the
  // monitor's real scale (1.25 here); see PixelSnap.qml for why Qt's own
  // ratio is the wrong grid.
  property real outputScale: 0
  readonly property real grid: outputScale > 0 ? outputScale : 1
  property real ox: 0
  property real oy: 0
  property real k: 1
  readonly property real pxUnit: 1 / (k * grid)      // one screen pixel, in local units

  function measure() {
    if (!root.visible || !root.Window.window) return
    var a = root.mapToItem(null, 0, 0)
    var b = root.mapToItem(null, 64, 64)
    var nk = (b.x - a.x) / 64
    if (!(nk > 0)) return
    if (Math.abs(nk - k) > 1e-6) k = nk
    if (Math.abs(a.x - ox) > 1e-6) ox = a.x
    if (Math.abs(a.y - oy) > 1e-6) oy = a.y
  }
  function sx(v) { return (Math.round((ox + v * k) * grid) / grid - ox) / k }
  function sy(v) { return (Math.round((oy + v * k) * grid) / grid - oy) / k }
  function sl(v) { return Math.max(1, Math.round(v * k * grid)) * pxUnit }

  // Measure after layout settles, then keep an eye out for the bar shifting
  // this icon (another widget appearing beside it). Cheap: a few mappings,
  // and nothing redraws unless the position actually changed.
  Timer { id: settle; interval: 280; onTriggered: root.measure() }
  Timer { interval: 2000; repeat: true; running: root.visible; onTriggered: root.measure() }
  Component.onCompleted: settle.restart()
  onVisibleChanged: settle.restart()
  onGridChanged: settle.restart()
  onWidthChanged: settle.restart()
  Connections {
    target: root.Window.window
    ignoreUnknownSignals: true
    function onWidthChanged() { settle.restart() }
    function onHeightChanged() { settle.restart() }
  }

  property real shownFill: fill
  property real lift: 0          // vertical offset, + is down
  property real sheen: -1        // gloss position across the top face, 0..1; <0 hidden

  Behavior on shownFill { NumberAnimation { duration: Style.duration(360); easing.type: Easing.OutCubic } }

  implicitWidth: iconSize
  implicitHeight: iconSize
  clip: true

  // Fixed painted bounds, so the bar doesn't rescale the icon while it moves.
  Rectangle { anchors.fill: parent; color: "transparent" }

  onInsertTickChanged: { ejectAnim.stop(); insertAnim.restart() }
  onEjectTickChanged: { insertAnim.stop(); ejectAnim.restart() }

  // Layout in whole screen pixels. `m` is the design pixel: 1 screen pixel
  // in the bar (about 15 px tall), 2 at the eject list's larger size, so the
  // proportions hold at every size and every edge stays on the grid.
  readonly property int wpx: Math.max(8, Math.floor(iconSize / pxUnit))
  readonly property int hpx: Math.max(8, Math.floor(iconSize / pxUnit))
  readonly property int m: Math.max(1, Math.round(hpx / 13))
  function pp(n) { return n * pxUnit }
  readonly property real x0: sx(0)
  readonly property real y0: sy(0)

  readonly property real stroke: pp(m)
  // Heights in design pixels: top face 4, front face 7 (border, 5 inside, border).
  readonly property int topH: 4 * m
  readonly property int faceHpx: 7 * m
  readonly property real slabTop: y0 + pp(Math.floor((hpx - topH - faceHpx) / 2))

  // Front face box. Its border is drawn inside the box.
  readonly property real faceX: x0 + pp(m)
  readonly property real faceW: pp(wpx - 2 * m)
  readonly property real faceY: slabTop + pp(topH)
  readonly property real faceH: pp(faceHpx)

  // Top face: stroke is centred on the path, so its edges sit half a stroke
  // inside whole-pixel rows, and the front corners meet the face's border.
  readonly property real backL: x0 + pp(3 * m) + stroke / 2
  readonly property real backR: x0 + pp(wpx - 3 * m) - stroke / 2
  readonly property real backY: slabTop + stroke / 2
  readonly property real frontL: faceX + stroke / 2
  readonly property real frontR: faceX + faceW - stroke / 2
  readonly property real edgeY: faceY + stroke / 2
  readonly property real baseY: faceY + faceH

  Item {
    id: slab
    anchors.fill: parent
    transform: Translate { y: root.lift }

    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      // Top face: soft tint and outline.
      ShapePath {
        fillColor: Qt.rgba(root.color.r, root.color.g, root.color.b, 0.14)
        strokeColor: root.color
        strokeWidth: root.stroke
        joinStyle: ShapePath.RoundJoin
        startX: root.backL; startY: root.backY
        PathLine { x: root.backR; y: root.backY }
        PathLine { x: root.frontR; y: root.edgeY }
        PathLine { x: root.frontL; y: root.edgeY }
        PathLine { x: root.backL; y: root.backY }
      }

    }

    // Gloss: a soft slanted band moved by position only, so a sweep never
    // rebuilds the shape. Clipped to the top face's box.
    Item {
      x: root.backL - 1 * root.u
      y: root.backY + root.stroke / 2
      width: root.backR - root.backL + 2 * root.u
      height: root.edgeY - root.backY - root.stroke
      clip: true
      visible: root.sheen >= 0

      Rectangle {
        width: 2.4 * root.u
        height: parent.height * 2
        y: -parent.height / 2
        x: -width + root.sheen * (parent.width + width * 2)
        rotation: 28
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: "transparent" }
          GradientStop { position: 0.5; color: Qt.rgba(root.color.r, root.color.g, root.color.b, 0.8) }
          GradientStop { position: 1.0; color: "transparent" }
        }
      }
    }

    // Front face
    Rectangle {
      x: root.faceX
      y: root.faceY
      width: root.faceW
      height: root.faceH
      radius: 1.6 * root.u
      color: "transparent"
      border.width: root.stroke
      border.color: root.color
    }

    // Usage line on the front face
    // Middle row of the face. Inside the border: 1 pad, the line, a 2 gap,
    // the 3-wide light, 1 pad, all in design pixels.
    Item {
      x: root.faceX + root.pp(2 * root.m)
      y: root.faceY + root.pp(3 * root.m)
      width: root.pp(Math.max(root.m, root.wpx - 2 * root.m - 2 * root.m - 7 * root.m))
      height: root.pp(root.m)

      Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.color
        opacity: 0.25
      }
      Rectangle {
        height: parent.height
        width: Math.round(parent.width * Math.max(0, Math.min(1, root.shownFill)) / root.pxUnit) * root.pxUnit
        radius: height / 2
        color: root.color
        visible: width > 0.5
      }
    }

    // Status light
    Rectangle {
      id: led
      // 3x3 design pixels, centred on the face's middle row.
      width: root.pp(3 * root.m)
      height: width
      radius: width / 2
      x: root.faceX + root.faceW - root.pp(2 * root.m) - width
      y: root.faceY + root.pp(2 * root.m)
      color: root.color
      opacity: root.lit ? 1 : 0.25
    }
  }

  // Busy (ejecting): only the status light blinks, twice a second. Each
  // change redraws the bar, so this is 2 redraws a second instead of a
  // continuous animation.
  Timer {
    interval: 500
    repeat: true
    running: root.busy && !Style.reduceMotion
    onTriggered: led.opacity = led.opacity > 0.5 ? 0.15 : 1
    onRunningChanged: led.opacity = Qt.binding(function() { return root.lit ? 1 : 0.25 })
  }

  SequentialAnimation {
    id: insertAnim
    ScriptAction { script: { root.shownFill = 0; root.lift = -4 * root.u } }
    ParallelAnimation {
      NumberAnimation { target: slab; property: "opacity"; from: 0; to: 1; duration: Style.duration(180); easing.type: Easing.OutCubic }
      NumberAnimation { target: root; property: "lift"; to: 0; duration: Style.duration(280); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
    }
    ScriptAction { script: root.shownFill = Qt.binding(function() { return root.fill }) }
    NumberAnimation { target: root; property: "sheen"; from: 0; to: 1; duration: Style.duration(650); easing.type: Easing.OutCubic }
    ScriptAction { script: { if (!root.busy) root.sheen = -1; root.measure() } }
  }

  SequentialAnimation {
    id: ejectAnim
    ScriptAction { script: root.shownFill = 0 }
    ParallelAnimation {
      NumberAnimation { target: root; property: "lift"; to: -4 * root.u; duration: Style.duration(220); easing.type: Easing.OutCubic }
      NumberAnimation { target: slab; property: "opacity"; to: 0; duration: Style.duration(200); easing.type: Easing.OutCubic }
    }
    ScriptAction { script: root.lift = 0 }
  }
}
