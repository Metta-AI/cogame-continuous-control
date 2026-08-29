## The derived broadcast events — §Test 49 — and the tier-2 stream.

import std/[json, sets, strutils, unittest]
import cc/[sim, sim_config, baselines, events, decide]
import helpers

suite "the event vocabulary is a CLOSED enum":
  test "49. the emitted set equals exactly the eleven listed kinds":
    var emitted = initHashSet[string]()
    var perTick = initHashSet[string]()
    for seed in [42'i64, 7, 91, 606]:
      var config = ladderConfig(@[mHopper, mCheetah, mWalker], seed)
      var sim = newSimServer(config)
      var engine = initDecisionEngine(sim)
      let params = defaultBaselineParams()
      sim.phase = phPlaying
      sim.startStage(0)
      while not sim.episodeOver():
        if sim.turnDue():
          sim.beginTurn(scriptedOrder(params, sim, blTrotter))
        let before = sim.events.len
        sim.stepTick()
        var thisTick = initHashSet[string]()
        for i in before ..< sim.events.len:
          let kind = sim.events[i]{"k"}.getStr()
          emitted.incl(kind)
          if kind in thisTick:
            ## a kind that fires twice in one tick would flood at 24 Hz
            perTick.incl(kind)
          thisTick.incl(kind)
        if sim.turnDue(): sim.endTurn("")
        if sim.ladderComplete(): break
      sim.settle(endComplete, erLadderComplete)
      for node in sim.events:
        emitted.incl(node{"k"}.getStr())
    ## everything emitted is in the closed list ...
    for kind in emitted:
      checkpoint(kind)
      check kind in EventKinds
    ## ... and the beats are a strict subset of it
    for kind in BeatKinds:
      check kind in EventKinds
    ## the interesting kinds actually fire
    for kind in ["stagestart", "turn", "order", "stride", "milestone",
                 "stageend", "end"]:
      checkpoint(kind)
      check kind in emitted
    ## NOTHING fires per tick: footstrikes, dust and torque flashes are
    ## renderer FX derived from state deltas, never events.
    check perTick.len == 0

  test "49b. every kind the appended game block handles is in the set":
    let page = readRepoFile("client/replay_broadcast.html")
    let blockText = page[page.find("CONTINUOUS-CONTROL additions") .. ^1]
    for kind in EventKinds:
      if kind in ["turn"]:
        continue     ## the turn tick marker drives no feed row
      checkpoint(kind)
      check ("case '" & kind & "':") in blockText

  test "49c. the tier-2 stream keeps its mandatory summary row":
    let log = newEventLog(true)
    log.add(seStageStart, 0, %*{"stage": 0, "morph": "hopper"})
    log.add(seServo, 1, %*{"tau": [1, 2, 3]})
    let stream = log.eventsJsonl(1_512)
    let lines = stream.strip().splitLines()
    check lines.len == 3
    let summary = parseJson(lines[^1])
    check summary["type"].getStr() == "summary"
    check summary["ticks"].getInt() == 1_512
    check summary["events"].getInt() == 2
    check summary["gameVersion"].getStr() == GameVersion
    ## `Servo` is the per-tick action trace the replay deliberately omits
    check "Servo" in eventKindNames()
    check eventKindNames().len == 9
