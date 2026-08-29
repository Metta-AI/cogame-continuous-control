## Sweeps the gait table's per-joint (amp, phase, trim) and the servo gains,
## and pins the winner.
##
##   nim r --hints:off -d:release --path:src tools/tune_gaits.nim --sweep hopper
##   nim r --hints:off -d:release --path:src tools/tune_gaits.nim --check
##
## `--sweep <morph>` runs the bounded random search plus a local refinement and
## prints the pick; `--check` (what `ci.yml` runs, and what
## `tests/test_cc_tuning.nim` asserts) compares the SHIPPED `GaitTable` against
## `tools/ci/gait_tuning.json` and fails on any difference. The check is the
## cheap half deliberately: re-running the search in CI would spend minutes to
## reproduce a number that is already committed, and the committed number is
## the thing a reviewer needs pinned.
##
## THE OBJECTIVE is the MEAN distance the DRIVER ALONE covers in one stage
## across the operating grid a policy actually sends — cadence 45/60/75 x power
## 60/80 — rather than the single (cadence 60, power 70) sample the design note
## names. Optimising one sample ships a table that works only at that sample
## and falls everywhere else, which makes the game unplayable rather than hard.
##
## THE MORPHOLOGY, SOLVER AND SCORING CONSTANTS ARE NOT SWEPT AND ARE NOT
## TUNABLE. If a body cannot walk, this sweep moves, never the physics.

import std/[json, os, random, strformat, strutils, times]
import cc/[sim, sim_config]

proc runStage(params: GaitParams, morph: Morph, gait: Gait,
              cadence, power, lean, bias: int32, seed: int64):
    tuple[distance: float, outcome: StageOutcome] =
  var config = defaultConfig()
  config.stageLadder = @[morph, morph, morph]
  config.seed = seed
  var sim = newSimServer(config)
  sim.params = params
  sim.phase = phPlaying
  sim.startStage(0)
  sim.activeOrder = Order(gait: gait, cadence: cadence, power: power,
    lean: lean, strideBias: bias, source: osScripted)
  sim.haveOrder = true
  for tick in 0 ..< config.stageTicks:
    sim.stepTick()
    if sim.phase != phPlaying:
      break
  (float(sim.stages[0].distanceMicro) / 1_000_000.0, sim.stages[0].outcome)

proc score(params: GaitParams, morph: Morph): float =
  var total = 0.0
  var n = 0
  for cadence in [45'i32, 60, 75]:
    for power in [60'i32, 80]:
      total += runStage(params, morph, gRun, cadence, power, 0, 0, 42).distance
      inc n
  total / float(n)

proc mutate(params: GaitParams, morph: Morph, rng: var Rand,
            scale: int): GaitParams =
  result = params
  let m = ord(morph)
  var run = result.rows[m][ord(gRun)]
  for j in 0 ..< MaxJoints:
    run.trimMilli[j] = int32(clamp(int(run.trimMilli[j]) +
      rng.rand(-scale .. scale), -1_200, 900))
    run.ampMilli[j] = int32(clamp(int(run.ampMilli[j]) +
      rng.rand(-scale .. scale), 0, 900))
    if rng.rand(0 .. 5) == 0:
      run.phaseMicro[j] = int32(rng.rand(0 .. 7) * 125_000)
  result.rows[m][ord(gRun)] = run
  ## `walk` and `bound` are the same shape at 0.8x and 1.3x the amplitude, so
  ## the sweep tunes ONE row and the ladder of gaits stays coherent.
  var walk = run
  var bound = run
  for j in 0 ..< MaxJoints:
    walk.ampMilli[j] = int32(int(run.ampMilli[j]) * 8 div 10)
    bound.ampMilli[j] = int32(int(run.ampMilli[j]) * 13 div 10)
  result.rows[m][ord(gWalk)] = walk
  result.rows[m][ord(gBound)] = bound
  for j in 0 ..< MaxJoints:
    result.kpMilli[m][j] = int32(clamp(int(result.kpMilli[m][0]) +
      rng.rand(-40_000 .. 40_000), 60_000, 800_000))
    result.kdMilli[m][j] = int32(clamp(int(result.kdMilli[m][0]) +
      rng.rand(-4_000 .. 4_000), 2_000, 60_000))

proc sweep(morph: Morph, rounds: int): GaitParams =
  var rng = initRand(20260829)
  var best = GaitTable
  var bestScore = score(best, morph)
  let started = epochTime()
  echo &"start {morph} {bestScore:.3f}"
  var scale = 160
  for round in 0 ..< rounds:
    var improved = false
    for _ in 0 ..< 200:
      let candidate = mutate(best, morph, rng, scale)
      let value = score(candidate, morph)
      if value > bestScore:
        bestScore = value
        best = candidate
        improved = true
    if not improved:
      scale = max(10, scale div 2)
    echo &"  round {round} scale={scale} best={bestScore:.3f} " &
      &"({epochTime() - started:.0f}s)"
  best

when isMainModule:
  let mode = if paramCount() >= 1: paramStr(1) else: "--check"
  case mode
  of "--sweep":
    let morph = parseMorph(if paramCount() >= 2: paramStr(2) else: "hopper")
    if not morph.ok:
      quit("unknown morphology", 2)
    let rounds = if paramCount() >= 3: parseInt(paramStr(3)) else: 10
    let pick = sweep(morph.morph, rounds)
    echo pretty(gaitTableJson(pick)[$morph.morph])
  of "--report":
    for morph in Morphs:
      for cadence in [30'i32, 45, 60, 75, 90]:
        for power in [55'i32, 70, 85]:
          let r = runStage(GaitTable, morph, gRun, cadence, power, 0, 0, 42)
          echo &"{morph} cadence={cadence} power={power}: " &
            &"{r.distance:.2f} m ({r.outcome})"
  else:
    let pinned = parseFile("tools/ci/gait_tuning.json")["gaits"]
    let shipped = gaitTableJson(GaitTable)
    for morph in Morphs:
      if pinned[$morph] != shipped[$morph]:
        echo "shipped GaitTable differs from tools/ci/gait_tuning.json for ",
          morph
        quit(1)
    echo "gait tuning matches tools/ci/gait_tuning.json"
