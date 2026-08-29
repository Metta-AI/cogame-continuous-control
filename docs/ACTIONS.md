# Gait orders and the reply format

One JSON object every 1.5 seconds. A deterministic pattern generator in the game
runs your order 240 times a second on every joint until your next order. You are
not sending torques; you are **tuning the machine that sends them**.

```json
{"gait":"run","cadence":72,"power":85,"lean":12,"stride_bias":-6,"phase_shift":0,
 "say":"lengthening the stride now the cheetah is up to speed",
 "notes":"run/72/85/+12 holds the gallop. front knee saturates above power 88."}
```

| Field | Type | Cap / domain | When violated |
|---|---|---|---|
| `gait` | string | **<= 8 runes**; closed enum `stand`, `crouch`, `walk`, `run`, `bound`, `brake`, matched case-insensitively and whitespace-trimmed; synonyms accepted: `sprint`/`gallop`/`trot` -> `run`, `hop`/`leap` -> `bound`, `stop`/`halt` -> `brake`, `idle`/`hold` -> `stand` | unrecognised or missing -> **last turn's gait**, else `walk` on the stage's first turn |
| `cadence` | integer | **clamped 0 .. 100**; numeric strings accepted; a decimal below 6 is read as HERTZ and mapped onto the 0.80 .. 4.00 Hz band | missing -> last turn's value, else 50 |
| `power` | integer | **clamped 0 .. 100** | missing -> last turn's value, else 60 |
| `lean` | integer | **clamped -50 .. +50**; a value in -1.0 .. 1.0 is read as a fraction of the range | missing -> last turn's value, else 0 |
| `stride_bias` | integer | **clamped -50 .. +50** | missing -> last turn's value, else 0 |
| `phase_shift` | integer | **clamped -50 .. +50** (percent of one stride cycle) | missing -> 0. It is a ONE-SHOT nudge and is **never inherited** |
| `say` | string | **<= 140 runes** — drawn in the spectator feed and in the replay, never fed back to the seat | truncated on rune boundaries |
| `notes` | string | **<= 320 runes** — private scratchpad, echoed to this seat only next turn | truncated on rune boundaries |
| whole reply | bytes | **<= 4096** read from the provider before parsing | over-long -> parse failure -> one retry |

**Out-of-range numbers are CLAMPED, never dropped.** There is no irreversible
move here, so a clamped `power: 140 -> 100` is the honest reading of "as hard as
possible". Every clamp increments `ordersRepaired` and is reported back to the
seat next turn as `last_turn.repaired`.

**Parsing is tolerant**: markdown fences are stripped, the outermost balanced
`{...}` is taken, numeric strings are accepted, unknown top-level keys are
ignored. A reply with a valid `say` but no usable order field is **usable** —
last turn's order continues and the narration is delivered. A reply that is not
a JSON object is a parse failure.

## The six gaits

| gait | what the driver does |
|---|---|
| `stand` | the neutral pose, no stride. The one pose a stiff PD servo genuinely holds. Settle here. |
| `crouch` | a low pose, no stride. Plant the feet before you move. |
| `walk` | a long slow stride, both feet down often. Stable. |
| `run` | a short fast stride. The workhorse. |
| `bound` | big amplitude, big air, big risk. |
| `brake` | amplitude zero and **pure damping**: the position servo is switched OFF (`Kp := 0`, `Kd := KdBrake`). It kills speed at once. On the cheetah that is free. **On the hopper or the walker nothing is holding you up any more, so a brake is how you END a stage, not how you save one.** |

## What you get back

Every joint's angle, rate, limits and how much of its torque ceiling the servo
just used (`torque_pct`, and `saturated` when it is pegged). Every foot's ground
contact and slip. Torso height, pitch, forward speed. Your x on the track. What
your LAST order actually achieved: distance, mean speed, strides, peak torque,
saturated ticks, airborne ticks, and whether you fell.

Read those numbers — they are the whole game:

```
saturated joints                    -> your power is too high for this cadence
slip above ~0.5 m/s                 -> the foot is skating; lower cadence or power
airborne_ticks near 36              -> you are launching, not running
distance near zero with high strides-> you are marching on the spot; add lean
pitch heading toward the fall limit -> you are about to lose the stage
```

## What is hidden

The episode **seed**; the per-joint start perturbation of any stage that has not
started; the gait table's raw amplitude / phase / trim constants; the servo
gains; and the agent's own **real player/policy name**. Nothing about identity
ever reaches a prompt.

## Fielding your own policy

A policy is just a prompt. Reuse the image and set `PLAYER_PROMPT`:

```bash
coworld upload-policy coworld-continuous-control --name my-cog \
  --run /bin/continuous-control-player \
  --secret-env PLAYER_PROMPT="<your strategy>"
```

`PLAYER_SCRIPTED=trotter|plodder` selects a scripted baseline from the same
image instead. A seat that sets neither is `trotter`.
