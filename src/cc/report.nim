## The observation builder, the results document and the viewer packet's
## numbers.
##
## THIS IS THE ONLY MODULE ALLOWED TO USE `isqrtQ16` AND THE ONLY MODULE
## ALLOWED TO PRODUCE A DECIMAL STRING. It never writes hashed state, and
## `tests/test_cc_sim.nim` 13 asserts the sim compiles with it excluded.
##
## VIEW COORDINATES are the only coordinates a policy or the chrome ever sees:
## metres, x forward (right), y up, origin at the start line on the ground.
## That is also the sim's own frame — unlike the top-down ctf games this one is
## a SIDE ELEVATION with y up, so there is no y-flip anywhere. Angles reported
## to policies are DEGREES, positive counter-clockwise, and every number shown
## to a policy is rounded to 2 decimals.

import std/[json, math, strutils]
import sim_types, trig, body, solver, gaits, driver, sim

proc isqrtQ16*(value: int64): int64 =
  ## Integer square root of a Q16 value, in Q16. The ONE square root in the
  ## repo, and it is on the reporting path only: the solver is sqrt-free
  ## because the ground is a single horizontal line.
  if value <= 0:
    return 0
  var
    x = value * OneQ16
    r = 1'i64
    shift = 0'i64
  var probe = x
  while probe > 0:
    probe = probe div 4
    shift += 1
  r = 1'i64 shl shift
  while true:
    let next = (r + x div r) div 2
    if next >= r:
      break
    r = next
  while r > 0 and r * r > x:
    dec r
  while (r + 1) * (r + 1) <= x:
    inc r
  r

proc metres*(q: int64): float = float(q) / 65536.0
proc round2*(value: float): float =
  let scaled = value * 100.0
  (if scaled >= 0.0: float(int64(scaled + 0.5))
   else: -float(int64(-scaled + 0.5))) / 100.0
proc round3*(value: float): float =
  let scaled = value * 1000.0
  (if scaled >= 0.0: float(int64(scaled + 0.5))
   else: -float(int64(-scaled + 0.5))) / 1000.0

proc m2*(q: int64): float = round2(metres(q))
proc micro2*(v: int64): float = round2(float(v) / 1_000_000.0)
proc micro3*(v: int64): float = round3(float(v) / 1_000_000.0)
proc degrees*(q: int64): float = round2(float(q) * 180.0 / 205887.0 * 1.0)
proc dps*(q: int64): float = round2(float(q) * 180.0 / 205887.0)

proc pointsPerMetre*(morph: Morph): float =
  let s = spec(morph)
  round2(float(s.distNum) / float(s.distDen))

proc uprightPointsPerSecond*(morph: Morph): float =
  let s = spec(morph)
  round3(float(s.uprightPerTick * int64(TargetFps)) / 1_000_000.0)

proc torquePct*(sim: SimServer, j: int): int =
  let cap = max(1'i64, sim.lastForces.tauCap[j])
  int(min(100'i64, (absQ(sim.lastForces.tau[j]) * 100'i64) div cap))

proc strideHz*(sim: SimServer): float =
  round2(float(strideMilliHz(sim.spec, int(sim.activeOrder.cadence))) / 1000.0)

proc cyclePct*(sim: SimServer): int =
  int((int64(sim.cyclePos) * 100'i64) div MicroCycle)

proc bodyJson*(sim: SimServer): JsonNode =
  var joints = newJArray()
  for j in 0 ..< sim.spec.jointCount:
    let js = sim.spec.joints[j]
    joints.add(%*{
      "j": j, "name": js.name,
      "angle_deg": degrees(sim.body.jointCoord(sim.spec, j)),
      "rate_dps": dps(sim.body.jointRate(sim.spec, j)),
      "limit_deg": [degrees(js.limitLo), degrees(js.limitHi)],
      "torque_pct": sim.torquePct(j),
      "saturated": sim.torquePct(j) >= 100})
  var feet = newJArray()
  for f in 0 ..< sim.spec.footCount:
    let idx = sim.spec.feet[f]
    feet.add(%*{
      "f": f, "name": sim.spec.footNames[f],
      "on_ground": sim.body.footOnGround(sim.spec, f, PenetrationSlopQ16),
      "x_m": m2(sim.body.links[idx].x),
      "slip_m_s": m2(sim.body.footSlip(sim.spec, f))})
  let torso = sim.body.links[0]
  ## The per-joint array is `joints` — the key the design note's own
  ## observation example iterates. The note also shows a scalar `"joints": 6`
  ## in the same object, which is not constructible JSON; the COUNT keeps a key
  ## of its own so both readings are available.
  %*{
    "links": sim.spec.linkCount,
    "joint_count": sim.spec.jointCount,
    "torso": {
      "height_m": m2(torso.y),
      "pitch_deg": degrees(sim.body.torsoPitch(sim.spec)),
      "vx_m_s": m2(torso.vx),
      "vy_m_s": m2(torso.vy),
      "spin_dps": dps(torso.w)},
    "joints": joints,
    "feet": feet}

proc ladderJson*(sim: SimServer): JsonNode =
  result = newJArray()
  for i, record in sim.stages:
    if i < sim.stageIndex:
      result.add(%*{
        "i": i, "morph": $record.morph, "outcome": $record.outcome,
        "distance_m": micro2(record.distanceMicro),
        "return": micro3(record.returnMicro)})
    elif i == sim.stageIndex:
      result.add(%*{"i": i, "morph": $record.morph, "outcome": "running"})
    else:
      result.add(%*{"i": i, "morph": $record.morph, "outcome": "pending"})

proc observationJson*(sim: SimServer, seat: int): JsonNode =
  ## Everything this seat may legitimately know, and nothing else.
  ##
  ## HIDDEN: the episode SEED, the per-joint start perturbation of any stage
  ## that has not started, the gait table's raw amplitude / phase / trim
  ## constants, the servo gains, and the agent's own REAL policy name. Nothing
  ## about identity ever reaches a prompt.
  let
    torso = sim.body.links[0]
    s = sim.spec
    fallText =
      if not s.terminates:
        "this body cannot fall; it just scores badly on its back"
      else:
        "falls below " & $round2(metres(s.lowY)) & " m of torso height or " &
        "past " & $int(degrees(s.maxPitch)) & " degrees of pitch"
  result = %*{
    "you": seatAlias(seat),
    "turn": sim.turnsPlayed + 1,
    "of": sim.config.maxTurns,
    "tick": sim.tick,
    "stage": {
      "index": sim.stageIndex + 1,
      "of": sim.config.stagesPerEpisode,
      "morph": $sim.morph,
      "tick": sim.stageTick,
      "of_ticks": sim.config.stageTicks,
      "turns_left": max(0,
        (sim.config.stageTicks - sim.stageTick) div
        max(1, sim.config.turnTicks)),
      "terminates_on_fall": s.terminates,
      "points_per_metre": pointsPerMetre(sim.morph),
      "upright_points_per_second": uprightPointsPerSecond(sim.morph)},
    "track": {
      "length_m": 60.0,
      "x_m": m2(torso.x),
      "best_x_m": m2(sim.bestX),
      "to_line_m": m2(TrackLineXQ16 - torso.x)},
    "body": sim.bodyJson(),
    "gait_now": {
      "gait": $sim.activeOrder.gait,
      "cadence": int(sim.activeOrder.cadence),
      "power": int(sim.activeOrder.power),
      "lean": int(sim.activeOrder.lean),
      "stride_bias": int(sim.activeOrder.strideBias),
      "phase_shift": int(sim.activeOrder.phaseShift),
      "stride_hz": sim.strideHz(),
      "cycle_pct": sim.cyclePct(),
      "source": $sim.activeOrder.source},
    "gaits": GaitNames,
    "ladder": sim.ladderJson(),
    "totals": {
      "return": micro3(sim.totalReturnMicro),
      "par": micro3(sim.config.par),
      "max": micro3(maxReturnMicro(sim.config))},
    "rules": {
      "cadence": "0-100 -> stride frequency 0.80-4.00 Hz for this body",
      "power": "0-100 -> joint amplitude and torque ceiling " &
        "(ceiling = 40% + 60% x power)",
      "lean": "-50..+50 -> pitch the whole body back / forward",
      "stride_bias": "-50..+50 -> shift amplitude from the back leg to the " &
        "front leg",
      "phase_shift": "-50..+50 -> advance / retard the stride phase, in " &
        "percent of one cycle",
      "fall": fallText,
      "order_lasts": $sim.config.turnTicks & " ticks (" &
        $round2(float(sim.config.turnTicks) / float(TargetFps)) &
        " s), executed " & $(TargetFps * sim.config.substepsPerTick) &
        " times a second by the driver"}}
  if sim.lastReport.valid:
    result["last_turn"] = %*{
      "distance_m": micro2(sim.lastReport.distanceMicro),
      "mean_vx_m_s": micro2(sim.lastReport.meanVxMicro),
      "strides": round2(float(sim.lastReport.strideMilli) / 1000.0),
      "peak_torque_pct": int(sim.lastReport.peakTorquePct),
      "saturated_ticks": int(sim.lastReport.saturatedTicks),
      "airborne_ticks": int(sim.lastReport.airborneTicks),
      "fell": sim.lastReport.fell,
      "return_delta": micro3(sim.lastReport.returnDeltaMicro),
      "repaired": sim.lastReport.repaired,
      "notes": sim.lastReport.notes}
  else:
    result["last_turn"] = newJNull()

# ---------------------------------------------------------------------------
#  Results
# ---------------------------------------------------------------------------

const ResultsKeys* = [
  "names", "aliases", "scores", "win", "winner", "reason", "endRule",
  "variant", "seed", "stageCount", "stageTicks", "par", "maxReturn",
  "totalReturn", "stageMorph", "stageOutcome", "stageDistance", "stageReturn",
  "stageTicksRun", "stageTurns", "stageUprightTicks", "stageCtrlCost",
  "stagePeakSpeed", "stageStrides", "stagesLined", "distanceTotal",
  "uprightTicksTotal", "ctrlCostTotal", "falls", "saturatedTicks",
  "finalTick", "turnsPlayed", "ordersRepaired", "policyKinds", "llmTurns",
  "fallbackTurns", "deadSeats", "stopDetail"]

proc ladderResultsJson*(sim: SimServer): JsonNode =
  ## The CLOSED results schema. Adding a key means updating this proc, the
  ## manifest's `results_schema` and `tools/ci/docker_smoke.sh`'s expected-key
  ## set in the same commit — Coworld schemas are closed and undeclared keys
  ## are dropped.
  var
    names = newJArray()
    aliases = newJArray()
    policyKinds = newJArray()
    deadSeats = newJArray()
    llmTurns = 0
    fallbackTurns = 0
  for seat in sim.seats:
    names.add(%(if seat.name.len > 0: seat.name else: seat.policyLabel))
    aliases.add(%seat.alias)
    policyKinds.add(%seat.kind)
    deadSeats.add(%seat.dead)
    llmTurns += seat.llmTurns
    fallbackTurns += seat.fallbackTurns
  var
    morphs = newJArray()
    outcomes = newJArray()
    distances = newJArray()
    returns = newJArray()
    ticksRun = newJArray()
    turns = newJArray()
    upright = newJArray()
    ctrl = newJArray()
    peak = newJArray()
    strides = newJArray()
  for record in sim.stages:
    morphs.add(%($record.morph))
    outcomes.add(%($(if record.outcome == soRunning: soUnreached
                     else: record.outcome)))
    distances.add(%micro3(record.distanceMicro))
    returns.add(%micro3(record.returnMicro))
    ticksRun.add(%int(record.ticksRun))
    turns.add(%int(record.turns))
    upright.add(%int(record.uprightTicks))
    ctrl.add(%micro3(record.ctrlCostMicro))
    peak.add(%micro2(record.peakSpeedMicro))
    strides.add(%int(record.strides))
  result = %*{
    "names": names,
    "aliases": aliases,
    "scores": [micro3(sim.totalReturnMicro)],
    "win": [sim.episodeWin()],
    "winner": (if sim.episodeWin(): %0 else: newJNull()),
    "reason": $sim.reason,
    "endRule": $sim.endRule,
    "variant": sim.config.variant,
    "seed": sim.config.seed,
    "stageCount": sim.config.stagesPerEpisode,
    "stageTicks": sim.config.stageTicks,
    "par": micro3(sim.config.par),
    "maxReturn": micro3(maxReturnMicro(sim.config)),
    "totalReturn": micro3(sim.totalReturnMicro),
    "stageMorph": morphs,
    "stageOutcome": outcomes,
    "stageDistance": distances,
    "stageReturn": returns,
    "stageTicksRun": ticksRun,
    "stageTurns": turns,
    "stageUprightTicks": upright,
    "stageCtrlCost": ctrl,
    "stagePeakSpeed": peak,
    "stageStrides": strides,
    "stagesLined": sim.stagesLined,
    "distanceTotal": micro3(sim.distanceTotalMicro()),
    "uprightTicksTotal": sim.uprightTicksTotal(),
    "ctrlCostTotal": micro3(sim.ctrlCostTotalMicro()),
    "falls": sim.falls,
    "saturatedTicks": sim.saturatedTicksTotal(),
    "finalTick": sim.tick,
    "turnsPlayed": sim.turnsPlayed,
    "ordersRepaired": sim.ordersRepaired,
    "policyKinds": policyKinds,
    "llmTurns": llmTurns,
    "fallbackTurns": fallbackTurns,
    "deadSeats": deadSeats,
    "stopDetail": sim.stopDetail.truncateRunes(MaxStopDetailRunes)}
