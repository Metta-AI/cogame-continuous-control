# Training

## Numeric Metta RL and PufferLib

Both certified variants use the headless physics simulator and the exact
player-visible observation. Build the persistent bridge and play complete
scripted and random games:

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/cc-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/cc-train-bridge
```

Pass the binary, `coworld_manifest_template.json`, and `ladder` or `bipeds`
to `recipes.external.coworld_metta_rl.train` or
`recipes.external.coworld.train` in Metta, with `players=1` and a finite
`total_timesteps`. The 99-feature observation comes from `observationJson`.
Six action heads select gait, cadence, power, lean, stride bias, and phase
shift. The terminal score is the game's return; terminal utility divides
that return by the documented theoretical maximum and clips it to [-1, 1].
This supports the single-seat training contract without changing scoring.

## Metta post-training data

The maintained physics simulator and published `trotter` policy can export
supervised examples for both certified variants:

```sh
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/continuous-control-ladder 10 1 ladder
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/continuous-control-bipeds 10 1 bipeds
```

Each run uses the variant's manifest config and plays complete seeded games.
The exporter records the hosted system prompt, player-visible observation,
and a baseline order accepted by the game's reply parser. Splits are by game
seed. The manifest records source revision, variant, scores, wins, and row
counts. Existing output directories are never overwritten.

Train either output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/continuous-control-ladder \
  --output /tmp/continuous-control-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

This is scripted-policy distillation; it does not establish improved league
play. The local 10-game ladder export contained 214 train and 62 validation
examples, with 3/10 wins. Bipeds contained 188 train and 63 validation
examples, with 8/10 wins. All 527 examples fit a 4096-token smoke model.
One CPU optimizer update reduced validation loss from 1.7550 to 1.7487
(ladder) and 1.7533 to 1.7473 (bipeds).
