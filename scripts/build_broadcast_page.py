#!/usr/bin/env python3
"""Derives client/replay_broadcast.html from the inherited coworld-ctf page.

The page is NOT written from scratch. It is the starter's broadcast page with

  * exactly the elements the design note's Viewer section lists as REMOVED cut
    out (markup, CSS, wiring and test ids),
  * the spectator-chrome vocabulary re-mapped (the design note's re-labelling
    table), and
  * the CONTINUOUS-CONTROL game block appended under its banner comment, spliced in
    through the starter's own `window.PaintballChrome` hook renamed
    `window.CcChrome`.

A page written from scratch that reuses the starter's ids is a rewrite and
fails review (cogame-gridlock, 2026-08-23), so this script exists to make the
provenance mechanical and checkable: run it against a fresh checkout of
coworld-ctf and it reproduces the shipped file.

    python3 scripts/build_broadcast_page.py \
        /workspace/starters/coworld-ctf/client/replay_broadcast.html \
        client/replay_broadcast.html client/cc_block.html
"""

import sys


def cut(text, start, end, note, inclusive_end=True):
    """Deletes the span from `start` to `end`, asserting both anchors exist."""
    i = text.index(start)
    j = text.index(end, i)
    if inclusive_end:
        j += len(end)
    removed = text[i:j]
    assert removed, note
    return text[:i] + text[j:]


def swap(text, old, new, count=None):
    found = text.count(old)
    assert found, "anchor not found: " + old[:70]
    if count is not None:
        assert found == count, "%d occurrences of %r, expected %d" % (
            found, old[:50], count)
    return text.replace(old, new)


def main():
    src, dst, block_path = sys.argv[1], sys.argv[2], sys.argv[3]
    page = open(src, encoding="utf-8").read()

    # ---------------------------------------------------------------- CSS ---
    page = cut(page, "#povBadge {", "#povBadge.on { display: flex; }\n",
               "povBadge CSS")
    page = cut(page, ".fpv-hp {", ".fpv-dead .fpv-hp, .fpv-dead .fpv-gear "
               "{ opacity: 0.4; }\n", "fpv hp/gear CSS")
    page = cut(page, "/* Un-fogged tactical minimap inset",
               "/* ---------- 4b. VIEW CONTROLS", "fpv-map CSS",
               inclusive_end=False)
    page = cut(page, "/* ---------- 4b. VIEW CONTROLS",
               "#zoom-read.zoomed { color: var(--amber); }\n",
               "viewpanel + zoombar CSS")
    page = cut(page, "/* Opt-OUT of the #viewpanel overlay",
               "body[data-noviewpanel] #viewpanel { display: none !important; }\n",
               "viewpanel opt-out CSS")
    page = cut(page, "#endcard .ec-heart {",
               "/* loop countdown \u2014 present only while the server holds "
               "the end segment */", "ec-heart CSS", inclusive_end=False)
    page = cut(page, "/* kill ticks are short and colored",
               "/* winner cap: a flat block just past the track",
               "kill/steal/return/capture beat CSS", inclusive_end=False)

    # ------------------------------------------------------------- markup ---
    page = cut(page, "    <!-- View controls: zoom the board",
               "    </div>\n\n    <div id=\"mmwarn\">",
               "viewpanel markup", inclusive_end=False)
    page = swap(page, "    <div id=\"povBadge\">"
                "\U0001f441 POV lens \u2014 click to clear</div>\n", "", 1)
    page = swap(page, "        <span class=\"fpv-hp\" id=\"fpv-hp\"></span>\n"
                "        <span class=\"fpv-gear\" id=\"fpv-gear\"></span>\n",
                "", 1)
    page = cut(page, "      <!-- Un-fogged tactical minimap",
               "      <div class=\"fpv-cap\" id=\"fpv-cap\">",
               "fpv-map markup", inclusive_end=False)

    # ----------------------------------------------------------- the JS -----
    # The whole raycast first-person pipeline. This game is PERFECT
    # INFORMATION: there is nothing to occlude, so it is deleted outright
    # rather than left as unreachable code. The #fpv CANVAS is reused (as the
    # gait card); the raycaster is not.
    page = cut(page, "  function renderFpv(s) {",
               "  function renderMismatch(s) {",
               "raycast FPV pipeline", inclusive_end=False)
    page = swap(page, """  function renderPov(s) {
    var badge = $('povBadge');
    badge.classList.toggle('on', s.pov >= 0);
    if (s.pov >= 0) badge.textContent = '\U0001f441 POV: ' + shortName(rosterName(s, s.pov)) + ' \u2014 click to clear';
    renderFpv(s);
  }
""", """  // With ONE seat there is nothing to select, so the POV badge and the
  // raycast lens are gone; the #fpv panel is repurposed wholesale as the
  // gait card, which the appended CONTINUOUS-CONTROL block draws.
  function renderPov(s) { return s; }
""", 1)
    page = swap(page, "  $('povBadge').addEventListener('click', "
                "function () { send('v:-1'); });\n", "", 1)
    page = cut(page, "  // ---- view controls: zoom cluster + minimap",
               "  canvas.addEventListener('dblclick', function (ev) {",
               "zoom bar + minimap wiring", inclusive_end=False)
    page = swap(page, """    onFirstFrame: function () { core.setViewportFit(); syncViewUi(); },""",
                """    onFirstFrame: function () { core.setViewportFit(); },""", 1)
    page = swap(page, """    onTransform: function (t) { syncViewUi(t); }""",
                """    onTransform: function (t) { syncTouchAction(t); }""", 1)
    page = cut(page, "  // ?viewpanel=0 hides the #viewpanel overlay",
               "  // Tick deep-link (?t=<tick>)",
               "viewpanel query-param wiring", inclusive_end=False)


    # The first-person map ingest reads `s.fpmap`, which this game never emits
    # (perfect information: there is no fog layer to silhouette). Deleted, not
    # left as unreachable code.
    page = cut(page, "  // The server ships the static minimap wall silhouette",
               "  // ---------- scorebug ----------", "fp map ingest",
               inclusive_end=False)
    page = swap(page, "    ingestFpMap(s);\n", "", 1)
    page = swap(page, """    <!-- First-person picture-in-picture: the selected seat's Wolfenstein-style
         raycast view, shown only while a player is in POV. A window into what
         that soldier sees down the barrel, riding alongside their top-down fog.
         Its own inset tactical map (bottom-left) shows the seat's position and
         vision cone against the WHOLE un-fogged arena, so the viewer always
         knows where the EYES are looking and standing. -->""",
                """    <!-- The GAIT CARD. The starter's first-person panel, repurposed
         wholesale: the gait name in large type, five labelled bars for
         cadence / power / lean / stride bias / phase shift, and a phase wheel
         showing cycle_pct ticking round once per stride so the order is
         visibly RUNNING, not just displayed. Draggable and resizable by the
         starter's own grip. This game is PERFECT INFORMATION, so nothing here
         is a lens on a fogged view. -->""", 1)


    # The eye-level billboard art belonged to the raycaster, which is gone. The
    # COG_BASE path expression stays: the locker-room curtain and the appended
    # block both resolve their assets through it, and it is the ONE place that
    # maps the page's three delivery routes.
    page = cut(page, "  var COG_ART = {}, COG_ART_GUN = {};",
               "  // ---- pre-load curtain: the bot locker room", "eye-level billboard art",
               inclusive_end=False)
    page = swap(page, "window.CtfStaticReplay", "window.CcStaticReplay")
    # One cog, and it is red: the blue/green/yellow locker-room webps are not
    # shipped, so the curtain seats the red bot alone.
    page = cut(page, "      green:  { ax: 22.83", "      red:    { ax: 79.03",
               "locker-room bot roster", inclusive_end=False)
    page = swap(page, "    ['green', 'blue', 'yellow', 'red'].forEach"
                "(function (bot) {", "    ['red'].forEach(function (bot) {", 1)
    page = swap(page, "      red:    { ax: 79.03", "      red:    { ax: 50.00", 1)

    # -------------------------------------------- spectator vocabulary ------
    page = swap(page, "Filling hoppers with fresh paint&hellip;",
                "Wheeling the first machine onto the track&hellip;")
    page = swap(page, "Filling hoppers with fresh paint\u2026",
                "Wheeling the first machine onto the track\u2026")
    page = swap(page, ">In the locker room<", ">Waiting for the cog<", 1)
    page = swap(page,
                "Replay hash mismatch \u2014 showing recorded inputs",
                "Replay hash mismatch \u2014 resynced from the recorded pose", 1)
    page = swap(page, "<div class=\"fpv-cap\" id=\"fpv-cap\">EYES</div>",
                "<div class=\"fpv-cap\" id=\"fpv-cap\">GAIT ORDER</div>", 1)
    page = swap(page,
                "title=\"Spoilers: kills / flag story / winner on the "
                "timeline ahead of the playhead (o)\"",
                "title=\"Spoilers: falls and stage results on the timeline "
                "ahead of the playhead (o)\"", 1)
    page = swap(page, "<span class=\"momentum-label\">LIVES LEAD</span>",
                "<span class=\"momentum-label\">RETURN</span>", 1)
    page = swap(page, "<span class=\"lives-label\">Lives</span>",
                "<span class=\"stage-label\">Stage</span>", 1)
    page = swap(page, "<span class=\"lives-label pb-lbl\">Hill</span>",
                "<span class=\"stage-label pb-lbl\">Body</span>", 1)
    page = swap(page, "<span class=\"fl-cap\">Lives left</span>",
                "<span class=\"fl-cap\">Stages standing</span>", 1)
    page = swap(page, "<span class=\"fl-cap\">Hill time</span>",
                "<span class=\"fl-cap\">Metres covered</span>", 1)
    page = swap(page,
                "'<div class=\"ec-thead\"><span>Player</span><span>K</span>"
                "<span>D</span><span>TK</span><span>Clstr</span><span>Cap</span>"
                "</div>'",
                "'<div class=\"ec-thead\"><span>Stage</span><span>Body</span>"
                "<span>Result</span><span>Distance</span><span>Return</span>"
                "</div>'", 1)
    page = swap(page,
                "'<div class=\"ec-thead\"><span>Cog</span><span>Tags</span>"
                "<span>Out</span><span>Paint</span></div>'",
                "'<div class=\"ec-thead\"><span>Cog</span><span>Metres</span>"
                "<span>Falls</span><span>Return</span></div>'", 1)
    page = swap(page, ".lives-label {", ".stage-label {")
    page = swap(page, "<div class=\"flagicon\" id=\"flag-'",
                "<div class=\"stagechips\" id=\"flag-'", 1)
    page = swap(page, ".flagicon {", ".stagechips {")
    page = swap(page, ".flagicon ", ".stagechips ")
    page = swap(page,
                "'<span class=\"team-name\" id=\"name-' + team + '\">'",
                "'<span class=\"team-name plate-name\" id=\"name-' + team + "
                "'\">'", 1)

    # `buildFlag` keeps its name, its call site and its `.carrier-tag` child
    # (updateFlag writes into it); only what it DRAWS changes, from paintbot's
    # flag to this game's three stage chips.
    page = cut(page, "  // ---- flag icon svg", "  // (speed chips are built",
               "buildFlag body", inclusive_end=False)
    page = swap(page, "  // (speed chips are built", """  // ---- stage chips (three, filled as stages resolve) ----
  // The starter's flag glyph, retargeted: same element, same id, same
  // `.carrier-tag` child, so every call site in the inherited chrome still
  // works; only what it draws changes.
  function buildFlag(el, color) {
    var chips = '';
    for (var i = 0; i < 3; i++) {
      chips += '<i class="stage-chip" data-i="' + i + '"></i>';
    }
    el.innerHTML = chips + '<div class="carrier-tag"></div>';
    el.style.setProperty('--stage-col', color || '#e8a33d');
  }

  // (speed chips are built""", 1)

    # -------------------------------------------------- the appended block --
    marker = "<!-- ============================================================\n" \
             "     PAINTBALL additions to the inherited coworld-ctf chrome"
    index = page.index(marker)
    page = page[:index] + open(block_path, encoding="utf-8").read()
    page = swap(page, "window.PaintballChrome", "window.CcChrome")
    page = swap(page, "PB_MODE && window.CcChrome",
                "CC_READY && window.CcChrome")
    page = swap(page, "if (!PB_MODE && s.regime !== undefined) PB_MODE = true;",
                "if (!CC_READY && s.cc !== undefined) CC_READY = true;", 1)
    page = swap(page, "  var PB_MODE = false;", "  var PB_MODE = false;\n"
                "  // Latched on the first frame that carries this game's own\n"
                "  // `sok` payload, exactly as PB_MODE latches on `regime`.\n"
                "  var CC_READY = false;", 1)
    page = swap(page, "<title>Ctf \u2014 Broadcast Replay</title>",
                "<title>Continuous control \u2014 Broadcast Replay</title>", 1)
    open(dst, "w", encoding="utf-8").write(page)
    print("wrote", dst, len(page), "bytes")


if __name__ == "__main__":
    main()
