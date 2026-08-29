## The broadcast chrome frame: the JSON object the viewer's `onText` parses.
##
## Forked from the starter's `src/ctf/broadcast.nim`, retargeted field for
## field. THE KEYS ABOVE THE FOLD ARE CTF'S OWN (`broadcast.nim:866-892`) and
## are consumed by the BYTE-IDENTICAL `client/chrome_common.js`, so they are
## kept exactly; everything this game adds rides under two namespaced keys,
## `cc` and `orders`, consumed only by the appended game block.
##
## There is exactly ONE `teams` key (`alpha`), so chrome_common's plate loop
## renders one plate, in `#plates-l`, and `#plates-r` stays empty. `roster`
## carries the REAL policy name and is spectator-side only; `cc.body`,
## `cc.order` and the board carry only the alias.

import std/[json, strutils]
import sim_types, trig, body, solver, sim, report, replay_runtime, labels

proc rosterJson*(sim: SimServer): JsonNode =
  ## One entry per seat, keyed by stable join slot. `name` is the SPECTATOR
  ## side — the real policy name — and `alias` is the in-game name.
  result = newJArray()
  for slot, seat in sim.seats:
    result.add(%*{
      "s": slot,
      "team": "alpha",
      "name": (if seat.name.len > 0: seat.name else: seat.policyLabel),
      "pol": (if seat.name.len > 0: seat.name else: seat.policyLabel),
      "col": 0,
      "alive": true,
      "lives": sim.stagesLined,
      "hp": 1,
      "carry": false,
      "k": 0, "d": 0, "cap": 0, "mk2": 0, "mk3": 0, "tk": 0,
      "alias": seat.alias,
      "seat": slot,
      "kind": seat.kind,
      "score": micro3(sim.totalReturnMicro),
      "distance": micro2(sim.distanceTotalMicro()),
      "llmTurns": seat.llmTurns,
      "fallbacks": seat.fallbackTurns,
      "repaired": sim.ordersRepaired})

proc teamsJson*(sim: SimServer): JsonNode =
  ## ONE team, `alpha`, so the inherited scorebug builds exactly one plate — in
  ## `#plates-l`. `#plates-r` stays present but empty: it is one of the
  ## scorebug's three flex columns and removing it would un-centre `#clock`.
  var policies = newJArray()
  for seat in sim.seats:
    policies.add(%(if seat.name.len > 0: seat.name else: seat.policyLabel))
  var done = 0
  for record in sim.stages:
    if record.outcome in {soLined, soRan, soFell}:
      inc done
  %*{
    "alpha": {
      "lives": done,
      "flag": "home",
      "carrier": -1,
      "prog": 0,
      "policies": policies,
      "score": micro3(sim.totalReturnMicro),
      "stagesDone": done,
      "stagesLined": sim.stagesLined,
      "distance": micro2(sim.distanceTotalMicro()),
      "speed": m2(sim.body.links[0].vx),
      "falls": sim.falls,
      "down": sim.phase == phStageReset}}

proc stageLogJson(sim: SimServer): JsonNode =
  result = newJArray()
  for i, record in sim.stages:
    if record.outcome in {soRunning, soUnreached}:
      continue
    result.add(%*{
      "i": i, "morph": $record.morph, "outcome": $record.outcome,
      "distance": micro2(record.distanceMicro),
      "return": micro3(record.returnMicro),
      "ticks": int(record.ticksRun),
      "peak": micro2(record.peakSpeedMicro)})

proc trackMarksJson(sim: SimServer): JsonNode =
  ## A ghost marker for each resolved stage's final distance, so the ladder's
  ## progress is one picture on the 60 m track strip.
  result = newJArray()
  for i, record in sim.stages:
    if record.outcome in {soRunning, soUnreached}:
      continue
    result.add(%*{"i": i, "x": micro2(record.distanceMicro),
                  "outcome": $record.outcome})

proc ccBodyJson(sim: SimServer): JsonNode =
  var links = newJArray()
  for i in 0 ..< sim.spec.linkCount:
    let l = sim.body.links[i]
    links.add(%*{
      "i": i, "name": sim.spec.links[i].name,
      "x": m2(l.x), "y": m2(l.y), "a": degrees(l.a),
      "hl": m2(sim.spec.links[i].hl), "r": m2(sim.spec.links[i].r)})
  var joints = newJArray()
  for j in 0 ..< sim.spec.jointCount:
    joints.add(%*{
      "j": j, "name": sim.spec.joints[j].name,
      "a": degrees(sim.body.jointCoord(sim.spec, j)),
      "tq": sim.torquePct(j), "sat": sim.torquePct(j) >= 100})
  var feet = newJArray()
  for f in 0 ..< sim.spec.footCount:
    let idx = sim.spec.feet[f]
    feet.add(%*{
      "f": f, "name": sim.spec.footNames[f],
      "g": sim.body.footOnGround(sim.spec, f, PenetrationSlopQ16),
      "x": m2(sim.body.links[idx].x), "y": m2(sim.body.links[idx].y),
      "slip": m2(sim.body.footSlip(sim.spec, f))})
  let torso = sim.body.links[0]
  var airborne = true
  for f in 0 ..< sim.spec.footCount:
    if sim.body.footOnGround(sim.spec, f, PenetrationSlopQ16):
      airborne = false
  %*{
    "morph": $sim.morph, "links": links, "joints": joints, "feet": feet,
    "vx": m2(torso.vx), "vy": m2(torso.vy), "spin": dps(torso.w),
    "pitch": degrees(sim.body.torsoPitch(sim.spec)),
    "height": m2(torso.y), "airborne": airborne}

proc feedJson(sim: SimServer): JsonNode =
  result = newJArray()
  for record in sim.feed:
    result.add(record)

proc buildStateJson*(sim: SimServer, events: JsonNode, playing: bool,
                     speed: int, maxTick: int, looping: bool,
                     transportEnabled: bool, mismatchTick: int,
                     startTick = 0, endHoldSeconds = 0, skipLulls = false,
                     fastForwarding = false,
                     lullSpans: seq[array[2, int]] = @[],
                     returnSeries: seq[array[2, int]] = @[],
                     beats: seq[Beat] = @[], sendLead = false): string =
  ## Assembles the broadcast chrome frame. Board-derived STATE is always
  ## present, so even a frame reached by a seek hydrates the scorebug and the
  ## endcard with no events.
  var state = %*{
    "t": sim.tick,
    "mt": sim.config.maxTicks,
    "ph": $sim.phase,
    "lob": sim.lobbyTicks div TargetFps,
    "pl": playing,
    "sp": speed,
    "mx": max(1, maxTick),
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForwarding,
    "en": transportEnabled,
    "mm": mismatchTick,
    "bs": 1,
    "pov": -1,
    "hold": endHoldSeconds,
    "turnTicks": sim.config.turnTicks,
    "turn": sim.turnsPlayed,
    "turns": sim.config.maxTurns,
    "teams": sim.teamsJson(),
    "roster": sim.rosterJson(),
    "events": (if events.isNil: newJArray() else: events)}
  state["cc"] = %*{
    "stage": {
      "index": sim.stageIndex + 1,
      "of": sim.config.stagesPerEpisode,
      "morph": $sim.morph,
      "morphLabel": morphLabel(sim.morph),
      "tick": sim.stageTick,
      "of_ticks": sim.config.stageTicks,
      "terminatesOnFall": sim.spec.terminates,
      "phase": $sim.phase,
      "ppm": pointsPerMetre(sim.morph),
      "log": sim.stageLogJson()},
    "track": {
      "length": 60.0,
      "x": m2(sim.body.links[0].x),
      "best": m2(sim.bestX),
      "cam": m2(sim.body.links[0].x) - 3.0,
      "back": -6.0,
      "marks": sim.trackMarksJson()},
    "body": sim.ccBodyJson(),
    "order": {
      "gait": $sim.activeOrder.gait,
      "cadence": int(sim.activeOrder.cadence),
      "power": int(sim.activeOrder.power),
      "lean": int(sim.activeOrder.lean),
      "stride_bias": int(sim.activeOrder.strideBias),
      "phase_shift": int(sim.activeOrder.phaseShift),
      "stride_hz": sim.strideHz(),
      "cycle_pct": sim.cyclePct(),
      "source": $sim.activeOrder.source,
      "say": sim.activeOrder.say},
    "score": {
      "return": micro3(sim.totalReturnMicro),
      "par": micro3(sim.config.par),
      "max": micro3(maxReturnMicro(sim.config)),
      "falls": sim.falls,
      "lined": sim.stagesLined,
      "saturated": sim.saturatedTicksTotal(),
      "repaired": sim.ordersRepaired,
      "fallbacks": (block:
        var total = 0
        for seat in sim.seats: total += seat.fallbackTurns
        total)},
    "alias": sim.seats[0].alias,
    "name": (if sim.seats[0].name.len > 0: sim.seats[0].name
             else: sim.seats[0].policyLabel),
    "kind": sim.seats[0].kind,
    "reason": $sim.reason,
    "endRule": $sim.endRule,
    "win": sim.episodeWin(),
    "feed": sim.feedJson()}
  var orders = newJArray()
  for record in sim.feed:
    if record{"k"}.getStr() == "order":
      orders.add(%*{
        "turn": record{"turn"}.getInt(),
        "source": record{"source"}.getStr(),
        "gait": record{"gait"}.getStr(),
        "cadence": record{"cadence"}.getInt(),
        "power": record{"power"}.getInt(),
        "lean": record{"lean"}.getInt(),
        "say": record{"say"}.getStr()})
  state["orders"] = orders
  if sendLead:
    ## The full-episode series ships ONCE, on the first frame after the
    ## load-time pre-scan: the progress sparkline, the scrubber beats and the
    ## lull shading all draw at FULL WIDTH on the first frame instead of
    ## growing in.
    var points = newJArray()
    for point in returnSeries:
      points.add(%[point[0], point[1]])
    state["lead"] = %*{"teams": ["alpha"], "pts": points}
    var spans = newJArray()
    for span in lullSpans:
      spans.add(%[span[0], span[1]])
    state["lulls"] = spans
    var beatRows = newJArray()
    for beat in beats:
      beatRows.add(%*{"t": beat.tick, "k": beat.kind, "label": beat.label})
    ## NOT `beats`: the inherited chrome's `ingestBeats` would turn that key
    ## into unlabelled `<div>` markers. The game block reads `cc_beats` and
    ## draws LABELLED, CLICKABLE BUTTONS instead.
    state["cc_beats"] = beatRows
  if sim.phase == phGameOver:
    state["over"] = %*{
      "winner": (if sim.episodeWin(): "alpha" else: ""),
      "draw": false,
      "timeLimit": sim.reason == endDeadline,
      "endRule": $sim.endRule,
      "reason": $sim.reason,
      "score": micro3(sim.totalReturnMicro),
      "ticks": sim.tick,
      "teams": {"alpha": {
        "stagesLined": sim.stagesLined,
        "falls": sim.falls,
        "distance": micro2(sim.distanceTotalMicro()),
        "upright": sim.uprightTicksTotal(),
        "saturated": sim.saturatedTicksTotal()}}}
  $state
