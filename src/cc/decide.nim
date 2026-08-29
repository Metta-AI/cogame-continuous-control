## The decision layer: the per-turn loop that asks the seat what it does next,
## and ALWAYS has an answer.
##
## Cadence: one command turn every `turnTicks` (36 ticks = 1.5 s), at most 42
## turns per episode. THE PER-TURN LLM CALL BUDGET IS EXACTLY ONE REQUEST, PLUS
## AT MOST ONE RETRY. There is a single seat, so the starter's
## one-parallel-batch-per-turn machinery (`curly.makeRequests`,
## `src/ctf/decide.nim:427`) carries a batch of ONE and is otherwise untouched:
## at most 42 x 2 = 84 provider calls per episode, never more than one in
## flight.
##
## DEGRADE, NEVER HANG. Every wait is bounded: attempt 1 gets `attempt1Ms`, the
## single retry gets `retryMs`, the whole turn is wrapped in a monotonic
## `turnBudgetMs` deadline, a rolling 60 s request counter refuses a call that
## would cross the sidecar's per-episode cap, and the budget guard switches the
## LLM off for the rest of the episode the moment two more full turns would not
## fit inside the engine's wall-clock stop.
##
## On the seat's timeout or parse failure the call is RETRIED ONCE; on the
## second failure the turn's order becomes the `trotter` scripted order computed
## inside the game — the same proc the `trotter` baseline uses, imported, never
## duplicated. The attempt-1 notice says "will retry"; only a genuine second
## failure logs "falling back" (the pommerman 0.1.1 phase-60 grep scar).

import std/[json, monotimes, os, strutils, times, unicode]
import curly
import sim_types, sim, driver, directives, baselines, llm, report

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field —
    ## or never registers at all — is `trotter`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    params*: BaselineParams
    seats*: seq[SeatPolicy]
    lastCallStart*: MonoTime
    callStarted*: bool
    llmOff*: bool                 ## the budget guard fired; scripted from here
    requestTimes*: seq[MonoTime]  ## the rolling 60 s request counter
    records*: seq[string]

const
  RollingWindowSeconds = 60
  RollingRequestCap = 28
    ## `turnSpacingMs` pins the steady state at 23 req/min, but a run of
    ## retrying turns issues two requests each. If issuing the next request
    ## would push the trailing-60 s count above this, the turn skips the call
    ## and takes the `trotter` order with `cause = "rate_guard"`. Bounded,
    ## logged, and never a sleep on the episode's critical path (the raid round
    ## 2 sidecar-throttle scar).

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.client = newLlmClient(sim.config)
  result.params = defaultBaselineParams()
  result.seats = newSeq[SeatPolicy](sim.seatCount())
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blTrotter
    result.seats[i].label = "trotter"

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm: "llm"
  else: "scripted"

proc fallbackRecord*(turn, attempt: int, cause, detail: string): string =
  $(%*{
    "k": "fallback", "turn": turn, "attempt": attempt, "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)})

proc registerRecord*(slot: int, alias, name, policy, kind,
                     baseline: string): string =
  ## The REDACTED registration record. The seat's PROMPT is never written: only
  ## the policy label, the kind, and which baseline a scripted seat picked.
  $(%*{
    "k": "register", "slot": slot, "alias": alias, "name": name,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind, "baseline": baseline})

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

proc orderRecord*(sim: SimServer, order: Order, turn, slot: int,
                  view: JsonNode): string =
  ## The replay chat record for one turn's order. Re-applied at playback into
  ## NON-HASHED fields only: it drives the broadcast feed and
  ## `tools/replay_summary.py` and can never affect the simulation.
  var record = %*{
    "k": "order",
    "turn": turn,
    "stage": sim.stageIndex,
    "slot": slot,
    "alias": seatAlias(slot),
    "source": $order.source,
    "latency_ms": order.latencyMs,
    "gait": $order.gait,
    "cadence": int(order.cadence),
    "power": int(order.power),
    "lean": int(order.lean),
    "stride_bias": int(order.strideBias),
    "phase_shift": int(order.phaseShift),
    "repaired": order.repaired,
    "say": order.say.truncateRunes(MaxSayRunes)}
  if not view.isNil:
    ## The observation MINUS `notes`, so the replay explains every decision.
    var mirrored = view.copy()
    if mirrored.hasKey("last_turn") and
        mirrored["last_turn"].kind == JObject and
        mirrored["last_turn"].hasKey("notes"):
      mirrored["last_turn"].delete("notes")
    record["view"] = mirrored
  result = $record
  var guard = 0
  while result.runeLen > MaxOrderRecordRunes and guard < 4:
    inc guard
    record.delete("view")
    result = $record

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record — the episode's whole results document,
  ## written once into the replay chat stream at episode end. It is what makes
  ## the replay SELF-SUFFICIENT: without it the outcome exists only at
  ## `COGAME_RESULTS_URI`.
  "{\"k\":\"result\",\"results\":" & $sim.ladderResultsJson() & "}"

proc pruneWindow(engine: var DecisionEngine) =
  let now = getMonoTime()
  var kept: seq[MonoTime]
  for stamp in engine.requestTimes:
    if (now - stamp).inSeconds < RollingWindowSeconds:
      kept.add(stamp)
  engine.requestTimes = kept

proc rateGuardBlocks(engine: var DecisionEngine): bool =
  engine.pruneWindow()
  engine.requestTimes.len >= RollingRequestCap

proc turn*(engine: var DecisionEngine, sim: SimServer, turnIndex: int,
           elapsedSeconds: int):
    tuple[order: Order, records: seq[string], view: JsonNode] =
  ## Runs ONE decision turn for the single seat and returns its order plus the
  ## replay chat records the turn produced. NEVER RAISES: every failure path
  ## ends in a legal order.
  const seat = 0
  let
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
  ## Throttle state is PER TURN: a 429 on turn k says nothing about turn k + 1.
  engine.client.throttled = false
  result.view = sim.observationJson(seat)
  let previous = sim.activeOrder

  template scripted(kind: Baseline): Order =
    block:
      var order = scriptedOrder(engine.params, sim, kind)
      order.source = osScripted
      order

  template fallbackOrder(cause, detail: string, attempt: int): Order =
    ## The `trotter` scripted order computed server-side — the SAME proc the
    ## `trotter` baseline uses, imported, never duplicated.
    block:
      var order = scriptedOrder(engine.params, sim, blTrotter)
      order.source = osFallback
      order.notes = ""
      engine.records.add(fallbackRecord(turnIndex, attempt, cause, detail))
      order

  template finish(chosen: Order) =
    result.order = chosen
    result.records = engine.records
    engine.records = @[]
    return

  # --- budget guard: settle EARLY rather than overrun ----------------------
  if not engine.llmOff:
    let turnSeconds =
      (sim.config.turnSpacingMs + sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      engine.records.add(budgetGuardRecord(
        turnIndex, max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "continuous-control: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  if not engine.seats[seat].isLlm:
    finish(scripted(engine.seats[seat].baseline))

  if engine.llmOff or engine.client.disabled:
    let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
    echo "continuous-control llm: seat ", seat,
      " falling back to trotter (", cause, ") on turn ", turnIndex
    finish(fallbackOrder(cause,
      "the LLM is unavailable for this turn; playing trotter", 1))

  if engine.rateGuardBlocks():
    echo "continuous-control llm: seat ", seat,
      " falling back to trotter (rate_guard) on turn ", turnIndex
    finish(fallbackOrder("rate_guard",
      "the trailing 60 s request count is at the cap", 1))

  # --- the rate floor ------------------------------------------------------
  # Hold the START of consecutive requests `turnSpacingMs` apart, which pins
  # the episode at 23 req/min against the sidecar's 30/min per-episode cap.
  # The cert fixture sets it to 0, so offline runs pay nothing.
  if engine.callStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastCallStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  engine.lastCallStart = getMonoTime()
  engine.callStarted = true

  var
    attempt = 0
    lastCause = "parse_error"
    lastDetail = "no usable reply"
  while attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      lastCause = "timeout"
      lastDetail = "per-turn budget exhausted before attempt " & $(attempt + 1)
      break
    ## Each attempt's deadline is clamped to what is LEFT of the outer budget,
    ## floored at 1 000 ms because curl's CURLOPT_TIMEOUT granularity is whole
    ## seconds and floors.
    let
      spentMs = (getMonoTime() - turnStart).inMilliseconds.int
      remainingMs = max(0, sim.config.turnBudgetMs - spentMs)
      configuredMs =
        if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
      deadlineMs = max(1000, min(configuredMs, remainingMs))
    var user = $result.view
    if attempt > 0:
      user.add("\n\nYour previous reply was not usable. Reply with ONLY the " &
        "JSON object described above, starting with '{'.")
    let request = engine.client.requestFor(
      SystemPrompt, userMessage(engine.seats[seat].prompt, user))
    ## ONE seat, so this is a BATCH OF ONE through the starter's unchanged
    ## batching path. The code is the starter's; the batch simply carries one
    ## request.
    var batch: RequestBatch
    batch.post(request.url, request.headers, request.body, $seat)
    let started = getMonoTime()
    engine.requestTimes.add(started)
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    try:
      let text = engine.client.textOf(
        responses[0].response, responses[0].error, batch[0].url)
      var order = parseOrderReply(text, previous, sim.haveOrder)
      order.source = osLlm
      order.latencyMs = latency
      finish(order)
    except CatchableError as error:
      lastDetail = error.msg
      if responses[0].error.len > 0:
        lastCause =
          if "timeout" in responses[0].error.toLowerAscii(): "timeout"
          else: "transport_error"
      elif error.msg.startsWith("llm throttled"):
        lastCause = "throttled"
      else:
        lastCause = "parse_error"
      if attempt == 0:
        ## "will retry" — NOT "falling back". Only a genuine second failure may
        ## say "falling back", which is the phrase phase 60 greps for.
        echo "continuous-control llm: seat ", seat,
          " attempt 1 failed, will retry: ", error.msg
        engine.records.add(fallbackRecord(turnIndex, 1, lastCause, error.msg))
    inc attempt
    if engine.client.throttled:
      echo "continuous-control llm: provider throttled with no other ",
        "candidate; seat ", seat, " falls back for turn ", turnIndex
      break

  echo "continuous-control llm: seat ", seat, " falling back to trotter (",
    lastCause, ") on turn ", turnIndex
  finish(fallbackOrder(lastCause, lastDetail, 2))
