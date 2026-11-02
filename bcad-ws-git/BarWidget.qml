import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "kai.git-status"

  // Существующие свойства плагина
  property var repoRows: []
  property int dirtyCount: 0
  property int untrackedCount: 0
  property int missingCount: 0
  property int errorCount: 0
  property string statusSummary: ""
  property string statusError: ""
  property bool panelOpen: false
  property bool busy: false
  property string panelAction: "status"
  property string panelSummary: ""
  property string panelError: ""
  property var panelRows: []
  property bool vpnActive: false
  property string pendingAction: ""
  property string pendingArg: ""
  property bool vpnConfirmOpen: false
  property string vpnPhase: ""
  property string busyText: "Working…"
  readonly property bool opened: panelOpen

  // Подпись текущей вкладки / выполняемого действия для заголовка панели
  readonly property string headerState: {
    if (busy) {
      if (vpnPhase !== "") return "VPN…"
      if (branchProcess.running) return "Switching…"
      if (panelAction === "pull") return "Pulling…"
      if (panelAction === "push") return "Pushing…"
      if (panelAction === "fetch") return "Fetching…"
      if (panelAction === "status") return "Checking…"
      if (panelAction === "branches") return "Loading…"
      return "Working…"
    }
    if (panelAction === "branches") return "Branches"
    if (panelAction === "pull") return "Pull"
    if (panelAction === "push") return "Push"
    if (panelAction === "fetch") return "Fetch"
    if (panelAction === "status") return "Status"
    return ""
  }
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string icon: "\uf1d3"
  readonly property string vpnConnection: String(setting("vpnConnection", "FALT")).trim()
  readonly property string vpnMode: {
    var mode = String(setting("vpnMode", "auto")).trim().toLowerCase()
    return mode === "always" || mode === "never" ? mode : "auto"
  }
  readonly property string workspacePath: expandPath(String(setting("workspacePath", "~/BAS/bcad-ws")))
  readonly property string scriptPath: decodeURIComponent(String(Qt.resolvedUrl("workspace.py")).replace(/^file:\/\//, ""))
  readonly property string packagesPath: workspacePath + "/packages.json"
  readonly property bool showWidget: repoRows.length > 0 || statusError !== ""

  // Свойства для управления новым оверлеем веток
  property bool branchOverlayOpen: false
  property var selectedRepoData: null
  property string newBranchName: ""
  property string overlayMessage: ""
  property string overlayError: ""

  readonly property string barText: {
    if (root.vertical) return icon
      if (statusError !== "") return icon + " !"
        if (dirtyCount > 0) return icon + " " + dirtyCount + (untrackedCount > 0 ? "?" : "")
          if (untrackedCount > 0) return icon + " ?"
            if (missingCount > 0 || errorCount > 0) return icon + " !"
              return icon
  }
  readonly property string tooltip: buildTooltip()

  function expandPath(value) {
    if (value === "~") return home
      if (value.indexOf("~/") === 0) return home + value.substring(1)
        return value
  }

  function refresh() {
    if (statusProcess.running) return
      statusProcess.command = ["python3", root.scriptPath, "status", root.workspacePath]
      statusProcess.running = true
  }

  function open() { panelOpen = true }
  function close() {
    if (vpnConfirmOpen) vpnConfirmOpen = false
      panelOpen = false
      branchOverlayOpen = false
  }
  function togglePanel() { if (panelOpen) close(); else panelOpen = true }

  function actionLabel(action) {
    if (action === "pull") return "Pull"
      if (action === "push") return "Push"
        if (action === "fetch") return "Fetch"
          if (action === "status") return "Status"
            if (action === "branches") return "Branches"
              return action
  }

  function runAction(action, arg) {
    if (branchProcess.running || actionProcess.running || vpnCheckProcess.running || vpnUpProcess.running) return
      panelAction = action
      panelError = ""
      busy = true
      busyText = "Running " + actionLabel(action) + "…"
      actionProcess.command = ["python3", root.scriptPath, action, root.workspacePath].concat(arg ? [String(arg)] : [])
      actionProcess.running = true
  }

  function runFetch(dest) {
    overlayMessage = ""
    overlayError = ""
    requestNetworkAction("fetch", dest)
  }

  function switchBranch(dest, branch, create) {
    if (branchProcess.running || actionProcess.running || vpnCheckProcess.running || vpnUpProcess.running) return
      var name = String(branch || "").trim()
      if (name === "") {
        panelError = "Branch name is required"
        return
      }
      panelError = ""
      busy = true
      busyText = (create ? "Creating " : "Switching to ") + name + "…"
      branchProcess.command = ["python3", root.scriptPath, "switch-branch", root.workspacePath, dest, name, create ? "create" : "switch"]
      branchProcess.running = true
      branchOverlayOpen = false // Закрываем оверлей после запуска команды
  }

  function requestNetworkAction(action, arg) {
    if (branchProcess.running || actionProcess.running || vpnCheckProcess.running || vpnUpProcess.running) return
      if (vpnMode === "never" || vpnConnection === "") {
        runAction(action, arg)
        return
      }
      pendingAction = action
      pendingArg = String(arg || "")
      panelAction = action
      panelError = ""
      busy = true
      busyText = "Checking VPN " + vpnConnection + "…"
      // auto: сначала проверяем, что VPN-профиль вообще настроен на этой машине
      // (на работе FALT нет — тогда действуем напрямую). always: сразу проверяем активность.
      vpnPhase = vpnMode === "always" ? "precheck" : "profilecheck"
      vpnCheckProcess.command = vpnMode === "always"
        ? ["nmcli", "-t", "-f", "NAME", "connection", "show", "--active"]
        : ["nmcli", "-t", "-f", "NAME", "connection", "show"]
      vpnCheckProcess.running = true
  }

  function connectVpn() {
    if (vpnUpProcess.running) return
      vpnConfirmOpen = false
      panelError = ""
      busy = true
      busyText = "Connecting VPN " + vpnConnection + "…"
      vpnUpProcess.command = ["nmcli", "connection", "up", vpnConnection]
      vpnUpProcess.running = true
  }

  function cancelVpnConfirm() { vpnConfirmOpen = false; pendingAction = ""; pendingArg = ""; panelSummary = "Cancelled" }

  function applyStatus(data) {
    repoRows = Array.isArray(data.rows) ? data.rows : []
    dirtyCount = Number(data.dirtyCount) || 0
    untrackedCount = Number(data.untrackedCount) || 0
    missingCount = Number(data.missingCount) || 0
    errorCount = Number(data.errorCount) || 0
    statusSummary = String(data.summary || "")
    statusError = data.error ? String(data.error) : ""
    if (panelAction === "status" && panelRows.length > 0) {
      panelRows = repoRows
      panelSummary = statusSummary
      panelError = statusError
    }
  }

  function applyActionResult(data) {
    panelRows = Array.isArray(data.rows) ? data.rows : []
    panelSummary = String(data.summary || "")
    panelError = data.error ? String(data.error) : ""
    if (data.action === "status") applyStatus(data)
  }

  // Fetch внутри оверлея веток: обновляем список веток, оверлей не закрываем
  function applyFetchResult(data) {
    if (branchOverlayOpen && selectedRepoData) {
      if (data.error) overlayError = String(data.error)
        else overlayMessage = String(data.summary || "")
      var rows = Array.isArray(data.rows) ? data.rows : []
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].dest === selectedRepoData.dest) {
          selectedRepoData = rows[i]
          overlayBranchPicker.options = rows[i].branches || []
          overlayBranchPicker.value = rows[i].branch || ""
          break
        }
      }
    }
    refresh()
  }

  function parseOutput(text) {
    try { return JSON.parse(text) } catch (error) { return null }
  }

  function rowColor(state) {
    if (state === "clean" || state === "ok" || state === "untracked") return Color.accent
      if (state === "modified" || state === "mismatch" || state === "missing" || state === "error" || state === "failed") return Color.urgent
        return Color.foreground
  }

  function rowDetailColor(state) {
    if (state === "untracked" || state === "mismatch") return Color.muted
      return Color.urgent
  }

  function buildTooltip() {
    var lines = []
    if (statusError !== "") {
      lines.push("Workspace: " + statusError)
      lines.push(packagesPath)
      return lines.join("\n")
    }
    if (repoRows.length === 0) {
      lines.push("Workspace: no repositories")
      lines.push(packagesPath)
      return lines.join("\n")
    }
    lines.push("BCAD workspace" + (statusSummary !== "" ? " · " + statusSummary : ""))
    var problems = []
    for (var i = 0; i < repoRows.length; i++) {
      var row = repoRows[i]
      if (row.state === "clean" || row.state === "ok") continue
        problems.push(row.dest + ": " + (row.label || row.state || ""))
    }
    if (problems.length === 0) {
      lines.push("All clean")
    } else {
      for (var j = 0; j < problems.length; j++) lines.push(problems[j])
    }
    return lines.join("\n")
  }

  onPanelOpenChanged: {
    if (panelOpen) {
      runAction("status")
    } else if (vpnConfirmOpen) {
      vpnConfirmOpen = false
      pendingAction = ""
    }
  }

  visible: showWidget
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // IPC Handler
  IpcHandler {
    target: "kai.git-status"
    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function status(): void { root.runAction("status") }
    function branches(): void { root.runAction("branches") }
    function switchBranch(dest: string, branch: string, create: bool): void { root.switchBranch(dest, branch, create) }
    function pull(): void { root.requestNetworkAction("pull") }
    function push(): void { root.requestNetworkAction("push") }
    function fetch(dest: string): void { root.runFetch(dest) }
    function cancelVpn(): void { root.cancelVpnConfirm() }
    function confirmVpn(): void { root.connectVpn() }
    function state(): string {
      return JSON.stringify({
        action: root.panelAction,
        headerState: root.headerState,
        workspacePath: root.workspacePath,
        panelOpen: root.panelOpen,
        busy: root.busy,
        vpnMode: root.vpnMode,
        vpnConnection: root.vpnConnection,
        vpnActive: root.vpnActive,
        vpnConfirmOpen: root.vpnConfirmOpen,
        pendingAction: root.pendingAction,
        summary: root.panelSummary,
        error: root.panelError,
        rows: root.panelRows,
        dirtyCount: root.dirtyCount,
        untrackedCount: root.untrackedCount,
        statusSummary: root.statusSummary,
        tooltip: root.tooltip
      })
    }
  }

  // Процессы бэкенда
  Process {
    id: statusProcess
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.statusError = statusStderr.text.trim() || "workspace.py failed"
        return
      }
      var data = root.parseOutput(statusStdout.text)
      if (data) root.applyStatus(data)
        else root.statusError = "could not parse status output"
    }
  }

  Process {
    id: actionProcess
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.busy = false
      var wasFetch = root.panelAction === "fetch"
      if (exitCode !== 0) {
        var failMessage = actionStderr.text.trim() || "workspace.py failed"
        root.panelError = failMessage
        if (wasFetch) root.overlayError = failMessage
        return
      }
      var data = root.parseOutput(actionStdout.text)
      if (!data) {
        root.panelError = "could not parse action output"
        if (wasFetch) root.overlayError = "could not parse fetch output"
        return
      }
      root.applyActionResult(data)
      if (wasFetch) root.applyFetchResult(data)
    }
  }
  Process {
    id: branchProcess
    stdout: StdioCollector { id: branchStdout; waitForEnd: true }
    stderr: StdioCollector { id: branchStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode !== 0) {
        root.panelError = branchStderr.text.trim() || "workspace.py failed"
        return
      }
      var data = root.parseOutput(branchStdout.text)
      if (!data) {
        root.panelError = "could not parse switch-branch output"
        return
      }
      root.applyActionResult(data)
      if (!data.error) root.refresh()
    }
  }
  Process {
    id: vpnCheckProcess
    stdout: StdioCollector { id: vpnCheckStdout; waitForEnd: true }
    stderr: StdioCollector { id: vpnCheckStderr; waitForEnd: true }
    function nameListed(text, name) {
      var lines = String(text).split("\n")
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trim() === name) return true
      }
      return false
    }
    onExited: function(exitCode) {
      var phase = root.vpnPhase
      root.vpnPhase = ""

      if (phase === "profilecheck") {
        if (exitCode !== 0) {
          root.busy = false
          root.pendingAction = ""
          root.pendingArg = ""
          root.panelError = vpnCheckStderr.text.trim() || "could not read NetworkManager connections"
          return
        }
        if (!nameListed(vpnCheckStdout.text, root.vpnConnection)) {
          // Профиля VPN на этой машине нет (рабочий вариант) — запускаем действие напрямую
          var directAction = root.pendingAction
          var directArg = root.pendingArg
          root.pendingAction = ""
          root.pendingArg = ""
          root.busy = false
          root.runAction(directAction, directArg)
          return
        }
        root.vpnPhase = "precheck"
        root.busyText = "Checking VPN " + root.vpnConnection + "…"
        vpnCheckProcess.command = ["nmcli", "-t", "-f", "NAME", "connection", "show", "--active"]
        vpnCheckProcess.running = true
        return
      }

      var active = exitCode === 0 && nameListed(vpnCheckStdout.text, root.vpnConnection)
      root.vpnActive = active
      if (phase === "precheck" && exitCode !== 0) {
        root.busy = false
        root.pendingAction = ""
        root.pendingArg = ""
        root.panelError = vpnCheckStderr.text.trim() || "could not check VPN " + root.vpnConnection
        return
      }
      if (phase === "precheck" && !active) {
        root.busy = false
        if (root.panelOpen) root.vpnConfirmOpen = true
          else {
            root.pendingAction = ""
            root.pendingArg = ""
          }
            return
      }
      if (phase === "postcheck" && !active) {
        root.busy = false
        root.pendingAction = ""
        root.pendingArg = ""
        root.panelError = "VPN " + root.vpnConnection + " is not active"
        return
      }
      if (phase === "precheck" || phase === "postcheck") {
        var action = root.pendingAction
        var arg = root.pendingArg
        root.pendingAction = ""
        root.pendingArg = ""
        root.busy = false
        root.runAction(action, arg)
      }
    }
  }
  Process {
    id: vpnUpProcess
    stdout: StdioCollector { id: vpnUpStdout; waitForEnd: true }
    stderr: StdioCollector { id: vpnUpStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.busy = false
        root.pendingAction = ""
        root.pendingArg = ""
        root.panelError = vpnUpStderr.text.trim() || "could not connect VPN " + root.vpnConnection
        return
      }
      root.vpnPhase = "postcheck"
      root.busyText = "Waiting for VPN " + root.vpnConnection + "…"
      vpnCheckProcess.command = ["nmcli", "-t", "-f", "NAME", "connection", "show", "--active"]
      vpnCheckProcess.running = true
    }
  }
  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    tooltipText: root.tooltip
    active: root.dirtyCount > 0 || root.untrackedCount > 0 || root.missingCount > 0 || root.errorCount > 0 || root.statusError !== ""
    fontSize: Style.font.body
    onPressed: function(b) {
      if (b === Qt.RightButton) root.refresh()
        else root.togglePanel()
    }
  }
  KeyboardPanel {
    id: popup
    anchorItem: button       // Привязка к кнопке на панели
    owner: root
    bar: root.bar
    open: root.panelOpen     // Синхронизация состояния открытия

    contentWidth: popup.fittedContentWidth(Style.space(480))
    contentHeight: popup.fittedContentHeight(panelColumn.implicitHeight, Style.space(620))

    Column {
      id: panelColumn
      anchors.fill: parent
      spacing: Style.space(8)
      Row {
        width: parent.width
        spacing: Style.space(6)
        Text {
          width: parent.width - headerStateText.width - parent.spacing
          text: "BCAD workspace"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }
        Text {
          id: headerStateText
          anchors.verticalCenter: parent.verticalCenter
          width: implicitWidth // пустой текст даёт нулевую ширину без отдельной видимости
          text: root.headerState
          color: root.busy ? Color.accent : Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
      Text {
        width: parent.width
        text: root.workspacePath
        color: Qt.darker(Color.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }
      Row {
        width: parent.width
        spacing: Style.space(6)
        Button {
          text: "Status"
          bordered: true
          fontSize: Style.font.caption
          opacity: root.busy ? 0.5 : 1
          onClicked: if (!root.busy) root.runAction("status")
        }
        Button {
          text: "Branches"
          bordered: true
          fontSize: Style.font.caption
          opacity: root.busy ? 0.5 : 1
          onClicked: if (!root.busy) root.runAction("branches")
        }
        Button {
          text: "Pull"
          bordered: true
          fontSize: Style.font.caption
          opacity: root.busy ? 0.5 : 1
          onClicked: if (!root.busy) root.requestNetworkAction("pull")
        }
        Button {
          text: "Push"
          bordered: true
          fontSize: Style.font.caption
          opacity: root.busy ? 0.5 : 1
          onClicked: if (!root.busy) root.requestNetworkAction("push")
        }
      }
      Rectangle {
        width: parent.width
        height: 1
        color: Color.foreground
        opacity: 0.18
      }
      Text {
        width: parent.width
        visible: root.busy || root.panelError !== "" || root.panelSummary !== ""
        text: root.busy ? root.busyText : (root.panelError !== "" ? root.panelError : root.panelSummary)
        color: root.panelError !== "" ? Color.urgent : Qt.darker(Color.foreground, 1.35)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }
      Text {
        width: parent.width
        visible: root.panelRows.length === 0 && !root.busy && root.panelError === ""
        text: "Choose an action"
        color: Qt.darker(Color.foreground, 1.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
      }
      Flickable {
        width: parent.width
        height: root.panelRows.length === 0 ? 0 : Math.max(Style.space(28), Math.min(rowColumn.implicitHeight, Style.space(380)))
        visible: root.panelRows.length > 0
        contentWidth: width
        contentHeight: rowColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Column {
          id: rowColumn
          width: parent.width
          spacing: Style.space(3)
          Repeater {
            model: root.panelRows
            delegate: Column {
              id: repoRow
              required property var modelData
              width: rowColumn.width
              spacing: Style.space(3)
              // Элемент списка (кликабельный во вкладке Branches)
              MouseArea {
                width: parent.width
                height: Style.space(32)
                enabled: !root.busy
                Rectangle {
                  anchors.fill: parent
                  color: parent.pressed ? Util.alpha(Color.foreground, 0.1) : (parent.containsMouse ? Util.alpha(Color.foreground, 0.05) : "transparent")
                  radius: Style.cornerRadius
                }
                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  spacing: Style.space(6)
                  Text {
                    width: parent.width - stateLabel.width - parent.spacing
                    anchors.verticalCenter: parent.verticalCenter
                    // Во вкладке "branches" пишем "Репозиторий / ветка", иначе стандартный dest
                    text: modelData.dest
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: root.panelAction === "branches"
                    elide: Text.ElideRight
                  }
                  Text {
                    id: stateLabel
                    width: Math.min(implicitWidth, parent.width * 0.4)
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.label
                    color: root.rowColor(modelData.state)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                  }
                }
                onClicked: {
                  if (root.panelAction === "branches") {
                    root.selectedRepoData = modelData
                    root.newBranchName = ""
                    root.overlayMessage = ""
                    root.overlayError = ""

                    // Сначала принудительно выставляем значения для элементов управления в оверлее,
                    // чтобы Dropdown не залипал на старых данных
                    overlayBranchPicker.options = modelData.branches || []
                    overlayBranchPicker.value = modelData.branch || ""

                    root.branchOverlayOpen = true

                    Qt.callLater(function() {
                      overlayNewBranchField.forceActiveFocus();
                    });
                  }
                }
              }
              Text {
                width: parent.width
                visible: root.panelAction !== "branches" && modelData.detail !== undefined && modelData.detail !== ""
                text: modelData.detail
                color: root.rowDetailColor(modelData.state)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption * 0.9
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
              }
            }
          }
        }
      }
    }
    // Оверлей для управления ветками конкретного репозитория
    // Оверлей для управления ветками конкретного репозитория
    Rectangle {
      id: branchOverlay
      anchors.fill: parent
      visible: root.branchOverlayOpen
      color: Color.popups.background || "#242424"
      radius: Style.cornerRadius
      z: 5

      // Перехватываем фокус при открытии оверлея
      onVisibleChanged: {
          if (visible) {
              Qt.callLater(function() {
                  overlayNewBranchField.forceActiveFocus();
              });
          }
      }

      Column {
        anchors.fill: parent
        anchors.margins: Style.space(12)
        spacing: Style.space(10)

        Row {
          width: parent.width
          spacing: Style.space(6)

          Text {
            width: parent.width - closeOverlayButton.width - fetchBranchButton.width - (parent.spacing * 2)
            text: root.selectedRepoData ? "⚙ " + root.selectedRepoData.dest : "Branch management"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
          }

          // Кнопка Fetch в оверлее
          Button {
            id: fetchBranchButton
            text: root.busy && root.panelAction === "fetch" ? "⏳ Fetching…" : "🔄 Fetch"
            fontSize: Style.font.caption
            bordered: true
            enabled: !root.busy && root.selectedRepoData && root.selectedRepoData.state !== "missing"
            onClicked: {
              if (root.selectedRepoData) {
                root.runFetch(root.selectedRepoData.dest)
              }
            }
          }

          Button {
            id: closeOverlayButton
            text: "✕"
            fontSize: Style.font.caption
            onClicked: {
              root.branchOverlayOpen = false
              root.overlayMessage = ""
              root.overlayError = ""
            }
          }
        }

        // Индикатор недоступности переключения веток
        Text {
          width: parent.width
          visible: root.selectedRepoData && (!root.selectedRepoData.eligible || root.selectedRepoData.state === "missing")
          text: "Branch switch unavailable: " + (root.selectedRepoData ? (root.selectedRepoData.ineligibleReason || "Repository must be clean") : "")
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        // Сообщение о результате Fetch (оверлея перекрывает общий summary/error панели)
        Text {
          width: parent.width
          visible: root.overlayError !== "" || root.overlayMessage !== ""
          text: root.overlayError !== "" ? root.overlayError : root.overlayMessage
          color: root.overlayError !== "" ? Color.urgent : Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        // Элементы управления (активны, если переключение разрешено)
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.selectedRepoData && root.selectedRepoData.eligible && root.selectedRepoData.state !== "missing"

          Row {
            width: parent.width
            spacing: Style.space(6)

            Dropdown {
              id: overlayBranchPicker
              width: parent.width - overlaySwitchButton.width - parent.spacing
              options: root.selectedRepoData ? (root.selectedRepoData.branches || []) : []
              value: root.selectedRepoData ? root.selectedRepoData.branch : ""
              showLabel: false
              fontFamily: Style.font.family
            }

            Button {
              id: overlaySwitchButton
              text: "Switch"
              bordered: true
              fontSize: Style.font.caption
              enabled: overlayBranchPicker.value && overlayBranchPicker.value !== (root.selectedRepoData ? root.selectedRepoData.branch : "")
              onClicked: root.switchBranch(root.selectedRepoData.dest, overlayBranchPicker.value, false)
            }
          }

          Rectangle {
            width: parent.width
            height: 1
            color: Color.foreground
            opacity: 0.1
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: overlayNewBranchField
              width: parent.width - overlayCreateButton.width - parent.spacing
              placeholderText: "new branch name"
              font.pixelSize: Style.font.caption
              text: root.newBranchName

              // Включаем фокус на уровне движка QML
              activeFocusOnTab: true

              // Перехватываем клик мыши на самом глубоком уровне
              MouseArea {
                anchors.fill: parent
                propagateComposedEvents: false // Блокируем кражу фокуса родительскими элементами

                onPressed: (mouse) => {
                  overlayNewBranchField.forceActiveFocus();
                  mouse.accepted = false; // Передаем событие клика самому TextField, чтобы появился курсор
                }
              }

              onTextChanged: root.newBranchName = text
              onAccepted: if (text.trim() !== "") root.switchBranch(root.selectedRepoData.dest, text.trim(), true)
            }

            Button {
              id: overlayCreateButton
              text: "Create"
              bordered: true
              fontSize: Style.font.caption
              enabled: root.newBranchName.trim() !== ""
              onClicked: root.switchBranch(root.selectedRepoData.dest, root.newBranchName.trim(), true)
            }
          }
        }
      }
    }
    ConfirmDialog {
      id: vpnConfirm
      anchors.fill: parent
      z: 10
      opened: root.vpnConfirmOpen
      message: "VPN " + root.vpnConnection + " is off. Turn it on and continue with " + root.actionLabel(root.pendingAction) + "?"
      cancelText: "Cancel"
      confirmText: "Turn on"
      background: Color.popups.background
      foreground: Color.popups.text
        scrim: Util.alpha(Color.background, 0.7)
        selectedBackground: Util.alpha(Color.foreground, 0.08)
        selectedText: Color.accent
        fontFamily: Style.font.family
        cornerRadius: Style.cornerRadius
        onCanceled: root.cancelVpnConfirm()
        onConfirmed: root.connectVpn()
    }
  }
}
