## Persistent JSONL bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:cc-train-bridge tools/train_bridge.nim

import std/[json, os]
import cc/[baselines, directives, llm, report, sim, sim_config]

const
  OperatorPrompt = "Drive each machine down the track using the observed joint and stride feedback."
  Variants = ["ladder", "bipeds"]
  Gaits = ["stand", "crouch", "walk", "run", "bound", "brake"]
  Fields = ["gait", "cadence", "power", "lean", "stride_bias", "phase_shift"]

proc seedOf(value: string): int64 =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int64(hash and 0x7fffffff'u32) + 1

proc heads(): JsonNode =
  result = newJArray()
  var gaits = newJArray()
  for gait in Gaits:
    gaits.add(%gait)
  result.add(%*{"name": "gait", "choices": gaits})
  for field in Fields[1 .. ^1]:
    var choices = newJArray()
    let offset = if field in ["lean", "stride_bias", "phase_shift"]: -50 else: 0
    for index in 0 .. 100:
      choices.add(%(index + offset))
    result.add(%*{"name": field, "choices": choices})

proc number(node: JsonNode): float =
  case node.kind
  of JInt: node.getInt().float
  of JFloat: node.getFloat()
  else: raise newException(ValueError, "expected numeric observation")

proc values(view: JsonNode, variant: string): JsonNode =
  result = newJArray()
  for name in Variants:
    result.add(%(if variant == name: 1 else: 0))
  for field in ["turn", "of", "tick"]:
    result.add(%view[field].number())
  let stage = view["stage"]
  for field in ["index", "of", "tick", "of_ticks", "turns_left",
      "points_per_metre", "upright_points_per_second"]:
    result.add(%stage[field].number())
  for name in ["hopper", "cheetah", "walker"]:
    result.add(%(if stage["morph"].getStr() == name: 1 else: 0))
  result.add(%(if stage["terminates_on_fall"].getBool(): 1 else: 0))
  for field in ["length_m", "x_m", "best_x_m", "to_line_m"]:
    result.add(%view["track"][field].number())
  let body = view["body"]
  for field in ["height_m", "pitch_deg", "vx_m_s", "vy_m_s", "spin_dps"]:
    result.add(%body["torso"][field].number())
  for index in 0 ..< MaxJoints:
    if index < body["joints"].len:
      let joint = body["joints"][index]
      for field in ["angle_deg", "rate_dps", "torque_pct"]:
        result.add(%joint[field].number())
      for limit in joint["limit_deg"]:
        result.add(%limit.number())
      result.add(%(if joint["saturated"].getBool(): 1 else: 0))
    else:
      for field in 0 ..< 6:
        result.add(%0)
  for index in 0 ..< MaxFeet:
    if index < body["feet"].len:
      let foot = body["feet"][index]
      result.add(%(if foot["on_ground"].getBool(): 1 else: 0))
      for field in ["x_m", "slip_m_s"]:
        result.add(%foot[field].number())
    else:
      for field in 0 ..< 3:
        result.add(%0)
  let gait = view["gait_now"]
  for name in Gaits:
    result.add(%(if gait["gait"].getStr() == name: 1 else: 0))
  for field in Fields[1 .. ^1]:
    result.add(%gait[field].number())
  for field in ["stride_hz", "cycle_pct"]:
    result.add(%gait[field].number())
  for field in ["return", "par", "max"]:
    result.add(%view["totals"][field].number())
  let report = view["last_turn"]
  result.add(%(if report.kind == JNull: 0 else: 1))
  for field in ["distance_m", "mean_vx_m_s", "strides", "peak_torque_pct",
      "saturated_ticks", "airborne_ticks", "return_delta", "repaired"]:
    result.add(%(if report.kind == JNull: 0.0 else: report[field].number()))
  result.add(%(if report.kind != JNull and report["fell"].getBool(): 1 else: 0))

proc decision(game: SimServer, id: int): JsonNode =
  let view = game.observationJson(0)
  var properties = newJObject()
  var required = newJArray()
  for head in heads():
    let name = head["name"].getStr()
    properties[name] = %*{"enum": head["choices"]}
    required.add(%name)
  %*{
    "kind": "decision", "game": "continuous-control",
    "decision_id": id, "seat": 0, "engine_seat": 0,
    "turn": game.turnsPlayed, "semantic_view": view,
    "inbox": [], "messages": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": userMessage(OperatorPrompt, $view)}
    ], "speech_messages": [],
    "action_schema": {"type": "object", "properties": properties,
      "required": required}, "typed_question": newJNull()
  }

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: cc-train-bridge MANIFEST VARIANT", 1)
  let variant = args[1]
  doAssert variant in Variants
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var game: SimServer
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == 1
      var config = defaultConfig()
      config.update(variantConfig)
      config.seed = seedOf(request["seed"].getStr())
      config.validate()
      game = newSimServer(config)
      game.phase = phPlaying
      game.startStage(0)
      id = 0
      response = game.decision(id)
    of "encode":
      doAssert not game.episodeOver()
      response = %*{"decision_id": id,
        "values": game.observationJson(0).values(variant),
        "action_heads": heads()}
    of "teacher":
      doAssert not game.episodeOver()
      response = %*{"response": $game.scriptedOrder(blTrotter).orderJson()}
    of "step":
      doAssert not game.episodeOver() and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      for head in heads():
        doAssert action[head["name"].getStr()] in head["choices"]
      let order = parseOrderObject(action, game.activeOrder, game.haveOrder)
      doAssert order.orderJson() == action
      game.beginTurn(order)
      let turnEnd = game.tick + game.config.turnTicks
      while game.tick < turnEnd and game.phase != phGameOver:
        game.stepTick()
        if game.ladderComplete():
          break
      game.endTurn("")
      inc id
      if game.episodeOver():
        game.settle(endComplete,
          if game.ladderComplete(): erLadderComplete else: erTurnCap)
        let score = float(game.totalReturnMicro) / 1_000_000.0
        let utility = clamp(float(game.totalReturnMicro) /
          float(maxReturnMicro(game.config)), -1.0, 1.0)
        response = %*{"kind": "accepted", "action": action,
          "observation": %*{"kind": "terminal", "scores": {"0": score},
            "utilities": {"0": utility}}}
      else:
        response = %*{"kind": "accepted", "action": action,
          "observation": game.decision(id)}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
