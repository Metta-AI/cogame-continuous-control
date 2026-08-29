# Rules

**One cog, three machines, sixty metres of track, three times.**

The cog is handed a **hopper** — a single-legged pogo of four links and three
powered joints — and told to cover ground. Then a **cheetah**: seven links, six
joints, two legs, no way to fall over and every reason to go fast. Then a
**walker**: seven links, six joints, two legs, and a torso that tips over if it
gets ahead of its feet.

Each body starts at the same line, on flat ground, under gravity, with a small
seeded wobble in its joints. Each has **19.5 seconds** and a **60-metre line**.
The score is the **return**: metres covered, plus a small bonus for every tick
spent upright, minus a small cost for slamming the actuators.

Nothing about the bodies changes between episodes. What changes is the
**order**: every 1.5 seconds the cog names a **gait** (`stand`, `crouch`,
`walk`, `run`, `bound`, `brake`) and five numbers — cadence, power, lean, stride
bias, phase shift — and a deterministic pattern generator in this repo executes
it, 240 times a second, until the next order.

The whole game is: **read the body you have been given, and tune the gait it
needs before it falls over.**

## The seat

`num_agents` is **1**, always — in both manifest variants and in the
certification fixture, always inside `game_config`. Every episode is a solo run;
policies are compared across episodes, never within one.

In-game the seat is **`Alpha`**. That alias is the only name that appears in an
observation, in a prompt, in a `say`, or drawn on the board. The seat's real
policy name lives only in `results.names`, in the replay's join record, and
spectator-side in the viewer's scorebug plate and endcard.

## The idea's "no LLM path", resolved

The source idea says "neural-policy coworld only; no LLM path (deliberately)".
The platform pin overrides it: every coworld ships an LLM policy **and** a
scripted baseline from day one, in the same image, env-switched.

The tension is resolved by making the seat an **LLM dispatcher/controller over a
deterministic per-tick physics driver**. The LLM does not emit joint torques —
nobody can emit six torques 24 times a second over an HTTP round trip. It emits
a **gait order** at bounded decision points (one order every 36 ticks = 1.5 s),
and a deterministic, integer-only, in-repo **central pattern generator + PD
servo** turns that order into per-joint target angles and torques **every
substep**, 240 times a second. The scripted baselines drive the *identical*
order interface with a fixed algorithm, so the two policy kinds are strictly
comparable and a baseline is legal by construction.

The continuous-torque actuator the idea asks for is real and is what the physics
actually integrates; what this repo reinterprets is *who chooses its parameters
and how often*.

## The three bodies

| morph | links | joints | mass | points/metre | upright bonus | ends on a fall |
|---|---|---|---|---|---|---|
| `hopper` | 4 | 3 | 15.49 kg | 2.00 | 0.096 pts/s | yes — torso below 0.70 m or past 20 deg |
| `cheetah` | 7 | 6 | 14.11 kg | 0.50 | none | **no** — it has no upright to lose |
| `walker` | 7 | 6 | 23.15 kg | 1.50 | 0.096 pts/s | yes — torso outside 0.80 .. 2.00 m or past 57 deg |

The three points-per-metre numbers are the **inverse of how far each body can
go**, chosen so that a competent run is worth roughly twenty points on every
stage and no single morphology decides the episode.

## Time

```
turnTicks        =   36   (1.5 s)   the decision cadence
stageTicks       =  468   (19.5 s)  13 turns of running per stage
resetTicks       =   36   (1.5 s)   the hold after a stage resolves
stagesPerEpisode =    3
maxTurns         =   42
maxTicks         = 1512   (63.0 s)
```

Turn boundaries live on the **global** tick grid (`t mod 36 == 0`) and are
**never** re-aligned when a stage ends early. A hopper that falls at tick 213 is
followed by 36 reset ticks and the next stage starts on the tick after that,
mid-turn. **A fall therefore shortens the episode** in both ticks and LLM turns:
the episode settles early rather than overruns.

## Scoring

Per stage `k` with morphology `m`, in micro-points:

```
distTerm[k]   = (torso.x - xStart) * DistNum[m] / DistDen[m]     # may be NEGATIVE
upright[k]    = UprightPerTick[m] * uprightTicks[k]
ctrl[k]       = ctrlCostAccum[k] / 64
stageReturn[k]= distTerm[k] + upright[k] - ctrl[k]
scores[0]     = sum(stageReturn) / 1e6, rounded to 3 decimals
```

**Higher is better, and the score CAN be negative.** There is no floor clamp and
no participation term: clamping at zero would make "fell over immediately" and
"sprinted the wrong way for a minute" indistinguishable, and the league needs
them distinguishable.

`results.win[0]` is `totalReturn >= par` — a "did the cog clear the bar" flag,
not a duel — and `results.winner` is `0` when `win[0]` is true and `null`
otherwise: there is no opponent, so the only honest winner is the seat itself or
nobody.

**Measured but never scored:** `bestX`, `stagePeakSpeed`, `stageStrides`,
`saturatedTicks`, `falls`, `ordersRepaired`, `fallbackTurns`.

## Variants

| Variant | Ladder | `par` | max |
|---|---|---|---|
| `ladder` | hopper, cheetah, walker | 40.0 | 243.744 |
| `bipeds` | hopper, walker, walker | 30.0 | 305.616 |

## End conditions

`results.reason` is a closed enum — exactly `complete`, `deadline`, `fault` —
and `results.endRule` is `ladderComplete | turnCap | wallClock | fault`.
`results.stageOutcome[i]` is `lined | ran | fell | unreached`.

Nothing a player container does can stop the clock: a seat that never connects,
disconnects mid-episode or fails every decision is driven by `trotter` and the
ladder runs to its natural end.
