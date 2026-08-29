## The board-label vocabulary contract.
##
## The starter's `labels.nim` deliberately scopes itself to what is DRAWN on
## the board, so the two-name-space rule is enforceable by a test:
## `tests/label_manifest.txt` lists every string this game can draw on the
## board, and `tests/test_cc_viewer.nim` asserts the emitted set equals it.
##
## `showPlayerLabels` is false, as in the starter's paintball variant, so
## NOTHING DRAWN ON THE BOARD LEAKS AN IDENTITY: the cog's own alias is the
## only name the board can carry, and the real policy name lives spectator-side
## only (the scorebug plate, the endcard, `results.names`).

import std/strutils
import sim_types

const
  BoardLabels* = [
    "ALPHA",        ## the seat's in-game alias, and the only name on the board
    "HOPPER", "CHEETAH", "WALKER",
    "START", "FINISH",
    "GAIT ORDER"
  ]

proc boardLabelVocabulary*(): seq[string] =
  for label in BoardLabels:
    result.add(label)

proc morphLabel*(morph: Morph): string = ($morph).toUpperAscii()

proc outcomeLabel*(outcome: StageOutcome): string =
  case outcome
  of soLined: "LINED OUT"
  of soRan: "RAN"
  of soFell: "DOWN"
  of soUnreached: "UNREACHED"
  of soRunning: "IN PLAY"

proc fallLabel*(morph: Morph, why: FallWhy, metres: string): string =
  ## The `#bannerlane` line and the `.fall` beat's own label — the idea's own
  ## highlight, and the moment the spectator came for.
  let reason =
    case why
    of fwPitched: "PITCHED PAST THE LIMIT"
    of fwLow: "DROPPED TOO LOW"
    of fwHigh: "LEFT THE GROUND"
    of fwNone: "DOWN"
  "DOWN — " & morphLabel(morph) & " " & reason & " AT " & metres & " M"
