## Sweeps the six `BaselineParams` knobs and pins the winner.
##
##   nim r --hints:off -d:release --path:src tools/tune_baselines.nim --sweep
##   nim r --hints:off -d:release --path:src tools/tune_baselines.nim --check
##
## `--sweep` runs the bounded random search and prints the pick as JSON;
## `--check` (what `ci.yml` runs, and what `tests/test_cc_tuning.nim` asserts)
## compares the SHIPPED `defaultBaselineParams()` against
## `tools/ci/baseline_tuning.json` and fails on any difference. The check is
## the cheap half deliberately: re-running the search in CI would spend
## minutes to reproduce a number that is already committed, and the committed
## number is the thing a reviewer needs pinned.
##
## THE PHYSICS CONSTANTS ARE NOT SWEPT AND ARE NOT TUNABLE. If `trotter` cannot
## walk, the sweep moves these six numbers (or the gait table, via
## `tools/tune_gaits.nim`), never the morphology, the solver or the scoring.

import std/[json, math, os, random, strformat, strutils]
import cc/[sim, sim_config, baselines, directives]

proc paramsJson*(p: BaselineParams): JsonNode =
  var target = newJArray()
  var ramp = newJArray()
  var cruiseC = newJArray()
  var cruiseP = newJArray()
  var bias = newJArray()
  for i in 0 .. 2:
    target.add(%int(p.targetVxMicro[i]))
    ramp.add(%int(p.rampCadence[i]))
    cruiseC.add(%int(p.cruiseCadence[i]))
    cruiseP.add(%int(p.cruisePower[i]))
    bias.add(%int(p.biasFor[i]))
  %*{
    "settleTicks": int(p.settleTicks),
    "targetVxMicro": target,
    "rampCadence": ramp,
    "cruiseCadence": cruiseC,
    "cruisePower": cruiseP,
    "biasFor": bias}

proc runLadder(params: BaselineParams, kind: Baseline, seed: int64,
               ladder: seq[Morph]): tuple[total: float, dist: array[3, float],
                                          falls: int] =
  var config = defaultConfig()
  config.stageLadder = ladder
  config.seed = seed
  var sim = newSimServer(config)
  sim.phase = phPlaying
  sim.startStage(0)
  while not sim.episodeOver():
    if sim.turnDue():
      let order = scriptedOrder(params, sim, kind)
      doAssert order.isBounded(), "a baseline proposed an unbounded order"
      sim.beginTurn(order)
    sim.stepTick()
    if sim.turnDue():
      sim.endTurn("")
  sim.settle(endComplete, erLadderComplete)
  for i, record in sim.stages:
    result.dist[i] = float(record.distanceMicro) / 1_000_000.0
  result.total = float(sim.totalReturnMicro) / 1_000_000.0
  result.falls = sim.falls

const
  Bands = [(6.0, 14.0), (30.0, 58.0), (11.0, 24.0)]
    ## §Decisions → baseline strength: `trotter` covers 6-14 m on the hopper,
    ## 30-58 m on the cheetah and 11-24 m on the walker.
  Seeds = [11'i64, 29, 47, 83, 101]

proc bandPenalty(value: float, band: (float, float)): float =
  if value < band[0]: band[0] - value
  elif value > band[1]: value - band[1]
  else: 0.0

proc score(params: BaselineParams): float =
  var penalty = 0.0
  for seed in Seeds:
    let trotter = runLadder(params, blTrotter, seed,
      @[mHopper, mCheetah, mWalker])
    let plodder = runLadder(params, blPlodder, seed,
      @[mHopper, mCheetah, mWalker])
    for i in 0 .. 2:
      penalty += bandPenalty(trotter.dist[i], Bands[i])
      ## `plodder` must be strictly SHORTER than `trotter` on every morphology.
      if plodder.dist[i] >= trotter.dist[i]:
        penalty += 4.0 + (plodder.dist[i] - trotter.dist[i])
    if trotter.falls > 1:
      penalty += 6.0 * float(trotter.falls - 1)
    if plodder.total < 0.0:
      penalty += 4.0 - plodder.total
    ## `trotter` should straddle par, which is what makes par a bar rather
    ## than a rubber stamp.
    penalty += abs(trotter.total - 45.0) / 10.0
  -penalty

proc mutate(base: BaselineParams, rng: var Rand, scale: int): BaselineParams =
  result = base
  result.settleTicks = int32(clamp(
    int(result.settleTicks) + rng.rand(-4 .. 4), 6, 48))
  for i in 0 .. 2:
    result.targetVxMicro[i] = int32(clamp(
      int(result.targetVxMicro[i]) + rng.rand(-200_000 .. 200_000),
      200_000, 6_000_000))
    result.rampCadence[i] = int32(clamp(
      int(result.rampCadence[i]) + rng.rand(-scale .. scale), 20, 100))
    result.cruiseCadence[i] = int32(clamp(
      int(result.cruiseCadence[i]) + rng.rand(-scale .. scale), 20, 100))
    result.cruisePower[i] = int32(clamp(
      int(result.cruisePower[i]) + rng.rand(-scale .. scale), 20, 100))
    result.biasFor[i] = int32(clamp(
      int(result.biasFor[i]) + rng.rand(-4 .. 4), -30, 30))

proc sweep(rounds: int): BaselineParams =
  var rng = initRand(20260829)
  var best = defaultBaselineParams()
  var bestScore = score(best)
  echo &"start {bestScore:.3f}"
  var scale = 12
  for round in 0 ..< rounds:
    var improved = false
    for _ in 0 ..< 40:
      let candidate = mutate(best, rng, scale)
      let value = score(candidate)
      if value > bestScore:
        bestScore = value
        best = candidate
        improved = true
    if not improved:
      scale = max(2, scale div 2)
    echo &"round {round} scale={scale} score={bestScore:.3f}"
  echo &"BEST {bestScore:.3f}"
  best

when isMainModule:
  let mode = if paramCount() >= 1: paramStr(1) else: "--check"
  case mode
  of "--sweep":
    let rounds = if paramCount() >= 2: parseInt(paramStr(2)) else: 10
    let pick = sweep(rounds)
    echo pretty(paramsJson(pick))
  of "--report":
    let params = defaultBaselineParams()
    for kind in [blTrotter, blPlodder]:
      for seed in Seeds:
        let r = runLadder(params, kind, seed, @[mHopper, mCheetah, mWalker])
        echo &"{kind} seed={seed} total={r.total:.2f} " &
          &"hopper={r.dist[0]:.1f} cheetah={r.dist[1]:.1f} " &
          &"walker={r.dist[2]:.1f} falls={r.falls}"
  else:
    let pinned = parseFile("tools/ci/baseline_tuning.json")
    let shipped = paramsJson(defaultBaselineParams())
    if pinned != shipped:
      echo "shipped BaselineParams differ from tools/ci/baseline_tuning.json"
      echo "shipped: ", shipped
      echo "pinned:  ", pinned
      quit(1)
    echo "baseline tuning matches tools/ci/baseline_tuning.json"
