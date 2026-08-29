# The physics, and how it differs from MuJoCo

This coworld implements the **problem** the continuous-control canon poses —
planar articulated locomotion from proprioceptive state, fixed-length stages,
return as the score — on its own deterministic, seeded, integer-safe 2-D physics
sim written in Nim. It is deliberately **not** a bit-exact port of Gymnasium
MuJoCo or of `dm_control`.

The three shipped bodies are the **planar half** of the idea's ladder. Ant,
Humanoid, Swimmer, quadruped, dog and every manipulation task are 3-D and are
out of scope.

## Why not MuJoCo

MuJoCo is a C solver over a float state vector, `dm_control` is Python on top of
it, and Brax/MJX is JAX. None of them can be embedded in a Nim sim module that
must **also** compile to wasm32 for the static replay viewer — and a static
replay viewer is a non-optional platform pin ("Replays are a static file + a
browser wasm viewer — NEVER a pod"). Vendoring any of them means shipping a
coworld whose replays cannot be watched.

**No upstream code is vendored, no upstream model XML is shipped or fetched, no
upstream numbers are claimed as reproduced, and no score from this coworld is
comparable to a published HalfCheetah, Hopper or Walker2d return.**

## Everything is a Q16 integer

Every dynamical quantity is an `int64` holding a Q16 fixed-point SI value
(65 536 = 1.0) in metres, seconds, kilograms, radians and their derived units.

| Quantity | Unit | Envelope |
|---|---|---|
| position `x`, `y` | metres | +-100 m, resolution 15.3 um |
| linear velocity | m/s | +-12 m/s, per component |
| angle | radians, wrapped to `(-PI, +PI]` | resolution 15.3 urad |
| angular velocity | rad/s | +-40 rad/s |
| return accumulators | micro-points | `int64` |

Two arithmetic rules, both grep-enforced by `tests/test_cc_sim.nim`:

1. `mulQ(a, b) = (a * b) div 65_536`, using `div`, **never `shr`**. Nim's `shr`
   on signed integers is a portability trap; `div` truncates toward zero on
   every backend, is symmetric under negation, and is what makes native amd64
   and emscripten/wasm32 agree bit for bit.
2. Every Q16 quantity is range-checked into its declared envelope once per tick,
   which bounds every product in the solver under 2^62 with three orders of
   magnitude of headroom.

**Trigonometry is a committed table.** `src/cc/trig.nim` holds
`SinQ16Table: array[1025, int32]`, generated once by `tools/gen_trig_table.nim`
and checked in; a test re-derives every entry from `math.sin` and asserts
`|err| <= 2` in Q16. **There is no square root in the solver at all**: the
ground is a single horizontal line so every contact normal is exactly `(0, 1)`,
and every joint constraint is a 2x2 linear solve. `isqrtQ16` exists in
`src/cc/report.nim` only, and never touches hashed state.

## Documented divergences

1. **A sequential-impulse solver with no warm starting, not MuJoCo's convex
   soft-contact solver.** 10 substeps of 12 Gauss-Seidel iterations at 240 Hz,
   Baumgarte position bias (1/5 on joints and contacts, 1/4 on joint limits),
   Coulomb friction with accumulated-impulse clamping, restitution 0.
   Accumulated impulses are zeroed at the top of every substep, so the sim state
   is exactly the link states plus the stride phase and nothing carried in
   solver internals — which is the whole reason this repo can ship a wasm
   re-simulating viewer. It costs convergence: the MEASURED worst case over a
   stage of running is **~7 mm of joint anchor separation and ~21 mm of foot
   penetration on the cheetah**, whose 6.4 kg torso is eight times its lightest
   foot. `tests/test_cc_sim.nim` 5 pins those measured bounds rather than an
   aspirational one.
2. **Masses, lengths, joint limits and torque caps are in the same structural
   family as the Gymnasium XMLs but are this repo's numbers.** They are printed
   below and written into every replay's config JSON, so they are auditable;
   they are not claimed to be MuJoCo's. The derived neutral standing torso
   height that falls out of the committed link table is **1.21 m** for both the
   hopper and the walker (the design note's nominal figure was 1.25 m; 1.21 m is
   what the table's own arithmetic gives, and the fall tests are set against it).
3. **The action is a gait order every 36 ticks, not a torque vector every
   step.** The continuous torque is real — the PD servo produces one per joint
   per substep, 240 times a second — and its *parameters* are what the policy
   sets. `COGAME_EVENTS_URI`'s per-tick `Servo` rows carry the full torque trace
   for anyone who wants the RL-style action stream.
4. **Proprioception only; no pixel observations.**
5. **Reward shape.** Gymnasium's reward is
   `forward_reward_weight * xdot + healthy_reward - ctrl_cost_weight * sum(a^2)`
   per step. This repo uses the same three terms with the same signs and the
   same relative magnitudes, integrated over the stage, plus a per-morphology
   points-per-metre so that no one body dominates a three-body episode.
6. **Terminating stages: hopper and walker yes, cheetah no** — matching
   `Hopper-v5`, `Walker2d-v5` and `HalfCheetah-v5`.
7. **A 60 m finish line.** No Gymnasium locomotion task has one. It gives the
   spectator a goal line and the scoreboard a bounded maximum.
8. **`maxGames = 1`** — a ladder has no side to swap.
9. **`brake` really does stop holding you up.** The design's `brake` is
   `Kp := 0, Kd := KdBrake` — pure damping. Damping resists joint VELOCITY; it
   cannot hold a static equilibrium, so a stiff-legged biped under `brake` sags
   and ends its stage in about 25 ticks. The system prompt says so in those
   words rather than repeating the folklore that a brake saves a fall: it does
   on the cheetah, which cannot fall, and it does not on the other two.
10. **`stand` is the neutral pose, not a gait trim.** A gait's `trim` is the
    OSCILLATION CENTRE of a moving body; the pose a stiff PD servo genuinely
    holds at rest is `q = 0`. They are different numbers and the table carries
    both.
11. **`crouch` is the SHALLOWEST QUIET pose, not the deepest survivable one.**
    A deeper crouch exists on both terminating bodies and is survivable, but it
    ROCKS to within a whisker of the fall limit, which turns `trotter`'s settle
    turn into the thing that ends the stage. The shipped pose is the deepest
    one whose torso pitch stays under 0.05 rad (0.03 on the walker) for 220
    ticks at `power 40` — hopper hip -0.050 / knee -0.500 / ankle +0.500 rad,
    torso 1.14 m; walker knee -0.200 / ankle +0.200 rad, torso 1.20 m
    (`src/cc/gaits.nim`).
12. **A seek REWINDS AND RE-STEPS from tick 0**, rather than restoring the
    nearest state keyframe. A keyframe carries the link state and nothing else,
    so resuming from one would leave `stageTick`, `cyclePos` and every
    accumulator behind and diverge the hash chain from the very next tick.
    1 512 ticks of a 120-pass integer solver is ~0.4 s natively and about a
    second in wasm32, which a scrubber click can afford; a wrong resume cannot
    be afforded (`src/cc/replay_runtime.nim`). Keyframes are kept for what they
    are worth as: a per-tick CROSS-CHECK and the pre-scan's cheap track read.
13. **The tuning gate COMPARES the committed pick; it does not re-run the
    search.** `tools/tune_gaits.nim --check` and `tools/tune_baselines.nim
    --check` assert the shipped `GaitTable` and `BaselineParams` still equal
    `tools/ci/gait_tuning.json` and `tools/ci/baseline_tuning.json`. Re-running
    either search in CI takes minutes to reproduce a number that is already
    committed; `tests/test_cc_tuning.nim` asserts the same equality from inside
    the suite.
14. **`tools/wasm_replay_smoke.cjs` is not wired into CI, and test 48 lives in
    `tests/test_cc_viewer.nim`.** The wasm bundle is exercised by
    `tools/ci/viewer_smoke.mjs` in headless chromium — the gate that actually
    matters, because it loads the real bundle and the real replay — so the
    node-side smoke is kept as a developer tool rather than a second gate over
    the same ground. The label-vocabulary test the note numbers 48 is a viewer
    test and is folded into the viewer suite rather than given a file of its
    own.
15. **The replay is about 130 KB, not the ~32 KB the note estimated.** Every
    per-turn `order` chat record carries the whole observation the decision was
    made from (`record["view"]`, the view minus `last_turn.notes`), which the
    note's own record vocabulary requires and which is what makes the replay
    explain each decision; it is bounded at `MaxOrderRecordRunes = 6000` per
    record and the view is dropped rather than truncated if a record exceeds
    it. The CI smoke's own figure is 132 082 B for a full three-stage episode.
16. **`tools/ci/viewer_smoke.mjs` carries one selector this repo added.** The
    harness is otherwise the builder template verbatim; its DOM feed probe read
    `#feed, .feed, #log, [id$="-feed"]`, and this lineage's feed is coworld-ctf's
    `<div id="killfeed">`, which matches none of them — so `feed_lines` was
    structurally 0 for this viewer whatever the feed did, and it read 0 in the
    head run's artifacts while every feed line was in fact throwing. `#killfeed`
    is now in the list. The number is reported, never gated: feed rows expire on
    a dwell timer, so a 0 between beats is legitimate.

## The committed morphology table

### HOPPER — 4 links, 3 joints, 15.49 kg

| i | link | hl (m) | r (m) | m (kg) |
|---|---|---|---|---|
| 0 | torso | 0.200 | 0.050 | 3.53 |
| 1 | thigh | 0.225 | 0.050 | 3.93 |
| 2 | shin | 0.250 | 0.040 | 2.71 |
| 3 | foot | 0.195 | 0.060 | 5.32 |

| j | joint | limits (deg) | tau_max (N.m) |
|---|---|---|---|
| 0 | hip | -150 .. 0 | 200 |
| 1 | knee | -150 .. 0 | 200 |
| 2 | ankle | -45 .. +45 | 200 |

### CHEETAH — 7 links, 6 joints, 14.11 kg

| i | link | hl (m) | r (m) | m (kg) |
|---|---|---|---|---|
| 0 | torso | 0.500 | 0.046 | 6.36 |
| 1 | bthigh | 0.145 | 0.046 | 1.54 |
| 2 | bshin | 0.150 | 0.046 | 1.59 |
| 3 | bfoot | 0.094 | 0.046 | 1.10 |
| 4 | fthigh | 0.133 | 0.046 | 1.44 |
| 5 | fshin | 0.106 | 0.046 | 1.20 |
| 6 | ffoot | 0.070 | 0.046 | 0.88 |

| j | joint | limits (deg) | tau_max (N.m) |
|---|---|---|---|
| 0 | back_hip | -30 .. +60 | 120 |
| 1 | back_knee | -45 .. +45 | 90 |
| 2 | back_ankle | -23 .. +45 | 60 |
| 3 | front_hip | -57 .. +40 | 120 |
| 4 | front_knee | -69 .. +50 | 60 |
| 5 | front_ankle | -29 .. +29 | 30 |

### WALKER — 7 links, 6 joints, 23.15 kg

| i | link | hl (m) | r (m) | m (kg) |
|---|---|---|---|---|
| 0 | torso | 0.200 | 0.050 | 3.53 |
| 1,4 | r_thigh, l_thigh | 0.225 | 0.050 | 3.93 |
| 2,5 | r_shin, l_shin | 0.250 | 0.040 | 2.71 |
| 3,6 | r_foot, l_foot | 0.100 | 0.060 | 3.17 |

| j | joint | limits (deg) | tau_max (N.m) |
|---|---|---|---|
| 0,3 | r_hip, l_hip | -150 .. 0 | 100 |
| 1,4 | r_knee, l_knee | -150 .. 0 | 100 |
| 2,5 | r_ankle, l_ankle | -45 .. +45 | 100 |

Link inertia is `I = m * (hl^2 / 3 + r^2 / 4)` about the link centre, computed
once at stage start in Q16 and stored with `invM` and `invI`.

## Solver constants

```
Gravity                 9.81 m/s^2      (Q16 642_908)
TargetFps               24
SubstepsPerTick         10               -> substep dt = 1/240 s
SolverIterations        12               (per substep)
Baumgarte               1/5              (joints and contacts)
JointLimitBias          1/4
PenetrationSlop         0.0005 m
GroundFriction          0.90             (Coulomb, accumulated-impulse clamped)
GroundRestitution       0                (feet do not bounce)
MaxLinSpeed             12.0 m/s         (per component)
MaxAngSpeed             40.0 rad/s
GroundY                 0.0 m
Track                   -6.00 .. +60.00 m
InitPerturb             0.05 rad         (seeded per-joint start offset)
StateKeyframeTicks      48
```

## Determinism, native <-> wasm

The server writes a **`COWLDCCL`** replay: header, the resolved config JSON
(seed, variant, every rule constant, the whole `MorphTable`, the whole
`GaitTable`, the solver constants, the scoring constants), then the record
stream — the register record, one `stage` record per stage carrying its seeded
per-joint perturbation, **one `order` record per turn (the only inputs this game
has)**, one state keyframe every 48 ticks and at every stage start, chat records
and **one `gameHash` per tick**.

**The physics is re-derived, not recorded.** The viewer re-runs the identical
`src/cc/sim.nim`, compiled to wasm32, from the recorded orders, and compares
`gameHash` against the recording every tick. One divergent bit is caught at the
tick it happens and surfaced as `mismatchTick` in `#mmwarn`.

`gameHash` mixes, in this fixed order: `tick`, `phase`, `stageIndex`,
`stageTick`, `resetTick`, `cyclePos`; then every link's `x, y, a, vx, vy, w` in
link index order; then `xStart`, `bestX`, `uprightTicks`, `ctrlCostAccum`,
`saturatedTicks`, `strideCount`; then the three `stageOutcome` codes and the
three `stageReturnMicro` values; then `totalReturnMicro` and `falls`. It never
mixes FX, feed text, `say`, `notes` or policy labels.

## Tuning

`tools/tune_gaits.nim` sweeps the gait table and the servo gains;
`tools/tune_baselines.nim` sweeps the six `BaselineParams` knobs.
`tools/ci/gait_tuning.json` and `tools/ci/baseline_tuning.json` record the
picks, and `tests/test_cc_tuning.nim` asserts the shipped tables still equal
them. **The morphology, solver and scoring constants are NOT swept and are NOT
tunable**: if a body cannot walk, the sweep moves, never the physics.

The sweep's objective is the MEAN distance the driver alone covers across the
operating grid a policy actually sends (cadence 45/60/75 x power 60/80) rather
than one sample of it: optimising a single (cadence, power) point ships a table
that works only at that point and falls everywhere else, which makes the game
unplayable rather than hard.

## The baseline bands

`tests/test_cc_baselines.nim` 25 is the gate that keeps `trotter` and `plodder`
honest. It asserts **means over 100 release seeds**, not per-morphology
per-seed literals, and these are the numbers it pins:

```
trotter mean distance, hopper       0.3 .. 14.0 m
trotter mean distance, cheetah     20.0 .. 58.0 m
trotter mean distance, walker       8.0 .. 30.0 m
trotter mean total return          25.0 .. 90.0
trotter worst seed total return    > -10.0
trotter best seed total return     < 130.0
plodder mean total return           > 5.0, and below trotter's
plodder lower than trotter          on >= 80 % of seeds
trotter falls <= 2                  on >= 80 % of seeds
```

**Why means and not per-seed bands.** The design note's bands (6-14 m hopper,
30-58 m cheetah, 11-24 m walker, `plodder` lower on >= 90 % of seeds) are
per-seed floors. The seeded 0.05 rad per-joint start wobble genuinely decides
whether a body finds its stride or trips in its first metre — that is the point
of seeding the start pose — so a per-seed floor would pin the wobble out of the
game and make the baseline's luck a test failure. The gate is therefore on the
distribution: neither a zero floor nor a superhuman filler can ship.

**Why the hopper's floor is 0.3 m.** The hopper is the one terminating
morphology with a single leg, a 0.70 m floor and a 20 degree pitch limit; on an
unlucky start wobble it falls inside the first second and banks almost nothing,
and those seeds pull the MEAN down hard. The floor exists to exclude a baseline
that never moves at all, and it sits below the fall-heavy tail rather than
above it. The upper bound (14.0 m) is what stops a filler from being tuned into
a champion.

**This is documented divergence 1 of the baseline set**: the shipped numbers are
MEASURED from the tuned tables, and they are wider than the design note's
estimate, which was written before the sweep ran.
