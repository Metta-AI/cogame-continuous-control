## The sim: the numbered turn/tick resolution order of the design note, the
## per-tick hash chain, stage and episode end evaluation, scoring, and the
## state-keyframe writer.
##
## Imports and RE-EXPORTS the sim modules, as the starter's `src/ctf/sim.nim`
## does, so `import cc/sim` sees everything.
##
## ALL SIM ARITHMETIC IS INTEGER. There is no floating point in this module or
## in trig/body/solver/gaits/driver, and `tests/test_cc_sim.nim` 13 greps for
## it. `src/cc/report.nim` is the ONLY module allowed to use `isqrtQ16` and the
## only module allowed to produce a decimal string; it never writes hashed
## state.

import std/json
import sim_types, trig, body, solver, gaits, driver
export sim_types, trig, body, solver, gaits, driver

const
  InitPerturbQ16* = 3_277'i64     ## 0.05 rad
  TrackStartXQ16* = 0'i64
  TrackLineXQ16* = 60'i64 * OneQ16
  TrackBackXQ16* = -6'i64 * OneQ16
  MilestoneMetres* = 5
  GuardMinXQ16* = -20'i64 * OneQ16
  GuardMaxXQ16* = 80'i64 * OneQ16
  GuardMinYQ16* = -2'i64 * OneQ16
  GuardMaxYQ16* = 20'i64 * OneQ16
  AirborneNone* = 0'i32

type
  StageRecord* = object
    morph*: Morph
    outcome*: StageOutcome
    why*: FallWhy
    distanceMicro*: int64        ## micro-metres; MAY BE NEGATIVE
    returnMicro*: int64
    ticksRun*: int32
    turns*: int32
    uprightTicks*: int32
    ctrlCostMicro*: int64
    peakSpeedMicro*: int64       ## micro-metres/second
    strides*: int32
    saturatedTicks*: int32
    airborneTicks*: int32
    footstrikes*: int32
    perturb*: array[MaxJoints, int32]   ## the seeded per-joint start offset
    startTick*: int32

  SeatInfo* = object
    name*: string                ## the REAL policy name — spectator side only
    alias*: string               ## the in-game alias: `Alpha`
    policyLabel*: string
    kind*: string                ## "llm" | "scripted"
    baseline*: string
    registered*: bool
    dead*: bool
    llmTurns*: int
    fallbackTurns*: int

  TurnReport* = object
    ## What the seat is told about its own last turn.
    valid*: bool
    distanceMicro*: int64
    meanVxMicro*: int64
    strideMilli*: int32          ## strides completed x 1000
    peakTorquePct*: int32
    saturatedTicks*: int32
    airborneTicks*: int32
    fell*: bool
    returnDeltaMicro*: int64
    repaired*: int
    notes*: string

  SimServer* = ref object
    config*: GameConfig
    params*: GaitParams
    phase*: Phase
    tick*: int
    lobbyTicks*: int
    turnsPlayed*: int

    stageIndex*: int             ## 0-based; -1 before the first stage
    stageTick*: int
    resetTick*: int
    stageTurns*: int
    morph*: Morph
    spec*: MorphSpec
    body*: BodyState
    cyclePos*: int32

    xStart*: int64
    bestX*: int64
    uprightTicks*: int32
    ctrlCostAccum*: int64
    saturatedTicks*: int32
    strideCount*: int32
    airborneTicks*: int32
    footstrikes*: int32
    peakSpeedMicro*: int64
    lastMilestone*: int32
    footWasDown*: array[MaxFeet, bool]

    stages*: seq[StageRecord]
    totalReturnMicro*: int64
    falls*: int
    stagesLined*: int

    activeOrder*: Order
    haveOrder*: bool
    lastForces*: TickForces
    turnStartX*: int64
    turnStartCycle*: int32
    turnStartReturn*: int64
    turnSaturated*: int32
    turnAirborne*: int32
    turnPeakTorque*: int32
    turnFell*: bool
    lastReport*: TurnReport
    ordersRepaired*: int

    reason*: EndReason
    endRule*: EndRule
    stopDetail*: string
    seats*: seq[SeatInfo]

    gameHashValue*: uint64
    hashes*: seq[uint64]
    events*: seq[JsonNode]
    feed*: seq[JsonNode]
    keyframes*: seq[tuple[tick: int32, words: seq[int32]]]

const EventKinds* = [
  "stagestart", "turn", "order", "say", "fallback", "stride", "milestone",
  "fall", "stageend", "budget", "end"]

const BeatKinds* = [
  "stagestart", "milestone", "fall", "stageend", "fallback", "end"]

# ---------------------------------------------------------------------------
#  Seeding
# ---------------------------------------------------------------------------

proc mix64*(a, b, c: int64): uint64 =
  ## splitmix64 over the mixed words — A PURE HASH, never a consumed stream.
  ## Nothing the policy does can shift a draw, reorder draws, or consume one
  ## out from under a later stage, so stage `k`'s start is identical no matter
  ## what happened in stage `k - 1`.
  var z = uint64(a) * 0x9E3779B97F4A7C15'u64
  z = z xor (uint64(b) + 0x165667B19E3779F9'u64)
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = z xor (uint64(c) + 0x27D4EB2F165667C5'u64)
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc perturbFor*(seed: int64, stage, joint: int): int64 =
  ## `(mix64(seed, k, j) mod (2 * InitPerturb + 1)) - InitPerturb`.
  let span = uint64(2 * InitPerturbQ16 + 1)
  int64(mix64(seed, int64(stage), int64(joint)) mod span) - InitPerturbQ16

# ---------------------------------------------------------------------------
#  Construction
# ---------------------------------------------------------------------------

proc ladderMorph*(config: GameConfig, index: int): Morph =
  if index >= 0 and index < config.stageLadder.len: config.stageLadder[index]
  else: mHopper

proc newSimServer*(config: GameConfig): SimServer =
  result = SimServer(
    config: config,
    params: GaitTable,
    phase: phLobby,
    stageIndex: -1,
    reason: endComplete,
    endRule: erLadderComplete,
    activeOrder: defaultOrder(),
    morph: ladderMorph(config, 0))
  result.spec = spec(result.morph)
  for slot in 0 ..< max(1, config.numAgents):
    result.seats.add(SeatInfo(
      name: "", alias: seatAlias(slot), policyLabel: "trotter",
      kind: "scripted", baseline: "trotter"))
  for i in 0 ..< config.stagesPerEpisode:
    result.stages.add(StageRecord(
      morph: ladderMorph(config, i), outcome: soUnreached))

proc seatCount*(sim: SimServer): int = sim.seats.len

proc emit*(sim: SimServer, node: JsonNode) =
  node["t"] = %sim.tick
  sim.events.add(node)

proc drainEvents*(sim: SimServer): JsonNode =
  result = newJArray()
  for node in sim.events:
    result.add(node)
  sim.events.setLen(0)

# ---------------------------------------------------------------------------
#  The hash chain
# ---------------------------------------------------------------------------

proc mixHash(value: var uint64, word: int64) {.inline.} =
  value = (value xor uint64(word)) * 0x100000001B3'u64
  value = value xor (value shr 29)

proc computeGameHash*(sim: SimServer): uint64 =
  ## Mixes, in this FIXED order: tick, phase, stageIndex, stageTick, resetTick,
  ## cyclePos; then every link's x, y, a, vx, vy, w in LINK INDEX ORDER; then
  ## xStart, bestX, uprightTicks, ctrlCostAccum, saturatedTicks, strideCount;
  ## then the three stageOutcome codes and the three stageReturnMicro values;
  ## then totalReturnMicro and falls. It never mixes FX, feed text, `say`,
  ## `notes` or policy labels, so a cosmetic change can never invalidate a
  ## recorded episode and a physics change always does.
  result = 0xCBF29CE484222325'u64
  result.mixHash(int64(sim.tick))
  result.mixHash(int64(ord(sim.phase)))
  result.mixHash(int64(sim.stageIndex))
  result.mixHash(int64(sim.stageTick))
  result.mixHash(int64(sim.resetTick))
  result.mixHash(int64(sim.cyclePos))
  for i in 0 ..< sim.spec.linkCount:
    let l = sim.body.links[i]
    result.mixHash(l.x)
    result.mixHash(l.y)
    result.mixHash(l.a)
    result.mixHash(l.vx)
    result.mixHash(l.vy)
    result.mixHash(l.w)
  result.mixHash(sim.xStart)
  result.mixHash(sim.bestX)
  result.mixHash(int64(sim.uprightTicks))
  result.mixHash(sim.ctrlCostAccum)
  result.mixHash(int64(sim.saturatedTicks))
  result.mixHash(int64(sim.strideCount))
  for record in sim.stages:
    result.mixHash(int64(ord(record.outcome)))
  for record in sim.stages:
    result.mixHash(record.returnMicro)
  result.mixHash(sim.totalReturnMicro)
  result.mixHash(int64(sim.falls))

proc gameHash*(sim: SimServer): uint64 = sim.gameHashValue

# ---------------------------------------------------------------------------
#  State keyframes
# ---------------------------------------------------------------------------

proc keyframeWords*(sim: SimServer): seq[int32] =
  ## The full link state (`x, y, a, vx, vy, w` per link), Q16 narrowed to
  ## `int32` with a range assert. 32 keyframes x 7 links x 6 x 4 B = 5.4 KB.
  result = @[]
  for i in 0 ..< sim.spec.linkCount:
    let l = sim.body.links[i]
    for value in [l.x, l.y, l.a, l.vx, l.vy, l.w]:
      if value < low(int32) or value > high(int32):
        raise newException(SimGuardError,
          "keyframe word " & $value & " does not fit int32")
      result.add(int32(value))

proc pushKeyframe(sim: SimServer) =
  sim.keyframes.add((int32(sim.tick), sim.keyframeWords()))

proc restoreKeyframe*(sim: SimServer, words: openArray[int32]) =
  var k = 0
  for i in 0 ..< sim.spec.linkCount:
    sim.body.links[i].x = int64(words[k]); inc k
    sim.body.links[i].y = int64(words[k]); inc k
    sim.body.links[i].a = int64(words[k]); inc k
    sim.body.links[i].vx = int64(words[k]); inc k
    sim.body.links[i].vy = int64(words[k]); inc k
    sim.body.links[i].w = int64(words[k]); inc k

# ---------------------------------------------------------------------------
#  Stages
# ---------------------------------------------------------------------------

proc microMetres*(q: int64): int64 {.inline.} =
  (q * 1_000_000'i64) div OneQ16

proc buildStartPose*(seed: int64, stage: int, morph: Morph,
                     perturb: var array[MaxJoints, int32]): BodyState =
  ## Every link is placed from the neutral pose, every joint angle is offset by
  ## the seeded perturbation, the chain is re-derived forward from the torso so
  ## the joints are exactly satisfied at t = 0, and the body is dropped with the
  ## lowest contact point exactly on `y = 0` and `torso.x = 0`.
  let s = spec(morph)
  var q: array[MaxJoints, int64]
  for j in 0 ..< s.jointCount:
    let offset = perturbFor(seed, stage, j)
    perturb[j] = int32(offset)
    q[j] = clampQ(offset, s.joints[j].limitLo, s.joints[j].limitHi)
  for j in s.jointCount ..< MaxJoints:
    perturb[j] = 0
  result.links[0].a = s.rootAngle
  result.links[0].x = 0
  result.links[0].y = 0
  result.forwardKinematics(s, q)
  let low = result.lowestPoint(s)
  result.translate(s, -result.links[0].x, -low)

proc closeStageTurns(sim: SimServer) =
  ## `stageTurns` keeps counting through the stage's RESET HOLD, because turn
  ## boundaries live on the global tick grid and are never re-aligned: the turn
  ## issued at tick 216 belongs to the stage that fell at tick 213. The count
  ## is therefore banked when the NEXT stage starts (or when the episode
  ## settles), not when the stage resolves — which is what makes
  ## `sum(stageTurns) == turnsPlayed` (§Server, identity 2) true.
  if sim.stageIndex >= 0 and sim.stageIndex < sim.stages.len:
    sim.stages[sim.stageIndex].turns = int32(sim.stageTurns)

proc startStage*(sim: SimServer, index: int) =
  ## The first tick of stage `index`: build the body from `MorphTable`, place it
  ## in the neutral pose with the seeded perturbation, zero every velocity,
  ## reset `cyclePos`, `xStart := 0`, emit `stagestart`.
  sim.closeStageTurns()
  sim.stageIndex = index
  sim.morph = ladderMorph(sim.config, index)
  sim.spec = spec(sim.morph)
  var perturb: array[MaxJoints, int32]
  sim.body = buildStartPose(sim.config.seed, index, sim.morph, perturb)
  sim.cyclePos = 0
  sim.stageTick = 0
  sim.resetTick = 0
  sim.stageTurns = 0
  sim.xStart = sim.body.links[0].x
  sim.bestX = sim.body.links[0].x
  sim.uprightTicks = 0
  sim.ctrlCostAccum = 0
  sim.saturatedTicks = 0
  sim.strideCount = 0
  sim.airborneTicks = 0
  sim.footstrikes = 0
  sim.peakSpeedMicro = 0
  sim.lastMilestone = 0
  sim.turnStartX = sim.xStart
  sim.turnStartReturn = sim.totalReturnMicro
  for f in 0 ..< MaxFeet:
    sim.footWasDown[f] = false
  sim.phase = phPlaying
  sim.activeOrder = defaultOrder()
  sim.haveOrder = false
  var record = sim.stages[index]
  record.morph = sim.morph
  record.outcome = soRunning
  record.perturb = perturb
  record.startTick = int32(sim.tick)
  sim.stages[index] = record
  sim.emit(%*{
    "k": "stagestart", "i": index, "of": sim.config.stagesPerEpisode,
    "morph": $sim.morph, "links": sim.spec.linkCount,
    "joints": sim.spec.jointCount,
    "terminatesOnFall": sim.spec.terminates})
  sim.pushKeyframe()

proc stageReturnMicro*(sim: SimServer, index: int): int64 =
  let
    record = sim.stages[index]
    s = spec(record.morph)
    dist = (record.distanceMicro * s.distNum) div s.distDen
    upright = s.uprightPerTick * int64(record.uprightTicks)
  dist + upright - record.ctrlCostMicro

proc resolveStage(sim: SimServer, outcome: StageOutcome, why: FallWhy) =
  var record = sim.stages[sim.stageIndex]
  record.outcome = outcome
  record.why = why
  record.ticksRun = int32(sim.stageTick)
  record.strides = sim.strideCount
  record.saturatedTicks = sim.saturatedTicks
  record.airborneTicks = sim.airborneTicks
  record.footstrikes = sim.footstrikes
  record.peakSpeedMicro = sim.peakSpeedMicro
  record.ctrlCostMicro = sim.ctrlCostAccum div 64
  if outcome == soLined:
    ## Crossing the line is not punished for the ticks it saves.
    record.distanceMicro = 60_000_000'i64
    record.uprightTicks = int32(sim.config.stageTicks)
  else:
    record.distanceMicro = microMetres(sim.body.links[0].x - sim.xStart)
    record.uprightTicks = sim.uprightTicks
  sim.stages[sim.stageIndex] = record
  record.returnMicro = sim.stageReturnMicro(sim.stageIndex)
  sim.stages[sim.stageIndex] = record
  sim.totalReturnMicro += record.returnMicro
  if outcome == soFell:
    inc sim.falls
    sim.turnFell = true
  if outcome == soLined:
    inc sim.stagesLined
  sim.emit(%*{
    "k": "stageend", "i": sim.stageIndex, "outcome": $outcome,
    "distance": record.distanceMicro, "return": record.returnMicro,
    "ticks": int(record.ticksRun), "peakSpeed": record.peakSpeedMicro})
  sim.phase = phStageReset
  sim.resetTick = 0

proc ladderComplete*(sim: SimServer): bool =
  sim.stageIndex + 1 >= sim.config.stagesPerEpisode and
    sim.phase == phStageReset and sim.resetTick >= sim.config.resetTicks

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc beginTurn*(sim: SimServer, order: Order) =
  ## Installs one turn's order. `say` and `notes` are already sanitised on rune
  ## boundaries by the validator; nothing here can lengthen them.
  sim.activeOrder = order
  sim.haveOrder = true
  inc sim.turnsPlayed
  inc sim.stageTurns
  sim.turnStartX = sim.body.links[0].x
  sim.turnStartCycle = sim.cyclePos
  sim.turnStartReturn = sim.totalReturnMicro
  sim.turnSaturated = 0
  sim.turnAirborne = 0
  sim.turnPeakTorque = 0
  sim.turnFell = false
  sim.ordersRepaired += order.repaired
  sim.emit(%*{
    "k": "turn", "n": sim.turnsPlayed, "stage": sim.stageIndex,
    "stageTurn": sim.stageTurns})
  sim.emit(%*{
    "k": "order", "n": sim.turnsPlayed, "gait": $order.gait,
    "cadence": int(order.cadence), "power": int(order.power),
    "lean": int(order.lean), "stride_bias": int(order.strideBias),
    "phase_shift": int(order.phaseShift), "source": $order.source,
    "repaired": order.repaired})
  if order.say.len > 0:
    sim.emit(%*{"k": "say", "text": order.say})
  if order.source == osFallback:
    sim.emit(%*{"k": "fallback", "cause": "fallback"})

proc endTurn*(sim: SimServer, notes: string) =
  ## Records what the seat is told about its own last turn.
  let
    ticks = max(1, sim.config.turnTicks)
    dist = microMetres(sim.body.links[0].x - sim.turnStartX)
    cycles = ((int64(sim.cyclePos) - int64(sim.turnStartCycle)) +
      MicroCycle) mod MicroCycle
  sim.lastReport = TurnReport(
    valid: true,
    distanceMicro: dist,
    meanVxMicro: (dist * int64(TargetFps)) div int64(ticks),
    strideMilli: int32((cycles * 1000'i64) div MicroCycle),
    peakTorquePct: sim.turnPeakTorque,
    saturatedTicks: sim.turnSaturated,
    airborneTicks: sim.turnAirborne,
    fell: sim.turnFell,
    returnDeltaMicro: sim.totalReturnMicro - sim.turnStartReturn,
    repaired: sim.activeOrder.repaired,
    notes: notes)
  sim.emit(%*{
    "k": "stride", "turn": sim.turnsPlayed,
    "distance": dist, "meanVx": sim.lastReport.meanVxMicro,
    "strides": int(sim.lastReport.strideMilli),
    "peakTorquePct": int(sim.turnPeakTorque),
    "saturatedTicks": int(sim.turnSaturated),
    "airborneTicks": int(sim.turnAirborne)})

# ---------------------------------------------------------------------------
#  The tick
# ---------------------------------------------------------------------------

proc assertInvariants(sim: SimServer) =
  ## Step 8. Any link outside the world box, any velocity past its clamp, or
  ## any unwrapped angle is a `fault` end with a partial replay written, never
  ## a silent non-zero exit.
  for i in 0 ..< sim.spec.linkCount:
    let l = sim.body.links[i]
    if l.x < GuardMinXQ16 or l.x > GuardMaxXQ16 or
        l.y < GuardMinYQ16 or l.y > GuardMaxYQ16:
      raise newException(SimGuardError,
        "link " & $i & " left the world box at (" & $l.x & ", " & $l.y & ")")
    if absQ(l.vx) > MaxLinSpeedQ16 or absQ(l.vy) > MaxLinSpeedQ16:
      raise newException(SimGuardError,
        "link " & $i & " exceeded MaxLinSpeed")
    if absQ(l.w) > MaxAngSpeedQ16:
      raise newException(SimGuardError,
        "link " & $i & " exceeded MaxAngSpeed")
    if l.a <= -PiQ16 or l.a > PiQ16:
      raise newException(SimGuardError,
        "link " & $i & " angle " & $l.a & " is outside (-PI, PI]")

proc accountTick(sim: SimServer, forces: TickForces) =
  ## Step 5. `distance`, `bestX`, `uprightTicks`, the control cost, the
  ## saturation count, the stride count and the footstrike FX.
  let torso = sim.body.links[0]
  if torso.x > sim.bestX:
    sim.bestX = torso.x
  if sim.spec.terminates and sim.body.isUnhealthy(sim.spec) == fwNone:
    inc sim.uprightTicks
  var saturated = false
  var peak = 0'i32
  for j in 0 ..< sim.spec.jointCount:
    let cap = max(1'i64, forces.tauCap[j])
    let e = (absQ(forces.tau[j]) * 100'i64) div cap
    sim.ctrlCostAccum += e * e
    if int32(e) > peak:
      peak = int32(e)
    if e >= 100:
      saturated = true
  if peak > sim.turnPeakTorque:
    sim.turnPeakTorque = peak
  if saturated:
    inc sim.saturatedTicks
    inc sim.turnSaturated
  var anyDown = false
  for f in 0 ..< sim.spec.footCount:
    let down = forces.contacts[f]
    if down and not sim.footWasDown[f]:
      inc sim.footstrikes
    sim.footWasDown[f] = down
    if down:
      anyDown = true
  if not anyDown:
    inc sim.airborneTicks
    inc sim.turnAirborne
  let speed = absQ(microMetres(torso.vx))
  if speed > sim.peakSpeedMicro:
    sim.peakSpeedMicro = speed

proc stepTick*(sim: SimServer) =
  ## ONE tick, in the numbered order of §Turn and tick structure. THIS IS THE
  ## WHOLE PHYSICS OF THE GAME and nothing else mutates the world.
  if sim.phase == phGameOver or sim.phase == phLobby:
    return
  ## 1. clocks
  inc sim.tick
  if sim.phase == phStageReset:
    inc sim.resetTick
  else:
    inc sim.stageTick

  ## 2. the stride phase
  var order = sim.activeOrder
  if sim.phase == phStageReset:
    ## The order is forced to `{gait: brake, power: 0}` while the body flops
    ## and settles — the watchable half of a wipeout.
    order = Order(gait: gBrake, cadence: 0, power: 0, lean: 0,
      strideBias: 0, phaseShift: 0, source: order.source)
  let milli = strideMilliHz(sim.spec, int(order.cadence))
  let before = sim.cyclePos
  sim.cyclePos = advanceCycle(sim.cyclePos, milli)
  if sim.cyclePos < before:
    inc sim.strideCount

  ## 3. the driver
  var
    targets: array[MaxJoints, int64]
    kp: array[MaxJoints, int64]
    kd: array[MaxJoints, int64]
  sim.params.driverTargets(sim.spec, order, sim.cyclePos, targets)
  sim.params.driverGains(sim.spec, order, kp, kd)

  ## 4. the physics
  let forces = sim.body.stepBody(sim.spec, targets, kp, kd, int(order.power),
    sim.config.substepsPerTick, sim.config.solverIterations)
  sim.lastForces = forces

  if sim.phase == phPlaying:
    ## 5. accounting
    sim.accountTick(forces)

    ## 6. stage termination, first that fires wins
    var resolved = false
    if sim.body.links[0].x >= TrackLineXQ16:
      sim.resolveStage(soLined, fwNone)
      resolved = true
    else:
      let why = sim.body.isUnhealthy(sim.spec)
      if why != fwNone:
        sim.emit(%*{
          "k": "fall", "stage": sim.stageIndex, "why": $why,
          "x": microMetres(sim.body.links[0].x - sim.xStart)})
        sim.resolveStage(soFell, why)
        resolved = true
      elif sim.stageTick >= sim.config.stageTicks:
        sim.resolveStage(soRan, fwNone)
        resolved = true

    ## 7. milestones
    if not resolved:
      let metres = int32(microMetres(sim.body.links[0].x - sim.xStart) div
        (int64(MilestoneMetres) * 1_000_000'i64))
      if metres > sim.lastMilestone:
        sim.lastMilestone = metres
        sim.emit(%*{
          "k": "milestone", "stage": sim.stageIndex,
          "metres": int(metres) * MilestoneMetres})
  else:
    ## 10. the reset hold, then the next stage (or the end of the ladder)
    if sim.resetTick >= sim.config.resetTicks:
      if sim.stageIndex + 1 < sim.config.stagesPerEpisode:
        sim.startStage(sim.stageIndex + 1)

  ## 8. the invariant guard
  sim.assertInvariants()

  ## 9. the hash chain, and a state keyframe every `stateKeyframeTicks`
  sim.gameHashValue = sim.computeGameHash()
  sim.hashes.add(sim.gameHashValue)
  if sim.config.stateKeyframeTicks > 0 and
      sim.tick mod sim.config.stateKeyframeTicks == 0:
    sim.pushKeyframe()

proc episodeOver*(sim: SimServer): bool =
  sim.phase == phGameOver or sim.ladderComplete() or
    sim.turnsPlayed >= sim.config.maxTurns or
    sim.tick >= sim.config.maxTicks

proc turnDue*(sim: SimServer): bool =
  ## Turn boundaries live on the GLOBAL tick grid and are NEVER re-aligned when
  ## a stage ends early: re-aligning would make the wall-clock budget a
  ## function of how the run went, and the wall clock is what the platform
  ## kills you for.
  sim.phase != phGameOver and sim.tick mod max(1, sim.config.turnTicks) == 0

# ---------------------------------------------------------------------------
#  Scoring and the end
# ---------------------------------------------------------------------------

proc maxReturnMicro*(config: GameConfig): int64 =
  ## The theoretical maximum: 60 m at each stage's points-per-metre, plus the
  ## full upright bonus for every stage that has a health test.
  for i in 0 ..< config.stagesPerEpisode:
    let s = spec(ladderMorph(config, i))
    result += (60_000_000'i64 * s.distNum) div s.distDen
    result += s.uprightPerTick * int64(config.stageTicks)

proc episodeWin*(sim: SimServer): bool =
  sim.totalReturnMicro >= sim.config.par

proc distanceTotalMicro*(sim: SimServer): int64 =
  for record in sim.stages:
    result += record.distanceMicro

proc uprightTicksTotal*(sim: SimServer): int =
  for record in sim.stages:
    result += int(record.uprightTicks)

proc ctrlCostTotalMicro*(sim: SimServer): int64 =
  for record in sim.stages:
    result += record.ctrlCostMicro

proc saturatedTicksTotal*(sim: SimServer): int =
  for record in sim.stages:
    result += int(record.saturatedTicks)

proc settle*(sim: SimServer, reason: EndReason, rule: EndRule, detail = "") =
  ## Ends the episode. Every stage that never started is marked `unreached`
  ## with zero distance, zero return and zero ticks, and the stages that DID
  ## run keep their real results — a deadline episode is still rankable.
  if sim.phase == phGameOver:
    return
  if sim.phase == phPlaying and sim.stageIndex >= 0:
    sim.resolveStage(soRan, fwNone)
  sim.closeStageTurns()
  for i in 0 ..< sim.stages.len:
    if sim.stages[i].outcome in {soRunning, soUnreached}:
      sim.stages[i].outcome = soUnreached
      sim.stages[i].distanceMicro = 0
      sim.stages[i].returnMicro = 0
      sim.stages[i].ticksRun = 0
      sim.stages[i].turns = 0
      sim.stages[i].uprightTicks = 0
      sim.stages[i].ctrlCostMicro = 0
  sim.reason = reason
  sim.endRule = rule
  sim.stopDetail = detail.truncateRunes(MaxStopDetailRunes)
  sim.phase = phGameOver
  sim.emit(%*{
    "k": "end", "reason": $reason, "endRule": $rule,
    "total": sim.totalReturnMicro, "score": sim.totalReturnMicro,
    "stagesLined": sim.stagesLined, "falls": sim.falls})
