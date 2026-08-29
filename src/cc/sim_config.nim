## The game config lifecycle: `COGAME_CONFIG_URI` in, a validated `GameConfig`
## out, and the RESOLVED config document the replay header pins so playback
## never re-derives anything.
##
## The starter's validators are kept (`src/ctf/sim_config.nim:688-713`) and
## §Decisions' numbers satisfy them: `attempt1Ms` and `retryMs` must be WHOLE
## SECONDS (curl's `CURLOPT_TIMEOUT` granularity is whole seconds, so a 4 500 ms
## deadline really runs with 4 s and is not the deadline it claims to be),
## `attempt1Ms + retryMs <= turnBudgetMs`, and `wallClockBudgetSeconds` must be
## positive and inside 60 % of the platform's `episodeTimeoutSeconds`.

import std/[json, strutils]
import sim_types, body, gaits, trig, solver

proc readCogameUri*(uri, label: string): string =
  ## `file:///...` for local runs; the runner only ever hands the game
  ## container file URIs.
  if uri.startsWith("file://"):
    return readFile(uri[7 .. ^1])
  raise newException(CcError, label & ": unsupported URI scheme: " & uri)

proc getInt(node: JsonNode, key: string, fallback: int): int =
  let value = node{key}
  if value.isNil: return fallback
  case value.kind
  of JInt: int(value.getBiggestInt())
  of JFloat: int(value.getFloat())
  of JString:
    try: value.getStr().strip().parseInt()
    except CatchableError: fallback
  else: fallback

proc getBool(node: JsonNode, key: string, fallback: bool): bool =
  let value = node{key}
  if value.isNil: return fallback
  case value.kind
  of JBool: value.getBool()
  of JInt: value.getBiggestInt() != 0
  else: fallback

proc getMicro(node: JsonNode, key: string, fallback: int64): int64 =
  ## A points value read as micro-points, so `par: 40.0` and `par: 40` are the
  ## same number and neither leaves a float in the sim.
  let value = node{key}
  if value.isNil: return fallback
  case value.kind
  of JInt: value.getBiggestInt() * 1_000_000'i64
  of JFloat:
    let scaled = value.getFloat() * 1_000_000.0
    int64(if scaled >= 0.0: scaled + 0.5 else: scaled - 0.5)
  else: fallback

proc update*(config: var GameConfig, payload: JsonNode) =
  ## Applies the runner's `game_config` over the defaults. Unknown keys are
  ## ignored (the CLI already validated them against `config_schema`);
  ## `tokens` is runner-injected and is never read from a variant.
  if payload.isNil or payload.kind != JObject:
    return
  let players = payload{"players"}
  if not players.isNil and players.kind == JArray and players.len > 0:
    config.players = @[]
    for item in players:
      if item.kind == JObject:
        config.players.add(PlayerSpec(name: item{"name"}.getStr("Alpha")))
      elif item.kind == JString:
        config.players.add(PlayerSpec(name: item.getStr()))
  let tokens = payload{"tokens"}
  if not tokens.isNil and tokens.kind == JArray:
    config.tokens = @[]
    for item in tokens:
      config.tokens.add(item.getStr())
  let slots = payload{"slots"}
  if not slots.isNil and slots.kind == JArray:
    config.slots = @[]
    for item in slots:
      if item.kind == JInt:
        config.slots.add(int(item.getBiggestInt()))
  let seed = payload{"seed"}
  if not seed.isNil and seed.kind in {JInt, JFloat}:
    config.seed = seed.getBiggestInt()
  let ladder = payload{"stageLadder"}
  if not ladder.isNil and ladder.kind == JArray and ladder.len > 0:
    config.stageLadder = @[]
    for item in ladder:
      let parsed = parseMorph(item.getStr())
      if not parsed.ok:
        raise newException(CcError,
          "unknown morphology in stageLadder: " & item.getStr())
      config.stageLadder.add(parsed.morph)
  config.numAgents = payload.getInt("num_agents",
    payload.getInt("numAgents", config.numAgents))
  config.minPlayers = payload.getInt("minPlayers", config.minPlayers)
  config.stagesPerEpisode = payload.getInt(
    "stagesPerEpisode", config.stagesPerEpisode)
  config.stageTicks = payload.getInt("stageTicks", config.stageTicks)
  config.resetTicks = payload.getInt("resetTicks", config.resetTicks)
  config.turnTicks = payload.getInt("turnTicks", config.turnTicks)
  config.maxTurns = payload.getInt("maxTurns", config.maxTurns)
  config.maxTicks = payload.getInt("maxTicks", config.maxTicks)
  config.par = payload.getMicro("par", config.par)
  config.substepsPerTick = payload.getInt(
    "substepsPerTick", config.substepsPerTick)
  config.solverIterations = payload.getInt(
    "solverIterations", config.solverIterations)
  config.stateKeyframeTicks = payload.getInt(
    "stateKeyframeTicks", config.stateKeyframeTicks)
  config.attempt1Ms = payload.getInt("attempt1Ms", config.attempt1Ms)
  config.retryMs = payload.getInt("retryMs", config.retryMs)
  config.turnBudgetMs = payload.getInt("turnBudgetMs", config.turnBudgetMs)
  config.turnSpacingMs = payload.getInt("turnSpacingMs", config.turnSpacingMs)
  config.wallClockBudgetSeconds = payload.getInt(
    "wallClockBudgetSeconds", config.wallClockBudgetSeconds)
  config.lobbyJoinTimeoutTicks = payload.getInt(
    "lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
  config.gameOverTicks = payload.getInt("gameOverTicks", config.gameOverTicks)
  config.fastMode = payload.getBool("fastMode", config.fastMode)
  config.showPlayerLabels = payload.getBool(
    "showPlayerLabels", config.showPlayerLabels)
  config.maxOutputTokens = payload.getInt(
    "maxOutputTokens", config.maxOutputTokens)
  let model = payload{"model"}
  if not model.isNil and model.kind == JString:
    config.model = model.getStr()
  let variant = payload{"variant"}
  if not variant.isNil and variant.kind == JString:
    config.variant = variant.getStr()

proc validate*(config: GameConfig) =
  if config.numAgents != 1:
    raise newException(CcError,
      "num_agents is fixed at 1 in this coworld: continuous control is a " &
      "solitary return-maximisation problem")
  if config.stagesPerEpisode < 1:
    raise newException(CcError, "stagesPerEpisode must be at least 1")
  if config.stageLadder.len != config.stagesPerEpisode:
    raise newException(CcError,
      "stageLadder must have stagesPerEpisode entries")
  if config.turnTicks < 1:
    raise newException(CcError, "turnTicks must be at least 1")
  if config.stageTicks mod config.turnTicks != 0:
    raise newException(CcError, "stageTicks must be a multiple of turnTicks")
  if config.maxTicks !=
      config.stagesPerEpisode * (config.stageTicks + config.resetTicks):
    raise newException(CcError,
      "maxTicks must equal stagesPerEpisode * (stageTicks + resetTicks)")
  if config.maxTurns != config.maxTicks div config.turnTicks:
    raise newException(CcError, "maxTurns must equal maxTicks div turnTicks")
  if config.substepsPerTick < 1 or config.substepsPerTick > 40:
    raise newException(CcError, "substepsPerTick must be in 1 .. 40")
  if config.solverIterations < 1 or config.solverIterations > 64:
    raise newException(CcError, "solverIterations must be in 1 .. 64")
  if config.attempt1Ms mod 1000 != 0 or config.retryMs mod 1000 != 0:
    raise newException(CcError,
      "attempt1Ms and retryMs must be whole seconds: curl's CURLOPT_TIMEOUT " &
      "granularity is whole seconds, so a sub-second remainder is silently " &
      "floored and the deadline is not the one configured")
  if config.attempt1Ms + config.retryMs > config.turnBudgetMs:
    raise newException(CcError,
      "attempt1Ms + retryMs must fit inside turnBudgetMs")
  if config.wallClockBudgetSeconds <= 0:
    raise newException(CcError, "wallClockBudgetSeconds must be positive")
  if config.wallClockBudgetSeconds > 720:
    raise newException(CcError,
      "wallClockBudgetSeconds must stay inside 60 % of the platform's " &
      "1200 s episodeTimeoutSeconds")

proc morphJson*(morph: Morph): JsonNode =
  ## One morphology's whole committed table, so a viewer never has to know it
  ## a priori.
  let s = spec(morph)
  var links = newJArray()
  for i in 0 ..< s.linkCount:
    links.add(%*{
      "name": s.links[i].name, "hl": s.links[i].hl, "r": s.links[i].r,
      "m": s.links[i].m, "invM": s.links[i].invM, "invI": s.links[i].invI,
      "inertia": s.links[i].inertia})
  var joints = newJArray()
  for j in 0 ..< s.jointCount:
    joints.add(%*{
      "name": s.joints[j].name, "parent": s.joints[j].parent,
      "child": s.joints[j].child,
      "pOff": [s.joints[j].pOffX, s.joints[j].pOffY],
      "cOff": [s.joints[j].cOffX, s.joints[j].cOffY],
      "mount": s.joints[j].mount,
      "limit": [s.joints[j].limitLo, s.joints[j].limitHi],
      "tauMax": s.joints[j].tauMax, "side": int(s.joints[j].side)})
  var feet = newJArray()
  for f in 0 ..< s.footCount:
    feet.add(%*{"link": s.feet[f], "name": s.footNames[f]})
  %*{
    "morph": $morph, "links": links, "joints": joints, "feet": feet,
    "rootAngle": s.rootAngle, "terminates": s.terminates,
    "lowY": s.lowY, "highY": s.highY, "maxPitch": s.maxPitch,
    "distNum": s.distNum, "distDen": s.distDen,
    "uprightPerTick": s.uprightPerTick,
    "freqMinMilliHz": int(s.freqMinMilliHz),
    "freqMaxMilliHz": int(s.freqMaxMilliHz)}

proc gaitTableJson*(params: GaitParams): JsonNode =
  result = newJObject()
  for m in Morphs:
    var byGait = newJObject()
    for g in Gaits:
      let row = params.rows[ord(m)][ord(g)]
      var amp = newJArray()
      var phase = newJArray()
      var trim = newJArray()
      var lean = newJArray()
      for j in 0 ..< MaxJoints:
        amp.add(%int(row.ampMilli[j]))
        phase.add(%int(row.phaseMicro[j]))
        trim.add(%int(row.trimMilli[j]))
        lean.add(%int(row.leanMilli[j]))
      byGait[$g] = %*{"amp": amp, "phase": phase, "trim": trim, "lean": lean}
    var kp = newJArray()
    var kd = newJArray()
    for j in 0 ..< MaxJoints:
      kp.add(%int(params.kpMilli[ord(m)][j]))
      kd.add(%int(params.kdMilli[ord(m)][j]))
    byGait["kp"] = kp
    byGait["kd"] = kd
    byGait["kdBrake"] = %int(params.kdBrakeMilli[ord(m)])
    result[$m] = byGait

proc solverJson*(config: GameConfig): JsonNode =
  %*{
    "gravity": GravityQ16, "substepsPerTick": config.substepsPerTick,
    "solverIterations": config.solverIterations,
    "baumgarte": [BaumgarteNum, BaumgarteDen],
    "jointLimitBias": [JointLimitBiasNum, JointLimitBiasDen],
    "penetrationSlop": PenetrationSlopQ16,
    "groundFriction": GroundFrictionQ16,
    "groundRestitution": GroundRestitution,
    "maxLinSpeed": MaxLinSpeedQ16, "maxAngSpeed": MaxAngSpeedQ16,
    "detEps": DetEpsQ16, "groundY": GroundY,
    "trackStartX": 0, "trackLineX": 60 * OneQ16, "trackBackX": -6 * OneQ16,
    "initPerturb": 3_277}

proc configJson*(config: GameConfig): JsonNode =
  ## The RESOLVED config, written into the replay header so the bytes are
  ## SELF-SUFFICIENT: a spectator holding the file can reconstruct every rule,
  ## every morphology and the whole gait table without a fetch.
  var players = newJArray()
  for player in config.players:
    players.add(%*{"name": player.name})
  var slots = newJArray()
  for slot in config.slots:
    slots.add(%slot)
  var ladder = newJArray()
  for morph in config.stageLadder:
    ladder.add(%($morph))
  var morphs = newJObject()
  for m in Morphs:
    morphs[$m] = morphJson(m)
  %*{
    "seed": config.seed,
    "variant": config.variant,
    "num_agents": config.numAgents,
    "minPlayers": config.minPlayers,
    "stageLadder": ladder,
    "stagesPerEpisode": config.stagesPerEpisode,
    "stageTicks": config.stageTicks,
    "resetTicks": config.resetTicks,
    "turnTicks": config.turnTicks,
    "maxTurns": config.maxTurns,
    "maxTicks": config.maxTicks,
    "par": config.par,
    "substepsPerTick": config.substepsPerTick,
    "solverIterations": config.solverIterations,
    "stateKeyframeTicks": config.stateKeyframeTicks,
    "attempt1Ms": config.attempt1Ms,
    "retryMs": config.retryMs,
    "turnBudgetMs": config.turnBudgetMs,
    "turnSpacingMs": config.turnSpacingMs,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "gameOverTicks": config.gameOverTicks,
    "fastMode": config.fastMode,
    "showPlayerLabels": config.showPlayerLabels,
    "maxOutputTokens": config.maxOutputTokens,
    "players": players,
    "slots": slots,
    "morphs": morphs,
    "gaits": gaitTableJson(GaitTable),
    "solver": solverJson(config)}

proc configFromJson*(payload: JsonNode): GameConfig =
  ## The inverse of `configJson` — what the replay runtime rebuilds the sim
  ## from, so a constant this build happened to change can never alter an old
  ## replay.
  result = defaultConfig()
  result.update(payload)
