## The two published scripted baselines. `trotter` is also the certification
## player and the server-side fallback.
##
## Both emit the SAME order objects an LLM does, through the SAME validator,
## which is what makes the bounded-orders test meaningful and a baseline legal
## by construction. NEITHER ever emits `say` or `notes` — a baseline that
## narrated would make the feed lie about which seats are LLMs.
##
## The six tunables are a `BaselineParams` object, not literals: they are swept
## by `tools/tune_baselines.nim`, pinned in `tools/ci/baseline_tuning.json` and
## asserted by `tests/test_cc_tuning.nim`. THE PHYSICS CONSTANTS ARE NOT SWEPT
## AND ARE NOT TUNABLE: if `trotter` cannot walk, the sweep moves these six
## numbers, not the sim.

import std/strutils
import sim_types, trig, body, driver, sim

type
  Baseline* = enum
    blTrotter = "trotter"
    blPlodder = "plodder"

  BaselineParams* = object
    settleTicks*: int32
    targetVxMicro*: array[3, int32]    ## micro-metres/second per morphology
    rampCadence*: array[3, int32]
    cruiseCadence*: array[3, int32]
    cruisePower*: array[3, int32]
    biasFor*: array[3, int32]

proc defaultBaselineParams*(): BaselineParams =
  ## The sweep's pick (`tools/tune_baselines.nim --sweep`), recorded in
  ## `tools/ci/baseline_tuning.json` and asserted by
  ## `tests/test_cc_tuning.nim`. Morphology order is `[hopper, cheetah,
  ## walker]`, as everywhere else.
  BaselineParams(
    settleTicks: 23,
    targetVxMicro: [1_670_253'i32, 3_213_876, 1_741_081],
    rampCadence: [43'i32, 27, 72],
    cruiseCadence: [82'i32, 77, 65],
    cruisePower: [61'i32, 82, 100],
    biasFor: [-12'i32, 4, -6])

proc parseBaseline*(text: string): Baseline =
  ## A seat that registers with neither field — or never registers at all — is
  ## `trotter` (the starter's "anything unrecognised is the published default"
  ## rule).
  case text.strip().toLowerAscii()
  of "plodder": blPlodder
  else: blTrotter

proc nearFall(sim: SimServer, factor: int): bool =
  ## `|pitch|` above `factor/10` of the fall limit, or the torso within 0.06 m
  ## of the low limit. `false` for a body that cannot fall.
  if not sim.spec.terminates:
    return false
  let pitch = absQ(sim.body.torsoPitch(sim.spec))
  if pitch * 10 > sim.spec.maxPitch * int64(factor):
    return true
  sim.body.links[0].y < sim.spec.lowY + 3_932'i64      ## 0.06 m in Q16

proc meanVxMicro(sim: SimServer): int64 =
  if sim.lastReport.valid: sim.lastReport.meanVxMicro
  else: microMetres(sim.body.links[0].vx)

proc trotterOrder*(params: BaselineParams, sim: SimServer): Order =
  ## The certification player, the per-turn fallback and the default for a seat
  ## that registers with neither env var.
  let m = ord(sim.morph)
  result = defaultOrder()
  result.source = osScripted
  if sim.stageTick < int(params.settleTicks):
    result.gait = gCrouch
    result.cadence = 0
    result.power = 40
    result.lean = 0
    result.strideBias = 0
  elif nearFall(sim, 6):
    result.gait = gBrake
    result.cadence = 25
    result.power = 45
    result.lean = -12
    result.strideBias = 0
  elif meanVxMicro(sim) * 2 < int64(params.targetVxMicro[m]):
    result.gait = gRun
    result.cadence = params.rampCadence[m]
    result.power = 90
    result.lean = 14
    result.strideBias = params.biasFor[m]
  else:
    result.gait = gRun
    result.cadence = params.cruiseCadence[m]
    result.power = params.cruisePower[m]
    result.lean = 8
    result.strideBias = params.biasFor[m]
  ## `phase_shift` is 0 except on the turn the gait changes, where it is 25.
  result.phaseShift = if sim.haveOrder and sim.activeOrder.gait != result.gait:
      25'i32 else: 0'i32

proc plodderOrder*(params: BaselineParams, sim: SimServer): Order =
  ## The floor, and the answer to "did the champion actually tune?". It almost
  ## never falls and it almost never gets anywhere, which is exactly the floor
  ## this benchmark needs.
  result = defaultOrder()
  result.source = osScripted
  if nearFall(sim, 8):
    result.gait = gBrake
    result.cadence = 25
    result.power = 45
    result.lean = -12
    result.strideBias = 0
  else:
    result.gait = gWalk
    result.cadence = 40
    result.power = 55
    result.lean = 4
    result.strideBias = 0
  result.phaseShift = if sim.haveOrder and sim.activeOrder.gait != result.gait:
      25'i32 else: 0'i32

proc scriptedOrder*(params: BaselineParams, sim: SimServer,
                    kind: Baseline): Order =
  case kind
  of blTrotter: trotterOrder(params, sim)
  of blPlodder: plodderOrder(params, sim)

proc scriptedOrder*(sim: SimServer, kind: Baseline): Order =
  scriptedOrder(defaultBaselineParams(), sim, kind)
