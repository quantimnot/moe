import packages/docutils/highlite, strutils, terminal, os, strformat, tables, times, osproc, heapqueue, math, deques
import gapbuffer, editorview, ui, unicodeext, highlight, independentutils, fileutils, undoredostack, window, color, workspace, statusbar, settings, bufferstatus, cursor

type Platform* = enum
  linux, wsl, mac, other

type Registers* = object
  yankedLines*: seq[seq[Rune]]
  yankedStr*: seq[Rune]

type EditorStatus* = object
  platform*: Platform
  bufStatus*: seq[BufferStatus]
  searchHistory*: seq[seq[Rune]]
  registers*: Registers
  settings*: EditorSettings
  workSpace*: seq[WorkSpace]
  currentWorkSpaceIndex*: int
  timeConfFileLastReloaded*: DateTime
  isSearchHighlight*: bool
  isReplaceTextHighlight*: bool
  currentDir: seq[Rune]
  messageLog*: seq[seq[Rune]]
  debugMode: int
  statusBar*: seq[StatusBar]
  commandWindow*: Window
  tabWindow*: Window
  popUpWindow*: Window
  workSpaceInfoWindow*: Window

proc initPlatform(): Platform =
  if defined linux:
    if execProcess("uname -r").contains("Microsoft"): result = Platform.wsl
    else: result = Platform.linux
  elif defined macosx: result = Platform.mac
  else: result = Platform.other

proc initRegisters(): Registers =
  result.yankedLines = @[]
  result.yankedStr = @[]

proc initStatusBar*(): StatusBar = result.window = initWindow(1, 1, 1, 1, EditorColorPair.defaultChar)

proc initEditorStatus*(): EditorStatus =
  result.platform = initPlatform()
  result.currentDir = getCurrentDir().toRunes
  result.registers = initRegisters()
  result.settings = initEditorSettings()

  if result.settings.workSpace.useBar: result.workSpaceInfoWindow = initWindow(1, terminalWidth(), 0, 0, EditorColorPair.defaultChar)
  var newWorkSpace = initWorkSpace()
  result.workSpace = @[newWorkSpace]

  if result.settings.tabLine.useTab: result.tabWindow = initWindow(1, terminalWidth(), 0, 0, EditorColorPair.defaultChar)

  if result.settings.statusBar.useBar: result.statusBar = @[initStatusBar()]

  result.commandWindow = initWindow(1, terminalWidth(), terminalHeight() - 1, 0, EditorColorPair.defaultChar)

proc changeCurrentBuffer*(status: var EditorStatus, bufferIndex: int) =
  if 0 <= bufferIndex and bufferIndex < status.bufStatus.len:
    status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.bufferIndex = bufferIndex

    status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.currentLine = 0
    status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.currentColumn = 0
    status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.expandedColumn = 0

proc bufferIndexInCurrentWindow*(status: Editorstatus): int = status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.bufferIndex

proc changeMode*(status: var EditorStatus, mode: Mode) =
  let currentBufferIndex = status.bufferIndexInCurrentWindow
  status.bufStatus[currentBufferIndex].prevMode = status.bufStatus[currentBufferIndex].mode
  status.bufStatus[currentBufferIndex].mode = mode

proc changeCurrentWin*(status:var EditorStatus, index: int) =
  if index < status.workSpace[status.currentWorkSpaceIndex].numOfMainWindow and index > 0:
    status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode = status.workSpace[status.currentWorkSpaceIndex].mainWindowNode.searchByWindowIndex(index)

proc executeOnExit(settings: EditorSettings) = changeCursorType(settings.defaultCursor)

proc exitEditor*(settings: EditorSettings) =
  executeOnExit(settings)
  exitUi()
  quit()

proc writeWorkSpaceInfoWindow(status: var Editorstatus) =
  status.workSpaceInfoWindow.erase
  let
    width = status.workSpaceInfoWindow.width
    workspaceInfoStr =  $(status.currentWorkSpaceIndex + 1) & "/" & $status.workspace.len
    textStartPosition = int(width / 2) - int(ceil(workspaceInfoStr.len / 2))
    buffer = " ".repeat(textStartPosition) & workspaceInfoStr & " ".repeat(width - int(width / 2) - int(workspaceInfoStr.len / 2))

  status.workSpaceInfoWindow.write(0, 0, buffer, EditorColorPair.statusBarNormalMode)
  status.workSpaceInfoWindow.refresh

proc writeTab(tabWin: var Window, start, tabWidth: int, filename: string, color: EditorColorPair) =
  let
    title = if filename == "": "New file" else: filename
    buffer = if filename.len < tabWidth: " " & title & " ".repeat(tabWidth - title.len) else: " " & (title).substr(0, tabWidth - 3) & "~"
  tabWin.write(0, start, buffer, color)

proc writeTabLine*(status: var EditorStatus) =
  let
    isAllBuffer = status.settings.tabLine.allbuffer
    defaultColor = EditorColorPair.tab
    currentTabColor = EditorColorPair.currentTab
    currentWindowBuffer = status.bufferIndexInCurrentWindow

  status.tabWindow.erase

  if isAllBuffer:
    ## Display all buffer
    for index, bufStatus in status.bufStatus:
      let
        color = if currentWindowBuffer == index: currentTabColor else: defaultColor
        currentMode = bufStatus.mode
        prevMode = bufStatus.prevMode
        filename = if (currentMode == Mode.filer) or (prevMode == Mode.filer and currentMode == Mode.ex): getCurrentDir() else: $bufStatus.filename
        tabWidth = status.bufStatus.len.calcTabWidth(terminalWidth())
      status.tabWindow.writeTab(index * tabWidth, tabWidth, filename, color)
  else:
    ## Displays only the buffer currently displayed in the window
    let allBufferIndex = status.workSpace[status.currentWorkSpaceIndex].mainWindowNode.getAllBufferIndex
    for index, bufIndex in allBufferIndex:
      let
        color = if currentWindowBuffer == bufIndex: currentTabColor else: defaultColor
        bufStatus = status.bufStatus[bufIndex]
        currentMode = bufStatus.mode
        prevMode = bufStatus.prevMode
        filename = if (currentMode == Mode.filer) or (prevMode == Mode.filer and currentMode == Mode.ex): getCurrentDir() else: $bufStatus.filename
        tabWidth = status.workSpace[status.currentWorkSpaceIndex].mainWindowNode.getAllBufferIndex.len.calcTabWidth(terminalWidth())
      status.tabWindow.writeTab(index * tabWidth, tabWidth, filename, color)

  status.tabWindow.refresh

proc resize*(status: var EditorStatus, height, width: int) =
  setCursor(false)

  let
    useTab = if status.settings.tabLine.useTab: 1 else: 0
    useStatusBar = if status.settings.statusBar.useBar: 1 else: 0
    useWorkSpaceBar = if status.settings.workSpace.useBar: 1 else: 0

  status.workSpace[status.currentWorkSpaceIndex].mainWindowNode.resize(useTab + useWorkSpaceBar, 0, height - useTab - useStatusBar - useWorkSpaceBar, width)

  const statusBarHeight = 1
  var
    statusBarIndex = 0
    queue = initHeapQueue[WindowNode]()
  for node in status.workSpace[status.currentWorkSpaceIndex].mainWindowNode.child: queue.push(node)
  while queue.len > 0:
    let queueLength = queue.len
    for i in  0 ..< queueLength:
      let node = queue.pop
      if node.window != nil:
        let
          bufIndex = node.bufferIndex
          widthOfLineNum = node.view.widthOfLineNum
          adjustedHeight = max(node.h - statusBarHeight, 4)
          adjustedWidth = max(node.w - widthOfLineNum - 1, 4)

        node.view.resize(status.bufStatus[bufIndex].buffer, adjustedHeight, adjustedWidth, widthOfLineNum)
        node.view.seekCursor(status.bufStatus[bufIndex].buffer, node.currentLine, node.currentColumn)

        ## Resize status bar window
        const height = 1
        let
          width = if node.x > 0 and node.parent.splitType == SplitType.vertical: node.w - 1 else: node.w
          y = node.y + adjustedHeight
          x = if node.x > 0 and node.parent.splitType == SplitType.vertical: node.x + 1 else: node.x
        status.statusBar[statusBarIndex].window.resize(height, width, y, x)
        status.statusBar[statusBarIndex].window.refresh

        ## Set bufStatus index
        status.statusBar[statusBarIndex].bufferIndex = bufIndex

        inc(statusBarIndex)

      if node.child.len > 0:
        for node in node.child: queue.push(node)

  ## Resize status bar window
  if status.settings.statusBar.useBar and not status.settings.statusBar.multipleStatusBar:
    const
      statusBarHeight = 1
      x = 0
    let 
      y = max(height, 4) - 2
    status.statusBar[0].window.resize(statusBarHeight, width, y, x)

  ## Resize work space info window
  if status.settings.workSpace.useBar:
    const
      workSpaceBarHeight = 1
      x = 0
      y = 0
    status.workSpaceInfoWindow.resize(workSpaceBarHeight, width, y, x)

  ## Resize tab line window
  if status.settings.tabLine.useTab:
    const
      tabLineHeight = 1
      x = 0
    let y = if status.settings.workSpace.useBar: 1 else: 0
    status.tabWindow.resize(tabLineHeight, width, y, x)

  ## Resize command window
  const
    commandWindowHeight = 1
    x = 0
  let y = max(height, 4) - 1
  status.commandWindow.resize(commandWindowHeight, width, y, x)
  status.commandWindow.refresh

  setCursor(true)

proc highlightPairOfParen(status: var Editorstatus)
proc highlightOtherUsesCurrentWord*(status: var Editorstatus)
proc highlightSelectedArea(status: var Editorstatus)
proc updateHighlight*(status: var EditorStatus, windowNode: var WindowNode)

proc updateStatusBar(status: var Editorstatus) =
  if not status.settings.statusBar.multipleStatusBar:
    status.bufStatus[status.statusBar[0].bufferIndex].writeStatusBar(status.statusBar[0], status.workspace[status.currentWorkSpaceIndex].currentMainWindowNode, status.settings)
  else:
    for i in 0 ..< status.statusBar.len:
      let
        bufferIndex = status.statusBar[i].bufferIndex
        windowNode = status.workspace[status.currentWorkSpaceIndex].mainWindowNode.searchByWindowIndex(status.statusBar[i].windowIndex)
      status.bufStatus[bufferIndex].writeStatusBar(status.statusBar[i], windowNode, status.settings)

proc initSyntaxHighlight(windowNode: var WindowNode, bufStatus: seq[BufferStatus], isSyntaxHighlight: bool) =
  var queue = initHeapQueue[WindowNode]()
  for node in windowNode.child: queue.push(node)
  while queue.len > 0:
    for i in  0 ..< queue.len:
      var node = queue.pop
      if node.window != nil:
        let bufStatus = bufStatus[node.bufferIndex]
        if (bufStatus.mode != Mode.filer) and not (bufStatus.mode == Mode.ex and bufStatus.prevMode == Mode.filer):
          let lang = if isSyntaxHighlight: bufStatus.language else: SourceLanguage.langNone
          node.highlight = ($bufStatus.buffer).initHighlight(lang)

      if node.child.len > 0:
        for node in node.child: queue.push(node)

proc updateLogViewer(status: var Editorstatus, bufferIndex: int) =
  status.bufStatus[bufferIndex].buffer = initGapBuffer(@[ru""])
  for i in 0 ..< status.messageLog.len: status.bufStatus[bufferIndex].buffer.insert(status.messageLog[i], i)

proc update*(status: var EditorStatus) =
  setCursor(false)

  if status.settings.workSpace.useBar: status.writeWorkSpaceInfoWindow

  if status.settings.tabLine.useTab: status.writeTabLine

  status.workspace[status.currentWorkSpaceIndex].mainWindowNode.initSyntaxHighlight(status.bufStatus, status.settings.syntax)

  var queue = initHeapQueue[WindowNode]()
  for node in status.workSpace[status.currentWorkSpaceIndex].mainWindowNode.child: queue.push(node)
  while queue.len > 0:
    for i in  0 ..< queue.len:
      var node = queue.pop
      if node.window != nil:
        let bufStatus = status.bufStatus[node.bufferIndex]

        let
          currentMode = bufStatus.mode
          prevMode = bufStatus.prevMode

        if bufStatus.buffer.high < node.currentLine: node.currentLine = bufStatus.buffer.high
        if currentMode != Mode.insert and  bufStatus.buffer[node.currentLine].len > 0 and bufStatus.buffer[node.currentLine].high < node.currentColumn:
          node.currentColumn = bufStatus.buffer[node.currentLine].high

        node.view.reload(bufStatus.buffer, min(node.view.originalLine[0], bufStatus.buffer.high))

        let
          isCurrentMainWin = if node.windowIndex == status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.windowIndex: true else: false
          isVisualMode = if (currentMode == Mode.visual) or (prevMode == Mode.visual and currentMode == Mode.ex): true else: false
          isVisualBlockMode = if (currentMode == Mode.visualBlock) or (prevMode == Mode.visualBlock and currentMode == Mode.ex): true else: false

        ## Update highlight
        ## TODO: Refactor and fix
        if (currentMode == logViewer) or (currentMode == ex and prevMode == logViewer):
          status.updateLogViewer(node.bufferIndex)
          status.updateHighlight(node)
        elif (currentMode != Mode.filer) and not (currentMode == Mode.ex and prevMode == Mode.filer):
          if isCurrentMainWin:
            if status.settings.highlightOtherUsesCurrentWord: status.highlightOtherUsesCurrentWord
            if isVisualMode or isVisualBlockMode: status.highlightSelectedArea
            if status.settings.highlightPairOfParen: status.highlightPairOfParen
          status.updateHighlight(node)

        let
          startSelectedLine = bufStatus.selectArea.startLine
          endSelectedLine = bufStatus.selectArea.endLine

        node.view.seekCursor(bufStatus.buffer, node.currentLine, node.currentColumn)
        node.view.update(node.window, status.settings.view, isCurrentMainWin, isVisualMode, bufStatus.buffer, node.highlight, node.currentLine, startSelectedLine, endSelectedLine)

        if isCurrentMainWin: node.cursor.update(node.view, node.currentLine, node.currentColumn)

        node.window.refresh

      if node.child.len > 0:
        for node in node.child: queue.push(node)

  var currentMainWindowNode = status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode
  let
    currentMode = status.bufStatus[currentMainWindowNode.bufferIndex].mode
    prevMode = status.bufStatus[currentMainWindowNode.bufferIndex].prevMode
  if (currentMode != Mode.filer) and not (currentMode == Mode.ex and prevMode == Mode.filer):
    currentMainWindowNode.window.moveCursor(currentMainWindowNode.cursor.y, currentMainWindowNode.view.widthOfLineNum + currentMainWindowNode.cursor.x)

  if status.settings.statusBar.useBar: status.updateStatusBar

  setCursor(true)

proc verticalSplitWindow*(status: var EditorStatus) =
  let 
    currentBufferIndex = status.bufferIndexInCurrentWindow
    buffer = status.bufStatus[currentBufferIndex].buffer
  status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode = status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.verticalSplit(buffer)
  inc(status.workSpace[status.currentWorkSpaceIndex].numOfMainWindow)

  var statusBar = initStatusBar()
  statusBar.windowIndex = status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.windowIndex
  status.statusBar.add(statusBar)

proc horizontalSplitWindow*(status: var Editorstatus) =
  let 
    currentBufferIndex = status.bufferIndexInCurrentWindow
    buffer = status.bufStatus[currentBufferIndex].buffer
  status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode = status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.horizontalSplit(buffer)
  inc(status.workSpace[status.currentWorkSpaceIndex].numOfMainWindow)

  var statusBar = initStatusBar()
  statusBar.windowIndex = status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.windowIndex
  status.statusBar.add(statusBar)

proc closeWindow*(status: var EditorStatus, node: WindowNode) =
  if status.workSpace[status.currentWorkSpaceIndex].numOfMainWindow == 1: exitEditor(status.settings)

  let deleteWindowIndex = node.windowIndex
  var parent = node.parent

  if parent.child.len == 1:
    if status.settings.statusBar.multipleStatusBar: status.statusBar.delete(status.statusBar.high)

    parent.parent.child.delete(parent.index)
    dec(status.workSpace[status.currentWorkSpaceIndex].numOfMainWindow)

    status.resize(terminalHeight(), terminalWidth())

    let newCurrentWinIndex = if deleteWindowIndex > status.workSpace[status.currentWorkSpaceIndex].numOfMainWindow - 1: status.workSpace[status.currentWorkSpaceIndex].numOfMainWindow - 1 else: deleteWindowIndex
    status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode = status.workSpace[status.currentWorkSpaceIndex].mainWindowNode.searchByWindowIndex(newCurrentWinIndex)
  else:
    if status.settings.statusBar.multipleStatusBar: status.statusBar.delete(status.statusBar.high)

    parent.child.delete(node.index)
    dec(status.workSpace[status.currentWorkSpaceIndex].numOfMainWindow)

    status.resize(terminalHeight(), terminalWidth())

    let newCurrentWinIndex = if deleteWindowIndex > status.workSpace[status.currentWorkSpaceIndex].numOfMainWindow - 1: status.workSpace[status.currentWorkSpaceIndex].numOfMainWindow - 1 else: deleteWindowIndex
    status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode = status.workSpace[status.currentWorkSpaceIndex].mainWindowNode.searchByWindowIndex(newCurrentWinIndex)

proc moveCurrentMainWindow*(status: var EditorStatus, index: int) =
  if index < 0 or status.workSpace[status.currentWorkSpaceIndex].numOfMainWindow <= index: return

  status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode = status.workSpace[status.currentWorkSpaceIndex].mainWindowNode.searchByWindowIndex(index)

proc moveNextWindow*(status: var EditorStatus) = status.moveCurrentMainWindow(status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.windowIndex + 1)

proc movePrevWindow*(status: var EditorStatus) = status.moveCurrentMainWindow(status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.windowIndex - 1)

proc writePopUpWindow*(status: var Editorstatus, x, y: var int, currentLine: int,  buffer: seq[seq[Rune]]) =
  # Pop up window size
  var maxBufferLen = 0
  for runes in buffer:
    if maxBufferLen < runes.len: maxBufferLen = runes.len
  let
    h = if buffer.len > terminalHeight() - 1: terminalHeight() - 1 else: buffer.len
    w = maxBufferLen + 2

  # Pop up window position
  if y == terminalHeight() - 1: y = y - h
  if w > terminalHeight() - x: x = terminalHeight() - w

  status.popUpWindow = initWindow(h, w, y, x, EditorColorPair.popUpWindow)

  let startLine = if currentLine == -1: 0 elif currentLine - h + 1 > 0: currentLine - h + 1 else: 0
  for i in 0 ..< h:
    if currentLine != -1 and i + startLine == currentLine: status.popUpWindow.write(i, 1, buffer[i + startLine], EditorColorPair.popUpWinCurrentLine)
    else: status.popUpWindow.write(i, 1, buffer[i + startLine], EditorColorPair.popUpWindow)

  status.popUpWindow.refresh

proc deletePopUpWindow*(status: var Editorstatus) =
  if status.popUpWindow != nil:
    status.popUpWindow.deleteWindow
    status.update

proc addNewBuffer*(status: var EditorStatus, filename: string)
from commandview import writeFileOpenError

proc addNewBuffer*(status: var EditorStatus, filename: string) =
  status.bufStatus.add(BufferStatus(filename: filename.toRunes, lastSaveTime: now()))
  let index = status.bufStatus.high

  if existsFile(filename) == false: status.bufStatus[index].buffer = newFile()
  else:
    try:
      let textAndEncoding = openFile(filename.toRunes)
      status.bufStatus[index].buffer = textAndEncoding.text.toGapBuffer
      status.settings.characterEncoding = textAndEncoding.encoding
    except IOError:
      status.commandWindow.writeFileOpenError(filename, status.messageLog)
      return

  if filename != "": status.bufStatus[index].language = detectLanguage(filename)

  status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.view = status.bufStatus[index].buffer.initEditorView(terminalHeight(), terminalWidth())

  status.changeCurrentBuffer(index)
  status.changeMode(Mode.normal)

proc deleteBuffer*(status: var Editorstatus, deleteIndex: int) =
  let beforeWindowIndex = status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.windowIndex

  var queue = initHeapQueue[WindowNode]()
  for node in status.workSpace[status.currentWorkSpaceIndex].mainWindowNode.child: queue.push(node)
  while queue.len > 0:
    for i in 0 ..< queue.len:
      let node = queue.pop
      if node.bufferIndex == deleteIndex: status.closeWindow(node)

      if node.child.len > 0:
        for node in node.child: queue.push(node)

  status.resize(terminalHeight(), terminalWidth())

  status.bufStatus.delete(deleteIndex)

  queue = initHeapQueue[WindowNode]()
  for node in status.workSpace[status.currentWorkSpaceIndex].mainWindowNode.child: queue.push(node)
  while queue.len > 0:
    for i in 0 ..< queue.len:
      var node = queue.pop
      if node.bufferIndex > deleteIndex: dec(node.bufferIndex)

      if node.child.len > 0:
        for node in node.child: queue.push(node)

  let afterWindowIndex = if beforeWindowIndex > status.workSpace[status.currentWorkSpaceIndex].numOfMainWindow - 1: status.workSpace[status.currentWorkSpaceIndex].numOfMainWindow - 1 else: beforeWindowIndex
  status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode = status.workSpace[status.currentWorkSpaceIndex].mainWindowNode.searchByWindowIndex(afterWindowIndex)

proc createWrokSpace*(status: var Editorstatus) =
  var newWorkSpace = initWorkSpace()
  status.workSpace.insert(newWorkSpace, status.currentWorkSpaceIndex + 1)
  status.currentWorkSpaceIndex += 1
  status.addNewBuffer("")
  status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.bufferIndex = status.bufStatus.high

proc deleteWorkSpace*(status: var Editorstatus, index: int) =
  if 0 < index and index <= status.workSpace.len:
    status.workspace.delete(index)

    if status.workspace.len == 0: status.settings.exitEditor

    if status.currentWorkSpaceIndex > status.workSpace.high: status.currentWorkSpaceIndex = status.workSpace.high

proc changeCurrentWorkSpace*(status: var Editorstatus, index: int) =
  if 0 < index and index <= status.workSpace.len: status.currentWorkSpaceIndex = index - 1

proc tryRecordCurrentPosition*(bufStatus: var BufferStatus, windowNode: WindowNode) =
  bufStatus.positionRecord[bufStatus.buffer.lastSuitId] = (windowNode.currentLine, windowNode.currentColumn, windowNode.expandedColumn)

proc revertPosition*(bufStatus: var BufferStatus, windowNode: WindowNode, id: int) =
  doAssert(bufStatus.positionRecord.contains(id), fmt"The id not recorded was requested. [bufStatus.positionRecord = {bufStatus.positionRecord}, id = {id}]")

  windowNode.currentLine = bufStatus.positionRecord[id].line
  windowNode.currentColumn = bufStatus.positionRecord[id].column
  windowNode.expandedColumn = bufStatus.positionRecord[id].expandedColumn

proc eventLoopTask*(status: var Editorstatus)

proc initSelectedAreaColorSegment(startLine, startColumn: int): ColorSegment =
  result.firstRow = startLine
  result.firstColumn = startColumn
  result.lastRow = startLine
  result.lastColumn = startColumn
  result.color = EditorColorPair.visualMode

proc overwriteColorSegmentBlock[T](highlight: var Highlight, area: SelectArea, buffer: T) =
  var
    startLine = area.startLine
    endLine = area.endLine
  if startLine > endLine: swap(startLine, endLine)

  for i in startLine .. endLine:
    let colorSegment = ColorSegment(firstRow: i, firstColumn: area.startColumn, lastRow: i, lastColumn: min(area.endColumn, buffer[i].high), color: EditorColorPair.visualMode)
    highlight = highlight.overwrite(colorSegment)

proc highlightSelectedArea(status: var Editorstatus) =
  let
    currentBufferIndex = status.bufferIndexInCurrentWindow
    area = status.bufStatus[currentBufferIndex].selectArea
    windowNode = status.workspace[status.currentWorkSpaceIndex].currentMainWindowNode

  var colorSegment = initSelectedAreaColorSegment(windowNode.currentLine, windowNode.currentColumn)

  if area.startLine == area.endLine:
    colorSegment.firstRow = area.startLine
    colorSegment.lastRow = area.endLine
    if area.startColumn < area.endColumn:
      colorSegment.firstColumn = area.startColumn
      colorSegment.lastColumn = area.endColumn
    else:
      colorSegment.firstColumn = area.endColumn
      colorSegment.lastColumn = area.startColumn
  elif area.startLine < area.endLine:
    colorSegment.firstRow = area.startLine
    colorSegment.lastRow = area.endLine
    colorSegment.firstColumn = area.startColumn
    colorSegment.lastColumn = area.endColumn
  else:
    colorSegment.firstRow = area.endLine
    colorSegment.lastRow = area.startLine
    colorSegment.firstColumn = area.endColumn
    colorSegment.lastColumn = area.startColumn

  let
    currentMode = status.bufStatus[currentBufferIndex].mode
    prevMode = status.bufStatus[currentBufferIndex].prevMode

  if (currentMode == Mode.visual) or (currentMode == Mode.ex and prevMode == Mode.visual):
    status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.highlight = status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.highlight.overwrite(colorSegment)
  elif (currentMode == Mode.visualBlock) or (currentMode == Mode.ex and prevMode == Mode.visualBlock):
    status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.highlight.overwriteColorSegmentBlock(status.bufStatus[currentBufferIndex].selectArea, status.bufStatus[currentBufferIndex].buffer)

proc highlightPairOfParen(status: var Editorstatus) =
  let
    currentBufferIndex = status.bufferIndexInCurrentWindow
    buffer = status.bufStatus[currentBufferIndex].buffer
    windowNode = status.workspace[status.currentWorkSpaceIndex].currentMainWindowNode
    currentLine = windowNode.currentLine
    currentColumn = if windowNode.currentColumn > buffer[currentLine].high: buffer[currentLine].high else: windowNode.currentColumn

  if buffer[currentLine].len < 1 or (buffer[currentLine][currentColumn] == ru'"') or (buffer[currentLine][currentColumn] == ru'\''): return

  if isOpenParen(buffer[currentLine][currentColumn]):
    var depth = 0
    let
      openParen = buffer[currentLine][currentColumn]
      closeParen = correspondingCloseParen(openParen)
    for i in currentLine ..< buffer.len:
      let startColumn = if i == currentLine: currentColumn else: 0
      for j in startColumn ..< buffer[i].len:
        if buffer[i][j] == openParen: inc(depth)
        elif buffer[i][j] == closeParen: dec(depth)
        if depth == 0:
          let colorSegment = ColorSegment(firstRow: i, firstColumn: j, lastRow: i, lastColumn: j, color: EditorColorPair.parenText)
          status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.highlight = status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.highlight.overwrite(colorSegment)
          return
  elif isCloseParen(buffer[currentLine][currentColumn]):
    var depth = 0
    let
      closeParen = buffer[currentLine][currentColumn]
      openParen = correspondingOpenParen(closeParen)
    for i in countdown(currentLine, 0):
      let startColumn = if i == currentLine: currentColumn else: buffer[i].high
      for j in countdown(startColumn, 0):
        if buffer[i].len < 1: break
        if buffer[i][j] == closeParen: inc(depth)
        elif buffer[i][j] == openParen: dec(depth)
        if depth == 0:
          let colorSegment = ColorSegment(firstRow: i, firstColumn: j, lastRow: i, lastColumn: j, color: EditorColorPair.parenText)
          status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.highlight = status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.highlight.overwrite(colorSegment)
          return

# Highlighting other uses of the current word under the cursor
proc highlightOtherUsesCurrentWord*(status: var Editorstatus) =
  let
    currentBufferIndex = status.bufferIndexInCurrentWindow
    bufStatus = status.bufStatus[currentBufferIndex]
    windowNode = status.workspace[status.currentWorkSpaceIndex].currentMainWindowNode
    line = bufStatus.buffer[windowNode.currentLine]

  if line.len < 1 or windowNode.currentColumn > line.high or (line[windowNode.currentColumn] != '_' and unicodeext.isPunct(line[windowNode.currentColumn])) or line[windowNode.currentColumn].isSpace: return
  var
    startCol = windowNode.currentColumn
    endCol = windowNode.currentColumn

  # Set start col
  for i in countdown(windowNode.currentColumn - 1, 0):
    if (line[i] != '_' and unicodeext.isPunct(line[i])) or line[i].isSpace: break
    else: startCol.dec

  # Set end col
  for i in windowNode.currentColumn ..< line.len:
    if (line[i] != '_' and unicodeext.isPunct(line[i])) or line[i].isSpace: break
    else: endCol.inc

  let highlightWord = line[startCol ..< endCol]

  let
    range = status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.view.rangeOfOriginalLineInView
    startLine = range[0]
    endLine = if bufStatus.buffer.len > range[1] + 1: range[1] + 2 elif bufStatus.buffer.len > range[1]: range[1] + 1 else: range[1]

  for i in startLine ..< endLine:
    let line = bufStatus.buffer[i]
    for j in 0 .. (line.len - highlightWord.len):
      let endCol = j + highlightWord.len
      if line[j ..< endCol] == highlightWord:
        if j == 0 or (j > 0 and ((line[j - 1] != '_' and unicodeext.isPunct(line[j - 1])) or line[j - 1].isSpace)):
          if (j == (line.len - highlightWord.len)) or ((line[j + highlightWord.len] != '_' and unicodeext.isPunct(line[j + highlightWord.len])) or line[j + highlightWord.len].isSpace):
            # Set color
            let
              originalColorPair = status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.highlight.getColorPair(i, j)
              theme = status.settings.editorColorTheme
              colors = theme.getColorFromEditorColorPair(originalColorPair)
            setColorPair(EditorColorPair.currentWord, colors[0], ColorThemeTable[theme].currentWordBg)

            let colorSegment = ColorSegment(firstRow: i, firstColumn: j, lastRow: i, lastColumn: j + highlightWord.high, color: EditorColorPair.currentWord)
            status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.highlight = status.workSpace[status.currentWorkSpaceIndex].currentMainWindowNode.highlight.overwrite(colorSegment)

from searchmode import searchAllOccurrence
proc updateHighlight*(status: var EditorStatus, windowNode: var WindowNode) =
  let bufStatus = status.bufStatus[windowNode.bufferIndex]
  if (bufStatus.mode == Mode.filer) or (bufStatus.mode == Mode.ex and bufStatus.prevMode == Mode.filer): return

  let
    range = windowNode.view.rangeOfOriginalLineInView
    startLine = range[0]
    endLine = if bufStatus.buffer.len > range[1] + 1: range[1] + 2 elif bufStatus.buffer.len > range[1]: range[1] + 1 else: range[1]
  var bufferInView = initGapBuffer[seq[Rune]]()
  for i in startLine ..< endLine: bufferInView.add(bufStatus.buffer[i])

  # highlight full width space
  if status.settings.highlightFullWidthSpace:
    const fullWidthSpace = ru"　"
    let
      allOccurrence = bufferInView.searchAllOccurrence(fullWidthSpace)
      color = EditorColorPair.highlightFullWidthSpace
    for pos in allOccurrence:
      let colorSegment = ColorSegment(firstRow: range[0] + pos.line, firstColumn: pos.column, lastRow: range[0] + pos.line, lastColumn: pos.column, color: color)
      windowNode.highlight = windowNode.highlight.overwrite(colorSegment)

  # highlight search results
  if status.bufStatus[windowNode.bufferIndex].isHighlight and status.searchHistory.len > 0:
    let
      keyword = status.searchHistory[^1]
      allOccurrence = searchAllOccurrence(bufferInView, keyword)
      color = if status.isSearchHighlight: EditorColorPair.searchResult else: EditorColorPair.replaceText
    for pos in allOccurrence:
      let colorSegment = ColorSegment(firstRow: range[0] + pos.line, firstColumn: pos.column, lastRow: range[0] + pos.line, lastColumn: pos.column + keyword.high, color: color)
      windowNode.highlight = windowNode.highlight.overwrite(colorSegment)

proc changeTheme*(status: var EditorStatus) = setCursesColor(ColorThemeTable[status.settings.editorColorTheme])

from commandview import writeMessageAutoSave
proc autoSave(status: var Editorstatus) =
  let interval = status.settings.autoSaveInterval.minutes
  for index, bufStatus in status.bufStatus:
    if bufStatus.filename != ru"" and now() > bufStatus.lastSaveTime + interval:
      saveFile(bufStatus.filename, bufStatus.buffer.toRunes, status.settings.characterEncoding)
      status.commandWindow.writeMessageAutoSave(bufStatus.filename, status.messageLog)
      status.bufStatus[index].lastSaveTime = now()

from settings import loadSettingFile
proc eventLoopTask(status: var Editorstatus) =
  if status.settings.autoSave: status.autoSave
  if status.settings.liveReloadOfConf and status.timeConfFileLastReloaded + 1.seconds < now():
    let beforeTheme = status.settings.editorColorTheme
    status.settings.loadSettingFile
    status.timeConfFileLastReloaded = now()
    if beforeTheme != status.settings.editorColorTheme:
      changeTheme(status)
      status.resize(terminalHeight(), terminalWidth())
