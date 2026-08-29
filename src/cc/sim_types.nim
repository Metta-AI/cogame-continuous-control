## cogame-continuous-control — shared types, wire caps and game constants.
##
## Forked from `coworld-ctf`'s `src/ctf/sim_types.nim`: the `GameVersion`
## prepend-only changelog discipline, `TargetFps` / `ReplayFps`, the closed
## `reason` / `endRule` string vocabularies, the websocket route names and the
## RUNE caps every recorded string is truncated against are that file's,
## because they are what keeps a replay parseable by a strict UTF-8 reader.
##
## GameVersion changelog — PREPEND ONLY, one line per bump:
##   "1"  first release: hopper / cheetah / walker down a 60 m track, gait
##        orders every 36 ticks over a Q16 integer multibody sim.
##
## INTEGER DISCIPLINE. Every stored sim field is explicitly `int32`, `int64`,
## `uint8`, `bool` or an enum: Nim's `int` is 64-bit natively and 32-bit under
## `--cpu:wasm32`, and the replay's per-tick `gameHash` chain is re-derived by
## the wasm build of this same module. There is NO floating point anywhere
## under `src/cc/{sim,solver,body,driver,gaits,trig}.nim` (grep-enforced by
## tests/test_cc_sim.nim 13).

import std/[strutils, unicode]

const
  GameName* = "continuous-control"
  GameVersion* = "1"
  ProtocolName* = "continuous-control/v1"

  ## --- Time (kept verbatim from ctf: sim_types.nim:401, :342) -------------
  TargetFps* = 24
  ReplayFps* = 24
  PlaybackSpeeds* = [1, 2, 4, 8]

  ## --- Rune caps. RE-PINNED in this fork (§Decisions → reply schema): the
  ## starter's MaxSayRunes = ShoutMaxChars = 10 is an in-world shout and its
  ## MaxNoteRunes = 160 is a short note; a cog narrating a gait needs a
  ## sentence and a cog carrying "do not exceed power 88 on this body" between
  ## turns needs more than 160 runes.
  MaxSayRunes* = 140
  MaxNoteRunes* = 320
  MaxPolicyLabelRunes* = 48
  MaxPromptRunes* = 4000
  MaxFallbackDetailRunes* = 200
  MaxStopDetailRunes* = 200
  MaxOrderRecordRunes* = 6000
  MaxReplyBytes* = 4096
  MaxGaitRunes* = 8

  ## --- Websocket + HTTP routes (kept verbatim from ctf) --------------------
  WebSocketPath* = "/player"
  GlobalWebSocketPath* = "/global"
  ReplayWebSocketPath* = "/replay"
  DefaultHost* = "0.0.0.0"
  DefaultPort* = 8080

  ## --- Board render space --------------------------------------------------
  ## 1 board pixel = 6 250 um, so the camera viewport is 9.00 m x 6.00 m of
  ## world at 1440 x 960 logical map pixels (BOARD_ASPECT 1.5 — the aspect the
  ## starter's chrome was authored against). 1 382 400 map pixels sits well
  ## under ctf's MaxSupersampledMapPixels (8 000 000), so `boardRenderScaleFor`
  ## still returns RenderScale 2 and `predictedViewerRenderBytes(1440, 960)` is
  ## ~122 MB against WasmViewerBudgetBytes 1 600 000 000 — 13x headroom.
  MapWidth* = 1440
  MapHeight* = 960
  UmPerPixel* = 6_250

  MaxLinks* = 7
  MaxJoints* = 6
  MaxFeet* = 4
  MaxContacts* = 2 * MaxLinks

  BroadcastChromeSpriteId* = 4090
    ## Reserved 1x1 never-drawn sprite whose LABEL carries the broadcast chrome
    ## JSON. Smuggling the chrome through the same binary channel the board
    ## rides is what makes it survive a hosted replay.

type
  CcError* = object of CatchableError
  SimGuardError* = object of CcError
    ## A step-8 invariant guard tripped: the episode ends `fault`, with the
    ## partial replay written, never a silent non-zero exit.

  Morph* = enum
    ## The three planar morphologies. Array order everywhere; never reorder.
    mHopper = "hopper"
    mCheetah = "cheetah"
    mWalker = "walker"

  Gait* = enum
    ## The closed order enum. An unrecognised gait is repaired to LAST turn's,
    ## else the stage's first-turn default — never dropped.
    gStand = "stand"
    gCrouch = "crouch"
    gWalk = "walk"
    gRun = "run"
    gBound = "bound"
    gBrake = "brake"

  StageOutcome* = enum
    soRunning = "running"
    soLined = "lined"
    soRan = "ran"
    soFell = "fell"
    soUnreached = "unreached"

  FallWhy* = enum
    fwNone = "none"
    fwLow = "low"
    fwHigh = "high"
    fwPitched = "pitched"

  Phase* = enum
    phLobby = "lobby"
    phPlaying = "playing"
    phStageReset = "stagereset"
    phGameOver = "gameover"

  EndReason* = enum
    ## The starter's closed enum. Exactly these three values are legal.
    endComplete = "complete"
    endDeadline = "deadline"
    endFault = "fault"

  EndRule* = enum
    erLadderComplete = "ladderComplete"
    erTurnCap = "turnCap"
    erWallClock = "wallClock"
    erFault = "fault"

  OrderSource* = enum
    osLlm = "llm"
    osScripted = "scripted"
    osFallback = "fallback"

  PlayerSpec* = object
    name*: string

  GameConfig* = object
    ## The resolved episode configuration. Every field is also a
    ## `game.config_schema` property in `coworld_manifest_template.json`, and
    ## `tests/test_cc_manifest.nim` asserts that every variant's `game_config`
    ## constructs one of these.
    players*: seq[PlayerSpec]
    slots*: seq[int]
    tokens*: seq[string]
    seed*: int64
    numAgents*: int
    minPlayers*: int
    stageLadder*: seq[Morph]
    stagesPerEpisode*: int
    stageTicks*: int
    resetTicks*: int
    turnTicks*: int
    maxTurns*: int
    maxTicks*: int
    par*: int64                 ## micro-points
    substepsPerTick*: int
    solverIterations*: int
    stateKeyframeTicks*: int
    attempt1Ms*: int
    retryMs*: int
    turnBudgetMs*: int
    turnSpacingMs*: int
    wallClockBudgetSeconds*: int
    lobbyJoinTimeoutTicks*: int
    gameOverTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    model*: string
    maxOutputTokens*: int
    variant*: string

const
  Gaits* = [gStand, gCrouch, gWalk, gRun, gBound, gBrake]
  Morphs* = [mHopper, mCheetah, mWalker]
  GaitNames* = ["stand", "crouch", "walk", "run", "bound", "brake"]

proc parseMorph*(text: string): tuple[ok: bool, morph: Morph] =
  for m in Morph:
    if $m == text.strip().toLowerAscii():
      return (true, m)
  (false, mHopper)

proc parseGait*(text: string): tuple[ok: bool, gait: Gait] =
  ## Case-insensitive, whitespace-trimmed, with the synonyms a model actually
  ## emits (§Decisions → reply schema).
  case text.strip().toLowerAscii()
  of "stand", "idle", "hold": (true, gStand)
  of "crouch", "squat": (true, gCrouch)
  of "walk", "march": (true, gWalk)
  of "run", "sprint", "gallop", "trot": (true, gRun)
  of "bound", "hop", "leap": (true, gBound)
  of "brake", "stop", "halt": (true, gBrake)
  else: (false, gWalk)

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single place
  ## any recorded string is shortened. Byte truncation is what makes a replay
  ## that renders in a browser fail a strict UTF-8 parser.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc seatAlias*(slot: int): string =
  ## `IdentityNames[slot]` title-cased (the starter's `roster.nim:64-65`).
  ## With one seat this is always `Alpha`, and it is the ONLY name that appears
  ## in an observation, in a prompt, in a `say`, or drawn on the board.
  const Names = ["Alpha", "Bravo", "Charlie", "Delta"]
  if slot >= 0 and slot < Names.len: Names[slot] else: "Cog"

proc defaultLadder*(): seq[Morph] = @[mHopper, mCheetah, mWalker]

proc defaultConfig*(): GameConfig =
  ## The `ladder` variant's numbers, which are also every test's starting
  ## point. `sim_config.update` overwrites them from the runner's JSON.
  GameConfig(
    players: @[PlayerSpec(name: "Alpha")],
    slots: @[],
    tokens: @[],
    seed: 1,
    numAgents: 1,
    minPlayers: 1,
    stageLadder: defaultLadder(),
    stagesPerEpisode: 3,
    stageTicks: 468,
    resetTicks: 36,
    turnTicks: 36,
    maxTurns: 42,
    maxTicks: 1512,
    par: 40_000_000'i64,
    substepsPerTick: 10,
    solverIterations: 12,
    stateKeyframeTicks: 48,
    attempt1Ms: 6000,
    retryMs: 3000,
    turnBudgetMs: 9000,
    turnSpacingMs: 2600,
    wallClockBudgetSeconds: 690,
    lobbyJoinTimeoutTicks: 2400,
    gameOverTicks: 96,
    fastMode: true,
    showPlayerLabels: false,
    model: "",
    maxOutputTokens: 900,
    variant: "ladder")
