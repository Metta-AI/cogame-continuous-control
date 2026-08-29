## The viewer — §Tests 41-46, 48.

import std/[algorithm, json, os, sequtils, strutils, unittest]
import crunchy/sha256
import cc/[sim, sim_config, report, broadcast, global, labels, wire_constants,
           replay_runtime, baselines]
import helpers

let page = readRepoFile("client/replay_broadcast.html")
let core = readRepoFile("client/broadcast_core.js")
let chrome = readRepoFile("client/chrome_common.js")
let starter = "/workspace/starters/coworld-ctf"

suite "chrome provenance":
  test "41. chrome_common.js is byte-identical to the starter's":
    ## Not edited, not reformatted. Everything this game adds lives in the
    ## appended game block; `wire_constants.nim` publishes BOTH
    ## `window.CC_WIRE` and the `window.CTF_WIRE` alias this file reads, which
    ## is what keeps the byte-for-byte pin and the rename compatible.
    check chrome.len == 40_022
    var digest = ""
    for byteValue in sha256(chrome):
      digest.add(toHex(int(byteValue), 2).toLowerAscii())
    check digest ==
      "7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c"
    check "window.CTF_WIRE" in chrome
    check "window.CC_WIRE=window.CTF_WIRE" notin chrome
    check "window.CTF_WIRE=window.CC_WIRE;" in WireConstantsJs
    check "window.CC_WIRE={" in WireConstantsJs

  test "42. the broadcast page is the starter's page plus an appended block":
    ## It is coworld-ctf's own page with the removed elements cut out and the
    ## game block appended under its banner — not a lookalike that reuses the
    ## starter's ids (cogame-gridlock, 2026-08-23).
    check "CONTINUOUS-CONTROL additions to the inherited coworld-ctf chrome" in
      page
    ## the starter's structural landmarks survive, verbatim
    for landmark in ["<div id=\"viewport\"", "id=\"stage\"", "id=\"board\"",
                     "id=\"lightpool\"", "id=\"grain\"", "id=\"lockerroom\"",
                     "id=\"chrome\"", "id=\"scorebug\"", "id=\"plates-l\"",
                     "id=\"plates-r\"", "id=\"clock\"", "id=\"clock-time\"",
                     "id=\"clock-caption\"", "id=\"ffwd-mini\"",
                     "id=\"bannerlane\"", "id=\"killfeed\"", "id=\"mmwarn\"",
                     "id=\"transport\"", "id=\"btn-restart\"",
                     "id=\"btn-back\"", "id=\"btn-play\"", "id=\"btn-fwd\"",
                     "id=\"btn-end\"", "id=\"btn-loop\"", "id=\"btn-skip\"",
                     "id=\"btn-spoilers\"", "id=\"ffwd-chip\"",
                     "id=\"win-chip\"", "id=\"tick-clock\"",
                     "id=\"speedchips\"", "id=\"scrub\"", "id=\"momentum\"",
                     "id=\"scrub-fill\"", "id=\"lulls\"", "id=\"scrub-win\"",
                     "id=\"scrub-head\"", "id=\"endcard\"",
                     "id=\"ec-headline\"", "id=\"ec-wincond\"",
                     "id=\"ec-how\"", "id=\"ec-teams\"", "id=\"ec-replay\"",
                     "id=\"status\"", "id=\"fpv\"", "id=\"fpv-canvas\"",
                     "id=\"fpv-hud\"", "id=\"fpv-name\"", "id=\"fpv-cap\"",
                     "id=\"fpv-grip\""]:
      checkpoint(landmark)
      check landmark in page
    ## the splice hook keeps the starter's signatures
    check "window.CcChrome.install(PB_CTX)" in page
    check "window.CcChrome.frame(s, PB_CTX, jumped)" in page
    check "window.CcChrome.event(e, s, PB_CTX)" in page
    ## broadcast_core.js is the starter's, modulo the documented rename
    if dirExists(starter):
      let original = readFile(starter / "client/broadcast_core.js")
      check core.replace("window.CC_WIRE", "window.CTF_WIRE")
        .replace("src/cc/sim.nim", "src/ctf/sim.nim").endsWith(
          original.split("\n", 3)[3])
      check chrome == readFile(starter / "client/chrome_common.js")
    ## pushFeed keeps its SIGNATURE and its call site (the cogball 0.1.4 latch
    ## scar: a signature drift threw mid-replay and latched static_replay.js
    ## into `failed`). The game block routes EVERY feed line through it.
    if dirExists(starter):
      let originalPage = readFile(starter / "client/replay_broadcast.html")
      let signature = originalPage[originalPage.find("function pushFeed(") ..
        originalPage.find(")", originalPage.find("function pushFeed("))]
      check signature in page
    check "ctx.pushFeed(text, cls" in page

  test "43. no game-block identifier shadows a chrome alias":
    ## `var markBeat = C.markBeat` hoists over a same-named function
    ## declaration (the tandem 2026-08-23 trap), so the beat builder is
    ## `ccBeat` and every game-block helper carries the `cc` prefix.
    ## The slice starts INSIDE the block's own banner comment, so the opener
    ## is re-attached before stripping: otherwise the banner's explanation of
    ## the hoisting trap reads as code that falls into it.
    let blockText = stripJsComments(
      "<!--" & page[page.find("CONTINUOUS-CONTROL additions") .. ^1])
    check "function ccBeat(" in blockText
    check "function markBeat(" notin blockText
    for alias in ["markBeat", "renderBeatMarkers", "ingestBeats",
                  "renderClock", "renderTransport", "ingestLullSpans",
                  "renderMomentum", "pushFeed", "banner", "esc", "fmt"]:
      checkpoint(alias)
      check ("function " & alias & "(") notin blockText
      check ("var " & alias & " =") notin blockText

  test "44. beat CSS matches EXACTLY the kinds the sim emits":
    var styled: seq[string] = @[]
    for kind in BeatKinds:
      if (".beat-marker." & kind) in page:
        styled.add(kind)
    check styled.sorted() == @BeatKinds.sorted()
    ## and no CSS survives for a kind this game never emits
    for gone in ["kill", "steal", "return", "capture", "gamestart",
                 "hillflip", "tagout", "gameover"]:
      checkpoint(gone)
      check (".beat-marker." & gone) notin page

  test "45. transport, endcard and the 360 px rules":
    let endcardRule = page[page.find("#endcard {") ..
      page.find("}", page.find("#endcard {"))]
    check "bottom: var(--band, 0px);" in endcardRule
    ## relayout() still owns --band / --topband / --hudscale on :root
    check "--band" in page
    check "--topband" in page
    check "--hudscale" in page
    check "setProperty('--hudscale'" in page
    check "setProperty('--band'" in page
    ## every seek dismisses the endcard
    check "classList.remove('on')" in page
    ## the removed ids appear NOWHERE as elements
    for gone in ["id=\"viewpanel\"", "id=\"minimap\"", "id=\"minimap-canvas\"",
                 "id=\"zoombar\"", "id=\"zoom-in\"", "id=\"zoom-out\"",
                 "id=\"zoom-slider\"", "id=\"zoom-read\"",
                 "id=\"povBadge\"", "id=\"fpv-hp\"", "id=\"fpv-gear\"",
                 "id=\"fpv-map\"", "id=\"fpv-map-canvas\""]:
      checkpoint(gone)
      check gone notin page
    check "attachMinimap(" notin page
    check "renderFpv(" notin page
    ## the five `.tiny` rules this game adds
    check ".plate-name {" in page
    check "flex: 1 1 auto;" in page
    check "min-width: 3.2em;" in page
    check "#stage.tiny #cc-ribbon" in page
    check "#stage.tiny #cc-pips" in page
    check "#stage.tiny #cc-strip" in page
    check "#stage.tiny #fpv" in page
    check "#stage.tiny #fpv-grip { display: none; }" in page
    check "@media (max-width: 640px)" in page
    ## NO GAME-BLOCK ELEMENT SITS IN THE TRANSPORT BAND. Every panel this
    ## block adds hangs off `var(--topband)` (the top band relayout() owns) or
    ## lives inside the board region; none is `position: fixed` and none
    ## anchors to the bottom of the viewport.
    let blockText = page[page.find("CONTINUOUS-CONTROL additions") .. ^1]
    check "position: fixed" notin blockText
    for panel in ["#cc-ribbon", "#cc-pips", "#cc-strip"]:
      checkpoint(panel)
      let rule = blockText[blockText.find(panel & " {") ..
        blockText.find("}", blockText.find(panel & " {"))]
      check "var(--topband, 0px)" in rule
      check "bottom:" notin rule

  test "46. the state JSON keeps ctf's own key names":
    let run = runScriptedEpisode(ladderConfig(
      @[mHopper, mCheetah, mWalker], 91))
    let state = parseJson(run.sim.buildStateJson(
      newJArray(), playing = true, speed = 1, maxTick = run.sim.tick,
      looping = true, transportEnabled = true, mismatchTick = -1,
      startTick = 0, endHoldSeconds = 3, skipLulls = true,
      fastForwarding = false, lullSpans = @[[10, 60]],
      returnSeries = @[[0, 0], [100, 1_000]],
      beats = @[Beat(tick: 4, kind: "fall", label: "DOWN")], sendLead = true))
    for key in ["t", "mt", "ph", "lob", "pl", "sp", "mx", "st", "lp", "sk",
                "ff", "en", "mm", "bs", "pov", "teams", "roster", "events",
                "lead", "lulls", "over", "hold"]:
      checkpoint(key)
      check state.hasKey(key)
    ## exactly ONE `teams` entry, so chrome_common renders one plate in
    ## #plates-l and #plates-r stays empty
    var teamKeys: seq[string] = @[]
    for key in state["teams"].keys: teamKeys.add(key)
    check teamKeys == @["alpha"]
    ## everything this game adds lives under `cc` / `orders` / `cc_beats`
    check state.hasKey("cc")
    check state.hasKey("orders")
    check state.hasKey("cc_beats")
    check state["cc"]["body"]["links"].len == 7
    check state["roster"][0]["name"].getStr().len > 0
    check state["roster"][0]["alias"].getStr() == "Alpha"

  test "48. the board label vocabulary equals tests/label_manifest.txt":
    var pinned: seq[string] = @[]
    for line in readRepoFile("tests/label_manifest.txt").splitLines():
      let text = line.strip()
      if text.len > 0 and not text.startsWith("#"):
        pinned.add(text)
    check boardLabelVocabulary().sorted() == pinned.sorted()
    ## and no real policy name can reach it
    for label in boardLabelVocabulary():
      check "daveey" notin label.toLowerAscii()
