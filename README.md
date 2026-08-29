# cogame-continuous-control

**One cog, three planar machines, sixty metres of track, three times.**

A single-seat Coworld over the continuous-control canon. The cog is handed a
**hopper** — a one-legged pogo of four links and three powered joints — and told
to cover ground. Then a **cheetah**: seven links, six joints, a long body, no way
to fall over and every reason to go fast. Then a **walker**: two legs and a torso
that tips over if it gets ahead of its feet.

Each machine gets **19.5 seconds** and a **60-metre line**. The score is the
**return**: metres covered, plus a small bonus for every tick spent upright,
minus a small cost for slamming the actuators. Higher is better, and it can go
negative.

Nothing about the machines changes between episodes. What changes is the
**order**: every 1.5 seconds the cog names a gait — `stand`, `crouch`, `walk`,
`run`, `bound`, `brake` — and five numbers (cadence, power, lean, stride bias,
phase shift), and a deterministic pattern generator in this repo executes it 240
times a second until the next order. A hopper that runs a gallop cadence
face-plants in two strides. A walker that leans +40 into a fast cadence out-runs
its own feet. A cheetah that never leans and never raises power crawls.

**The whole game is: read the body you have been given, and tune the gait it
needs before it falls over.**

## A policy is just a prompt

The LLM does not emit joint torques — nobody can emit six torques 24 times a
second over an HTTP round trip. It emits a **gait order** at bounded decision
points, and an integer-only central pattern generator plus PD servos turn that
order into per-joint targets and torques every substep. The scripted baselines
drive the *identical* order interface, so the two policy kinds are strictly
comparable and a baseline is legal by construction.

```bash
coworld upload-policy coworld-continuous-control --name my-cog \
  --run /bin/continuous-control-player \
  --secret-env PLAYER_PROMPT="Tune, do not thrash. Every machine has one
cadence/power pair that works; find it in two turns and then hold it."
```

`PLAYER_SCRIPTED=trotter|plodder` selects a scripted baseline from the same
image. A seat that sets neither is `trotter`, which is also the certification
player and the server-side fallback.

## Documentation

- [docs/RULES.md](docs/RULES.md) — the ladder, the bodies, the scoring, the end
  conditions.
- [docs/ACTIONS.md](docs/ACTIONS.md) — the gait order, the reply schema, every
  cap and every repair.
- [docs/PHYSICS.md](docs/PHYSICS.md) — the Q16 integer solver, the committed
  morphology tables, and every documented divergence from MuJoCo.
- [docs/PROTOCOL.md](docs/PROTOCOL.md) — the Coworld game contract, the player
  protocol, the replay format.

## Layout

```
src/cc/            the sim module: Q16 integer physics, the driver, the decision
                   layer, the replay codec, the server. Compiled TWICE — natively
                   into /bin/continuous-control, and to wasm32 for the viewer.
src/continuous_control.nim         the game entrypoint
src/continuous_control_player.nim  the thin seat registrar
client/            the broadcast chrome, inherited from coworld-ctf
replay-viewer/     the static wasm replay bundle's entry point and shell
tools/             the build hook, the CI smoke, the sweeps, the forensics
tests/             the Nim suite, run in debug AND -d:release by ci.yml
```

## Building and running locally

```bash
# the toolchain the Dockerfile and ci.yml both use
curl -fsSL -o ~/.local/bin/nimby \
  https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64
chmod +x ~/.local/bin/nimby && nimby use 2.2.4
export PATH="$HOME/.nimby/nim/bin:$PATH"
nimby --global sync nimby.lock

# regenerate nim.cfg from THIS machine's package tree (the committed one would
# pin the author's paths)
rm -f nim.cfg
for pkg in "$HOME"/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg

# the tests, the way CI runs them
for t in tests/test_cc_*.nim; do
  nim r --hints:off --path:src "$t"
  nim r --hints:off -d:release --path:src "$t"
done

# one whole episode, no Docker
nim c -d:release --path:src -o:/tmp/cc src/continuous_control.nim
nim c -d:release --path:src -o:/tmp/cc-player src/continuous_control_player.nim
```

## The replay

Binary, magic `COWLDCCL`, about 130 KB. It records the per-turn **orders** and a
`gameHash` per tick; **the physics is re-derived, not recorded**, by re-running
the identical `src/cc/sim.nim` compiled to wasm32 in the browser. That is the
idea's own integrity clause — "replay verification by deterministic
re-simulation" — implemented as the only way the viewer works, so a divergence
cannot go unnoticed.

`tools/replay_summary.py` (Python 3 standard library only) prints one
strict-UTF-8 JSON object summarising any `.replay`:

```bash
python3 tools/replay_summary.py episode.replay | jq '.protocol, .results.reason'
```

## Art

The three machines' visual identities are nano-banana renders of the Softmax
cog, one kit per morphology, so a spectator can tell them apart at board scale
without reading a label. The source sheet
(`scripts/art/source/machines_sheet.png`) and the split script
(`scripts/art/split_machine_sheet.py`) are both committed; CI never regenerates
art. Everything else on the board — the dirt bed, the horizon, the ruler, the
finish gate, the link hulls, the dust and the footprints — is baked at install
with pixie from the starter's own shipped assets.

## Licence

MIT. See [LICENSE](LICENSE).
