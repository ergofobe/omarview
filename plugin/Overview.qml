import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Mission Control. Window tiles use Hyprland's toplevel export while this
// overlay is open. A covered or hidden window only keeps drawing if told to
// render unfocused, and a later frame is only delivered when the monitor
// commits, so a one-pixel pulse keeps those copies moving. Closing the
// overlay stops both. A window with no frame yet keeps its icon and title.
Item {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool outputPulse: false
  property int selectedWorkspaceId: -1
  property int selectedWindowIndex: -1
  property string selectedAddress: ""
  // Wayland toplevel objects keyed by Hyprland address, for ScreencopyView.
  property var windowSources: ({})

  readonly property int side: Style.space(40)
  readonly property int cardGap: Style.spacing.xl
  readonly property int cardMin: Style.space(200)
  readonly property int cardMax: Style.space(440)
  readonly property int cardPad: Style.spacing.lg
  readonly property color background: Commons.Color.menu.background
  readonly property color foreground: Commons.Color.menu.text
  readonly property color border: Commons.Color.menu.border
  readonly property color selectedFill: Commons.Color.menu.selectedBackground
  readonly property color accent: Commons.Color.accent
  readonly property string fontFamily: Style.font.menuFamily

  readonly property int monitorCount: {
    var seen = ({})
    var count = 0
    for (var i = 0; i < cardModel.count; i++) {
      var name = String(cardModel.get(i).monitorName || "")
      if (seen[name]) continue
      seen[name] = true
      count += 1
    }
    return count
  }

  readonly property real cardWidth: {
    var n = Math.max(1, cardModel.count)
    var gaps = root.cardGap * Math.max(0, n - 1)
    var fit = (Math.max(root.cardMin, panel.width - root.side * 2) - gaps) / n
    return Math.max(root.cardMin, Math.min(root.cardMax, fit))
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  ListModel { id: cardModel }

  // Covered windows, and windows on another workspace, stop drawing unless
  // Hyprland keeps rendering them. The flag is cleared as soon as we close.
  function setPreviewRendering(turnOn) {
    var value = turnOn ? "1" : "0"
    var script = 'for _, w in ipairs(hl.get_windows()) do if w and w.address then hl.dispatch(hl.dsp.window.set_prop({ prop = "render_unfocused", value = "' + value + '", window = "address:" .. w.address })) end end'
    if (turnOn)
      script = 'if not _G.omarview_fps then _G.omarview_fps = hl.get_config("misc.render_unfocused_fps") end; hl.config({ ["misc.render_unfocused_fps"] = 30 }); ' + script
    else
      script = script + '; if _G.omarview_fps then hl.config({ ["misc.render_unfocused_fps"] = _G.omarview_fps }); _G.omarview_fps = nil end'
    Quickshell.execDetached(["hyprctl", "eval", script])
  }

  function open(payload) {
    root.selectedAddress = ""
    root.selectedWorkspaceId = -1
    root.selectedWindowIndex = -1
    Hyprland.refreshMonitors()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    root.setPreviewRendering(true)
    root.opened = true
    root.rebuild()
    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    root.opened = false
    root.setPreviewRendering(false)
  }

  Component.onDestruction: root.setPreviewRendering(false)

  function dismiss() {
    root.opened = false
    var id = (root.manifest && root.manifest.id) || "omarview"
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(id)
  }

  function numberAt(value, index) {
    if (!value) return 0
    if (index === 0) return Number(value.x !== undefined ? value.x : value[0]) || 0
    return Number(value.y !== undefined ? value.y : value[1]) || 0
  }

  function monitorBox(monitor) {
    var scale = Number(monitor.scale) || 1
    if (!(scale > 0)) scale = 1
    return {
      name: String(monitor.name || ""),
      x: Number(monitor.x) || 0,
      y: Number(monitor.y) || 0,
      width: (Number(monitor.width) || scale) / scale,
      height: (Number(monitor.height) || scale) / scale,
      scale: scale
    }
  }

  function collect() {
    var monitors = Hyprland.monitors.values
    var monByName = ({})
    for (var i = 0; i < monitors.length; i++) {
      var box = root.monitorBox(monitors[i])
      if (box.name) monByName[box.name] = box
    }

    var windowsByWorkspace = ({})
    var toplevels = Hyprland.toplevels.values
    for (var t = 0; t < toplevels.length; t++) {
      var top = toplevels[t]
      var workspace = top.workspace
      if (!workspace || !(workspace.id >= 1)) continue
      var ipc = top.lastIpcObject || ({})
      if (ipc.mapped === false || ipc.hidden === true) continue
      var width = root.numberAt(ipc.size, 0)
      var height = root.numberAt(ipc.size, 1)
      if (width < 1 || height < 1) continue
      var address = String(top.address || ipc.address || "")
      if (address && address.indexOf("0x") !== 0) address = "0x" + address
      var className = String(ipc["class"] || ipc.initialClass || "")
      var entry = className ? DesktopEntries.heuristicLookup(className) : null
      var iconName = entry && entry.icon ? String(entry.icon) : ""
      var icon = iconName ? Quickshell.iconPath(iconName, true) : ""
      var list = windowsByWorkspace[workspace.id] || []
      list.push({
        address: address,
        title: String(top.title || ipc.title || className || "Window"),
        icon: icon,
        x: root.numberAt(ipc.at, 0),
        y: root.numberAt(ipc.at, 1),
        w: width,
        h: height,
        floating: ipc.floating === true,
        focused: top.activated === true
      })
      windowsByWorkspace[workspace.id] = list
    }

    var cards = []
    var workspaces = Hyprland.workspaces.values
    for (var w = 0; w < workspaces.length; w++) {
      var space = workspaces[w]
      if (!space || !(space.id >= 1)) continue
      var monitorName = ""
      if (space.monitor && space.monitor.name) monitorName = String(space.monitor.name)
      else if (space.lastIpcObject && space.lastIpcObject.monitor)
        monitorName = String(space.lastIpcObject.monitor)
      var monitor = monByName[monitorName]
      if (!monitor) continue
      var wins = (windowsByWorkspace[space.id] || []).slice()
      var overflow = false
      for (var n = 0; n < wins.length; n++) {
        if (wins[n].w > monitor.width * 1.2 || wins[n].h > monitor.height * 1.2)
          overflow = true
      }
      var logicalWidth = overflow && monitor.scale !== 1 ? monitor.width * monitor.scale : monitor.width
      var logicalHeight = overflow && monitor.scale !== 1 ? monitor.height * monitor.scale : monitor.height
      wins.sort(function(a, b) {
        if (a.floating !== b.floating) return a.floating ? 1 : -1
        if (a.y !== b.y) return a.y - b.y
        return a.x - b.x
      })
      cards.push({
        workspaceId: space.id,
        label: String(space.name || space.id),
        monitorName: monitor.name,
        active: space.focused === true || space.active === true,
        logicalWidth: logicalWidth,
        logicalHeight: logicalHeight,
        originX: monitor.x,
        originY: monitor.y,
        windows: wins
      })
    }

    cards.sort(function(a, b) {
      if (a.originX !== b.originX) return a.originX - b.originX
      if (a.originY !== b.originY) return a.originY - b.originY
      return a.workspaceId - b.workspaceId
    })
    return cards
  }

  function windowsOf(index) {
    if (index < 0 || index >= cardModel.count) return []
    try { return JSON.parse(cardModel.get(index).windowsJson) || [] } catch (e) { return [] }
  }

  function workspaceIndex(id) {
    for (var i = 0; i < cardModel.count; i++) {
      if (Number(cardModel.get(i).workspaceId) === Number(id)) return i
    }
    return -1
  }

  function refreshSources() {
    var map = ({})
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var top = toplevels[i]
      if (!top || !top.wayland) continue
      var address = String(top.address || "")
      if (!address) continue
      if (address.indexOf("0x") !== 0) address = "0x" + address
      map[address] = top.wayland
    }
    root.windowSources = map
  }

  function rebuild() {
    root.refreshSources()
    var cards = root.collect()
    var keepAddress = root.selectedAddress
    var keepWorkspace = root.selectedWorkspaceId
    var keepWindow = root.selectedWindowIndex
    cardModel.clear()
    for (var i = 0; i < cards.length; i++) {
      var card = cards[i]
      cardModel.append({
        workspaceId: card.workspaceId,
        label: card.label,
        monitorName: card.monitorName,
        active: card.active,
        logicalWidth: card.logicalWidth,
        logicalHeight: card.logicalHeight,
        originX: card.originX,
        originY: card.originY,
        windowsJson: JSON.stringify(card.windows)
      })
    }
    root.selectedAddress = keepAddress
    root.selectedWorkspaceId = keepWorkspace
    root.selectedWindowIndex = keepWindow
    root.restoreSelection()
  }

  function pickInitial() {
    for (var i = 0; i < cardModel.count; i++) {
      var wins = root.windowsOf(i)
      for (var j = 0; j < wins.length; j++) {
        if (wins[j].focused) {
          root.selectedWorkspaceId = Number(cardModel.get(i).workspaceId)
          root.selectedWindowIndex = j
          root.selectedAddress = String(wins[j].address || "")
          Qt.callLater(root.ensureCardVisible)
          return
        }
      }
    }
    for (var k = 0; k < cardModel.count; k++) {
      if (cardModel.get(k).active) {
        root.selectWorkspace(k)
        return
      }
    }
    if (cardModel.count > 0) root.selectWorkspace(0)
  }

  function restoreSelection() {
    if (root.selectedAddress) {
      for (var i = 0; i < cardModel.count; i++) {
        var wins = root.windowsOf(i)
        for (var j = 0; j < wins.length; j++) {
          if (String(wins[j].address || "") === root.selectedAddress) {
            root.selectedWorkspaceId = Number(cardModel.get(i).workspaceId)
            root.selectedWindowIndex = j
            Qt.callLater(root.ensureCardVisible)
            return
          }
        }
      }
    }
    var index = root.workspaceIndex(root.selectedWorkspaceId)
    if (index >= 0) {
      root.selectWorkspace(index, root.selectedWindowIndex)
      return
    }
    root.pickInitial()
  }

  function selectWorkspace(index, windowIndex) {
    if (index < 0 || index >= cardModel.count) return
    var wins = root.windowsOf(index)
    root.selectedWorkspaceId = Number(cardModel.get(index).workspaceId)
    if (windowIndex === undefined || windowIndex === null) {
      windowIndex = wins.length > 0 ? 0 : -1
      for (var i = 0; i < wins.length; i++) {
        if (wins[i].focused) windowIndex = i
      }
    }
    if (windowIndex < 0 || windowIndex >= wins.length) {
      root.selectedWindowIndex = -1
      root.selectedAddress = ""
    } else {
      root.selectedWindowIndex = windowIndex
      root.selectedAddress = String(wins[windowIndex].address || "")
    }
    Qt.callLater(root.ensureCardVisible)
  }

  function moveWorkspace(delta) {
    if (cardModel.count === 0) return
    var index = root.workspaceIndex(root.selectedWorkspaceId)
    if (index < 0) index = 0
    else index = (index + delta + cardModel.count) % cardModel.count
    root.selectWorkspace(index)
  }

  function moveWindow(delta) {
    var index = root.workspaceIndex(root.selectedWorkspaceId)
    if (index < 0) {
      root.moveWorkspace(0)
      return
    }
    var wins = root.windowsOf(index)
    if (wins.length === 0) {
      root.moveWorkspace(delta)
      return
    }
    var current = root.selectedWindowIndex
    if (current < 0) current = delta > 0 ? 0 : wins.length - 1
    else current = (current + delta + wins.length) % wins.length
    root.selectedWindowIndex = current
    root.selectedAddress = String(wins[current].address || "")
  }

  function selectByLabel(label) {
    for (var i = 0; i < cardModel.count; i++) {
      if (String(cardModel.get(i).label) === String(label)) {
        root.selectWorkspace(i)
        return
      }
    }
  }

  function ensureCardVisible() {
    var index = root.workspaceIndex(root.selectedWorkspaceId)
    if (index < 0 || !scroller.visible) return
    var stride = root.cardWidth + root.cardGap
    var x = index * stride
    var left = scroller.contentX
    if (x < left) scroller.contentX = x
    else if (x + root.cardWidth > left + scroller.width)
      scroller.contentX = Math.max(0, x + root.cardWidth - scroller.width)
  }

  function place(win, originX, originY, logicalWidth, logicalHeight, stageWidth, stageHeight) {
    var x = logicalWidth > 0 ? (win.x - originX) / logicalWidth * stageWidth : 0
    var y = logicalHeight > 0 ? (win.y - originY) / logicalHeight * stageHeight : 0
    var w = logicalWidth > 0 ? win.w / logicalWidth * stageWidth : stageWidth
    var h = logicalHeight > 0 ? win.h / logicalHeight * stageHeight : stageHeight
    var minW = Math.min(stageWidth, Style.space(36))
    var minH = Math.min(stageHeight, Style.space(24))
    w = Math.max(minW, w)
    h = Math.max(minH, h)
    if (w > stageWidth) w = stageWidth
    if (h > stageHeight) h = stageHeight
    if (x < 0) x = 0
    if (y < 0) y = 0
    if (x + w > stageWidth) x = stageWidth - w
    if (y + h > stageHeight) y = stageHeight - h
    return { x: x, y: y, width: w, height: h }
  }

  function activateSelection() {
    var address = root.selectedAddress
    var workspaceId = root.selectedWorkspaceId
    var request = ""
    if (/^0x[0-9a-fA-F]+$/.test(address))
      request = "hl.dsp.focus({ window = \"address:" + address + "\" })"
    else if (workspaceId >= 1)
      request = "hl.dsp.focus({ workspace = \"" + workspaceId + "\" })"
    root.dismiss()
    if (!request) return
    focusTimer.request = request
    focusTimer.restart()
  }

  function isDismissKey(event) {
    return event.key === Qt.Key_Escape || event.key === Qt.Key_F3 || event.key === Qt.Key_LaunchA
  }

  Timer {
    id: focusTimer
    interval: 80
    repeat: false
    property string request: ""
    onTriggered: if (request) Hyprland.dispatch(request)
  }

  Timer {
    id: rebuildTimer
    interval: 40
    repeat: false
    onTriggered: if (root.opened) root.rebuild()
  }

  // Toplevel export delivers the next frame when the monitor commits. This
  // overlay would otherwise sit still and leave every tile on its first copy.
  Timer {
    interval: 66
    repeat: true
    running: root.opened
    onTriggered: root.outputPulse = !root.outputPulse
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!root.opened || !event) return
      var name = String(event.name || "")
      if (name === "openwindow" || name === "closewindow" || name === "movewindow"
          || name === "movewindowv2" || name === "windowtitle" || name === "windowtitlev2"
          || name === "workspace" || name === "focusedmon" || name === "changefloatingmode"
          || name === "fullscreen" || name === "createworkspace" || name === "destroyworkspace")
        rebuildTimer.restart()
      if (name === "openwindow") root.setPreviewRendering(true)
    }
  }

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "omarview"

    Rectangle {
      anchors.fill: parent
      color: Commons.Util.alpha(Commons.Color.background, 0.72)
    }

    Rectangle {
      width: 1
      height: 1
      color: root.outputPulse ? "#010101" : "#020202"
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (root.isDismissKey(event)) {
          root.dismiss()
          event.accepted = true
        } else if (event.key === Qt.Key_Left) {
          root.moveWorkspace(Commons.I18n.rightToLeft ? 1 : -1)
          event.accepted = true
        } else if (event.key === Qt.Key_Right) {
          root.moveWorkspace(Commons.I18n.rightToLeft ? -1 : 1)
          event.accepted = true
        } else if (event.key === Qt.Key_Up) {
          root.moveWindow(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Down) {
          root.moveWindow(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier)) {
          root.moveWindow(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Backtab || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
          root.moveWindow(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.activateSelection()
          event.accepted = true
        } else if (event.key === Qt.Key_Home) {
          root.selectWorkspace(0)
          event.accepted = true
        } else if (event.key === Qt.Key_End) {
          root.selectWorkspace(cardModel.count - 1)
          event.accepted = true
        } else if (event.text >= "1" && event.text <= "9" && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
          root.selectByLabel(event.text)
          event.accepted = true
        }
      }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      visible: root.opened && cardModel.count === 0
      textFormat: Text.PlainText
      text: strings.t("none")
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
    }

    Flickable {
      id: scroller
      visible: cardModel.count > 0
      width: Math.min(parent.width - root.side * 2, Math.max(1, row.implicitWidth))
      height: Math.min(parent.height - root.side * 2, Math.max(1, row.implicitHeight))
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      contentWidth: row.implicitWidth
      contentHeight: row.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.HorizontalFlick
      interactive: contentWidth > width

      Row {
        id: row
        spacing: root.cardGap

        Repeater {
          model: cardModel

          delegate: Item {
            id: slot
            required property int index
            required property int workspaceId
            required property string label
            required property string monitorName
            required property bool active
            required property real logicalWidth
            required property real logicalHeight
            required property real originX
            required property real originY
            required property string windowsJson

            readonly property bool selected: Number(workspaceId) === Number(root.selectedWorkspaceId)
            readonly property var windows: {
              try { return JSON.parse(windowsJson) || [] } catch (e) { return [] }
            }
            readonly property bool newMonitor: {
              if (index === 0 || root.monitorCount < 2) return false
              var previous = cardModel.get(index - 1)
              return previous && String(previous.monitorName) !== monitorName
            }
            readonly property real aspect: logicalWidth > 0 ? logicalHeight / logicalWidth : 0.65

            width: root.cardWidth + (newMonitor ? root.cardGap * 2 : 0)
            height: card.implicitHeight

            Rectangle {
              id: card
              anchors.right: parent.right
              anchors.top: parent.top
              width: root.cardWidth
              implicitHeight: column.implicitHeight + root.cardPad * 2
              height: implicitHeight
              radius: Style.cornerRadius
              color: root.background
              border.width: selected ? Math.max(2, Style.focusBorderWidth) : Math.max(1, Style.normalBorderWidth)
              border.color: selected ? root.accent : root.border

              MouseArea {
                anchors.fill: parent
                onClicked: {
                  root.selectWorkspace(slot.index, -1)
                  root.activateSelection()
                  keyCatcher.forceActiveFocus()
                }
              }

              Column {
                id: column
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: root.cardPad
                spacing: Style.spacing.sm

                Row {
                  width: parent.width
                  spacing: Style.spacing.sm

                  Rectangle {
                    width: slot.active ? Style.space(8) : 0
                    height: Style.space(8)
                    radius: width / 2
                    visible: slot.active
                    color: root.accent
                  }

                  Text {
                    width: Math.max(0, parent.width - (slot.active ? Style.space(8) + Style.spacing.sm : 0) - (root.monitorCount > 1 ? monitorLabel.implicitWidth + Style.spacing.sm : 0))
                    textFormat: Text.PlainText
                    text: slot.label
                    color: slot.selected ? root.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                    font.bold: slot.selected
                    elide: Text.ElideRight
                  }

                  Text {
                    id: monitorLabel
                    visible: root.monitorCount > 1
                    textFormat: Text.PlainText
                    text: slot.monitorName
                    color: root.foreground
                    opacity: 0.6
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Item {
                  id: stage
                  width: parent.width
                  height: Math.max(Style.space(80), width * slot.aspect)
                  clip: true

                  Repeater {
                    model: slot.windows

                    delegate: Rectangle {
                      id: win
                      required property int index
                      required property var modelData

                      readonly property var placed: root.place(modelData, slot.originX, slot.originY, slot.logicalWidth, slot.logicalHeight, stage.width, stage.height)
                      readonly property bool chosen: slot.selected && String(modelData.address || "") === root.selectedAddress

                      x: placed.x
                      y: placed.y
                      width: placed.width
                      height: placed.height
                      radius: Math.min(Style.cornerRadius, height / 3)
                      clip: true
                      color: chosen ? root.selectedFill : Commons.Util.alpha(root.foreground, 0.14)
                      border.width: chosen ? Math.max(2, Style.focusBorderWidth) : 1
                      border.color: chosen ? root.accent : Commons.Util.alpha(root.foreground, 0.35)

                      readonly property var source: {
                        var address = String(modelData.address || "")
                        var map = root.windowSources
                        return map && map[address] ? map[address] : null
                      }

                      ScreencopyView {
                        id: preview
                        anchors.fill: parent
                        anchors.margins: win.border.width
                        // Each paint asks for another frame. The source is cleared on
                        // close, which destroys the recording context.
                        captureSource: root.opened ? win.source : null
                        live: root.opened
                        visible: hasContent
                      }

                      Column {
                        anchors.centerIn: parent
                        width: Math.max(0, parent.width - Style.spacing.md * 2)
                        spacing: Style.spacing.xs
                        visible: !preview.hasContent && win.height >= Style.space(56)

                        Image {
                          anchors.horizontalCenter: parent.horizontalCenter
                          visible: String(win.modelData.icon || "") !== ""
                          source: visible ? String(win.modelData.icon) : ""
                          width: visible ? Style.space(28) : 0
                          height: width
                          fillMode: Image.PreserveAspectFit
                          asynchronous: true
                          sourceSize.width: Math.max(1, width * 2)
                          sourceSize.height: Math.max(1, height * 2)
                        }

                        Text {
                          width: parent.width
                          horizontalAlignment: Text.AlignHCenter
                          textFormat: Text.PlainText
                          text: String(win.modelData.title || "")
                          color: win.chosen ? Commons.Color.menu.selectedText : root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          elide: Text.ElideRight
                        }
                      }

                      Rectangle {
                        visible: preview.hasContent && win.height >= Style.space(28)
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: Style.space(20)
                        color: Commons.Util.alpha(root.background, 0.78)

                        Text {
                          anchors.fill: parent
                          anchors.leftMargin: Style.spacing.xs
                          anchors.rightMargin: Style.spacing.xs
                          verticalAlignment: Text.AlignVCenter
                          textFormat: Text.PlainText
                          text: String(win.modelData.title || "")
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                        }
                      }

                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onContainsMouseChanged: if (containsMouse) {
                          root.selectedWorkspaceId = slot.workspaceId
                          root.selectedWindowIndex = win.index
                          root.selectedAddress = String(win.modelData.address || "")
                        }
                        onClicked: {
                          root.selectedWorkspaceId = slot.workspaceId
                          root.selectedWindowIndex = win.index
                          root.selectedAddress = String(win.modelData.address || "")
                          root.activateSelection()
                          keyCatcher.forceActiveFocus()
                        }
                      }
                    }
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: slot.windows.length === 0
                    textFormat: Text.PlainText
                    text: strings.t("empty")
                    color: root.foreground
                    opacity: 0.55
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: slot.windows.length === 0
                    ? strings.t("empty")
                    : (slot.windows.length === 1
                        ? String(slot.windows[0].title || "")
                        : strings.tn("windows", slot.windows.length).arg(Commons.I18n.formatNumber(slot.windows.length)))
                  color: slot.selected ? root.accent : root.foreground
                  opacity: slot.selected ? 1 : 0.75
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }
            }
          }
        }
      }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.spacing.xl
      textFormat: Text.PlainText
      text: strings.t("hint")
      color: root.foreground
      opacity: 0.75
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    WheelHandler {
      onWheel: function(event) {
        var delta = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x
        if (delta > 0) root.moveWorkspace(Commons.I18n.rightToLeft ? 1 : -1)
        else if (delta < 0) root.moveWorkspace(Commons.I18n.rightToLeft ? -1 : 1)
        event.accepted = true
      }
    }
  }
}
