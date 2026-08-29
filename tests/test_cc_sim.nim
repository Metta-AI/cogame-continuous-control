## Sim unit tests — §Tests 1-14.
##
## Every randomised sweep AGGREGATES into a worst-case value and checks it
## once. `unittest`'s `check` inside a 100 000-iteration loop is the slow half
## of a debug run, and a failure that prints ten thousand identical lines hides
## the one number a reader needs.

import std/[math, os, random, strutils, times, unittest]
import cc/[sim, sim_config, report]
import helpers

const
  Heavy = when defined(release): 1 else: 24
    ## Debug builds carry a range check on every Q16 product and are ~20x
    ## slower, so the randomised sweeps run a twenty-fourth of their iterations
    ## there. CI runs every file in BOTH modes and the RELEASE pass is the one
    ## that covers the full count.
  Ticks = when defined(release): 480 else: 96

suite "fixed-point arithmetic and the committed trig table":
  test "1. mulQ is exact and symmetric under negation":
    var rng = initRand(9001)
    var exact = true
    var symmetric = true
    for _ in 0 ..< 10_000 div Heavy:
      let
        a = int64(rng.rand(-8_000_000 .. 8_000_000))
        b = int64(rng.rand(-8_000_000 .. 8_000_000))
      ## The reference product, computed the long way in int64: both factors
      ## are inside the declared envelopes, so `a * b` never leaves 2^62.
      if mulQ(a, b) != (a * b) div 65_536: exact = false
      ## Symmetry under negation is what `div` buys and `shr` would break.
      if mulQ(a, -b) != -mulQ(a, b): symmetric = false
      if mulQ(-a, b) != -mulQ(a, b): symmetric = false
    check exact
    check symmetric

  test "1b. wrapAngle is idempotent and maps (-3PI, 3PI] into (-PI, PI]":
    var inRange = true
    var idempotent = true
    var a = -3 * PiQ16
    while a <= 3 * PiQ16:
      let w = wrapAngle(a)
      if w <= -PiQ16 or w > PiQ16: inRange = false
      if wrapAngle(w) != w: idempotent = false
      a += 37
    check inRange
    check idempotent
    check wrapAngle(-PiQ16) == PiQ16
    check wrapAngle(PiQ16) == PiQ16

  test "2. no `shr` on a signed value anywhere in the sim":
    var offenders: seq[string] = @[]
    for name in ["sim", "solver", "body", "driver", "gaits", "trig"]:
      let source = stripNimComments(readRepoFile("src/cc/" & name & ".nim"))
      for line in source.splitLines():
        ## `shr` on the UNSIGNED hash mixer is legal and is the only use.
        if " shr " in line and "uint64" notin line and "uint32" notin line and
            "z shr" notin line and "value shr" notin line and
            "state shr" notin line and "seed shr" notin line:
          offenders.add(name & ": " & line.strip())
    check offenders.len == 0

  test "3. every committed trig entry re-derives from math.sin":
    var worst = 0.0
    for k in 0 .. 1024:
      let want = 65536.0 * sin(float(k) * PI / 2048.0)
      worst = max(worst, abs(float(SinQ16Table[k]) - want))
    check worst <= 2.0
    ## odd, 2*PI-periodic, and sin^2 + cos^2 == 1 to within 40 Q16 units
    var odd = true
    var periodic = true
    var worstUnit = 0'i64
    for k in 0 ..< 4096 div Heavy:
      let a = int64(k) * (TwoPiQ16 div 4096) - PiQ16
      if sinQ16(a) != -sinQ16(-a): odd = false
      if sinQ16(a) != sinQ16(a + TwoPiQ16): periodic = false
      let s = sinQ16(a)
      let c = cosQ16(a)
      worstUnit = max(worstUnit, abs(mulQ(s, s) + mulQ(c, c) - OneQ16))
    check odd
    check periodic
    check worstUnit <= 40

suite "kinematics and the solver":
  test "4. forward kinematics closes every joint and lands on the ground":
    var rng = initRand(4242)
    var worstAnchor = 0'i64
    var worstAngle = 0'i64
    for morph in Morphs:
      let s = spec(morph)
      var perturb: array[MaxJoints, int32]
      let neutral = buildStartPose(7, 0, morph, perturb)
      check abs(neutral.lowestPoint(s)) <= 2
      check abs(neutral.links[0].x) <= 2
      for _ in 0 ..< 500 div Heavy:
        var q: array[MaxJoints, int64]
        for j in 0 ..< s.jointCount:
          q[j] = clampQ(int64(rng.rand(-1_200 .. 1_200)) * 100,
            s.joints[j].limitLo, s.joints[j].limitHi)
        var body = BodyState()
        body.links[0].a = s.rootAngle
        body.forwardKinematics(s, q)
        for j in 0 ..< s.jointCount:
          let js = s.joints[j]
          let
            pa = body.links[js.parent].localToWorld(js.pOffX, js.pOffY)
            pb = body.links[js.child].localToWorld(js.cOffX, js.cOffY)
          worstAnchor = max(worstAnchor,
            max(absQ(pa.x - pb.x), absQ(pa.y - pb.y)))
          worstAngle = max(worstAngle,
            absQ(wrapAngle(body.jointCoord(s, j) - q[j])))
    check worstAnchor <= 2
    check worstAngle <= 2

  test "5. solver invariants hold, and the determinant guard never fires":
    var rng = initRand(555)
    var degenerate = 0
    var worstSep = 0'i64
    var worstPen = 0'i64
    for morph in Morphs:
      let s = spec(morph)
      var kp: array[MaxJoints, int64]
      var kd: array[MaxJoints, int64]
      var target: array[MaxJoints, int64]
      for j in 0 ..< MaxJoints:
        let g = GaitTable.servoGains(morph, gRun, j)
        kp[j] = g.kp
        kd[j] = g.kd
      ## (a) 2 000 randomised states per morphology: the 2x2 effective-mass
      ## determinant is NEVER degenerate.
      for _ in 0 ..< 2_000 div Heavy:
        var perturb: array[MaxJoints, int32]
        var body = buildStartPose(int64(rng.rand(1 .. 1_000_000)), 0, morph,
          perturb)
        body.translate(s, 0, int64(rng.rand(0 .. 40_000)))
        for i in 0 ..< s.linkCount:
          body.links[i].vx = int64(rng.rand(-200_000 .. 200_000))
          body.links[i].vy = int64(rng.rand(-200_000 .. 200_000))
          body.links[i].w = int64(rng.rand(-400_000 .. 400_000))
        for j in 0 ..< s.jointCount:
          target[j] = clampQ(int64(rng.rand(-800 .. 800)) * 100,
            s.joints[j].limitLo, s.joints[j].limitHi)
        degenerate += int(body.stepBody(s, target, kp, kd, 70, 10, 12)
          .degenerate)
      ## (b) states the sim ACTUALLY REACHES. The bounds here are MEASURED, not
      ## claimed: 12 Gauss-Seidel passes with no warm starting close a joint to
      ## ~7 mm and a contact to ~21 mm on the cheetah, whose 6.4 kg torso is
      ## eight times its lightest foot. `docs/PHYSICS.md` records the numbers.
      var perturb: array[MaxJoints, int32]
      var body = buildStartPose(42, 0, morph, perturb)
      let order = Order(gait: gRun, cadence: 60, power: 70)
      var cyclePos = 0'i32
      for tick in 0 ..< Ticks div 2:
        cyclePos = advanceCycle(cyclePos, strideMilliHz(s, 60))
        GaitTable.driverTargets(s, order, cyclePos, target)
        discard body.stepBody(s, target, kp, kd, 70, 10, 12)
        for j in 0 ..< s.jointCount:
          let js = s.joints[j]
          let
            pa = body.links[js.parent].localToWorld(js.pOffX, js.pOffY)
            pb = body.links[js.child].localToWorld(js.cOffX, js.cOffY)
          worstSep = max(worstSep, max(absQ(pa.x - pb.x), absQ(pa.y - pb.y)))
        for i in 0 ..< s.linkCount:
          for cap in 0 .. 1:
            let p = body.contactPoint(s, i, cap)
            worstPen = max(worstPen, s.links[i].r - p.y)
    check degenerate == 0
    check worstSep <= 10 * 66          ## 10 mm
    check worstPen <= PenetrationSlopQ16 + 25 * 66   ## slop + 25 mm

  test "6. energy is non-increasing with the servo switched off":
    ## Restitution 0 and Coulomb friction are dissipative, so a body dropped
    ## from its neutral pose with zero torque can only lose energy. A solver
    ## that PUMPS energy fails here.
    for morph in Morphs:
      let s = spec(morph)
      var zero: array[MaxJoints, int64]
      var target: array[MaxJoints, int64]
      var perturb: array[MaxJoints, int32]
      var body = buildStartPose(3, 0, morph, perturb)
      proc energy(b: BodyState): int64 =
        for i in 0 ..< s.linkCount:
          let
            v2 = mulQ(b.links[i].vx, b.links[i].vx) +
                 mulQ(b.links[i].vy, b.links[i].vy)
            w2 = mulQ(b.links[i].w, b.links[i].w)
          result += mulQ(s.links[i].m, v2) div 2
          result += mulQ(s.links[i].inertia, w2) div 2
          result += mulQ(mulQ(s.links[i].m, GravityQ16),
            b.links[i].y + 2 * OneQ16)
      let start = energy(body)
      for tick in 0 ..< Ticks:
        discard body.stepBody(s, target, zero, zero, 0, 10, 12)
      ## a 1 % per second numerical allowance over 20 s
      check energy(body) <= start + start div 5 + 4 * OneQ16

  test "7. no body escapes the world box":
    var rng = initRand(77)
    var escaped = false
    var overSpeed = false
    for morph in Morphs:
      let s = spec(morph)
      var kp: array[MaxJoints, int64]
      var kd: array[MaxJoints, int64]
      var target: array[MaxJoints, int64]
      for j in 0 ..< MaxJoints:
        let g = GaitTable.servoGains(morph, gBound, j)
        kp[j] = g.kp
        kd[j] = g.kd
      for _ in 0 ..< 12 div Heavy + 1:
        var perturb: array[MaxJoints, int32]
        var body = buildStartPose(int64(rng.rand(1 .. 99_999)), 0, morph,
          perturb)
        for tick in 0 ..< Ticks:
          for j in 0 ..< s.jointCount:
            target[j] = clampQ(int64(rng.rand(-900 .. 900)) * 100,
              s.joints[j].limitLo, s.joints[j].limitHi)
          discard body.stepBody(s, target, kp, kd, 100, 10, 12)
          for i in 0 ..< s.linkCount:
            let l = body.links[i]
            if l.x <= -20 * OneQ16 or l.x >= 80 * OneQ16 or
                l.y <= -2 * OneQ16 or l.y >= 20 * OneQ16:
              escaped = true
            if absQ(l.vx) > MaxLinSpeedQ16 or absQ(l.vy) > MaxLinSpeedQ16 or
                absQ(l.w) > MaxAngSpeedQ16:
              overSpeed = true
    check not escaped
    check not overSpeed

suite "the driver":
  test "8. the driver is a pure integer function":
    var deterministic = true
    var inLimits = true
    var constantHold = true
    for morph in Morphs:
      let s = spec(morph)
      for gait in Gaits:
        var a, b: array[MaxJoints, int64]
        let order = Order(gait: gait, cadence: 63, power: 71, lean: 11,
          strideBias: -7, phaseShift: 13)
        GaitTable.driverTargets(s, order, 314_159, a)
        GaitTable.driverTargets(s, order, 314_159, b)
        for j in 0 ..< s.jointCount:
          if a[j] != b[j]: deterministic = false
          if a[j] < s.joints[j].limitLo or a[j] > s.joints[j].limitHi:
            inLimits = false
        if gait in {gStand, gCrouch, gBrake}:
          var c: array[MaxJoints, int64]
          GaitTable.driverTargets(s, order, 777_777, c)
          for j in 0 ..< s.jointCount:
            if c[j] != a[j]: constantHold = false
        if gait == gBrake:
          for j in 0 ..< MaxJoints:
            check GaitTable.servoGains(morph, gBrake, j).kp == 0
            check GaitTable.servoGains(morph, gBrake, j).kd > 0
    check deterministic
    check inLimits
    check constantHold

  test "9. the stride phase advances exactly and phase_shift is a one-shot":
    var exact = true
    for morph in Morphs:
      let s = spec(morph)
      for cadence in [0, 25, 50, 75, 100]:
        let milli = strideMilliHz(s, cadence)
        var pos = 0'i32
        for _ in 0 ..< 24:
          let before = pos
          pos = advanceCycle(pos, milli)
          let step = int32((int64(milli) * 1000'i64) div int64(TargetFps))
          if pos != int32((int64(before) + int64(step)) mod 1_000_000'i64):
            exact = false
        if pos < 0 or pos >= 1_000_000: exact = false
      ## phase_shift = +-50 moves the phase by exactly half a cycle, on the
      ## tick it is applied and never again (it is not inherited).
      var plain, shifted, halfCycle: array[MaxJoints, int64]
      let base = Order(gait: gRun, cadence: 60, power: 70)
      var nudged = base
      nudged.phaseShift = 50
      GaitTable.driverTargets(s, base, 0, plain)
      GaitTable.driverTargets(s, nudged, 0, shifted)
      GaitTable.driverTargets(s, base, 500_000, halfCycle)
      for j in 0 ..< s.jointCount:
        check shifted[j] == halfCycle[j]
    check exact

suite "the tick loop":
  test "10. the numbered resolution order, end to end":
    let config = ladderConfig(@[mHopper, mCheetah, mWalker], 42)
    var sim = newSimServer(config)
    sim.phase = phPlaying
    sim.startStage(0)
    var resetSpans = 0
    while not sim.episodeOver():
      if sim.turnDue():
        sim.beginTurn(defaultOrder())
      let before = sim.phase
      sim.stepTick()
      if before == phPlaying and sim.phase == phStageReset:
        inc resetSpans
        ## a stage that resolves breaks to StageReset for exactly resetTicks
        var held = 0
        ## Bounded: after the LAST stage's hold the sim stays in StageReset
        ## with `ladderComplete()` true — that is the episode's end state, not
        ## a phase it leaves.
        while sim.phase == phStageReset and held <= config.resetTicks and
            not sim.ladderComplete():
          sim.stepTick()
          inc held
        check held == config.resetTicks
      if sim.ladderComplete():
        break
    check resetSpans >= 1
    ## a stage that never started is `unreached` with zero everything
    let short = ladderConfig(@[mHopper, mCheetah, mWalker], 42)
    var early = newSimServer(short)
    early.phase = phPlaying
    early.startStage(0)
    early.settle(endDeadline, erWallClock, "forced")
    check early.stages[1].outcome == soUnreached
    check early.stages[1].distanceMicro == 0
    check early.stages[1].returnMicro == 0
    check early.stages[1].ticksRun == 0

  test "11. fall detection: the cheetah NEVER falls":
    var rng = initRand(1111)
    var cheetahFell = false
    var wrong = 0
    for morph in Morphs:
      let s = spec(morph)
      for _ in 0 ..< 2_000 div Heavy:
        var perturb: array[MaxJoints, int32]
        var body = buildStartPose(int64(rng.rand(1 .. 999_999)), 0, morph,
          perturb)
        body.links[0].y = int64(rng.rand(-40_000 .. 200_000))
        body.links[0].a = wrapAngle(s.rootAngle +
          int64(rng.rand(-200_000 .. 200_000)))
        let why = body.isUnhealthy(s)
        if morph == mCheetah:
          if why != fwNone: cheetahFell = true
        else:
          let
            y = body.links[0].y
            pitch = absQ(body.torsoPitch(s))
          let want =
            if y < s.lowY: fwLow
            elif y > s.highY: fwHigh
            elif pitch > s.maxPitch: fwPitched
            else: fwNone
          if why != want: inc wrong
    check not cheetahFell
    check wrong == 0
    ## The sweep above re-derives `isUnhealthy` from the SAME spec fields it is
    ## testing, so it passes for any values of them. The design note's own
    ## limits are therefore pinned as literals here: hopper `y < 0.70 m` or
    ## `|pitch| > 20 deg`, walker `y` outside `0.80 .. 2.00 m` or
    ## `|pitch| > 57 deg`, cheetah never (design.md, "Falling"). `highY` on the
    ## hopper is the sim's world-box ceiling, which is a guard and not a fall
    ## condition — it is pinned as such.
    proc mmQ(value: int64): int64 = (value * OneQ16) div 1000
    check spec(mHopper).terminates
    check spec(mHopper).lowY == mmQ(700)
    check spec(mHopper).maxPitch == degQ16(20)
    check spec(mHopper).highY == GuardMaxYQ16
    check spec(mWalker).terminates
    check spec(mWalker).lowY == mmQ(800)
    check spec(mWalker).highY == mmQ(2000)
    check spec(mWalker).maxPitch == degQ16(57)
    check not spec(mCheetah).terminates
    ## and each branch fires at its own limit. The hopper's `fwHigh` sits at
    ## 20 m, outside the sweep's sampled band, so it is exercised here rather
    ## than left to a random draw that can never reach it.
    for morph in [mHopper, mWalker]:
      checkpoint($morph)
      let s = spec(morph)
      var perturb: array[MaxJoints, int32]
      var body = buildStartPose(4242, 0, morph, perturb)
      body.links[0].a = wrapAngle(s.rootAngle)
      body.links[0].y = s.lowY - 1
      check body.isUnhealthy(s) == fwLow
      body.links[0].y = s.highY + 1
      check body.isUnhealthy(s) == fwHigh
      body.links[0].y = (s.lowY + s.highY) div 2
      check body.isUnhealthy(s) == fwNone
      body.links[0].a = wrapAngle(s.rootAngle + s.maxPitch + OneQ16 div 100)
      check body.isUnhealthy(s) == fwPitched

  test "12. the line resolves `lined` at exactly 60.000 m":
    let config = ladderConfig(@[mCheetah, mCheetah, mCheetah], 5)
    var sim = newSimServer(config)
    sim.phase = phPlaying
    sim.startStage(0)
    sim.beginTurn(defaultOrder())
    ## teleport the machine past the line and step once
    sim.body.translate(sim.spec, 61 * OneQ16, 0)
    sim.stepTick()
    check sim.stages[0].outcome == soLined
    check sim.stages[0].distanceMicro == 60_000_000
    check sim.stages[0].uprightTicks == int32(config.stageTicks)
    let ticksAtLine = sim.stages[0].ticksRun
    sim.stepTick()
    check sim.stages[0].ticksRun == ticksAtLine

  test "13. no floating point in the hashed sim modules":
    var offenders: seq[string] = @[]
    for name in ["sim", "solver", "body", "driver", "gaits", "trig"]:
      let source = stripNimComments(readRepoFile("src/cc/" & name & ".nim"))
      if "float" in source: offenders.add(name & ": float")
      if "sqrt" in source: offenders.add(name & ": sqrt")
      if "math.sin" in source: offenders.add(name & ": math.sin")
      if "std/math" in source: offenders.add(name & ": std/math")
      for line in source.splitLines():
        ## a float literal is a digit, a dot and a digit
        for i in 1 ..< max(1, line.len - 1):
          if line[i] == '.' and line[i - 1] in {'0' .. '9'} and
              line[i + 1] in {'0' .. '9'}:
            offenders.add(name & ": " & line.strip())
    check offenders.len == 0
    ## and `report.nim` — the ONLY module allowed a decimal — is excluded by
    ## name and is not imported by any of them.
    for name in ["sim", "solver", "body", "driver", "gaits", "trig"]:
      let source = stripNimComments(readRepoFile("src/cc/" & name & ".nim"))
      check "report" notin source

  test "14. a full episode fits the tick budget":
    let config = ladderConfig(@[mHopper, mCheetah, mWalker], 42)
    let started = epochTime()
    let run = runScriptedEpisode(config)
    let elapsed = epochTime() - started
    check run.sim.tick >= 400
    when defined(release):
      check elapsed < 3.0
    else:
      check elapsed < 90.0
