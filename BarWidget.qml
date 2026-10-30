import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar button for OmaRaptor Player. Left-click plays the copied video link, right-click opens
// an empty player that asks for a link, middle-click closes every player. The first click
// installs the player from this plugin folder (plugin/run), so nothing else is needed.
BarWidget {
  id: root
  moduleName: "io.github.karpage.omaraptor"

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string runner: pluginDir + "/plugin/run"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function run(action) { Quickshell.execDetached([runner, action]) }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf03d"
    slotSize: Style.bar.iconSlot
    activeColor: Color.accent
    tooltipText: "OmaRaptor Player · click: play copied link · right-click: new · middle: close all"
    onPressed: function(code) {
      if (code === Qt.LeftButton) root.run("play")
      else if (code === Qt.RightButton) root.run("new")
      else if (code === Qt.MiddleButton) root.run("close")
    }
  }
}
