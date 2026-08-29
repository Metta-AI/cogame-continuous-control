## Bounded orders, the fallback identity, the validator and baseline strength —
## §Tests 22-25.

import std/[json, random, strutils, unicode, unittest]
import cc/[sim, sim_config, report, directives, baselines, decide]
import helpers

const Seeds = when defined(release): 100 else: 12

suite "the scripted baselines":
  test "22. baselines are bounded and legal in every state":
    var rng = initRand(22)
    var bad = 0
    let params = defaultBaselineParams()
    for morph in Morphs:
      for _ in 0 ..< 100:
        var config = ladderConfig(@[morph, morph, morph],
          int64(rng.rand(1 .. 99_999)))
        var sim = newSimServer(config)
        sim.phase = phPlaying
        sim.startStage(0)
        ## mid-stage and fresh, upright and falling, all three stage phases
        for _ in 0 ..< rng.rand(0 .. 60):
          if sim.turnDue(): sim.beginTurn(defaultOrder())
          sim.stepTick()
        if rng.rand(0 .. 1) == 1:
          sim.body.links[0].a = wrapAngle(sim.spec.rootAngle +
            int64(rng.rand(-40_000 .. 40_000)))
        for kind in [blTrotter, blPlodder]:
          let order = scriptedOrder(params, sim, kind)
          if not order.isBounded(): inc bad
          if order.say.len != 0 or order.notes.len != 0: inc bad
          if ($orderJson(order)).len > 512: inc bad
          ## the gait is in the closed enum by construction
          check order.gait in {gStand, gCrouch, gWalk, gRun, gBound, gBrake}
    check bad == 0

  test "23. the fallback IS the trotter proc":
    ## The decision engine's fallback path and the `trotter` baseline resolve
    ## to the same proc, so they cannot drift.
    var config = ladderConfig(@[mWalker, mWalker, mWalker], 5)
    var sim = newSimServer(config)
    sim.phase = phPlaying
    sim.startStage(0)
    for _ in 0 ..< 40:
      if sim.turnDue(): sim.beginTurn(defaultOrder())
      sim.stepTick()
    var engine = initDecisionEngine(sim)
    engine.seats[0].isLlm = true
    ## no credentials -> the engine falls straight back
    let outcome = engine.turn(sim, 1, 0)
    let scripted = scriptedOrder(engine.params, sim, blTrotter)
    check outcome.order.source == osFallback
    check outcome.order.gait == scripted.gait
    check outcome.order.cadence == scripted.cadence
    check outcome.order.power == scripted.power
    check outcome.order.lean == scripted.lean
    check outcome.order.strideBias == scripted.strideBias
    var sawFallback = false
    for record in outcome.records:
      if parseJson(record){"k"}.getStr() == "fallback": sawFallback = true
    check sawFallback

suite "the reply validator":
  test "24. tolerant parsing, clamping, inheritance and rune truncation":
    let previous = Order(gait: gRun, cadence: 71, power: 83, lean: 9,
      strideBias: 4, phaseShift: 25)
    ## the schema, accepted as written
    let clean = parseOrderReply(
      """{"gait":"bound","cadence":40,"power":50,"lean":-20,""" &
      """"stride_bias":10,"phase_shift":-30}""", previous, true)
    check clean.gait == gBound
    check clean.cadence == 40
    check clean.power == 50
    check clean.lean == -20
    check clean.strideBias == 10
    check clean.phaseShift == -30
    check clean.repaired == 0
    ## an out-of-range number is CLAMPED, never dropped, and counted
    let clamped = parseOrderReply(
      """{"gait":"run","cadence":180,"power":-40,"lean":900}""",
      previous, true)
    check clamped.cadence == 100
    check clamped.power == 0
    check clamped.lean == 50
    check clamped.repaired == 3
    ## a missing field inherits LAST TURN's value ...
    let inherited = parseOrderReply("""{"cadence":55}""", previous, true)
    check inherited.gait == previous.gait
    check inherited.power == previous.power
    check inherited.lean == previous.lean
    ## ... and `phase_shift` is a ONE-OFF nudge, never inherited
    check inherited.phaseShift == 0
    ## ... and on the first turn of a stage it takes the gait's default
    let fresh = parseOrderReply("""{"cadence":55}""", previous, false)
    check fresh.gait == defaultOrder().gait
    check fresh.power == defaultOrder().power
    ## synonyms, case and whitespace
    for pair in [("SPRINT", gRun), (" Gallop ", gRun), ("trot", gRun),
                 ("HOP", gBound), ("leap", gBound), ("stop", gBrake),
                 ("halt", gBrake), ("idle", gStand), ("hold", gStand)]:
      let parsed = parseOrderReply("""{"gait":"""" & pair[0] & """"}""",
        previous, true)
      check parsed.gait == pair[1]
    ## numeric strings, markdown fences and trailing prose
    let messy = parseOrderReply(
      "here you go:\n```json\n{\"gait\":\"walk\",\"cadence\":\"62\"}\n```\nok",
      previous, true)
    check messy.gait == gWalk
    check messy.cadence == 62
    ## a fractional -1.0 .. 1.0 lean is a fraction of the range
    let fractional = parseOrderReply("""{"lean":0.4,"stride_bias":-0.5}""",
      previous, true)
    check fractional.lean == 20
    check fractional.strideBias == -25
    ## a cadence given in HERTZ maps onto the morphology's band
    let hertz = parseOrderReply("""{"cadence":2.4}""", previous, true)
    check hertz.cadence == 50
    ## a `say`-only reply is USABLE: last turn's order continues
    let narration = parseOrderReply("""{"say":"holding the gallop"}""",
      previous, true)
    check narration.gait == previous.gait
    check narration.cadence == previous.cadence
    check narration.say == "holding the gallop"
    ## a non-object is a parse failure
    expect OrderError:
      discard parseOrderReply("[1,2,3]", previous, true)
    expect OrderError:
      discard parseOrderReply("no json here at all", previous, true)
    expect OrderError:
      discard parseOrderReply("""{"unknown":1}""", previous, true)
    ## the whole reply is capped at 4096 BYTES before parsing
    expect OrderError:
      discard parseOrderReply("""{"gait":"run","notes":"""" &
        repeat("x", 5000) & """"}""", previous, true)
    ## RUNE-boundary truncation with 4-byte emoji sitting exactly on the cap
    let emoji = "\u{1F9BF}"          ## a 4-byte codepoint
    let longSay = repeat(emoji, MaxSayRunes + 20)
    let longNote = repeat(emoji, MaxNoteRunes + 20)
    let truncated = parseOrderObject(%*{
      "gait": "run", "say": longSay, "notes": longNote}, previous, true)
    check truncated.say.runeLen == MaxSayRunes
    check truncated.notes.runeLen == MaxNoteRunes
    check truncated.say.len == MaxSayRunes * 4
    check truncated.notes.len == MaxNoteRunes * 4
    check truncated.repaired >= 1
    ## and validateUtf8 finds no broken codepoint
    check validateUtf8(truncated.say) == -1
    check validateUtf8(truncated.notes) == -1

suite "baseline strength":
  test "25. the shipped baselines sit inside their pinned band":
    ## MEASURED bands over the SEED DISTRIBUTION, not per-seed literals:
    ## the seeded per-joint start wobble genuinely decides whether a walker
    ## finds its stride or trips at 2 m, and pinning a per-seed floor would
    ## pin the wobble out of the game. Neither a zero floor nor a superhuman
    ## filler can ship, which is what this gate is for; `docs/PHYSICS.md`
    ## records the numbers and why the hopper's band is where it is.
    var
      trotterTotal = 0.0
      plodderTotal = 0.0
      dist: array[3, float]
      lowFalls = 0
      plodderLower = 0
      worstTrotter = 1.0e9
      bestTrotter = -1.0e9
    for seed in 1 .. Seeds:
      let config = ladderConfig(@[mHopper, mCheetah, mWalker], int64(seed * 7))
      let t = runScriptedEpisode(config, blTrotter)
      let p = runScriptedEpisode(config, blPlodder)
      let tTotal = float(t.sim.totalReturnMicro) / 1_000_000.0
      let pTotal = float(p.sim.totalReturnMicro) / 1_000_000.0
      trotterTotal += tTotal
      plodderTotal += pTotal
      worstTrotter = min(worstTrotter, tTotal)
      bestTrotter = max(bestTrotter, tTotal)
      for i in 0 .. 2:
        dist[i] += float(t.sim.stages[i].distanceMicro) / 1_000_000.0
      if t.sim.falls <= 2: inc lowFalls
      if pTotal < tTotal: inc plodderLower
    let n = float(Seeds)
    ## `trotter` covers real ground on every morphology ...
    check dist[0] / n > 0.3          ## hopper
    check dist[0] / n < 14.0
    check dist[1] / n > 20.0         ## cheetah
    check dist[1] / n < 58.0
    check dist[2] / n > 8.0          ## walker
    check dist[2] / n < 30.0
    ## ... straddles a meaningful bar rather than rubber-stamping par ...
    check trotterTotal / n > 25.0
    check trotterTotal / n < 90.0
    check worstTrotter > -10.0
    check bestTrotter < 130.0
    ## ... and `plodder` is the FLOOR: lower on almost every seed, and never
    ## a superhuman filler.
    check plodderTotal / n > 5.0
    check plodderTotal / n < trotterTotal / n
    check plodderLower * 100 >= Seeds * 80
    check lowFalls * 100 >= Seeds * 80
