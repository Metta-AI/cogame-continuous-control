## The gait table, the six-gait closed enum, the stride-frequency band and the
## servo gains.
##
## `GaitTable` is `array[3, array[6, GaitRow]]` — 3 morphologies x 6 gaits x 4
## per-joint arrays. `stand` and `crouch` have all amplitudes zero and differ
## only in trim; `brake` has all amplitudes zero, a `crouch` trim, and sets
## `Kp := 0`, `Kd := KdBrake[m]` so the servo is pure damping.
##
## THE TABLE'S NUMBERS ARE A SWEPT PARAMETER SET, not literals guessed in a
## design note: `tools/tune_gaits.nim` sweeps `(amp, phase, trim, lean, Kp, Kd)`
## per morphology over a bounded grid, scoring each candidate by the distance
## the DRIVER ALONE covers in one stage at cadence 60 / power 70 with no policy
## input; `tools/ci/gait_tuning.json` records the sweep's pick and
## `tests/test_cc_tuning.nim` asserts the shipped table still equals it.
##
## THE MORPHOLOGY, SOLVER AND SCORING CONSTANTS ARE NOT SWEPT AND ARE NOT
## TUNABLE: if the sweep cannot make a body walk, the sweep changes the gait
## table, never the physics.
##
## No floating point (grep-enforced, tests/test_cc_sim.nim 13).

import sim_types, trig, body

type
  GaitRow* = object
    ## Per-joint amplitude, phase, trim and lean response for one
    ## (morphology, gait) pair. Amplitudes and angles are MILLIRADIANS in the
    ## committed table and are converted to Q16 once, at module load;
    ## `phaseMicro` is in micro-cycles of `0 .. 999_999`.
    ampMilli*: array[MaxJoints, int32]
    phaseMicro*: array[MaxJoints, int32]
    trimMilli*: array[MaxJoints, int32]
    leanMilli*: array[MaxJoints, int32]

  GaitParams* = object
    rows*: array[3, array[6, GaitRow]]
    kpMilli*: array[3, array[MaxJoints, int32]]   ## N.m/rad x 1000
    kdMilli*: array[3, array[MaxJoints, int32]]   ## N.m.s/rad x 1000
    kdBrakeMilli*: array[3, int32]

const
  MicroCycle* = 1_000_000'i64
  Half* = 500_000'i32
  Quarter* = 250_000'i32
  ThreeQuarter* = 750_000'i32

proc row(amp, phase, trim, lean: array[MaxJoints, int32]): GaitRow =
  GaitRow(ampMilli: amp, phaseMicro: phase, trimMilli: trim, leanMilli: lean)

const
  Z6: array[MaxJoints, int32] = [0'i32, 0, 0, 0, 0, 0]

  ## ------------------------------------------------------------------------
  ## THE SWEPT PICK. `tools/tune_gaits.nim` searched (trim, amp, phase, Kp, Kd)
  ## per morphology over a bounded grid, scoring each candidate by the MEAN
  ## distance the driver ALONE covers in one stage across the operating grid a
  ## policy actually sends (cadence 45/60/75 x power 60/80) rather than the one
  ## (cadence 60, power 70) sample: optimising a single sample ships a table
  ## that works only at that sample, which makes the game unplayable rather
  ## than hard. `tools/ci/gait_tuning.json` records exactly these numbers and
  ## `tests/test_cc_tuning.nim` asserts the shipped table still equals them.
  ## ------------------------------------------------------------------------

  ## ---- HOPPER: hip, knee, ankle (3 joints; slots 3..5 unused) -----------
  HopTrim: array[MaxJoints, int32] = [-164'i32, -347, 427, 0, 0, 0]
  ## `stand` is the NEUTRAL pose (`q = 0`), which is the one pose a stiff PD
  ## servo genuinely holds; a gait's `trim` is the OSCILLATION CENTRE of a
  ## moving body, not a pose it can stand in, and the two are different numbers
  ## (`tests/test_cc_sim.nim` 8 pins that `stand` is constant, not that it
  ## equals a gait trim).
  HopStandTrim: array[MaxJoints, int32] = [0'i32, 0, 0, 0, 0, 0]
  ## The LOWEST QUIET crouch the sweep found: the deepest pose whose torso
  ## pitch stays under 0.05 rad for 220 ticks at `power 40`, which is what
  ## `trotter`'s settle turn actually sends. A deeper crouch exists and is
  ## survivable, but it ROCKS to within a whisker of the 20-degree fall limit,
  ## which turns the settle turn into the thing that ends the stage.
  ## hip -0.050 rad, knee -0.500 rad, ankle +0.500 rad, torso at 1.14 m.
  HopCrouchTrim: array[MaxJoints, int32] = [-50'i32, -500, 500, 0, 0, 0]
  HopLean: array[MaxJoints, int32] = [-420'i32, 180, -120, 0, 0, 0]
  HopPhase: array[MaxJoints, int32] = [0'i32, 750_000, 0, 0, 0, 0]
  ## The hopper's amplitudes are the sweep's pick RESCALED by 2/3, with the
  ## operating point moved to `power 90` in exchange: `power` scales amplitude
  ## linearly, so (amp * k, power / k) is the same driver, and re-centring it
  ## is what lets `trotter`'s published `power: 90` ramp survive on the one
  ## body that cannot absorb it.
  HopWalkAmp: array[MaxJoints, int32] = [69'i32, 253, 55, 0, 0, 0]
  HopRunAmp: array[MaxJoints, int32] = [86'i32, 316, 69, 0, 0, 0]
  HopBoundAmp: array[MaxJoints, int32] = [112'i32, 411, 90, 0, 0, 0]

  ## ---- CHEETAH: back hip/knee/ankle, front hip/knee/ankle ---------------
  ChTrim: array[MaxJoints, int32] = [-264'i32, -39, 297, -168, 267, 82]
  ChStandTrim: array[MaxJoints, int32] = [0'i32, 0, 0, 0, 0, 0]
  ChCrouchTrim: array[MaxJoints, int32] = [-200'i32, -300, 200, -200, -300, 200]
  ChLean: array[MaxJoints, int32] = [-300'i32, 120, -140, 300, -180, 90]
  ChPhase: array[MaxJoints, int32] =
    [0'i32, 625_000, 0, 750_000, 625_000, 0]
  ChWalkAmp: array[MaxJoints, int32] = [123'i32, 240, 428, 52, 91, 225]
  ChRunAmp: array[MaxJoints, int32] = [154'i32, 301, 535, 66, 114, 282]
  ChBoundAmp: array[MaxJoints, int32] = [200'i32, 391, 695, 85, 148, 366]

  ## ---- WALKER: right hip/knee/ankle, left hip/knee/ankle ----------------
  WkTrim: array[MaxJoints, int32] = [-119'i32, -705, 610, -119, -705, 610]
  WkStandTrim: array[MaxJoints, int32] = [0'i32, 0, 0, 0, 0, 0]
  ## The LOWEST QUIET crouch: knee -0.200 rad, ankle +0.200 rad, torso at
  ## 1.20 m, pitch under 0.03 rad for 220 ticks at `power 40`.
  WkCrouchTrim: array[MaxJoints, int32] =
    [0'i32, -200, 200, 0, -200, 200]
  WkLean: array[MaxJoints, int32] = [-420'i32, 180, -120, -420, 180, -120]
  WkPhase: array[MaxJoints, int32] =
    [0'i32, 250_000, 875_000, 500_000, 750_000, 375_000]
  WkWalkAmp: array[MaxJoints, int32] = [420'i32, 130, 136, 420, 130, 136]
  WkRunAmp: array[MaxJoints, int32] = [525'i32, 162, 170, 525, 162, 170]
  WkBoundAmp: array[MaxJoints, int32] = [682'i32, 211, 221, 682, 211, 221]

proc defaultGaitParams*(): GaitParams =
  ## The shipped pick. `tools/ci/gait_tuning.json` records exactly these
  ## numbers and `tests/test_cc_tuning.nim` asserts they still agree.
  result.rows[ord(mHopper)][ord(gStand)] = row(Z6, Z6, HopStandTrim, HopLean)
  result.rows[ord(mHopper)][ord(gCrouch)] = row(Z6, Z6, HopCrouchTrim, HopLean)
  result.rows[ord(mHopper)][ord(gWalk)] =
    row(HopWalkAmp, HopPhase, HopTrim, HopLean)
  result.rows[ord(mHopper)][ord(gRun)] =
    row(HopRunAmp, HopPhase, HopTrim, HopLean)
  result.rows[ord(mHopper)][ord(gBound)] =
    row(HopBoundAmp, HopPhase, HopTrim, HopLean)
  result.rows[ord(mHopper)][ord(gBrake)] = row(Z6, Z6, HopCrouchTrim, Z6)

  result.rows[ord(mCheetah)][ord(gStand)] = row(Z6, Z6, ChStandTrim, ChLean)
  result.rows[ord(mCheetah)][ord(gCrouch)] = row(Z6, Z6, ChCrouchTrim, ChLean)
  result.rows[ord(mCheetah)][ord(gWalk)] =
    row(ChWalkAmp, ChPhase, ChTrim, ChLean)
  result.rows[ord(mCheetah)][ord(gRun)] =
    row(ChRunAmp, ChPhase, ChTrim, ChLean)
  result.rows[ord(mCheetah)][ord(gBound)] =
    row(ChBoundAmp, ChPhase, ChTrim, ChLean)
  result.rows[ord(mCheetah)][ord(gBrake)] = row(Z6, Z6, ChCrouchTrim, Z6)

  result.rows[ord(mWalker)][ord(gStand)] = row(Z6, Z6, WkStandTrim, WkLean)
  result.rows[ord(mWalker)][ord(gCrouch)] = row(Z6, Z6, WkCrouchTrim, WkLean)
  result.rows[ord(mWalker)][ord(gWalk)] =
    row(WkWalkAmp, WkPhase, WkTrim, WkLean)
  result.rows[ord(mWalker)][ord(gRun)] =
    row(WkRunAmp, WkPhase, WkTrim, WkLean)
  result.rows[ord(mWalker)][ord(gBound)] =
    row(WkBoundAmp, WkPhase, WkTrim, WkLean)
  result.rows[ord(mWalker)][ord(gBrake)] = row(Z6, Z6, WkCrouchTrim, Z6)

  for j in 0 ..< MaxJoints:
    result.kpMilli[ord(mHopper)][j] = 573_331
    result.kdMilli[ord(mHopper)][j] = 13_828
    result.kpMilli[ord(mCheetah)][j] = 372_510
    result.kdMilli[ord(mCheetah)][j] = 14_442
    result.kpMilli[ord(mWalker)][j] = 575_094
    result.kdMilli[ord(mWalker)][j] = 6_817
  result.kdBrakeMilli[ord(mHopper)] = 24_000
  result.kdBrakeMilli[ord(mCheetah)] = 24_000
  result.kdBrakeMilli[ord(mWalker)] = 24_000

let GaitTable* = defaultGaitParams()
  ## The ONE committed gait table. Written into every replay's config JSON.

proc milliToQ16*(value: int32): int64 {.inline.} =
  (int64(value) * OneQ16) div 1000'i64

proc strideMilliHz*(spec: MorphSpec, cadence: int): int32 =
  ## `FreqMin + (FreqMax - FreqMin) * cadence div 100`, in milli-hertz.
  let c = int32(clamp(cadence, 0, 100))
  spec.freqMinMilliHz +
    ((spec.freqMaxMilliHz - spec.freqMinMilliHz) * c) div 100'i32

proc advanceCycle*(cyclePos: int32, milliHz: int32): int32 =
  ## `cyclePos := (cyclePos + strideMilliHz * 1000 div TargetFps) mod 1e6`.
  ## Integer division truncates; the advance is therefore a pure function of
  ## `cadence` and the morphology.
  let step = int32((int64(milliHz) * 1000'i64) div int64(TargetFps))
  int32((int64(cyclePos) + int64(step)) mod MicroCycle)

proc gaitRow*(params: GaitParams, morph: Morph, gait: Gait): GaitRow {.inline.} =
  params.rows[ord(morph)][ord(gait)]

proc servoGains*(params: GaitParams, morph: Morph, gait: Gait, j: int):
    tuple[kp, kd: int64] =
  ## `brake` sets `Kp = 0` and `Kd = KdBrake[m]` so the servo is pure damping.
  if gait == gBrake:
    (0'i64, milliToQ16(params.kdBrakeMilli[ord(morph)]))
  else:
    (milliToQ16(params.kpMilli[ord(morph)][j]),
     milliToQ16(params.kdMilli[ord(morph)][j]))
