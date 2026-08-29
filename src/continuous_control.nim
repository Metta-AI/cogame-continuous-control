## The continuous-control entrypoint: reads the Coworld runtime contract and
## starts either a live episode server or a replay viewer server.
##
## SEED RANDOMISATION HAPPENS HERE, BEFORE `config.update`, so every
## seed-derived draw — the per-joint start perturbation of every stage —
## follows the FINAL seed (paintbot's rule, `src/ctf.nim:7-46`). The seed is
## randomised by the runner, recorded in the replay config and in
## `results.seed`, and NEVER disclosed to the seat.

import std/[json, strutils, sysrand]
import bitworld/runtime
import cc/[server, sim_config, sim_types]

proc randomSeed(): int64 =
  var buf: array[8, byte]
  if not urandom(buf):
    raise newException(CcError, "OS entropy source unavailable")
  var value: int64 = 0
  for b in buf:
    value = (value shl 8) or int64(b)
  value and 0x7FFF_FFFF_FFFF_FFFF'i64

proc seedPinned(configText: string): bool =
  if configText.strip().len == 0:
    return false
  try:
    let node = parseJson(configText)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false

when isMainModule:
  var runtimeConfig: RuntimeConfig
  try:
    runtimeConfig = readRuntimeConfig()
  except CatchableError as error:
    quit("continuous-control: bad runtime configuration: " & error.msg, 2)

  if runtimeConfig.replayMode:
    runReplayServer(runtimeConfig)
  else:
    if runtimeConfig.config.strip().len == 0:
      quit("continuous-control: COGAME_CONFIG_URI is required " &
        "(no game config given)", 2)
    var config = defaultConfig()
    if not seedPinned(runtimeConfig.config):
      config.seed = randomSeed()
      echo "continuous-control: seed not pinned; randomized"
    try:
      config.update(parseJson(runtimeConfig.config))
    except CatchableError as error:
      quit("continuous-control: invalid game config: " & error.msg, 2)
    try:
      config.validate()
    except CatchableError as error:
      quit("continuous-control: invalid game config: " & error.msg, 2)
    if config.tokens.len == 0:
      quit("continuous-control: the game config must carry one token per " &
        "seat", 2)
    if config.players.len != config.numAgents:
      quit("continuous-control: the game config must name " &
        $config.numAgents & " players", 2)
    echo "continuous-control: seats=", config.numAgents,
      " variant=", config.variant,
      " stages=", config.stagesPerEpisode,
      " stageTicks=", config.stageTicks,
      " maxTicks=", config.maxTicks,
      " turnTicks=", config.turnTicks,
      " wallClock=", config.wallClockBudgetSeconds, "s",
      " model=", config.model
    try:
      runGameServer(config, runtimeConfig)
    except CatchableError as error:
      quit("continuous-control: " & error.msg, 2)
