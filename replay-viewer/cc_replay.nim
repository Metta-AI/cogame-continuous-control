import
  std/json,
  cc/[broadcast, global, replay_runtime, replays, sim]

var
  runtimeLoaded = false
  replay: ReplayPlayer
  game: SimServer
  viewer: GlobalViewerState
  packet: seq[uint8]
  lastError: string
  leadSent = false

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the module's
## own globals instead of trapping. The bundle is therefore linked with
## `-s ABORTING_MALLOC=1` — allocation failure aborts the runtime loudly — and
## this FIXED buffer, stamped before each risky phase, stays readable from JS
## after the abort (aborting kills the call stack, not the linear memory), so
## the page can still report what the runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent(events: JsonNode) =
  let sendLead = not leadSent and replay.scanComplete
  let chrome = game.buildStateJson(
    events,
    playing = replay.playing,
    speed = replay.replaySpeed(),
    maxTick = replay.maxTick,
    looping = replay.looping,
    transportEnabled = true,
    mismatchTick = replay.mismatchTick(),
    startTick = replay.startTick,
    endHoldSeconds = replay.endHoldSecondsLeft(),
    skipLulls = replay.skipLulls,
    fastForwarding = replay.fastForwarding,
    lullSpans = (if sendLead: replay.lullSpans else: @[]),
    returnSeries = (if sendLead: replay.returnSeries else: @[]),
    beats = (if sendLead: replay.beats else: @[]),
    sendLead = sendLead)
  if sendLead:
    leadSent = true
  var nextViewer: GlobalViewerState
  packet = game.buildViewerPacket(viewer, nextViewer, chrome)
  viewer = nextViewer

proc ccLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "cc_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let replayData = parseReplayBytes(data.bytesFromPointer(int(length)))
    ## THE LOAD-TIME PRE-SCAN. It walks the recorded state keyframes and the
    ## per-turn orders — NOT a full re-simulation — to build the
    ## cumulative-return series, the stage boundary ticks, the beat ticks and
    ## the lull spans. Reading 32 keyframes and 42 orders is microseconds,
    ## which is what lets the progress sparkline and the scrubber beats draw at
    ## FULL WIDTH on the first frame instead of growing in; re-simulating
    ## 1 512 ticks x 120 solver passes at load would delay the first frame by
    ## seconds.
    stampStage("pre-scan replay")
    var initialized = initReplayRuntime(replayData)
    game = initialized.sim
    replay = initialized.player
    viewer = initGlobalViewerState()
    leadSent = false
    runtimeLoaded = true
    let mapNote = " (map " & $MapWidth & "x" & $MapHeight & ")"
    ## Refuse boards whose render buffers cannot fit the 32-bit address space
    ## BEFORE baking starts, so the page gets a clean diagnostic instead of an
    ## OOM abort. 1440 x 960 at k = 2 predicts ~122 MB against the 1.6 GB
    ## budget — 13x headroom.
    stampStage("check viewer capacity" & mapNote)
    let predicted = predictedViewerRenderBytes(MapWidth, MapHeight)
    if predicted > WasmViewerBudgetBytes:
      raise newException(CcError,
        "replay board is too large for the browser viewer" & mapNote &
        ": needs ~" & $(predicted div 1_048_576) &
        " MB of render buffers, beyond the wasm32 2 GB address space")
    frameStage = "advance replay" & mapNote
    stampStage("render first frame" & mapNote)
    renderCurrent(newJArray())
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc ccInput(data: ptr uint8, length: cint) {.exportc: "cc_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))

proc ccFrame(): cint {.exportc: "cc_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    let seekTicks =
      if viewer.replaySeekTick >= 0: @[viewer.replaySeekTick]
      else: newSeq[int]()
    let commands = viewer.replayCommands
    viewer.replaySeekTick = -1
    viewer.replayCommands.setLen(0)
    let events = replay.advanceReplayFrame(game, seekTicks, commands)
    renderCurrent(events)
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc ccPacketPointer(): ptr uint8 {.exportc: "cc_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: packet[0].addr

proc ccPacketLength(): cint {.exportc: "cc_packet_len", cdecl.} =
  cint(packet.len)

proc ccMismatchTick(): cint {.exportc: "cc_mismatch_tick", cdecl.} =
  ## `checkReplayHash`'s divergence tick, or -1. One divergent bit is caught at
  ## the tick it happens and surfaced as `mismatchTick` in `#mmwarn`.
  if runtimeLoaded: cint(replay.mismatchTick()) else: -1

proc ccErrorPointer(): ptr uint8 {.exportc: "cc_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc ccErrorLength(): cint {.exportc: "cc_error_len", cdecl.} =
  cint(lastError.len)

proc ccStagePointer(): ptr uint8 {.exportc: "cc_stage_ptr", cdecl.} =
  ## Unlike `cc_error_*`, this stays valid after an allocation-failure abort,
  ## so JS can report what the runtime was doing.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc ccStageLength(): cint {.exportc: "cc_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing the baked board plates, the replay data — everything — while the
  # wasm module stays alive and JS keeps calling cc_load_replay/cc_frame. The
  # whole session then runs on freed globals. Unwinding main through
  # emscripten's live-runtime exit skips the destructor epilogue entirely, so
  # globals stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
