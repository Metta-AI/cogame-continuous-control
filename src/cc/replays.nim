## The binary `COWLDCCL` replay codec.
##
## Forked from the starter's `src/ctf/replays.nim` (`CtfReplayMagic =
## "COWLDCTF"` -> `CcReplayMagic = "COWLDCCL"`, plus the state-keyframe record):
## magic + format version + game name/version header, the RESOLVED config JSON,
## then the record stream and one `gameHash` per tick.
##
## THE PHYSICS IS RE-DERIVED, NOT RECORDED. This game's ONLY inputs are the
## per-turn orders, so the record stream is tiny and the whole episode
## re-derives from it by re-running the identical `src/cc/sim.nim` compiled to
## wasm. That is the idea's own integrity clause — "replay verification by
## deterministic re-simulation" — implemented as the ONLY way the viewer works,
## so a divergence cannot go unnoticed.
##
## STATE KEYFRAMES ARE BOTH A SEEK INDEX AND A CROSS-CHECK. Every
## `stateKeyframeTicks` ticks (and at every stage start) the full link state is
## recorded: 32 keyframes x 7 links x 6 x 4 B = 5.4 KB. Seeking is then
## O(48 ticks) instead of O(t), and at each keyframe the re-simulated state must
## equal the recorded one.
##
## THE WALL-CLOCK STOP IS A LOAD-BEARING RECORD, not an inference. A wall-clock
## fact cannot be re-derived from sim state, so the stop is written as one
## record applied by the SAME proc on record and on playback (the
## particle-worlds 2026-08-26 scar).

import std/json
import sim_types, driver

const
  CcReplayMagic* = "COWLDCCL"
  ReplayFormatVersion* = 1

type
  RecordKind* = enum
    rkStage = 1
    rkOrder = 2
    rkChat = 3
    rkStop = 4
    rkKeyframe = 5

  StagePayload* = object
    index*: int
    morph*: Morph
    perturb*: array[MaxJoints, int32]
    startTick*: int

  OrderPayload* = object
    turn*: int
    stage*: int
    source*: OrderSource
    gait*: Gait
    cadence*, power*, lean*, strideBias*, phaseShift*: int32
    repaired*: int
    say*: string
    notes*: string

  KeyframePayload* = object
    words*: seq[int32]

  StopPayload* = object
    tick*: int
    reason*: EndReason
    endRule*: EndRule
    detail*: string

  ReplayRecord* = object
    kind*: RecordKind
    tick*: int
    stage*: StagePayload
    order*: OrderPayload
    keyframe*: KeyframePayload
    chat*: string
    stop*: StopPayload

  ReplayData* = object
    gameName*: string
    gameVersion*: string
    protocol*: string
    config*: JsonNode
    records*: seq[ReplayRecord]
    hashes*: seq[uint64]

# ---------------------------------------------------------------------------
#  Little-endian primitives
# ---------------------------------------------------------------------------

proc addU8(bytes: var string, value: int) =
  bytes.add(char(value and 0xFF))

proc addU16(bytes: var string, value: int) =
  bytes.add(char(value and 0xFF))
  bytes.add(char((value shr 8) and 0xFF))

proc addRawU32(bytes: var string, value: uint32) =
  for shift in [0, 8, 16, 24]:
    bytes.add(char(int((value shr shift) and 0xFF'u32)))

proc addU32(bytes: var string, value: int) =
  ## Lengths and tick counts only, all far under 2^31.
  bytes.addRawU32(uint32(value))

proc addI32(bytes: var string, value: int32) =
  ## A SIGNED word goes out through `uint32`, never through `int`: Nim's `int`
  ## is 32 bits under `--cpu:wasm32`, so a negative Q16 word round-tripped as
  ## an `int` traps with "value out of range" the moment the viewer parses it
  ## (CI run 33247466068).
  bytes.addRawU32(cast[uint32](value))

proc addU64(bytes: var string, value: uint64) =
  for shift in 0 ..< 8:
    bytes.add(char(int((value shr (shift * 8)) and 0xFF'u64)))

proc addText(bytes: var string, text: string) =
  bytes.addU32(text.len)
  bytes.add(text)

type Cursor = object
  data: string
  offset: int

proc need(cursor: var Cursor, count: int) =
  if count < 0 or cursor.offset + count > cursor.data.len:
    raise newException(CcError, "replay truncated")

proc readU8(cursor: var Cursor): int =
  cursor.need(1)
  result = int(uint8(cursor.data[cursor.offset]))
  inc cursor.offset

proc readU16(cursor: var Cursor): int =
  cursor.need(2)
  result = int(uint8(cursor.data[cursor.offset])) or
    (int(uint8(cursor.data[cursor.offset + 1])) shl 8)
  cursor.offset += 2

proc readRawU32(cursor: var Cursor): uint32 =
  cursor.need(4)
  for shift in [0, 8, 16, 24]:
    result = result or (uint32(uint8(cursor.data[cursor.offset])) shl shift)
    inc cursor.offset

proc readU32(cursor: var Cursor): int =
  ## Lengths and tick counts only. A file claiming a length past 2^31 is
  ## refused here rather than trapping inside the wasm runtime.
  let raw = cursor.readRawU32()
  if raw > uint32(high(int32)):
    raise newException(CcError, "replay length field is implausible")
  int(raw)

proc readI32(cursor: var Cursor): int32 =
  ## See `addI32`: the SIGNED word never passes through `int`.
  cast[int32](cursor.readRawU32())

proc readU64(cursor: var Cursor): uint64 =
  cursor.need(8)
  for shift in 0 ..< 8:
    result = result or
      (uint64(uint8(cursor.data[cursor.offset])) shl (shift * 8))
    inc cursor.offset

proc readText(cursor: var Cursor): string =
  let length = cursor.readU32()
  cursor.need(length)
  result = cursor.data[cursor.offset ..< cursor.offset + length]
  cursor.offset += length

# ---------------------------------------------------------------------------
#  Writing
# ---------------------------------------------------------------------------

type ReplayWriter* = ref object
  header*: string
  body*: string
  hashes*: seq[uint64]

proc newReplayWriter*(config: JsonNode): ReplayWriter =
  result = ReplayWriter()
  result.header.add(CcReplayMagic)
  result.header.addU16(ReplayFormatVersion)
  result.header.addText(GameName)
  result.header.addText(GameVersion)
  result.header.addText(ProtocolName)
  result.header.addText($config)

proc writeStage*(writer: ReplayWriter, tick: int, payload: StagePayload) =
  writer.body.addU8(ord(rkStage))
  writer.body.addU32(tick)
  writer.body.addU16(payload.index)
  writer.body.addText($payload.morph)
  writer.body.addU32(payload.startTick)
  writer.body.addU16(MaxJoints)
  for j in 0 ..< MaxJoints:
    writer.body.addI32(payload.perturb[j])

proc writeOrder*(writer: ReplayWriter, tick: int, payload: OrderPayload) =
  writer.body.addU8(ord(rkOrder))
  writer.body.addU32(tick)
  writer.body.addU16(payload.turn)
  writer.body.addU16(payload.stage + 1)
  writer.body.addU8(ord(payload.source))
  writer.body.addU8(ord(payload.gait))
  writer.body.addI32(payload.cadence)
  writer.body.addI32(payload.power)
  writer.body.addI32(payload.lean)
  writer.body.addI32(payload.strideBias)
  writer.body.addI32(payload.phaseShift)
  writer.body.addU16(payload.repaired)
  writer.body.addText(payload.say)
  writer.body.addText(payload.notes)

proc writeKeyframe*(writer: ReplayWriter, tick: int, words: openArray[int32]) =
  writer.body.addU8(ord(rkKeyframe))
  writer.body.addU32(tick)
  writer.body.addU16(words.len)
  for value in words:
    writer.body.addI32(value)

proc writeChat*(writer: ReplayWriter, tick: int, record: string) =
  writer.body.addU8(ord(rkChat))
  writer.body.addU32(tick)
  writer.body.addText(record)

proc writeStop*(writer: ReplayWriter, stop: StopPayload) =
  writer.body.addU8(ord(rkStop))
  writer.body.addU32(stop.tick)
  writer.body.addText($stop.reason)
  writer.body.addText($stop.endRule)
  writer.body.addText(stop.detail)

proc writeHash*(writer: ReplayWriter, value: uint64) =
  writer.hashes.add(value)

proc bytes*(writer: ReplayWriter): string =
  result = writer.header
  result.addU32(writer.body.len)
  result.add(writer.body)
  result.addU32(writer.hashes.len)
  for value in writer.hashes:
    result.addU64(value)

# ---------------------------------------------------------------------------
#  Reading
# ---------------------------------------------------------------------------

proc parseReplayBytes*(data: string): ReplayData =
  var cursor = Cursor(data: data, offset: 0)
  cursor.need(CcReplayMagic.len)
  if data[0 ..< CcReplayMagic.len] != CcReplayMagic:
    raise newException(CcError, "not a " & CcReplayMagic & " replay")
  cursor.offset = CcReplayMagic.len
  let format = cursor.readU16()
  if format != ReplayFormatVersion:
    raise newException(CcError,
      "replay format version " & $format & " is not supported")
  result.gameName = cursor.readText()
  result.gameVersion = cursor.readText()
  result.protocol = cursor.readText()
  result.config = parseJson(cursor.readText())
  let bodyLength = cursor.readU32()
  let bodyEnd = cursor.offset + bodyLength
  while cursor.offset < bodyEnd:
    var record: ReplayRecord
    let kind = cursor.readU8()
    if kind < ord(low(RecordKind)) or kind > ord(high(RecordKind)):
      raise newException(CcError, "unknown replay record kind " & $kind)
    record.kind = RecordKind(kind)
    record.tick = cursor.readU32()
    case record.kind
    of rkStage:
      record.stage.index = cursor.readU16()
      let morph = parseMorph(cursor.readText())
      if not morph.ok:
        raise newException(CcError, "unknown morphology in stage record")
      record.stage.morph = morph.morph
      record.stage.startTick = cursor.readU32()
      let count = cursor.readU16()
      for j in 0 ..< count:
        let value = cursor.readI32()
        if j < MaxJoints:
          record.stage.perturb[j] = value
    of rkOrder:
      record.order.turn = cursor.readU16()
      record.order.stage = cursor.readU16() - 1
      let source = cursor.readU8()
      if source > ord(high(OrderSource)):
        raise newException(CcError, "unknown order source")
      record.order.source = OrderSource(source)
      let gait = cursor.readU8()
      if gait > ord(high(Gait)):
        raise newException(CcError, "unknown gait in order record")
      record.order.gait = Gait(gait)
      record.order.cadence = cursor.readI32()
      record.order.power = cursor.readI32()
      record.order.lean = cursor.readI32()
      record.order.strideBias = cursor.readI32()
      record.order.phaseShift = cursor.readI32()
      record.order.repaired = cursor.readU16()
      record.order.say = cursor.readText()
      record.order.notes = cursor.readText()
    of rkKeyframe:
      let count = cursor.readU16()
      for _ in 0 ..< count:
        record.keyframe.words.add(cursor.readI32())
    of rkChat:
      record.chat = cursor.readText()
    of rkStop:
      record.stop.tick = record.tick
      let reason = cursor.readText()
      var parsedReason = endComplete
      for value in EndReason:
        if $value == reason:
          parsedReason = value
      record.stop.reason = parsedReason
      let rule = cursor.readText()
      var parsedRule = erLadderComplete
      for value in EndRule:
        if $value == rule:
          parsedRule = value
      record.stop.endRule = parsedRule
      record.stop.detail = cursor.readText()
    result.records.add(record)
  cursor.offset = bodyEnd
  let hashCount = cursor.readU32()
  for _ in 0 ..< hashCount:
    result.hashes.add(cursor.readU64())

proc orderFromPayload*(payload: OrderPayload): Order =
  Order(gait: payload.gait, cadence: payload.cadence, power: payload.power,
        lean: payload.lean, strideBias: payload.strideBias,
        phaseShift: payload.phaseShift, say: payload.say,
        notes: payload.notes, source: payload.source,
        repaired: payload.repaired)

proc chatRecords*(replay: ReplayData): seq[JsonNode] =
  for record in replay.records:
    if record.kind != rkChat:
      continue
    try:
      result.add(parseJson(record.chat))
    except CatchableError:
      discard
