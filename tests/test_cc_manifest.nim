## The manifest — §Tests 39-40.

import std/[json, os, osproc, strutils, unittest]
import cc/[sim, sim_config, report, baselines]
import helpers

let manifest = parseJson(readRepoFile("coworld_manifest_template.json"))

suite "manifest pins":
  test "39. num_agents, the closed schemas and the arithmetic":
    ## num_agents == 1 in BOTH variants' game_config AND in the certification
    ## fixture, and NEVER at a variant's top level (`CoworldVariant` is
    ## additionalProperties: false and the platform reads only
    ## game_config.num_agents).
    check manifest["variants"].len == 2
    for variant in manifest["variants"]:
      check variant["game_config"]["num_agents"].getInt() == 1
      check not variant.hasKey("num_agents")
      ## no literal `tokens` in any game_config (matriculate rejects
      ## "game_config must not include runner-managed tokens")
      check not variant["game_config"].hasKey("tokens")
    check manifest["certification"]["game_config"]["num_agents"].getInt() == 1
    check not manifest["certification"]["game_config"].hasKey("tokens")

    ## exactly ONE declared player, and it IS the certification seat
    check manifest["player"].len == 1
    check manifest["player"][0]["id"].getStr() == "trotter"
    check manifest["certification"]["players"].len == 1
    check manifest["certification"]["players"][0]["player_id"].getStr() ==
      "trotter"
    check manifest["certification"]["game_config"]["players"].len == 1
    ## limits.cpu must be at least "1" (pistonball 0.1.1)
    check manifest["player"][0]["resources"]["limits"]["cpu"].getStr() == "1"

    ## every array in config_schema carries minItems/maxItems (tandem 0.1.0)
    for name, prop in manifest["game"]["config_schema"]["properties"]:
      if prop{"type"}.getStr() == "array":
        checkpoint(name)
        check prop.hasKey("minItems")
        check prop.hasKey("maxItems")
    check manifest["game"]["config_schema"]["additionalProperties"].getBool() ==
      false
    var required: seq[string] = @[]
    for item in manifest["game"]["config_schema"]["required"]:
      required.add(item.getStr())
    check "tokens" in required
    check "players" in required

    ## episode_timeout_minutes is TOP LEVEL, not under `game`
    check manifest["episode_timeout_minutes"].getInt() == 20
    check not manifest["game"].hasKey("episode_timeout_minutes")
    ## >= 3 top-level tags, and game.tags must NOT exist (pistonball 0.1.0)
    check manifest["tags"].len >= 3
    check not manifest["game"].hasKey("tags")
    check manifest["game"]["description"].getStr().len > 40
    check not manifest["game"].hasKey("display_name")
    check not manifest.hasKey("version")

    ## both protocols present as {"type","value"} OBJECTS (garble 0.1.0)
    for key in ["player", "global"]:
      let node = manifest["game"]["protocols"][key]
      check node.kind == JObject
      check node["type"].getStr() == "uri"
      check node["value"].getStr().len > 0
    ## docs.readme + pages
    check manifest["game"]["docs"]["readme"]["value"].getStr().len > 0
    check manifest["game"]["docs"]["pages"].len == 3
    for page in manifest["game"]["docs"]["pages"]:
      check page["id"].getStr().len > 0
      check page["title"].getStr().len > 0
      check page["content"]["value"].getStr().len > 0
    ## the static wasm bundle, under `game`, never a pod
    check manifest["game"]["replay_viewer"]["bundle"].getStr() ==
      "static-replay-viewer"
    check manifest["game"]["owner"].getStr().len > 0
    check manifest["game"]["runnable"]["run"][0].getStr() ==
      "/bin/continuous-control"
    ## `game.name` equals the slug AND the secret URI's namespace
    check manifest["game"]["name"].getStr() == "continuous-control"
    check manifest["game"]["runnable"]["env"]["ANTHROPIC_API_KEY_URI"]
      .getStr() == "secret://coworld/continuous-control/anthropic_api_key"

    ## the results_schema closed enums
    let rs = manifest["game"]["results_schema"]["properties"]
    check rs["reason"]["enum"].len == 3
    check rs["endRule"]["enum"].len == 4
    check rs["stageOutcome"]["items"]["enum"].len == 4
    check rs["stageMorph"]["items"]["enum"].len == 3
    check manifest["game"]["results_schema"]["additionalProperties"]
      .getBool() == false

  test "39b. every variant's game_config actually builds a legal episode":
    ## The collab-cooking 0.1.1 scar: test EVERY variant, not just the fixture.
    var fixtures = @[manifest["certification"]["game_config"]]
    for variant in manifest["variants"]:
      fixtures.add(variant["game_config"])
    for gameConfig in fixtures:
      var config = defaultConfig()
      config.update(gameConfig)
      config.tokens = @["token-0"]
      config.validate()
      check config.numAgents == 1
      check config.wallClockBudgetSeconds <= 690
      check config.attempt1Ms mod 1000 == 0
      check config.retryMs mod 1000 == 0
      check config.attempt1Ms + config.retryMs <= config.turnBudgetMs
      check config.maxTicks ==
        config.stagesPerEpisode * (config.stageTicks + config.resetTicks)
      check config.maxTurns == config.maxTicks div config.turnTicks
      check config.stageTicks mod config.turnTicks == 0
      check config.stageLadder.len == config.stagesPerEpisode
      ## it builds all three of its bodies and plays the 42-turn schedule
      var sim = newSimServer(config)
      sim.phase = phPlaying
      for stage in 0 ..< config.stagesPerEpisode:
        sim.startStage(stage)
        check sim.spec.linkCount >= 4
        check sim.body.lowestPoint(sim.spec).abs <= 2
      let run = runScriptedEpisode(config)
      check run.sim.tick > 200
      check run.sim.reason == endComplete
      check run.results["scores"].len == 1

  test "40. the manifest loads under the installed CLI's own validators":
    ## `coworld` is not installed in the sandbox or in the `test` job; the
    ## release workflow's `coworld build` is where it runs for real. What is
    ## checkable HERE is the shape those validators demand (0.1.42 wants
    ## `game.replay_viewer`, no top-level `version`, no `game.display_name`,
    ## `game.owner` required, no runner-managed `tokens`) plus the image
    ## placeholder's compose-derived name.
    check manifest["game"]["image"].getStr() == "{{CONTINUOUS_CONTROL_IMAGE}}"
    let compose = readRepoFile("compose.yaml")
    check "continuous-control:" in compose
    check "image: coworld-continuous-control:latest" in compose
    check "platform: linux/amd64" in compose
    check "network: host" in compose
    ## and the CLI, if it happens to be installed, gets the real thing
    let probe = execCmdEx("python3 -c \"import json,sys; " &
      "json.load(open('" & repoRoot() &
      "/coworld_manifest_template.json'))\"")
    check probe.exitCode == 0
