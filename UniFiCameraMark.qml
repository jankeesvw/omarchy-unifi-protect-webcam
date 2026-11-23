import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons

// The plugin's own mark: a video camera with a U cut out of its body.
//
// Drawn on a 24x24 grid with every straight edge on an even coordinate, so the
// stems of the U land on whole pixels at the bar's 12px and at twice that on a
// scaled display.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Commons.Color.foreground

  implicitWidth: iconSize
  implicitHeight: iconSize

  Item {
    anchors.centerIn: parent
    width: 24
    height: 24
    scale: root.iconSize / 24

    Shape {
      anchors.fill: parent
      antialiasing: true
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        fillColor: root.color
        strokeWidth: 0
        fillRule: ShapePath.OddEvenFill

        PathSvg {
          path: "M4 4h10a4 4 0 0 1 4 4v8a4 4 0 0 1-4 4H4a4 4 0 0 1-4-4V8a4 4 0 0 1 4-4zM4 8v3a5 5 0 0 0 10 0V8h-2v3a3 3 0 0 1-6 0V8zM20 10l4-3v10l-4-3z"
        }
      }
    }
  }
}
