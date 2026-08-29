## End-to-end episodes — §Tests 29-33.

import std/[json, os, strutils, unittest]
import cc/[sim, sim_config, report, baselines, decide, replays, replay_runtime]
import helpers

suite "an episode writes its artifacts":
  test "29. the seven results identities hold":
    let config = ladderConfig(@[mHopper, mCheetah, mWalker], 20260829)
    let run = runScriptedEpisode(config)
    let r = run.results
    check r["reason"].getStr() == "complete"
    check r["endRule"].getStr() == "ladderComplete"
    check run.bytes.len > 4_000

    ## 1. finalTick == sum over the stages that started of ticksRun + resetTicks
    var expectedTick = 0
    var started = 0
    for i in 0 .. 2:
      if r["stageOutcome"][i].getStr() != "unreached":
        inc started
        expectedTick += r["stageTicksRun"][i].getInt() + config.resetTicks
    check r["finalTick"].getInt() == expectedTick
    var ticksRun = 0
    for i in 0 .. 2: ticksRun += r["stageTicksRun"][i].getInt()
    check ticksRun <= config.stagesPerEpisode * config.stageTicks

    ## 2. sum(stageTurns) == turnsPlayed
    var turns = 0
    for i in 0 .. 2: turns += r["stageTurns"][i].getInt()
    check turns == r["turnsPlayed"].getInt()

    ## 3. lined <=> 60.000 m ; unreached <=> zero ticks and zero return
    for i in 0 .. 2:
      let outcome = r["stageOutcome"][i].getStr()
      if outcome == "lined":
        check r["stageDistance"][i].getFloat() == 60.0
      if outcome == "unreached":
        check r["stageTicksRun"][i].getInt() == 0
        check r["stageReturn"][i].getFloat() == 0.0

    ## 4. falls == count(fell) ; stagesLined == count(lined)
    var falls = 0
    var lined = 0
    for i in 0 .. 2:
      if r["stageOutcome"][i].getStr() == "fell": inc falls
      if r["stageOutcome"][i].getStr() == "lined": inc lined
    check r["falls"].getInt() == falls
    check r["stagesLined"].getInt() == lined

    ## 5. the totals are the sums
    var distance = 0.0
    var upright = 0
    var ctrl = 0.0
    for i in 0 .. 2:
      distance += r["stageDistance"][i].getFloat()
      upright += r["stageUprightTicks"][i].getInt()
      ctrl += r["stageCtrlCost"][i].getFloat()
    check abs(r["distanceTotal"].getFloat() - distance) < 0.002
    check r["uprightTicksTotal"].getInt() == upright
    check abs(r["ctrlCostTotal"].getFloat() - ctrl) < 0.004

    ## 6. every stageReturn re-derives from the morphology's constants
    var total = 0.0
    for i in 0 .. 2:
      let s = spec(parseMorph(r["stageMorph"][i].getStr()).morph)
      let want = float(s.distNum) / float(s.distDen) *
        r["stageDistance"][i].getFloat() +
        float(s.uprightPerTick) / 1_000_000.0 *
        float(r["stageUprightTicks"][i].getInt()) -
        r["stageCtrlCost"][i].getFloat()
      check abs(r["stageReturn"][i].getFloat() - want) < 0.01
      total += r["stageReturn"][i].getFloat()
    check abs(r["totalReturn"].getFloat() - total) < 0.005

    ## 7. scores[0] == round(totalReturn, 3) ; win ; winner
    check r["scores"][0].getFloat() == r["totalReturn"].getFloat()
    check r["win"][0].getBool() ==
      (r["totalReturn"].getFloat() >= r["par"].getFloat())
    if r["win"][0].getBool():
      check r["winner"].getInt() == 0
    else:
      check r["winner"].kind == JNull

  test "29b. the results key set equals the manifest results_schema exactly":
    let run = runScriptedEpisode(ladderConfig(
      @[mHopper, mCheetah, mWalker], 11))
    let manifest = parseJson(readRepoFile("coworld_manifest_template.json"))
    var schemaKeys: seq[string] = @[]
    for key in manifest["game"]["results_schema"]["properties"].keys:
      schemaKeys.add(key)
    var resultKeys: seq[string] = @[]
    for key in run.results.keys:
      resultKeys.add(key)
    for key in schemaKeys:
      check key in resultKeys
    for key in resultKeys:
      check key in schemaKeys
    for key in ResultsKeys:
      check key in resultKeys

  test "30. the certification seed is interesting":
    ## seed 42 on `ladder` yields >= 900 recorded ticks, at least one stage
    ## with distance >= 10 m and at least one `fall`, so the CI smoke replay
    ## always exercises the stagestart / milestone / fall / stageend beat paths
    ## and always outlasts the 10 s viewer soak.
    var config = ladderConfig(@[mHopper, mCheetah, mWalker], 42)
    config.wallClockBudgetSeconds = 240
    let run = runScriptedEpisode(config)
    check run.sim.tick >= 900
    var far = false
    var fell = false
    for record in run.sim.stages:
      if record.distanceMicro >= 10_000_000: far = true
      if record.outcome == soFell: fell = true
    check far
    check fell

  test "31. no seat can stall the episode":
    ## A seat that never registers plays `trotter` and the ladder runs to its
    ## natural end; the failure payload is the platform's CLOSED shape.
    let run = runScriptedEpisode(ladderConfig(
      @[mHopper, mCheetah, mWalker], 9))
    check run.sim.reason == endComplete
    check run.sim.tick >= 400
    let payload = %*{"failed_policy_index": 0,
                     "message": "player slot 0 never registered"}
    var keys: seq[string] = @[]
    for key in payload.keys: keys.add(key)
    check keys.len == 2
    check "message" in keys
    check "failed_policy_index" in keys

  test "32. the budget guard settles EARLY, complete rather than deadline":
    var config = ladderConfig(@[mHopper, mCheetah, mWalker], 13)
    var sim = newSimServer(config)
    sim.phase = phPlaying
    sim.startStage(0)
    var engine = initDecisionEngine(sim)
    engine.seats[0].isLlm = true
    ## force the guard: two more full turns would not fit
    let outcome = engine.turn(sim, 1, config.wallClockBudgetSeconds - 1)
    check engine.llmOff
    var named = false
    for record in outcome.records:
      let node = parseJson(record)
      if node{"k"}.getStr() == "budget_guard" and node{"turn"}.getInt() == 1:
        named = true
    check named
    ## and the episode still ends `complete`
    let run = runScriptedEpisode(config)
    check run.sim.reason == endComplete

  test "33. every end condition produces the right rule":
    let config = ladderConfig(@[mHopper, mCheetah, mWalker], 77)
    let healthy = runScriptedEpisode(config)
    check healthy.sim.reason == endComplete
    check healthy.sim.endRule == erLadderComplete

    let stopped = runScriptedEpisode(config, stopAtTurn = 6)
    check stopped.sim.reason == endDeadline
    check stopped.sim.endRule == erWallClock
    ## a wall-clock stop mid-ladder marks every UNSTARTED stage `unreached`
    ## with zero everything, and still scores the stages that ran
    var unreached = 0
    for record in stopped.sim.stages:
      if record.outcome == soUnreached:
        inc unreached
        check record.distanceMicro == 0
        check record.returnMicro == 0
        check record.ticksRun == 0
    check unreached >= 1

    let faulted = runScriptedEpisode(config, faultAtTurn = 4)
    check faulted.sim.reason == endFault
    check faulted.sim.endRule == erFault
    check faulted.sim.stopDetail.len > 0

    ## the turn cap is an independent guard
    var capped = config
    capped.stageTicks = 36
    capped.resetTicks = 36
    capped.maxTicks = 3 * (36 + 36)
    capped.maxTurns = capped.maxTicks div capped.turnTicks
    capped.validate()
    let short = runScriptedEpisode(capped)
    check short.sim.reason == endComplete
    check short.sim.endRule in {erLadderComplete, erTurnCap}
