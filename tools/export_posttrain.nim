## Export complete scripted control games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED] [ladder|bipeds]

import std/[json, os, osproc, strutils]
import cc/[sim, sim_config, report, baselines, directives, llm]

const OperatorPrompt = "Drive each machine down the track using the observed joint and stride feedback."

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [ladder|bipeds]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "ladder"
  if episodes < 10 or firstSeed < 1:
    quit("at least ten episodes and a positive first seed are required", 1)
  if variant notin ["ladder", "bipeds"]:
    quit("variant must be ladder or bipeds", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var config = defaultConfig()
    config.update(variantConfig)
    config.seed = int64(seed)
    config.validate()
    let sim = newSimServer(config)
    sim.phase = phPlaying
    sim.startStage(0)
    var rows: seq[string]
    while not sim.episodeOver():
      let view = sim.observationJson(0)
      var order = sim.scriptedOrder(blTrotter)
      let completion = order.orderJson()
      let parsed = parseOrderReply($completion, sim.activeOrder, sim.haveOrder)
      doAssert $parsed.orderJson() == $completion
      rows.add($(%*{
        "episode_id": "continuous-control-" & variant & "-" & $seed,
        "seed": "continuous-control-" & variant & "-" & $seed,
        "decision_id": sim.turnsPlayed,
        "prompt": [
          {"role": "system", "content": SystemPrompt},
          {"role": "user", "content": userMessage(OperatorPrompt, $view)}
        ],
        "completion": [{"role": "assistant", "content": $completion}],
        "game": "continuous-control",
        "action_schema_revision": "continuous-control-order-v1"
      }))
      sim.beginTurn(order)
      let turnEnd = sim.tick + config.turnTicks
      while sim.tick < turnEnd and sim.phase != phGameOver:
        sim.stepTick()
        if sim.ladderComplete():
          break
      sim.endTurn("")
    sim.settle(endComplete,
      if sim.ladderComplete(): erLadderComplete else: erTurnCap)
    doAssert rows.len > 0 and sim.reason == endComplete
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "return": sim.totalReturnMicro, "win": sim.episodeWin()})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "continuous-control",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-trotter",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
