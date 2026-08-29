## Replay playback: the runtime that re-derives an episode from the recorded
## bytes, tick by tick, with the SAME sim module the server ran.
##
## Forked from the starter's `src/ctf/replay_runtime.nim` + the transport half
## of `replays.nim`. A seek REWINDS AND RE-STEPS from tick 0: the recorded
## state keyframe carries the link state and nothing else, so restoring one
## mid-stream would leave `stageTick`, `cyclePos` and every accumulator behind
## and diverge the hash chain from the very next tick. The keyframes are what
## they are worth as: a CROSS-CHECK, applied at the tick they were recorded on
## (see `applyRecordsAt`), and the pre-scan's cheap read of the torso track.
## 1 512 ticks of a 120-pass integer solver is ~0.4 s natively and about a
## second in wasm32, which a scrubber click can afford; a wrong resume is not.
##
## A LOAD-TIME PRE-SCAN walks the recorded keyframes and per-turn orders — NOT
## a full re-simulation — to build the cumulative-return series, the stage
## boundary ticks, the beat ticks and the lull spans, then renders frame 0.
## Reading 32 keyframes and 42 orders is microseconds, which is what lets the
## progress sparkline and the scrubber beats draw at FULL WIDTH on the first
## frame instead of growing in.

import std/[json, strutils]
import sim_types, trig, body, sim, sim_config, report, replays, labels

const
  FramesPerTick* = 1
    ## At speed 1 the board advances ONE tick per presentation frame — 24
    ## ticks/second, real time. A full 1 512-tick episode plays for 63 s and
    ## even a triple-fall episode plays for ~12 s, which is what lets
    ## `viewer_smoke.mjs --soak 10` observe real advancement instead of a
    ## legitimately finished replay (the ecos 2026-08-23 scar).
  LullTicks* = 48
    ## A lull is 48 consecutive ticks with the torso moving under 0.15 m and no
    ## stage change.
  LullMoveQ16* = 9_830'i64      ## 0.15 m
  EndHoldSeconds* = 4

type
  Beat* = object
    tick*: int
    kind*: string
    label*: string

  ReplayPlayer* = object
    data*: ReplayData
    recordIndex*: int
    hashIndex*: int
    hashMismatchTick*: int
    keyframeMismatchTick*: int
    playing*: bool
    looping*: bool
    skipLulls*: bool
    speedIndex*: int
    frameCounter*: int
    endHoldFrames*: int
    maxTick*: int
    startTick*: int
    beats*: seq[Beat]
    lullSpans*: seq[array[2, int]]
    returnSeries*: seq[array[2, int]]   ## [tick, cumulative return micro/1000]
    stageBoundaries*: seq[int]
    stageMarks*: seq[array[2, int]]     ## [stage, final distance micro]
    scanComplete*: bool
    fastForwarding*: bool

proc replaySpeed*(player: ReplayPlayer): int =
  PlaybackSpeeds[clamp(player.speedIndex, 0, PlaybackSpeeds.high)]

proc newSimFromReplay*(data: ReplayData): SimServer =
  var config = defaultConfig()
  config.update(data.config)
  result = newSimServer(config)
  result.phase = phPlaying

proc applyChat(sim: SimServer, record: string) =
  ## Chat records are re-applied at playback into NON-HASHED fields only: they
  ## drive the broadcast feed and `tools/replay_summary.py` and can never
  ## affect the simulation.
  var node: JsonNode
  try:
    node = parseJson(record)
  except CatchableError:
    return
  case node{"k"}.getStr()
  of "register":
    let slot = node{"slot"}.getInt()
    if slot >= 0 and slot < sim.seats.len:
      sim.seats[slot].name = node{"name"}.getStr()
      sim.seats[slot].policyLabel = node{"policy"}.getStr()
      sim.seats[slot].kind = node{"kind"}.getStr("scripted")
      sim.seats[slot].baseline = node{"baseline"}.getStr()
      sim.seats[slot].registered = true
  of "budget_guard":
    sim.emit(%*{"k": "budget", "turn": node{"turn"}.getInt(),
                "remaining_s": node{"remaining_s"}.getInt()})
  of "fallback", "order":
    sim.feed.add(node)
  else:
    discard

proc applyRecordsAt(player: var ReplayPlayer, sim: SimServer) =
  while player.recordIndex < player.data.records.len and
      player.data.records[player.recordIndex].tick <= sim.tick:
    let record = player.data.records[player.recordIndex]
    inc player.recordIndex
    case record.kind
    of rkStage:
      sim.startStage(record.stage.index)
    of rkOrder:
      var order = orderFromPayload(record.order)
      sim.beginTurn(order)
      if order.source == osLlm:
        sim.seats[0].llmTurns.inc
      elif order.source == osFallback:
        sim.seats[0].fallbackTurns.inc
    of rkKeyframe:
      ## AT EACH KEYFRAME THE RE-SIMULATED STATE MUST EQUAL THE RECORDED ONE.
      ## If it does not, publish `keyframeMismatchTick`, show `#mmwarn`, and
      ## RESYNC from the recorded keyframe, so a spectator always sees the run
      ## that actually happened rather than a divergent one.
      let derived = sim.keyframeWords()
      if derived.len == record.keyframe.words.len:
        var same = true
        for i in 0 ..< derived.len:
          if derived[i] != record.keyframe.words[i]:
            same = false
            break
        if not same:
          if player.keyframeMismatchTick < 0:
            player.keyframeMismatchTick = sim.tick
          sim.restoreKeyframe(record.keyframe.words)
    of rkChat:
      sim.applyChat(record.chat)
    of rkStop:
      sim.settle(record.stop.reason, record.stop.endRule, record.stop.detail)

proc stepReplay*(player: var ReplayPlayer, sim: SimServer) =
  ## One recorded tick, re-derived from the recorded orders.
  player.applyRecordsAt(sim)
  if sim.phase == phGameOver:
    return
  if sim.ladderComplete():
    sim.settle(endComplete, erLadderComplete)
    return
  let before = sim.tick
  sim.stepTick()
  if sim.tick == before:
    ## Nothing advanced: the recording cannot produce this, but a truncated
    ## file can, so stop rather than spin.
    sim.settle(endComplete, erLadderComplete)
    return
  if player.hashIndex < player.data.hashes.len:
    if player.data.hashes[player.hashIndex] != sim.gameHashValue and
        player.hashMismatchTick < 0:
      ## ONE DIVERGENT BIT IS CAUGHT AT THE TICK IT HAPPENS and surfaced as
      ## `mismatchTick` in `#mmwarn`.
      player.hashMismatchTick = sim.tick
    inc player.hashIndex

proc rewind*(player: var ReplayPlayer, sim: var SimServer) =
  sim = newSimFromReplay(player.data)
  player.recordIndex = 0
  player.hashIndex = 0

proc seekReplay*(player: var ReplayPlayer, sim: var SimServer, tick: int) =
  let target = clamp(tick, 0, player.maxTick)
  player.rewind(sim)
  while sim.tick < target and sim.phase != phGameOver:
    player.stepReplay(sim)
  sim.events.setLen(0)

proc metresText(micro: int64): string =
  let whole = micro div 1_000_000
  let frac = abs((micro mod 1_000_000) div 100_000)
  $whole & "." & $frac

proc scanReplay*(player: var ReplayPlayer) =
  ## THE LOAD-TIME PRE-SCAN. It walks the recorded stage records, the per-turn
  ## orders and the state keyframes rather than re-simulating 1 512 ticks x 120
  ## solver passes, which would delay the first drawn frame by seconds.
  player.beats.setLen(0)
  player.lullSpans.setLen(0)
  player.returnSeries.setLen(0)
  player.stageBoundaries.setLen(0)
  player.stageMarks.setLen(0)
  player.returnSeries.add([0, 0])

  var config = defaultConfig()
  config.update(player.data.config)

  ## The keyframes carry the torso x at each recorded tick, which is all the
  ## lull scan and the sparkline need.
  var
    lastX = 0'i64
    lastKeyTick = 0
    quietStart = -1
    cumulative = 0'i64
    stageIndex = -1
    stageStartTick = 0
  var maxTick = 0
  for record in player.data.records:
    if record.tick > maxTick:
      maxTick = record.tick
  for record in player.data.records:
    case record.kind
    of rkStage:
      stageIndex = record.stage.index
      stageStartTick = record.tick
      player.stageBoundaries.add(record.tick)
      player.beats.add(Beat(tick: record.tick, kind: "stagestart",
        label: "STAGE " & $(stageIndex + 1) & " OF " &
          $config.stagesPerEpisode & " — " & morphLabel(record.stage.morph) &
          ", 60 M OF TRACK"))
      if quietStart >= 0 and record.tick - quietStart >= LullTicks:
        player.lullSpans.add([quietStart, record.tick])
      quietStart = -1
    of rkOrder:
      if record.order.source == osFallback:
        player.beats.add(Beat(tick: record.tick, kind: "fallback",
          label: "MISSED THE CALL — trotter order"))
    of rkKeyframe:
      if record.keyframe.words.len >= 2:
        let x = int64(record.keyframe.words[0])
        if absQ(x - lastX) < LullMoveQ16:
          if quietStart < 0:
            quietStart = lastKeyTick
        else:
          if quietStart >= 0 and record.tick - quietStart >= LullTicks:
            player.lullSpans.add([quietStart, record.tick])
          quietStart = -1
        lastX = x
        lastKeyTick = record.tick
    of rkChat:
      var node: JsonNode
      try:
        node = parseJson(record.chat)
      except CatchableError:
        continue
      if node{"k"}.getStr() == "result":
        discard
    of rkStop:
      discard

  ## The cumulative-return series and the stage beats come from the `result`
  ## record's own per-stage numbers, which is the only place the outcome of a
  ## stage is written down once and for all.
  var stageTicks: seq[int] = player.stageBoundaries
  for node in player.data.chatRecords():
    if node{"k"}.getStr() != "result":
      continue
    let results = node{"results"}
    if results.isNil:
      continue
    let outcomes = results{"stageOutcome"}
    let distances = results{"stageDistance"}
    let returns = results{"stageReturn"}
    let ticksRun = results{"stageTicksRun"}
    if outcomes.isNil or distances.isNil or returns.isNil or ticksRun.isNil:
      continue
    for i in 0 ..< outcomes.len:
      let endTick =
        (if i < stageTicks.len: stageTicks[i] else: 0) +
        ticksRun[i].getInt()
      let dist = distances[i].getFloat()
      let ret = returns[i].getFloat()
      let outcome = outcomes[i].getStr()
      if outcome == "unreached":
        continue
      cumulative += int64(ret * 1000.0)
      player.returnSeries.add([endTick, int(cumulative)])
      player.stageMarks.add([i, int(dist * 1000.0)])
      let distText = metresText(int64(dist * 1_000_000.0))
      if outcome == "fell":
        player.beats.add(Beat(tick: endTick, kind: "fall",
          label: "DOWN — STAGE " & $(i + 1) & " AT " & distText & " M"))
      elif outcome == "lined":
        player.beats.add(Beat(tick: endTick, kind: "stageend",
          label: "LINED OUT — 60 M IN " &
            metresText(int64(ticksRun[i].getInt() * 1_000_000 div TargetFps)) &
            " S"))
      else:
        player.beats.add(Beat(tick: endTick, kind: "stageend",
          label: "STAGE " & $(i + 1) & " DONE — " & distText & " M"))
      var metre = MilestoneMetres
      while float(metre) <= dist:
        player.beats.add(Beat(
          tick: (if i < stageTicks.len: stageTicks[i] else: 0) +
            int(float(ticksRun[i].getInt()) * float(metre) / max(0.001, dist)),
          kind: "milestone", label: $metre & " METRES"))
        metre += MilestoneMetres
    player.beats.add(Beat(tick: maxTick, kind: "end",
      label: "FINAL — RETURN " &
        metresText(int64(results{"totalReturn"}.getFloat() * 1_000_000.0))))

  player.maxTick = max(1, maxTick)
  player.returnSeries.add([player.maxTick, int(cumulative)])
  player.scanComplete = true

proc initReplayRuntime*(data: ReplayData):
    tuple[sim: SimServer, player: ReplayPlayer] =
  var player = ReplayPlayer(
    data: data, hashMismatchTick: -1, keyframeMismatchTick: -1,
    playing: true, looping: true, skipLulls: true, speedIndex: 0, startTick: 0)
  player.scanReplay()
  var sim = newSimFromReplay(data)
  player.rewind(sim)
  result.sim = sim
  result.player = player

proc isLullTick*(player: ReplayPlayer, tick: int): bool =
  for span in player.lullSpans:
    if tick >= span[0] and tick < span[1]:
      return true
  false

proc mismatchTick*(player: ReplayPlayer): int =
  ## `checkReplayHash`'s divergence tick, or -1. A keyframe mismatch counts too:
  ## both are surfaced in `#mmwarn`.
  if player.hashMismatchTick >= 0: player.hashMismatchTick
  elif player.keyframeMismatchTick >= 0: player.keyframeMismatchTick
  else: -1

proc applyReplayCommand*(player: var ReplayPlayer, sim: var SimServer,
                         command: char) =
  ## The starter's transport vocabulary, kept 1:1 so `chrome_common.js`'s
  ## buttons and speed chips drive this runtime unchanged.
  case command
  of ' ': player.playing = not player.playing
  of 'p': player.playing = true
  of 'P': player.playing = false
  of '1': player.speedIndex = 0
  of '2': player.speedIndex = 1
  of '4': player.speedIndex = 2
  of '8': player.speedIndex = 3
  of '+', '=':
    player.speedIndex = min(player.speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_':
    player.speedIndex = max(player.speedIndex - 1, 0)
  of ',', '<':
    player.playing = false
    player.seekReplay(sim, player.startTick)
  of 'b':
    player.playing = false
    player.seekReplay(sim, max(player.startTick, sim.tick - 1))
  of 'e':
    player.playing = false
    player.seekReplay(sim, player.maxTick)
  of 'r': player.looping = not player.looping
  of 'f': player.skipLulls = not player.skipLulls
  of '.', '>':
    player.playing = false
    player.seekReplay(sim, sim.tick + ReplayFps * 5)
  else: discard

proc advanceReplayFrame*(player: var ReplayPlayer, sim: var SimServer,
                         seekTicks: openArray[int],
                         commands: openArray[char]): JsonNode =
  ## Applies viewer controls and advances ONE presentation frame.
  for tick in seekTicks:
    player.seekReplay(sim, tick)
    player.endHoldFrames = 0
  for command in commands:
    let before = sim.tick
    player.applyReplayCommand(sim, command)
    if sim.tick != before:
      player.endHoldFrames = 0
  sim.events.setLen(0)
  player.fastForwarding = false
  if not player.playing:
    return sim.drainEvents()
  if sim.phase == phGameOver:
    if player.looping:
      if player.endHoldFrames <= 0:
        player.endHoldFrames = EndHoldSeconds * ReplayFps
      dec player.endHoldFrames
      if player.endHoldFrames <= 0:
        player.seekReplay(sim, player.startTick)
    return sim.drainEvents()
  inc player.frameCounter
  var ticks = player.replaySpeed()
  if player.skipLulls and player.isLullTick(sim.tick):
    ticks = ticks * 8
    player.fastForwarding = true
  for _ in 0 ..< ticks:
    if sim.phase == phGameOver:
      break
    player.stepReplay(sim)
  sim.drainEvents()

proc endHoldSecondsLeft*(player: ReplayPlayer): int =
  if player.endHoldFrames <= 0: 0
  else: (player.endHoldFrames + ReplayFps - 1) div ReplayFps
