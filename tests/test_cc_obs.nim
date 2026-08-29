## The observation — §Tests 26-28.

import std/[json, random, strutils, unittest]
import cc/[sim, sim_config, report, baselines, llm, decide]
import helpers

const States = when defined(release): 1_000 else: 60

suite "the seat's observation":
  test "26. the observation reconstructs the sim state":
    var rng = initRand(26)
    var mismatches = 0
    for _ in 0 ..< States:
      let morph = Morphs[rng.rand(0 .. 2)]
      var config = ladderConfig(@[morph, morph, morph],
        int64(rng.rand(1 .. 99_999)))
      var sim = newSimServer(config)
      sim.phase = phPlaying
      sim.startStage(0)
      for _ in 0 ..< rng.rand(1 .. 80):
        if sim.turnDue(): sim.beginTurn(defaultOrder())
        sim.stepTick()
        if sim.phase != phPlaying: break
      let view = sim.observationJson(0)
      let body = view["body"]
      ## `joints` and `feet` always have exactly the morphology's counts
      if body["joints"].getInt() != sim.spec.jointCount: inc mismatches
      if body["links"].getInt() != sim.spec.linkCount: inc mismatches
      if body["joints_detail"].len != sim.spec.jointCount: inc mismatches
      if body["feet"].len != sim.spec.footCount: inc mismatches
      ## `gaits` is always the six names, in that order
      var names: seq[string] = @[]
      for item in view["gaits"]: names.add(item.getStr())
      if names != @["stand", "crouch", "walk", "run", "bound", "brake"]:
        inc mismatches
      ## `ladder` always has exactly three entries
      if view["ladder"].len != 3: inc mismatches
      ## every reported number round-trips within the 2-decimal rounding
      let torso = body["torso"]
      if abs(torso["height_m"].getFloat() - m2(sim.body.links[0].y)) > 0.005:
        inc mismatches
      if abs(torso["pitch_deg"].getFloat() -
          degrees(sim.body.torsoPitch(sim.spec))) > 0.005:
        inc mismatches
      if abs(torso["vx_m_s"].getFloat() - m2(sim.body.links[0].vx)) > 0.005:
        inc mismatches
      for j in 0 ..< sim.spec.jointCount:
        let row = body["joints_detail"][j]
        if row["name"].getStr() != sim.spec.joints[j].name: inc mismatches
        if abs(row["angle_deg"].getFloat() -
            degrees(sim.body.jointCoord(sim.spec, j))) > 0.005:
          inc mismatches
        if abs(row["limit_deg"][0].getFloat() -
            degrees(sim.spec.joints[j].limitLo)) > 0.005:
          inc mismatches
      for f in 0 ..< sim.spec.footCount:
        let row = body["feet"][f]
        if row["on_ground"].getBool() !=
            sim.body.footOnGround(sim.spec, f, PenetrationSlopQ16):
          inc mismatches
      if abs(view["track"]["x_m"].getFloat() - m2(sim.body.links[0].x)) > 0.005:
        inc mismatches
    check mismatches == 0

  test "27. torque_pct and saturated agree":
    var rng = initRand(27)
    var wrong = 0
    for _ in 0 ..< 120:
      let morph = Morphs[rng.rand(0 .. 2)]
      var config = ladderConfig(@[morph, morph, morph],
        int64(rng.rand(1 .. 9_999)))
      var sim = newSimServer(config)
      sim.phase = phPlaying
      sim.startStage(0)
      for _ in 0 ..< rng.rand(1 .. 60):
        if sim.turnDue():
          sim.beginTurn(Order(gait: gBound, cadence: 90, power: 100))
        sim.stepTick()
        if sim.phase != phPlaying: break
      let view = sim.observationJson(0)
      for j in 0 ..< sim.spec.jointCount:
        let row = view["body"]["joints_detail"][j]
        let pct = row["torque_pct"].getInt()
        ## `torque_pct` is |tau| * 100 div tauCap at the tick's FIRST substep
        let cap = max(1'i64, sim.lastForces.tauCap[j])
        let want = int(min(100'i64,
          (absQ(sim.lastForces.tau[j]) * 100'i64) div cap))
        if pct != want: inc wrong
        ## `saturated` is true EXACTLY when torque_pct == 100
        if row["saturated"].getBool() != (pct >= 100): inc wrong
    check wrong == 0

  test "28. nothing hidden leaks into the observation or the prompt":
    let config = ladderConfig(@[mHopper, mCheetah, mWalker], 8_675_309)
    var sim = newSimServer(config)
    sim.seats[0].name = "daveey-1"
    sim.seats[0].policyLabel = "gaitsmith"
    sim.phase = phPlaying
    sim.startStage(0)
    for _ in 0 ..< 200:
      if sim.turnDue(): sim.beginTurn(defaultOrder())
      sim.stepTick()
    let view = $sim.observationJson(0)
    let prompt = userMessage("operator guidance here", view)
    for text in [view, prompt]:
      ## the episode SEED
      check "8675309" notin text
      check "\"seed\"" notin text
      ## the per-joint start perturbation of ANY stage
      check "perturb" notin text
      ## the raw gait-table constants and the servo gains
      check "ampMilli" notin text
      check "trimMilli" notin text
      check "phaseMicro" notin text
      check "kpMilli" notin text
      check "kdMilli" notin text
      ## the agent's own REAL policy/player name
      check "daveey" notin text
      check "gaitsmith" notin text
    ## the alias IS there, and it is the only name
    check "\"you\":\"Alpha\"" in view.replace(" ", "")

  test "28b. the same holds over a whole recorded episode":
    let run = runScriptedEpisode(ladderConfig(
      @[mHopper, mCheetah, mWalker], 555_777))
    var sim = newSimServer(ladderConfig(@[mHopper, mCheetah, mWalker], 555_777))
    sim.phase = phPlaying
    sim.startStage(0)
    var leaked = false
    while not sim.episodeOver():
      if sim.turnDue():
        let view = $sim.observationJson(0)
        if "555777" in view or "perturb" in view or "kpMilli" in view:
          leaked = true
        sim.beginTurn(scriptedOrder(defaultBaselineParams(), sim, blTrotter))
      sim.stepTick()
      if sim.ladderComplete(): break
    check not leaked
    check run.sim.tick > 0
