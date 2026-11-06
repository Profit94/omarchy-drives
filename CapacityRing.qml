import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons

// A thin ring showing used space, with the percentage in the middle. While
// busy, a short arc circles instead.
Item {
  id: root

  property real value: 0
  property bool busy: false
  property bool mounted: true
  property color color: "white"
  property color trackColor: Qt.rgba(1, 1, 1, 0.15)
  property color hotColor: color
  property color textColor: color
  property string fontFamily: Style.font.family
  property real thickness: Style.space(3)
  property real outputScale: 0

  property real shown: value
  Behavior on shown { NumberAnimation { duration: Style.duration(280); easing.type: Easing.OutCubic } }

  readonly property real r: Math.min(width, height) / 2 - thickness / 2

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: "transparent"
      strokeColor: root.trackColor
      strokeWidth: root.thickness
      PathAngleArc { centerX: root.width / 2; centerY: root.height / 2; radiusX: root.r; radiusY: root.r; startAngle: 0; sweepAngle: 360 }
    }
  }

  Shape {
    id: arc
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    visible: root.busy || root.shown > 0

    ShapePath {
      fillColor: "transparent"
      strokeColor: root.shown > 0.9 && !root.busy ? root.hotColor : root.color
      strokeWidth: root.thickness
      capStyle: ShapePath.RoundCap
      PathAngleArc {
        centerX: root.width / 2; centerY: root.height / 2
        radiusX: root.r; radiusY: root.r
        startAngle: -90
        sweepAngle: root.busy ? 80 : Math.max(4, 360 * Math.min(1, root.shown))
      }
    }

    RotationAnimation on rotation {
      running: root.busy && !Style.reduceMotion
      loops: Animation.Infinite
      from: 0; to: 360
      duration: 1100
      onRunningChanged: if (!running) arc.rotation = 0
    }
  }

  SnapText {
    anchors.centerIn: parent
    outputScale: root.outputScale
    text: root.busy ? "…" : root.mounted ? Commons.I18n.formatNumber(Math.round(root.value * 100), 0) + "%" : "—"
    color: root.textColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }
}
