import packages/docutils/highlite, strutils, terminal, os, strformat
import gapbuffer, editorview, ui, cursor, unicodeext, highlight

type Mode* = enum
  normal, insert, visual, replace, ex, filer, search, quit

type Registers* = object
  yankedLines*: seq[seq[Rune]]
  yankedStr*: seq[Rune]

type StatusBarSettings* = object
  useBar*: bool
  mode*: bool
  filename*: bool
  chanedMark*: bool
  line*: bool
  column*: bool
  characterEncoding*: bool
  language*: bool
  directory*: bool

type EditorSettings* = object
  statusBar*: StatusBarSettings
  lineNumber*: bool
  syntax*: bool
  autoCloseParen*: bool
  autoIndent*: bool 
  tabStop*: int
  characterEncoding*: CharacterEncoding # TODO: move to EditorStatus ...?
  defaultCursor*: CursorType
  normalModeCursor*: CursorType
  insertModeCursor*: CursorType

type EditorStatus* = object
  buffer*: GapBuffer[seq[Rune]]
  highlight*: Highlight
  language*: SourceLanguage
  searchHistory*: seq[seq[Rune]]
  view*: EditorView
  cursor*: CursorPosition
  registers*: Registers
  settings*: EditorSettings
  filename*: seq[Rune]
  openDir: seq[Rune]
  currentDir: seq[Rune]
  currentLine*: int
  currentColumn*: int
  expandedColumn*: int
  prevMode* : Mode
  mode* : Mode
  cmdLoop*: int
  countChange*: int
  debugMode: int
  mainWindow*: Window
  statusWindow*: Window
  commandWindow*: Window

proc initRegisters(): Registers =
  result.yankedLines = @[]
  result.yankedStr = @[]

proc initStatusBarSettings*(): StatusBarSettings =
  result.useBar = true
  result.mode = true
  result.filename = true
  result.chanedMark = true
  result.line = true
  result.column = true
  result.characterEncoding = true
  result.language = true
  result.directory = true

proc initEditorSettings*(): EditorSettings =
  result.statusBar = initStatusBarSettings()
  result.lineNumber = true
  result.syntax = true
  result.autoCloseParen = true
  result.autoIndent = true
  result.tabStop = 2
  result.defaultCursor = CursorType.blockMode   # Terminal default curosr shape
  result.normalModeCursor = CursorType.blockMode
  result.insertModeCursor = CursorType.ibeamMode

proc initEditorStatus*(): EditorStatus =
  result.currentDir = getCurrentDir().toRunes
  result.language = SourceLanguage.langNone
  result.registers = initRegisters()
  result.settings = initEditorSettings()
  result.mode = Mode.normal
  result.prevMode = Mode.normal

  let useStatusBar = if result.settings.statusBar.useBar: 1 else: 0
  result.mainWindow = initWindow(terminalHeight()-1, terminalWidth(), 0, 0)
  if result.settings.statusBar.useBar:
    result.statusWindow = initWindow(1, terminalWidth(), terminalHeight() - useStatusBar - 1, 0, ui.ColorPair.blackPink)
  result.commandWindow = initWindow(1, terminalWidth(), terminalHeight()-1, 0)

proc changeMode*(status: var EditorStatus, mode: Mode) =
  status.prevMode = status.mode
  status.mode = mode

proc executeOnExit*(settings: EditorSettings) =
  changeCursorType(settings.defaultCursor)

proc writeStatusBarNormalModeInfo(status: var EditorStatus) =
  status.statusWindow.append(ru" ", ui.ColorPair.blackPink)
  if status.settings.statusBar.filename: status.statusWindow.append(if status.filename.len > 0: status.filename else: ru"No name", ui.ColorPair.blackPink)
  if status.countChange > 0 and status.settings.statusBar.chanedMark: status.statusWindow.append(ru" [+]", ui.ColorPair.blackPink)

  let
    line = if status.settings.statusBar.line: fmt"{status.currentLine+1}/{status.buffer.len}" else: ""
    column = if status.settings.statusBar.column: fmt"{status.currentColumn + 1}/{status.buffer[status.currentLine].len}" else: ""
    encoding = if status.settings.statusBar.characterEncoding: $status.settings.characterEncoding else: ""
    language = if status.language == SourceLanguage.langNone: "Plain" else: sourceLanguageToStr[status.language]
    info = fmt"{line} {column} {encoding} {language} "
  status.statusWindow.write(0, terminalWidth()-info.len, info, ui.Colorpair.blackPink)

proc writeStatusBarFilerModeInfo(status: var EditorStatus) =
  if status.settings.statusBar.directory: status.statusWindow.append(ru" ", ui.ColorPair.blackPink)
  status.statusWindow.append(getCurrentDir().toRunes, ui.ColorPair.blackPink)

proc writeStatusBar*(status: var EditorStatus) =
  status.statusWindow.erase

  if status.mode == Mode.ex:
    if status.settings.statusBar.mode: status.statusWindow.write(0, 0, ru" EX ", ui.ColorPair.blackWhite)
    if status.prevMode == Mode.filer:
      writeStatusBarFilerModeInfo(status)
    else:
      writeStatusBarNormalModeInfo(status)
  elif status.mode == Mode.visual:
    if status.settings.statusBar.mode: status.statusWindow.write(0, 0, ru" VISUAL ", ui.ColorPair.blackWhite)
    writeStatusBarNormalModeInfo(status)
  elif status.mode == Mode.replace:
    if status.settings.statusBar.mode: status.statusWindow.write(0, 0, ru" REPLACE ", ui.ColorPair.blackWhite)
    writeStatusBarNormalModeInfo(status)
  elif status.mode == Mode.filer:
    if status.settings.statusBar.mode: status.statusWindow.write(0, 0, ru" FILER ", ui.ColorPair.blackWhite)
    writeStatusBarFilerModeInfo(status)
  else:
    if status.settings.statusBar.mode:
      status.statusWindow.write(0, 0,  if status.mode == Mode.normal: ru" NORMAL " else: ru" INSERT ", ui.ColorPair.blackWhite)
    writeStatusBarNormalModeInfo(status)

  status.statusWindow.refresh

proc resize*(status: var EditorStatus, height, width: int) =
  let
    adjustedHeight = max(height, 4)
    adjustedWidth = max(width, status.view.widthOfLineNum+4)
    useStatusBar = if status.settings.statusBar.useBar: 1 else: 0

  resize(status.mainWindow, adjustedHeight - useStatusBar - 1, adjustedWidth, 0, 0)
  if status.settings.statusBar.useBar: resize(status.statusWindow, 1, adjustedWidth, adjustedHeight-2, 0)
  resize(status.commandWindow, 1, adjustedWidth, adjustedHeight-1, 0)
  
  if status.mode != Mode.filer:
    status.view.resize(status.buffer, adjustedHeight - useStatusBar - 1, adjustedWidth-status.view.widthOfLineNum-1, status.view.widthOfLineNum)
    status.view.seekCursor(status.buffer, status.currentLine, status.currentColumn)

  if status.settings.statusBar.useBar: writeStatusBar(status)

proc erase*(status: var EditorStatus) =
  erase(status.mainWindow)
  erase(status.statusWindow)
  erase(status.commandWindow)

proc update*(status: var EditorStatus) =
  setCursor(false)
  if status.settings.statusBar.useBar: writeStatusBar(status)
  status.view.seekCursor(status.buffer, status.currentLine, status.currentColumn)
  status.view.update(status.mainWindow, status.settings.lineNumber, status.buffer, status.highlight, status.currentLine)
  status.cursor.update(status.view, status.currentLine, status.currentColumn)
  status.mainWindow.write(status.cursor.y, status.view.widthOfLineNum+status.cursor.x, "")
  status.mainWindow.refresh
  setCursor(true)

proc updateHighlight*(status: var EditorStatus)

from searchmode import searchAllOccurrence

proc updateHighlight*(status: var EditorStatus) =
  status.highlight = initHighlight($status.buffer, status.language)

  # highlight search results
  if status.searchHistory.len > 0:
    let keyword = status.searchHistory[^1]
    let allOccurrence = searchAllOccurrence(status.buffer, keyword)
    for pos in allOccurrence:
      let colorSegment = ColorSegment(firstRow: pos.line, firstColumn: pos.column, lastRow: pos.line, lastColumn: pos.column+keyword.high, color: defaultMagenta)
      status.highlight = status.highlight.overwrite(colorSegment)