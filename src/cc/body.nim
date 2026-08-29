## The three planar bodies: the committed `MorphTable`, the neutral poses, the
## derived inertias, forward kinematics down the kinematic chain, the contact
## points and the per-morphology health test.
##
## A body is a set of CAPSULE LINKS (a segment of half-length `hl` with radius
## `r`) connected by HINGE JOINTS, all in the plane. There is no self-collision,
## no joint friction beyond the servo's damping, and no aerodynamic drag.
##
## LOCAL FRAME CONVENTION, one sentence, because everything else follows from
## it: a link's local +y is its PROXIMAL end and it extends toward local -y, so
## a link at absolute angle 0 hangs straight DOWN from its own anchor. A point
## at local `(lx, ly)` maps to world
## `(x + lx*cos a - ly*sin a, y + lx*sin a + ly*cos a)`.
##
## Every joint carries a MOUNT angle — the structural rotation between parent
## and child at the model's reference pose — so the joint coordinate `q` that
## limits, targets and the observation all speak is
## `q = wrap(child.a - parent.a - mount)`, with `q = 0` the neutral pose. That
## is MuJoCo's own convention and it is why the design note's joint ranges
## (which are all quoted about a neutral standing/prone pose) can be used
## verbatim.
##
## No floating point (grep-enforced, tests/test_cc_sim.nim 13).

import sim_types, trig

type
  Link* = object
    ## One capsule link's dynamical state. Every field is Q16 `int64`.
    x*, y*: int64            ## centre, metres
    a*: int64                ## absolute angle, radians, wrapped to (-PI, PI]
    vx*, vy*: int64          ## metres/second
    w*: int64                ## radians/second

  LinkSpec* = object
    name*: string
    hl*: int64               ## half-length, Q16 metres
    r*: int64                ## radius, Q16 metres
    m*: int64                ## mass, Q16 kg
    invM*: int64
    invI*: int64
    inertia*: int64

  JointSpec* = object
    name*: string
    parent*: int
    child*: int
    pOffX*, pOffY*: int64    ## anchor in the PARENT's local frame, Q16 m
    cOffX*, cOffY*: int64    ## anchor in the CHILD's local frame, Q16 m
    mount*: int64            ## structural rotation, Q16 radians
    limitLo*, limitHi*: int64  ## joint coordinate limits, Q16 radians
    tauMax*: int64           ## N.m, Q16
    side*: int32             ## -1 back/right leg, +1 front/left leg, 0 torso

  MorphSpec* = object
    morph*: Morph
    linkCount*: int
    jointCount*: int
    footCount*: int
    links*: array[MaxLinks, LinkSpec]
    joints*: array[MaxJoints, JointSpec]
    feet*: array[MaxFeet, int]        ## link index of each foot
    footNames*: array[MaxFeet, string]
    rootAngle*: int64                 ## the torso's absolute neutral angle
    terminates*: bool                 ## does an unhealthy state end the stage
    lowY*, highY*: int64              ## torso-centre health band, Q16 m
    maxPitch*: int64                  ## |pitch| health limit, Q16 radians
    distNum*, distDen*: int64         ## points per metre
    uprightPerTick*: int64            ## micro-points per upright tick
    freqMinMilliHz*, freqMaxMilliHz*: int32

  BodyState* = object
    ## The whole dynamical state of one machine. `links` is fixed-size so
    ## nothing allocates inside the step loop.
    links*: array[MaxLinks, Link]

const
  ## Q16 metre/kilogram helpers for the committed tables. Written as
  ## milli-units so the table reads like the design note's own numbers.
  MilliQ16 = 65'i64             ## unused directly; see `mm` / `g` below

proc mm(value: int64): int64 {.inline.} =
  ## `value` in millimetres as Q16 metres.
  (value * OneQ16) div 1000

proc gram(value: int64): int64 {.inline.} =
  ## `value` in grams as Q16 kilograms.
  (value * OneQ16) div 1000

proc link(name: string, hlMm, rMm, mG: int64): LinkSpec =
  result.name = name
  result.hl = mm(hlMm)
  result.r = mm(rMm)
  result.m = gram(mG)
  ## I = m * (hl^2 / 3 + r^2 / 4) about the link centre, in Q16.
  let
    hl2 = mulQ(result.hl, result.hl)
    r2 = mulQ(result.r, result.r)
  result.inertia = mulQ(result.m, hl2 div 3 + r2 div 4)
  result.invM = divQ(OneQ16, result.m)
  result.invI = divQ(OneQ16, max(1'i64, result.inertia))

proc joint(name: string, parent, child: int, pOffX, pOffY, cOffX, cOffY,
           mountDeg, loDeg, hiDeg, tauMax: int64, side: int32): JointSpec =
  JointSpec(
    name: name, parent: parent, child: child,
    pOffX: pOffX, pOffY: pOffY, cOffX: cOffX, cOffY: cOffY,
    mount: degQ16(mountDeg),
    limitLo: degQ16(loDeg), limitHi: degQ16(hiDeg),
    tauMax: tauMax * OneQ16, side: side)

proc buildHopper(): MorphSpec =
  ## HOPPER — 4 links, 3 joints, 2 foot contact points. Total mass 15.49 kg.
  result.morph = mHopper
  result.linkCount = 4
  result.jointCount = 3
  result.footCount = 1
  result.links[0] = link("torso", 200, 50, 3530)
  result.links[1] = link("thigh", 225, 50, 3930)
  result.links[2] = link("shin", 250, 40, 2710)
  result.links[3] = link("foot", 195, 60, 5320)
  result.joints[0] = joint("hip", 0, 1, 0, -mm(200), 0, mm(225),
    0, -150, 0, 200, 0)
  result.joints[1] = joint("knee", 1, 2, 0, -mm(225), 0, mm(250),
    0, -150, 0, 200, 0)
  result.joints[2] = joint("ankle", 2, 3, 0, -mm(250), 0, mm(195),
    90, -45, 45, 200, 0)
  result.feet[0] = 3
  result.footNames[0] = "foot"
  result.rootAngle = 0
  result.terminates = true
  result.lowY = mm(700)
  result.highY = mm(4000)
  result.maxPitch = degQ16(20)
  result.distNum = 2
  result.distDen = 1
  result.uprightPerTick = 4_000
  result.freqMinMilliHz = 800
  result.freqMaxMilliHz = 4000

proc buildCheetah(): MorphSpec =
  ## CHEETAH — 7 links, 6 joints, 4 foot contact points. Total mass 14.11 kg.
  ## It CANNOT fall, for the same reason `HalfCheetah-v5` has no termination:
  ## it has no upright posture to lose.
  result.morph = mCheetah
  result.linkCount = 7
  result.jointCount = 6
  result.footCount = 2
  result.links[0] = link("torso", 500, 46, 6360)
  result.links[1] = link("bthigh", 145, 46, 1540)
  result.links[2] = link("bshin", 150, 46, 1590)
  result.links[3] = link("bfoot", 94, 46, 1100)
  result.links[4] = link("fthigh", 133, 46, 1440)
  result.links[5] = link("fshin", 106, 46, 1200)
  result.links[6] = link("ffoot", 70, 46, 880)
  ## The torso's local +y points -x (rear), so its proximal end is the tail and
  ## it extends forward. `rootAngle = +90 deg` puts it flat.
  result.joints[0] = joint("back_hip", 0, 1, 0, mm(500), 0, mm(145),
    -90, -30, 60, 120, -1)
  result.joints[1] = joint("back_knee", 1, 2, 0, -mm(145), 0, mm(150),
    0, -45, 45, 90, -1)
  result.joints[2] = joint("back_ankle", 2, 3, 0, -mm(150), 0, mm(94),
    60, -23, 45, 60, -1)
  result.joints[3] = joint("front_hip", 0, 4, 0, -mm(500), 0, mm(133),
    -90, -57, 40, 120, 1)
  result.joints[4] = joint("front_knee", 4, 5, 0, -mm(133), 0, mm(106),
    0, -69, 50, 60, 1)
  result.joints[5] = joint("front_ankle", 5, 6, 0, -mm(106), 0, mm(70),
    60, -29, 29, 30, 1)
  result.feet[0] = 3
  result.feet[1] = 6
  result.footNames[0] = "back_foot"
  result.footNames[1] = "front_foot"
  result.rootAngle = degQ16(90)
  result.terminates = false
  result.lowY = 0
  result.highY = 0
  result.maxPitch = 0
  result.distNum = 1
  result.distDen = 2
  result.uprightPerTick = 0
  result.freqMinMilliHz = 800
  result.freqMaxMilliHz = 4000

proc buildWalker(): MorphSpec =
  ## WALKER — 7 links, 6 joints, 4 foot contact points. Total mass 23.15 kg.
  result.morph = mWalker
  result.linkCount = 7
  result.jointCount = 6
  result.footCount = 2
  result.links[0] = link("torso", 200, 50, 3530)
  result.links[1] = link("r_thigh", 225, 50, 3930)
  result.links[2] = link("r_shin", 250, 40, 2710)
  result.links[3] = link("r_foot", 100, 60, 3170)
  result.links[4] = link("l_thigh", 225, 50, 3930)
  result.links[5] = link("l_shin", 250, 40, 2710)
  result.links[6] = link("l_foot", 100, 60, 3170)
  result.joints[0] = joint("r_hip", 0, 1, 0, -mm(200), 0, mm(225),
    0, -150, 0, 100, -1)
  result.joints[1] = joint("r_knee", 1, 2, 0, -mm(225), 0, mm(250),
    0, -150, 0, 100, -1)
  result.joints[2] = joint("r_ankle", 2, 3, 0, -mm(250), 0, mm(100),
    90, -45, 45, 100, -1)
  result.joints[3] = joint("l_hip", 0, 4, 0, -mm(200), 0, mm(225),
    0, -150, 0, 100, 1)
  result.joints[4] = joint("l_knee", 4, 5, 0, -mm(225), 0, mm(250),
    0, -150, 0, 100, 1)
  result.joints[5] = joint("l_ankle", 5, 6, 0, -mm(250), 0, mm(100),
    90, -45, 45, 100, 1)
  result.feet[0] = 3
  result.feet[1] = 6
  result.footNames[0] = "r_foot"
  result.footNames[1] = "l_foot"
  result.rootAngle = 0
  result.terminates = true
  result.lowY = mm(800)
  result.highY = mm(2000)
  result.maxPitch = degQ16(57)
  result.distNum = 3
  result.distDen = 2
  result.uprightPerTick = 4_000
  result.freqMinMilliHz = 800
  result.freqMaxMilliHz = 4000

let MorphTable* = [buildHopper(), buildCheetah(), buildWalker()]
  ## The ONE committed morphology table. Every number in it is written into the
  ## replay's config JSON, so a viewer never has to know them a priori.

proc spec*(morph: Morph): MorphSpec {.inline.} =
  MorphTable[ord(morph)]

# ---------------------------------------------------------------------------
#  Kinematics
# ---------------------------------------------------------------------------

proc localToWorld*(link: Link, lx, ly: int64): tuple[x, y: int64] =
  ## A point in a link's local frame, in world metres.
  let
    c = cosQ16(link.a)
    s = sinQ16(link.a)
  (link.x + mulQ(lx, c) - mulQ(ly, s),
   link.y + mulQ(lx, s) + mulQ(ly, c))

proc jointCoord*(body: BodyState, spec: MorphSpec, j: int): int64 {.inline.} =
  ## `q = wrap(child.a - parent.a - mount)` — the joint coordinate the limits,
  ## the driver targets and the observation all speak.
  let js = spec.joints[j]
  wrapAngle(body.links[js.child].a - body.links[js.parent].a - js.mount)

proc jointRate*(body: BodyState, spec: MorphSpec, j: int): int64 {.inline.} =
  let js = spec.joints[j]
  body.links[js.child].w - body.links[js.parent].w

proc forwardKinematics*(body: var BodyState, spec: MorphSpec,
                        q: openArray[int64]) =
  ## Places every link from the root's pose and the joint coordinates, walking
  ## the chain in joint index order (every joint's parent is placed before it,
  ## which the committed tables guarantee). The solver therefore never has to
  ## fix a broken start state.
  for j in 0 ..< spec.jointCount:
    let js = spec.joints[j]
    let parent = body.links[js.parent]
    body.links[js.child].a = wrapAngle(parent.a + js.mount + q[j])
    let anchor = parent.localToWorld(js.pOffX, js.pOffY)
    let child = body.links[js.child]
    let
      c = cosQ16(child.a)
      s = sinQ16(child.a)
      offX = mulQ(js.cOffX, c) - mulQ(js.cOffY, s)
      offY = mulQ(js.cOffX, s) + mulQ(js.cOffY, c)
    body.links[js.child].x = anchor.x - offX
    body.links[js.child].y = anchor.y - offY

proc contactPoint*(body: BodyState, spec: MorphSpec, link, cap: int):
    tuple[x, y: int64] =
  ## End cap `cap` (0 = proximal, 1 = distal) of link `link`, in world metres.
  let hl = spec.links[link].hl
  body.links[link].localToWorld(0, if cap == 0: hl else: -hl)

proc lowestPoint*(body: BodyState, spec: MorphSpec): int64 =
  ## The lowest surface point of the whole body: `min(cap.y - r)` over every
  ## end cap of every link. This is what the start pose is dropped onto y = 0.
  result = high(int64)
  for i in 0 ..< spec.linkCount:
    for cap in 0 .. 1:
      let p = body.contactPoint(spec, i, cap)
      result = min(result, p.y - spec.links[i].r)

proc translate*(body: var BodyState, spec: MorphSpec, dx, dy: int64) =
  for i in 0 ..< spec.linkCount:
    body.links[i].x += dx
    body.links[i].y += dy

proc footOnGround*(body: BodyState, spec: MorphSpec, foot: int,
                   slop: int64): bool =
  ## A foot is "on the ground" when either of its end caps is within the
  ## contact slop of the plane.
  let idx = spec.feet[foot]
  for cap in 0 .. 1:
    let p = body.contactPoint(spec, idx, cap)
    if p.y <= spec.links[idx].r + slop:
      return true
  false

proc footSlip*(body: BodyState, spec: MorphSpec, foot: int): int64 =
  ## |vx| of the foot link's centre — the skating speed a policy reads.
  let idx = spec.feet[foot]
  absQ(body.links[idx].vx)

proc torsoPitch*(body: BodyState, spec: MorphSpec): int64 {.inline.} =
  ## Pitch away from the morphology's neutral root angle, wrapped.
  wrapAngle(body.links[0].a - spec.rootAngle)

proc isUnhealthy*(body: BodyState, spec: MorphSpec): FallWhy =
  ## The per-morphology fall test. THE CHEETAH NEVER FALLS, in any state, ever
  ## (tests/test_cc_sim.nim 11).
  if not spec.terminates:
    return fwNone
  let y = body.links[0].y
  if y < spec.lowY:
    return fwLow
  if y > spec.highY:
    return fwHigh
  if absQ(body.torsoPitch(spec)) > spec.maxPitch:
    return fwPitched
  fwNone
