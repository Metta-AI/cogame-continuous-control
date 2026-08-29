## The continuous-control game server: the Coworld game contract over mummy.
##
## Forked from `coworld-ctf`'s `src/ctf/server.nim` with the three named edits
## of the design note:
##
## 1. TURN BOUNDARY — unchanged in shape, with ONE seat in the batch and the
##    stage lifecycle of the resolution order. Turn boundaries live on the
##    GLOBAL tick grid (`t mod turnTicks == 0`) and are never re-aligned when a
##    stage ends early.
## 2. REGISTRATION INTERCEPTION — the seat's Sprite v1 chat message (`0x81`)
##    whose text parses as a registration object is consumed as REGISTRATION,
##    not applied as a shout and not written to the replay chat stream; the
##    server writes a REDACTED `register` record instead (policy label and
##    kind, never the prompt). The server LOGS LOUDLY and refuses to treat a
##    joined seat with no register record as a policy (the grf-football
##    2026-08-27 silent-default scar). Any other chat text from the seat is
##    dropped — the cog speaks through `say`.
## 3. WALL-CLOCK STOP — the starter's `wallClockBudgetSeconds` check at the top
##    of every loop iteration, kept, forcing `reason = deadline`,
##    `endRule = wallClock`, and written as a LOAD-BEARING stop record applied
##    by the same proc on record and on playback.
##
## Endpoints:
##   GET /healthz                 liveness
##   GET /client/player           the seat page (view-only; policies are prompts)
##   GET /client/global           the spectator page
##   GET /client/replay           the broadcast replay page
##   GET /client/<asset>          chrome_common.js, broadcast_core.js, art
##   GET /replay-data             the recorded replay bytes (replay mode)
##   WS  /player?slot=N&token=T   the player protocol
##   WS  /global                  spectator sprite packets
##
## The certifier's browser probes are served for real and registered BEFORE any
## catch-all asset route, `/client/player` must NOT open the player socket, the
## player websocket CLOSES unless the token matches the seat (the certifier
## probes with a bad token — cogame-flatland 0.1.1), and `websocketHandler`
## keeps the `Ping -> socket.send(message.data, Pong)` branch with NO additional
## `kind` guard: a `kind != TextMessage` guard drops the player's BINARY
## registration frames (lux-ai 0.1.0, snake-royale 0.1.0).

import std/[json, locks, os, sets, strutils, tables, times]
import bitworld/runtime
import bitworld/spriteprotocol
import curly
import mummy
import mummy/routers
import sim_types, sim, sim_config, report, directives, baselines, broadcast,
  decide, events, global, replays, wire_constants

const
  ShutdownGraceSeconds = 20
    ## `/healthz` and `/global` keep answering for a bounded grace AFTER the
    ## artifacts are written, then the process exits: the runner pings
    ## `/global` with a 2 s deadline after the player pods start, and a short
    ## episode may already have exited (the lantern 0.1.3 scar).
  FootprintRing = 64

type
  ServerState = object
    prompts: seq[string]
    scripted: seq[Baseline]
    isLlm: seq[bool]
    policies: seq[string]
    names: seq[string]
    registered: seq[bool]
    everRegistered: seq[bool]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    viewerStates: Table[WebSocket, GlobalViewerState]
    seats: int
    finished: bool

var
  stateLock: Lock
  shared: ServerState
  gameSim: SimServer
  gameServer: Server
  replayPayload: string
  eventsSinkPath: string
  runtimeCfg: RuntimeConfig
  footprints: seq[array[2, int]]

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc declarePlayerFailure(slot: int, message: string) =
  ## The platform's CLOSED payload — exactly `{"message","failed_policy_index"}`
  ## and nothing else.
  try:
    writeCogameEnv("COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json")
  except CatchableError as error:
    echo "continuous-control: player-failure declaration failed: ", error.msg

proc requireFileUri(name: string): string =
  let uri = getEnv(name)
  if uri.len == 0:
    return ""
  if not uri.startsWith("file://"):
    return ""
  uri[7 .. ^1]

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc trackFootprints() =
  ## The renderer's 64-entry ring of ground marks. A pure FX derived from state
  ## deltas, never an event: individual footstrikes must not be able to flood
  ## the feed at 24 Hz.
  if gameSim.stageIndex < 0 or gameSim.phase != phPlaying:
    return
  for f in 0 ..< gameSim.spec.footCount:
    if not gameSim.footWasDown[f]:
      continue
    let idx = gameSim.spec.feet[f]
    let x = int(microMetres(gameSim.body.links[idx].x))
    if footprints.len > 0 and abs(footprints[^1][0] - x) < 120_000:
      continue
    footprints.add([x, gameSim.stageIndex])
    if footprints.len > FootprintRing:
      footprints.delete(0)

proc liveChrome(): string =
  gameSim.buildStateJson(
    gameSim.drainEvents(), playing = true, speed = 1,
    maxTick = max(1, gameSim.config.maxTicks), looping = false,
    transportEnabled = false, mismatchTick = -1)

proc broadcastPacketLocked(chrome: string) =
  ## Global broadcasts are FIRE AND FORGET so a slow viewer can never stall the
  ## episode.
  for socket in shared.globalSockets:
    var next: GlobalViewerState
    let state = shared.viewerStates.getOrDefault(
      socket, initGlobalViewerState())
    let packet = gameSim.buildViewerPacket(state, next, chrome, footprints)
    shared.viewerStates[socket] = next
    try:
      ## The FIRST frame carries the whole baked bed, which is past the hosted
      ## 1 MiB WS frame cap, so every packet goes out chunked at message
      ## boundaries (ctf's own rule).
      for chunk in chunkSpritePacket(packet, MaxWsFrameBytes):
        socket.send(blobFromBytes(chunk), BinaryMessage)
    except CatchableError:
      discard

proc pushFrames() =
  ## Informational: the seat is not required to answer, decisions are
  ## server-side. `fastMode` is true and the server computes every joint
  ## target, so the Sprite v1 Ready packet's dead-reckoning hazard cannot
  ## arise.
  let chrome = liveChrome()
  broadcastPacketLocked(chrome)
  for slot, socket in shared.playerSockets:
    try:
      socket.send($(%*{
        "type": "turn", "turn": gameSim.turnsPlayed, "tick": gameSim.tick,
        "stage": gameSim.stageIndex + 1, "of": gameSim.config.stagesPerEpisode,
        "morph": $gameSim.morph, "alias": seatAlias(slot)}))
    except CatchableError:
      discard

proc broadcastDone(results: JsonNode) =
  let payload = $(%*{"done": true, "result": results})
  for slot, socket in shared.playerSockets:
    try:
      socket.send(payload)
    except CatchableError as error:
      echo "continuous-control: done frame to slot ", slot, " failed: ",
        error.msg

proc finishEpisode(writer: ReplayWriter, log: EventLog) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if shared.finished:
      return
    shared.finished = true
    results = gameSim.ladderResultsJson()
    writer.writeChat(gameSim.tick, resultRecord(gameSim))
    replayData = writer.bytes()
    ## Final frames to the players BEFORE the artifacts: the hosted worker
    ## tears player pods down as soon as results.json exists.
    broadcastDone(results)
    broadcastPacketLocked(liveChrome())
    replayPayload = replayData
  echo "continuous-control: writing replay (", replayData.len,
    " bytes) and results"
  ## The REPLAY first, then the results: the hosted worker treats results.json
  ## as the end of the episode and tears the pods down when it appears, so a
  ## replay written after it can be lost.
  writeArtifact(runtimeCfg.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD")
  writeArtifact(runtimeCfg.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  if eventsSinkPath.len > 0:
    try:
      writeFile(eventsSinkPath, log.eventsJsonl(gameSim.tick))
    except CatchableError as error:
      echo "continuous-control: event sink write failed: ", error.msg
  echo "continuous-control: episode complete (", $gameSim.reason, "/",
    $gameSim.endRule, ") after ", gameSim.tick, " ticks, return ",
    gameSim.totalReturnMicro, " micro-points, ", gameSim.falls, " falls"

proc runGame(unused: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = gameSim.config
    let gameStart = epochTime()
    let lobbySeconds = config.lobbyJoinTimeoutTicks / TargetFps
    let connectDeadline = gameStart + lobbySeconds
    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = shared.playerSockets.len >= shared.seats
      if allConnected:
        break
      gameSim.lobbyTicks = int(connectDeadline - epochTime()) * TargetFps
      sleep(200)
    ## Give a connected-but-silent seat a moment to send its register frame.
    let registerDeadline = min(epochTime() + 4.0, connectDeadline + 4.0)
    while epochTime() < registerDeadline:
      var allRegistered = true
      withLock stateLock:
        for slot in 0 ..< shared.seats:
          if shared.playerSockets.hasKey(slot) and not shared.registered[slot]:
            allRegistered = false
      if allRegistered:
        break
      sleep(100)

    var noShow = -1
    withLock stateLock:
      for slot in 0 ..< shared.seats:
        if not shared.everRegistered[slot]:
          if noShow < 0:
            noShow = slot
          ## LOUD, and the design's rule: a joined seat with no register record
          ## is a defect, not a default. The episode still runs — nothing a
          ## player container does may stop the clock — but the log says so.
          if shared.playerSockets.hasKey(slot):
            echo "continuous-control: ERROR seat ", slot, " connected but ",
              "never sent a register frame; refusing to treat it as a policy ",
              "and seating the trotter baseline"
          else:
            echo "continuous-control: seat ", slot, " never connected; the ",
              "seat plays the trotter baseline"
          shared.isLlm[slot] = false
          shared.scripted[slot] = blTrotter
        gameSim.seats[slot].kind =
          if shared.isLlm[slot]: "llm" else: "scripted"
        gameSim.seats[slot].policyLabel = shared.policies[slot]
        gameSim.seats[slot].baseline = $shared.scripted[slot]
        gameSim.seats[slot].name = shared.names[slot]
        gameSim.seats[slot].registered = shared.everRegistered[slot]
        gameSim.seats[slot].dead = not shared.everRegistered[slot]
      echo "continuous-control: starting with ", shared.playerSockets.len, "/",
        shared.seats, " players connected"
    if noShow >= 0:
      declarePlayerFailure(noShow,
        "player slot " & $noShow & " never registered; the seat played the " &
        "trotter baseline")

    var engine = initDecisionEngine(gameSim)
    withLock stateLock:
      for slot in 0 ..< shared.seats:
        engine.seats[slot].isLlm = shared.isLlm[slot]
        engine.seats[slot].prompt = shared.prompts[slot]
        engine.seats[slot].baseline = shared.scripted[slot]
        engine.seats[slot].label = shared.policies[slot]
        engine.seats[slot].registered = shared.everRegistered[slot]

    let writer = newReplayWriter(configJson(config))
    let log = newEventLog(eventsSinkPath.len > 0)
    for slot in 0 ..< shared.seats:
      writer.writeChat(0, registerRecord(
        slot, seatAlias(slot), gameSim.seats[slot].name,
        gameSim.seats[slot].policyLabel, gameSim.seats[slot].kind,
        gameSim.seats[slot].baseline))

    var
      reason = endComplete
      rule = erLadderComplete
      detail = ""
      notes = ""
      lastStageWritten = -1
    gameSim.phase = phPlaying
    try:
      while not gameSim.episodeOver():
        let elapsed = int(epochTime() - gameStart)
        ## EDIT 3 — the wall-clock stop, checked at the top of every loop
        ## iteration.
        if elapsed >= config.wallClockBudgetSeconds:
          reason = endDeadline
          rule = erWallClock
          detail = "wall clock budget of " & $config.wallClockBudgetSeconds &
            "s reached at turn " & $gameSim.turnsPlayed
          echo "continuous-control: ", detail
          break
        if gameSim.stageIndex < 0:
          gameSim.startStage(0)
        if gameSim.stageIndex != lastStageWritten:
          lastStageWritten = gameSim.stageIndex
          writer.writeStage(gameSim.tick, StagePayload(
            index: gameSim.stageIndex,
            morph: gameSim.morph,
            perturb: gameSim.stages[gameSim.stageIndex].perturb,
            startTick: gameSim.tick))
          writer.writeKeyframe(gameSim.tick, gameSim.keyframeWords())
          log.add(seStageStart, gameSim.tick, %*{
            "stage": gameSim.stageIndex, "morph": $gameSim.morph})
        ## EDIT 1 — the decision turn, immediately before the tick that starts
        ## it. This is the determinism boundary: the LLM lives on THIS side of
        ## it and only the clamped order below is recorded, so the wasm viewer
        ## re-derives the whole episode without running it.
        let outcome = engine.turn(gameSim, gameSim.turnsPlayed + 1, elapsed)
        var order = outcome.order
        for record in outcome.records:
          writer.writeChat(gameSim.tick, record)
          gameSim.feed.add(parseJson(record))
        if order.source == osLlm:
          gameSim.seats[0].llmTurns.inc
        elif order.source == osFallback:
          gameSim.seats[0].fallbackTurns.inc
        writer.writeOrder(gameSim.tick, OrderPayload(
          turn: gameSim.turnsPlayed + 1, stage: gameSim.stageIndex,
          source: order.source, gait: order.gait, cadence: order.cadence,
          power: order.power, lean: order.lean, strideBias: order.strideBias,
          phaseShift: order.phaseShift, repaired: order.repaired,
          say: order.say, notes: order.notes))
        log.add(seTurnStart, gameSim.tick, %*{
          "turn": gameSim.turnsPlayed + 1, "source": $order.source,
          "gait": $order.gait, "cadence": int(order.cadence),
          "power": int(order.power)})
        let record = orderRecord(gameSim, order, gameSim.turnsPlayed + 1, 0,
          outcome.view)
        writer.writeChat(gameSim.tick, record)
        gameSim.feed.add(parseJson(record))
        if gameSim.feed.len > 40:
          gameSim.feed.delete(0)
        notes = order.notes
        gameSim.beginTurn(order)
        let turnEndTick = gameSim.tick + config.turnTicks
        while gameSim.tick < turnEndTick and gameSim.phase != phGameOver:
          let stageBefore = gameSim.stageIndex
          gameSim.stepTick()
          writer.writeHash(gameSim.gameHashValue)
          if config.stateKeyframeTicks > 0 and
              gameSim.tick mod config.stateKeyframeTicks == 0:
            writer.writeKeyframe(gameSim.tick, gameSim.keyframeWords())
          log.add(seServo, gameSim.tick, %*{
            "stage": gameSim.stageIndex,
            "tau": (block:
              var row = newJArray()
              for j in 0 ..< gameSim.spec.jointCount:
                row.add(%gameSim.lastForces.tau[j])
              row)})
          trackFootprints()
          if gameSim.stageIndex != stageBefore and gameSim.stageIndex >= 0:
            lastStageWritten = gameSim.stageIndex
            writer.writeStage(gameSim.tick, StagePayload(
              index: gameSim.stageIndex, morph: gameSim.morph,
              perturb: gameSim.stages[gameSim.stageIndex].perturb,
              startTick: gameSim.tick))
            writer.writeKeyframe(gameSim.tick, gameSim.keyframeWords())
            log.add(seStageStart, gameSim.tick, %*{
              "stage": gameSim.stageIndex, "morph": $gameSim.morph})
          if gameSim.ladderComplete():
            break
        gameSim.endTurn(notes)
        withLock stateLock:
          pushFrames()
        if gameSim.ladderComplete():
          break
      if reason == endComplete and not gameSim.ladderComplete() and
          gameSim.turnsPlayed >= config.maxTurns:
        rule = erTurnCap
    except SimGuardError as guard:
      reason = endFault
      rule = erFault
      detail = "sim guard: " & guard.msg
      echo "continuous-control: SIM GUARD tripped — ", guard.msg
    except CatchableError as error:
      reason = endFault
      rule = erFault
      detail = error.msg
      echo "continuous-control: FAULT — ", error.msg

    if reason != endComplete:
      writer.writeStop(StopPayload(
        tick: gameSim.tick, reason: reason, endRule: rule, detail: detail))
    gameSim.settle(reason, rule, detail)
    finishEpisode(writer, log)
    ## Keep /healthz and /global answering for a bounded grace after the
    ## artifacts are written, then exit.
    sleep(ShutdownGraceSeconds * 1000)
    quit(0)

var gameThread: Thread[RuntimeConfig]

proc serveText(request: Request, body, contentType: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = contentType
  request.respond(200, headers, body)

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    serveText(request, readFile(path), contentType)
  else:
    request.respond(404)

proc servePage(request: Request, path: string) =
  if not fileExists(path):
    request.respond(404)
    return
  var page = readFile(path)
  page = page.spliceWireConstants()
  let chromeCommon = clientDir() / "chrome_common.js"
  if fileExists(chromeCommon):
    page = page.replace("<!-- CHROME_COMMON -->",
      "<script>" & readFile(chromeCommon) & "</script>")
  let core = clientDir() / "broadcast_core.js"
  if fileExists(core):
    page = page.replace("<!-- BROADCAST_CORE -->",
      "<script>" & readFile(core) & "</script>")
  serveText(request, page, "text/html; charset=utf-8")

proc healthzHandler(request: Request) {.gcsafe.} =
  serveText(request, """{"ok":true}""", "application/json")

proc replayPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}: servePage(request, clientDir() / "replay_broadcast.html")

proc playerPageHandler(request: Request) {.gcsafe.} =
  ## Token-checked, and it MUST NOT open the player socket: the certifier
  ## fetches this page as a browser probe before the player pods start.
  {.gcsafe.}:
    let token = request.queryParams["token"]
    var ok = false
    withLock stateLock:
      for candidate in gameSim.config.tokens:
        if candidate == token:
          ok = true
    if not ok and gameSim.config.tokens.len > 0 and token.len > 0:
      request.respond(403)
      return
    serveText(request,
      "<!doctype html><meta charset=utf-8><title>Continuous control seat" &
      "</title><body style=\"background:#16110d;color:#f2e8d8;" &
      "font:14px system-ui;padding:24px\"><h1>Continuous control</h1>" &
      "<p>A policy is just a prompt. This seat is driven from the game " &
      "server; there is nothing to control here.</p>" &
      "<p><a style=\"color:#e8a33d\" href=\"/client/replay\">Watch the " &
      "board</a></p>", "text/html; charset=utf-8")

proc globalPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}: servePage(request, clientDir() / "replay_broadcast.html")

proc clientAssetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".js"): "application/javascript; charset=utf-8"
      elif name.endsWith(".css"): "text/css; charset=utf-8"
      elif name.endsWith(".html"): "text/html; charset=utf-8"
      elif name.endsWith(".png"): "image/png"
      elif name.endsWith(".jpg"): "image/jpeg"
      elif name.endsWith(".webp"): "image/webp"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, clientDir() / name, contentType)

proc clientArtHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let
      kind = request.pathParams["kind"]
      name = request.pathParams["name"]
    if "/" in kind or "/" in name or name.startsWith(".") or
        kind.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".webp"): "image/webp"
      elif name.endsWith(".png"): "image/png"
      else: "image/jpeg"
    serveFile(request, clientDir() / "art" / kind / name, contentType)

proc replayDataHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    var bytes = ""
    withLock stateLock:
      bytes = replayPayload
    if bytes.len == 0:
      request.respond(404)
      return
    serveText(request, bytes, "application/octet-stream")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let
      slotText = request.queryParams["slot"]
      token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    var duplicate = false
    withLock stateLock:
      authorized = slot >= 0 and slot < gameSim.config.tokens.len and
        gameSim.config.tokens[slot] == token
      duplicate = authorized and shared.playerSockets.hasKey(slot)
    if not authorized:
      ## The certifier probes with a WRONG token and requires a close
      ## (cogame-flatland 0.1.1).
      request.respond(403)
      return
    if duplicate:
      request.respond(409)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.playerSockets[slot] = websocket
      shared.socketSlots[websocket] = slot
      echo "continuous-control: player slot ", slot, " connected (",
        shared.playerSockets.len, "/", shared.seats, ")"
      try:
        websocket.send($(%*{
          "type": "welcome", "protocol": ProtocolName, "slot": slot,
          "alias": seatAlias(slot),
          "turn_ticks": gameSim.config.turnTicks}))
      except CatchableError:
        discard

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.globalSockets.incl(websocket)
      shared.viewerStates[websocket] = initGlobalViewerState()
      var next: GlobalViewerState
      let packet = gameSim.buildViewerPacket(
        shared.viewerStates[websocket], next, liveChrome(), footprints)
      shared.viewerStates[websocket] = next
      try:
        for chunk in chunkSpritePacket(packet, MaxWsFrameBytes):
          websocket.send(blobFromBytes(chunk), BinaryMessage)
      except CatchableError:
        discard

proc applyRegistration(slot: int, text: string): bool =
  ## The seat's registration blob. ANY OTHER chat text from the seat is dropped
  ## — the cog speaks through `say`, never through the socket.
  var payload: JsonNode
  try:
    payload = parseJson(text)
  except CatchableError:
    return false
  if payload.isNil or payload.kind != JObject:
    return false
  if not payload.hasKey("policy") and not payload.hasKey("prompt") and
      not payload.hasKey("scripted"):
    return false
  let prompt = payload{"prompt"}.getStr().truncateRunes(MaxPromptRunes)
  let scriptedNode = payload{"scripted"}
  var scriptedName = ""
  if not scriptedNode.isNil and scriptedNode.kind == JString:
    scriptedName = scriptedNode.getStr().strip()
  var isLlm = prompt.strip().len > 0
  if scriptedName.len > 0:
    isLlm = false
  withLock stateLock:
    shared.prompts[slot] = prompt
    shared.isLlm[slot] = isLlm
    shared.scripted[slot] =
      if scriptedName.len > 0: parseBaseline(scriptedName) else: blTrotter
    shared.policies[slot] =
      payload{"policy"}.getStr().truncateRunes(MaxPolicyLabelRunes)
    if shared.policies[slot].len == 0:
      shared.policies[slot] = if isLlm: "llm" else: $shared.scripted[slot]
    shared.names[slot] =
      payload{"name"}.getStr().truncateRunes(MaxPolicyLabelRunes)
    if shared.names[slot].len == 0:
      shared.names[slot] = shared.policies[slot]
    shared.registered[slot] = true
    shared.everRegistered[slot] = true
  echo "continuous-control: slot ", slot, " registered (", prompt.len,
    " prompt chars", (if isLlm: ", llm" else: ", scripted " & scriptedName),
    ")"
  true

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
                      message: Message) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application; the certifier pings
      ## /global AND /player to check the game is alive, so an unanswered ping
      ## fails certification. NOTHING else is guarded here: a
      ## `kind != TextMessage` guard drops the player's BINARY registration
      ## frames (lux-ai 0.1.0, snake-royale 0.1.0).
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      var slot = -1
      withLock stateLock:
        slot = shared.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        withLock stateLock:
          if websocket in shared.viewerStates:
            var state = shared.viewerStates[websocket]
            state.applyGlobalViewerMessage(message.data)
            state.replayCommands.setLen(0)
            state.replaySeekTick = -1
            shared.viewerStates[websocket] = state
        return
      var handled = false
      for item in message.data.parseSpriteClientMessages():
        if item.kind == SpriteClientChatMessage:
          if applyRegistration(slot, item.text):
            handled = true
      if not handled:
        discard applyRegistration(slot, message.data)
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in shared.socketSlots:
          let closing = shared.socketSlots[websocket]
          shared.socketSlots.del(websocket)
          if shared.playerSockets.getOrDefault(closing) == websocket:
            shared.playerSockets.del(closing)
          ## A seat that drops keeps playing: nothing a player container does
          ## can stop the clock.
          shared.registered[closing] = shared.everRegistered[closing]
        shared.globalSockets.excl(websocket)
        shared.viewerStates.del(websocket)

proc buildRouter(replayMode: bool): Router =
  ## The certifier's probes are registered BEFORE the catch-all asset route.
  result.get("/healthz", healthzHandler)
  result.get("/client/player", playerPageHandler)
  result.get("/client/global", globalPageHandler)
  result.get("/client/replay", replayPageHandler)
  result.get("/client/art/@kind/@name", clientArtHandler)
  result.get("/client/@name", clientAssetHandler)
  result.get("/replay-data", replayDataHandler)
  result.get("/global", globalUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  replayPayload = runtimeConfig.replay
  gameSim = newSimServer(defaultConfig())
  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  echo "continuous-control: replay mode on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc stopServer*() =
  if gameServer != nil:
    gameServer.close()

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.numAgents:
    raise newException(CcError, "tokens must name exactly num_agents seats")
  runtimeCfg = runtimeConfig
  eventsSinkPath = requireFileUri("COGAME_EVENTS_URI")
  gameSim = newSimServer(config)
  shared.seats = config.numAgents
  shared.prompts = newSeq[string](shared.seats)
  shared.scripted = newSeq[Baseline](shared.seats)
  shared.isLlm = newSeq[bool](shared.seats)
  shared.policies = newSeq[string](shared.seats)
  shared.names = newSeq[string](shared.seats)
  shared.registered = newSeq[bool](shared.seats)
  shared.everRegistered = newSeq[bool](shared.seats)
  for slot in 0 ..< shared.seats:
    shared.policies[slot] = "trotter"
    shared.names[slot] = "trotter"
  ## Bake the board plates BEFORE the listener opens: a viewer's first-message
  ## clock starts at its successful connect (the certifier allows only
  ## seconds), so nothing may be accepted until every frame the loop will ever
  ## build can be assembled instantly.
  warmBoardRenderCaches()
  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  createThread(gameThread, runGame, runtimeConfig)
  echo "continuous-control: serving on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
