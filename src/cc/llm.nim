## Claude-backed gait orders. A policy is just a prompt: the GAME SERVER
## composes the seat's observation plus that seat's `PLAYER_PROMPT` and asks
## Claude what the machine does for the next 1.5 seconds.
##
## Kept from `coworld-ctf`'s `src/ctf/llm.nim` behaviour for behaviour — the
## credential ladder, the model list, the `throttled` fast-fail, the
## fence-tolerant JSON extraction and the rune-boundary truncation are all that
## file's, because they are all scar tissue from real hosted failures.
##
## Credentials, in order of preference:
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to the
## scripted layer INSTANTLY, with no network wait — which is what lets offline
## certification finish in seconds.

import std/[json, os, strutils]
import curly
import sim_types, sim_config

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
      ## The provider answered 429 and there is no other candidate model to
      ## rotate to. Set per turn and cleared by the turn loop: retrying inside
      ## the same turn cannot succeed, so the seat fails fast to the scripted
      ## fallback instead of spending the turn budget on a refused call.

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "continuous-control llm: failed to fetch ANTHROPIC_API_KEY_URI: ",
      error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order; `BEDROCK_MODEL` pins
  ## one. `us.anthropic.claude-sonnet-4-6` is DELIBERATELY NOT a candidate: it
  ## times out on every sidecar call (cogame-raid round 2, 2026-08-23).
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "continuous-control llm: ",
    client.bedrockModels[client.bedrockModel - 1], " unusable (", why,
    "); falling back to ", client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens))
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "continuous-control llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "continuous-control llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside "falling
    ## back" in decide.nim.
    echo "continuous-control llm: no credentials — the LLM provider is ",
      "unavailable; every turn is falling back to the scripted layer"

proc requestFor*(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live. The
  ## assistant turn is PREFILLED with `{` so the reply cannot open with prose
  ## and be cut off at `max_tokens` before any JSON (the procgen 0.1.2 fix,
  ## taken from day one rather than after the fact).
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [
      {"role": "user", "content": user},
      {"role": "assistant", "content": "{"}]}
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(client: LlmClient, response: Response, error, url: string): string =
  ## The text of one reply, or an `LlmError` describing why there is none.
  ## Auth failure disables the client for the rest of the episode;
  ## model-access denial and throttling rotate the Bedrock model instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes. A byte slice can cut a codepoint in
    ## half, and `truncateRunes` downstream only SHORTENS — it cannot repair one.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(LlmError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  ## Re-prefix the prefill unless the provider echoed it back.
  let head = result.strip()
  if not head.startsWith("{"):
    result = "{" & result
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

const SystemPrompt* = """
You are ONE cog driving ONE machine down a flat 60-metre track, seen from the
side. x runs right (forward), y runs up. You get THREE machines in one episode,
one after the other, 19.5 seconds each, and your score is the RETURN: metres
covered, plus a small bonus per second upright, minus a small cost for slamming
the joints. Higher is better. It can go negative.

THE MACHINES
  HOPPER  4 links, 3 joints, ONE leg. Falls if the torso drops below 0.70 m or
          pitches past 20 degrees. Worth 2.00 points per metre.
  CHEETAH 7 links, 6 joints, two legs, long body. CANNOT fall - there is no
          upright to lose. Worth 0.50 points per metre, so it has to go far.
  WALKER  7 links, 6 joints, two legs, upright torso. Falls below 0.80 m or
          past 57 degrees of pitch. Worth 1.50 points per metre.
Each machine is worth about twenty points to a competent run. None of them
dominates the episode.

WHAT YOU SEND, EVERY 1.5 SECONDS
One JSON object: a GAIT and five numbers. A deterministic pattern generator in
the game runs your order 240 times a second on every joint until your next
order. You are not sending torques; you are tuning the machine that sends them.
  "gait"         stand | crouch | walk | run | bound | brake
                 stand  = neutral pose, no stride. Settle here.
                 crouch = low pose, no stride. Plant the feet before you move.
                 walk   = long slow stride, both feet down often. Stable.
                 run    = short fast stride. The workhorse.
                 bound  = big amplitude, big air, big risk. Hoppers live here.
                 brake  = amplitude zero and PURE DAMPING: the position
                          servo is switched off entirely. It kills speed at
                          once. On the CHEETAH that is free. On the HOPPER or
                          the WALKER nothing is holding you up any more, so a
                          brake is how you END a stage, not how you save one.
  "cadence"      0-100. Stride frequency. High cadence with a heavy machine
                 means the feet never load; low cadence means you never move.
  "power"        0-100. Scales BOTH the joint amplitude and the torque ceiling.
                 Power costs score, and a saturated joint tracks nothing.
  "lean"         -50..+50. Pitch the whole body. Positive is forward. Forward
                 lean is how you accelerate and how you fall over.
  "stride_bias"  -50..+50. Shifts amplitude from the back leg to the front leg.
                 0 on a hopper. Small values on a walker fix a limp.
  "phase_shift"  -50..+50. Percent of one stride cycle. A ONE-OFF nudge so a
                 new gait starts on the correct foot instead of mid-air.
  "say"          <=140 chars, spectators only.
  "notes"        <=320 chars, echoed back to you next turn. Nobody else sees it.

WHAT YOU GET BACK
Every joint's angle, rate, limits and how much of its torque ceiling the servo
just used ("torque_pct", and "saturated" when it is pegged). Every foot's
ground contact and slip. Torso height, pitch, forward speed. Your x on the
track. What your LAST order actually achieved: distance, mean speed, strides,
peak torque, saturated ticks, airborne ticks, and whether you fell.

READ THOSE NUMBERS. They are the whole game:
  saturated joints          -> your power is too high for this cadence.
  slip above ~0.5 m/s       -> the foot is skating; lower cadence or power.
  airborne_ticks near 36    -> you are launching, not running.
  distance_m near zero with -> you are marching on the spot; add lean.
    high strides
  pitch heading toward the fall limit -> cut power and shorten the stride.
    A brake will NOT save you: it switches the servo off.

REPLY FORMAT
Reply with ONE JSON object and NOTHING else. Your reply MUST begin with the
character { and end with }. No prose, no markdown, no code fences.
{"gait":"run","cadence":72,"power":85,"lean":12,"stride_bias":0,"phase_shift":0,"say":"<=140 chars","notes":"<=320 chars"}
"""

proc operatorBlock*(prompt: string): string =
  ## The seat's own `PLAYER_PROMPT`, under a heading that tells the model how
  ## much weight it carries. NEVER echoed into the replay or the results — only
  ## `policyKind`, the label and the resulting order are.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt, viewJson: string): string =
  operatorBlock(operatorPrompt) & viewJson
