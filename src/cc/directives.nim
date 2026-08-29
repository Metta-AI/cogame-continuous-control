## The reply schema: what a policy (LLM or scripted) may say, how a reply is
## parsed TOLERANTLY, and how an illegal reply is REPAIRED rather than
## rejected.
##
## Both policy kinds emit the SAME object through the SAME validator, which is
## what makes the bounded-orders test in `tests/test_cc_baselines.nim`
## meaningful and a scripted baseline legal by construction.
##
## RUNE DISCIPLINE. Every cap here is measured in RUNES (Unicode codepoints)
## and every truncation lands on a rune boundary (`runeLen` / `runeSubStr`).
## Slicing a string by BYTE index anywhere on the path to the replay is
## forbidden: a byte-truncated multi-byte character renders fine in a browser
## and then fails a strict UTF-8 parser.
##
## OUT-OF-RANGE NUMBERS ARE CLAMPED, NEVER DROPPED. Unlike an irreversible push
## in Sokoban there is no irreversible move here, so a clamped
## `power: 140 -> 100` is the honest reading of the intent. Every clamp
## increments `repaired` and is reported back to the seat next turn.

import std/[json, math, strutils, unicode]
import sim_types, driver

type
  OrderError* = object of ValueError

proc sanitizeSay*(text: string): string =
  ## The cog thinking out loud: capped at `MaxSayRunes` on a rune boundary
  ## FIRST, then stripped of control characters. That order matters — the rune
  ## cut never leaves half a codepoint for the filter to smear.
  result = ""
  for rune in text.replace("\n", " ").replace("\r", " ")
      .truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    ## Braces are excluded deliberately: the replay chat stream tells a CONTROL
    ## record from a cog's line by a leading '{'.
    if value >= 32 and value != ord('{') and value != ord('}'):
      result.add($rune)
  result = result.strip()

proc sanitizeNote*(text: string): string =
  ## The private scratchpad, echoed back to this seat only next turn. Newlines
  ## collapse to spaces so one record stays one line.
  text.replace("\n", " ").replace("\r", " ").strip()
    .truncateRunes(MaxNoteRunes)

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is
  ## what recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(OrderError,
      "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc readNumber(node: JsonNode): tuple[ok: bool, value: float] =
  ## One numeric field: an int, a float, or a NUMERIC STRING. Anything
  ## non-finite reports `ok = false` so the caller applies its own repair
  ## rather than inventing a value.
  if node.isNil:
    return (false, 0.0)
  case node.kind
  of JInt:
    (true, float(node.getBiggestInt()))
  of JFloat:
    let f = node.getFloat()
    if f != f or f > 1.0e9 or f < -1.0e9: (false, 0.0) else: (true, f)
  of JString:
    try: (true, parseFloat(node.getStr().strip()))
    except CatchableError: (false, 0.0)
  of JBool:
    (true, (if node.getBool(): 1.0 else: 0.0))
  else:
    (false, 0.0)

proc roundHalf(value: float): int =
  if value >= 0.0: int(value + 0.5) else: -int(-value + 0.5)

proc parseOrderObject*(payload: JsonNode, previous: Order,
                       hasPrevious: bool): Order =
  ## Validates and clamps field by field, in the schema's order. A field that
  ## is missing or unusable inherits LAST TURN's value, and on the first turn of
  ## a stage the schema's declared default.
  if payload.isNil or payload.kind != JObject:
    raise newException(OrderError, "reply is not a JSON object")
  let base = if hasPrevious: previous else: defaultOrder()
  result = base
  result.say = ""
  result.notes = ""
  result.repaired = 0
  result.phaseShift = 0     ## a ONE-OFF nudge, never inherited
  var usable = 0

  ## gait — closed enum, <= 8 runes, case-insensitive, synonyms accepted
  let gaitNode = payload{"gait"}
  if not gaitNode.isNil and gaitNode.kind == JString:
    let raw = gaitNode.getStr().strip()
    let parsed = parseGait(raw.truncateRunes(MaxGaitRunes))
    if parsed.ok:
      result.gait = parsed.gait
      inc usable
      if raw.runeLen > MaxGaitRunes or raw != raw.toLowerAscii():
        inc result.repaired
    else:
      inc result.repaired

  template numeric(key: string, field: untyped, lo, hi: int32,
                   fractional: bool) =
    let node = payload{key}
    let read = readNumber(node)
    if read.ok:
      inc usable
      var value = read.value
      if fractional and value >= -1.0 and value <= 1.0 and
          abs(value - value.round()) > 0.0001:
        ## A percentage given as -1.0 .. 1.0 is a fraction of the range.
        value = value * 50.0
        inc result.repaired
      let whole = roundHalf(value)
      if whole < int(lo) or whole > int(hi):
        inc result.repaired
      field = int32(clamp(whole, int(lo), int(hi)))
    elif not node.isNil:
      inc result.repaired

  ## cadence — 0 .. 100, and a decimal below 6 is read as HERTZ
  let cadenceNode = payload{"cadence"}
  let cadenceRead = readNumber(cadenceNode)
  if cadenceRead.ok:
    inc usable
    var value = cadenceRead.value
    if value > 0.0 and value < 6.0 and abs(value - value.round()) > 0.0001:
      ## Given in Hz: map onto the morphology's 0.80 .. 4.00 Hz band.
      value = (value - 0.8) * 100.0 / 3.2
      inc result.repaired
    let whole = roundHalf(value)
    if whole < 0 or whole > 100:
      inc result.repaired
    result.cadence = int32(clamp(whole, 0, 100))
  elif not cadenceNode.isNil:
    inc result.repaired

  numeric("power", result.power, 0, 100, false)
  numeric("lean", result.lean, -50, 50, true)
  numeric("stride_bias", result.strideBias, -50, 50, true)
  numeric("phase_shift", result.phaseShift, -50, 50, true)

  let sayNode = payload{"say"}
  if not sayNode.isNil and sayNode.kind == JString:
    let raw = sayNode.getStr()
    result.say = sanitizeSay(raw)
    if raw.runeLen > MaxSayRunes:
      inc result.repaired
    ## A reply with a valid `say` but no usable order field is USABLE: last
    ## turn's order continues and the narration is delivered.
    inc usable

  let noteNode = payload{"notes"}
  if not noteNode.isNil and noteNode.kind == JString:
    let raw = noteNode.getStr()
    result.notes = sanitizeNote(raw)
    if raw.runeLen > MaxNoteRunes:
      inc result.repaired

  if usable == 0:
    raise newException(OrderError, "reply carried no usable field")

  ## Belt and braces: every field is inside its documented range whatever the
  ## reply said, so the driver can never see an illegal order.
  result.cadence = int32(clamp(int(result.cadence), 0, 100))
  result.power = int32(clamp(int(result.power), 0, 100))
  result.lean = int32(clamp(int(result.lean), -50, 50))
  result.strideBias = int32(clamp(int(result.strideBias), -50, 50))
  result.phaseShift = int32(clamp(int(result.phaseShift), -50, 50))
  result.say = sanitizeSay(result.say)
  result.notes = sanitizeNote(result.notes)

proc parseOrderReply*(text: string, previous: Order,
                      hasPrevious: bool): Order =
  ## The whole reply is capped at `MaxReplyBytes` BEFORE parsing: an over-long
  ## reply is a parse failure, which the decision engine retries once.
  if text.len > MaxReplyBytes:
    raise newException(OrderError,
      "reply is " & $text.len & " bytes, over the " & $MaxReplyBytes &
      " byte cap")
  parseOrderObject(extractJsonObject(text), previous, hasPrevious)

proc orderJson*(order: Order): JsonNode =
  %*{
    "gait": $order.gait,
    "cadence": int(order.cadence),
    "power": int(order.power),
    "lean": int(order.lean),
    "stride_bias": int(order.strideBias),
    "phase_shift": int(order.phaseShift)}

proc isBounded*(order: Order): bool =
  ## What `tests/test_cc_baselines.nim` 22 asserts of EVERY order a baseline
  ## can propose, in every state.
  order.cadence >= 0 and order.cadence <= 100 and
    order.power >= 0 and order.power <= 100 and
    order.lean >= -50 and order.lean <= 50 and
    order.strideBias >= -50 and order.strideBias <= 50 and
    order.phaseShift >= -50 and order.phaseShift <= 50
