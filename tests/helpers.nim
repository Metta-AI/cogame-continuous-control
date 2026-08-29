## Shared test helpers: a headless episode driver that mirrors the SERVER's
## own loop exactly — turn boundary, order record, per-tick hash, per-48-tick
## state keyframe, stage records, the `result` record — so the record ->
## re-derive tests exercise the bytes the server actually writes.

import std/[json, os, strutils]
import cc/[sim, sim_config, report, directives, baselines, replays, decide,
           replay_runtime]

type
  EpisodeRun* = object
    sim*: SimServer
    bytes*: string
    results*: JsonNode

proc ladderConfig*(ladder: seq[Morph], seed: int64,
                   variant = "ladder"): GameConfig =
  result = defaultConfig()
  result.stageLadder = ladder
  result.seed = seed
  result.variant = variant
  result.tokens = @["token-0"]

proc runScriptedEpisode*(config: GameConfig, kind = blTrotter,
                         reason = endComplete, rule = erLadderComplete,
                         stopAtTurn = -1, faultAtTurn = -1): EpisodeRun =
  ## One whole episode driven by a scripted baseline, recorded exactly as
  ## `src/cc/server.nim` records it.
  var sim = newSimServer(config)
  let params = defaultBaselineParams()
  let writer = newReplayWriter(configJson(config))
  sim.seats[0].name = "test-" & $kind
  sim.seats[0].policyLabel = $kind
  sim.seats[0].kind = "scripted"
  sim.seats[0].baseline = $kind
  writer.writeChat(0, registerRecord(0, seatAlias(0), sim.seats[0].name,
    sim.seats[0].policyLabel, sim.seats[0].kind, sim.seats[0].baseline))
  sim.phase = phPlaying
  var lastStage = -1
  var settledReason = reason
  var settledRule = rule
  var detail = ""
  try:
    while not sim.episodeOver():
      if sim.stageIndex < 0:
        sim.startStage(0)
      if sim.stageIndex != lastStage:
        lastStage = sim.stageIndex
        writer.writeStage(sim.tick, StagePayload(
          index: sim.stageIndex, morph: sim.morph,
          perturb: sim.stages[sim.stageIndex].perturb, startTick: sim.tick))
        writer.writeKeyframe(sim.tick, sim.keyframeWords())
      if stopAtTurn >= 0 and sim.turnsPlayed >= stopAtTurn:
        settledReason = endDeadline
        settledRule = erWallClock
        detail = "forced wall-clock stop at turn " & $sim.turnsPlayed
        break
      if faultAtTurn >= 0 and sim.turnsPlayed >= faultAtTurn:
        settledReason = endFault
        settledRule = erFault
        detail = "forced fault at turn " & $sim.turnsPlayed
        break
      var order = scriptedOrder(params, sim, kind)
      order.source = osScripted
      writer.writeOrder(sim.tick, OrderPayload(
        turn: sim.turnsPlayed + 1, stage: sim.stageIndex, source: order.source,
        gait: order.gait, cadence: order.cadence, power: order.power,
        lean: order.lean, strideBias: order.strideBias,
        phaseShift: order.phaseShift, repaired: order.repaired,
        say: order.say, notes: order.notes))
      writer.writeChat(sim.tick, orderRecord(sim, order,
        sim.turnsPlayed + 1, 0, nil))
      sim.beginTurn(order)
      let turnEnd = sim.tick + config.turnTicks
      while sim.tick < turnEnd and sim.phase != phGameOver:
        let stageBefore = sim.stageIndex
        sim.stepTick()
        writer.writeHash(sim.gameHashValue)
        if config.stateKeyframeTicks > 0 and
            sim.tick mod config.stateKeyframeTicks == 0:
          writer.writeKeyframe(sim.tick, sim.keyframeWords())
        if sim.stageIndex != stageBefore and sim.stageIndex >= 0:
          lastStage = sim.stageIndex
          writer.writeStage(sim.tick, StagePayload(
            index: sim.stageIndex, morph: sim.morph,
            perturb: sim.stages[sim.stageIndex].perturb, startTick: sim.tick))
          writer.writeKeyframe(sim.tick, sim.keyframeWords())
        if sim.ladderComplete():
          break
      sim.endTurn("")
      if sim.ladderComplete():
        break
    if settledReason == endComplete and not sim.ladderComplete() and
        sim.turnsPlayed >= config.maxTurns:
      settledRule = erTurnCap
  except CatchableError as error:
    settledReason = endFault
    settledRule = erFault
    detail = error.msg
  if settledReason != endComplete:
    writer.writeStop(StopPayload(tick: sim.tick, reason: settledReason,
      endRule: settledRule, detail: detail))
  sim.settle(settledReason, settledRule, detail)
  writer.writeChat(sim.tick, resultRecord(sim))
  result.sim = sim
  result.bytes = writer.bytes()
  result.results = sim.ladderResultsJson()

proc rederive*(bytes: string): tuple[sim: SimServer, player: ReplayPlayer] =
  ## Re-derives the whole episode from the recorded bytes, tick by tick, with
  ## the SAME sim module the recorder ran.
  let data = parseReplayBytes(bytes)
  var runtime = initReplayRuntime(data)
  var sim = runtime.sim
  var player = runtime.player
  while sim.phase != phGameOver and sim.tick < player.maxTick + 4:
    let before = sim.tick
    player.stepReplay(sim)
    if sim.tick == before:
      break
  (sim, player)

proc repoRoot*(): string =
  var dir = getCurrentDir()
  for _ in 0 .. 4:
    if fileExists(dir / "coworld_manifest_template.json"):
      return dir
    dir = dir.parentDir()
  getCurrentDir()

proc readRepoFile*(relative: string): string =
  readFile(repoRoot() / relative)

proc stripNimComments*(source: string): string =
  ## Drops `##`/`#` comment tails and doc-comment lines so a "no floating
  ## point" grep reads CODE, not prose. A `#` inside a string literal is kept,
  ## which is why the scan tracks quoting.
  for line in source.splitLines():
    var kept = ""
    var inString = false
    var escaped = false
    var i = 0
    while i < line.len:
      let ch = line[i]
      if inString:
        kept.add(ch)
        if escaped: escaped = false
        elif ch == '\\': escaped = true
        elif ch == '"': inString = false
      elif ch == '"':
        inString = true
        kept.add(ch)
      elif ch == '#':
        break
      else:
        kept.add(ch)
      inc i
    result.add(kept)
    result.add('\n')

proc stripJsComments*(source: string): string =
  ## Drops `//` tails AND `<!-- ... -->` HTML comment spans so a "no shadowed
  ## alias" grep reads CODE, not the block's own banner explaining WHY the
  ## alias must not be shadowed.
  var text = source
  while true:
    let open = text.find("<!--")
    if open < 0: break
    let close = text.find("-->", open)
    if close < 0:
      text = text[0 ..< open]
      break
    text = text[0 ..< open] & text[close + 3 .. ^1]
  for line in text.splitLines():
    let cut = line.find("//")
    result.add(if cut >= 0: line[0 ..< cut] else: line)
    result.add('\n')
