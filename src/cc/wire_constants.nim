## The JS wire-constants block: the handful of engine constants the browser
## chromes must agree with. Rendered ONCE, from the same Nim consts the engine
## runs on; `server.nim` splices the block into every served client page and
## `tools/gen_wire_constants.nim` emits it for the static wasm bundle.
##
## The block publishes `window.CC_WIRE` and ALIASES `window.CTF_WIRE` to it.
## The alias is not laziness: `client/chrome_common.js` is inherited
## BYTE-FOR-BYTE from `coworld-ctf` (its sha256 is pinned as a literal in
## `tests/test_cc_viewer.nim`), and that file reads `window.CTF_WIRE` for the
## speed chips and the fps. Renaming inside it would break the byte-for-byte
## pin; publishing both names keeps the chrome verbatim AND gives this game's
## own code the renamed global.

import std/strutils
import sim_types

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, value in values:
    if i > 0: result.add(",")
    result.add($value)
  result.add("]")

const WireConstantsJs* =
  "window.CC_WIRE={speeds:" & jsIntArray(PlaybackSpeeds) &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",boardW:" & $MapWidth &
  ",boardH:" & $MapHeight &
  ",umPerPixel:" & $UmPerPixel &
  ",maxSayRunes:" & $MaxSayRunes &
  ",maxNoteRunes:" & $MaxNoteRunes &
  "};window.CTF_WIRE=window.CC_WIRE;"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"

proc spliceWireConstants*(page: string): string =
  page.replace(WireConstantsMarker, "<script>" & WireConstantsJs & "</script>")
