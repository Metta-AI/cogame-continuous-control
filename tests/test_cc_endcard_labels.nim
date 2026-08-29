## Endcard and chrome label re-mapping — §Test 47.
##
## A forked ctf endcard silently ships paintbot's vocabulary: nothing in the
## starter's tests, in `viewer_smoke.mjs` or in the label manifest covers
## SPECTATOR CHROME STRINGS, because `labels.nim` deliberately scopes itself to
## the POLICY contract. The re-labelings are therefore enumerated here and
## enforced.
##
## The gate is on what a SPECTATOR READS. It runs against the page with every
## comment block removed, and it is exact about the strings rather than about
## identifiers: the starter's unreachable `PB_MODE` plate branch still carries
## `hillchip` as an ID, and renaming a dead identifier is a rewrite of working
## chrome, not a re-labelling.

import std/[strutils, unittest]
import helpers

let page = readRepoFile("client/replay_broadcast.html")
let core = readRepoFile("client/broadcast_core.js")
let blockText = page[page.find("CONTINUOUS-CONTROL additions") .. ^1]

suite "the spectator vocabulary is this game's, not paintbot's":
  test "47a. the paintbot copy the design note lists as re-mapped is gone":
    for gone in ["<span class=\"fl-cap\">Lives left</span>",
                 "<span class=\"fl-cap\">Hill time</span>",
                 "<span class=\"momentum-label\">LIVES LEAD</span>",
                 "<span class=\"lives-label\">Lives</span>",
                 "<span class=\"lives-label pb-lbl\">Hill</span>",
                 "<span>Clstr</span>",
                 "<div class=\"fpv-cap\" id=\"fpv-cap\">EYES</div>",
                 "Filling hoppers with fresh paint",
                 ">In the locker room<",
                 "showing recorded inputs",
                 "Spoilers: kills / flag story / winner",
                 "\U0001f441 POV lens"]:
      checkpoint(gone)
      check gone notin page

  test "47b. NOTHING this game adds carries paintbot vocabulary":
    var offenders: seq[string] = @[]
    let visible = stripJsComments("<!--" & blockText)
    for word in ["Lives", "LIVES", "Clstr", "flagicon", "heart", "paint",
                 "hoppers", "hillchip", "POV", "EYES", "spray", "grenade",
                 "med kit", "killfeed(", "squad-pip"]:
      if word in visible:
        offenders.add("block: " & word)
    check offenders.len == 0

  test "47c. each re-mapped string is present":
    for text in ["<span class=\"stage-label\">Stage</span>",
                 "<span class=\"stage-label pb-lbl\">Body</span>",
                 "<span class=\"fl-cap\">Stages standing</span>",
                 "<span class=\"fl-cap\">Metres covered</span>",
                 "<span class=\"momentum-label\">RETURN</span>",
                 "Wheeling the first machine onto the track",
                 ">Waiting for the cog<",
                 "resynced from the recorded pose",
                 "<div class=\"fpv-cap\" id=\"fpv-cap\">GAIT ORDER</div>",
                 "Spoilers: falls and stage results on the timeline"]:
      checkpoint(text)
      check page.count(text) >= 1
    ## the endcard's two table headers, re-mapped
    check page.count("<span>Stage</span><span>Body</span>" &
      "<span>Result</span><span>Distance</span><span>Return</span>") >= 1
    check page.count("<span>Cog</span><span>Metres</span>" &
      "<span>Falls</span><span>Return</span>") >= 1
    ## and the stage chips replaced the flag glyph, same element and id
    check "class=\"stagechips\" id=\"flag-'" in page
    check "stage-chip" in page

  test "47d. the plate carries the alias and the endcard the morphology":
    ## team words RED / BLUE become the seat's ALIAS on the plate and the
    ## MORPHOLOGY name as the endcard section head.
    check "cc-alias" in page
    check "MORPH[g.stage.morph]" in page
    check "ec-tname-alpha" in page
    check "CC_WIRE" in core
    check "window.CTF_WIRE" notin core
