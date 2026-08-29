## The replay — §Tests 34-38.

import std/[json, os, osproc, strutils, unicode, unittest]
import cc/[sim, sim_config, report, directives, baselines, replays,
           replay_runtime, decide]
import helpers

proc hashesMatch(bytes: string): tuple[ok: bool, tick: int] =
  let derived = rederive(bytes)
  (derived.player.hashMismatchTick < 0 and
     derived.player.keyframeMismatchTick < 0,
   derived.player.hashMismatchTick)

suite "record, then re-derive":
  test "34. every end reason re-derives, INCLUDING its stop tick":
    let config = ladderConfig(@[mHopper, mCheetah, mWalker], 31337)
    for run in [runScriptedEpisode(config),
                runScriptedEpisode(config, stopAtTurn = 7),
                runScriptedEpisode(config, faultAtTurn = 5)]:
      let derived = rederive(run.bytes)
      checkpoint($run.sim.reason & "/" & $run.sim.endRule)
      ## identical hashes at EVERY tick, including the stop tick
      check derived.player.hashMismatchTick == -1
      ## identical STATE at every recorded keyframe
      check derived.player.keyframeMismatchTick == -1
      check derived.sim.reason == run.sim.reason
      check derived.sim.endRule == run.sim.endRule
      check derived.sim.tick == run.sim.tick
      check derived.sim.totalReturnMicro == run.sim.totalReturnMicro
    ## the turn cap, as its own end reason
    var capped = config
    capped.stageTicks = 36
    capped.resetTicks = 36
    capped.maxTicks = 3 * 72
    capped.maxTurns = capped.maxTicks div capped.turnTicks
    capped.validate()
    let short = runScriptedEpisode(capped)
    let derivedShort = rederive(short.bytes)
    check derivedShort.player.hashMismatchTick == -1
    check derivedShort.sim.tick == short.sim.tick

  test "35. the replay is self-sufficient":
    let run = runScriptedEpisode(ladderConfig(
      @[mHopper, mCheetah, mWalker], 4711))
    let data = parseReplayBytes(run.bytes)
    check data.gameName == GameName
    check data.gameVersion == GameVersion
    check data.protocol == ProtocolName
    ## the seed, the variant, num_agents and every rule constant
    check data.config["seed"].getBiggestInt() == 4711
    check data.config["variant"].getStr() == "ladder"
    check data.config["num_agents"].getInt() == 1
    for key in ["stagesPerEpisode", "stageTicks", "resetTicks", "turnTicks",
                "maxTurns", "maxTicks", "par", "substepsPerTick",
                "solverIterations", "stateKeyframeTicks", "attempt1Ms",
                "retryMs", "turnBudgetMs", "turnSpacingMs",
                "wallClockBudgetSeconds", "fastMode"]:
      check data.config.hasKey(key)
    ## the WHOLE MorphTable and the WHOLE GaitTable
    for morph in Morphs:
      let m = data.config["morphs"][$morph]
      check m["links"].len == spec(morph).linkCount
      check m["joints"].len == spec(morph).jointCount
      check m["links"][0].hasKey("hl")
      check m["joints"][0].hasKey("tauMax")
      let g = data.config["gaits"][$morph]
      for gait in Gaits:
        check g[$gait]["amp"].len == MaxJoints
        check g[$gait]["phase"].len == MaxJoints
        check g[$gait]["trim"].len == MaxJoints
        check g[$gait]["lean"].len == MaxJoints
      check g["kp"].len == MaxJoints
      check g["kdBrake"].getInt() > 0
    check data.config["solver"]["gravity"].getBiggestInt() == 642_908
    ## the seat's REAL name, its alias, the policy kind, all three stage
    ## records with their perturbations, every order and the result
    var stages = 0
    var orders = 0
    var keyframes = 0
    for record in data.records:
      case record.kind
      of rkStage:
        inc stages
        check record.stage.perturb.len == MaxJoints
      of rkOrder: inc orders
      of rkKeyframe:
        inc keyframes
        check record.keyframe.words.len ==
          6 * spec(mHopper).linkCount or record.keyframe.words.len ==
          6 * spec(mCheetah).linkCount
      else: discard
    check stages == 3
    check orders >= 12
    check keyframes >= 12
    var sawRegister = false
    var sawResult = false
    for node in data.chatRecords():
      case node{"k"}.getStr()
      of "register":
        sawRegister = true
        check node{"alias"}.getStr() == "Alpha"
        check node{"kind"}.getStr() == "scripted"
        ## the PROMPT is never written
        check not node.hasKey("prompt")
      of "result":
        sawResult = true
        check node["results"]["names"][0].getStr().len > 0
      else: discard
    check sawRegister
    check sawResult
    ## and re-simulating from them reproduces every frame with NO fetch
    check hashesMatch(run.bytes).ok

  test "36. keyframes are a cross-check, not a crutch":
    let run = runScriptedEpisode(ladderConfig(
      @[mHopper, mCheetah, mWalker], 606))
    ## a corrupted KEYFRAME is detected and the viewer resyncs from it
    var data = parseReplayBytes(run.bytes)
    var corruptedIndex = -1
    for i, record in data.records:
      if record.kind == rkKeyframe and record.tick > 100:
        corruptedIndex = i
        break
    check corruptedIndex >= 0
    data.records[corruptedIndex].keyframe.words[1] += 5_000
    var sim = newSimFromReplay(data)
    var player = ReplayPlayer(data: data, hashMismatchTick: -1,
      keyframeMismatchTick: -1, playing: true, maxTick: run.sim.tick)
    player.rewind(sim)
    while sim.phase != phGameOver and sim.tick < player.maxTick:
      let before = sim.tick
      player.stepReplay(sim)
      if sim.tick == before: break
    check player.keyframeMismatchTick >= 0
    ## a corrupted HASH is detected at the exact tick
    var data2 = parseReplayBytes(run.bytes)
    data2.hashes[120] = data2.hashes[120] xor 1'u64
    var sim2 = newSimFromReplay(data2)
    var player2 = ReplayPlayer(data: data2, hashMismatchTick: -1,
      keyframeMismatchTick: -1, playing: true, maxTick: run.sim.tick)
    player2.rewind(sim2)
    while sim2.phase != phGameOver and sim2.tick < player2.maxTick:
      let before = sim2.tick
      player2.stepReplay(sim2)
      if sim2.tick == before: break
    check player2.hashMismatchTick == 121

  test "37. replay_summary.py emits strict UTF-8 JSON":
    ## Every capped field filled to EXACTLY its cap with 4-byte emoji.
    let emoji = "\u{1F9BF}"
    var config = ladderConfig(@[mHopper, mCheetah, mWalker], 8_181)
    var sim = newSimServer(config)
    let writer = newReplayWriter(configJson(config))
    sim.phase = phPlaying
    sim.startStage(0)
    writer.writeChat(0, registerRecord(0, seatAlias(0),
      repeat(emoji, MaxPolicyLabelRunes), repeat(emoji, MaxPolicyLabelRunes),
      "scripted", "trotter"))
    writer.writeStage(0, StagePayload(index: 0, morph: mHopper,
      perturb: sim.stages[0].perturb, startTick: 0))
    writer.writeKeyframe(0, sim.keyframeWords())
    var order = defaultOrder()
    order.say = repeat(emoji, MaxSayRunes)
    order.notes = repeat(emoji, MaxNoteRunes)
    writer.writeOrder(0, OrderPayload(turn: 1, stage: 0, source: osLlm,
      gait: order.gait, cadence: order.cadence, power: order.power,
      lean: order.lean, strideBias: order.strideBias,
      phaseShift: order.phaseShift, repaired: 0, say: order.say,
      notes: order.notes))
    sim.beginTurn(order)
    for _ in 0 ..< 60:
      sim.stepTick()
      writer.writeHash(sim.gameHashValue)
    sim.settle(endComplete, erLadderComplete)
    sim.stopDetail = repeat(emoji, MaxStopDetailRunes)
    writer.writeStop(StopPayload(tick: sim.tick, reason: endFault,
      endRule: erFault, detail: repeat(emoji, MaxStopDetailRunes)))
    writer.writeChat(sim.tick, resultRecord(sim))
    let path = getTempDir() / "cc-summary-test.replay"
    writeFile(path, writer.bytes())
    let script = repoRoot() / "tools" / "replay_summary.py"
    let (output, code) = execCmdEx("python3 " & quoteShell(script) & " " &
      quoteShell(path))
    removeFile(path)
    check code == 0
    ## strict UTF-8 JSON with no lone surrogates
    check validateUtf8(output) == -1
    check "\\ud" notin output.toLowerAscii()
    let summary = parseJson(output)
    check summary["protocol"].getStr() == "continuous-control/v1"
    check summary["gameVersion"].getStr() == GameVersion
    check summary["orders"][0]["say"].getStr().runeLen == MaxSayRunes
    check summary["stop"]["endRule"].getStr() == "fault"
    check summary["tickCount"].getInt() == 60

  test "38. every committed fixture carries the current GameVersion":
    let run = runScriptedEpisode(ladderConfig(
      @[mHopper, mCheetah, mWalker], 1234))
    check parseReplayBytes(run.bytes).gameVersion == GameVersion
    ## the starter's sweep over tests/, kept: any fixture in the tree must
    ## carry this GameVersion or it is a stale recording.
    let fixtures = repoRoot() / "tests" / "fixtures"
    if dirExists(fixtures):
      for path in walkFiles(fixtures / "*.replay"):
        check parseReplayBytes(readFile(path)).gameVersion == GameVersion
