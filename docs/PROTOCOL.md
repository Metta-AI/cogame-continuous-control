# Protocol

Protocol name: **`continuous-control/v1`**.

## The Coworld game contract

In: `COGAME_CONFIG_URI`.
Out: `COGAME_RESULTS_URI`, `COGAME_SAVE_REPLAY_URI`,
`COGAME_PLAYER_FAILURE_URI`, `COGAME_EVENTS_URI`.
Replay mode: `COGAME_LOAD_REPLAY_URI` + `/client/replay`.
Bind: `COGAME_HOST` / `COGAME_PORT`.

| Route | Purpose |
|---|---|
| `GET /healthz` | liveness |
| `GET /client/player?slot=&token=` | the seat page. Token-checked, and it does **not** open the player socket |
| `GET /client/global` | the spectator page |
| `GET /client/replay` | the broadcast replay page (developer convenience; the hosted viewer is the static wasm bundle) |
| `GET /client/<asset>` | `chrome_common.js`, `broadcast_core.js`, art |
| `GET /replay-data` | the recorded replay bytes, in replay mode |
| `WS /player?slot=N&token=T` | the player protocol. **Closes unless the token matches the seat** |
| `WS /global` | spectator sprite-protocol packets |

`/healthz` and `/global` keep answering for a bounded grace after the artifacts
are written, then the process exits.

`websocketHandler` answers a `Ping` with `socket.send(message.data, Pong)` and
guards **nothing else**: a `kind != TextMessage` guard would drop the player's
binary registration frames.

## The player protocol

The seat sends ONE registration blob as a Sprite v1 chat frame (`0x81`), and
re-sends it for the first ~10 s of received frames (a first send can race the
server's slot bookkeeping):

```json
{"policy": "<label>", "prompt": "<PLAYER_PROMPT or empty>",
 "scripted": "trotter" | "plodder" | null}
```

`prompt` is rune-truncated at 4000 and `policy` at 48. The server consumes it as
**registration** — never as a line, never into the replay chat stream — and
writes a **redacted** `register` record instead (policy label and kind, never
the prompt). Any other chat text from the seat is dropped: the cog speaks
through `say`.

The server sends `welcome`, then one informational `turn` frame per command
turn, then `{"done": true, "result": {…}}`. The seat is not required to answer:
**every decision is made in the game server**, because that is where the
`anthropic_api_key` coworld secret is injected.

A seat that never connects, disconnects mid-episode, or fails every decision is
driven by `trotter` and the ladder runs to its natural end with
`deadSeats[0] = true`. A no-show is reported once to
`COGAME_PLAYER_FAILURE_URI` with the platform's **closed** payload — exactly
`{"message", "failed_policy_index"}`.

## The replay

Binary, magic **`COWLDCCL`**. Everything the viewer needs is in the bytes; no
server is contacted except S3 for the file.

| Content | Carries |
|---|---|
| header | magic, format version, `gameName` `continuous-control`, `gameVersion`, protocol |
| config JSON | `seed`, `variant`, `num_agents`, every rule constant, the whole `MorphTable`, the whole `GaitTable`, the servo gains, every solver constant, the scoring constants, `players[].name`, `slots[]`, `fastMode` |
| stages | per stage: `morph`, the seeded per-joint perturbation, the start tick |
| orders | per turn: the **clamped** gait order — this game's entire input log |
| keyframes | every 48 ticks and at every stage start: the full link state, Q16 narrowed to `int32` |
| chats | `register` / `order` / `fallback` / `budget_guard` / `stop` / `result` |
| hashes | one `gameHash` per tick — the integrity chain the viewer checks |

**The physics is re-derived, not recorded.** The viewer re-runs the identical
`src/cc/sim.nim` from the recorded orders — which is the idea's own integrity
clause, "replay verification by deterministic re-simulation", implemented as the
ONLY way the viewer works, so a divergence cannot go unnoticed.

**State keyframes are a CROSS-CHECK, not a seek index.** They carry the link
state and nothing else, so restoring one mid-stream would leave `stageTick`,
`cyclePos` and every accumulator behind; they are compared against the
re-simulated state at the tick they were recorded on, and a mismatch publishes
`mismatchTick`, shows `#mmwarn` and resyncs from the recorded pose.

**The wall-clock stop is a load-bearing record, not an inference.** A wall-clock
fact cannot be re-derived from sim state, so the stop is written as one record
applied by the *same proc* on record and on playback.

`gameHash` mixes, in this fixed order: `tick`, `phase`, `stageIndex`,
`stageTick`, `resetTick`, `cyclePos`; then every link's `x, y, a, vx, vy, w` in
link index order; then `xStart`, `bestX`, `uprightTicks`, `ctrlCostAccum`,
`saturatedTicks`, `strideCount`; then the three `stageOutcome` codes and the
three `stageReturnMicro` values; then `totalReturnMicro` and `falls`.

`tools/replay_summary.py` (Python 3 stdlib only) prints one strict-UTF-8 JSON
object summarising a `.replay`, which is what phase 60's definition-of-done
check reads.

## The tier-2 analysis stream

`COGAME_EVENTS_URI` gets JSON lines with `SimEventKind` in
`{StageStart, TurnStart, Order, Fallback, Servo, Footstrike, Milestone, Fall,
StageEnd}` plus a mandatory trailing summary row (`type`, `ticks`, `events`,
`gameVersion`). **`Servo` is the per-tick row carrying every joint's applied
torque** — the full continuous-control action trace the idea's neural-policy
teams want, up to 1 512 rows an episode, which the replay deliberately does not
carry.

## Results

A closed schema; `game.results_schema` in the manifest lists exactly these keys.
See [RULES.md](RULES.md) for the scoring formula and the end conditions.
