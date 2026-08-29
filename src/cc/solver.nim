## The solver: gravity, the PD servo, the three constraint families and the
## fixed `SubstepsPerTick x SolverIterations` loop. This is the only file that
## touches constraint arithmetic.
##
## THERE IS NO CONVERGENCE LOOP ANYWHERE. It is a fixed 10 x 12 = 120 passes per
## tick and it terminates whether or not it has converged — the "degrade, never
## hang" pin applies to the physics as much as to the network.
##
## THERE IS NO SQUARE ROOT. The ground is a single horizontal line so every
## contact normal is exactly `(0, 1)`, and every joint constraint is a 2x2
## linear solve. `isqrtQ16` exists in `src/cc/report.nim` only, and never
## touches hashed state.
##
## NO WARM STARTING. Accumulated constraint impulses are zeroed at the top of
## every substep, so the sim state is exactly the link states plus the stride
## phase and nothing carried in solver internals. That costs a little stability
## and buys an exactly-defined, exactly-hashable state — which is the whole
## reason this repo can ship a wasm re-simulating viewer.
##
## No floating point (grep-enforced, tests/test_cc_sim.nim 13).

import sim_types, trig, body

const
  GravityQ16* = 642_908'i64        ## 9.81 m/s^2
  MaxLinSpeedQ16* = 786_432'i64    ## 12.0 m/s, per component
  MaxAngSpeedQ16* = 2_621_440'i64  ## 40.0 rad/s
  GroundFrictionQ16* = 58_982'i64  ## 0.90, Coulomb
  GroundRestitution* = 0'i64       ## feet do not bounce
  PenetrationSlopQ16* = 33'i64     ## 0.0005 m
  BaumgarteNum* = 1'i64
  BaumgarteDen* = 5'i64
  JointLimitBiasNum* = 1'i64
  JointLimitBiasDen* = 4'i64
  DetEpsQ16* = 4'i64
    ## A 2x2 effective-mass determinant below this skips the constraint for
    ## this pass and is counted; tests/test_cc_sim.nim 5 asserts it never fires
    ## on any legal state.
  MaxImpulseQ16* = 100 * OneQ16
  GroundY* = 0'i64

type
  TickForces* = object
    ## What the accounting layer reads back out of one tick. `tau` is sampled
    ## at the FIRST substep of the tick — one sample per tick per joint, which
    ## is cheap and is what `torque_pct`, `saturated` and the control cost are
    ## computed from.
    tau*: array[MaxJoints, int64]
    tauCap*: array[MaxJoints, int64]
    degenerate*: int32           ## DetEpsQ16 skips this tick
    contacts*: array[MaxFeet, bool]

proc substepDt*(substeps: int): int64 {.inline.} =
  ## Q16 seconds per substep. 65536 div 240 = 273 for the shipped 10 substeps.
  OneQ16 div (int64(TargetFps) * int64(max(1, substeps)))

proc substepRate*(substeps: int): int64 {.inline.} =
  int64(TargetFps) * int64(max(1, substeps))

proc torqueCap*(spec: MorphSpec, j: int, power: int): int64 {.inline.} =
  ## `tauCap[j] = tauMax[m][j] * (40 + 60 * power div 100) div 100`.
  let scale = 40'i64 + (60'i64 * int64(clamp(power, 0, 100))) div 100'i64
  (spec.joints[j].tauMax * scale) div 100'i64

proc applyGravity(body: var BodyState, spec: MorphSpec, dt: int64) =
  for i in 0 ..< spec.linkCount:
    body.links[i].vy -= mulQ(GravityQ16, dt)

proc applyServo(body: var BodyState, spec: MorphSpec,
                target, kp, kd: openArray[int64], power: int,
                dt: int64, forces: var TickForces, sample: bool) =
  for j in 0 ..< spec.jointCount:
    let
      js = spec.joints[j]
      cap = torqueCap(spec, j, power)
      q = body.jointCoord(spec, j)
      rate = body.jointRate(spec, j)
      err = wrapAngle(target[j] - q)
    var tau = mulQ(kp[j], err) - mulQ(kd[j], rate)
    tau = clampQ(tau, -cap, cap)
    if sample:
      forces.tau[j] = tau
      forces.tauCap[j] = cap
    let impulse = mulQ(tau, dt)
    body.links[js.child].w += mulQ(spec.links[js.child].invI, impulse)
    body.links[js.parent].w -= mulQ(spec.links[js.parent].invI, impulse)

proc solveJointPoints(body: var BodyState, spec: MorphSpec, rate: int64,
                      forces: var TickForces) =
  ## Joint point constraints, joint index order. For joint `j` with world
  ## anchors `pA`, `pB` and arms `rA`, `rB`, the 2x2 effective-mass matrix
  ##   K = (invMA + invMB) I2 + invIA skew(rA)^T skew(rA)
  ##                          + invIB skew(rB)^T skew(rB)
  ## is inverted in Q16 with a guarded determinant.
  for j in 0 ..< spec.jointCount:
    let js = spec.joints[j]
    let
      ia = js.parent
      ib = js.child
      la = body.links[ia]
      lb = body.links[ib]
      pa = la.localToWorld(js.pOffX, js.pOffY)
      pb = lb.localToWorld(js.cOffX, js.cOffY)
      rax = pa.x - la.x
      ray = pa.y - la.y
      rbx = pb.x - lb.x
      rby = pb.y - lb.y
      invMa = spec.links[ia].invM
      invMb = spec.links[ib].invM
      invIa = spec.links[ia].invI
      invIb = spec.links[ib].invI
      k00 = invMa + invMb + mulQ(invIa, mulQ(ray, ray)) +
        mulQ(invIb, mulQ(rby, rby))
      k11 = invMa + invMb + mulQ(invIa, mulQ(rax, rax)) +
        mulQ(invIb, mulQ(rbx, rbx))
      k01 = -mulQ(invIa, mulQ(rax, ray)) - mulQ(invIb, mulQ(rbx, rby))
      det = mulQ(k00, k11) - mulQ(k01, k01)
    if det < DetEpsQ16:
      forces.degenerate += 1
      continue
    ## Relative anchor velocity, plus the Baumgarte bias -(1/5) * err / dt.
    let
      vax = la.vx - mulQ(la.w, ray)
      vay = la.vy + mulQ(la.w, rax)
      vbx = lb.vx - mulQ(lb.w, rby)
      vby = lb.vy + mulQ(lb.w, rbx)
      ex = pa.x - pb.x
      ey = pa.y - pb.y
      biasX = (ex * rate * BaumgarteNum) div BaumgarteDen
      biasY = (ey * rate * BaumgarteNum) div BaumgarteDen
      rhsX = -(vax - vbx + biasX)
      rhsY = -(vay - vby + biasY)
      px = divQ(mulQ(k11, rhsX) - mulQ(k01, rhsY), det)
      py = divQ(mulQ(k00, rhsY) - mulQ(k01, rhsX), det)
      impX = clampQ(px, -MaxImpulseQ16, MaxImpulseQ16)
      impY = clampQ(py, -MaxImpulseQ16, MaxImpulseQ16)
    body.links[ia].vx += mulQ(invMa, impX)
    body.links[ia].vy += mulQ(invMa, impY)
    body.links[ia].w += mulQ(invIa, mulQ(rax, impY) - mulQ(ray, impX))
    body.links[ib].vx -= mulQ(invMb, impX)
    body.links[ib].vy -= mulQ(invMb, impY)
    body.links[ib].w -= mulQ(invIb, mulQ(rbx, impY) - mulQ(rby, impX))

proc solveJointLimits(body: var BodyState, spec: MorphSpec, rate: int64,
                      acc: var array[MaxJoints, int64]) =
  ## Inequality constraints on `q` against `[lo, hi]`, with the accumulated
  ## impulse clamped to the correct sign and a `(1/4) * overshoot / dt` bias.
  for j in 0 ..< spec.jointCount:
    let
      js = spec.joints[j]
      q = body.jointCoord(spec, j)
    var
      c = 0'i64
      lower = false
    if q < js.limitLo:
      c = q - js.limitLo
      lower = true
    elif q > js.limitHi:
      c = q - js.limitHi
    else:
      continue
    let
      invIa = spec.links[js.parent].invI
      invIb = spec.links[js.child].invI
      eff = invIa + invIb
    if eff < DetEpsQ16:
      continue
    let
      relRate = body.jointRate(spec, j)
      bias = (c * rate * JointLimitBiasNum) div JointLimitBiasDen
    var lambda = divQ(-(relRate + bias), eff)
    let old = acc[j]
    if lower:
      acc[j] = max(0'i64, old + lambda)
    else:
      acc[j] = min(0'i64, old + lambda)
    acc[j] = clampQ(acc[j], -MaxImpulseQ16, MaxImpulseQ16)
    lambda = acc[j] - old
    body.links[js.child].w += mulQ(invIb, lambda)
    body.links[js.parent].w -= mulQ(invIa, lambda)

proc solveContacts(body: var BodyState, spec: MorphSpec, rate: int64,
                   accN, accT: var array[MaxContacts, int64]) =
  ## Ground contacts in (link index, contact-point index) order. The normal is
  ## exactly `(0, 1)`: non-penetration with restitution 0 and a Baumgarte bias
  ## outside the slop, then a tangential (x) friction impulse clamped to
  ## `+-GroundFriction * accumulatedNormalImpulse`. Feet do not stick and do
  ## not bounce.
  var idx = 0
  for i in 0 ..< spec.linkCount:
    let
      invM = spec.links[i].invM
      invI = spec.links[i].invI
      radius = spec.links[i].r
    for cap in 0 .. 1:
      let slot = idx
      inc idx
      let p = body.contactPoint(spec, i, cap)
      let depth = radius - (p.y - GroundY)
      if depth < -PenetrationSlopQ16:
        continue
      let
        rx = p.x - body.links[i].x
        ry = p.y - body.links[i].y
        vn = body.links[i].vy + mulQ(body.links[i].w, rx)
        effN = invM + mulQ(invI, mulQ(rx, rx))
      if effN < DetEpsQ16:
        continue
      let bias =
        if depth > PenetrationSlopQ16:
          ((depth - PenetrationSlopQ16) * rate * BaumgarteNum) div BaumgarteDen
        else:
          0'i64
      var lambda = divQ(-(vn - bias), effN)
      let oldN = accN[slot]
      accN[slot] = clampQ(max(0'i64, oldN + lambda), 0, MaxImpulseQ16)
      lambda = accN[slot] - oldN
      body.links[i].vy += mulQ(invM, lambda)
      body.links[i].w += mulQ(invI, mulQ(rx, lambda))
      ## Coulomb friction along x, with accumulated-impulse clamping.
      let
        vt = body.links[i].vx - mulQ(body.links[i].w, ry)
        effT = invM + mulQ(invI, mulQ(ry, ry))
      if effT < DetEpsQ16:
        continue
      var lt = divQ(-vt, effT)
      let
        oldT = accT[slot]
        limit = mulQ(GroundFrictionQ16, accN[slot])
      accT[slot] = clampQ(oldT + lt, -limit, limit)
      lt = accT[slot] - oldT
      body.links[i].vx += mulQ(invM, lt)
      body.links[i].w -= mulQ(invI, mulQ(ry, lt))

proc integrate(body: var BodyState, spec: MorphSpec, dt: int64) =
  for i in 0 ..< spec.linkCount:
    body.links[i].x += mulQ(body.links[i].vx, dt)
    body.links[i].y += mulQ(body.links[i].vy, dt)
    body.links[i].a = wrapAngle(body.links[i].a + mulQ(body.links[i].w, dt))

proc clampVelocities(body: var BodyState, spec: MorphSpec) =
  for i in 0 ..< spec.linkCount:
    body.links[i].vx = clampQ(body.links[i].vx, -MaxLinSpeedQ16,
      MaxLinSpeedQ16)
    body.links[i].vy = clampQ(body.links[i].vy, -MaxLinSpeedQ16,
      MaxLinSpeedQ16)
    body.links[i].w = clampQ(body.links[i].w, -MaxAngSpeedQ16, MaxAngSpeedQ16)

proc stepBody*(body: var BodyState, spec: MorphSpec,
               target, kp, kd: openArray[int64], power: int,
               substeps, iterations: int): TickForces =
  ## ONE TICK of physics: `substeps` substeps, each running gravity, the servo,
  ## `iterations` Gauss-Seidel passes over the three constraint families in
  ## this exact order, then integrate and clamp.
  let
    dt = substepDt(substeps)
    rate = substepRate(substeps)
  for s in 0 ..< max(1, substeps):
    var
      limitAcc: array[MaxJoints, int64]
      normalAcc: array[MaxContacts, int64]
      tangentAcc: array[MaxContacts, int64]
    body.applyGravity(spec, dt)
    body.applyServo(spec, target, kp, kd, power, dt, result, s == 0)
    for it in 0 ..< max(1, iterations):
      body.solveJointPoints(spec, rate, result)
      body.solveJointLimits(spec, rate, limitAcc)
      body.solveContacts(spec, rate, normalAcc, tangentAcc)
    body.integrate(spec, dt)
    body.clampVelocities(spec)
  for f in 0 ..< spec.footCount:
    result.contacts[f] = body.footOnGround(spec, f, PenetrationSlopQ16)
