## The driver: the deterministic, integer-only central pattern generator that
## turns ONE gait order into per-joint target angles, every tick, 240 times a
## second through the PD servo underneath it.
##
## UNLIKE THE STARTER'S `src/ctf/control.nim`, THIS DRIVER SITS INSIDE THE
## DETERMINISM BOUNDARY: it is integer-only, it is hashed, and it is re-run
## identically in the browser. That is the one structural change this fork
## makes to ctf's architecture, and the reason is arithmetic — the action here
## is one order per 36 ticks (42 records, ~8 KB) rather than one byte per tick,
## so re-deriving the per-tick targets is what keeps the replay at 32 KB
## instead of 1 MB.
##
## The driver never invents a value the schema does not express and holds NO
## memory across ticks except `cyclePos`, which is hashed.
##
## No floating point (grep-enforced, tests/test_cc_sim.nim 13).

import sim_types, trig, body, gaits

type
  Order* = object
    ## One turn's gait order. The clamped form of this object is the game's
    ## ENTIRE input log.
    gait*: Gait
    cadence*: int32          ## 0 .. 100
    power*: int32            ## 0 .. 100
    lean*: int32             ## -50 .. +50
    strideBias*: int32       ## -50 .. +50
    phaseShift*: int32       ## -50 .. +50, a ONE-OFF nudge
    say*: string
    notes*: string
    source*: OrderSource
    latencyMs*: int
    repaired*: int

proc defaultOrder*(): Order =
  ## The floor every repair path lands on: the stage's first-turn defaults.
  Order(gait: gWalk, cadence: 50, power: 60, lean: 0, strideBias: 0,
        phaseShift: 0, source: osScripted)

proc driverTargets*(params: GaitParams, spec: MorphSpec, order: Order,
                    cyclePos: int32, targets: var array[MaxJoints, int64]) =
  ## The six-step order -> per-joint-target formula of §Decisions → the driver.
  ## Every operation is `int64` with `div`, never `shr`.
  let g = params.gaitRow(spec.morph, order.gait)
  for j in 0 ..< spec.jointCount:
    ## 1. the joint's own phase within the stride cycle
    let cycle = ((int64(cyclePos) + int64(order.phaseShift) * 10_000'i64 +
      int64(g.phaseMicro[j])) mod MicroCycle + MicroCycle) mod MicroCycle
    ## 2. the stride-bias side scale: -1 on the back/right leg, +1 on the
    ##    front/left leg, 0 on the torso and on a single-legged body.
    let sideScale = 100'i64 +
      int64(order.strideBias) * int64(spec.joints[j].side)
    ## 3. amplitude, scaled by power and by the side bias
    let amp = (milliToQ16(g.ampMilli[j]) * int64(order.power) div 100'i64) *
      sideScale div 100'i64
    ## 4. the lean response
    let leanNow = milliToQ16(g.leanMilli[j]) * int64(order.lean) div 50'i64
    ## 5. trim + lean + amplitude * sin(phase)
    let angle = (cycle * TwoPiQ16) div MicroCycle
    var target = milliToQ16(g.trimMilli[j]) + leanNow +
      mulQ(amp, sinQ16(angle))
    ## 6. clamp into the joint's own limits
    targets[j] = clampQ(target, spec.joints[j].limitLo, spec.joints[j].limitHi)
  for j in spec.jointCount ..< MaxJoints:
    targets[j] = 0

proc driverGains*(params: GaitParams, spec: MorphSpec, order: Order,
                  kp, kd: var array[MaxJoints, int64]) =
  for j in 0 ..< MaxJoints:
    let g = params.servoGains(spec.morph, order.gait, j)
    kp[j] = g.kp
    kd[j] = g.kd
