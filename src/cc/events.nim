## The tier-2 analysis stream written to `COGAME_EVENTS_URI`.
##
## The starter's JSON-lines `eventsJsonl` contract, kept — including the
## MANDATORY trailing summary row, which is how a reader distinguishes "this
## episode had no events" from "the file was truncated".
##
## `Servo` is the PER-TICK row carrying every joint's target angle and applied
## torque: the full continuous-control action trace the idea's neural-policy
## teams want, up to 1 512 rows an episode, which the replay deliberately does
## not carry.

import std/json
import sim_types

type
  SimEventKind* = enum
    seStageStart = "StageStart"
    seTurnStart = "TurnStart"
    seOrder = "Order"
    seFallback = "Fallback"
    seServo = "Servo"
    seFootstrike = "Footstrike"
    seMilestone = "Milestone"
    seFall = "Fall"
    seStageEnd = "StageEnd"

  EventLog* = ref object
    rows*: seq[string]
    enabled*: bool

proc newEventLog*(enabled = true): EventLog =
  EventLog(enabled: enabled)

proc add*(log: EventLog, kind: SimEventKind, tick: int, payload: JsonNode) =
  if not log.enabled:
    return
  var row = payload
  if row.isNil or row.kind != JObject:
    row = newJObject()
  row["type"] = %($kind)
  row["tick"] = %tick
  log.rows.add($row)

proc eventsJsonl*(log: EventLog, ticks: int): string =
  for row in log.rows:
    result.add(row)
    result.add("\n")
  result.add($(%*{
    "type": "summary", "ticks": ticks, "events": log.rows.len,
    "gameVersion": GameVersion}))
  result.add("\n")

proc eventKindNames*(): seq[string] =
  for kind in SimEventKind:
    result.add($kind)
